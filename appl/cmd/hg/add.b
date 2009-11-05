implement HgAdd;

include "sys.m";
	sys: Sys;
	sprint: import sys;
include "draw.m";
include "arg.m";
include "bufio.m";
include "readdir.m";
	readdir: Readdir;
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
	rev, readfile, l2a, inssort, warn, fail: import util;

HgAdd: module {
	init:	fn(nil: ref Draw->Context, args: list of string);
};


dflag: int;
repo: ref Repo;
hgpath := "";

init(nil: ref Draw->Context, args: list of string)
{
	sys = load Sys Sys->PATH;
	arg := load Arg Arg->PATH;
	readdir = load Readdir Readdir->PATH;
	str = load String String->PATH;
	tables = load Tables Tables->PATH;
	util = load Util0 Util0->PATH;
	util->init();
	hg = load Mercurial Mercurial->PATH;
	hg->init(0);

	arg->init(args);
	arg->setusage(arg->progname()+" [-d] [-h path] [path ...]");
	while((c := arg->opt()) != 0)
		case c {
		'd' =>	hg->debug = dflag++;
		'h' =>	hgpath = arg->earg();
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
	untracked := 0;
	ds := hg->xdirstate(repo, untracked);
	base := repo.xworkdir();

	if(args == nil) {
		diradd(ds, ".");
	} else {
		for(l := args; l != nil; l = tl l) {
			p := repo.patheval(base, hd l);
			if(p == nil)
				error(sprint("%q is outside repository", hd l));
			(ok, dir) := sys->stat(repo.workroot()+"/"+p);
			if(ok != 0) {
				warn(sprint("%q: %r", p));
				continue;
			}
			add(ds, p, dir, 1);
		}
	}

	if(ds.dirty)
		repo.xwritedirstate(ds);
}

add(ds: ref Dirstate, path: string, dir: Sys->Dir, direct: int)
{
	if(path == ".hg" || str->prefix(".hg/", path))
		return;
	if(dir.mode & Sys->DMDIR)
		return diradd(ds, path);

	dsf := ds.find(path);
	if(dsf == nil) {
		dsf = ref Dsfile (hg->STadd, dir.mode&8r777, int dir.length, dir.mtime, path, nil, 0);
		ds.add(dsf);
		if(!direct)
			warn(sprint("%q", path));
		ds.dirty++;
	} else if(direct)
		warn(sprint("%q already tracked", path));
}

diradd(ds: ref Dirstate, path: string)
{
	(dirs, ok) := readdir->init(repo.workroot()+"/"+path, Readdir->NAME);
	if(ok < 0)
		return warn(sprint("reading %q: %r", path));
	for(i := 0; i < len dirs; i++)
		if(dirs[i].name != ".hg")
			add(ds, hg->xsanitize(path+"/"+dirs[i].name), *dirs[i], 0);
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
