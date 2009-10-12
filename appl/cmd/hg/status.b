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
include "mercurial.m";
	hg: Mercurial;
	Dirstate, Dirstatefile, Revlog, Repo, Change: import hg;

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
	hg->init();

	arg->init(args);
	arg->setusage(arg->progname()+" [-d] [-h path]");
	while((c := arg->opt()) != 0)
		case c {
		'd' =>	hg->debug = dflag++;
		'h' =>	hgpath = arg->earg();
		* =>	arg->usage();
		}
	args = arg->argv();
	if(len args != 0)
		arg->usage();

	{ init0(); }
	exception e {
	"hg:*" =>
		fail(e[3:]);
	}
}

init0()
{
	repo := Repo.xfind(hgpath);
	root := repo.workroot();
	wds := hg->xworkdirstate(root);
	ds := repo.xdirstate();

	# first print status for all known files
	dsf := l2a(ds.l);
	inssort(dsf, statepathge);
	for(i := 0; i < len dsf; i++) {
		e := dsf[i];
		if(e.state != hg->STremove && e.state != hg->STuntracked && !exists(root+"/"+e.path)) {
			sys->print("! %q\n", e.path);
			continue;
		}
		case e.state {
		hg->STneedmerge =>	sys->print("M %q\n", e.path);
		hg->STremove =>	sys->print("R %q\n", e.path);
		hg->STadd =>	sys->print("A %q\n", e.path);
		hg->STnormal =>
			if(isdirty(root+"/"+e.path, e))
				sys->print("M %q\n", e.path);
		hg->STuntracked =>	sys->print("? %q\n", e.path);
		* =>	raise "missing case";
		}
	}

	# print all remaining paths as unknown
	wdsf := l2a(wds.l);
	inssort(wdsf, pathge);
	inssort(dsf, pathge);
	i = 0;
	wi := 0;
	while(wi < len wdsf) {
		while(i < len dsf && dsf[i].path < wdsf[wi].path)
			i++;

		if(i < len dsf && dsf[i].path == wdsf[wi].path) {
			i++;
			wi++;
			continue;
		}

		sys->print("? %q\n", wdsf[wi].path);
		wi++;
	}
}

isdirty(path: string, dsf: ref Dirstatefile): int
{
	(ok, dir) := sys->stat(path);
	if(ok != 0) {
		warn(sprint("stat %q: %r", path));
		return 1;
	}
	fx := (dsf.mode & 8r100) != 0;
	dx := (dir.mode & 8r100) != 0;
	if(fx != dx)
		return 1;
	if(int dir.length == dsf.size && dir.mtime == dsf.mtime)
		return 0;
	return 1;
}

exists(e: string): int
{
	(ok, dir) := sys->stat(e);
	return ok == 0 && (dir.mode&Sys->DMDIR) == 0;
}

statepathge(a, b: ref Dirstatefile): int
{
	if(a.state != b.state)
		return a.state >= b.state;
	return pathge(a, b);
}

pathge(a, b: ref Dirstatefile): int
{
	return a.path >= b.path;
}

say(s: string)
{
	if(dflag)
		warn(s);
}
