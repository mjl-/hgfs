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
include "lists.m";
	lists: Lists;
include "keyring.m";
	keyring: Keyring;
	DigestState: import keyring;


print, sprint, fprint, fildes: import sys;

dflag: int;
pflag: int;
mflag: int;

Indexsize:	con 64;
Nullnode:	con -1;
nullnode:	array of byte;


Hunk: adt {
	start, end:	int;
	buf: array of byte;

	text:	fn(h: self ref Hunk): string;
};


Readindex: module {
	init:	fn(nil: ref Draw->Context, args: list of string);
};

init(nil: ref Draw->Context, args: list of string)
{
	sys = load Sys Sys->PATH;
	arg := load Arg Arg->PATH;
	bufio = load Bufio Bufio->PATH;
	lists = load Lists Lists->PATH;
	keyring = load Keyring Keyring->PATH;
	inflate = load Filter Filter->INFLATEPATH;
	inflate->init();

	nullnode = array[20] of {* => byte 0};

	arg->init(args);
	arg->setusage(arg->progname()+" [-dpm] file");
	while((c := arg->opt()) != 0)
		case c {
		'd' =>	dflag++;
		'p' =>	pflag++;
		'm' =>	mflag++;
		* =>	arg->usage();
		}
	args = arg->argv();
	if(len args != 1)
		arg->usage();

	path := hd args;
	b := bufio->open(path, Bufio->OREAD);
	o := big 0;
	base := array[0] of byte;
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
		add(i, ix.nodeid);

		print("index: %s\n", ix.text());
		o += big Indexsize;

		if(pflag || mflag) {
			say(sprint("reading from offset %bd", o));
			b.seek(o, Bufio->SEEKSTART);
			defl := array[ix.csize] of byte;
			n = b.read(defl, len defl);
			if(n != len defl)
				fail(sprint("reading data after index entry: %r"));

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

			d: array of byte;
			if(ix.base != ix.link) {
				print("diff (base %d, link %d)...\n", ix.base, ix.link);
				(hunks, herr) := decode(raw);
				if(herr != nil) {
					print("error decoding patch: %s\n", herr);
				} else {
					for(l := hunks; l != nil; l = tl l) {
						h := hd l;
						print("hunk: %s\n", h.text());
					}
					d = apply(base, hunks);
				}
			} else {
				print("full copy (base %d)...\n", ix.base);
				d = raw;
			}
			base = d;

			par1 := lookup(ix.p1);
			par2 := lookup(ix.p2);
			if(par1 == nil || par2 == nil)
				fail("could not find parent nodeid");
			node := mknodeid(d, par1, par2);
			if(hex(node) != hex(ix.nodeid))
				fail(sprint("nodeid mismatch, have %s, header claims %s", hex(node), hex(ix.nodeid)));

			if(pflag) {
				print("## data start (%d bytes)\n", len d);
				print("%s\n", string d);
				print("## data end\n");
			}

			if(mflag) {
				print("as manifest:\n");
				line: array of byte;
				while(len d > 0) {
					(line, d) = split(d, byte '\n');
					(file, nodeid) := split(line, byte '\0');
					if(len nodeid > 40) {
						print("long: %s\n", hex(line));
						print("nodeid=%q file=%q\n", hex(nodeid[:40]), string file);
						print("end=%q\n", string nodeid[40:]);
					} else
						print("nodeid=%q file=%q\n", string nodeid, string file);
				}
			}
		}

		o += big ix.csize;
	}
}

parents: list of (int, array of byte);
lookup(parent: int): array of byte
{
	if(parent == Nullnode)
		return nullnode;

	for(l := parents; l != nil; l = tl l) {
		(p, nodeid) := hd l;
		if(p == parent)
			return nodeid;
	}
	return nil;
}

add(parent: int, nodeid: array of byte)
{
	parents = (parent, nodeid)::parents;
}

cmp(p1, p2: array of byte): int
{
	for(i := 0; i < len p1; i++)
		if(p1[i] < p2[i])
			return -1;
		else if(p1[i] > p2[i])
			return 1;
	return 0;
}

mknodeid(d, p1, p2: array of byte): array of byte
{

	if(cmp(p1, p2) > 0)
		(p1, p2) = (p2, p1);

	state: ref DigestState;
	state = keyring->sha1(p1, len p1, nil, state);
	state = keyring->sha1(p2, len p2, nil, state);
	state = keyring->sha1(d, len d, nil, state);

	hash := array[Keyring->SHA1dlen] of byte;
	keyring->sha1(nil, 0, hash, state);
	return hash;
}

Hunk.text(h: self ref Hunk): string
{
	return sprint("<hunk s=%d e=%d buf=%s length=%d>", h.start, h.end, string h.buf, len h.buf);
}

apply(d: array of byte, l: list of ref Hunk): array of byte
{
	off := 0;
	for(; l != nil; l = tl l) {
		h := hd l;
		del := h.end-h.start;
		add := len h.buf;
		diff := add-del;

		s := h.start+off;
		e := h.end+off;
		nd := array[len d+diff] of byte;
		nd[:] = d[:s];
		nd[s:] = h.buf;
		nd[s+len h.buf:] = d[e:];
		d = nd;

		off += diff;
	}
	return d;
}

merge(l: list of list of ref Hunk): list of ref Hunk
{
	return hd l; # xxx implement
}

decode(d: array of byte): (list of ref Hunk, string)
{
	o := 0;
	l: list of ref Hunk;
	print("decode, buf %s\n", hex(d));
	while(o+12 < len d) {
		start, end, length: int;
		(start, o) = g32(d, o);
		(end, o) = g32(d, o);
		(length, o) = g32(d, o);
		say(sprint("s %d e %d l %d", start, end, length));
		if(start > end)
			return (nil, "bad data, start > end");
		if(o+length > len d)
			return (nil, "bad data, hunk points past buffer");
		buf := array[length] of byte;
		buf[:] = d[o:o+length];
		l = ref Hunk(start, end, buf)::l;
		o += length;
	}
	return (lists->reverse(l), nil);
}

split(buf: array of byte, b: byte): (array of byte, array of byte)
{
	for(i := 0; i < len buf; i++)
		if(buf[i] == b)
			return (buf[:i], buf[i+1:]);
	return (buf, array[0] of byte);
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
	ix.nodeid = array[20] of byte;
	ix.nodeid[:] = buf[o:o+20];
	o += 20;
	if(len buf-o != 12)
		return (nil, "wrong number of superfluous bytes");
	
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
