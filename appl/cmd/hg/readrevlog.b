implement HgReadrevlog;

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
	Revlog, Repo, Entry, Change: import hg;

dflag: int;

HgReadrevlog: module {
	init:	fn(nil: ref Draw->Context, args: list of string);
};

init(nil: ref Draw->Context, args: list of string)
{
	sys = load Sys Sys->PATH;
	arg := load Arg Arg->PATH;
	str = load String String->PATH;
	hg = load Mercurial Mercurial->PATH;
	hg->init();

	arg->init(args);
	arg->setusage(arg->progname()+" [-d] path");
	while((c := arg->opt()) != 0)
		case c {
		'd' =>	hg->debug = dflag++;
		* =>	arg->usage();
		}
	args = arg->argv();
	if(len args != 1)
		arg->usage();
	path := hd args;

	{ init0(path); }
	exception e {
	"hg:*" =>
		fail(e[3:]);
	}
}

init0(path: string)
{
	rl := Revlog.xopen(path, 0);
	last := rl.xlastrev();

	for(i := 0; i <= last; i++)
		sys->print("%s\n", rl.xfind(i).text());
}

fail(s: string)
{
	sys->fprint(sys->fildes(2), "%s\n", s);
	raise "fail:"+s;
}
