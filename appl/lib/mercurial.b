implement Mercurial;

include "sys.m";
	sys: Sys;
	sprint: import sys;
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
include "string.m";
	str: String;
include "daytime.m";
	daytime: Daytime;

include "mercurial.m";


Entrysize:	con 64;
Nullnode:	con -1;
Cachemax:	con 64;  # max number of cached items in a revlog

init()
{
	sys = load Sys Sys->PATH;
	bufio = load Bufio Bufio->PATH;
	lists = load Lists Lists->PATH;
	keyring = load Keyring Keyring->PATH;
	str = load String String->PATH;
	daytime = load Daytime Daytime->PATH;
	inflate = load Filter Filter->INFLATEPATH;
	inflate->init();

	nullnode = ref Nodeid(array[20] of {* => byte 0});
}

Nodeid.parse(s: string): (ref Nodeid, string)
{
	{
		d := unhex(s);
		if(len d != 20)
			return (nil, sprint("bad nodeid: %s", s));
		return (ref Nodeid (d), nil);
	} exception ex {
	"unhex:*" =>
		return (nil, "bad nodeid: "+ex[len "unhex:":]);
	}
}

Nodeid.create(d: array of byte, n1, n2: ref Nodeid): ref Nodeid
{
	if(Nodeid.cmp(n1, n2) > 0)
		(n1, n2) = (n2, n1);

	state: ref DigestState;
	state = keyring->sha1(n1.d[:20], 20, nil, state);
	state = keyring->sha1(n2.d[:20], 20, nil, state);
	state = keyring->sha1(d, len d, nil, state);

	hash := array[Keyring->SHA1dlen] of byte;
	keyring->sha1(nil, 0, hash, state);
	return ref Nodeid(hash);
}


Nodeid.text(n: self ref Nodeid): string
{
	if(n == nil)
		return "<nil>";
	return hex(n.d[:20]);
}

Nodeid.cmp(n1, n2: ref Nodeid): int
{
	if(len n1.d != len n2.d)
		raise "bogus nodeid comparison";
	for(i := 0; i < len n1.d; i++)
		if(n1.d[i] < n2.d[i])
			return -1;
		else if(n1.d[i] > n2.d[i])
			return 1;
	return 0;
}

Nodeid.isnull(n: self ref Nodeid): int
{
	return Nodeid.cmp(n, nullnode) == 0;
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
	c := ref nullchange;
	c.nodeid = e.nodeid;
	c.rev = e.rev;
	c.p1 = e.p1;
	c.p2 = e.p2;
	if(c.p1 == Nullnode)
		c.p1 = -1;
	if(c.p2 == Nullnode)
		c.p2 = -1;

	b := bufio->aopen(data);

	l := getline(b);
	if(l == nil)
		return (nil, "missing manifest nodeid");
	c.manifestnodeid = ref Nodeid(unhex(l));

	l = getline(b);
	if(l == nil)
		return (nil, "missing committer");
	c.who = l;

	l = getline(b);
	if(l == nil)
		return (nil, "missing timestamp");
	(t, tzoff) := str->splitstrl(l, " ");
	if(tzoff == nil || str->drop(t, "0-9") != nil || str->drop(t, "0-9-") != nil)
		return (nil, "invalid timestamp/timezone");
	c.when = int t;
	c.tzoff = int tzoff[1:];

	for(;;) {
		l = getline(b);
		if(l == nil)
			break;
		c.files = l::c.files;
	}
	c.files = lists->reverse(c.files);

	d := array[0] of byte;
	for(;;) {
		n := b.read(buf := array[1024] of byte, len buf);
		if(n == 0)
			break;
		if(n < 0)
			return (nil, "reading message");
		nd := array[len d+n] of byte;
		nd[:] = d;
		nd[len d:] = buf[:n];
		d = nd;
	}
	c.msg = string d;

	return (c, nil);
}

Change.text(c: self ref Change): string
{
	s := "";
	s += sprint("revision: %d\n", c.rev);
	pstr := "";
	if(c.p1 == -1 && c.p2 == -1)
		pstr = "  none";
	if(c.p1 != -1)
		pstr += ", "+string c.p1;
	if(c.p2 != -1)
		pstr += ", "+string c.p2;
	s += "parents: "+pstr[2:]+"\n";
	s += sprint("manifest nodeid: %s\n", c.manifestnodeid.text());
	s += sprint("committer: %s\n", c.who);
	when := daytime->gmt(c.when);
	when.tzoff = c.tzoff;
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

Manifest.parse(d: array of byte, n: ref Nodeid): (ref Manifest, string)
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
			"lx" or "xl" =>	flags = Flink|Fexec;
			* =>	return (nil, sprint("unknown flags: %q", flagstr));
			}
			nodeid = nodeid[:40];
			#say(sprint("manifest flags=%x", flags));
		}
		# say(sprint("nodeid=%q path=%q", string nodeid, string path));
		mf := ref Manifestfile(string path, 0, ref Nodeid(unhex(string nodeid)), flags);
		files = mf::files;
	}
	files = lists->reverse(files);
	return (ref Manifest(n, files), nil);
}

reopen(rl: ref Revlog): string
{
	# test whether we need to reread index files
	(ok, dir) := sys->fstat(rl.ifd);
	if(ok < 0)
		return sprint("%r");
	if(dir.length == rl.length && dir.mtime == rl.mtime)
		return nil;

say(sprint("revlog, reopen, path %q", rl.path));

	# reread the index file.  we also get here for the first open of the revlog.
	# instead of rereading everything, we could continue at where we left.
	# as long as isreadonly didn't change that is.  maybe later.
	ib := bufio->fopen(rl.ifd, Bufio->OREAD);
	if(ib == nil)
		return sprint("fopen: %r");
	ib.seek(big 0, Bufio->SEEKSTART);

	if(breadn(ib, buf := array[4] of byte, len buf) != len buf)
		return sprint("reading revlog version & flags: %r");

	rl.flags = g16(buf, 0).t0;
	rl.version = g16(buf, 2).t0;
	rl.bd = nil;
	rl.dfd = nil;
	if(!isindexonly(rl)) {
		dpath := rl.path+".d";
		rl.dfd = sys->open(dpath, Sys->OREAD);
		if(rl.dfd == nil)
			return sprint("open %q: %r", dpath);
		# xxx verify .d file is as expected?
	}

	err := readrevlog(rl, ib);
	if(err == nil) {
		rl.length = dir.length;
		rl.mtime = dir.mtime;
	}
	return err;
}

# read through the entire revlog, store all entries in rl.entries.
# revlog's are usually very small.
readrevlog(rl: ref Revlog, ib: ref Iobuf): string
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
			return sprint("reading entry: %r");
		if(n != len eb)
			return sprint("short entry");

		(e, err) := Entry.parse(eb, len l);
		if(err != nil)
			return "parsing entry: "+err;

		# no .d file, the data for an entry comes directly after the entry.
		# so skip over it for the next iteration of this loop
		if(indexonly) {
			e.ioffset = ib.offset();
			if(ib.seek(big e.csize, Bufio->SEEKRELA) != e.ioffset+big e.csize)
				return sprint("seek: %r");
		}

		l = e::l;
	}
	rl.ents = l2a(lists->reverse(l));
	rl.cache = array[len rl.ents] of array of byte;
	rl.ncache = 0;
	rl.full = nil;
	rl.fullrev = -1;
say(sprint("readrevlog, len ents %d", len rl.ents));
	return nil;
}


Revlog.open(path: string): (ref Revlog, string)
{
	say(sprint("revlog.open %q", path));
	rl := ref Revlog;
	rl.path = path;
	rl.fullrev = -1;

	# we keep ifd open at all times.  we'll need it if this revlog isindexonly and we need to read data parts.
	rl.ifd = sys->open(path+".i", Sys->OREAD);
	if(rl.ifd == nil)
		return (nil, sprint("open %q: %r", path+".i"));

	rl.length = ~big 0;
	rl.mtime = ~0;
	err := reopen(rl);
	if(err != nil)
		rl = nil;
	return (rl, err);
}

isindexonly(rl: ref Revlog): int
{
	return rl.flags & Indexonly;
}

Revlog.isindexonly(rl: self ref Revlog): int
{
	reopen(rl);
	return rl.flags & Indexonly;
}

reconstruct(rl: ref Revlog, e: ref Entry, base: array of byte, patches: array of array of byte): (array of byte, string)
{
say(sprint("reconstruct, len base %d, len patches %d, e.rev %d", len base, len patches, e.rev));

	# first is base, later are patches
	(d, err) := Patch.applymany(base, patches);
	if(err != nil)
		return (nil, err);

	# verify data is correct
	pn1 := pn2 := nullnode;
	if(e.p1 >= 0)
		pn1 = rl.ents[e.p1].nodeid;
	if(e.p2 >= 0)
		pn2 = rl.ents[e.p2].nodeid;
	n := Nodeid.create(d, pn1, pn2);
	if(Nodeid.cmp(n, e.nodeid) != 0)
		return (nil, sprint("nodeid mismatch, have %s, header claims %s, (p1 %s p2 %s, len %d, entry %s)", n.text(), e.nodeid.text(), pn1.text(), pn2.text(), len d, e.text()));

	rl.fullrev = e.rev;
	rl.full = d;

	return (d, nil);
}

reconstructlength(base: array of byte, patches: array of array of byte): (big, string)
{
	# first is base, later are patches
	size := big len base;
	for(i := 0; i < len patches; i++) {
		(p, perr) := Patch.parse(patches[i]);
		if(perr != nil)
			return (big -1, sprint("error decoding patch: %s", perr));
		size += big p.sizediff();
	}
	return (size, nil);
}

decompress(d: array of byte): (array of byte, string)
{
	if(len d == 0)
		return (d, nil);
	# may be compressed, first byte will tell us.
	case int d[0] {
	'u' =>	return (d[1:], nil);
	0 =>	return (d, nil);
	* =>	return inflatebuf(d);
	}
}

getdata(rl: ref Revlog, e: ref Entry): (array of byte, string)
{
	if(rl.cache[e.rev] != nil) {
		#say(sprint("getdata, rev %d from cache", e.rev));
		return (rl.cache[e.rev], nil);
	}

	#say(sprint("getdata, getting fresh data for rev %d", e.rev));
	if(rl.bd == nil) {
		fd := rl.dfd;
		if(rl.isindexonly())
			fd = rl.ifd;
		rl.bd = bufio->fopen(fd, Bufio->OREAD);
	}

	if(rl.bd.seek(e.ioffset, Bufio->SEEKSTART) != e.ioffset)
		return (nil, sprint("seek %bd: %r", e.ioffset));
	if(breadn(rl.bd, buf := array[e.csize] of byte, len buf) != len buf)
		return (nil, sprint("read: %r"));
	err: string;
	#say(sprint("getdata, %d compressed bytes for rev %d", len buf, e.rev));
	(buf, err) = decompress(buf);
	if(err != nil)
		return (nil, err);
	#say(sprint("getdata, %d decompressed bytes for rev %d", len buf, e.rev));

	for(i := 0; rl.ncache >= Cachemax && i < len rl.cache; i++)
		if(rl.cache[i] != nil) {
			rl.cache[i] = nil;
			rl.ncache--;
		}
	rl.cache[e.rev] = buf;
	rl.ncache++;
	return (buf, nil);
}

# fetch data to reconstruct the entry.
# the head of the result is the base of the data, the other buffers are the delta's
getbufs(rl: ref Revlog, e: ref Entry): (array of array of byte, string)
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

	err: string;
	for(i := base; err == nil && i <= e.rev; i++)
		if(bufs[i-base] == nil)
			(bufs[i-base], err) = getdata(rl, rl.ents[i]);
	return (bufs, err);
}

get(rl: ref Revlog, e: ref Entry): (array of byte, string)
{
	if(e.rev == rl.fullrev) {
		#say(sprint("get, using cache for rev %d", e.rev));
		return (rl.full, nil);
	}

	#say(sprint("get, going to reconstruct for rev %d", e.rev));
	buf: array of byte;
	(bufs, err) := getbufs(rl, e);
	if(err == nil)
		(buf, err) = reconstruct(rl, e, bufs[0], bufs[1:]);
	return (buf, err);
}

getlength(rl: ref Revlog, e: ref Entry): (big, string)
{
	if(e.rev == rl.fullrev)
		return (big len rl.full, nil);

	length := big -1;
	(bufs, err) := getbufs(rl, e);
	if(err == nil)
		(length, err) = reconstructlength(bufs[0], bufs[1:]);
	return (length, err);
}

Revlog.get(rl: self ref Revlog, rev: int, nodeid: ref Nodeid): (array of byte, ref Entry, string)
{
	#say(sprint("revlog.get, rev %d, nodeid %s", rev, nodeid.text()));

	d: array of byte;
	(e, err) := rl.find(rev, nodeid);
	if(err == nil)
		(d, err) = get(rl, e);
	return (d, e, err);
}


# create delta from prev to rev.  prev may be -1.
# the typical and easy case is that prev is rev predecessor, and we can use the delta from the revlog.
# otherwise we'll have to create a patch.  for prev -1 this simply means making
# a patch with the entire file contents.
# for prev >= 0, we should generate a patch.  instead, for now we'll patch over the entire file.
# xxx
Revlog.delta(rl: self ref Revlog, prev, rev: int): (array of byte, string)
{
	#say(sprint("delta, prev %d, rev %d", prev, rev));
	(e, err) := rl.findrev(rev);
	if(err != nil)
		return (nil, err);

	if(prev != -1 && prev == e.rev-1 && e.base != e.rev) {
		#say(sprint("matching delta, e %s", e.text()));
		return getdata(rl, e);
	}

	#say("creating new delta with full contents");
	buf: array of byte;
	(buf, err) = get(rl, e);
	obuflen := 0;
	if(err == nil && prev >= 0) {
		pe: ref Entry;
		(pe, err) = rl.findrev(prev);
		if(err == nil)
			obuflen = pe.uncsize;
	}
	if(err != nil)
		return (nil, err);
	#say(sprint("delta with full contents, start %d end %d size %d, e %s", 0, obuflen, len buf, e.text()));
	delta := array[3*4+len buf] of byte;
	o := 0;
	o += p32(delta, o, 0); # start
	o += p32(delta, o, obuflen); # end
	o += p32(delta, o, len buf); # size
	delta[o:] = buf;
	return (delta, nil);
}

Revlog.filelength(rl: self ref Revlog, n: ref Nodeid): (big, string)
{
	length := big -1;
	(e, err) := rl.findnodeid(n);
	if(err == nil)
		(length, err) = getlength(rl, e);
	return (length, err);
}

Revlog.getrev(rl: self ref Revlog, rev: int): (array of byte, string)
{
	(d, nil, err) := rl.get(rev, nil);
	return (d, err);
}

Revlog.getnodeid(rl: self ref Revlog, nodeid: ref Nodeid): (array of byte, string)
{
	(d, nil, err) := rl.get(-1, nodeid);
	return (d, err);
}

Revlog.find(rl: self ref Revlog, rev: int, nodeid: ref Nodeid): (ref Entry, string)
{
	err := reopen(rl);
	if(err != nil)
		return (nil, err);

	# looking for last entry
	if(rev < 0 && nodeid == nil)
		return (rl.ents[len rl.ents-1], nil);

	# looking for revision number
	if(rev >= 0) {
		if(rev >= len rl.ents)
			return (nil, sprint("no revision %d", rev));
		return (rl.ents[rev], nil);
	}

	# looking for nodeid
	for(i := 0; i < len rl.ents; i++)
		if(Nodeid.cmp(rl.ents[i].nodeid, nodeid) == 0)
			return (rl.ents[i], nil);
	return (nil, sprint("no nodeid %s", nodeid.text()));
}

Revlog.findrev(rl: self ref Revlog, rev: int): (ref Entry, string)
{
	return rl.find(rev, nil);
}

Revlog.findnodeid(rl: self ref Revlog, nodeid: ref Nodeid): (ref Entry, string)
{
	return rl.find(-1, nodeid);
}

Revlog.lastrev(rl: self ref Revlog): (int, string)
{
	err := reopen(rl);
	return (len rl.ents-1, err);
}

Revlog.entries(rl: self ref Revlog): (array of ref Entry, string)
{
	err := reopen(rl);
	if(err != nil)
		return (nil, err);
	ents := array[len rl.ents] of ref Entry;
	ents[:] = rl.ents;
	return (ents, nil);
}


Repo.open(path: string): (ref Repo, string)
{
	say("repo.open");

	reqpath := path+"/requires";
	b := bufio->open(reqpath, Bufio->OREAD);
	if(b == nil)
		return (nil, sprint("repo \"requires\" file: %r"));
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
		return (nil, sprint("stat %q: %r", namepath));
	name := dir.name;

	repo := ref Repo (path, requires, name, -1, -1, nil, nil);
	if(repo.isstore() && !isdir(path+"/store"))
		return (nil, "missing directory \".hg/store\"");
	if(!repo.isstore() && !isdir(path+"/data"))
		return (nil, "missing directory \".hg/data\"");
	say(sprint("have repo, path %q", path));
	return (repo, nil);
}

Repo.find(path: string): (ref Repo, string)
{
	if(path == nil)
		path = workdir();

	while(path != nil) {
		while(path != nil && path[len path-1] == '/')
			path = path[:len path-1];

		hgpath := path+"/.hg";
		if(exists(hgpath))
			return Repo.open(hgpath);

		(path, nil) = str->splitstrr(path, "/");
	}
	return (nil, "no repo found");
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

Repo.storedir(r: self ref Repo): string
{
	path := r.path;
	if(r.isstore())
		path += "/store";
	return path;
}

Repo.openrevlog(r: self ref Repo, path: string): (ref Revlog, string)
{
	path = r.storedir()+"/data/"+r.escape(path);
	return Revlog.open(path);
}


Repo.manifest(r: self ref Repo, rev: int): (ref Change, ref Manifest, string)
{
	say("repo.manifest");

	(cl, clerr) := r.changelog();
	if(clerr != nil)
		return (nil, nil, clerr);
	(cdata, ce, clderr) := cl.get(rev, nil);
	if(clderr != nil)
		return (nil, nil, clderr);

	(c, cerr) := Change.parse(cdata, ce);
	if(cerr != nil)
		return (nil, nil, cerr);

	say("repo.manifest, have change, manifest nodeid "+c.manifestnodeid.text());

	(ml, mlerr) := r.manifestlog();
	if(mlerr != nil)
		return (nil, nil, mlerr);

	(mdata, mderr) := ml.getnodeid(c.manifestnodeid);
	if(mderr != nil)
		return (nil, nil, mderr);

	(m, merr) := Manifest.parse(mdata, c.manifestnodeid);
	if(merr != nil)
		return (nil, nil, merr);

	return (c, m, nil);
}

Repo.readfile(r: self ref Repo, path: string, nodeid: ref Nodeid): (array of byte, string)
{
	say(sprint("repo.readfile, path %q, nodeid %s", path, nodeid.text()));
	rlpath := r.storedir()+"/data/"+r.escape(path);
	(rl, rlerr) := Revlog.open(rlpath);
	if(rlerr != nil)
		return (nil, rlerr);
	return rl.getnodeid(nodeid);
}

Repo.lastrev(r: self ref Repo): (int, string)
{
	(cl, clerr) := r.changelog();
	if(clerr != nil)
		return (-1, clerr);

	(ok, d) := sys->fstat(cl.ifd);
	if(ok != 0)
		return (-1, sprint("fstat changelog index: %r"));

	if(r.lastrevision >= 0 && d.mtime <= r.lastmtime)
		return (r.lastrevision, nil);

	(rev, rerr) := cl.lastrev();
	if(rerr != nil)
		return (-1, rerr);
	r.lastrevision = rev;
	r.lastmtime = d.mtime;
	return (rev, nil);
}

Repo.change(r: self ref Repo, rev: int): (ref Change, string)
{
	(cl, clerr) := r.changelog();
	if(clerr != nil)
		return (nil, clerr);

	(cdata, e, clderr) := cl.get(rev, nil);
	if(clderr != nil)
		return (nil, clderr);

	(c, cerr) := Change.parse(cdata, e);
	return (c, cerr);
}

Repo.filelength(r: self ref Repo, path: string, n: ref Nodeid): (big, string)
{
	(rl, err) := r.openrevlog(path);
	if(err != nil)
		return (big -1, err);
	return rl.filelength(n);
}

Repo.filemtime(r: self ref Repo, path: string, n: ref Nodeid): (int, string)
{
	e: ref Entry;
	c: ref Change;
	(rl, err) := r.openrevlog(path);
	if(err == nil)
		(e, err) = rl.findnodeid(n);
	if(err == nil)
		(c, err) = r.change(e.link);
	if(err != nil)
		return (0, err);
	return (c.when+c.tzoff, nil);
}

Repo.dirstate(r: self ref Repo): (ref Dirstate, string)
{
	path := r.path+"/dirstate";
	b := bufio->open(path, Bufio->OREAD);
	if(b == nil)
		return (nil, sprint("open %q: %r", path));

	n1 := b.read(p1 := array[20] of byte, len p1);
	n2 := b.read(p2 := array[20] of byte, len p2);
	if(n1 != len p1 || n2 != len p2)
		return (nil, sprint("reading parents: %r"));

	buf := array[1+4+4+4+4] of byte;
	l: list of ref Dirstatefile;
	for(;;) {
		n := b.read(buf, len buf);
		if(n == 0)
			break;
		if(n != len buf)
			return (nil, sprint("bad dirstate, early eof for path header, want %d, saw %d", len buf, n));
		dsf := ref Dirstatefile;
		o := 0;
		stb := buf[o++];
		dsf.state = find(statestrs, sprint("%c", int stb));
		(dsf.mode, o) = g32(buf, o);
		(dsf.size, o) = g32(buf, o);
		(dsf.mtime, o) = g32(buf, o);
		length: int;
		(length, o) = g32(buf, o);
		if(length >= 2*1024)
			return (nil, sprint("implausible path length %d in dirstate", length));
		n = b.read(namebuf := array[length] of byte, len namebuf);
		if(n != len namebuf)
			return (nil, "early eof in dirstate while reading path");
		dsf.name = string namebuf;
		for(nul := 0; nul < len namebuf; nul++)
			if(namebuf[nul] == byte '\0') {
				dsf.name = string namebuf[:nul];
				dsf.origname = string namebuf[nul+1:];
				break;
			}
		l = dsf::l;
	}
	nd1 := ref Nodeid (p1);
	nd2 := ref Nodeid (p2);
	ds := ref Dirstate (nd1, nd2, lists->reverse(l));
	return (ds, nil);
}

Repo.workroot(r: self ref Repo): string
{
	return r.path[:len r.path-len "/.hg"];
}

Repo.tags(r: self ref Repo): (list of ref Tag, string)
{
	path := r.workroot()+"/"+".hgtags";
	b := bufio->open(path, Bufio->OREAD);
	if(b == nil)
		return (nil, nil); # absent file is valid

	(cl, clerr) := r.changelog();
	if(clerr != nil)
		return (nil, "opening changelog, for revisions: "+clerr);

	l: list of ref Tag;
	for(;;) {
		s := b.gets('\n');
		if(s == nil)
			break;
		if(s[len s-1] != '\n')
			return (nil, sprint("missing newline in .hgtags: %s", s));
		s = s[:len s-1];
		toks := sys->tokenize(s, " ").t1;
		if(len toks != 2)
			return (nil, sprint("wrong number of tokes in .hgtags: %s", s));

		name := hd tl toks;
		e: ref Entry;
		(n, err) := Nodeid.parse(hd toks);
		if(err == nil)
			(e, err) = cl.findnodeid(n);
		if(err != nil)
			return (nil, err);
		l = ref Tag (name, n, e.rev)::l;
	}
	return (lists->reverse(l), nil);
}

Repo.branches(r: self ref Repo): (list of ref Branch, string)
{
	path := r.path+"/branch.cache";
	b := bufio->open(path, Bufio->OREAD);
	# b nil is okay, we're sure not to read from it if so below

	(cl, clerr) := r.changelog();
	if(clerr != nil)
		return (nil, "opening changelog, for revisions: "+clerr);

	# first line has nodeid+revision of tip
	if(b != nil)
		b.gets('\n');

	l: list of ref Branch;
	for(;;) {
		if(b == nil)
			break;

		s := b.gets('\n');
		if(s == nil)
			break;
		if(s[len s-1] != '\n')
			return (nil, sprint("missing newline in branch.cache: %s", s));
		s = s[:len s-1];
		toks := sys->tokenize(s, " ").t1;
		if(len toks != 2)
			return (nil, sprint("wrong number of tokes in branch.cache: %s", s));

		name := hd tl toks;
		e: ref Entry;
		(n, err) := Nodeid.parse(hd toks);
		if(err == nil)
			(e, err) = cl.findnodeid(n);
		if(err != nil)
			return (nil, err);
		l = ref Branch (name, n, e.rev)::l;
	}
	if(l == nil && len cl.ents > 0) {
		(e, err) := cl.find(-1, nil);
		if(err != nil)
			return (nil, err);
		l = ref Branch ("default", e.nodeid, e.rev)::l;
	}
	return (lists->reverse(l), nil);
}

Repo.heads(r: self ref Repo): (array of ref Entry, string)
{
	(cl, clerr) := r.changelog();
	if(clerr != nil)
		return (nil, clerr);

	(a, err) := cl.entries();
	if(err != nil)
		return (nil, err);

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
	return (l2a(lists->reverse(hl)), nil);
}

Repo.changelog(r: self ref Repo): (ref Revlog, string)
{
	if(r.cl == nil) {
		path := r.storedir()+"/00changelog";
		(cl, err) := Revlog.open(path);
		if(err == nil)
			r.cl = cl;
	}
	return (r.cl, nil);
}

Repo.manifestlog(r: self ref Repo): (ref Revlog, string)
{
	if(r.ml == nil) {
		path := r.storedir()+"/00manifest";
		(ml, err) := Revlog.open(path);
		if(err == nil)
			r.ml = ml;
	}
	return (r.ml, nil);
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
	s := sprint("%s %03uo %10d %s %q", statestr(f.state), 8r777&f.mode, f.size, timestr, f.name);
	if(f.origname != nil)
		s += sprint(" (from %q)", f.origname);
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
	ng.l = lists->reverse(ng.l);
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
	if(len patches == 0)
		return (base, nil);

	g := ref Group (base::nil, len base, 0);
	for(i := 0; i < len patches; i++) {
		(p, err) := Patch.parse(patches[i]);
		if(err != nil)
			return (nil, err);
		{
			g = Group.apply(g, p);
		} exception e {
		"group:*" =>
			return (nil, e[len "group:":]);
		}
	}
	return (g.flatten(), nil);
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
	o := 0;
	l: list of ref Hunk;
	while(o+12 <= len d) {
		start, end, length: int;
		(start, o) = g32(d, o);
		(end, o) = g32(d, o);
		(length, o) = g32(d, o);
		if(start > end)
			return (nil, sprint("bad data, start %d > end %d", start, end));
		if(o+length > len d)
			return (nil, sprint("bad data, hunk points past buffer, o+length %d+%d > len d %d", o, length, len d));
		buf := array[length] of byte;
		buf[:] = d[o:o+length];

		h := ref Hunk (start, end, buf);
		if(l != nil && h.start < (hd l).end)
			return (nil, sprint("bad patch, hunk starts before preceding hunk, start %d < end %d", h.start, (hd l).end));
		l = h::l;
		o += length;
	}
	return (ref Patch(lists->reverse(l)), nil);
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
	if(len buf != 64)
		return (nil, "wrong number of bytes");

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
	node := array[20] of byte;
	node[:] = buf[o:o+20];
	e.nodeid = ref Nodeid(node);
	o += 20;
	if(len buf-o != 12)
		return (nil, "wrong number of superfluous bytes");

	if(e.p1 >= e.rev || e.p2 >= e.rev || e.base > e.rev)
		return (nil, sprint("bad revision value for parent or base revision, rev %d, p1 %d, p2 %d, base %d", e.rev, e.p1, e.p2, e.base));

	return (e, nil);
}

Entry.text(e: self ref Entry): string
{
	return sprint("<Entry rev=%d, off=%bd,%bd flags=%x size=%d,%d base=%d link=%d p1=%d p2=%d nodeid=%s>", e.rev, e.offset, e.ioffset, e.flags, e.csize, e.uncsize, e.base, e.link, e.p1, e.p2, e.nodeid.text());
}


inflatebuf(src: array of byte): (array of byte, string)
{
	l: list of array of byte;

	total := 0;
	rqch := inflate->start("z");
	<-rqch;
	for(;;) 
	pick m := <-rqch {
	Start =>
		return (nil, "received another start message");
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
			return (nil, "inflatebuf: trailing bytes after inflating: "+hex(m.buf));
		#say(sprint("received %d bytes total", total));
		return (flatten(total, lists->reverse(l)), nil);
	Info =>
		say("filter: "+m.msg);
	Error =>
		return (nil, "error from filter: "+m.e);
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

unhex(s: string): array of byte
{
	if(len s % 2 != 0)
		raise "unhex:bogus hex string";

	d := array[len s/2] of byte;
	for(i := 0; i < len d; i++) {
		(num, rem) := str->toint(s[i*2:(i+1)*2], 16);
		if(rem != nil)
			raise "unhex:bad hex string";
		d[i] = byte num;
	}
	return d;
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
	ds := ref Dirstate (nil, nil, nil);
	err := workstatedir0(ds, path, "");
	if(err == nil)
		ds.l = lists->reverse(ds.l);
	return (ds, nil);
}

workstatedir0(ds: ref Dirstate, base, pre: string): string
{
	path := base+"/"+pre;
	fd := sys->open(path, Sys->OREAD);
	if(fd == nil)
		return sprint("open %q: %r", path);
	for(;;) {
		(n, dirs) := sys->dirread(fd);
		if(n < 0)
			return sprint("dirread %q: %r", path);
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
				err := workstatedir0(ds, base, npre);
				if(err != nil)
					return err;
			}
		}
	}
	return nil;
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

max(a, b: int): int
{
	if(a > b)
		return a;
	return b;
}

p32(d: array of byte, o: int, v: int): int
{
	d[o++] = byte (v>>24);
	d[o++] = byte (v>>16);
	d[o++] = byte (v>>8);
	d[o++] = byte (v>>0);
	return 4;
}

l2a[T](l: list of T): array of T
{
	a := array[len l] of T;
	i := 0;
	for(; l != nil; l = tl l)
		a[i++] = hd l;
	return a;
}

a2l[T](a: array of T): list of T
{
	l: list of T;
	for(i := len a-1; i >= 0; i--)
		l = a[i]::l;
	return l;
}

say(s: string)
{
	if(debug)
		warn(s);
}

warn(s: string)
{
	sys->fprint(sys->fildes(2), "%s\n", s);
}
