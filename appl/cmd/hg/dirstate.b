implement HgDirstate;

include "sys.m";
	sys: Sys;
	sprint: import sys;
include "draw.m";
include "arg.m";
include "string.m";
	str: String;
include "mercurial.m";
	hg: Mercurial;
	Dirstatefile, Revlog, Repo, Nodeid, Change: import hg;

dflag: int;
vflag: int;

HgDirstate: module {
	init:	fn(nil: ref Draw->Context, args: list of string);
};

init(nil: ref Draw->Context, args: list of string)
{
	sys = load Sys Sys->PATH;
	arg := load Arg Arg->PATH;
	str = load String String->PATH;
	hg = load Mercurial Mercurial->PATH;
	hg->init();

	hgpath := "";

	arg->init(args);
	arg->setusage(arg->progname()+" [-dv] [-h path]");
	while((c := arg->opt()) != 0)
		case c {
		'd' =>	dflag++;
			if(dflag > 1)
				hg->debug++;
		'v' =>	vflag++;
		'h' =>	hgpath = arg->earg();
		* =>	arg->usage();
		}
	args = arg->argv();
	if(len args != 0)
		arg->usage();

	(repo, rerr) := Repo.find(hgpath);
	if(rerr != nil)
		fail(rerr);

	(ds, err) := repo.dirstate();
	if(err != nil)
		fail("dirstate: "+err);

	if(vflag) {
		sys->print("parents:");
		if(ds.p1 != nil)
			sys->print(" %s", ds.p1.text());
		if(ds.p2 != nil)
			sys->print(" %s", ds.p2.text());
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
