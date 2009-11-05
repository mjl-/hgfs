implement HgRemove;

include "sys.m";
	sys: Sys;
	sprint: import sys;
include "draw.m";
include "arg.m";
include "bufio.m";
include "daytime.m";
	daytime: Daytime;
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

HgRemove: module {
	init:	fn(nil: ref Draw->Context, args: list of string);
};


dflag: int;
fflag: int;
repo: ref Repo;
hgpath := "";

init(nil: ref Draw->Context, args: list of string)
{
	sys = load Sys Sys->PATH;
	arg := load Arg Arg->PATH;
	daytime = load Daytime Daytime->PATH;
	readdir = load Readdir Readdir->PATH;
	str = load String String->PATH;
	tables = load Tables Tables->PATH;
	util = load Util0 Util0->PATH;
	util->init();
	hg = load Mercurial Mercurial->PATH;
	hg->init(0);

	arg->init(args);
	arg->setusage(arg->progname()+" [-d] [-h path] [-f] path ...");
	while((c := arg->opt()) != 0)
		case c {
		'd' =>	hg->debug = dflag++;
		'h' =>	hgpath = arg->earg();
		'f' =>	fflag++;
		* =>	arg->usage();
		}
	args = arg->argv();
	if(args == nil)
		arg->usage();

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
	untracked := 0;
	ds := hg->xdirstate(repo, untracked);
	root := repo.workroot();
	base := repo.xworkdir();

	now := daytime->now();
	erroutside := 0;
	paths := hg->xpathseval(root, base, args, erroutside);
	(nil, l) := ds.enumerate(paths, untracked, 1);
	for(; l != nil; l = tl l) {
		f := hd l;
		p := f.path;

		case f.state {
		hg->STremove =>
			;
		hg->STnormal =>
			if(f.size < 0 && !fflag) {
				warn(sprint("%q: modified, refusing to remove without -f", p));
				continue;
			}
			f.state = hg->STremove;
			f.size = hg->SZdirty;
			f.mtime = now;
			ds.dirty++;
			if(sys->remove(root+"/"+p) != 0)
				warn(sprint("removing %q: %r", p));
		hg->STadd =>
			if(fflag) {
				ds.del(f.path);
				ds.dirty++;
			} else
				warn(sprint("%q: file marked for add, refusing to remove without -f", p));
		hg->STneedmerge =>
			if(fflag) {
				f.state = hg->STremove;
				f.size = hg->SZdirty;
				f.mtime = now;
				ds.dirty++;
			} else
				warn(sprint("%q: file marked for merge, refusing to remove without -f", p));
		* =>
			error(sprint("missing case for dirstate file state %d", f.state));
		}
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
