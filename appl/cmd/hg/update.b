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
	Dirstate, Dsfile, Revlog, Repo, Change, Manifest, Mfile, Entry: import hg;
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
	ds := hg->xdirstate(repo, 0);

	# xxx do special things when two parents are present (i.e. we were merging)?
	onodeid := ds.p1;
	(orev, nil) := repo.xlookup(onodeid, 1);
	say(sprint("current rev %d nodeid %q", orev, onodeid));

	(rev, nodeid) := repo.xlookup(revstr, 1);
	say(sprint("new rev %d nodeid %q, revstr %q", rev, nodeid, revstr));

	(oc, om) := repo.xrevision(orev);
	(nil, obranch) := oc.findextra("branch");

	nbranch: string;
	nm := repo.xmanifest(nodeid);
	if(nodeid != hg->nullnode) {
		(nc, nil) := repo.xrevision(rev);
		(nil, nbranch) = nc.findextra("branch");
	}

	wbranch := repo.xworkbranch();
	if(obranch == nil) obranch = "default";
	if(nbranch == nil) nbranch = "default";

	ofiles := om.files;
	nfiles := nm.files;

	dsf := l2a(ds.l);
	for(i := 0; i < len dsf; i++) {
		f := dsf[i];
		case f.state {
		hg->STuntracked =>
			if(!Cflag && om.find(f.path) == nil && (mf := nm.find(f.path)) != nil && hg->differs(repo, mf))
				error(sprint("untracked file %q is present by different in target revision, refusing to update without -C", f.path));
		hg->STneedmerge or
		hg->STremove or
		hg->STadd =>
			if(!Cflag)
				error(sprint("%q is schedule for merge/remove/add, refusing to update without -C", f.path));
		hg->STnormal =>
			if(!Cflag && f.size < 0)
				error(sprint("%q has been modified, refusing to update without -C", f.path));
		* =>
			raise "missing case";
		}
	}

	nds := ref Dirstate (1, nodeid, hg->nullnode, nil, nil);
	oi := ni := 0;
	for(;;) {
		if(oi < len ofiles)
			op := ofiles[oi].path;
		if(ni < len nfiles)
			np := nfiles[ni].path;
		if(op == nil && np == nil)
			break;

		say(sprint("checking %q and %q", op, np));
		if(op == np) {
			if(ofiles[oi].nodeid != nfiles[ni].nodeid || hg->differs(repo, nfiles[ni])) {
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

removedirs(mf: array of ref Mfile, p: string)
{
	(a, nil) := str->splitstrr(p, "/");
	if(a == nil || mfhasprefix(mf, a))
		return;
	a = a[:len a-1];
	sys->remove(a);
	removedirs(mf, a);
}

mfhasprefix(mf: array of ref Mfile, p: string): int
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
	rl := repo.xopenrevlog(path);
	buf := rl.xgetnodeid(nodeid);

	s := ".";
	for(l := sys->tokenize(path, "/").t1; len l > 1; l = tl l) {
		s += "/"+hd l;
		sys->create(s, Sys->OREAD, 8r777|Sys->DMDIR);
	}

	fd := sys->create(path, Sys->OWRITE|Sys->OTRUNC, 8r666);
	if(fd == nil)
		error(sprint("create %q: %r", path));
	if(sys->write(fd, buf, len buf) != len buf)
		error(sprint("write %q: %r", path));
}

dsadd(ds: ref Dirstate, path: string)
{
	(ok, dir) := sys->stat(path);
	if(ok < 0)
		error(sprint("stat %q: %r", path));
	dsf := ref Dsfile (hg->STnormal, dir.mode&8r777, int dir.length, dir.mtime, path, nil, 0);
	ds.add(dsf);
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
