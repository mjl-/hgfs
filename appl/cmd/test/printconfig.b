implement HgPrintconfig;

include "sys.m";
	sys: Sys;
	print, sprint: import sys;
include "draw.m";
include "arg.m";
include "bufio.m";
include "tables.m";
include "../../lib/bdiff.m";
include "mercurial.m";
	hg: Mercurial;
	Configs, Config, Section, Dirstate, Dsfile, Revlog, Repo, Change, Manifest, Mfile, Entry: import hg;
include "util0.m";
	util: Util0;
	warn, fail: import util;

HgPrintconfig: module {
	init:	fn(nil: ref Draw->Context, args: list of string);
};


dflag: int;
repo: ref Repo;
hgpath := "";

init(nil: ref Draw->Context, args: list of string)
{
	sys = load Sys Sys->PATH;
	arg := load Arg Arg->PATH;
	util = load Util0 Util0->PATH;
	util->init();
	hg = load Mercurial Mercurial->PATH;
	hg->init(0);

	arg->init(args);
	arg->setusage(arg->progname()+" [-d] [-h path]");
	while((c := arg->opt()) != 0)
		case c {
		'd' =>	hg->debug = dflag++;
		'h' =>	hgpath = arg->earg();
		* =>	arg->usage();
		}
	args = arg->argv();
	if(args != nil)
		arg->usage();

	{ init0(); }
	exception e {
	"hg:*" =>
		fail(e[3:]);
	}
}

init0()
{
	repo = Repo.xfind(hgpath);
	c := hg->xreadconfigs(repo);
	dumpconfigs(c);
}

dumpconfigs(c: ref Configs)
{
	print("configs:\n");
	for(l := c.l; l != nil; l = tl l) {
		print("config:\n");
		cc := hd l;
		for(ll := cc.l; ll != nil; ll = tl ll) {
			sec := hd ll;
			print("section %q\n", sec.name);
			for(p := sec.l; p != nil; p = tl p)
				print("%s = %q\n", (hd p).t0, (hd p).t1);
			print("\n");
		}
		print("\n");
	}
}
