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
include "mercurial.m";
	hg: Mercurial;
	Dirstate, Dirstatefile, Revlog, Repo, Change, Manifest, Manifestfile, Entry: import hg;
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
	hg->init();

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

dirty: int;
init0(args: list of string)
{
	repo = Repo.xfind(hgpath);

	ds := repo.xdirstate();
	if(ds.p2 != hg->nullnode)
		error("checkout has two parents, is in merge, refusing to update");
	# xxx makes ure dirstate is complete & correct

	root := repo.workroot();

	dirty = 0;
	if(args == nil) {
		add(ds, root, ".", 0);
	} else {
		base := repo.xworkdir();
		say(sprint("base %q", base));
		for(l := args; l != nil; l = tl l)
			add(ds, root, hg->xsanitize(base+"/"+hd l), 1);
	}

	if(dirty)
		repo.xwritedirstate(ds);
}

add(ds: ref Dirstate, root, path: string, direct: int)
{
	(ok, dir) := sys->stat(root+"/"+path);
	if(ok != 0)
		return warn(sprint("%q: %r", path));
	add0(ds, root, path, dir, direct);
}

add0(ds: ref Dirstate, root, path: string, dir: Sys->Dir, direct: int)
{
	if(path == ".hg" || str->prefix(".hg/", path))
		return;
	if(dir.mode & Sys->DMDIR)
		return diradd(ds, root, path);

	dsf := ds.find(path);
	if(dsf == nil || dsf.state == hg->STuntracked) {
		ndsf := ref Dirstatefile (hg->STadd, dir.mode&8r500, int dir.length, dir.mtime, path, nil);
		ds.add(ndsf);
		if(!direct)
			warn(sprint("%q", path));
		dirty++;
	} else if(direct)
		warn(sprint("%q already tracked", path));
}

diradd(ds: ref Dirstate, root, path: string)
{
	(dirs, ok) := readdir->init(root+"/"+path, Readdir->NAME);
	if(ok < 0)
		return warn(sprint("reading %q: %r", path));
	for(i := 0; i < len dirs; i++)
		if(dirs[i].name != ".hg")
			add0(ds, root, hg->xsanitize(path+"/"+dirs[i].name), *dirs[i], 0);
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
