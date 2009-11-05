implement HgHeads;

include "sys.m";
	sys: Sys;
	sprint: import sys;
include "draw.m";
include "arg.m";
include "bufio.m";
include "daytime.m";
	daytime: Daytime;
include "string.m";
	str: String;
include "tables.m";
include "../../lib/bdiff.m";
include "mercurial.m";
	hg: Mercurial;
	Revlog, Repo, Entry, Change: import hg;

HgHeads: module {
	init:	fn(nil: ref Draw->Context, args: list of string);
};


dflag: int;
vflag: int;
hgpath := "";

init(nil: ref Draw->Context, args: list of string)
{
	sys = load Sys Sys->PATH;
	arg := load Arg Arg->PATH;
	daytime = load Daytime Daytime->PATH;
	str = load String String->PATH;
	hg = load Mercurial Mercurial->PATH;
	hg->init(0);

	arg->init(args);
	arg->setusage(arg->progname()+" [-d] [-h path] [-v]");
	while((c := arg->opt()) != 0)
		case c {
		'd' =>	hg->debug = dflag++;
		'h' =>	hgpath = arg->earg();
		'v' =>	vflag++;
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
	for(l := repo.xheads(); l != nil; l = tl l)
		sys->print("%s\n", hg->xentrylogtext(repo, hd l, vflag));
}

fail(s: string)
{
	sys->fprint(sys->fildes(2), "%s\n", s);
	raise "fail:"+s;
}
