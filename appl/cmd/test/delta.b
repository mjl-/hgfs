implement HgDelta;

include "sys.m";
	sys: Sys;
	sprint: import sys;
include "draw.m";
include "arg.m";
include "bufio.m";
include "string.m";
	str: String;
include "tables.m";
include "../../lib/bdiff.m";
include "mercurial.m";
	hg: Mercurial;
	Dirstate, Dsfile, Revlog, Repo, Change: import hg;

HgDelta: module {
	init:	fn(nil: ref Draw->Context, args: list of string);
};


dflag: int;
vflag: int;

init(nil: ref Draw->Context, args: list of string)
{
	sys = load Sys Sys->PATH;
	arg := load Arg Arg->PATH;
	str = load String String->PATH;
	hg = load Mercurial Mercurial->PATH;
	hg->init(0);

	hgpath := "";

	Tchangelog, Tmanifest, Tfile: con iota;
	which := Tfile;
	revlog: string;

	arg->init(args);
	arg->setusage(arg->progname()+" [-dv] [-h path] [-c | -m | revlog] rev");
	while((c := arg->opt()) != 0)
		case c {
		'd' =>	hg->debug = dflag++;
		'c' =>
			if(which != Tfile)
				arg->usage();
			which = Tchangelog;
		'm' =>
			if(which != Tfile)
				arg->usage();
			which = Tmanifest;
		'v' =>	vflag++;
		'h' =>	hgpath = arg->earg();
		* =>	arg->usage();
		}
	args = arg->argv();
	if(which == Tfile) {
		if(len args != 2)
			arg->usage();
		revlog = hd args;
		args = tl args;
	} else if(len args != 1)
		arg->usage();
	rev := int hd args;

	{
		repo := Repo.xfind(hgpath);

		rl: ref Revlog;
		case which {
		Tchangelog =>	rl = repo.xchangelog();
		Tmanifest =>	rl = repo.xmanifestlog();
		Tfile =>	rl = repo.xopenrevlog(revlog);
		}

		buf := rl.xdelta(-1, rev); # xxx make parent specifyable too?  default to base?

		if(sys->write(sys->fildes(1), buf, len buf) != len buf)
			fail(sprint("write: %r"));
	} exception x {
	"hg:*" =>
		fail(x[3:]);
	}
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
