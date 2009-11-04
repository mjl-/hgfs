implement HgApplydelta;

include "sys.m";
	sys: Sys;
	sprint: import sys;
include "draw.m";
include "arg.m";
include "util0.m";
	util: Util0;
	rev, l2a, warn, fail, readfile: import util;
include "../../lib/bdiff.m";
	bdiff: Bdiff;
	Patch, Delta: import bdiff;

HgApplydelta: module {
	init:	fn(nil: ref Draw->Context, args: list of string);
};


dflag: int;

init(nil: ref Draw->Context, args: list of string)
{
	sys = load Sys Sys->PATH;
	arg := load Arg Arg->PATH;
	util = load Util0 Util0->PATH;
	util->init();
	bdiff = load Bdiff Bdiff->PATH;
	bdiff->init();

	arg->init(args);
	arg->setusage(arg->progname()+" [-d] base delta1 ...");
	while((c := arg->opt()) != 0)
		case c {
		'd' =>	dflag++;
		* =>	arg->usage();
		}
	args = arg->argv();
	if(len args < 2)
		arg->usage();
	base := readfile(hd args, -1);
	if(base == nil)
		fail(sprint("%r"));
	l: list of array of byte;
	for(args = tl args; args != nil; args = tl args) {
		l = readfile(hd args, -1)::l;
		if(hd l == nil)
			fail(sprint("%r"));
	}
	l = rev(l);

	(r, err) := Delta.applymany(base, l2a(l));
	if(err != nil)
		fail(err);
	if(sys->write(sys->fildes(1), r, len r) != len r)
		fail(sprint("write: %r"));
}
