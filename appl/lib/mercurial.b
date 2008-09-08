implement Mercurial;

# todo
# - for to detect when .i-only is changed into using .d;  have to invalidate/fix cache
# - revlog revision & flags in .i?

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
nullnode:	ref Nodeid;

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

Manifest.parse(d: array of byte): (ref Manifest, string)
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
	return (ref Manifest(files), nil);
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
	for(;;) {
		n := b.read(ebuf, len ebuf);
		if(n == 0) {
			if(findlast)
				return (nil, entries, nil);
			return (nil, nil, sprint("no such rev/nodeid %d/%s", rev, nodeid.text()));
		}
		if(n < 0)
			return (nil, nil, sprint("read: %r"));
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
		if(findlast)
			entries = e::nil;
		else if(e.rev == e.base)
			entries = nil;

		if(e.rev >= len rl.nodeidcache)
			cacheadd(rl, e, indexonly);

		match := e.rev == rev || (nodeid != nil && Nodeid.cmp(nodeid, e.nodeid) == 0);
		if(!findlast && (keepentries || match))
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
		if(rev >= 0 && rev < len rl.entrycache) {
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

	clpath := r.storedir()+"/00changelog";
	(cl, clerr) := Revlog.open(clpath);
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

	(m, merr) := Manifest.parse(mdata);
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
	clpath := r.storedir()+"/00changelog";
	(cl, clerr) := Revlog.open(clpath);
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
	clpath := r.storedir()+"/00changelog";
	(cl, clerr) := Revlog.open(clpath);
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


Hunk: adt {
	start, end:	int;
	buf: array of byte;

	text:	fn(h: self ref Hunk): string;
};

Patch: adt {
	l:	list of ref Hunk;

	parse:	fn(d: array of byte): (ref Patch, string);
	merge:	fn(hl: list of ref Patch): ref Patch;
	apply:	fn(h: self ref Patch, d: array of byte): array of byte;
	sizediff:	fn(h: self ref Patch): int;
	text:	fn(h: self ref Patch): string;
};

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
			return (nil, "bad data, start > end");
		if(o+length > len d)
			return (nil, "bad data, hunk points past buffer");
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
		return (nil, "bad revision value for parent or base revision");
	
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
		raise "bogus hex string";

	d := array[len s/2] of byte;
	for(i := 0; i < len d; i++) {
		(num, rem) := str->toint(s[i*2:(i+1)*2], 16);
		if(rem != nil)
			raise "bad hex string";
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

say(s: string)
{
	if(debug)
		warn(s);
}

warn(s: string)
{
	sys->fprint(sys->fildes(2), "%s\n", s);
}
