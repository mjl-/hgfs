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
include "../../lib/bdiff.m";
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
reporoot: string;
repobase: string;

init(nil: ref Draw->Context, args: list of string)
{
	sys = load Sys Sys->PATH;
	arg := load Arg Arg->PATH;
	str = load String String->PATH;
	tables = load Tables Tables->PATH;
	util = load Util0 Util0->PATH;
	util->init();
	hg = load Mercurial Mercurial->PATH;
	hg->init(0);

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
	revstr: string;
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
	reporoot = repo.workroot();
	repobase = repo.xworkdir();
	untracked := 0;
	ds := hg->xdirstate(repo, untracked);
	if(revstr == nil)
		revstr = repo.xworkbranch();
	if(ds.p1 != hg->nullnode && ds.p2 != hg->nullnode && !Cflag)
		error("in merge, refusing to update without -C");

	onodeid := ds.p1;

	(nrev, nnodeid) := repo.xlookup(revstr, 1);
	say(sprint("new rev %d nodeid %q, revstr %q", nrev, nnodeid, revstr));

	(oc, om) := repo.xrevisionn(onodeid);
	(nil, obranch) := oc.findextra("branch");
	(nc, nm) := repo.xrevisionn(nnodeid);
	(nil, nbranch) := nc.findextra("branch");

	wbranch := repo.xworkbranch();
	if(obranch == nil) obranch = "default";
	if(nbranch == nil) nbranch = "default";
	say(sprint("obranch %q, nbranch %q, wbranch %q", obranch, nbranch, wbranch));

	ofiles := om.files;
	nfiles := nm.files;
	say(sprint("len ofiles %d, len nfiles %d", len ofiles, len nfiles));

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

	nupdated := nmerged := nremoved := nunresolved := 0;
	nds := ref Dirstate (1, nnodeid, hg->nullnode, nil, nil);
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
				nupdated++;
			}
			dsadd(nds, np);
			oi++;
			ni++;
		} else if(op != nil && op < np || np == nil) {
			f := reporoot+"/"+op;
			say(sprint("removing %q", f));
			sys->remove(f);
			removedirs(nfiles, op);
			nremoved++;
			oi++;
		} else if(np < op || op == nil) {
			say(sprint("creating %q", np));
			ewritefile(np, nfiles[ni].nodeid);
			dsadd(nds, np);
			ni++;
			nupdated++;
		}
	}

	nds.l = util->rev(nds.l);
	repo.xwritedirstate(nds);
	if(obranch != nbranch || nbranch != wbranch)
		repo.xwriteworkbranch(nbranch);

	warn(sprint("files: %d updated, %d merged, %d removed, %d unresolved", nupdated, nmerged, nremoved, nunresolved));
}

removedirs(mf: array of ref Mfile, p: string)
{
	(a, nil) := str->splitstrr(p, "/");
	if(a == nil || mfhasprefix(mf, a))
		return;
	a = a[:len a-1];
	f := reporoot+"/"+a;
	sys->remove(f);
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
	buf := rl.xgetn(nodeid);

	hg->ensuredirs(reporoot, path);
	f := reporoot+"/"+path;
	fd := sys->create(f, Sys->OWRITE|Sys->OTRUNC, 8r666);
	if(fd == nil)
		error(sprint("create %q: %r", f));
	if(sys->write(fd, buf, len buf) != len buf)
		error(sprint("write %q: %r", f));
}

dsadd(ds: ref Dirstate, path: string)
{
	f := reporoot+"/"+path;
	(ok, dir) := sys->stat(f);
	if(ok < 0)
		error(sprint("stat %q: %r", f));
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
