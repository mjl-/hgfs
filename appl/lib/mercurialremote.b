implement Mercurialremote;

include "sys.m";
	sys: Sys;
	sprint: import sys;
include "draw.m";
include "bufio.m";
	bufio: Bufio;
	Iobuf: import bufio;
include "string.m";
	str: String;
include "tables.m";
	tables: Tables;
	Strhash: import tables;
include "sh.m";
	sh: Sh;
include "mhttp.m";
	http: Http;
	Url, Req, Resp, Hdrs: import http;
include "util0.m";
	util: Util0;
	droptl, hasstr, rev, join, prefix, suffix, readfd, l2a, inssort, warn, fail: import util;
include "bdiff.m";
include "mercurial.m";
	hg: Mercurial;
	Dirstate, Dsfile, Revlog, Repo, Change, Manifest, Mfile, Entry, Config: import hg;
include "mercurialremote.m";

init()
{
	sys = load Sys Sys->PATH;
	bufio = load Bufio Bufio->PATH;
	bufio->open("/dev/null", Bufio->OREAD);
	str = load String String->PATH;
	tables = load Tables Tables->PATH;
	sh = load Sh Sh->PATH;
	sh->initialise();
	http = load Http Http->PATH;
	http->init(bufio);
	util = load Util0 Util0->PATH;
	util->init();
	hg = load Mercurial Mercurial->PATH;
	hg->init(1);
}

Remrepo.xnew(r: ref Repo, path: string): ref Remrepo
{
	if(prefix("http://", path) || prefix("https://", path)) {
		(u, err) := Url.unpack(path);
		if(err != nil)
			error(err);
		rr := ref Remrepo.Http (r, path, u);
		return rr;
	} else if(prefix("ssh://", path)) {
		s := path[len "ssh://":];
		host, user, port, dir: string;
		(host, dir) = str->splitstrl(s, "/");
		(a, b) := str->splitstrl(host, "@");
		if(b != nil) {
			user = a;
			host = b[1:];
		}
		(a, b) = str->splitstrr(host, ":");
		if(a != nil && b != nil) {
			host = a;
			port = b[1:];
		}
		if(prefix("/", dir))
			dir = dir[1:];
		say(sprint("remrepo, path %q, user %q, host %q, port %q, dir %q", path, user, host, port, dir));
		rr := ref Remrepo.Ssh (r, path, user, host, port, dir, nil, nil, nil);
		return rr;
	}

	error(sprint("unsupported remote repository path %#q", path));
	return nil; # not reached
}

Remrepo.xname(rr: self ref Remrepo): string
{
	pick r := rr {
	Http =>
		path := droptl(r.url.path, "/");
		return str->splitstrr(path, "/").t1;
	Ssh =>
		path := droptl(r.dir, "/");
		return str->splitstrr(path, "/").t1;
	}
}

httpcmd(r: ref Remrepo.Http, cmd: string, args: list of ref (string, string)): ref Sys->FD
{
say(sprint("httpget, cmd %q, args %s", cmd, argsfmt(args)));
	u := ref *r.url;
	u.query = sprint("?cmd=%s", http->encodequery(cmd));
	for(l := args; l != nil; l = tl l) {
		(k, v) := *hd l;
		u.query += sprint("&%s=%s", http->encodequery(k), http->encodequery(v));
	}
say(sprint("requesting url %#q", u.pack()));
	(nil, nil, fd, err) := http->get(u, ref Hdrs);
	if(err != nil)
		error(err);
	return fd;
}

httpget(r: ref Remrepo.Http, cmd: string, args: list of ref (string, string), max: int): string
{
	fd := httpcmd(r, cmd, args);
	buf := readfd(fd, max);
	if(buf == nil)
		error(sprint("reading response: %r"));
	s := string buf;
say(sprint("have response: %#q", s));
	return s;
}

xrun(l: list of string): (ref Sys->FD, ref Sys->FD)
{
say("xrun: "+join(l, " "));
	if(sys->pipe(tossh := array[2] of ref Sys->FD) != 0)
		error(sprint("pipe: %r"));
	if(sys->pipe(fromssh := array[2] of ref Sys->FD) != 0)
		error(sprint("pipe: %r"));
	spawn run0(l, tossh[1], fromssh[0]);
	return (tossh[0], fromssh[1]);
}

run0(l: list of string, in, out: ref Sys->FD)
{
	sys->pctl(Sys->NEWFD, list of {in.fd, out.fd, 2});
	sys->dup(in.fd, 0);
	sys->dup(out.fd, 1);
	in = out = nil;
	err := sh->run(nil, l);
	if(err != nil)
		warn(err);
}

sshensure(r: ref Remrepo.Ssh)
{
	if(r.tossh == nil) {
		(r.tossh, r.fromssh) = xrun(list of {"ssh", r.host, sprint("hg -R %s serve --stdio", r.dir)});
		r.b = bufio->fopen(r.fromssh, Bufio->OREAD);
		if(r.b == nil)
			error(sprint("fopen: %r"));
	}
}

sshcmd(r: ref Remrepo.Ssh, cmd: string, args: list of ref (string, string))
{
say(sprint("sshget, cmd %q, args %s", cmd, argsfmt(args)));
	sshensure(r);

	s := cmd+"\n";
	for(l := args; l != nil; l = tl l) {
		(k, v) := *hd l;
		s += sprint("%s %d\n%s", k, len v, v);
	}
	if(sys->fprint(r.tossh, "%s", s) < 0)
		error(sprint("write command: %r"));
}

sshget(r: ref Remrepo.Ssh, cmd: string, args: list of ref (string, string), n: int): string
{
	sshcmd(r, cmd, args);

	size := r.b.gets('\n');
	warn(sprint("from remote: %q", size));
	if(size == nil)
		error("eof from remote");
	if(size[len size-1] != '\n')
		error("bogus response, missing newline after size");
	(have, rem) := str->toint(size[:len size-1], 10);
	if(rem != nil)
		error("bogus response, size not a number");
	if(have > n)
		error(sprint("very long response, max %d, saw %d", n, have));
	nn := breadn(r.b, buf := array[have] of byte);
	if(nn < 0)
		error(sprint("reading response: %r"));
	if(nn != have)
		error(sprint("short response, expected %d, saw %d", have, nn));
	return string buf;
}

Remrepo.xlookup(rr: self ref Remrepo, revstr: string): string
{
	cmd := "lookup";
	args := list of {
		ref ("key", revstr),
	};

	s: string;
	pick r := rr {
	Http =>
		s = httpget(r, cmd, args, 8*1024);
	Ssh =>
		s = sshget(r, cmd, args, 8*1024);
	* =>
		raise "missing case";
	}

	if(prefix("0 ", s))
		error(s[2:]);
	if(!prefix("1 ", s))
		error(sprint("unexpected response to lookup: %#q", s));
	s = s[2:];
	if(suffix("\n", s))
		s = s[:len s-1];
	hg->xchecknodeid(s);
	return s;
}

Remrepo.xheads(rr: self ref Remrepo): list of string
{
	cmd := "heads";

	s: string;
	pick r := rr {
	Http =>
		s = httpget(r, cmd, nil, 8*1024);
	Ssh =>
		s = sshget(r, cmd, nil, 8*1024);
	* =>
		raise "missing case";
	}

	if(suffix("\n", s))
		s = s[:len s-1];
	l: list of string;
	while(s != nil) {
		n: string;
		(n, s) = str->splitstrl(s, " ");
		hg->xchecknodeid(n);
		l = n::l;
		if(s != nil)
			s = s[1:];
	}
	return l;
}

Remrepo.xcapabilities(rr: self ref Remrepo): list of string
{
	s: string;
	pick r := rr {
	Http =>
		s = httpget(r, "capabilities", nil, 8*1024);
	Ssh =>
		s = sshget(r, "hello", nil, 8*1024);
		if(s == nil)
			return nil;
		if(!prefix("capabilities: ", s))
			error(sprint("bad hello response, does not start with 'capabilities: ' (%q)", s));
		s = s[len "capabilities: ":];
		if(s != nil && s[len s-1] == '\n')
			s = s[:len s-1];
	* =>
		raise "missing case";
	}

say(sprint("xcapabilities, s %q", s));
	return sys->tokenize(s, " ").t1;
}

Remrepo.xbranches(rr: self ref Remrepo, nodes: list of string): list of ref (string, string, string, string)
{
	if(nodes == nil)
		error("no nodes specified");

	cmd := "branches";
	args := list of {
		ref ("nodes", join(nodes, " ")),
	};

	s: string;
	pick r := rr {
	Http =>
		s = httpget(r, cmd, args, 8*1024);
	Ssh =>
		s = sshget(r, cmd, args, 8*1024);
	* =>
		raise "missing case";
	}

	b: list of ref (string, string, string, string);
	while(s != nil) {
		ln: string;
		(ln, s) = str->splitstrl(s, "\n");
		if(s != nil)
			s = s[1:];
		if(len ln != 4*40+3)
			error(sprint("bad line for four nodeids: %#q", ln));
		t := l2a(sys->tokenize(ln, " ").t1);
		if(len t != 4)
			error(sprint("bad line for four nodeids: %#q", ln));
		tip := t[0];
		base := t[1];
		p1 := t[2];
		p2 := t[3];
		hg->xchecknodeid(tip);
		hg->xchecknodeid(base);
		hg->xchecknodeid(p1);
		hg->xchecknodeid(p2);
		if(!hasstr(nodes, tip))
			error(sprint("unrequested node %q returned", tip));
		b = ref (tip, base, p1, p2)::b;
	}
	return rev(b);
}

Remrepo.xbetween(rr: self ref Remrepo, pairs: list of ref (string, string)): list of list of string
{
	if(pairs == nil)
		error("no pairs specified");
	pairtups: list of string;
	for(l := pairs; l != nil; l = tl l) {
		(tip, base) := *hd l;
		hg->xchecknodeid(tip);
		hg->xchecknodeid(base);
		pairtups = (tip+"-"+base)::pairtups;
	}

	cmd := "between";
	args := list of {
		ref ("pairs", join(rev(pairtups), " ")),
	};

	s: string;
	pick r := rr {
	Http =>
		s = httpget(r, cmd, args, 8*1024);
	Ssh =>
		s = sshget(r, cmd, args, 8*1024);
	* =>
		raise "missing case";
	}

	rl: list of list of string;
	while(s != nil) {
		ln: string;
		(ln, s) = str->splitstrl(s, "\n");
		if(s != nil)
			s = s[1:];
		nl := sys->tokenize(ln, " ").t1;
		for(ll := nl; ll != nil; ll = tl ll)
			hg->xchecknodeid(hd ll);
		rl = nl::rl;
	}
	return rev(rl);
}

Remrepo.xchangegroup(rr: self ref Remrepo, roots: list of string): ref Sys->FD
{
	cmd := "changegroup";
	args := list of {
		ref ("roots", join(roots, " ")),
	};

	pick r := rr {
	Http =>
		fd := httpcmd(r, cmd, args);
		return fd;
	Ssh =>
		sshcmd(r, cmd, args);
		return r.fromssh;
	* =>
		raise "missing case";
	}
}

Remrepo.xchangegroupsubset(rr: self ref Remrepo, bases, heads: list of string): ref Sys->FD
{
	cmd := "changegroupsubset";
	args := list of {
		ref ("bases", join(bases, " ")),
		ref ("heads", join(heads, " ")),
	};
	pick r := rr {
	Http =>
		fd := httpcmd(r, cmd, args);
		return fd;
	Ssh =>
		sshcmd(r, cmd, args);
		return r.fromssh;
	* =>
		raise "missing case";
	}
}

Remrepo.iscompressed(rr: self ref Remrepo): int
{
	pick r := rr {
	Http =>	return 1;
	Ssh =>	return 0;
	}
}

breadn(b: ref Iobuf, buf: array of byte): int
{
	h := 0;
	while(h < len buf) {
		nn := b.read(buf[h:], len buf-h);
		if(nn < 0)
			return nn;
		if(nn == 0)
			break;
		h += nn;
	}
	return h;
}

argsfmt(l: list of ref (string, string)): string
{
	s := "";
	for(; l != nil; l = tl l) {
		(k, v) := *hd l;
		s += sprint(" %q=%q", k, v);
	}
	if(s != nil)
		s = s[1:];
	return s;
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
