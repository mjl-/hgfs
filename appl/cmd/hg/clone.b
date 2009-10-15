implement HgClone;

include "sys.m";
	sys: Sys;
	sprint: import sys;
include "draw.m";
include "arg.m";
include "bufio.m";
	bufio: Bufio;
	Iobuf: import bufio;
include "string.m";
	str: String;
include "tables.m";
	tables: Tables;
	Strhash: import tables;
include "util0.m";
	util: Util0;
	kill, min, max, rev, hex, g32i, readfile, l2a, inssort, warn, fail: import util;
include "filter.m";
	inflate: Filter;
	deflate: Filter;
include "filtertool.m";
	filtertool: Filtertool;
include "mercurial.m";
	hg: Mercurial;
	Dirstate, Dirstatefile, Revlog, Repo, Change, Manifest, Manifestfile, Entry, Patch: import hg;
include "mhttp.m";
include "../../lib/mercurialremote.m";
	hgrem: Mercurialremote;
	Remrepo: import hgrem;

HgClone: module {
	init:	fn(nil: ref Draw->Context, args: list of string);
};


dflag: int;
Cflag: int;
repo: ref Repo;
hgpath := "";
path: string;
dest: string;

init(nil: ref Draw->Context, args: list of string)
{
	sys = load Sys Sys->PATH;
	arg := load Arg Arg->PATH;
	bufio = load Bufio Bufio->PATH;
	str = load String String->PATH;
	tables = load Tables Tables->PATH;
	util = load Util0 Util0->PATH;
	util->init();
	inflate = load Filter Filter->INFLATEPATH;
	inflate->init();
	deflate = load Filter Filter->DEFLATEPATH;
	deflate->init();
	filtertool = load Filtertool Filtertool->PATH;
	hg = load Mercurial Mercurial->PATH;
	hg->init();
	hgrem = load Mercurialremote Mercurialremote->PATH;
	hgrem->init();

	arg->init(args);
	arg->setusage(arg->progname()+" [-d] path [dest]");
	while((c := arg->opt()) != 0)
		case c {
		'd' =>	hg->debug = dflag++;
		* =>	arg->usage();
		}
	args = arg->argv();
	if(len args == 0 || len args > 2)
		arg->usage();
	path = hd args;
	if(tl args != nil)
		dest = hd tl args;

	{ init0(); }
	exception e {
	"hg:*" =>
		fail(e[3:]);
	}
}

init0()
{
	warn("requesting all changes");
	rr := Remrepo.xnew(nil, path);
	if(dest == nil) {
		dest = rr.xname();
		if(dest == nil)
			error("cannot determine destination directory");
	}
	dest += "/";
	cfd := rr.xchangegroup(nil);

	create(dest, Sys->OREAD, 8r777|Sys->DMDIR);
	create(dest+".hg", Sys->OREAD, 8r777|Sys->DMDIR);
	create(dest+".hg/store", Sys->OREAD, 8r777|Sys->DMDIR);
	create(dest+".hg/store/data", Sys->OREAD, 8r777|Sys->DMDIR);
	fd := create(dest+".hg/hgrc", Sys->OWRITE|Sys->OEXCL, 8r666);
	if(sys->fprint(fd, "[paths]\ndefault = %s\n", path) < 0)
		error(sprint("write %q: %r", dest+".hg/hgrc"));

	fd = create(dest+".hg/requires", Sys->OWRITE|Sys->OTRUNC, 8r666);
	reqbuf := array of byte "revlogv1\nstore\n"; # xxx fncache
	if(sys->write(fd, reqbuf, len reqbuf) != len reqbuf)
		error(sprint("write .hg/requires: %r"));
	fd = nil;

	(ncfd, err) := filtertool->push(inflate, "z", cfd, 0);
	if(err != nil)
		error(err);
	b := bufio->fopen(ncfd, Bufio->OREAD);
	if(b == nil)
		error("fopen");

	warn("adding changesets");
	chtab := revlogwrite(b, dest+".hg/store/", "00changelog", nil);

	warn("adding manifests");
	revlogwrite(b, dest+".hg/store/", "00manifest", chtab);
	

	filedest := dest+".hg/store/data/";
	warn("adding file changes");
	nfiles := 0;
	nchanges := 0;
	for(;;) {
		i := bg32(b);
		if(i == 0)
			break;

		namebuf := breadn(b, i-4);
		name := string namebuf;
		tab := revlogwrite(b, filedest, hg->escape(name), chtab);
		nfiles++;
		nchanges += tablength(tab);
	}

	case b.getc() {
	Bufio->EOF =>	;
	Bufio->ERROR =>	error(sprint("error reading end of changegroup: %r"));
	* =>		error(sprint("data past end of changegroup..."));
	}

	warn(sprint("added %d changesets with %d changes to %d files", tablength(chtab), nchanges, nfiles));
}

revlogwrite(b: ref Iobuf, basedir, path: string, chtab: ref Strhash[ref Entry]): ref Strhash[ref Entry]
{
	ischlog := chtab == nil;

	tab := Strhash[ref Entry].new(31, nil);
	if(ischlog)
		chtab = tab;

	f := basedir+path+".i";
	hg->ensuredirs(basedir, path);
	ib := bufio->create(f, Sys->OWRITE|Sys->OEXCL, 8r666);
	if(ib == nil)
		error(sprint("creating %q: %r", f));
	db: ref Iobuf;
	ents: list of ref Entry;
	bufs: list of array of byte;
	totalsize := big 0;
	current := array[0] of byte;
	deltasizes := 0;
	offset := big 0;

	base := 0;
	nents := 0;
	ebuf := array[hg->Entrysize] of byte;
	for(;;) {
		i := bg32(b);
		if(i == 0)
			break;

		(rev, p1, p2, link, delta) := breadchunk(b, i);
		if(dflag) {
			say(sprint("\trev=%s", rev));
			say(sprint("\tp1=%s", p1));
			say(sprint("\tp2=%s", p2));
			say(sprint("\tlink=%s", link));
			say(sprint("\tlen delta=%d", len delta));
		}

		if(ischlog && rev != link)
			error(sprint("changelog entry %s with bogus link %s", rev, link));
		if(!ischlog && chtab.find(link) == nil)
			error(sprint("entry %s references absent changelog link %s", rev, link));

		p := Patch.xparse(delta);
		if(dflag) {
			say(sprint("\tpatch, sizediff %d", p.sizediff()));
			say(sprint("\t%s", p.text()));
		}
		
		p1rev := p2rev := -1;
		if(p1 != hg->nullnode)
			p1rev = findrev("p1", rev, tab, p1);
		if(p2 != hg->nullnode)
			p2rev = findrev("p2", rev, tab, p2);

		selfrev := nents++;
		linkrev := selfrev;
		if(!ischlog)
			linkrev = findrev("link", rev, chtab, link);

		if(selfrev == 0 && (len p.l != 1 || (c := hd p.l).start != 0 || c.end != 0))
			error(sprint("first change in group does not have single chunk in patch"));

		data: array of byte;
		if(selfrev == 0 || len p.l == 1 && (c = hd p.l).start == 0 && c.end == len current) {
			base = selfrev;
			data = current = (hd p.l).buf;
			deltasizes = 0;

			compr := compress(data);
			if(len compr < len data*90/100) {
				data = compr;
			} else {
				nd := array[1+len data] of byte;
				nd[0] = byte 'u';
				nd[1:] = data;
				data = nd;
			}
		} else {
			current = p.apply(current);
			if(deltasizes+len delta > 2*len current) {
				base = selfrev;
				data = current;
				deltasizes = 0;

				compr := compress(data);
				if(len compr < len data*90/100) {
					data = compr;
				} else {
					nd := array[1+len data] of byte;
					nd[0] = byte 'u';
					nd[1:] = data;
					data = nd;
				}
			} else {
				data = delta;
				deltasizes += len delta;

				compr := compress(data);
				if(len compr < len data*90/100)
					data = compr;
			}
		}
		nrev := hg->xcreatenodeid(current, p1, p2);
		if(nrev != rev)
			error(sprint("nodeid mismatch, expected %s saw %s", rev, nrev));

		flags := 0;
		e := ref Entry(selfrev, offset, big 0, flags, len data, len current, base, linkrev, p1rev, p2rev, rev);

		ntotalsize := totalsize + big hg->Entrysize + big len data;
		if(ntotalsize >= big (128*1024)) {
			if(db == nil) {
				f = basedir+path+".d";
				db = bufio->create(f, Sys->OWRITE|Sys->OTRUNC, 8r666);
				if(db == nil)
					error(sprint("creating %q: %r", f));

				# flush .i and .d contents so far
				for(l := util->rev(ents); l != nil; l = tl l) {
					oe := hd l;
					oe.xpack(ebuf, 0);
					if(ib.write(ebuf, len ebuf) != len ebuf)
						error(sprint("write: %r"));
				}

				for(m := util->rev(bufs); m != nil; m = tl m) {
					buf := hd m;
					if(db.write(buf, len buf) != len buf)
						error(sprint("write: %r"));
				}

				bufs = nil;
				ents = nil;
			}

			e.xpack(ebuf, 0);
			if(ib.write(ebuf, len ebuf) != len ebuf)
				error(sprint("write: %r"));
			if(db.write(data, len data) != len data)
				error(sprint("write: %r"));
		} else {
			bufs = data::bufs;
			ents = e::ents;
		}

		offset += big len data;
		totalsize = ntotalsize;
		tab.add(e.nodeid, e);
	}

	# if no .d file, it's time to flush
	if(totalsize < big (128*1024)) {
		ents = util->rev(ents);
		bufs = util->rev(bufs);
		while(ents != nil) {
			e := hd ents;
			buf := hd bufs;
			ents = tl ents;
			bufs = tl bufs;

			e.xpack(ebuf, 1);
			if(ib.write(ebuf, len ebuf) != len ebuf || ib.write(buf, len buf) != len buf)
				error(sprint("write: %r"));
		}
		if(ib.flush() == Bufio->ERROR)
			error(sprint("write: %r"));
	} else {
		if(ib.flush() == Bufio->ERROR || db.flush() == Bufio->ERROR)
			error(sprint("write: %r"));
	}

	return tab;
}

findrev(name, rev: string, tab: ref Strhash[ref Entry], n: string): int
{
	e := tab.find(n);
	if(e == nil)
		error(sprint("missing %s %s for nodeid %s", name, n, rev));
	return e.rev;
}

bg32(b: ref Iobuf): int
{
	return g32i(breadn(b, 4), 0).t0;
}

breadchunk(b: ref Iobuf, n: int): (string, string, string, string, array of byte)
{
	n -= 4;
	if(n < 4*20)
		error("short chunk");
	buf := breadn(b, n);
	o := 0;
	rev := buf[o:o+20];
	o += 20;
	p1 := buf[o:o+20];
	o += 20;
	p2 := buf[o:o+20];
	o += 20;
	link := buf[o:o+20];
	o += 20;
	delta := buf[o:];
	return (hex(rev), hex(p1), hex(p2), hex(link), delta);
}

breadn(b: ref Iobuf, n: int): array of byte
{
	buf := array[n] of byte;
	h := 0;
	while(h < n) {
		nn := b.read(buf[h:], n-h);
		if(nn == Bufio->EOF)
			error("premature eof");
		if(nn == Bufio->ERROR)
			error(sprint("reading: %r"));
		h += nn;
	}
	return buf;
}

create(f: string, mode, perm: int): ref Sys->FD
{
	fd := sys->create(f, mode, perm);
	if(fd == nil)
		error(sprint("create %q: %r", f));
	return fd;
}

compress(d: array of byte): array of byte
{
	(nd, err) := filtertool->convert(deflate, "z", d);
	if(err != nil)
		error("deflate: "+err);
	return nd;
}

tablength(t: ref Strhash[ref Entry]): int
{
	n := 0;
	for(i := 0; i < len t.items; i++)
		n += len t.items[i];
	return n;
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
