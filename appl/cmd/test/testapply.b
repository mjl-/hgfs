implement HgTestapply;

include "sys.m";
	sys: Sys;
	sprint: import sys;
include "draw.m";
include "arg.m";
include "bufio.m";
include "string.m";
	str: String;
include "lists.m";
	lists: Lists;
include "mercurial.m";
	hg: Mercurial;
	Dirstate, Dirstatefile, Revlog, Repo, Nodeid, Change, Patch, Hunk: import hg;

dflag: int;

HgTestapply: module {
	init:	fn(nil: ref Draw->Context, args: list of string);
};

init(nil: ref Draw->Context, args: list of string)
{
	sys = load Sys Sys->PATH;
	arg := load Arg Arg->PATH;
	str = load String String->PATH;
	lists = load Lists Lists->PATH;
	hg = load Mercurial Mercurial->PATH;
	hg->init();

	arg->init(args);
	arg->setusage(arg->progname()+" [-d] base patch1 ...");
	while((c := arg->opt()) != 0)
		case c {
		'd' =>	dflag++;
			if(dflag > 1)
				hg->debug++;
		* =>	arg->usage();
		}
	args = arg->argv();
	if(len args < 2)
		arg->usage();
	base := readfile(hd args);
	l: list of array of byte;
	for(args = tl args; args != nil; args = tl args)
		l = readfile(hd args)::l;
	l = lists->reverse(l);
	(r, err) := Patch.applymany(base, l2a(l));
	if(err != nil)
		fail(sprint("applymany: %r"));
	if(sys->write(sys->fildes(1), r, len r) != len r)
		fail(sprint("write: %r"));
}

readfile(f: string): array of byte
{
	fd := sys->open(f, Sys->OREAD);
	if(fd == nil)
		fail(sprint("open %q: %r", f));
	buf := array[0] of byte;
	d := array[32*1024] of byte;
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

l2a(l: list of array of byte): array of array of byte
{
	a := array[len l] of array of byte;
	i := 0;
	for(; l != nil; l = tl l)
		a[i++] = hd l;
	return a;
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
