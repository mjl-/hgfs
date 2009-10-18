implement Mercurialremote;

include "sys.m";
	sys: Sys;
	sprint: import sys;
include "bufio.m";
	bufio: Bufio;
include "string.m";
	str: String;
include "tables.m";
	tables: Tables;
	Strhash: import tables;
include "mhttp.m";
	http: Http;
	Url, Req, Resp, Hdrs: import http;
include "util0.m";
	util: Util0;
	droptl, hasstr, rev, join, prefix, suffix, readfd, l2a, inssort, warn, fail: import util;
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
	http = load Http Http->PATH;
	http->init(bufio);
	util = load Util0 Util0->PATH;
	util->init();
	hg = load Mercurial Mercurial->PATH;
	hg->init();
}

Remrepo.xnew(r: ref Repo, path: string): ref Remrepo
{
	if(prefix("http://", path) || prefix("https://", path)) {
		(u, err) := Url.unpack(path);
		if(err != nil)
			error(err);
		rr := ref Remrepo.Http (r, path, u);
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
	}
}

httpget(r: ref Remrepo.Http, query: string, max: int): string
{
	u := ref *r.url;
	u.query = query;
say(sprint("requesting url %#q", u.pack()));
	(nil, nil, fd, err) := http->get(u, ref Hdrs);
	if(err != nil)
		error(err);
	buf := readfd(fd, max);
	if(buf == nil)
		error(sprint("reading response: %r"));
	s := string buf;
say(sprint("have response: %#q", s));
	return s;
}

Remrepo.xlookup(rr: self ref Remrepo, revstr: string): string
{
	pick r := rr {
	Http =>
		s := httpget(r, sprint("?cmd=lookup&key=%s", http->encodequery(revstr)), 8*1024);
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
}

Remrepo.xheads(rr: self ref Remrepo): list of string
{
	pick r := rr {
	Http =>
		s := httpget(r, "?cmd=heads", 8*1024);
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
}

Remrepo.xcapabilities(rr: self ref Remrepo): list of string
{
	pick r := rr {
	Http =>
		s := httpget(r, "?cmd=capabilities", 8*1024);
		return sys->tokenize(s, " ").t1;
	}
}

Remrepo.xbranches(rr: self ref Remrepo, nodes: list of string): list of ref (string, string, string, string)
{
	pick r := rr {
	Http =>
		ns := "";
		for(l := nodes; l != nil; l = tl l) {
			n := hd l;
			hg->xchecknodeid(n);
			ns += "+"+n;
		}
		if(ns == nil)
			error("no nodes specified");
		ns = ns[1:];
		s := httpget(r, "?cmd=branches&nodes="+ns, 8*1024);
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
}

Remrepo.xbetween(rr: self ref Remrepo, pairs: list of ref (string, string)): list of list of string
{
	pick r := rr {
	Http =>
		qs := "";
		for(l := pairs; l != nil; l = tl l) {
			(tip, base) := *hd l;
			hg->xchecknodeid(tip);
			hg->xchecknodeid(base);
			qs += "+"+tip+"-"+base;
		}
		if(qs == nil)
			error("no pairs specified");
		qs = qs[1:];
		s := httpget(r, "?cmd=between&pairs="+qs, 8*1024);
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
	return nil;
}

Remrepo.xchangegroup(rr: self ref Remrepo, roots: list of string): ref Sys->FD
{
	pick r := rr {
	Http =>
		qs := "";
		for(l := roots; l != nil; l = tl l) {
			hg->xchecknodeid(hd l);
			qs += "+"+hd l;
		}
		if(qs != nil)
			qs = "&roots="+qs[1:];
		u := ref *r.url;
		u.query = "?cmd=changegroup"+qs;
say(sprint("requesting url %q", u.pack()));
		(nil, nil, fd, err) := http->get(u, ref Hdrs);
		if(err != nil)
			error(err);
		return fd;
	}
}

Remrepo.xchangegroupsubset(rr: self ref Remrepo, bases, heads: list of string): ref Sys->FD
{
	pick r := rr {
	Http =>
		qs := "?cmd=changegroupsubset";

		baseqs := "";
		for(l := bases; l != nil; l = tl l) {
			hg->xchecknodeid(hd l);
			baseqs += "+"+hd l;
		}
		if(baseqs != nil)
			qs += "&bases="+baseqs[1:];

		headqs := "";
		for(l = heads; l != nil; l = tl l) {
			hg->xchecknodeid(hd l);
			headqs += "+"+hd l;
		}
		if(headqs != nil)
			qs += "&heads="+headqs[1:];

		u := ref *r.url;
		u.query = qs;
say(sprint("requesting url %q", u.pack()));
		(nil, nil, fd, err) := http->get(u, ref Hdrs);
		if(err != nil)
			error(err);
		return fd;
	}
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
