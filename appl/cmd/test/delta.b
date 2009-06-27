implement HgDelta;

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
	Dirstate, Dirstatefile, Revlog, Repo, Nodeid, Change: import hg;

dflag: int;
vflag: int;

HgDelta: module {
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

	Tchangelog, Tmanifest, Tfile: con iota;
	which := Tfile;
	revlog: string;

	arg->init(args);
	arg->setusage(arg->progname()+" [-dv] [-h path] [-c | -m | revlog] rev");
	while((c := arg->opt()) != 0)
		case c {
		'd' =>	dflag++;
			if(dflag > 1)
				hg->debug++;
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

	(repo, rerr) := Repo.find(hgpath);
	if(rerr != nil)
		fail(rerr);

	rl: ref Revlog;
	err: string;
	case which {
	Tchangelog =>
		(rl, err) = repo.changelog();
	Tmanifest =>
		(rl, err) = repo.manifestlog();
	Tfile =>
		(rl, err) = repo.openrevlog(revlog);
	}
	if(err != nil)
		fail("open revlog: "+err);

	buf: array of byte;
	(buf, err) = rl.delta(-1, rev); # xxx make parent specifyable too?  default to base?
	if(err != nil)
		fail("delta: "+err);

	if(sys->write(sys->fildes(1), buf, len buf) != len buf)
		fail(sprint("write: %r"));
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
