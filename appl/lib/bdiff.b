implement Bdiff;

include "sys.m";
	sys: Sys;
	sprint: import sys;
include "util0.m";
	util: Util0;
	g32i, rev, p32i, max: import util;
include "bdiff.m";

init()
{
	sys = load Sys Sys->PATH;
	util = load Util0 Util0->PATH;
	util->init();
}

Patch.text(p: self ref Patch): string
{
	#return sprint("<patch s=%d e=%d length=%d buf=%q>", p.s, p.e, len p.d, string p.d);
	return sprint("<patch s=%d e=%d length=%d>", p.s, p.e, len p.d);
}


Delta.pack(d: self ref Delta): array of byte
{
	n := 0;
	for(l := d.l; l != nil; l = tl l)
		n += 3*4+len (hd l).d;
	buf := array[n] of byte;
	o := 0;
	for(l = d.l; l != nil; l = tl l) {
		p := hd l;
		o = p32i(buf, o, p.s);
		o = p32i(buf, o, p.e);
		o = p32i(buf, o, len p.d);
		buf[o:] = p.d;
		o += len p.d;
	}
	return buf;
}

Delta.replaces(d: self ref Delta, n: int): int
{
	return n == 0 && len d.l == 0 || len d.l == 1 && (p := hd d.l).s == 0 && p.e == n;
}

Delta.apply(dd: self ref Delta, b: array of byte): array of byte
{
	n := len b+dd.sizediff();
	d := array[n] of byte;
	ae := be := 0;
	for(l := dd.l; l != nil; l = tl l) {
		p := hd l;

		# copy data before hunk from base to dest
		d[be:] = b[ae:p.s];
		be += p.s-ae;

		# copy new data to dest, and skip the removed part from base
		d[be:] = p.d;
		be += len p.d;
		ae = p.e;
	}
	# and the trailing common data
	d[be:] = b[ae:];
	return d;
}

Group: adt {
	l:	list of array of byte;
	length:	int;	# original length of group
	o:	int;	# offset of hd l

	add:		fn(g: self ref Group, buf: array of byte);
	copy:		fn(g: self ref Group, sg: ref Group, s, e: int);
	flatten:	fn(g: self ref Group): array of byte;
	size:		fn(g: self ref Group): int;
	apply:		fn(g: ref Group, d: ref Delta): ref Group;
};

Group.add(g: self ref Group, buf: array of byte)
{
	g.l = buf::g.l;
	g.length += len buf;
}

Group.copy(g: self ref Group, sg: ref Group, s, e: int)
{
	# seek gs to s
	drop := s-sg.o;
	while(drop > 0) {
		b := hd sg.l;
		sg.l = tl sg.l;
		if(drop >= len b) {
			sg.o += len b;
			drop -= len b;
		} else {
			sg.l = b[drop:]::sg.l;
			sg.o += drop;
			drop = 0;
		}
	}
	if(sg.o != s) raise "group:bad0";

	# copy from sg into g
	n := e-s;
	while(n > 0 && sg.l != nil) {
		b := hd sg.l;
		sg.l = tl sg.l;
		take := len b;
		if(take > n) {
			take = n;
			sg.l = b[take:]::sg.l;
		}
		g.add(b[:take]);
		sg.o += take;
		n -= take;
	}
	if(n != 0) raise "group:bad1";
}

# note: we destruct g (in Group.copy), keeping g.o & hd g.l in sync.
# we never have to go back before an offset after having read it.
Group.apply(g: ref Group, d: ref Delta): ref Group
{
	g = ref *g;
	ng := ref Group (nil, 0, 0);
	o := 0;
	for(l := d.l; l != nil; l = tl l) {
		p := hd l;
		ng.copy(g, o, p.s);
		ng.add(p.d);
		o = p.e;
	}
	ng.copy(g, o, g.size());
	ng.l = rev(ng.l);
	return ng;
}

Group.size(g: self ref Group): int
{
	return g.length;
}

Group.flatten(g: self ref Group): array of byte
{
	d := array[g.size()] of byte;
	o := 0;
	for(l := g.l; l != nil; l = tl l) {
		d[o:] = hd l;
		o += len hd l;
	}
	return d;
}

Delta.applymany(base: array of byte, deltas: array of array of byte): (array of byte, string)
{
	if(len deltas == 0)
		return (base, nil);

	g := ref Group (base::nil, len base, 0);
	for(i := 0; i < len deltas; i++) {
		(p, err) := Delta.parse(deltas[i]);
		if(err != nil)
			return (nil, err);
		{
			g = Group.apply(g, p);
		} exception e {
		"group:*" =>
			return (nil, "bad patch: "+e[len "group:":]);
		}
	}
	return (g.flatten(), nil);
}

Delta.sizediff(d: self ref Delta): int
{
	n := 0;
	for(l := d.l; l != nil; l = tl l) {
		p := hd l;
		n += len p.d - (p.e-p.s);
	}
	return n;
}

Delta.parse(d: array of byte): (ref Delta, string)
{
	o := 0;
	l: list of ref Patch;
	while(o+12 <= len d) {
		s, e, n: int;
		(s, o) = g32i(d, o);
		(e, o) = g32i(d, o);
		(n, o) = g32i(d, o);
		if(s > e)
			return (nil, sprint("bad data, start %d > end %d", s, e));
		if(o+n > len d)
			return (nil, sprint("bad data, patch points past buffer, o+length %d+%d > len d %d", o, n, len d));
		buf := array[n] of byte;
		buf[:] = d[o:o+n];

		p := ref Patch (s, e, buf);
		if(l != nil && p.s < (hd l).e)
			return (nil, sprint("bad delta, patch starts before preceding patch, start %d < end %d", p.s, (hd l).e));
		l = p::l;
		o += n;
	}
	if(o != len d)
		return (nil, sprint("leftover bytes in delta, o %d != len d %d", o, len d));
	return (ref Delta (rev(l)), nil);
}

Delta.text(d: self ref Delta): string
{
	s: string;
	for(l := d.l; l != nil; l = tl l)
		s += sprint(" %s", (hd l).text());
	if(s != nil)
		s = s[1:];
	return s;
}


Line: adt {
	hash,
	s,
	e,
	n,
	i,
	eq:	int;
};

State: adt {
	a,
	b:	array of byte;
	la,
	lb:	array of ref Line;
	tab:	array of list of ref Line;
	r:	list of ref Patch;
};

# diff, on lines
diff(a, b: array of byte): ref Delta
{
	la := bounds(a);
	lb := bounds(b);

	# skip leading & trailing common lines, so the result will start & end in different lines.
	ea := len la;
	eb := len lb;
	for(s := 0; s < ea && s < eb ; s++) {
		l0 := la[s];
		l1 := lb[s];
		if(l0.hash != l1.hash || l0.n != l1.n || !eq(a, b, l0.s, l1.s, l0.n))
			break;
	}
	while(ea > s && eb > s) {
		l0 := la[--ea];
		l1 := lb[--eb];
		if(l0.hash != l1.hash || l0.n != l1.n || !eq(a, b, l0.s, l1.s, l0.n)) {
			ea++;
			eb++;
			break;
		}
	}

	tab := array[max(1, ea/8)] of list of ref Line;
	for(i := s; i < ea; i++) {
		l0 := la[i];
		h := l0.hash%len tab;
		tab[h] = l0::tab[h];
	}

	st := ref State (a, b, la, lb, tab, nil);
	diff0(st, s, s, ea, eb);
	return ref Delta (rev(st.r));
}

# find line boundaries & hash the lines
bounds(d: array of byte): array of ref Line
{
	l: list of ref Line;
	s := 0;
	h := 5381;
	nd := len d;
	nl := 0;
	for(i := 0; i < nd; i++) {
		c := int d[i];
		h = (h<<5)+h+c;
		if(c == '\n') {
			l = ref Line (h&16r7fffffff, s, i+1, (i+1)-s, nl++, -1)::l;
			s = i+1;
			h = 5381;
		}
	}
	if(s < i)
		l = ref Line (h&16r7fffffff, s, i, i-s, nl, -1)::l;
	return l2arev(l);
}

l2arev[T](l: list of T): array of T
{
	a := array[len l] of T;
	i := len a-1;
	for(; l != nil; l = tl l)
		a[i--] = hd l;
	return a;
}

same(st: ref State, l0, l1: ref Line): int
{
	m := eq(st.a, st.b, l0.s, l1.s, l0.n);
	if(m)
		l1.eq = l0.i;
	return m;
}

eq(a, b: array of byte, i, j, n: int): int
{
	while(n--)
		if(a[i++] != b[j++])
			return 0;
	return 1;
}

# find large(st) common substring (whole lines),
# keep that and diff again on the data before and after
# sa-ea are the lines from a to look at, ea-eb the lines from b.
# note that st.tab has all lines from a, so we have to check they are in the range we are looking for.
diff0(st: ref State, sa, sb: int, ea, eb: int)
{
	nla := ea-sa;
	nlb := eb-sb;
	if(nla == 0 && nlb == 0)
		return;
	if(nla == 0) {
		s: int;
		if(len st.la == 0)
			s = 0;
		else if(sa == len st.la)
			s = st.la[sa-1].e;
		else
			s = st.la[sa].s;
		st.r = ref Patch (s, s, st.b[st.lb[sb].s:st.lb[eb-1].e])::st.r;
		return;
	}
	if(nlb == 0) {
		st.r = ref Patch (st.la[sa].s, st.la[ea-1].e, array[0] of byte)::st.r;
		return;
	}

	# length & start+end of largest match so far
	length := 0;
	msa, msb, mea, meb: int;

	# for each line in b, for each line from a that matches b, determine the size of
	# the matching region (in whole lines, extending downwards in file).  keep track
	# of the largest match while continuing the search.
	# for each line in b & a, we check whether it has a chance of becoming a larger
	# match.  if not, we skip it and save ourselves some work.
	aend := st.la[ea-1].e;
	bend := st.lb[eb-1].e;
	for(i := sb; i < eb; i++) {
		l1 := st.lb[i];
		if(bend-l1.s <= length)
			break; # no longer match possible

		for(l := st.tab[l1.hash%len st.tab]; l != nil; l = tl l) {
			s0 := hd l;
			ia := s0.i;
			if(ia < sa || ia >= ea)
				continue; # not looking here
			s1 := l1;
			ib := s1.i;
			if(ia >= msa && ia < mea && ib >= msb && ib < meb)
				continue; # line part of longest match so far
			if(aend-s0.s <= length)
				continue; # no longer match possible with this line
			nlength := 0;
			for(;;) {
				if(ia >= ea || ib >= eb)
					break;
				l0 := st.la[ia];
				l1 = st.lb[ib];
				if(l1.eq != l0.i &&
					(l0.hash != l1.hash
					 || l0.n != l1.n
					 || !same(st, l0, l1)))
					break;
				nlength += l1.n;
				ia++;
				ib++;
			}
			if(nlength > length) {
				msa = s0.i;
				mea = ia;
				msb = s1.i;
				meb = ib;
				length = nlength;
			}
		}
	}

	if(length == 0) {
		st.r = ref Patch (st.la[sa].s, st.la[ea-1].e, st.b[st.lb[sb].s:st.lb[eb-1].e])::st.r;
		return;
	}

	diff0(st, sa, sb, msa, msb);
	diff0(st, mea, meb, ea, eb);
}
