implement HgPrintdelta;

include "sys.m";
	sys: Sys;
	sprint: import sys;
include "draw.m";
include "arg.m";
include "util0.m";
	util: Util0;
	warn, fail, readfd: import util;
include "../../lib/bdiff.m";
	bdiff: Bdiff;
	Delta, Patch: import bdiff;

HgPrintdelta: module {
	init:	fn(nil: ref Draw->Context, args: list of string);
};


dflag,
vflag: int;

init(nil: ref Draw->Context, args: list of string)
{
	sys = load Sys Sys->PATH;
	arg := load Arg Arg->PATH;
	util = load Util0 Util0->PATH;
	util->init();
	bdiff = load Bdiff Bdiff->PATH;
	bdiff->init();

	arg->init(args);
	arg->setusage(arg->progname()+" [-dv]");
	while((c := arg->opt()) != 0)
		case c {
		'd' =>	dflag++;
		'v' =>	vflag++;
		* =>	arg->usage();
		}
	args = arg->argv();
	if(args != nil)
		arg->usage();

	buf := readfd(sys->fildes(0), -1);
	if(buf == nil)
		fail(sprint("%r"));
	(d, err) := Delta.parse(buf);
	if(err != nil)
		fail("parsing delta: "+err);
	for(l := d.l; l != nil; l = tl l) {
		p := hd l;
		sys->print("%s\n", p.text());
		if(vflag)
			sys->print("%s\n", string p.d);
	}
}
