implement HgInit;

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
	Dirstate, Dirstatefile, Revlog, Repo, Change, Manifest, Manifestfile, Entry: import hg;
include "util0.m";
	util: Util0;
	readfile, l2a, inssort, warn, fail: import util;

HgInit: module {
	init:	fn(nil: ref Draw->Context, args: list of string);
};


dflag: int;
Cflag: int;
repo: ref Repo;
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
	arg->setusage(arg->progname()+" [-d]");
	while((c := arg->opt()) != 0)
		case c {
		'd' =>	hg->debug = dflag++;
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
	fd := sys->create(".hg", Sys->OREAD, 8r777|Sys->DMDIR);
	if(fd == nil)
		error(sprint("creating .hg/: %r"));
	fd = sys->create(".hg/store", Sys->OREAD, 8r777|Sys->DMDIR);
	if(fd == nil)
		error(sprint("creating .hg/store/: %r"));

	fd = sys->create(".hg/requires", Sys->OWRITE|Sys->OTRUNC, 8r666);
	if(fd == nil)
		error(sprint("creating .hg/requires"));
	buf := array of byte "revlogv1\nstore\nfncache\n";
	if(sys->write(fd, buf, len buf) != len buf)
		error(sprint("write .hg/requires: %r"));
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
