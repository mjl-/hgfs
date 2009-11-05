implement HgStatus;

include "sys.m";
	sys: Sys;
	sprint: import sys;
include "draw.m";
include "arg.m";
include "bufio.m";
include "string.m";
	str: String;
include "util0.m";
	util: Util0;
	fail, warn, l2a, inssort: import util;
include "tables.m";
include "../../lib/bdiff.m";
include "mercurial.m";
	hg: Mercurial;
	Dirstate, Dsfile, Revlog, Repo, Change: import hg;

HgStatus: module {
	init:	fn(nil: ref Draw->Context, args: list of string);
};


dflag: int;
hgpath := "";

init(nil: ref Draw->Context, args: list of string)
{
	sys = load Sys Sys->PATH;
	arg := load Arg Arg->PATH;
	str = load String String->PATH;
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
	repo := Repo.xfind(hgpath);
	untracked := 1;
	ds := hg->xdirstate(repo, untracked);
	root := repo.workroot();
	base := repo.xworkdir();

	l := ds.all();
	if(args != nil) {
		erroutside := 0;
		paths := hg->xpathseval(root, base, args, erroutside);
		(nil, l) = ds.enumerate(paths, untracked, 1);
	}
	a := l2a(l);
	inssort(a, statepathge);
	for(i := 0; i < len a; i++) {
		f := a[i];
say("dsf "+f.text());
		path := f.path;
		if(args != nil)
			path = hg->relpath(base, path);
		if(f.missing) {
			sys->print("! %q\n", path);
			continue;
		}
		case f.state {
		hg->STneedmerge =>
			sys->print("M %q\n", path);
		hg->STremove =>
			sys->print("R %q\n", path);
		hg->STadd =>
			sys->print("A %q\n", path);
		hg->STnormal =>
			if(f.size < 0)
				sys->print("M %q\n", path);
		hg->STuntracked =>
			sys->print("? %q\n", path);
		* =>
			raise "missing case";
		}
	}

	if(ds.dirty)
		repo.xwritedirstate(ds);
}

statepathge(a, b: ref Dsfile): int
{
	if(a.state != b.state)
		return a.state >= b.state;
	return pathge(a, b);
}

pathge(a, b: ref Dsfile): int
{
	return a.path >= b.path;
}

say(s: string)
{
	if(dflag)
		warn(s);
}
