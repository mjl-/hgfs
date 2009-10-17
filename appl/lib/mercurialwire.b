implement Mercurialwire;

include "sys.m";
	sys: Sys;
	sprint: import sys;
include "bufio.m";
include "env.m";
	env: Env;
include "string.m";
	str: String;
include "filter.m";
	deflate: Filter;
include "tables.m";
	tables: Tables;
	Strhash: import tables;
include "filtertool.m";
	filtertool: Filtertool;
include "util0.m";
	util: Util0;
	l2a, rev: import util;
include "mercurial.m";
	hg: Mercurial;
	Revlog, Repo, Entry, Change, Manifest: import hg;
include "mercurialwire.m";

init()
{
	sys = load Sys Sys->PATH;
	env = load Env Env->PATH;
	str = load String String->PATH;
	deflate = load Filter Filter->DEFLATEPATH;
	deflate->init();
	filtertool = load Filtertool Filtertool->PATH;
	tables = load Tables Tables->PATH;
	util = load Util0 Util0->PATH;
	util->init();
	hg = load Mercurial Mercurial->PATH;
	hg->init();
}

heads(r: ref Repo): (string, string)
{
	{
		ents := r.xheads();

		s := "";
		for(i := 0; i < len ents; i++)
			s += " "+ents[i].nodeid;
		if(s != nil)
			s = s[1:];
		return (s+"\n", nil);
	} exception e {
	"hg:*" =>	return (nil, e[len "hg:":]);
	}
}

# nodes: space-separated list of nodes
branches(r: ref Repo, nodes: string): (string, string)
{
	{
		return (branches0(r, nodes), nil);
	} exception e {
	"hg:*" =>	return (nil, e[len "hg:":]);
	}
}

branches0(r: ref Repo, nodes: string): string
{
	snodes := sys->tokenize(nodes, " ").t1;

	cl := r.xchangelog();
	ents := cl.xentries();

	resp := "";
	for(l := snodes; l != nil; l = tl l) {
		n := hd l;
		hg->xchecknodeid(n);

		if(n == hg->nullnode) {
			resp += sprint("%s %s %s %s\n", n, n, n, n);
			continue;
		}

		i := xfindnodeid(ents, n);
		e := ents[i];
		while(e.p1 >= 0 && e.p2 < 0)
			e = ents[e.p1];

		np1 := hg->nullnode;
		np2 := hg->nullnode;
		if(e.p1 >= 0)
			np1 = ents[e.p1].nodeid;
		if(e.p2 >= 0)
			np2 = ents[e.p2].nodeid;
		resp += sprint("%s %s %s %s\n", n, e.nodeid, np1, np2);
	}
	return resp;
}

xfindnodeid(a: array of ref Entry, n: string): int
{
	for(i := 0; i < len a; i++)
		if(a[i].nodeid == n)
			return i;
	error("no such nodeid "+n);
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
	"hg:*" =>	return (nil, e[len "hg:":]);
	}
}

between0(r: ref Repo, pair: string): string
{
	l := sys->tokenize(pair, "-").t1;
	if(len l != 2)
		error(sprint("bad pair %#q, need two nodeid's separated by dash", pair));
	tip := hd l;
	base := hd tl l;

	hg->xchecknodeid(tip);
	hg->xchecknodeid(base);

	cl := r.xchangelog();
	ents := cl.xentries();

	if(tip == hg->nullnode)
		return "\n";

	ti := xfindnodeid(ents, tip);
	bi := -1;
	if(base != hg->nullnode)
		bi = xfindnodeid(ents, base);

	count := 0;  # counter of entries seen for branch we are looking at
	next := 1;  # if next matches counter, print it
	lead := "";
	e := ents[ti];
	s := "";
	while(e.p1 >= 0 && e.rev != bi) {
		if(count++ == next) {
			s += sprint("%s%s", lead, e.nodeid);
			lead = " ";
			next *= 2;
		}
		e = ents[e.p1];
	}
	return s+"\n";
}

lookup(r: ref Repo, key: string): (string, string)
{
	{
		(nil, n) := r.xlookup(key, 1);
		return (n, nil);
	} exception e {
	"hg:*" =>	return (nil, e[len "hg:":]);
	}
}

nodes(l: list of string): array of string
{
	nodes := l2a(l);
	for(i := 0; i < len nodes; i++)
		hg->xchecknodeid(nodes[i]);
	return nodes;
}

openhist(r: ref Repo): (ref Revlog, ref Revlog, array of ref Entry, array of ref Entry)
{
	cl := r.xchangelog();
	ml := r.xmanifestlog();
	cents := cl.xentries();
	ments := ml.xentries();
	return (cl, ml, cents, ments);
}


filldesc(cents, a: array of ref Entry, nodes: array of string)
{
	havenull := 0;
	for(i := 0; i < len nodes; i++) {
		if(nodes[i] == hg->nullnode) {
			havenull++;
			continue;
		}
		ni := xfindnodeid(cents, nodes[i]);
		if(dflag) say(sprint("mark root entry %d", ni));
		a[ni] = cents[ni];
	}

	# for each entry in "cents", if a parent is set in "a", set the entry in "a" too
	for(i = 0; i < len cents; i++) {
		e := cents[i];
		if(havenull && e.p1 == -1 || (e.p1 >= 0 && a[e.p1] != nil) || (e.p2 >= 0 && a[e.p2] != nil)) {
			if(dflag) say(sprint("mark entry %d", i));
			a[i] = cents[i];
		}
	}
}

fillanc(cents, a: array of ref Entry, nodes: array of string)
{
	for(i := 0; i < len nodes; i++) {
		ni: int;
		if(nodes[i] == hg->nullnode)
			continue;
		ni = xfindnodeid(cents, nodes[i]);
		if(dflag) say(sprint("mark head %d", ni));
		fillanc0(cents, a, ni);
	}
}

fillanc0(cents, a: array of ref Entry, i: int)
{
	if(i < 0)
		return;
	a[i] = cents[i];
	fillanc0(cents, a, a[i].p1);
	fillanc0(cents, a, a[i].p2);
}

# roots: list of space-separated nodeid's
changegroup(r: ref Repo, sroots: string): (ref Sys->FD, string)
{
	{
		roots := nodes(sys->tokenize(sroots, " ").t1);
		(cl, ml, cents, ments) := openhist(r);
		desc := array[len cents] of ref Entry;
		if(len roots == 0)
			desc[:] = cents;
		else
			filldesc(cents, desc, roots);
		return mkchangegroup(r, cl, ml, cents, ments, desc);
	} exception e {
	"hg:*" =>	return (nil, e[len "hg:":]);
	}
}

# bases: list of space-separated nodeid's
# heads: list of space-separated nodeid's
changegroupsubset(r: ref Repo, sbases, sheads: string): (ref Sys->FD, string)
{
	{
		bases := nodes(sys->tokenize(sbases, " ").t1);
		heads := nodes(sys->tokenize(sheads, " ").t1);
		(cl, ml, cents, ments) := openhist(r);
		desc := array[len cents] of ref Entry;
		anc := array[len cents] of ref Entry;
		filldesc(cents, desc, bases);
		fillanc(cents, anc, heads);
		for(i := 0; i < len anc; i++)
			if(desc[i] == nil || anc[i] == nil) {
				desc[i] = nil;
				if(dflag) say(sprint("unmarking %d", i));
			}
		return mkchangegroup(r, cl, ml, cents, ments, desc);
	} exception e {
	"hg:*" =>	return (nil, e[len "hg:":]);
	}
}

mkchangegroup(r: ref Repo, cl, ml: ref Revlog, cents, ments, sel: array of ref Entry): (ref Sys->FD, string)
{
	p := array[2] of ref Sys->FD;
	if(sys->pipe(p) < 0)
		return (nil, sprint("pipe: %r"));
	spawn mkchangegroup0(r, cl, ml, cents, ments, sel, p[0]);
	return (p[1], nil);
}

mkchangegroup0(r: ref Repo, cl, ml: ref Revlog, cents, ments, sel: array of ref Entry, out: ref Sys->FD)
{
	if(dflag) {
		say("mkchangegroup, sending these ents:");
		for(i := 0; i < len sel; i++)
			if(sel[i] != nil)
				say(sprint("\t%s", sel[i].text()));
	}

	err: string;
	(out, err) = filtertool->push(deflate, "z0", out, 1);
	if(err != nil)
		error("init deflate: "+err);

	# print the changelog group chunks
	prev := -1;
	for(i := 0; i < len sel; i++) {
		e := sel[i];
		if(e == nil)
			continue;

		if(dflag) say("nodeid: "+sel[i].nodeid);

		hdr := array[4+4*20] of byte;
		if(prev == -1)
			prev = e.p1;
		delta := cl.xdelta(prev, e.rev);
		prev = e.rev;
		o := 0;
		o += p32(hdr, o, len hdr+len delta);
		hdr[o:] = hg->unhex(e.nodeid);
		o += 20;
		hdr[o:] = hg->unhex(getnodeid(cents, e.p1));
		o += 20;
		hdr[o:] = hg->unhex(getnodeid(cents, e.p2));
		o += 20;
		hdr[o:] = hg->unhex(getnodeid(cents, e.link));
		o += 20;

		ewrite(out, hdr);
		ewrite(out, delta);
	}
	eogroup(out);

	# do another pass, now for the manifests of the changegsets
	# gather the paths+their nodeids we might need to send info about, for the next pass
	tree := Treerevs.new();
	prev = -1;
	for(i = 0; i < len sel; i++) {
		ce := sel[i];
		if(ce == nil)
			continue;

		c: ref Change;
		m: ref Manifest;
		(c, m) = r.xmanifest(ce.rev);
		mn := c.manifestnodeid;
		mi := xfindnodeid(ments, mn);
		me := ments[mi];

		hdr := array[4+4*20] of byte;
		if(prev == -1)
			prev = me.p1;
		delta := ml.xdelta(prev, me.rev);
		prev = me.rev;
		o := 0;
		o += p32(hdr, o, len hdr+len delta);
		hdr[o:] = hg->unhex(me.nodeid);
		o += 20;
		hdr[o:] = hg->unhex(getnodeid(ments, me.p1));
		o += 20;
		hdr[o:] = hg->unhex(getnodeid(ments, me.p2));
		o += 20;
		hdr[o:] = hg->unhex(getnodeid(cents, ce.rev));
		o += 20;

		ewrite(out, hdr);
		ewrite(out, delta);

		for(j := 0; j < len m.files; j++) {
			mf := m.files[j];
			tree.add(mf.path, mf.nodeid);
		}
	}
	eogroup(out);

	# finally, the files in the manifests of the changesets
	tree.l = util->rev(tree.l);
	for(pl := tree.l; pl != nil; pl = tl pl) {
		p := hd pl;
		p.nodeids = util->rev(p.nodeids);
		filegroup(r, out, p, cents, sel);
	}
	eogroup(out);
}


filegroup(r: ref Repo, out: ref Sys->FD, p: ref Pathrevs, cents, sel: array of ref Entry)
{
	rl := r.xopenrevlog(p.path);
	fents := rl.xentries();

	wrote := 0;

	prev := -1;
	for(l := p.nodeids; l != nil; l = tl l) {
		n := hd l;
		i := xfindnodeid(fents, n);
		e := fents[i];
		if(dflag) say(sprint("\tnodeid %q, link %d, sel[link] nil %d", n, e.link, sel[e.link] == nil));
		if(sel[e.link] == nil)
			continue;

		if(dflag) say("adding file to filegroup");

		if(wrote == 0) {
			pathlen := array[4] of byte;
			pathbuf := array of byte p.path;
			p32(pathlen, 0, 4+len pathbuf);
			ewrite(out, pathlen);
			ewrite(out, pathbuf);
			wrote = 1;
		}

		hdr := array[4+4*20] of byte;
		if(prev == -1)
			prev = e.p1;
		delta := rl.xdelta(prev, e.rev);
		prev = e.rev;
		o := 0;
		o += p32(hdr, o, len hdr+len delta);
		hdr[o:] = hg->unhex(e.nodeid);
		o += 20;
		hdr[o:] = hg->unhex(getnodeid(fents, e.p1));
		o += 20;
		hdr[o:] = hg->unhex(getnodeid(fents, e.p2));
		o += 20;
		hdr[o:] = hg->unhex(getnodeid(cents, e.link));
		o += 20;
		ewrite(out, hdr);
		ewrite(out, delta);
	}
	if(wrote)
		eogroup(out);
}

Pathrevs: adt {
	path:	string;
	nodeids:	list of string;
};

Treerevs: adt {
	l:	list of ref Pathrevs;
	pathmap:	ref Strhash[ref Pathrevs];  # key: path
	pathrevmap:	ref Strhash[ref Pathrevs];  # key: nodeid+path

	new:	fn(): ref Treerevs;
	add:	fn(t: self ref Treerevs, path: string, nodeid: string);
};

Treerevs.new(): ref Treerevs
{
	t := ref Treerevs;
	t.pathmap = t.pathmap.new(128, nil);
	t.pathrevmap = t.pathrevmap.new(1024, nil);
	return t;
}

Treerevs.add(t: self ref Treerevs, path: string, nodeid: string)
{
	if(t.pathrevmap.find(nodeid+path) != nil)
		return;

	p := t.pathmap.find(path);
	if(p == nil) {
		p = ref Pathrevs (path, nil);
		t.l = p::t.l;
		t.pathmap.add(path, p);
	}

	p.nodeids = nodeid::p.nodeids;
	t.pathrevmap.add(nodeid+path, p);
}

endofgroup := array[4] of {* => byte 0};
eogroup(out: ref Sys->FD)
{
	ewrite(out, endofgroup);
}

getnodeid(a: array of ref Entry, p: int): string
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
			error(sprint("write: %r"));
	} exception e {
	"write on closed pipe" =>
		error("write "+e);
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

warn(s: string)
{
	sys->fprint(sys->fildes(2), "hgwire: %s\n", s);
}

say(s: string)
{
	if(dflag)
		warn(s);
}

error(s: string)
{
	warn(s);
	raise "hg:"+s;
}
