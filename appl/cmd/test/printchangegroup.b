implement HgPrintchangegroup;

include "sys.m";
	sys: Sys;
	sprint: import sys;
include "draw.m";
include "arg.m";
include "bufio.m";
	bufio: Bufio;
	Iobuf: import bufio;
include "string.m";
	str: String;
include "encoding.m";
	base16: Encoding;
include "tables.m";
include "../../lib/bdiff.m";
	bdiff: Bdiff;
	Delta, Patch: import bdiff;
include "mercurial.m";
	hg: Mercurial;
	Dirstate, Dsfile, Revlog, Repo, Change: import hg;

HgPrintchangegroup: module {
	init:	fn(nil: ref Draw->Context, args: list of string);
};


dflag: int;
vflag: int;
b: ref Iobuf;

Chunk: adt {
	n, p1, p2, link:	string;
	d:	ref Delta;
};

init(nil: ref Draw->Context, args: list of string)
{
	sys = load Sys Sys->PATH;
	arg := load Arg Arg->PATH;
	str = load String String->PATH;
	bufio = load Bufio Bufio->PATH;
	base16 = load Encoding Encoding->BASE16PATH;
	bdiff = load Bdiff Bdiff->PATH;
	bdiff->init();
	hg = load Mercurial Mercurial->PATH;
	hg->init(0);

	arg->init(args);
	arg->setusage(arg->progname()+" [-dv]");
	while((c := arg->opt()) != 0)
		case c {
		'd' =>	dflag++;
			if(dflag > 1)
				hg->debug = dflag-1;
		'v' =>	vflag++;
		* =>	arg->usage();
		}
	args = arg->argv();
	if(args != nil)
		arg->usage();

	b = bufio->fopen(sys->fildes(0), Bufio->OREAD);

	sys->print("changelog group:\n");
	chunks();

	sys->print("manifest group:\n");
	chunks();

	for(;;) {
		n := g32(read(4));
		if(n == 0)
			break;
		f := string read(n-4);
		sys->print("file %q:\n", f);
		chunks();
	}
}

chunks()
{
	for(;;) {
		c := readchunk();
		if(c == nil)
			break;
		printchunk(c);
	}
}

printchunk(c: ref Chunk)
{
	sys->print("\tnode:  %q\n", c.n);
	sys->print("\tp1:    %q\n", c.p1);
	sys->print("\tp2:    %q\n", c.p2);
	sys->print("\tlink:  %q\n", c.link);
	if(vflag) {
		sys->print("\tpatches:\n");
		for(l := c.d.l; l != nil; l = tl l) {
			p := hd l;
			sys->print("\t\t%s\n", p.text());
			sys->print("\t\t%s\n", string p.d);
		}
	} else {
		sys->print("\tpatches: %d\n", len c.d.l);
	}
	sys->print("\n");
}

read(n: int): array of byte
{
	buf := array[n] of byte;
	o := 0;
	while(o < n) {
		nn := b.read(buf[o:], n-o);
		if(nn < 0)
			fail(sprint("read: %r"));
		if(nn == 0)
			fail(sprint("short read, wanted %d, got %d", n, o));
		o += nn;
	}
	return buf;
}

readlength(): int
{
	return g32(read(4));
}

readchunk(): ref Chunk
{
	n := readlength();
	if(n == 0)
		return nil;
	buf := read(n-4);
	if(len buf < 4*20)
		fail(sprint("short chunk, len buf %d < 4*20, buf %s or %s", len buf, base16->enc(buf), string buf));
	c := ref Chunk;
	{
		o := 0;
		c.n = hg->hex(buf[o:o+20]);
		o += 20;
		c.p1 = hg->hex(buf[o:o+20]);
		o += 20;
		c.p2 = hg->hex(buf[o:o+20]);
		o += 20;
		c.link = hg->hex(buf[o:o+20]);
		o += 20;
		(d, err) := Delta.parse(buf[o:]);
		if(err != nil)
			fail("parsing patch: "+err);
		c.d = d;
	} exception x {
	"hg:*" =>
		fail("parsing patch: "+x[3:]);
	}
	return c;
}

g32(p: array of byte): int
{
	v := 0;
	v |= int p[0]<<24;
	v |= int p[1]<<16;
	v |= int p[2]<<8;
	v |= int p[3]<<0;
	return v;
}

warn(s: string)
{
	sys->fprint(sys->fildes(2), "%s\n", s);
}

say(s: string)
{
	if(dflag)
		warn(s);
}

fail(s: string)
{
	warn(s);
	raise "fail:"+s;
}
