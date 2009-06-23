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
	say(sprint("nodeid.create, len d %d, n1 %s n2 %s", len d, n1.text(), n2.text()));

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
	say("change.parse");

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
	say("manifest.parse");
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
			say(sprint("flags=%x", flags));
		}
		say(sprint("nodeid=%q path=%q", string nodeid, string path));
		mf := ref Manifestfile(string path, 0, ref Nodeid(unhex(string nodeid)), flags);
		files = mf::files;
	}
	files = lists->reverse(files);
	return (ref Manifest(n, files), nil);
}


Revlog.open(path: string): (ref Revlog, string)
{
	say(sprint("revlog.open %q", path));
	ipath := path+".i";
	rl := ref Revlog(path, nil, nil, 0, 0, array[0] of ref Nodeid, nil, big 0);
	rl.ifd = sys->open(ipath, Sys->OREAD);
	if(rl.ifd == nil)
		return (nil, sprint("open %q: %r", ipath));

	buf := array[4] of byte;
	if(sys->readn(rl.ifd, buf, len buf) != len buf)
		return (nil, sprint("reading revlog version & flags: %r"));

	rl.flags = g16(buf, 0).t0;
	rl.version = g16(buf, 2).t0;

	if(!rl.isindexonly()) {
		dpath := path+".d";
		rl.dfd = sys->open(dpath, Sys->OREAD);
		if(rl.dfd == nil)
			return (nil, sprint("open %q: %r", dpath));
		# xxx verify .d file is as expected?
	}

	say("revlog opened");
	return (rl, nil);
}

Revlog.isindexonly(rl: self ref Revlog): int
{
	return rl.flags&Indexonly;
}

reconstruct(rl: ref Revlog, e: ref Entry, bufs: list of array of byte): (array of byte, string)
{
	# first is base, later are patches
	d := hd bufs;
	for(bufs = tl bufs; bufs != nil; bufs = tl bufs) {
		(p, perr) := Patch.parse(hd bufs);
		if(perr != nil)
			return (nil, sprint("error decoding patch: %s", perr));

		say("patch: "+p.text());
		d = p.apply(d);
	}

	# verify data is correct
	# nodeidcache will always be filled when we get here
	par1 := par2 := nullnode;
	if(e.p1 >= 0)
		par1 = rl.nodeidcache[e.p1];
	if(e.p2 >= 0)
		par2 = rl.nodeidcache[e.p2];
	node := Nodeid.create(d, par1, par2);
	if(Nodeid.cmp(node, e.nodeid) != 0)
		return (nil, sprint("nodeid mismatch, have %s, header claims %s", node.text(), e.nodeid.text()));

	return (d, nil);
}

reconstructlength(bufs: list of array of byte): (big, string)
{
	# first is base, later are patches
	size := big len hd bufs;
	for(bufs = tl bufs; bufs != nil; bufs = tl bufs) {
		(p, perr) := Patch.parse(hd bufs);
		if(perr != nil)
			return (big -1, sprint("error decoding patch: %s", perr));

		say("patch: "+p.text());
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
	* =>	return inflatebuf(d); # xxx should e.uncsize matter here?
	}
}

# xxx should do adding/finding more efficiently
cacheadd(rl: ref Revlog, e: ref Entry, ecache: int)
{
	say(sprint("cacheadd, ecache %d, icacheoff %bd, e %s", ecache, rl.icacheoff, e.text()));
	if(e.rev < len rl.nodeidcache)
		return;

	nc := array[len rl.nodeidcache+1] of ref Nodeid;
	nc[:] = rl.nodeidcache;
	nc[len rl.nodeidcache] = e.nodeid;
	rl.nodeidcache = nc;
	if(ecache) {
		ne := array[len rl.entrycache+1] of ref Entry;
		ne[:] = rl.entrycache;
		ne[len rl.entrycache] = e;
		rl.icacheoff += big Entrysize;
		if(rl.isindexonly())
			rl.icacheoff += big e.csize;
		rl.entrycache = ne;
	}
}

cachefindnodeid(rl: ref Revlog, n: ref Nodeid): int
{
	nstr := n.text();
	for(i := 0; i < len rl.nodeidcache; i++)
		if(rl.nodeidcache[i].text() == nstr)
			return i;
	return -1;
}

Mkeepentries, Mfindlast, Mkeepdata: con 1<<iota;

# read through index starting at `start', keeping track of data since last baserev, until we find entry matching `rev' or `n'.
# mode:
# `findlast': read through the entire index file to find the last entry (only used for .i-only, otherwise we fstat)
# `keepentries': return all entries read.  otherwise, only the entry of the requested revision/nodeid is returned.
# `keepdata': return all data read.  otherwise no data is returned (or decompressed)
readindex(rl: ref Revlog, start: big, startrev, rev: int, nodeid: ref Nodeid, mode: int): (list of array of byte, list of ref Entry, string)
{
	keepentries := mode & Mkeepentries;
	findlast := mode & Mfindlast;
	keepdata := mode & Mkeepdata;
	say(sprint("readindex, start %bd startrev %d, rev %d nodeid %s, keepentries %d, findlast %d, keepdata %d", start, startrev, rev, nodeid.text(), keepentries, findlast, keepdata));

	b := bufio->fopen(rl.ifd, Bufio->OREAD);
	if(b == nil)
		return (nil, nil, sprint("bufio fopen: %r"));

	if(b.seek(start, Bufio->SEEKSTART) != start)
		return (nil, nil, sprint("seek: %r"));

	data: list of array of byte;
	entries: list of ref Entry;

	indexonly := rl.isindexonly();
	ebuf := array[Entrysize] of byte;
Next:
	for(;;) {
		n := b.read(ebuf, len ebuf);
		if(n == 0) {
			if(findlast)
				break Next;
			return (nil, nil, sprint("no such rev/nodeid %d/%s", rev, nodeid.text()));
		}
		if(n < 0)
			return (nil, nil, sprint("read: %r"));
		if(n != len ebuf)
			return (nil, nil, "short read on index");
		(e, err) := Entry.parse(ebuf, startrev++);
		if(err != nil)
			return (nil, nil, err);

		if(indexonly) {
			e.ioffset = start+big Entrysize;

			dbuf := array[e.csize] of byte;
			have := b.read(dbuf, len dbuf);
			if(have != len dbuf)
				return (nil, nil, sprint("read data: %r"));

			(dbuf, err) = decompress(dbuf);
			if(err != nil)
				return (nil, nil, err);

			if(keepdata) {
				if(e.rev == e.base)
					data = nil;
				data = dbuf::data;
			}

			start += big (Entrysize+e.csize);
		}
		if(findlast && !keepentries)
			entries = e::nil;
		else if(e.rev == e.base && !keepentries)
			entries = nil;

		if(e.rev >= len rl.nodeidcache)
			cacheadd(rl, e, indexonly);

		match := e.rev == rev || (nodeid != nil && Nodeid.cmp(nodeid, e.nodeid) == 0);
		if(keepentries || match)
			entries = e::entries;
		if(match)
			break;
	}
	return (lists->reverse(data), lists->reverse(entries), nil);
}

readentry(fd: ref Sys->FD, off: big, rev: int): (ref Entry, string)
{
	say(sprint("readentry, off %bd, rev %d", off, rev));
	if(sys->seek(fd, off, Sys->SEEKSTART) != off)
		return (nil, sprint("seek: %r"));
	ebuf := array[Entrysize] of byte;
	n := sys->readn(fd, ebuf, len ebuf);
	if(n != len ebuf)
		return (nil, sprint("reading entry: %r"));
	return Entry.parse(ebuf, rev);
}

get(rl: ref Revlog, rev: int, nodeid: ref Nodeid): (list of array of byte, ref Entry, string)
{
	say(sprint("revlog.get, rev %d nodeid %s", rev, nodeid.text()));
	bufs: list of array of byte;
	entries: list of ref Entry;

	# start at beginning of index file
	ioff := big 0;
	ioffrev := 0;

	# if looking for nodeid, perhaps we've seen it before
	if(rev < 0)
		rev = cachefindnodeid(rl, nodeid);

	if(rl.isindexonly()) {
		# if looking for rev, perhaps it's in the cache and we can skip anything before our revs base revision
		# xxx cache is broken?
		if(0 && rev >= 0 && rev < len rl.entrycache) {
			e := rl.entrycache[rev];
			ebase := rl.entrycache[e.base];
			ioff = ebase.ioffset;
			ioffrev = ebase.rev;
		}

		err: string;
		(bufs, entries, err) = readindex(rl, ioff, ioffrev, rev, nodeid, Mkeepdata);
		if(err != nil)
			return (nil, nil, err);
	} else {
		# if revision is known, read the entry to find the baserev
		if(rev >= 0) {
			(e, err) := readentry(rl.ifd, big (rev*Entrysize), rev);
			if(err != nil)
				return (nil, nil, err);
			ioff = big (e.base*Entrysize);
			ioffrev = e.base;
		}
		err: string;
		(nil, entries, err) = readindex(rl, ioff, ioffrev, rev, nodeid, Mkeepentries|Mkeepdata);
		if(err != nil)
			return (nil, nil, err);

		soff := (hd entries).offset;
		eend := hd lists->reverse(entries);
		eoff := eend.offset+big eend.csize;
		length := int (eoff-soff);
		dbuf := array[length] of byte;
		if(sys->seek(rl.dfd, soff, Sys->SEEKSTART) != soff)
			return (nil, nil, sprint("seek on data file: %r"));
		n := sys->readn(rl.dfd, dbuf, len dbuf);
		if(n < 0)
			return (nil, nil, sprint("reading data file: %r"));
		if(n != len dbuf)
			return (nil, nil, sprint("short read on data file: %r"));

		o := 0;
		for(l := entries; l != nil; l = tl l) {
			e := hd l;
			if(o+e.csize > length)
				return (nil, nil, "size of entry does not match length of data");
			(buf, derr) := decompress(dbuf[o:o+e.csize]);
			if(derr != nil)
				return (nil, nil, derr);
			bufs = buf::bufs;
			o += e.csize;
		}
		if(o != length)
			return (nil, nil, "size of entries does not match length of data");
	}

	return (bufs, hd lists->reverse(entries), nil);
}

Revlog.get(rl: self ref Revlog, rev: int, nodeid: ref Nodeid): (array of byte, ref Entry, string)
{
	say(sprint("revlog.get, rev %d, nodeid %s", rev, nodeid.text()));
	(bufs, e, err) := get(rl, rev, nodeid);
	if(err != nil)
		return (nil, nil, err);
	data: array of byte;
	(data, err) = reconstruct(rl, e, bufs);
	if(err != nil)
		data = nil;
	return (data, e, err);
}


# create delta from prev to rev.  prev may be -1.
# if we are lucky, rev's base is prev, and we can just use the patch in the revlog.
# otherwise we'll have to create a patch.  for prev -1 this simply means making
# a patch with the entire file contents.
# for prev >= 0, we should generate a patch.  instead, for now we'll patch over the entire file.
# xxx
Revlog.delta(rl: self ref Revlog, prev, rev: int): (array of byte, string)
{
	(bufs, e, err) := get(rl, rev, nil);
	if(err != nil)
		return (nil, err);

	delta := hd lists->reverse(bufs);
	if(prev == e.base && e.base != e.rev) {
		say(sprint("matching delta, e %s", e.text()));
		return (delta, nil);
	}

	obuflen := 0;
	nbuf: array of byte;
	if(e.rev == e.base)
		nbuf = delta;
	else
		(nbuf, nil, err) = rl.get(rev, nil);

	if(err == nil && prev >= 0) {
		pe: ref Entry;
		(pe, err) = rl.findrev(prev);
		if(err == nil)
			obuflen = pe.uncsize;
	}
	if(err != nil)
		return (nil, err);
	say(sprint("delta with full contents, start %d end %d size %d, e %s", 0, obuflen, len nbuf, e.text()));
	delta = array[3*4+len nbuf] of byte;
	o := 0;
	o += p32(delta, o, 0); # start
	o += p32(delta, o, obuflen); # end
	o += p32(delta, o, len nbuf); # size
	delta[o:] = nbuf;
	return (delta, nil);
}

Revlog.filelength(rl: self ref Revlog, nodeid: ref Nodeid): (big, string)
{
	say(sprint("revlog.filelength, nodeid %s", nodeid.text()));
	(bufs, nil, err) := get(rl, -1, nodeid);
	if(err != nil)
		return (big -1, err);
	return reconstructlength(bufs);
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

findentry(rl: ref Revlog, rev: int, nodeid: ref Nodeid): (ref Entry, string)
{
	findlast := rev < 0 && nodeid == nil;
	if(rev < 0 && nodeid != nil)
		rev = cachefindnodeid(rl, nodeid);
	if(rev >= 0 && rl.entrycache != nil && rev < len rl.entrycache)
		return (rl.entrycache[rev], nil);
	if(rev >= 0 && !rl.isindexonly())
		return readentry(rl.ifd, big (rev*Entrysize), rev);

	# either we are looking for a nodeid or last entry (rev < 0); or rev >= and we have an .i-only file
	# in both cases, we can skip the nodeids that are already in the case.
	ioff := big 0;
	ioffrev := 0;
	if(findlast && len rl.nodeidcache > 0) {
		if(rl.isindexonly())
			(ioff, ioffrev) = (rl.entrycache[len rl.entrycache-1].ioffset-big Entrysize, len rl.entrycache-1);
		else
			(ioff, ioffrev) = (big ((len rl.nodeidcache-1)*Entrysize), len rl.nodeidcache-1);
	}

	mode := 0;
	if(findlast)
		mode = Mfindlast;
	(nil, entries, err) := readindex(rl, ioff, ioffrev, rev, nodeid, mode);
	if(err != nil)
		return (nil, err);
	return (hd entries, nil);
}

Revlog.find(rl: self ref Revlog, rev: int, nodeid: ref Nodeid): (ref Entry, string)
{
	say(sprint("revlog.find, rev %d, nodeid %s", rev, nodeid.text()));
	return findentry(rl, rev, nodeid);
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
	if(!rl.isindexonly()) {
		say("repo.lastrev, using fstat");
		(ok, d) := sys->fstat(rl.ifd);
		if(ok != 0)
			return (-1, sprint("fstat index file: %r"));
		if(d.length == big 0)
			return (-1, "empty index file?");
		if(d.length % big Entrysize != big 0)
			return (-1, "index file not multiple of size of entry");
		return (int (d.length/big Entrysize - big 1), nil);
	}

	say("repo.lastrev, using readindex");
	(e, err) := findentry(rl, -1, nil);
	if(err != nil)
		return (-1, err);
	return (e.rev, nil);
}

Revlog.entries(rl: self ref Revlog): (array of ref Entry, string)
{
	(nil, l, err) := readindex(rl, big 0, 0, -1, nil, Mkeepentries|Mfindlast);
	if(err == nil)
		a := l2a(l);
	return (a, err);
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

	repo := ref Repo(path, requires, name, -1, -1);
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

	mpath := r.storedir()+"/00manifest";
	(mrl, mrlerr) := Revlog.open(mpath);
	if(mrlerr != nil)
		return (nil, nil, mrlerr);

	(mdata, mderr) := mrl.getnodeid(c.manifestnodeid);
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
	if(l == nil) {
		(e, err) := findentry(cl, -1, nil);
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
	path := r.storedir()+"/00changelog";
	return Revlog.open(path);
}

Repo.manifestlog(r: self ref Repo): (ref Revlog, string)
{
	path := r.storedir()+"/00manifest";
	return Revlog.open(path);
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
	return sprint("<hunk s=%d e=%d buf=%s length=%d>", h.start, h.end, string h.buf, len h.buf);
}

Patch.apply(p: self ref Patch, d: array of byte): array of byte
{
	off := 0;
	for(l := p.l; l != nil; l = tl l) {
		h := hd l;
		del := h.end-h.start;
		add := len h.buf;
		diff := add-del;
		say(sprint("apply, len d %d, del %d add %d, diff %d, off %d", len d, del, add, diff, off));

		s := h.start+off;
		e := h.end+off;
		nd := array[len d+diff] of byte;
		nd[:] = d[:s];
		nd[s:] = h.buf;
		nd[s+len h.buf:] = d[e:];
		d = nd[:];

		off += diff;
	}
	return d;
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

Patch.merge(pl: list of ref Patch): ref Patch
{
	return hd pl; # xxx implement
}

Patch.parse(d: array of byte): (ref Patch, string)
{
	o := 0;
	l: list of ref Hunk;
	say(sprint("hunk.parse, buf %s", hex(d)));
	while(o+12 <= len d) {
		start, end, length: int;
		(start, o) = g32(d, o);
		(end, o) = g32(d, o);
		(length, o) = g32(d, o);
		say(sprint("s %d e %d l %d", start, end, length));
		if(start > end)
			return (nil, sprint("bad data, start %d > end %d", start, end));
		if(o+length > len d)
			return (nil, sprint("bad data, hunk points past buffer, o+length %d+%d > len d %d", o, length, len d));
		buf := array[length] of byte;
		buf[:] = d[o:o+length];
		l = ref Hunk(start, end, buf)::l;
		o += length;
	}
	return (ref Patch(lists->reverse(l)), nil);
}

Patch.text(p: self ref Patch): string
{
	s := "";
	for(l := p.l; l != nil; l = tl l)
		s += sprint("hunk: %s", (hd l).text());
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
	#origsrc := src;
	src = src[2:];
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
			#writefile("deflate.bin", origsrc);
			return (nil, "error from filter: "+m.e);
		}
	}
}

writefile(path: string, d: array of byte)
{
	fd := sys->create(path, Sys->OWRITE, 8r666);
	if(fd == nil)
		raise sprint("creating %q: %r", path);
	if(sys->write(fd, d, len d) != len d)
		raise sprint("writing to %q: %r", path);
	say(sprint("wrote %d bytes to %q", len d, path));
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

say(s: string)
{
	if(debug)
		warn(s);
}

warn(s: string)
{
	sys->fprint(sys->fildes(2), "%s\n", s);
}
