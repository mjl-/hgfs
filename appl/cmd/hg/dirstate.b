implement HgDirstate;

include "sys.m";
	sys: Sys;
	sprint: import sys;
include "draw.m";
include "arg.m";
include "bufio.m";
include "string.m";
	str: String;
include "mercurial.m";
	hg: Mercurial;
	Dirstatefile, Revlog, Repo, Change: import hg;

HgDirstate: module {
	init:	fn(nil: ref Draw->Context, args: list of string);
};


dflag: int;
vflag: int;
hgpath := "";

init(nil: ref Draw->Context, args: list of string)
{
	sys = load Sys Sys->PATH;
	arg := load Arg Arg->PATH;
	str = load String String->PATH;
	hg = load Mercurial Mercurial->PATH;
	hg->init();


	arg->init(args);
	arg->setusage(arg->progname()+" [-dv] [-h path]");
	while((c := arg->opt()) != 0)
		case c {
		'd' =>	hg->debug = dflag++;
		'v' =>	vflag++;
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
	ds := repo.xdirstate();

	if(vflag) {
		sys->print("parents:");
		if(ds.p1 != nil)
			sys->print(" %s", ds.p1);
		if(ds.p2 != nil)
			sys->print(" %s", ds.p2);
		sys->print("\n");
	}

	for(l := ds.l; l != nil; l = tl l)
		sys->print("%s\n", (hd l).text());
}

fail(s: string)
{
	sys->fprint(sys->fildes(2), "%s\n", s);
	raise "fail:"+s;
}
