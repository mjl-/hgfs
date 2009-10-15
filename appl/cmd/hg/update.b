implement HgUpdate;

include "sys.m";
	sys: Sys;
	sprint: import sys;
include "draw.m";
include "arg.m";
include "bufio.m";
include "string.m";
	str: String;
include "tables.m";
	tables: Tables;
	Strhash: import tables;
include "mercurial.m";
	hg: Mercurial;
	Dirstate, Dirstatefile, Revlog, Repo, Change, Manifest, Manifestfile, Entry: import hg;
include "util0.m";
	util: Util0;
	readfile, l2a, inssort, warn, fail: import util;

HgUpdate: module {
	init:	fn(nil: ref Draw->Context, args: list of string);
};


dflag: int;
Cflag: int;
repo: ref Repo;
hgpath := "";

init(nil: ref Draw->Context, args: list of string)
{
	sys = load Sys Sys->PATH;
	arg := load Arg Arg->PATH;
	str = load String String->PATH;
	tables = load Tables Tables->PATH;
	util = load Util0 Util0->PATH;
	util->init();
	hg = load Mercurial Mercurial->PATH;
	hg->init();

	arg->init(args);
	arg->setusage(arg->progname()+" [-d] [-h path] [-C] [rev]");
	while((c := arg->opt()) != 0)
		case c {
		'd' =>	hg->debug = dflag++;
		'C' =>	Cflag++;
		'h' =>	hgpath = arg->earg();
		* =>	arg->usage();
		}
	args = arg->argv();
	if(len args > 1)
		arg->usage();
	revstr := "tip";
	if(len args == 1)
		revstr = hd args;

	{ init0(revstr); }
	exception e {
	"hg:*" =>
		fail(e[3:]);
	}
}

init0(revstr: string)
{
	repo = Repo.xfind(hgpath);
	ds := repo.xdirstate();
	if(ds.p2 != hg->nullnode)
		error("checkout has two parents, is in merge, refusing to update");
	onodeid := ds.p1;
	(orev, nil) := repo.xlookup(onodeid, 1);
	say(sprint("current rev %d nodeid %q", orev, onodeid));

	(rev, nodeid) := repo.xlookup(revstr, 1);
	say(sprint("new rev %d nodeid %q, revstr %q", rev, nodeid, revstr));

	(oc, om) := repo.xmanifest(orev);
	(nil, obranch) := oc.findextra("branch");

	nbranch: string;
	if(nodeid == hg->nullnode)
		nm := ref Manifest (hg->nullnode, nil);
	else {
		nc: ref Change;
		(nc, nm) = repo.xmanifest(rev);
		(nil, nbranch) = nc.findextra("branch");
	} 

	wbranch := repo.xworkbranch();
	if(obranch == nil) obranch = "default";
	if(nbranch == nil) nbranch = "default";

	ofiles := om.files;
	nfiles := nm.files;

	i: int;
	omtab := Strhash[ref Manifestfile].new(31, nil);
	for(i = 0; i < len ofiles; i++)
		omtab.add(ofiles[i].path, ofiles[i]);

	dsf := l2a(ds.l);
	for(i = 0; i < len dsf; i++) {
		e := dsf[i];
		case e.state {
		hg->STneedmerge or
		hg->STremove or
		hg->STadd =>
			fail("files have been scheduled for merge, remove or add, refusing to update");
		hg->STnormal =>
			omf := omtab.find(e.path);
			if(omf == nil)
				error(sprint("%#q in dirstate but not in manifest", e.path));
			if(!Cflag && hg->differs(repo, big e.size, e.mtime, omf))
				error(sprint("%#q has been modified, refusing to update", e.path));
		* =>
			raise "missing case";
		}
	}

	# check that files present in new manifest and in working dir but not in old manifest are the same
	oi := ni := 0;
	for(;;) {
		if(oi < len ofiles)
			op := ofiles[oi].path;
		if(ni < len nfiles)
			np := nfiles[ni].path;
		if(op == nil && np == nil)
			break;

		if(np == op) {
			ni++;
			oi++;
		} else if(np != nil && np < op || op == nil) {
			if(!Cflag && exists(np) && hg->differs(repo, big -1, -1, nfiles[ni]))
				error(sprint("%#q is in new revision, not in old, but is different from new version", np));
			ni++;
		} else if(op < np || np == nil) {
			oi++;
		}
	}

	nds := ref Dirstate (nodeid, hg->nullnode, nil);
	oi = ni = 0;
	for(;;) {
		if(oi < len ofiles)
			op := ofiles[oi].path;
		if(ni < len nfiles)
			np := nfiles[ni].path;
		if(op == nil && np == nil)
			break;

		say(sprint("checking %q and %q", op, np));
		if(op == np) {
			if(ofiles[oi].nodeid != nfiles[ni].nodeid || hg->differs(repo, big -1, -1, nfiles[ni])) {
				say(sprint("updating %q", np));
				ewritefile(np, nfiles[ni].nodeid);
			}
			dsadd(nds, np);
			oi++;
			ni++;
		} else if(op != nil && op < np || np == nil) {
			say(sprint("removing %q", op));
			sys->remove(op);
			removedirs(nfiles, op);
			oi++;
		} else if(np < op || op == nil) {
			say(sprint("creating %q", np));
			ewritefile(np, nfiles[ni].nodeid);
			dsadd(nds, np);
			ni++;
		}
	}

	nds.l = util->rev(nds.l);
	repo.xwritedirstate(nds);
	if(obranch != nbranch || nbranch != wbranch)
		repo.xwriteworkbranch(nbranch);
}

removedirs(mf: array of ref Manifestfile, p: string)
{
	(a, nil) := str->splitstrr(p, "/");
	if(a == nil || mfhasprefix(mf, a))
		return;
	a = a[:len a-1];
	sys->remove(a);
	removedirs(mf, a);
}

mfhasprefix(mf: array of ref Manifestfile, p: string): int
{
	for(i := 0; i < len mf; i++)
		if(str->prefix(p, mf[i].path))
			return 1;
	return 0;
}

exists(e: string): int
{
	(ok, dir) := sys->stat(e);
	return ok == 0 && (dir.mode&Sys->DMDIR) == 0;
}

ewritefile(path: string, nodeid: string)
{
	(rl, err) := repo.openrevlog(path);
	buf: array of byte;
	if(err == nil)
		(buf, err) = rl.getnodeid(nodeid);
	if(err != nil)
		fail(err);

	s := ".";
	for(l := sys->tokenize(path, "/").t1; len l > 1; l = tl l) {
		s += "/"+hd l;
		sys->create(s, Sys->OREAD, 8r777|Sys->DMDIR);
	}

	fd := sys->create(path, Sys->OWRITE|Sys->OTRUNC, 8r666);
	if(fd == nil)
		fail(sprint("create %q: %r", path));
	if(sys->write(fd, buf, len buf) != len buf)
		fail(sprint("write %q: %r", path));
}

dsadd(ds: ref Dirstate, path: string)
{
	(ok, dir) := sys->stat(path);
	if(ok < 0)
		fail(sprint("stat %q: %r", path));
	dsf := ref Dirstatefile (hg->STnormal, dir.mode&8r777, int dir.length, dir.mtime, path, nil);
	ds.l = dsf::ds.l;
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
