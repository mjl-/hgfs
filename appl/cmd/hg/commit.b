implement HgCommit;

include "sys.m";
	sys: Sys;
	sprint: import sys;
include "draw.m";
include "arg.m";
include "bufio.m";
	bufio: Bufio;
	Iobuf: import bufio;
include "daytime.m";
	daytime: Daytime;
include "readdir.m";
	readdir: Readdir;
include "string.m";
	str: String;
include "tables.m";
	tables: Tables;
	Strhash: import tables;
include "filter.m";
	deflate: Filter;
include "filtertool.m";
	filtertool: Filtertool;
include "mercurial.m";
	hg: Mercurial;
	Dirstate, Dsfile, Revlog, Repo, Change, Manifest, Mfile, Entry: import hg;
include "util0.m";
	util: Util0;
	readfd, rev, join, readfile, l2a, inssort, warn, fail: import util;

HgCommit: module {
	init:	fn(nil: ref Draw->Context, args: list of string);
};


dflag: int;
vflag: int;
repo: ref Repo;
hgpath := "";

init(nil: ref Draw->Context, args: list of string)
{
	sys = load Sys Sys->PATH;
	arg := load Arg Arg->PATH;
	bufio = load Bufio Bufio->PATH;
	bufio->open("/dev/null", Sys->OREAD);
	daytime = load Daytime Daytime->PATH;
	readdir = load Readdir Readdir->PATH;
	str = load String String->PATH;
	tables = load Tables Tables->PATH;
	util = load Util0 Util0->PATH;
	util->init();
	deflate = load Filter Filter->DEFLATEPATH;
	deflate->init();
	filtertool = load Filtertool Filtertool->PATH;
	hg = load Mercurial Mercurial->PATH;
	hg->init();

	arg->init(args);
	arg->setusage(arg->progname()+" [-d] [-h path] [-v] [path ...]");
	while((c := arg->opt()) != 0)
		case c {
		'd' =>	hg->debug = dflag++;
		'h' =>	hgpath = arg->earg();
		'v' =>	vflag++;
		* =>	arg->usage();
		}
	args = arg->argv();

	{ init0(args); }
	exception e {
	"hg:*" =>
		fail(e[3:]);
	}
}

init0(args: list of string)
{
	repo = Repo.xfind(hgpath);
	root := repo.workroot();

	user := hg->xreaduser(repo);
	now := daytime->now();
	tzoff := daytime->local(now).tzoff;
	say(sprint("have user %q, now %d, tzoff %d", user, now, tzoff));

	ds := hg->xdirstate(repo, 0);

	r: list of ref Dsfile;
	pathtab := Strhash[ref Dsfile].new(31, nil);
	if(args == nil)
		r = inspect(r, ds.l, pathtab, nil);
	else
		for(; args != nil; args = tl args)
			r = inspect(r, ds.findall(hd args, 0), pathtab, hd args);
	if(r == nil)
		error("no changes");

	ochrev := repo.xlastrev();
	link := ochrev+1;
	if(ochrev == -1)
		m := ref Manifest (hg->nullnode, nil);
	else
		(nil, m) = repo.xmanifest(ochrev);

	cp1 := ds.p1;
	cp2 := ds.p2;
	mp1 := mp2 := hg->nullnode;
	if(cp1 != hg->nullnode)
		(c1, m1) := repo.xmanifest(repo.xlookup(cp1, 1).t0);
	if(cp2 != hg->nullnode)
		(c2, m2) := repo.xmanifest(repo.xlookup(cp2, 1).t0);
	if(c1 != nil)
		mp1 = c1.manifestnodeid;
	if(c2 != nil)
		mp2 = c2.manifestnodeid;

	say(sprint("newrev and link is %d, changes p1 %s p2 %s, manifest p1 %s p2 %s", link, cp1, cp2, mp1, mp2));

	warn("message:");
	msg := string readfd(sys->fildes(0), -1);
	say(sprint("msg is %q", msg));
	if(msg == nil)
		error("empty commit message, aborting");

	files := l2a(r);
	inssort(files, pathge);
	filenodeids := array[len files] of string;
	modfiles: list of string;
	nds := ref Dirstate (1, hg->nullnode, hg->nullnode, ds.l, nil);
	for(i := 0; i < len files; i++) {
		dsf := files[i];
		path := dsf.path;
		say("handling "+dsf.text());
		m.del(path);
		case dsf.state {
		hg->STremove =>
			modfiles = path::modfiles;
			nds.del(path);
			continue;
		hg->STadd or
		hg->STneedmerge or
		hg->STnormal =>
			;
		* =>
			raise "other state?";
		}

		f := root+"/"+path;
		buf := readfile(f, -1);
		if(buf == nil)
			error(sprint("open %q: %r", f));
		(ok, dir) := sys->stat(f);
		if(ok != 0)
			error(sprint("stat %q: %r", f));

		rl := repo.xopenrevlog(path);

		fp1 := fp2 := hg->nullnode;
		if(m1 != nil && (mf1 := m1.find(path)) != nil)
			fp1 = mf1.nodeid;
		if(m2 != nil && (mf2 := m2.find(path)) != nil)
			fp2 = mf2.nodeid;

		say(sprint("adding to revlog for file %#q, fp1 %s, fp2 %s", path, fp1, fp2));
		ne := revlogadd(rl, fp1, fp2, link, buf);
		filenodeids[i] = ne.nodeid;
		say(sprint("file now at nodeid %s", ne.nodeid));

		mf := ref Mfile (path, dir.mode&8r777, ne.nodeid, 0);
		m.add(mf);
		modfiles = path::modfiles;

		dsf.state = hg->STnormal;
		dsf.size = int dir.length;
		dsf.mtime = dir.mtime;
	}

	say("adding to manifest");
	ml := repo.xmanifestlog();
	mbuf := m.xpack();
	me := revlogadd(ml, mp1, mp2, link, mbuf);

	say("adding to changelog");
	cl := repo.xchangelog();
	cmsg := sprint("%s\n%s\n%d %d\n%s\n\n%s", me.nodeid, user, now, tzoff, join(rev(modfiles), "\n"), msg);
	say(sprint("change message:"));
	say(cmsg);
	ce := revlogadd(cl, cp1, cp2, link, array of byte cmsg);

	nds.p1 = ce.nodeid;
	repo.xwritedirstate(nds);
}

revlogadd(rl: ref Revlog, p1, p2: string, link: int, buf: array of byte): ref Entry
{
	ents := rl.xentries();
	orev := -1;
	offset := big 0;
	if(len ents > 0) {
		ee := ents[len ents-1];
		orev = ee.rev;
		offset = ee.offset+big ee.csize;
	}
	nrev := orev+1;

	p1rev := p2rev := -1;
	if(p1 != hg->nullnode) {
		p1rev = findrev(ents, p1);
		if(p2 != hg->nullnode)
			p2rev = findrev(ents, p2);
	}

	nodeid := hg->xcreatenodeid(buf, p1, p2);

	# xxx should make a patch and use it if patches+newpatch < 2*newsize
	uncsize := len buf;
	compr := compress(buf);
	if(len compr < len buf*90/100) {
		buf = compr;
	} else {
		nbuf := array[1+len buf] of byte;
		nbuf[0] = byte 'u';
		nbuf[1:] = buf;
		buf = nbuf;
	}

	flags := 0;
	base := nrev; # xxx fix when we stop inserting full copies
	isindexonly := rl.isindexonly();
	e := ref Entry (nrev, offset, big 0, flags, len buf, uncsize, base, link, p1rev, p2rev, nodeid);
say(sprint("revlog %q, will be adding %s", rl.path, e.text()));
	ebuf := array[hg->Entrysize] of byte;
	e.xpack(ebuf, isindexonly);

	# xxx if length current .i file < 128k and length current .i+64+len buf >= 128k, copy all data to .d file and create new .i
	ipath := rl.path+".i";
	repo.xensuredirs(ipath);
	ib := hg->xbopencreate(ipath, Sys->OWRITE, 8r666);
	if(ib.seek(big 0, Bufio->SEEKEND) < big 0)
		error(sprint("open %q: %r", ipath));
	if(ib.write(ebuf, len ebuf) != len ebuf)
		error(sprint("write %q: %r", ipath));
	if(isindexonly) {
		if(ib.write(buf, len buf) != len buf)
			error(sprint("write %q: %r", ipath));
	} else {
		dpath := rl.path+".d";
		dfd := hg->xopencreate(dpath, Sys->OWRITE, 8r666);
		if(dfd == nil || ((nil, dir) := sys->fstat(dfd)).t0 != 0)
			error(sprint("open %q: %r", dpath));
		if(sys->pwrite(dfd, buf, len buf, dir.length) != len buf)
			error(sprint("write %q: %r", dpath));
	}
	if(ib.flush() == Bufio->ERROR)
		error(sprint("write %q: %r", ipath));

	return e;
}

findrev(ents: array of ref Entry, n: string): int
{
	for(i := 0; i < len ents; i++)
		if(ents[i].nodeid == n)
			return i;
	error(sprint("no such nodeid %q", n));
	return -1; # not reached
}

inspect(r, l: list of ref Dsfile, tab: ref Strhash[ref Dsfile], path: string): list of ref Dsfile
{
	n := 0;
	for(; l != nil; l = tl l) {
		dsf := hd l;
		if(tab.find(dsf.path) != nil)
			continue;
		case dsf.state {
		hg->STuntracked =>
			continue;
		hg->STnormal or
		hg->STneedmerge =>
			if(hg->STnormal && dsf.size < 0)
				continue;
			warn(sprint("M %q", dsf.path));
		hg->STremove =>
			warn(sprint("R %q", dsf.path));
		hg->STadd =>
			warn(sprint("A %q", dsf.path));
		}

		tab.add(dsf.path, dsf);
		r = dsf::r;
		n++;
	}
	if(n == 0 && path != nil)
		warn(sprint("%q: no matches", path));
	return r;
}

pathge(a, b: ref Dsfile): int
{
	return a.path >= b.path;
}

compress(d: array of byte): array of byte
{
	(nd, err) := filtertool->convert(deflate, "z", d);
	if(err != nil)
		error("deflate: "+err);
	return nd;
}

error(s: string)
{
	raise "hg:"+s;
}

say(s: string)
{
	if(dflag)
		warn(s);
}
