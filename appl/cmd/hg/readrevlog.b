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
		'd' =>	dflag++;
			if(dflag > 1)
				hg->debug++;
		* =>	arg->usage();
		}
	args = arg->argv();
	if(len args != 1)
		arg->usage();
	path := hd args;

	(rl, err) := Revlog.open(path, 0);
	if(err != nil)
		fail(err);

	last: int;
	(last, err) = rl.lastrev();
	if(err != nil)
		fail(err);

	e: ref Entry;
	for(i := 0; i <= last; i++) {
		(e, err) = rl.find(i);
		if(err != nil)
			fail(err);
		#sys->print("entry %d:\n", i);
		sys->print("%s\n", e.text());
	}
}

fail(s: string)
{
	sys->fprint(sys->fildes(2), "%s\n", s);
	raise "fail:"+s;
}
