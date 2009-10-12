implement HgPrintpatch;

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
	Dirstate, Dirstatefile, Revlog, Repo, Change, Patch, Hunk: import hg;

HgPrintpatch: module {
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

	arg->init(args);
	arg->setusage(arg->progname()+" [-d]");
	while((c := arg->opt()) != 0)
		case c {
		'd' =>	hg->debug = dflag++;
		* =>	arg->usage();
		}
	args = arg->argv();
	if(args != nil)
		arg->usage();

	buf := get();
	(p, err) := Patch.parse(buf);
	if(err != nil)
		fail("parse patch: "+err);
	for(l := p.l; l != nil; l = tl l) {
		h := hd l;
		sys->print("start=%d end=%d buf:\n%s\n", h.start, h.end, string h.buf);
	}
}

get(): array of byte
{
	d := array[32*1024] of byte;
	buf := array[0] of byte;
	fd := sys->fildes(0);
	for(;;) {
		n := sys->read(fd, d, len d);
		if(n < 0)
			fail(sprint("read: %r"));
		if(n == 0)
			break;
		nbuf := array[len buf+n] of byte;
		nbuf[:] = buf;
		nbuf[len buf:] = d[:n];
		buf = nbuf;
	}
	return buf;
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
