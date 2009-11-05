implement HgRevert;

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

HgRevert: module {
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
	root := repo.workroot();
	base := repo.xworkdir();

	l := ds.all();
	if(args != nil) {
		erroutside := 0;
		paths := hg->xpathseval(root, base, args, erroutside);
		(nil, l) = ds.enumerate(paths, untracked, 1);
	}
	for(; l != nil; l = tl l) {
		dsf := hd l;
		path := dsf.path;

		buf := repo.xread(path, ds);
		hg->ensuredirs(root, path);
		f := root+"/"+path;
		fd := sys->create(f, Sys->OWRITE|Sys->OTRUNC, 8r666);
		if(fd == nil) {
			warn(sprint("create %q: %r", f));
			continue;
		}
		if(sys->write(fd, buf, len buf) != len buf) {
			warn(sprint("write %q: %r", f));
			continue;
		}
		(ok, dir) := sys->fstat(fd);
		if(ok != 0) {
			warn(sprint("stat %q: %r", f));
			continue;
		}
		dsf.state = hg->STnormal;
		dsf.size = int dir.length;
		dsf.mtime = dir.mtime;
		ds.dirty++;
	}

	if(ds.dirty)
		repo.xwritedirstate(ds);
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
