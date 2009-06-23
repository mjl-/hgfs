implement HgLog;

include "sys.m";
	sys: Sys;
	sprint: import sys;
include "draw.m";
include "arg.m";
include "string.m";
	str: String;
include "mercurial.m";
	mercurial: Mercurial;
	Revlog, Repo, Nodeid, Change: import mercurial;

dflag: int;
vflag: int;

HgLog: module {
	init:	fn(nil: ref Draw->Context, args: list of string);
};

init(nil: ref Draw->Context, args: list of string)
{
	sys = load Sys Sys->PATH;
	arg := load Arg Arg->PATH;
	str = load String String->PATH;
	mercurial = load Mercurial Mercurial->PATH;
	mercurial->init();

	revision := -1;
	hgpath := "";
	showcount := -1;

	arg->init(args);
	arg->setusage(arg->progname()+" [-dv] [-r rev] [-n count] [-h path]");
	while((c := arg->opt()) != 0)
		case c {
		'd' =>	dflag++;
			if(dflag > 1)
				mercurial->debug++;
		'v' =>	vflag++;
		'r' =>	revision = int arg->earg();
		'h' =>	hgpath = arg->earg();
		'n' =>	showcount = int arg->earg();
		* =>	arg->usage();
		}
	args = arg->argv();
	if(len args != 0)
		arg->usage();

	(repo, rerr) := Repo.find(hgpath);
	if(rerr != nil)
		fail(rerr);
	say("found repo");

	if(revision == -1) {
		err: string;
		(revision, err) = repo.lastrev();
		if(err != nil)
			fail("look for last revision: "+err);
	}

	if(showcount == -1)
		showcount = revision+1;
	last := revision-showcount+1;
	first := 1;
	for(r := revision; r >= last; r--) {
		(change, cerr) := repo.change(r);
		if(cerr != nil)
			fail("reading change: "+cerr);

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
