implement Readindex;

include "sys.m";
	sys: Sys;
include "draw.m";
include "arg.m";
include "bufio.m";
	bufio: Bufio;
	Iobuf: import bufio;
include "filter.m";
	inflate: Filter;


print, sprint, fprint, fildes: import sys;

dflag: int;

Indexsize:	con 64;

Readindex: module {
	init:	fn(nil: ref Draw->Context, args: list of string);
};

init(nil: ref Draw->Context, args: list of string)
{
	sys = load Sys Sys->PATH;
	arg := load Arg Arg->PATH;
	bufio = load Bufio Bufio->PATH;
	inflate = load Filter "inflate.dis";
	inflate = load Filter Filter->INFLATEPATH;
	inflate->init();

	arg->init(args);
	arg->setusage(arg->progname()+" [-d] file");
	while((c := arg->opt()) != 0)
		case c {
		'd' =>	dflag++;
		* =>	arg->usage();
		}
	args = arg->argv();
	if(len args != 1)
		arg->usage();

	file := hd args;
	b := bufio->open(file, Bufio->OREAD);
	o := big 0;
	for(i := 0;; i++) {
		say(sprint("reading from offset %bd", o));
		buf := array[Indexsize] of byte;
		b.seek(o, Bufio->SEEKSTART);
		n := b.read(buf, len buf);
		if(n == 0)
			break;
		if(n < 0)
			fail(sprint("reading index: %r"));
		if(i == 0)
			buf[0:] = array[4] of {* => byte 0};  # xxx revlog version & flags
		(ix, err) := Index.parse(buf);
		if(err != nil)
			fail("parsing index entry: "+err);

		print("index: %s\n", ix.text());
		o += big Indexsize;

		if(1) {
		
		say(sprint("reading from offset %bd", o));
		b.seek(o, Bufio->SEEKSTART);
		defl := array[ix.csize] of byte;
		n = b.read(defl, len defl);
		if(n != len defl)
			fail(sprint("reading data after index entry: %r"));

		sys->remove("/usr/mjl/tmp/blahbuf");
		fd := sys->create("/usr/mjl/tmp/blahbuf", Sys->OWRITE, 8r666);
		if(fd == nil)
			fail(sprint("open blahbuf: %r"));
		if(sys->write(fd, defl, len defl) != len defl)
			fail(sprint("writing defl...: %r"));

		raw: array of byte;
		if(len defl != 0) {
			case int defl[0] {
			'u' =>
				raw = defl[1:];
			0 =>
				raw = defl;
			* =>
				derr: string;
				(raw, derr) = inflatebuf(defl[2:len defl]);
				if(derr != nil)
					fail("inflating data after header: "+derr);
			}
		} else
			raw = array[0] of byte;
		print("## data start (%d bytes)\n", len raw);
		print("%s\n", string raw);
		print("## data end\n");
		}

		o += big ix.csize;
	}
}


Index: adt {
	offset:	big;
	flags:	int;
	csize, uncsize:	int;
	base, link, p1, p2:	int;
	nodeid:	array of byte;

	parse:	fn(buf: array of byte): (ref Index, string);
	text:	fn(ix: self ref Index): string;
};
nullindex: Index;

Index.parse(buf: array of byte): (ref Index, string)
{
	if(len buf != 64)
		return (nil, "wrong number of bytes");

	ix := ref nullindex;
	o := 0;
	(ix.offset, o) = g48(buf, o);
	(ix.flags, o) = g16(buf, o);
	(ix.csize, o) = g32(buf, o);
	(ix.uncsize, o) = g32(buf, o);
	(ix.base, o) = g32(buf, o);
	(ix.link, o) = g32(buf, o);
	(ix.p1, o) = g32(buf, o); # xxx set to ffffffff?
	(ix.p2, o) = g32(buf, o); # idem
	ix.nodeid = array[len buf-o] of byte;
	ix.nodeid[:] = buf[o:];
	
	return (ix, nil);
}

Index.text(ix: self ref Index): string
{
	return sprint("<Index off=%bd flags=%x size=%d,%d base=%d link=%d p1=%d p2=%d nodeid=%s>", ix.offset, ix.flags, ix.csize, ix.uncsize, ix.base, ix.link, ix.p1, ix.p2, hex(ix.nodeid));
}


inflatebuf(src: array of byte): (array of byte, string)
{
	say(sprint("inflating %d bytes of data", len src));

	rqch := inflate->start("vd");
	startmsg := <-rqch;
	if(tagof startmsg != tagof (Filter->Rq).Start)
		return (nil, "invalid first message from inflate filter");
	dst := array[0] of byte;
	sent := 0;
	for(;;) {
		msg := <-rqch;
		pick m := msg {
		Start =>
			return (nil, "received another start message");
		Fill =>
			give := len src-sent;
			if(give > len m.buf)
				give = len m.buf;
			say(sprint("fill, give %d, sent %d, len m.buf %d", give, sent, len m.buf));
			m.buf[:] = src[sent:sent+give];
			m.reply <-= give;
			sent += give;
		Result =>
			say(sprint("result, len m.buf %d", len m.buf));
			ndst := array[len dst+len m.buf] of byte;
			ndst[:] = dst;
			ndst[len dst:] = m.buf;
			dst = ndst;
			m.reply <-= 0;
		Finished =>
			if(len m.buf != 0)
				say("trailing bytes after inflating");
			return (dst, nil);
		Info =>
			say("filter: "+m.msg);
		Error =>
			return (nil, "error from filter: "+m.e);
		}
	}
	
}

hex(d: array of byte): string
{
	s := "";
	n := len d;
	if(n == 32)
		n = 20;
	for(i := 0; i < n; i++)
		s += sprint("%02x", int d[i]);
	return s;
}

g16(d: array of byte, o: int): (int, int)
{
	return (int d[o]<<8|int d[o+1], o+2);
}

g32(d: array of byte, o: int): (int, int)
{
	return (g16(d, o).t0<<16|g16(d, o+2).t0, o+4);
}

g48(d: array of byte, o: int): (big, int)
{
	return (big g16(d, o).t0<<32|big g16(d, o+2).t0<<16|big g16(d, o+4).t0, o+6);
}


say(s: string)
{
	if(dflag)
		warn(s);
}

warn(s: string)
{
	fprint(fildes(2), "%s\n", s);
}

fail(s: string)
{
	warn(s);
	raise "fail:"+s;
}
