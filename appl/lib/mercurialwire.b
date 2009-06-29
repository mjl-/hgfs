implement Mercurialwire;

include "sys.m";
	sys: Sys;
	sprint: import sys;
include "bufio.m";
include "env.m";
	env: Env;
include "string.m";
	str: String;
include "lists.m";
	lists: Lists;
include "filter.m";
	deflate: Filter;
include "mercurial.m";
	hg: Mercurial;
	Revlog, Repo, Entry, Nodeid, Change, Manifest: import hg;
include "mercurialwire.m";

init()
{
	sys = load Sys Sys->PATH;
	env = load Env Env->PATH;
	str = load String String->PATH;
	lists = load Lists Lists->PATH;
	deflate = load Filter Filter->DEFLATEPATH;
	deflate->init();
	hg = load Mercurial Mercurial->PATH;
	hg->init();
}

heads(r: ref Repo): (string, string)
{
	{
		(entries, err) := r.heads();
		if(err != nil)
			fail(err);

		s := "";
		for(i := 0; i < len entries; i++)
			s += " "+entries[i].nodeid.text();
		if(s != nil)
			s = s[1:];
		return (s+"\n", nil);
	} exception e {
	"hgwire:*" =>	return (nil, e[len "hgwire:":]);
	}
}

# nodes: space-separated list of nodes
branches(r: ref Repo, nodes: string): (string, string)
{
	{
		return (branches0(r, nodes), nil);
	} exception e {
	"hgwire:*" =>	return (nil, e[len "hgwire:":]);
	}
}

branches0(r: ref Repo, nodes: string): string
{
	snodes := sys->tokenize(nodes, " ").t1;

	entries: array of ref Entry;
	(cl, err) := r.changelog();
	if(err == nil)
		(entries, err) = cl.entries();
	if(err != nil)
		fail(err);

	resp := "";
	for(l := snodes; l != nil; l = tl l) {
		n: ref Nodeid;
		(n, err) = Nodeid.parse(hd l);
		if(err != nil)
			fail(err);

		if(n.isnull()) {
			resp += sprint("%s %s %s %s\n", n.text(), n.text(), n.text(), n.text());
			continue;
		}

		i := findnodeid(entries, n);
		if(i < 0)
			fail(sprint("nodeid %s not found", n.text()));
		e := entries[i];
		while(e.p1 >= 0 && e.p2 < 0)
			e = entries[e.p1];

		np1 := hg->nullnode;
		np2 := hg->nullnode;
		if(e.p1 >= 0)
			np1 = entries[e.p1].nodeid;
		if(e.p2 >= 0)
			np2 = entries[e.p2].nodeid;
		resp += sprint("%s %s %s %s\n", n.text(), e.nodeid.text(), np1.text(), np2.text());
	}
	return resp;
}

findnodeid(a: array of ref Entry, n: ref Nodeid): int
{
	for(i := 0; i < len a; i++)
		if(Nodeid.cmp(a[i].nodeid, n) == 0)
			return i;
	return -1;
}

# pairs: list of space-separated dash-separated nodeid-tuples
between(r: ref Repo, spairs: string): (string, string)
{
	{
		pairs := sys->tokenize(spairs, " ").t1;
		s := "";
		for(; pairs != nil; pairs = tl pairs)
			s += between0(r, hd pairs);
		return (s, nil);
	} exception e {
	"hgwire:*" =>	return (nil, e[len "hgwire:":]);
	}
}

between0(r: ref Repo, pair: string): string
{
	l := sys->tokenize(pair, "-").t1;
	if(len l != 2)
		fail(sprint("bad pair %#q, need two nodeid's separated by dash", pair));
	tip := hd l;
	base := hd tl l;

	nbase: ref Nodeid;
	(ntip, err) := Nodeid.parse(tip);
	if(err == nil)
		(nbase, err) = Nodeid.parse(base);
	if(err != nil)
		fail(err);

	entries: array of ref Entry;
	cl: ref Revlog;
	(cl, err) = r.changelog();
	if(err == nil)
		(entries, err) = cl.entries();
	if(err != nil)
		fail(err);

	if(ntip.isnull())
		return "\n";

	ti := findnodeid(entries, ntip);
	if(ti < 0)
		fail("no such tip nodeid "+ntip.text());
	bi := -1;
	if(!nbase.isnull()) {
		bi = findnodeid(entries, nbase);
		if(bi < 0)
			fail("no such base nodeid "+nbase.text());
	}

	count := 0;  # counter of entries seen for branch we are looking at
	next := 1;  # if next matches counter, print it
	lead := "";
	e := entries[ti];
	s := "";
	while(e.p1 >= 0 && e.rev != bi) {
		if(count++ == next) {
			s += sprint("%s%s", lead, e.nodeid.text());
			lead = " ";
			next *= 2;
		}
		e = entries[e.p1];
	}
	return s+"\n";
}

lookup(r: ref Repo, key: string): (string, string)
{
	{
		(nil, n, err) := r.lookup(key);
		if(err != nil)
			fail(err);
		if(n == nil)
			fail(sprint("unknown revision %#q", key));
		return (n.text(), nil);
	} exception e {
	"hgwire:*" =>	return (nil, e[len "hgwire:":]);
	}
}

nodes(l: list of string): array of ref Nodeid
{
	nodes := array[len l] of ref Nodeid;
	i := 0;
	for(; l != nil; l = tl l) {
		err: string;
		(nodes[i++], err) = Nodeid.parse(hd l);
		if(err != nil)
			fail(err);
	}
	return nodes;
}

openhist(r: ref Repo): (ref Revlog, ref Revlog, array of ref Entry, array of ref Entry)
{
	cl, ml: ref Revlog;
	centries, mentries: array of ref Entry;
	err: string;
	(cl, err) = r.changelog();
	if(err != nil)
		fail("reading changelog: "+err);

	(centries, err) = cl.entries();
	if(err != nil)
		fail("reading changelog entries: "+err);

	(ml, err) = r.manifestlog();
	if(err != nil)
		fail("reading manifest: "+err);

	(mentries, err) = ml.entries();
	if(err != nil)
		fail("reading manifest entries: "+err);

	return (cl, ml, centries, mentries);
}


filldesc(centries, a: array of ref Entry, nodes: array of ref Nodeid)
{
	for(i := 0; i < len nodes; i++) {
		ni := 0;
		if(!nodes[i].isnull())
			ni = findnodeid(centries, nodes[i]);
		if(ni < 0)
			fail(sprint("no such nodeid %s", nodes[i].text()));
		say(sprint("mark root entry %d", ni));
		a[ni] = centries[ni];
	}

	# for each entry in "centries", if a parent is set in "a", set the entry in "a" too
	say(sprint("filldesc, len %d, len nodes %d", len a, len nodes));
	for(i = 0; i < len centries; i++) {
		e := centries[i];
		if((e.p1 >= 0 && a[e.p1] != nil) || (e.p2 >= 0 && a[e.p2] != nil)) {
			say(sprint("mark entry %d", i));
			a[i] = centries[i];
		}
	}
}

fillanc(centries, a: array of ref Entry, nodes: array of ref Nodeid)
{
	for(i := 0; i < len nodes; i++) {
		ni: int;
		if(nodes[i].isnull())
			continue;
		ni = findnodeid(centries, nodes[i]);
		if(ni < 0)
			fail(sprint("no such nodeid %s", nodes[i].text()));
		say(sprint("mark head %d", ni));
		fillanc0(centries, a, ni);
	}
}

fillanc0(centries, a: array of ref Entry, i: int)
{
	if(i < 0)
		return;
	a[i] = centries[i];
	fillanc0(centries, a, a[i].p1);
	fillanc0(centries, a, a[i].p2);
}

# roots: list of space-separated nodeid's
changegroup(r: ref Repo, sroots: string): (ref Sys->FD, string)
{
	{
		roots := nodes(sys->tokenize(sroots, " ").t1);
		(cl, ml, centries, mentries) := openhist(r);
		desc := array[len centries] of ref Entry;
		if(len roots == 0)
			desc[:] = centries;
		else
			filldesc(centries, desc, roots);
		fd := mkchangegroup(r, cl, ml, centries, mentries, desc);
		return (fd, nil);
	} exception e {
	"hgwire:*" =>	return (nil, e[len "hgwire:":]);
	}
}

# bases: list of space-separated nodeid's
# heads: list of space-separated nodeid's
changegroupsubset(r: ref Repo, sbases, sheads: string): (ref Sys->FD, string)
{
	{
		bases := nodes(sys->tokenize(sbases, " ").t1);
		heads := nodes(sys->tokenize(sheads, " ").t1);
		(cl, ml, centries, mentries) := openhist(r);
		desc := array[len centries] of ref Entry;
		anc := array[len centries] of ref Entry;
		filldesc(centries, desc, bases);
		fillanc(centries, anc, heads);
		for(i := 0; i < len anc; i++)
			if(desc[i] == nil || anc[i] == nil) {
				desc[i] = nil;
				say(sprint("unmarking %d", i));
			}
		fd := mkchangegroup(r, cl, ml, centries, mentries, desc);
		return (fd, nil);
	} exception e {
	"hgwire:*" =>	return (nil, e[len "hgwire:":]);
	}
}

mkchangegroup(r: ref Repo, cl, ml: ref Revlog, centries, mentries, sel: array of ref Entry): ref Sys->FD
{
	p := array[2] of ref Sys->FD;
	if(sys->pipe(p) < 0)
		fail(sprint("pipe: %r"));
	spawn mkchangegroup0(r, cl, ml, centries, mentries, sel, p[0]);
	return p[1];
}

mkchangegroup0(r: ref Repo, cl, ml: ref Revlog, centries, mentries, sel: array of ref Entry, out: ref Sys->FD)
{
	say("mkchangegroup, sending these entries:");
	for(i := 0; i < len sel; i++)
		if(sel[i] != nil)
			say(sprint("\t%s", sel[i].text()));

	err: string;
	(out, err) = pushfilter(deflate, "z0", out);
	if(err != nil)
		fail("init deflate: "+err);

	# print the changelog group chunks
	prev := -1;
	for(i = 0; i < len sel; i++) {
		e := sel[i];
		if(e == nil)
			continue;

		say("nodeid: "+sel[i].nodeid.text());

		hdr := array[4+4*20] of byte;
		delta: array of byte;
		if(prev == -1)
			prev = e.p1;
		(delta, err) = cl.delta(prev, e.rev);
		if(err != nil)
			fail(sprint("reading delta for changelog rev %d: %s", e.rev, err));
		prev = e.rev;
		o := 0;
		o += p32(hdr, o, len hdr+len delta);
		hdr[o:] = e.nodeid.d;
		o += 20;
		hdr[o:] = getnodeid(centries, e.p1).d;
		o += 20;
		hdr[o:] = getnodeid(centries, e.p2).d;
		o += 20;
		hdr[o:] = getnodeid(centries, e.link).d;
		o += 20;

		ewrite(out, hdr);
		ewrite(out, delta);
	}
	eogroup(out);

	# do another pass, now for the manifests of the changegsets
	# gather the paths+their nodeids we might need to send info about, for the next pass
	paths: list of ref Path;
	prev = -1;
	for(i = 0; i < len sel; i++) {
		ce := sel[i];
		if(ce == nil)
			continue;

		c: ref Change;
		m: ref Manifest;
		(c, m, err) = r.manifest(ce.rev);
		if(err != nil)
			fail(sprint("getting manifest nodeid for changeset rev %d: %s", ce.rev, err));
		mn := c.manifestnodeid;
		mi := findnodeid(mentries, mn);
		if(mi < 0)
			fail("unknown manifest nodeid "+mn.text());
		me := mentries[mi];

		hdr := array[4+4*20] of byte;
		delta: array of byte;
		if(prev == -1)
			prev = me.p1;
		(delta, err) = ml.delta(prev, me.rev);
		if(err != nil)
			fail(sprint("reading delta for manifest rev %d: %s", me.rev, err));
		prev = me.rev;
		o := 0;
		o += p32(hdr, o, len hdr+len delta);
		hdr[o:] = me.nodeid.d;
		o += 20;
		hdr[o:] = getnodeid(mentries, me.p1).d;
		o += 20;
		hdr[o:] = getnodeid(mentries, me.p2).d;
		o += 20;
		hdr[o:] = getnodeid(centries, me.link).d;
		o += 20;

		ewrite(out, hdr);
		ewrite(out, delta);

		for(fl := m.files; fl != nil; fl = tl fl)
			paths = addpathnodeid(paths, (hd fl).path, (hd fl).nodeid);
	}
	eogroup(out);

	# finally, the files in the manifests of the changesets
	paths = finishpaths(paths);
	for(pl := paths; pl != nil; pl = tl pl)
		filegroup(r, out, hd pl, centries, sel);
	eogroup(out);
}


filegroup(r: ref Repo, out: ref Sys->FD, p: ref Path, centries, sel: array of ref Entry)
{
	(rl, err) := r.openrevlog(p.path);
	if(err != nil)
		fail(sprint("openrevlog %q: %s", p.path, err));

	fentries: array of ref Entry;
	(fentries, err) = rl.entries();
	if(err != nil)
		fail(sprint("entries for %q: %s", p.path, err));

	wrote := 0;

	prev := -1;
	for(l := p.nodeids; l != nil; l = tl l) {
		n := hd l;
		i := findnodeid(fentries, n);
		if(i < 0)
			fail(sprint("missing nodeid %s for path %q", n.text(), p.path));
		e := fentries[i];
		say(sprint("\tnodeid %s, link %d, sel[link] nil %d", n.text(), e.link, sel[e.link] == nil));
		if(sel[e.link] == nil)
			continue;

		say("adding file to filegroup");

		if(wrote == 0) {
			pathlen := array[4] of byte;
			pathbuf := array of byte p.path;
			p32(pathlen, 0, 4+len pathbuf);
			ewrite(out, pathlen);
			ewrite(out, pathbuf);
			wrote = 1;
		}

		hdr := array[4+4*20] of byte;
		delta: array of byte;
		if(prev == -1)
			prev = e.p1;
		(delta, err) = rl.delta(prev, e.rev);
		if(err != nil)
			fail(sprint("reading delta for rev %d, path %q: %s", e.rev, p.path, err));
		prev = e.rev;
		o := 0;
		o += p32(hdr, o, len hdr+len delta);
		hdr[o:] = e.nodeid.d;
		o += 20;
		hdr[o:] = getnodeid(fentries, e.p1).d;
		o += 20;
		hdr[o:] = getnodeid(fentries, e.p2).d;
		o += 20;
		hdr[o:] = getnodeid(centries, e.link).d;
		o += 20;
		ewrite(out, hdr);
		ewrite(out, delta);
	}
	if(wrote)
		eogroup(out);
}

Path: adt {
	path:	string;
	nodeids:	list of ref Nodeid;
};

addpathnodeid(l: list of ref Path, path: string, nodeid: ref Nodeid): list of ref Path
{
	origl := l;
	for(; l != nil; l = tl l) {
		p := hd l;
		if(p.path != path)
			continue;

		if(!hasnodeid(p.nodeids, nodeid))
			p.nodeids = nodeid::p.nodeids;
		return origl;
	}
	np := ref Path (path, nodeid::nil);
	return np::origl;
}

finishpaths(l: list of ref Path): list of ref Path
{
	nl := lists->reverse(l);
	for(; l != nil; l = tl l)
		(hd l).nodeids = lists->reverse((hd l).nodeids);
	return nl;
}

eogroup(out: ref Sys->FD)
{
	eog := array[4] of {* => byte 0};
	ewrite(out, eog);
}

getnodeid(a: array of ref Entry, p: int): ref Nodeid
{
	if(p < 0)
		return hg->nullnode;
	return a[p].nodeid;
}

ewrite(fd: ref Sys->FD, d: array of byte)
{
	if(len d == 0)
		return;

	{
		if(sys->write(fd, d, len d) != len d)
			fail(sprint("write: %r"));
	} exception e {
	"write on closed pipe" =>
		fail("write "+e);
	}
}

pushfilter(f: Filter, params: string, out: ref Sys->FD): (ref Sys->FD, string)
{
	if(sys->pipe(fds := array[2] of ref Sys->FD) < 0)
		return (nil, sprint("pipe: %r"));

	spawn tunnel(f, params, fds[1], out, pidc := chan of int);
	<-pidc;
	return (fds[0], nil);
}

tunnel(f: Filter, params: string, in, out: ref Sys->FD, pidc: chan of int)
{
	pidc <-= sys->pctl(Sys->NEWFD, in.fd::out.fd::2::nil);
	in = sys->fildes(in.fd);
	out = sys->fildes(out.fd);

	rqc := f->start(params);
	for(;;)
	pick rq := <-rqc {
	Start =>
		;
	Fill =>
		n := sys->read(in, rq.buf, len rq.buf);
		rq.reply <-= n;
		if(n < 0) {
			warn(sprint("read: %r"));
			return;
		}
	Result =>
		if(sys->write(out, rq.buf, len rq.buf) != len rq.buf) {
			warn(sprint("write: %r"));
			return;
		}
		rq.reply <-= 0;
	Finished =>
		if(len rq.buf != 0)
			warn(sprint("%d leftover bytes", len rq.buf));
		return;
	Info =>
		# rq.msg
		;
	Error =>
		warn("error: "+rq.e);
		return;
	}
}

p32(d: array of byte, o: int, v: int): int
{
	d[o++] = byte (v>>24);
	d[o++] = byte (v>>16);
	d[o++] = byte (v>>8);
	d[o++] = byte (v>>0);
	return 4;
}

hasnodeid(l: list of ref Nodeid, e: ref Nodeid): int
{
	for(; l != nil; l = tl l)
		if(Nodeid.cmp((hd l), e) == 0)
			return 1;
	return 0;
}

warn(s: string)
{
	sys->fprint(sys->fildes(2), "mercurialwire: %s\n", s);
}

say(s: string)
{
	if(dflag)
		warn(s);
}

fail(s: string)
{
	warn(s);
	raise "hgwire:"+s;
}
