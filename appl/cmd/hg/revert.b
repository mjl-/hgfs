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
include "mercurial.m";
	hg: Mercurial;
	Dirstate, Dirstatefile, Revlog, Repo, Change, Manifest, Manifestfile, Entry: import hg;
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
	hg->init();

	arg->init(args);
	arg->setusage(arg->progname()+" [-d] [-h path] path ...");
	while((c := arg->opt()) != 0)
		case c {
		'd' =>	hg->debug = dflag++;
		'h' =>	hgpath = arg->earg();
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

init0(args: list of string)
{
	repo = Repo.xfind(hgpath);

	ds := repo.xdirstate();
	if(ds.p2 != hg->nullnode)
		error("checkout has two parents, is in merge, refusing to update");
	# xxx make sure dirstate is complete & correct

	root := repo.workroot();

	dirty := 0;
	base := repo.xworkdir();
	say(sprint("base %q", base));
	for(l := args; l != nil; l = tl l) {
		path := hg->xsanitize(base+"/"+hd l);
		dsf := ds.find(path);
		if(dsf == nil) {
			warn(sprint("%q: file not tracked", dsf.path));
			continue;
		}
		buf := repo.xget(ds.p1, path);
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

		dsf.state = hg->STnormal;
		dirty++;
	}

	if(dirty)
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
