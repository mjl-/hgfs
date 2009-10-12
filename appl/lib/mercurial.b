implement Mercurial;

include "sys.m";
	sys: Sys;
	sprint: import sys;
include "bufio.m";
	bufio: Bufio;
	Iobuf: import bufio;
include "filter.m";
	inflate: Filter;
include "keyring.m";
	keyring: Keyring;
	DigestState: import keyring;
include "string.m";
	str: String;
include "daytime.m";
	daytime: Daytime;
include "util0.m";
	util: Util0;
	max, l2a, readfile, writefile: import util;
include "mercurial.m";


Entrysize:	con 64;
Cachemax:	con 64;  # max number of cached items in a revlog

init()
{
	sys = load Sys Sys->PATH;
	bufio = load Bufio Bufio->PATH;
	bufio->open("/dev/null", Bufio->OREAD); # xxx ensure bufio is properly initialized
	keyring = load Keyring Keyring->PATH;
	str = load String String->PATH;
	daytime = load Daytime Daytime->PATH;
	inflate = load Filter Filter->INFLATEPATH;
	inflate->init();
	util = load Util0 Util0->PATH;
	util->init();
}

checknodeid(n: string): string
{
	{ xchecknodeid(n); return nil; } exception e { "hg:*" => return e[3:]; }
}

xchecknodeid(n: string)
{
	if(len n != 40)
		error(sprint("wrong nodeid length, len n %d != %d", len n, 40));
	for(i := 0; i < len n; i++)
		case n[i] {
		'0' to '9' or
		'a' to 'f' =>
			;
		* =>
			error(sprint("bad nodeid char %c in %q", n[i], n));
		}
}

createnodeid(d: array of byte, n1, n2: string): (string, string)
{
	{ return (xcreatenodeid(d, n1, n2), nil); } exception e { "hg:*" => return (nil, e[3:]); }
}

xcreatenodeid(d: array of byte, n1, n2: string): string
{
	if(n1 > n2)
		(n1, n2) = (n2, n1);
	(nn1, err1) := eunhex(n1);
	(nn2, err2) := eunhex(n2);
	if(err1 != nil)
		error(err1);
	if(err2 != nil)
		error(err2);
	
	st: ref DigestState;
	st = keyring->sha1(nn1[:20], 20, nil, st);
	st = keyring->sha1(nn2[:20], 20, nil, st);
	st = keyring->sha1(d, len d, nil, st);

	hash := array[Keyring->SHA1dlen] of byte;
	keyring->sha1(nil, 0, hash, st);
	return hex(hash);
}


differs(repo: ref Repo, size: big, mtime: int, mf: ref Manifestfile): int
{
	path := mf.path;
	(ok, dir) := sys->stat(path);
	if(ok != 0) {
		warn(sprint("stat %q: %r", path));
		return 1;
	}
	mfx := (mf.flags & Fexec) != 0;
	fx := (dir.mode & 8r100) != 0;
	if(mfx != fx)
		return 1;
	if(dir.length == size && dir.mtime == mtime)
		return 0;

	buf := readfile(path, -1);
	if(buf == nil) {
		warn(sprint("read %q: %r", path));
		return 1;
	}

	e, e1, e2: ref Entry;
	(rl, err) := repo.openrevlog(path);
	if(err == nil)
		(e, err) = rl.findnodeid(mf.nodeid);
	if(err == nil && e.p1 >= 0)
		(e1, err) = rl.find(e.p1);
	if(err == nil && e.p2 >= 0)
		(e2, err) = rl.find(e.p2);
	if(err != nil) {
		warn(sprint("%q: %s", path, err));
		return 1;
	}
	n1 := n2 := nullnode;
	if(e1 != nil)
		n1 = e1.nodeid;
	if(e2 != nil)
		n2 = e2.nodeid;
	n: string;
	(n, err) = createnodeid(buf, n1, n2);
	return err != nil || mf.nodeid != n;
}

getline(b: ref Iobuf): string
{
	l := b.gets('\n');
	if(l != nil && l[len l-1] == '\n')
		l = l[:len l-1];
	return l;
}

nullchange: Change;

Change.parse(data: array of byte, e: ref Entry): (ref Change, string)
{
	{ return (Change.xparse(data, e), nil); } exception ex { "hg:*" => return (nil, ex[3:]); }
}

Change.xparse(data: array of byte, e: ref Entry): ref Change
{
	c := ref nullchange;
	c.nodeid = e.nodeid;
	c.rev = e.rev;
	c.p1 = e.p1;
	c.p2 = e.p2;
	# p1 & p2 can be -1 for "no parent"

	b := bufio->aopen(data);

	l := getline(b);
	if(l == nil)
		error("missing manifest nodeid");
	err := checknodeid(l);
	if(err != nil)
		error(err);
	c.manifestnodeid = l;

	l = getline(b);
	if(l == nil)
		error("missing committer");
	c.who = l;

	l = getline(b);
	if(l == nil)
		error("missing timestamp");

	extrastr: string;
	(t, tzoff) := str->splitstrl(l, " ");
	if(tzoff != nil)
		(tzoff, extrastr) = str->splitstrl(tzoff[1:], " ");
	if(tzoff == nil || str->drop(t, "0-9") != nil || str->drop(t, "0-9-") != nil)
		error("invalid timestamp/timezone");
	c.when = int t;
	c.tzoff = int tzoff[1:];

	if(extrastr != nil)
		extrastr = extrastr[1:];
	while(extrastr != nil) {
		k, v: string;
		(k, extrastr) = str->splitstrl(extrastr, ":");
		if(extrastr == nil)
			error(sprint("bad extra, only key"));
		(v, extrastr) = str->splitstrl(extrastr[1:], "\0");
		if(extrastr != nil)
			extrastr = extrastr[1:];
		c.extra = (k, v)::c.extra;
	}

	for(;;) {
		l = getline(b);
		if(l == nil)
			break;
		c.files = l::c.files;
	}
	c.files = util->rev(c.files);

	d := array[0] of byte;
	for(;;) {
		n := b.read(buf := array[1024] of byte, len buf);
		if(n == 0)
			break;
		if(n < 0)
			error("reading message");
		nd := array[len d+n] of byte;
		nd[:] = d;
		nd[len d:] = buf[:n];
		d = nd;
	}
	c.msg = string d;

	return c;
}

Change.findextra(c: self ref Change, k: string): (string, string)
{
	for(l := c.extra; l != nil; l = tl l)
		if((hd l).t0 == k)
			return hd l;
	return (nil, nil);
}

Change.text(c: self ref Change): string
{
	s := "";
	s += sprint("revision: %d %q\n", c.rev, c.nodeid);
	pstr := "";
	if(c.p1 == -1 && c.p2 == -1)
		pstr = "  none";
	if(c.p1 != -1)
		pstr += ", "+string c.p1;
	if(c.p2 != -1)
		pstr += ", "+string c.p2;
	s += "parents: "+pstr[2:]+"\n";
	s += sprint("manifest nodeid: %q\n", c.manifestnodeid);
	s += sprint("committer: %s\n", c.who);
	when := daytime->gmt(c.when);
	when.tzoff = c.tzoff;
	(nil, v) := c.findextra("branch");
	if(v != nil)
		s += sprint("branch: %q\n", v);
	s += sprint("date: %s; %d %d\n", daytime->text(when), c.when, c.tzoff);
	s += sprint("files changed:\n");
	for(l := c.files; l != nil; l = tl l)
		s += sprint("%s\n", hd l);
	s += sprint("\n");
	s += sprint("%s\n", c.msg);
	return s;
}


split(buf: array of byte, b: byte): (array of byte, array of byte)
{
	for(i := 0; i < len buf; i++)
		if(buf[i] == b)
			return (buf[:i], buf[i+1:]);
	return (buf, array[0] of byte);
}

Manifest.parse(d: array of byte, n: string): (ref Manifest, string)
{
	{ return (Manifest.xparse(d, n), nil); } exception e { "hg:*" => return (nil, e[3:]); }
}

Manifest.xparse(d: array of byte, n: string): ref Manifest
{
	files: list of ref Manifestfile;

	line: array of byte;
	while(len d > 0) {
		(line, d) = split(d, byte '\n');
		(path, nodeid) := split(line, byte '\0');
		flags := 0;
		if(len nodeid > 40) {
			case flagstr := string nodeid[40:] {
			"l" =>	flags = Flink;
			"x" =>	flags = Fexec;
			"lx" or
			"xl" =>	flags = Flink|Fexec;
			* =>	error(sprint("unknown flags: %q", flagstr));
			}
			nodeid = nodeid[:40];
			#say(sprint("manifest flags=%x", flags));
		}
		# say(sprint("nodeid=%q path=%q", string nodeid, string path));
		mf := ref Manifestfile(string path, 0, string nodeid, flags);
		files = mf::files;
	}
	files = util->rev(files);
	return ref Manifest(n, files);
}

Manifest.find(m: self ref Manifest, path: string): ref Manifestfile
{
	for(l := m.files; l != nil; l = tl l)
		if((hd l).path == path)
			return hd l;
	return nil;
}

xreopen(rl: ref Revlog)
{
	# test whether we need to reread index files
	(ok, dir) := sys->fstat(rl.ifd);
	if(ok < 0)
		error(sprint("%r"));
	if(dir.length == rl.ilength && dir.mtime == rl.imtime)
		return;

say(sprint("revlog, reopen, path %q", rl.path));

	# reread the index file.  we also get here for the first open of the revlog.
	# instead of rereading everything, we could continue at where we left.
	# as long as isreadonly didn't change that is.  maybe later.
	ib := bufio->fopen(rl.ifd, Bufio->OREAD);
	if(ib == nil)
		error(sprint("fopen: %r"));
	ib.seek(big 0, Bufio->SEEKSTART);

	if(breadn(ib, buf := array[4] of byte, len buf) != len buf)
		error(sprint("reading revlog version & flags: %r"));

	rl.flags = g16(buf, 0).t0;
	rl.version = g16(buf, 2).t0;
	if(rl.version != Version1)
		error(sprint("revlog not version1 ('ng') but %d, not supported", rl.version));
	rl.bd = nil;
	rl.dfd = nil;
	if(!isindexonly(rl)) {
		dpath := rl.path+".d";
		rl.dfd = sys->open(dpath, Sys->OREAD);
		if(rl.dfd == nil)
			error(sprint("open %q: %r", dpath));
		# xxx verify .d file is as expected?
	}

	xreadrevlog(rl, ib);
	rl.ilength = dir.length;
	rl.imtime = dir.mtime;
}

# read through the entire revlog, store all entries in rl.entries.
# revlog's are usually very small.
xreadrevlog(rl: ref Revlog, ib: ref Iobuf)
{
	indexonly := isindexonly(rl);

	ib.seek(big 0, Bufio->SEEKSTART);

	l: list of ref Entry;
	eb := array[Entrysize] of byte;
	for(;;) {
		n := breadn(ib, eb, len eb);
		if(n == 0)
			break;
		if(n < 0)
			error(sprint("reading entry: %r"));
		if(n != len eb)
			error(sprint("short entry"));

		e := Entry.xparse(eb, len l);

		# no .d file, the data for an entry comes directly after the entry.
		# so skip over it for the next iteration of this loop
		if(indexonly) {
			e.ioffset = ib.offset();
			if(ib.seek(big e.csize, Bufio->SEEKRELA) != e.ioffset+big e.csize)
				error(sprint("seek: %r"));
		}

		l = e::l;
	}
	rl.ents = l2a(util->rev(l));
	rl.cache = array[len rl.ents] of array of byte;
	rl.ncache = 0;
	rl.full = nil;
	rl.fullrev = -1;
say(sprint("readrevlog, len ents %d", len rl.ents));
}


Revlog.xopen(path: string, cacheall: int): ref Revlog
{
	say(sprint("revlog.open %q", path));
	rl := ref Revlog;
	rl.path = path;
	rl.fullrev = -1;
	rl.cacheall = cacheall;

	# we keep ifd open at all times.  we'll need it if this revlog isindexonly and we need to read data parts.
	rl.ifd = sys->open(path+".i", Sys->OREAD);
	if(rl.ifd == nil)
		error(sprint("open %q: %r", path+".i"));

	rl.ilength = ~big 0;
	rl.imtime = ~0;
	xreopen(rl);
	return rl;
}

isindexonly(rl: ref Revlog): int
{
	return rl.flags & Indexonly;
}

Revlog.isindexonly(rl: self ref Revlog): int
{
	{ 
		xreopen(rl);
	} exception {
	"hg:*" =>	;
	}
	return rl.flags & Indexonly;
}

xreconstruct(rl: ref Revlog, e: ref Entry, base: array of byte, patches: array of array of byte): array of byte
{
say(sprint("reconstruct, len base %d, len patches %d, e.rev %d", len base, len patches, e.rev));

	# first is base, later are patches
	d := Patch.xapplymany(base, patches);

	# verify data is correct
	pn1 := pn2 := nullnode;
	if(e.p1 >= 0)
		pn1 = rl.ents[e.p1].nodeid;
	if(e.p2 >= 0)
		pn2 = rl.ents[e.p2].nodeid;

	n := xcreatenodeid(d, pn1, pn2);
	if(n != e.nodeid)
		error(sprint("nodeid mismatch, have %q, header claims %q, (p1 %q p2 %q, len %d, entry %s)", n, e.nodeid, pn1, pn2, len d, e.text()));
	rl.fullrev = e.rev;
	rl.full = d;
	return d;
}

xdecompress(d: array of byte): array of byte
{
	if(len d == 0)
		return d;
	# may be compressed, first byte will tell us.
	case int d[0] {
	'u' =>	return d[1:];
	0 =>	return d;
	* =>	return xinflatebuf(d);
	}
}

xgetdata(rl: ref Revlog, e: ref Entry): array of byte
{
	if(rl.cache[e.rev] != nil) {
		#say(sprint("getdata, rev %d from cache", e.rev));
		return rl.cache[e.rev];
	}

	#say(sprint("getdata, getting fresh data for rev %d", e.rev));
	if(rl.bd == nil) {
		fd := rl.dfd;
		if(rl.isindexonly())
			fd = rl.ifd;
		rl.bd = bufio->fopen(fd, Bufio->OREAD);
	}

	if(rl.bd.seek(e.ioffset, Bufio->SEEKSTART) != e.ioffset)
		error(sprint("seek %bd: %r", e.ioffset));
	if(breadn(rl.bd, buf := array[e.csize] of byte, len buf) != len buf)
		error(sprint("read: %r"));
	#say(sprint("getdata, %d compressed bytes for rev %d", len buf, e.rev));
	buf = xdecompress(buf);
	#say(sprint("getdata, %d decompressed bytes for rev %d", len buf, e.rev));

	if(!rl.cacheall)
	for(i := 0; rl.ncache >= Cachemax && i < len rl.cache; i++)
		if(rl.cache[i] != nil) {
			rl.cache[i] = nil;
			rl.ncache--;
		}
	rl.cache[e.rev] = buf;
	rl.ncache++;
	return buf;
}

# fetch data to reconstruct the entry.
# the head of the result is the base of the data, the other buffers are the delta's
xgetbufs(rl: ref Revlog, e: ref Entry): array of array of byte
{
	#say(sprint("getbufs, rev %d, base %d, fullrev %d", e.rev, e.base, rl.fullrev));
	usefull := rl.fullrev > e.base && rl.fullrev <= e.rev;
	base := e.base;
	if(usefull)
		base = rl.fullrev;

	bufs := array[e.rev+1-base] of array of byte;
	bufs[:] = rl.cache[base:e.rev+1];
	if(usefull)
		bufs[0] = rl.full;

	for(i := base; i <= e.rev; i++)
		if(bufs[i-base] == nil)
			bufs[i-base] = xgetdata(rl, rl.ents[i]);
	return bufs;
}

ismeta(d: array of byte): int
{
	return len d >= 2 && d[0] == byte 1 && d[1] == byte '\n';
}

line(d: array of byte, s, e: int): int
{
	while(s < e && d[s] != byte '\n')
		s++;
	return s;
}

getmeta(d: array of byte): list of (string, string)
{
	l: list of (string, string);
	if(!ismeta(d))
		return l;

	s := 2;
	e := 2;
	while(!ismeta(d[e:]))
		e++;
	while(s < e) {
		o := line(d, s, e);
		(k, v) := str->splitstrl(string d[s:o], ": ");
		if(v != nil)
			v = v[2:];
		s = o;
		if(s < e && d[s] == byte '\n')
			s++;
		l = (k, v)::l;
	}
	return l;
}

dropmeta(d: array of byte): array of byte
{
	getmeta(d);
	i := 0;
	if(len d >= 2 && d[0] == byte 1 && d[1] == byte '\n') {
		for(i = 2; i < len d; i++) {
			if(d[i] == byte 1 && i+1 < len d && d[i+1] == byte '\n') {
				i += 2;
				break;
			}
		}
	}
	return d[i:];
}

# return the revision data, without meta-data
xget(rl: ref Revlog, e: ref Entry, withmeta: int): array of byte
{
	if(e.rev == rl.fullrev) {
		#say(sprint("get, using cache for rev %d", e.rev));
		d := rl.full;
		if(!withmeta)
			d = dropmeta(d);
		return d;
	}

	#say(sprint("get, going to reconstruct for rev %d", e.rev));
	bufs := xgetbufs(rl, e);
	d := xreconstruct(rl, e, bufs[0], bufs[1:]);
	if(!withmeta)
		d = dropmeta(d);
	return d;
}

xgetlength(rl: ref Revlog, e: ref Entry): big
{
	return big len xget(rl, e, 0);
}

Revlog.xget(rl: self ref Revlog, rev: int): array of byte
{
	e := rl.xfind(rev);
	return xget(rl, e, 0);
}

Revlog.xgetnodeid(rl: self ref Revlog, n: string): array of byte
{
	e := rl.xfindnodeid(n);
	return rl.xget(e.rev);
}


# create delta from prev to rev.  prev may be -1.
# the typical and easy case is that prev is rev predecessor, and we can use the delta from the revlog.
# otherwise we'll have to create a patch.  for prev -1 this simply means making
# a patch with the entire file contents.
# for prev >= 0, we should generate a patch.  instead, for now we'll patch over the entire file.
# xxx
Revlog.xdelta(rl: self ref Revlog, prev, rev: int): array of byte
{
	#say(sprint("delta, prev %d, rev %d", prev, rev));
	e := rl.xfind(rev);

	if(prev != -1 && prev == e.rev-1 && e.base != e.rev) {
		#say(sprint("matching delta, e %s", e.text()));
		return xgetdata(rl, e);
	}

	#say("creating new delta with full contents");
	buf := xget(rl, e, 1);
	obuflen := 0;
	if(prev >= 0) {
		pe := rl.xfind(prev);
		obuflen = pe.uncsize;
	}
	#say(sprint("delta with full contents, start %d end %d size %d, e %s", 0, obuflen, len buf, e.text()));
	delta := array[3*4+len buf] of byte;
	o := 0;
	o = p32(delta, o, 0); # start
	o = p32(delta, o, obuflen); # end
	o = p32(delta, o, len buf); # size
	delta[o:] = buf;
	return delta;
}

Revlog.xlength(rl: self ref Revlog, rev: int): big
{
	xreopen(rl);
	return xgetlength(rl, rl.ents[rev]);
}

Revlog.xfind(rl: self ref Revlog, rev: int): ref Entry
{
	xreopen(rl);

	# looking for last entry
	# xxx is this really needed?
	if(rev < 0)
		return rl.ents[len rl.ents-1];
	if(rev >= len rl.ents)
		error(sprint("unknown revision %d", rev));
	return rl.ents[rev];
}


Revlog.xfindnodeid(rl: self ref Revlog, n: string): ref Entry
{
	xreopen(rl);
	for(i := 0; i < len rl.ents; i++)
		if(rl.ents[i].nodeid == n)
			return rl.ents[i];
	error(sprint("no nodeid %q", n));
	return nil; # not reached
}

Revlog.xlastrev(rl: self ref Revlog): int
{
	xreopen(rl);
	return len rl.ents-1;
}

Revlog.xentries(rl: self ref Revlog): array of ref Entry
{
	xreopen(rl);
	ents := array[len rl.ents] of ref Entry;
	ents[:] = rl.ents;
	return ents;
}

Revlog.xpread(rl: self ref Revlog, rev: int, n: int, off: big): array of byte
{
	d := rl.xget(rev);
	if(off > big len d)
		off = big len d;
	if(off+big n > big len d)
		n = int (big len d-off);
	d = d[int off:int off+n];
	return d;
}


Repo.xopen(path: string): ref Repo
{
	say("repo.open");

	reqpath := path+"/requires";
	b := bufio->open(reqpath, Bufio->OREAD);
	if(b == nil)
		error(sprint("repo \"requires\" file: %r"));
	requires: list of string;
	for(;;) {
		l := b.gets('\n');
		if(l == nil)
			break;
		if(l[len l-1] == '\n')
			l = l[:len l-1];
		requires = l::requires;
	}

	namepath := path+"/..";
	(ok, dir) := sys->stat(namepath);
	if(ok != 0)
		error(sprint("stat %q: %r", namepath));
	name := dir.name;

	repo := ref Repo (path, requires, name, -1, -1, nil, nil);
	if(repo.isstore() && !isdir(path+"/store"))
		error("missing directory \".hg/store\"");
	if(!repo.isstore() && !isdir(path+"/data"))
		error("missing directory \".hg/data\"");
	say(sprint("have repo, path %q", path));
	return repo;
}

Repo.xfind(path: string): ref Repo
{
	if(path == nil)
		path = workdir();

	while(path != nil) {
		while(path != nil && path[len path-1] == '/')
			path = path[:len path-1];

		hgpath := path+"/.hg";
		if(exists(hgpath))
			return Repo.xopen(hgpath);

		(path, nil) = str->splitstrr(path, "/");
	}
	error("no repo found");
	return nil; # not reached
}

Repo.name(r: self ref Repo): string
{
	return r.reponame;
}

Repo.isstore(r: self ref Repo): int
{
	return has(r.requires, "store");
}

Repo.isrevlogv1(r: self ref Repo): int
{
	return has(r.requires, "revlogv1");
}

Repo.escape(r: self ref Repo, path: string): string
{
	if(!r.isstore())
		return path;

	fa := array of byte path;
	res: string;
	for(i := 0; i < len fa; i++) {
		case int fa[i] {
		'_' =>
			res += "__";
		'A' to 'Z' =>
			res[len res] = '_';
			res[len res] = int fa[i]+'a'-'A';
		126 to 255 or '\\' or ':' or '*' or '?' or '"' or '<' or '>' or '|' =>
			res[len res] = '~';
			res += sprint("%02x", int fa[i]);
		* =>
			res[len res] = int fa[i];
		}
	}
	return res;
}

Repo.xunescape(r: self ref Repo, path: string): string
{
	if(!r.isstore())
		return path;

	p := array of byte path;
	ps := 0;
	pe := len p;
	s := array[len p] of byte;
	ns := 0;
	while(ps < pe)
		case c := int p[ps++] {
		'_' =>
			if(ps == pe)
				error("name ends with underscore");
			case cc := int path[ps++] {
			'_' =>
				s[ns++] = byte '_';
			'a' to 'z' =>
				s[ns++] = byte (cc-'a'+'A');
			* =>
				error(sprint("bad underscored character %c (%#x)", cc, cc));
			}

		'~' =>
			if(pe-ps < 2)
				error("missing chars after ~");
			{
				s[ns++] = (unhexchar(int p[ps])<<4) | unhexchar(int p[ps+1]);
				ps += 2;
			} exception {
			"unhexchar:*" =>
				error("bad hex chars after ~");
			}

		127 to 255 or '\\' or ':' or '*' or '?' or '"' or '<' or '>' or '|' =>
			error(sprint("invalid character %c (%#x)", c, c));

		* =>
			s[ns++] = byte c;
		}
	return string s[:ns];
}

Repo.storedir(r: self ref Repo): string
{
	path := r.path;
	if(r.isstore())
		path += "/store";
	return path;
}

Repo.xopenrevlog(r: self ref Repo, path: string): ref Revlog
{
	path = r.storedir()+"/data/"+r.escape(path);
	return Revlog.xopen(path, 0);
}


Repo.xmanifest(r: self ref Repo, rev: int): (ref Change, ref Manifest)
{
	say("repo.manifest");
	cl := r.xchangelog();
	ce := cl.xfind(rev);
	cd := cl.xget(rev);
	c := Change.xparse(cd, ce);
	ml := r.xmanifestlog();
	md := ml.xgetnodeid(c.manifestnodeid);
	m := Manifest.xparse(md, c.manifestnodeid);
	return (c, m);
}

Repo.xlastrev(r: self ref Repo): int
{
	cl := r.xchangelog();

	(ok, d) := sys->fstat(cl.ifd);
	if(ok != 0)
		error(sprint("fstat changelog index: %r"));

	if(r.lastrevision >= 0 && d.mtime <= r.lastmtime)
		return r.lastrevision;

	rev := cl.xlastrev();
	r.lastrevision = rev;
	r.lastmtime = d.mtime;
	return rev;
}

Repo.xchange(r: self ref Repo, rev: int): ref Change
{
	cl := r.xchangelog();
	ce := cl.xfind(rev);
	cd := cl.xget(rev);
	return Change.xparse(cd, ce);
}

Repo.xmtime(r: self ref Repo, rl: ref Revlog, rev: int): int
{
	e := rl.xfind(rev);
	c := r.xchange(e.link);
	return c.when+c.tzoff;
}

Repo.xdirstate(r: self ref Repo): ref Dirstate
{
	path := r.path+"/dirstate";
	b := bufio->open(path, Bufio->OREAD);
	if(b == nil)
		error(sprint("open %q: %r", path));

	n1 := b.read(p1 := array[20] of byte, len p1);
	n2 := b.read(p2 := array[20] of byte, len p2);
	if(n1 != len p1 || n2 != len p2)
		error(sprint("reading parents: %r"));

	buf := array[1+4+4+4+4] of byte;
	l: list of ref Dirstatefile;
	for(;;) {
		off := b.offset();
		n := b.read(buf, len buf);
		if(n == 0)
			break;
		if(n != len buf)
			error(sprint("bad dirstate, early eof for path header, want %d, saw %d", len buf, n));
		dsf := ref Dirstatefile;
		o := 0;
		stb := buf[o++];
		dsf.state = find(statestrs, sprint("%c", int stb));
		if(dsf.state < 0)
			error(sprint("bad state in dirstate at offset %bd, char %#x, %c", off, int stb, int stb));
		(dsf.mode, o) = g32(buf, o);
		(dsf.size, o) = g32(buf, o);
		(dsf.mtime, o) = g32(buf, o);
		length: int;
		(length, o) = g32(buf, o);
		if(length >= 2*1024)
			error(sprint("implausible path length %d in dirstate", length));
		n = b.read(namebuf := array[length] of byte, len namebuf);
		if(n != len namebuf)
			error("early eof in dirstate while reading path");
		dsf.path = string namebuf;
		for(nul := 0; nul < len namebuf; nul++)
			if(namebuf[nul] == byte '\0') {
				dsf.path = string namebuf[:nul];
				dsf.origpath = string namebuf[nul+1:];
				break;
			}
		l = dsf::l;
	}
	ds := ref Dirstate (hex(p1), hex(p2), util->rev(l));
	return ds;
}

Dirstate.packedsize(ds: self ref Dirstate): int
{
	n := 20+20;
	for(l := ds.l; l != nil; l = tl l) {
		f := hd l;
		n += 1+4+4+4+4+len array of byte f.path;
		if(f.origpath != nil)
			n += 1+len array of byte f.origpath;
	}
	return n;
}

Dirstate.pack(ds: self ref Dirstate, buf: array of byte)
{
	o := 0;
	buf[o:] = unhex(ds.p1);
	o += 20;
	buf[o:] = unhex(ds.p2);
	o += 20;
	for(l := ds.l; l != nil; l = tl l) {
		f := hd l;
		buf[o++] = byte statestrs[f.state][0];
		o = p32(buf, o, f.mode);
		o = p32(buf, o, f.size);
		o = p32(buf, o, f.mtime);
		path := f.path;
		if(f.origpath != nil)
			path += "\0"+f.origpath;
		pathbuf := array of byte path;
		o = p32(buf, o, len pathbuf);
		buf[o:] = pathbuf;
		o += len pathbuf;
	}
}

Repo.xwritedirstate(r: self ref Repo, ds: ref Dirstate)
{
	n := ds.packedsize();
	ds.pack(buf := array[n] of byte);
	path := r.path+"/dirstate";
	fd := sys->create(path, Sys->OWRITE|Sys->OTRUNC, 8r666);
	if(fd == nil)
		error(sprint("create %q: %r", path));
	if(sys->write(fd, buf, len buf) != len buf)
		error(sprint("write %q: %r", path));
}

Repo.xworkbranch(r: self ref Repo): string
{
	buf := readfile(r.path+"/branch", 1024);
	if(buf == nil)
		error(sprint("%r"));
	b := string buf;
	if(b != nil && b[len b-1] == '\n')
		b = b[:len b-1];
	return b;
}

Repo.xwriteworkbranch(r: self ref Repo, branch: string)
{
	err := writefile(r.path+"/branch", 1, array of byte (branch+"\n"));
	if(err != nil)
		error(err);
}

Repo.workroot(r: self ref Repo): string
{
	return r.path[:len r.path-len "/.hg"];
}

Repo.xtags(r: self ref Repo): list of ref Tag
{
	cl := r.xchangelog();
	ents := cl.xentries();
	if(len ents == 0)
		return nil;
	e := ents[len ents-1];
	(buf, err) := r.get(e.nodeid, ".hgtags");
	if(err != nil)
		return nil;
	return xparsetags(r, string buf);
}

Repo.xrevtags(r: self ref Repo, revstr: string): list of ref Tag
{
	(rev, n) := r.xlookup(revstr);
	if(n == nil)
		error("no such revision");

	cl := r.xchangelog();
	ents := cl.xentries();

	el: list of ref Entry;
	for(i := 0; i < len ents; i++) {
		e := ents[i];
		if(e.p1 == rev || e.p2 == rev)
			el = e::el;
	}

	tags: list of ref Tag;
	for(; el != nil; el = tl el) {
		e := hd el;
		(buf, err) := r.get(e.nodeid, ".hgtags");
		if(err != nil)
			continue;
		l := xparsetags(r, string buf);
		for(; l != nil; l = tl l) {
			t := hd l;
			if(t.n == n)
				tags = t::tags;
		}
	}
	return tags;
}

parsetags(r: ref Repo, s: string): (list of ref Tag, string)
{
	{ return (xparsetags(r, s), nil); } exception e { "hg:*" => return (nil, e[3:]); }
}

xparsetags(r: ref Repo, s: string): list of ref Tag
{
	cl := r.xchangelog();

	l: list of ref Tag;
	while(s != nil) {
		ln: string;
		(ln, s) = str->splitstrl(s, "\n");
		if(s == nil || s[0] != '\n')
			error(sprint("missing newline in .hgtags: %s", s));
		if(s != nil)
			s = s[1:];
		t := sys->tokenize(ln, " ").t1;
		if(len t != 2)
			error(sprint("wrong number of tokes in .hgtags: %s", s));

		name := hd tl t;
		n := hd t;
		xchecknodeid(n);
		e := cl.xfindnodeid(n);
		l = ref Tag (name, n, e.rev)::l;
	}
	return util->rev(l);
}

branchupdate(l: list of ref Branch, branch: string, e: ref Entry): list of ref Branch
{
	for(t := l; t != nil; t = tl t) {
		b := hd t;
		if(b.name == branch) {
			b.rev = e.rev;
			b.n = e.nodeid;
			return t;
		}
	}
	t = ref Branch (branch, e.nodeid, e.rev)::t;
	return t;
}

Repo.xbranches(r: self ref Repo): list of ref Branch
{
say("repo.branches");
	path := r.path+"/branch.cache";
	b := bufio->open(path, Bufio->OREAD);
	# b nil is okay, we're sure not to read from it if so below

	cl := r.xchangelog();

	# first line has nodeid+revision of tip.  used for seeing if the cache is up to date.
	l: list of ref Branch;
	i := 0;
	lastcacherev := 0;
	for(;; i++) {
		if(b == nil)
			break;

		s := b.gets('\n');
		if(s == nil)
			break;
		if(s[len s-1] != '\n')
			error(sprint("missing newline in branch.cache: %s", s));
		s = s[:len s-1];
		toks := sys->tokenize(s, " ").t1;
		if(len toks != 2)
			error(sprint("wrong number of tokes in branch.cache: %s", s));

		if(i == 0) {
			lastcacherev = int hd tl toks;
			continue;
		}

		name := hd tl toks;
		n := hd toks;
		xchecknodeid(n);
		e := cl.xfindnodeid(n);
		l = ref Branch (name, n, e.rev)::l;
	}

	# for missing branch entries, read the changelog
	lrev := r.xlastrev();
	for(lastcacherev++; lastcacherev <= lrev; lastcacherev++) {
		c := r.xchange(lastcacherev);
		(nil, v) := c.findextra("branch");
		say(sprint("branch in rev %d: %q", lastcacherev, v));
		if(v != nil) {
			ce := cl.xfind(lastcacherev);
			l = branchupdate(l, v, ce);
		}
	}

	# if no branches, fake one
	if(l == nil && len cl.ents > 0) {
		rev := cl.xlastrev();
		e := cl.xfind(rev);
		l = ref Branch ("default", e.nodeid, e.rev)::l;
	}
	return util->rev(l);
}

Repo.xheads(r: self ref Repo): array of ref Entry
{
	cl := r.xchangelog();
	a := cl.xentries();

	for(i := 0; i < len a; i++) {
		e := a[i];
		if(e.p1 >= 0)
			a[e.p1] = nil;
		if(e.p2 >= 0)
			a[e.p2] = nil;
	}

	hl: list of ref Entry;
	for(i = 0; i < len a; i++)
		if(a[i] != nil)
			hl = a[i]::hl;
	return l2a(util->rev(hl));
}

Repo.xchangelog(r: self ref Repo): ref Revlog
{
	if(r.cl == nil)
		r.cl = Revlog.xopen(r.storedir()+"/00changelog", 0);
	return r.cl;
}

Repo.xmanifestlog(r: self ref Repo): ref Revlog
{
	if(r.ml == nil)
		r.ml = Revlog.xopen(r.storedir()+"/00manifest", 0);
	return r.ml;
}

Repo.xlookup(r: self ref Repo, s: string): (int, string)
{
	if(s == "null")
		return (-1, nullnode);

	cl := r.xchangelog();
	ents := cl.xentries();

	if(s == "tip" || s == ".") {
		e := ents[len ents-1];
		return (e.rev, e.nodeid);
	}

	# try as revision number
	(rev, rem) := str->toint(s, 10);
	if(rem == nil && s != nil) {
		if(rev < 0) {
			rev = len ents-1+rev;
			if(rev < 0)
				return (-1, nil);
		}
		if(rev >= len ents)
			return (-1, nil);
		return (rev, ents[rev].nodeid);
	}

	# try exact nodeid match
	if(len s == 40) {
		err := checknodeid(s);
		if(err == nil) {
			e := cl.xfindnodeid(s);
			return (e.rev, e.nodeid);
		}
	}

	# try as nodeid
	m: ref Entry;
	for(i := 0; i < len ents; i++)
		if(str->prefix(s, ents[i].nodeid)) {
			if(m != nil)
				return (-1, nil); # ambiguous
			m = ents[i];
		}
	if(m != nil)
		return (m.rev, m.nodeid);

	# try as tag
	for(l := r.xtags(); l != nil; l = tl l)
		if((hd l).name == s)
			return ((hd l).rev, (hd l).n);

	# try as branch
	for(b := r.xbranches(); b != nil; b = tl b)
		if((hd b).name == s)
			return ((hd b).rev, (hd b).n);

	return (-1, nil);
}

Repo.xget(r: self ref Repo, revstr, path: string): array of byte
{
	(rev, n) := r.xlookup(revstr);
	if(n == nil)
		error("no such revision");
	(nil, m) := r.xmanifest(rev);
	mf := m.find(path);
	if(mf == nil)
		error(sprint("file %#q not in revision %q", path, revstr));
	rl := r.xopenrevlog(path);
	return rl.xgetnodeid(mf.nodeid);
}


find(a: array of string, e: string): int
{
	for(i := 0; i < len a; i++)
		if(a[i] == e)
			return i;
	return -1;
}

statestrs := array[] of {
"n", "m", "r", "a", "?",
};
statestr(i: int): string
{
	if(i >= 0 && i < len statestrs)
		return statestrs[i];
	return "X";
}

Dirstatefile.text(f: self ref Dirstatefile): string
{
	tm := daytime->local(daytime->now());
	timestr := sprint("%04d-%02d-%02d %2d:%2d:%2d", tm.year+1900, tm.mon+1, tm.mday, tm.hour, tm.min, tm.sec);
	s := sprint("%s %03uo %10d %s %q", statestr(f.state), 8r777&f.mode, f.size, timestr, f.path);
	if(f.origpath != nil)
		s += sprint(" (from %q)", f.origpath);
	return s;
}


Hunk.text(h: self ref Hunk): string
{
	return sprint("<hunk s=%d e=%d length=%d buf=%q>", h.start, h.end, len h.buf, string h.buf);
	#return sprint("<hunk s=%d e=%d length=%d>", h.start, h.end, len h.buf);
}

Patch.apply(p: self ref Patch, b: array of byte): array of byte
{
	n := len b+p.sizediff();
	d := array[n] of byte;
	ae := be := 0;
	for(l := p.l; l != nil; l = tl l) {
		h := hd l;

		# copy data before hunk from base to dest
		d[be:] = b[ae:h.start];
		be += h.start-ae;

		# copy new data to dest, and skip the removed part from base
		d[be:] = h.buf;
		be += len h.buf;
		ae = h.end;
	}
	# and the trailing common data
	d[be:] = b[ae:];
	return d;
}

Group: adt {
	l:	list of array of byte;
	length:	int;	# original length of group
	o:	int;	# offset of hd l

	add:	fn(g: self ref Group, buf: array of byte);
	copy:	fn(g: self ref Group, sg: ref Group, s, e: int);
	flatten:	fn(g: self ref Group): array of byte;
	size:	fn(g: self ref Group): int;
	apply:	fn(g: ref Group, p: ref Patch): ref Group;
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
Group.apply(g: ref Group, p: ref Patch): ref Group
{
	g = ref *g;
	ng := ref Group (nil, 0, 0);
	o := 0;
	for(l := p.l; l != nil; l = tl l) {
		h := hd l;
		ng.copy(g, o, h.start);
		ng.add(h.buf);
		o = h.end;
	}
	ng.copy(g, o, g.size());
	ng.l = util->rev(ng.l);
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

Patch.applymany(base: array of byte, patches: array of array of byte): (array of byte, string)
{
	{ return (Patch.xapplymany(base, patches), nil); } exception e { "hg:*" => return (nil, e[3:]); };
}

Patch.xapplymany(base: array of byte, patches: array of array of byte): array of byte
{
	if(len patches == 0)
		return base;

	g := ref Group (base::nil, len base, 0);
	for(i := 0; i < len patches; i++) {
		p := Patch.xparse(patches[i]);
		{
			g = Group.apply(g, p);
		} exception e {
		"group:*" =>
			error(e[len "group:":]);
		}
	}
	return g.flatten();
}

Patch.sizediff(p: self ref Patch): int
{
	n := 0;
	for(l := p.l; l != nil; l = tl l) {
		h := hd l;
		n += len h.buf - (h.end-h.start);
	}
	return n;
}

Patch.parse(d: array of byte): (ref Patch, string)
{
	{ return (Patch.xparse(d), nil); } exception e { "hg:*" => return (nil, e[3:]); }
}

Patch.xparse(d: array of byte): ref Patch
{
	o := 0;
	l: list of ref Hunk;
	while(o+12 <= len d) {
		start, end, length: int;
		(start, o) = g32(d, o);
		(end, o) = g32(d, o);
		(length, o) = g32(d, o);
		if(start > end)
			error(sprint("bad data, start %d > end %d", start, end));
		if(o+length > len d)
			error(sprint("bad data, hunk points past buffer, o+length %d+%d > len d %d", o, length, len d));
		buf := array[length] of byte;
		buf[:] = d[o:o+length];

		h := ref Hunk (start, end, buf);
		if(l != nil && h.start < (hd l).end)
			error(sprint("bad patch, hunk starts before preceding hunk, start %d < end %d", h.start, (hd l).end));
		l = h::l;
		o += length;
	}
	return ref Patch(util->rev(l));
}

Patch.text(p: self ref Patch): string
{
	s: string;
	for(l := p.l; l != nil; l = tl l)
		s += sprint("%s ", (hd l).text());
	if(s != nil)
		s = s[1:];
	return s;
}

nullentry: Entry;

Entry.parse(buf: array of byte, index: int): (ref Entry, string)
{
	{ return (Entry.xparse(buf, index), nil); } exception e { "hg:*" => return (nil, e[3:]); }
}

Entry.xparse(buf: array of byte, index: int): ref Entry
{
	if(len buf != 64)
		error("wrong number of bytes");

	# first entry in index file has version & flags in it
	if(index == 0)
		buf[0:] = array[4] of {* => byte 0};

	o := 0;
	e := ref nullentry;
	e.rev = index;
	(e.offset, o) = g48(buf, o);
	e.ioffset = e.offset;
	(e.flags, o) = g16(buf, o);
	(e.csize, o) = g32(buf, o);
	(e.uncsize, o) = g32(buf, o);
	(e.base, o) = g32(buf, o);
	(e.link, o) = g32(buf, o);
	(e.p1, o) = g32(buf, o);
	(e.p2, o) = g32(buf, o);
	e.nodeid = hex(buf[o:o+20]);
	o += 20;
	if(len buf-o != 12)
		error("wrong number of superfluous bytes");

	if(e.p1 >= e.rev || e.p2 >= e.rev || e.base > e.rev)
		error(sprint("bad revision value for parent or base revision, rev %d, p1 %d, p2 %d, base %d", e.rev, e.p1, e.p2, e.base));

	return e;
}

Entry.text(e: self ref Entry): string
{
	return sprint("<Entry rev=%d, off=%bd,%bd flags=%x size=%d,%d base=%d link=%d p1=%d p2=%d nodeid=%q>", e.rev, e.offset, e.ioffset, e.flags, e.csize, e.uncsize, e.base, e.link, e.p1, e.p2, e.nodeid);
}


xinflatebuf(src: array of byte): array of byte
{
	l: list of array of byte;

	total := 0;
	rqch := inflate->start("z");
	<-rqch;
	for(;;) 
	pick m := <-rqch {
	Start =>
		error("received another start message");
	Fill =>
		n := len src;
		if(n > len m.buf)
			n = len m.buf;
		m.buf[:] = src[:n];
		m.reply <-= n;
		src = src[n:];
	Result =>
		buf := array[len m.buf] of byte;
		buf[:] = m.buf;
		l = buf::l;
		total += len buf;
		m.reply <-= 0;
	Finished =>
		if(len m.buf != 0)
			error("inflatebuf: trailing bytes after inflating: "+hex(m.buf));
		#say(sprint("received %d bytes total", total));
		return flatten(total, util->rev(l));
	Info =>
		say("filter: "+m.msg);
	Error =>
		error("error from filter: "+m.e);
	}
}

flatten(total: int, l: list of array of byte): array of byte
{
	d := array[total] of byte;
	o := 0;
	for(; l != nil; l = tl l) {
		d[o:] = hd l;
		o += len hd l;
	}
	return d;
}

unhexchar(c: int): byte
{
	case c {
	'0' to '9' =>	return byte (c-'0');
	'a' to 'f' =>	return byte (c-'a'+10);
	'A' to 'F' =>	return byte (c-'A'+10);
	}
	raise sprint("unhexchar:not hex char, %c", c);
}

eunhex(s: string): (array of byte, string)
{
	if(len s % 2 != 0)
		return (nil, "bogus hex string");

	d := array[len s/2] of byte;
	i := 0;
	o := 0;
	{
		while(i < len d) {
			d[i++] = (unhexchar(s[o])<<4)|unhexchar(s[o+1]);
			o += 2;
		}
	} exception e {
	"unhexchar:*" =>
		warn(sprint("bogus hex string, %q, s %q", e, s));
		raise e;
		return (nil, e[len "unhexchar:":]);
	}
	return (d, nil);
}

unhex(s: string): array of byte
{
	return eunhex(s).t0;
}

hexchar(b: byte): byte
{
	if(b > byte 9)
		return byte 'a'-byte 10+b;
	return byte '0'+b;
}

hex(d: array of byte): string
{
	n := len d;
	if(n == 32)
		n = 20;
	r := array[2*n] of byte;
	i := 0;
	o := 0;
	while(o < n) {
		b := d[o++];
		r[i++] = hexchar((b>>4) & byte 15);
		r[i++] = hexchar(b & byte 15);
	}
	return string r;
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

has(l: list of string, e: string): int
{
	for(; l != nil; l = tl l)
		if(hd l == e)
			return 1;
	return 0;
}

exists(path: string): int
{
	return sys->stat(path).t0 == 0;
}

isdir(path: string): int
{
	(ok, dir) := sys->stat(path);
	return ok == 0 && dir.mode & Sys->DMDIR;
}

workdir(): string
{
	fd := sys->open(".", Sys->OREAD);
	if(fd == nil)
		return nil;
	return sys->fd2path(fd);
}

workdirstate(path: string): (ref Dirstate, string)
{
	{ return (xworkdirstate(path), nil); } exception e { "hg*:" => return (nil, e[3:]); }
}

xworkdirstate(path: string): ref Dirstate
{
	ds := ref Dirstate (nil, nil, nil);
	xworkstatedir0(ds, path, "");
	ds.l = util->rev(ds.l);
	return ds;
}

xworkstatedir0(ds: ref Dirstate, base, pre: string)
{
	path := base+"/"+pre;
	fd := sys->open(path, Sys->OREAD);
	if(fd == nil)
		error(sprint("open %q: %r", path));
	for(;;) {
		(n, dirs) := sys->dirread(fd);
		if(n < 0)
			error(sprint("dirread %q: %r", path));
		if(n == 0)
			break;
		for(i := 0; i < n; i++) {
			d := dirs[i];
			if(d.name == ".hg")
				continue;
			npre := pre;
			if(npre != nil)
				npre += "/";
			npre += d.name;
			if((d.mode&Sys->DMDIR) == 0) {
				dsf := ref Dirstatefile ('n', d.mode&8r777, int d.length, d.mtime, npre, nil);
				ds.l = dsf::ds.l;
			} else {
				xworkstatedir0(ds, base, npre);
			}
		}
	}
}

breadn(b: ref Iobuf, buf: array of byte, e: int): int
{
	s := 0;
	while(s < e) {
		n := b.read(buf[s:], e-s);
		if(n == Bufio->EOF || n == 0)
			break;
		if(n == Bufio->ERROR)
			return -1;
		s += n;
	}
	return s;
}

p32(d: array of byte, o: int, v: int): int
{
	d[o++] = byte (v>>24);
	d[o++] = byte (v>>16);
	d[o++] = byte (v>>8);
	d[o++] = byte (v>>0);
	return o;
}

a2l[T](a: array of T): list of T
{
	l: list of T;
	for(i := len a-1; i >= 0; i--)
		l = a[i]::l;
	return l;
}


# look away please

Revlog.open(path: string, cacheall: int): (ref Revlog, string)
{
	{ return (Revlog.xopen(path, cacheall), nil); } exception e { "hg:*" => return (nil, e[3:]); }
}

Revlog.get(rl: self ref Revlog, rev: int): (array of byte, string)
{
	{ return (rl.xget(rev), nil); } exception e { "hg:*" => return (nil, e[3:]); }
}

Revlog.getnodeid(rl: self ref Revlog, n: string): (array of byte, string)
{
	{ return (rl.xgetnodeid(n), nil); } exception e { "hg:*" => return (nil, e[3:]); }
}

Revlog.lastrev(rl: self ref Revlog): (int, string)
{
	{ return (rl.xlastrev(), nil); } exception e { "hg:*" => return (-1, e[3:]); }
}

Revlog.find(rl: self ref Revlog, rev: int): (ref Entry, string)
{
	{ return (rl.xfind(rev), nil); } exception e { "hg:*" => return (nil, e[3:]); }
}

Revlog.findnodeid(rl: self ref Revlog, n: string): (ref Entry, string)
{
	{ return (rl.xfindnodeid(n), nil); } exception e { "hg:*" => return (nil, e[3:]); }
}

Revlog.delta(rl: self ref Revlog, prev, rev: int): (array of byte, string)
{
	{ return (rl.xdelta(prev, rev), nil); } exception e { "hg:*" => return (nil, e[3:]); }
}

Revlog.pread(rl: self ref Revlog, rev: int, n: int, off: big): (array of byte, string)
{
	{ return (rl.xpread(rev, n, off), nil); } exception e { "hg:*" => return (nil, e[3:]); }
}

Revlog.length(rl: self ref Revlog, rev: int): (big, string)
{
	{ return (rl.xlength(rev), nil); } exception e { "hg:*" => return (big -1, e[3:]); }
}

Revlog.entries(rl: self ref Revlog): (array of ref Entry, string)
{
	{ return (rl.xentries(), nil); } exception e { "hg:*" => return (nil, e[3:]); }
}


Repo.open(path: string): (ref Repo, string)
{
	{ return (Repo.xopen(path), nil); } exception e { "hg:*" => return (nil, e[3:]); }
}

Repo.find(path: string): (ref Repo, string)
{
	{ return (Repo.xfind(path), nil); } exception e { "hg:*" => return (nil, e[3:]); }
}

Repo.openrevlog(r: self ref Repo, path: string): (ref Revlog, string)
{
	{ return (r.xopenrevlog(path), nil); } exception e { "hg:*" => return (nil, e[3:]); }
}

Repo.manifest(r: self ref Repo, rev: int): (ref Change, ref Manifest, string)
{
	{ (c, m) := r.xmanifest(rev); return (c, m, nil); } exception e { "hg:*" => return (nil, nil, e[3:]); }
}

Repo.lastrev(r: self ref Repo): (int, string)
{
	{ return (r.xlastrev(), nil); } exception e { "hg:*" => return (-1, e[3:]); }
}

Repo.change(r: self ref Repo, rev: int): (ref Change, string)
{
	{ return (r.xchange(rev), nil); } exception e { "hg:*" => return (nil, e[3:]); }
}

Repo.mtime(r: self ref Repo, rl: ref Revlog, rev: int): (int, string)
{
	{ return (r.xmtime(rl, rev), nil); } exception e { "hg:*" => return (0, e[3:]); }
}

Repo.dirstate(r: self ref Repo): (ref Dirstate, string)
{
	{ return (r.xdirstate(), nil); } exception e { "hg:*" => return (nil, e[3:]); }
}

Repo.writedirstate(r: self ref Repo, ds: ref Dirstate): string
{
	{ r.xwritedirstate(ds); return nil; } exception e { "hg:*" => return e[3:]; }
}

Repo.tags(r: self ref Repo): (list of ref Tag, string)
{
	{ return (r.xtags(), nil); } exception e { "hg:*" => return (nil, e[3:]); }
}

Repo.revtags(r: self ref Repo, revstr: string): (list of ref Tag, string)
{
	{ return (r.xrevtags(revstr), nil); } exception e { "hg:*" => return (nil, e[3:]); }
}

Repo.branches(r: self ref Repo): (list of ref Branch, string)
{
	{ return (r.xbranches(), nil); } exception e { "hg:*" => return (nil, e[3:]); }
}

Repo.workbranch(r: self ref Repo): (string, string)
{
	{ return (r.xworkbranch(), nil); } exception e { "hg:*" => return (nil, e[3:]); }
}

Repo.writeworkbranch(r: self ref Repo, b: string): string
{
	{ r.xwriteworkbranch(b); return nil; } exception e { "hg:*" => return e[3:]; }
}

Repo.heads(r: self ref Repo): (array of ref Entry, string)
{
	{ return (r.xheads(), nil); } exception e { "hg:*" => return (nil, e[3:]); }
}

Repo.changelog(r: self ref Repo): (ref Revlog, string)
{
	{ return (r.xchangelog(), nil); } exception e { "hg:*" => return (nil, e[3:]); }
}

Repo.manifestlog(r: self ref Repo): (ref Revlog, string)
{
	{ return (r.xmanifestlog(), nil); } exception e { "hg:*" => return (nil, e[3:]); }
}

Repo.lookup(r: self ref Repo, rev: string): (int, string, string)
{
	{ (rr, n) := r.xlookup(rev); return (rr, n, nil); } exception e { "hg:*" => return (-1, nil, e[3:]); }
}

Repo.get(r: self ref Repo, revstr, path: string): (array of byte, string)
{
	{ return (r.xget(revstr, path), nil); } exception e { "hg:*" => return (nil, e[3:]); }
}

Repo.unescape(r: self ref Repo, path: string): (string, string)
{
	{ return (r.xunescape(path), nil); } exception e { "hg:*" => return (nil, e[3:]); }
}


error(s: string)
{
	raise "hg:"+s;
}

say(s: string)
{
	if(debug)
		warn(s);
}

warn(s: string)
{
	sys->fprint(sys->fildes(2), "hg: %s\n", s);
}
