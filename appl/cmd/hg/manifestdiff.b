implement HgManifestdiff;

include "sys.m";
	sys: Sys;
	print, sprint: import sys;
include "draw.m";
include "arg.m";
include "bufio.m";
	bufio: Bufio;
	Iobuf: import bufio;
include "string.m";
	str: String;
include "util0.m";
	util: Util0;
	rev, readfile, l2a, inssort, warn, fail: import util;

HgManifestdiff: module {
	init:	fn(nil: ref Draw->Context, args: list of string);
};


dflag: int;

init(nil: ref Draw->Context, args: list of string)
{
	sys = load Sys Sys->PATH;
	arg := load Arg Arg->PATH;
	bufio = load Bufio Bufio->PATH;
	str = load String String->PATH;
	util = load Util0 Util0->PATH;
	util->init();

	arg->init(args);
	arg->setusage(arg->progname()+" [-d] manifest0 manifest1");
	while((c := arg->opt()) != 0)
		case c {
		'd' =>	dflag++;
		* =>	arg->usage();
		}
	args = arg->argv();
	if(len args != 2)
		arg->usage();

	{ init0(args); }
	exception e {
	"hg:*" =>
		fail(e[3:]);
	}
}

init0(args: list of string)
{
	f0 := hd args;
	f1 := hd tl args;

	b0 := bufio->open(f0, Bufio->OREAD);
	if(b0 == nil)
		error(sprint("open %q: %r", f0));
	b1 := bufio->open(f1, Bufio->OREAD);
	if(b1 == nil)
		error(sprint("open %q: %r", f1));

	p0, p1, n0, n1: string;
	(n0, p0) = get(b0);
	(n1, p1) = get(b1);
	for(;;)
		if(p0 == p1) {
			if(p0 == nil)
				break;
			if(n0 != n1)
				print("M %q\n", p0);
			(n0, p0) = get(b0);
			(n1, p1) = get(b1);
		} else if(p0 != nil && p0 < p1) {
			print("R %q\n", p0);
			(n0, p0) = get(b0);
		} else {
			print("A %q\n", p1);
			(n1, p1) = get(b1);
		}
}

get(b: ref Iobuf): (string, string)
{
	s := b.gets('\n');
	if(s == nil)
		return (nil, nil);
	if(s[len s-1] != '\n')
		error("line without newline");
	s = s[:len s-1];
	(n, p) := str->splitstrl(s, " ");
	if(p == nil)
		error(sprint("bad line: %q", s));
	return (n, p[1:]);
}

error(s: string)
{
	raise "hg:"+s;
}

say(s: string)
{
	if(dflag)
		warn(s);
}
