implement Mkdelta;

include "sys.m";
	sys: Sys;
	sprint: import sys;
include "draw.m";
include "arg.m";
include "util0.m";
	util: Util0;
	fail, warn, readfile: import util;
include "../../lib/bdiff.m";
	bdiff: Bdiff;
	Delta: import bdiff;

Mkdelta: module {
	init:	fn(nil: ref Draw->Context, nil: list of string);
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
	arg->setusage(arg->progname()+" [-d] file1 file2");
	while((c := arg->opt()) != 0)
		case c {
		'd' =>	dflag++;
		* =>	arg->usage();
		}
	args = arg->argv();
	if(len args != 2)
		arg->usage();

	a := readfile(hd args, -1);
	b := readfile(hd tl args, -1);
	if(a == nil || b == nil)
		fail(sprint("%r"));
	d := bdiff->diff(a, b);
	buf := d.pack();
	if(sys->write(sys->fildes(1), buf, len buf) != len buf)
		fail(sprint("write: %r"));
}
