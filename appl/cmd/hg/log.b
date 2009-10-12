implement HgLog;

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
	Revlog, Repo, Change: import hg;

HgLog: module {
	init:	fn(nil: ref Draw->Context, args: list of string);
};


dflag: int;
vflag: int;
revision := -1;
hgpath := "";
showcount := -1;

init(nil: ref Draw->Context, args: list of string)
{
	sys = load Sys Sys->PATH;
	arg := load Arg Arg->PATH;
	str = load String String->PATH;
	hg = load Mercurial Mercurial->PATH;
	hg->init();

	arg->init(args);
	arg->setusage(arg->progname()+" [-dv] [-r rev] [-n count] [-h path]");
	while((c := arg->opt()) != 0)
		case c {
		'd' =>	hg->debug = dflag++;
		'v' =>	vflag++;
		'r' =>	revision = int arg->earg();
		'h' =>	hgpath = arg->earg();
		'n' =>	showcount = int arg->earg();
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
	say("found repo");

	if(revision == -1)
		revision = repo.xlastrev();

	if(showcount == -1)
		showcount = revision+1;
	last := revision-showcount+1;
	first := 1;
	for(r := revision; r >= last; r--) {
		change := repo.xchange(r);

		if(first)
			first = 0;
		else
			sys->print("\n");

		sys->print("## revision %d\n", r);
		sys->print("%s\n", change.text());
	}
}

say(s: string)
{
	if(dflag)
		warn(s);
}

warn(s: string)
{
	sys->fprint(sys->fildes(2), "%s\n", s);
}

fail(s: string)
{
	warn(s);
	raise "fail:"+s;
}
