implement HgHeads;

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

HgHeads: module {
	init:	fn(nil: ref Draw->Context, args: list of string);
};


dflag: int;

init(nil: ref Draw->Context, args: list of string)
{
	sys = load Sys Sys->PATH;
	arg := load Arg Arg->PATH;
	str = load String String->PATH;
	hg = load Mercurial Mercurial->PATH;
	hg->init();

	hgpath := "";

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

	(r, err) := Repo.find(hgpath);
	if(err != nil)
		fail(err);

	entries: array of ref Entry;
	(entries, err) = r.heads();
	if(err != nil)
		fail(err);

	for(i := 0; i < len entries; i++) {
		e := entries[i];
		sys->print("%q, rev %d", e.nodeid, e.rev);
		if(e.p1 >= 0) {
			if(e.p2 >= 0)
				sys->print(", parents %d %d\n", e.p1, e.p2);
			else
				sys->print(", parent %d\n", e.p1);
		}
	}
}

fail(s: string)
{
	sys->fprint(sys->fildes(2), "%s\n", s);
	raise "fail:"+s;
}
