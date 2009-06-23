implement HgWebsrv;

include "sys.m";
	sys: Sys;
	sprint: import sys;
include "draw.m";
include "arg.m";
include "env.m";
	env: Env;
include "string.m";
	str: String;
include "lists.m";
	lists: Lists;
include "filter.m";
	deflate: Filter;
include "cgi.m";
	cgi: Cgi;
	Fields: import cgi;
include "mercurial.m";
	hg: Mercurial;
	Revlog, Repo, Entry, Nodeid, Change, Manifest: import hg;

dflag: int;
repo: ref Repo;
iscgi: int;
stdout, stderr: ref Sys->FD;
fields: ref Fields;
statusprinted := 0;

HgWebsrv: module {
	init:	fn(nil: ref Draw->Context, args: list of string);
};

init(nil: ref Draw->Context, args: list of string)
{
	sys = load Sys Sys->PATH;
	stdout = sys->fildes(1);
	stderr = sys->fildes(2);
	arg := load Arg Arg->PATH;
	env = load Env Env->PATH;
	str = load String String->PATH;
	lists = load Lists Lists->PATH;
	deflate = load Filter Filter->DEFLATEPATH;
	deflate->init();
	cgi = load Cgi Cgi->PATH;
	cgi->init();
	hg = load Mercurial Mercurial->PATH;
	hg->init();

	hgpath := "";

	arg->init(args);
	arg->setusage(arg->progname()+" [-d] [-h path] querystring");
	while((c := arg->opt()) != 0)
		case c {
		'd' =>	dflag++;
			if(dflag > 1)
				hg->debug++;
		'h' =>	hgpath = arg->earg();
		* =>	arg->usage();
		}
	args = arg->argv();
	if(len args > 1)
		arg->usage();
	iscgi = args == nil;
	qs: string;
	if(args == nil)
		qs = env->getenv("QUERY_STRING");
	else
		qs = hd args;


	err: string;
	(repo, err) = Repo.find(hgpath);
	if(err != nil)
		fail(err);

	fields = cgi->unpack(qs);
	if(!fields.has("cmd")) {
		sys->print("%s%s%s",
			"status: 200 OK\r\n",
			"content-type: text/plain\r\n\r\n",
			"this just serves mercurial repositories using the mercurial wire protocol over http.  no html frontend here.\n");
		return;
	}
	cmd := fields.get("cmd");
	case cmd {
	"heads" =>		heads();
	"branches" =>		branches();
	"between" =>		between();
	"changegroup" =>	changegroup();
	"changegroupsubset" =>	changegroupsubset();
	"capabilities" =>	capabilities();
	"lookup" =>		lookup();
	* =>
		fail(sprint("unrecognized command %#q", cmd));
	}
}

statusok()
{
	fd: ref Sys->FD;
	if(iscgi)
		fd = stdout;
	else
		fd = stderr;
	if(sys->fprint(fd, "status: 200\r\ncontent-type: application/mercurial-0.1\r\n\r\n") < 0)
		raise "fail:write";
	statusprinted = 1;
}

# ?cmd=heads
heads()
{
	(entries, err) := repo.heads();
	if(err != nil)
		fail(err);

	statusok();
	s := "";
	for(i := 0; i < len entries; i++) {
		e := entries[i];
		say(sprint("%s, rev %d", e.nodeid.text(), e.rev));
		if(e.p1 >= 0) {
			if(e.p2 >= 0)
				say(sprint("\tparents %d %d\n", e.p1, e.p2));
			else
				say(sprint("\tparent %d\n", e.p1));
		}
		s += " "+e.nodeid.text();
	}
	if(s != nil)
		s = s[1:];
	sys->print("%s\n", s);
}

# ?cmd=branches&nodes=$nodeid1+$nodeid2+...
branches()
{
	if(!fields.has("nodes"))
		fail("missing parameter 'nodes'");
	snodes := sys->tokenize(fields.get("nodes"), " ").t1;

	entries: array of ref Entry;
	(cl, err) := repo.changelog();
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
		if(e.p1 >= 0)
			e = entries[e.p1];
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
	statusok();
	ewrite(stdout, array of byte resp);
}

findnodeid(a: array of ref Entry, n: ref Nodeid): int
{
	for(i := 0; i < len a; i++)
		if(Nodeid.cmp(a[i].nodeid, n) == 0)
			return i;
	return -1;
}

# ?cmd=between&pairs=$nodeid1-$nodeid2
between()
{
	if(!fields.has("pairs"))
		fail("missing parameter 'pairs'");
	pairs := sys->tokenize(fields.get("pairs"), " ").t1;

	s := "";
	for(; pairs != nil; pairs = tl pairs)
		s += between0(hd pairs);
	statusok();
	ewrite(stdout, array of byte s);
}

between0(pair: string): string
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
	(cl, err) = repo.changelog();
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

# ?cmd=capabilities
capabilities()
{
	statusok();

	if(sys->print("lookup changegroupsubset") < 0)
		fail(sprint("write: %r"));
}

# ?cmd=lookup&key=$rev
lookup()
{
	statusok();

	if(!fields.has("key")) {
		sys->print("0 missing 'key'\n");
		return;
	}
	key := fields.get("key");

	case key {
	"null" =>
		sys->print("0 %s\n", (hg->nullnode).text());
	"." or
	"tip" =>
		rev: int;
		e: ref Entry;
		(cl, err) := repo.changelog();
		if(err == nil)
			(rev, err) = cl.lastrev();
		if(err == nil)
			(e, err) = cl.findrev(rev);
		if(err != nil)
			sys->print("0 error: %s\n", err);
		else
			sys->print("1 %s\n", e.nodeid.text());
	* =>
		if(len key == 40) {
			(n, err) := Nodeid.parse(key);
			if(err != nil)
				sys->print("0 bad nodeid: %s\n", err);
			else
				sys->print("1 %s\n", n.text());
			return;
		}
		(rev, rem) := str->toint(key, 10);
		if(rem != nil) {
			sys->print("0 unknown revision %#q\n", key);
			return;
		}

		(c, err) := repo.change(rev);
		if(err != nil)
			sys->print("0 unknown revision '%d'\n", rev);
		else
			sys->print("1 %s\n", c.nodeid.text());
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

openhist(): (ref Revlog, ref Revlog, array of ref Entry, array of ref Entry)
{
	cl, ml: ref Revlog;
	centries, mentries: array of ref Entry;
	err: string;
	(cl, err) = repo.changelog();
	if(err != nil)
		fail("reading changelog: "+err);

	(centries, err) = cl.entries();
	if(err != nil)
		fail("reading changelog entries: "+err);

	(ml, err) = repo.manifestlog();
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
		ni: int;
		if(nodes[i].isnull())
			ni = 0;
		else
			ni = findnodeid(centries, nodes[i]);
		if(ni < 0)
			fail(sprint("no such nodeid %s", nodes[i].text()));
		say(sprint("returning root entry %d", ni));
		a[ni] = centries[ni];
	}

	# for each entry in "centries", if a parent is set in "a", set the entry in "a" too
	say(sprint("filldesc, len %d, len nodes %d", len a, len nodes));
	for(i = 0; i < len centries; i++) {
		e := centries[i];
		if((e.p1 >= 0 && a[e.p1] != nil) || (e.p2 >= 0 && a[e.p2] != nil)) {
			say(sprint("returning entry %d", i));
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
		say(sprint("returning head %d", ni));
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

# ?cmd=changegroup&roots=$nodeid1+$nodeid2+...
changegroup()
{
	sroots := sys->tokenize(fields.get("roots"), " ").t1;

	roots := nodes(sroots);
	(cl, ml, centries, mentries) := openhist();
	desc := array[len centries] of ref Entry;
	filldesc(centries, desc, roots);
	mkchangegroup(cl, ml, centries, mentries, desc);
}

# ?cmd=changegroupsubset&bases=$nodeid1+$nodeid2+...&heads=$nodeid1+$nodeid2+...
changegroupsubset()
{
	sbases := sys->tokenize(fields.get("bases"), " ").t1;
	sheads := sys->tokenize(fields.get("heads"), " ").t1;

	bases := nodes(sbases);
	heads := nodes(sheads);
	(cl, ml, centries, mentries) := openhist();
	desc := array[len centries] of ref Entry;
	anc := array[len centries] of ref Entry;
	filldesc(centries, desc, bases);
	fillanc(centries, anc, heads);
	for(i := 0; i < len anc; i++)
		if(desc[i] == nil || anc[i] == nil)
			desc[i] = nil;
	mkchangegroup(cl, ml, centries, mentries, desc);
}

mkchangegroup(cl, ml: ref Revlog, centries, mentries, sel: array of ref Entry)
{
	statusok();

	say("mkchangegroup, sending these entries:");
	for(i := 0; i < len sel; i++)
		if(sel[i] != nil)
			say(sprint("\t%s\n", sel[i].text()));

	(out, err) := pushfilter(deflate, "z", stdout);
	if(err != nil)
		fail("init deflate: "+err);

	# print the changelog group chunks
	for(i = 0; i < len sel; i++) {
		e := sel[i];
		if(e == nil)
			continue;

		say("nodeid: "+sel[i].nodeid.text());

		hdr := array[4+4*20] of byte;
		delta: array of byte;
		(delta, err) = cl.delta(e.rev);
		if(err != nil)
			fail(sprint("reading delta for changelog rev %d: %s", e.rev, err));
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
	for(i = 0; i < len sel; i++) {
		ce := sel[i];
		if(ce == nil)
			continue;

		c: ref Change;
		m: ref Manifest;
		(c, m, err) = repo.manifest(ce.rev);
		if(err != nil)
			fail(sprint("getting manifest nodeid for changeset rev %d: %s", ce.rev, err));
		mn := c.manifestnodeid;
		mi := findnodeid(mentries, mn);
		if(mi < 0)
			fail("unknown manifest nodeid "+mn.text());
		me := mentries[mi];

		hdr := array[4+4*20] of byte;
		delta: array of byte;
		(delta, err) = ml.delta(me.rev);
		if(err != nil)
			fail(sprint("reading delta for manifest rev %d: %s", me.rev, err));
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
		filegroup(out, hd pl, centries, sel);
	eogroup(out);
}


filegroup(out: ref Sys->FD, p: ref Path, centries, sel: array of ref Entry)
{
	(rl, err) := repo.openrevlog(p.path);
	if(err != nil)
		fail(sprint("openrevlog %q: %s", p.path, err));

	fentries: array of ref Entry;
	(fentries, err) = rl.entries();
	if(err != nil)
		fail(sprint("entries for %q: %s", p.path, err));

	wrote := 0;

	say(sprint("path %s", p.path));
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
		(delta, err) = rl.delta(e.rev);
		if(err != nil)
			fail(sprint("reading delta for rev %d, path %q: %s", e.rev, p.path, err));
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
	if(sys->write(fd, d, len d) != len d)
		fail(sprint("write: %r"));
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
	sys->fprint(stderr, "hg/websrv: %s\n", s);
}

say(s: string)
{
	if(dflag)
		warn(s);
}

fail(s: string)
{
	hfd := dfd := stdout;
	if(statusprinted || !iscgi)
		hfd = stderr;
	if(statusprinted)
		dfd = stderr;
	sys->fprint(hfd, "status: 500 internal error\r\n");
	sys->fprint(hfd, "content-type: text/plain; charset=utf-8\r\n");
	sys->fprint(hfd, "\r\n");
	sys->fprint(dfd, "%s\n", s);
	raise "fail:"+s;
}
