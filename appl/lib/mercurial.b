implement Mercurial;

# todo
# - when to look for .d?  my repo's don't have any...
# - revlog revision & flags in .i?
# - flags in manifest?  like file mode (permissions)?
# - long entries in manifest?
# - keep track of entries while reading revlog index, so we can read base+updates without constantly reading the index

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

Change.parse(data: array of byte): (ref Change, string)
{
	say("change.parse");

	c := ref nullchange;

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
	s += sprint("manifest nodeid: %s\n", c.manifestnodeid.text());
	s += sprint("committer: %s\n", c.who);
	when := daytime->gmt(c.when);
	when.tzoff = c.tzoff;
	s += sprint("date: %s\n", daytime->text(when));
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
		if(len nodeid > 40) {
			say(sprint("long: %s", hex(line)));
			say(sprint("nodeid=%q path=%q", hex(nodeid[:40]), string path));
			say(sprint("end=%q", string nodeid[40:]));
			# xxx
			return (nil, "long entry in manifest");
		} else {
			say(sprint("nodeid=%q path=%q", string nodeid, string path));
			mf := ref Manifestfile(string path, 0, ref Nodeid(unhex(string nodeid)));
			files = mf::files;
		}
	}
	files = lists->reverse(files);
	return (ref Manifest(files), nil);
}


Revlog.open(path: string): (ref Revlog, string)
{
	say(sprint("revlog.open %q", path));
	ipath := path+".i";
	rl := ref Revlog(path, nil, nil, 0, 0, nil);
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

lookup(rl: ref Revlog, id: int): ref Nodeid
{
	if(id == Nullnode)
		return nullnode;

	if(!rl.isindexonly()) {
		(e, err) := findrevnode(rl, id, nil, 0);
		if(err != nil)
			return nil;
		return e.nodeid;
	}

	for(l := rl.nodes; l != nil; l = tl l) {
		(p, nodeid) := hd l;
		if(p == id)
			return nodeid;
	}
	return nil;
}

add(rl: ref Revlog, id: int, n: ref Nodeid)
{
	if(rl.isindexonly())
		rl.nodes = (id, n)::rl.nodes;
}

findrevnode(rl: ref Revlog, rev: int, nodeid: ref Nodeid, last: int): (ref Entry, string)
{
	say(sprint("findrevnode, rev %d, nodeid %s", rev, nodeid.text()));

	if(last && !rl.isindexonly()) {
		(ok, dir) := sys->fstat(rl.ifd);
		if(ok != 0)
			return (nil, sprint("fstat %q: %r", rl.path));
		if(dir.length % big Entrysize != big 0)
			return (nil, sprint("bad index file, not multiple of entrysize (%d): %bd", Entrysize, dir.length));
		rev = int (dir.length / big Entrysize)-1;
		last = 0;
	}
	if(rev != -1 && !rl.isindexonly()) {
		n := sys->pread(rl.ifd, buf := array[Entrysize] of byte, len buf, big (rev*Entrysize));
		if(n != len buf)
			return (nil, sprint("reading entry at offset %bd: %r", big (rev*Entrysize)));
		return Entry.parse(buf, rev);
	}

	b := bufio->fopen(rl.ifd, Bufio->OREAD);
	o := big 0;
	e: ref Entry;
	for(i := 0;; i++) {
		say(sprint("reading entry from offset %bd", o));
		buf := array[Entrysize] of byte;
		if(b.seek(o, Bufio->SEEKSTART) != o)
			return (nil, "seek failed");
		
		n := b.read(buf, len buf);
		if(n == 0)
			break;
		if(n < 0)
			return (nil, sprint("reading index: %r"));
		err: string;
		(e, err) = Entry.parse(buf, i);
		if(err != nil)
			return (nil, "parsing index entry: "+err);
		if(rl.isindexonly())
			e.ioffset = o+big Entrysize;
		add(rl, i, e.nodeid);

		say(sprint("entry: %s", e.text()));
		o += big Entrysize;
		if(rl.isindexonly())
			o += big e.csize;
		if(rev != -1 && i == rev)
			return (e, nil);
		if(nodeid != nil && Nodeid.cmp(e.nodeid, nodeid) == 0)
			return (e, nil);
	}
	if(last && e != nil)
		return (e, nil);
	return (nil, "no such revision");
}

Revlog.findrev(rl: self ref Revlog, rev: int): (ref Entry, string)
{
	return findrevnode(rl, rev, nil, 0);
}

Revlog.findnodeid(rl: self ref Revlog, n: ref Nodeid): (ref Entry, string)
{
	return findrevnode(rl, -1, n, 0);
}

Revlog.getentry(rl: self ref Revlog, e: ref Entry): (array of byte, string)
{
	say("revlog.getentry, "+e.text());

	fd := rl.dfd;
	if(rl.isindexonly())
		fd = rl.ifd;

	b := bufio->fopen(fd, Bufio->OREAD);
	if(b == nil)
		return (nil, sprint("bufio fopen revlog: %r"));

	say(sprint("reading data from offset %bd, index %d, path %q", e.ioffset, rl.isindexonly(), rl.path));
	if(b.seek(e.ioffset, Bufio->SEEKSTART) != e.ioffset)
		return (nil, "seek failed");

	defl := array[e.csize] of byte;
	n := b.read(defl, len defl);
	if(n != len defl)
		return (nil, sprint("reading data after index entry: %r"));

	if(len defl == 0)
		return (array[0] of byte, nil);

	raw: array of byte;
	case int defl[0] {
	'u' =>	raw = defl[1:];
	0 =>	raw = defl;
	* =>	derr: string;
		(raw, derr) = inflatebuf(defl);
		if(derr != nil)
			return (nil, "inflating data after header: "+derr);
		if(0 && len raw != e.uncsize)  # bogus check?
			return (nil, sprint("incorrect size after inflate, want %d, have %d", e.uncsize, len raw));
	}
	say(sprint("revlog.getentry, returning data (%d bytes): %s", len raw, string raw));
	return (raw, nil);
}

getentryrev(rl: ref Revlog, rev: int): (array of byte, string)
{
	(e, err) := rl.findrev(rev);
	if(err != nil)
		return (nil, err);

	return rl.getentry(e);
}

Revlog.getfile(rl: self ref Revlog, e: ref Entry): (array of byte, string)
{
	say("revlog.getfile: "+e.text());

	(d, derr) := getentryrev(rl, e.base);
	if(derr != nil)
		return (nil, "base: "+derr);

	for(i := e.base+1; i <= e.rev; i++) {
		(diff, err) := getentryrev(rl, i);
		if(err != nil)
			return (nil, "diff: "+err);

		say(sprint("diff (base %d, i %d, rev %d)...", e.base, i, e.rev));
		(p, perr) := Patch.parse(diff);
		if(perr != nil)
			return (nil, sprint("error decoding patch: %s", perr));

		say("patch: "+p.text());
		d = p.apply(d);
	}

	par1 := lookup(rl, e.p1);
	par2 := lookup(rl, e.p2);
	if(par1 == nil || par2 == nil)
		return (nil, "could not find parent nodeid");
	node := Nodeid.create(d, par1, par2);
	if(Nodeid.cmp(node, e.nodeid) != 0)
		return (nil, sprint("nodeid mismatch, have %s, header claims %s", node.text(), e.nodeid.text()));

	return (d, nil);
}

Revlog.getrev(rl: self ref Revlog, rev: int): (ref Entry, array of byte, string)
{
	say("revlog.getrev, "+string rev);
	(e, err) := rl.findrev(rev);
	if(err != nil)
		return (nil, nil, err);
	(d, derr) := rl.getfile(e);
	if(derr != nil)
		return (nil, nil, derr);
	return (e, d, nil);
}

Revlog.getnodeid(rl: self ref Revlog, n: ref Nodeid): (ref Entry, array of byte, string)
{
	say("revlog.getnodeid, "+n.text());
	(e, err) := rl.findnodeid(n);
	if(err != nil)
		return (nil, nil, err);
	(d, derr) := rl.getfile(e);
	if(derr != nil)
		return (nil, nil, derr);
	return (e, d, nil);
}

Revlog.lastrev(rl: self ref Revlog): (ref Entry, string)
{
	return findrevnode(rl, -1, nil, 1);
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

	repo := ref Repo(path, requires, name);
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
	path = r.storedir()+"/"+r.escape(path);
	return Revlog.open(path);
}


Repo.manifest(r: self ref Repo, rev: int): (ref Change, ref Manifest, string)
{
	say("repo.manifest");

	clpath := r.storedir()+"/00changelog";
	(cl, clerr) := Revlog.open(clpath);
	if(clerr != nil)
		return (nil, nil, clerr);
	(nil, cdata, clderr) := cl.getrev(rev);
	if(clderr != nil)
		return (nil, nil, clderr);

	(c, cerr) := Change.parse(cdata);
	if(cerr != nil)
		return (nil, nil, cerr);

	say("repo.manifest, have change, manifest nodeid "+c.manifestnodeid.text());

	mpath := r.storedir()+"/00manifest";
	(mrl, mrlerr) := Revlog.open(mpath);
	if(mrlerr != nil)
		return (nil, nil, mrlerr);
	
	(nil, mdata, mderr) := mrl.getnodeid(c.manifestnodeid);
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
	(nil, data, derr) := rl.getnodeid(nodeid);
	if(derr != nil)
		return (nil, derr);
	return (data, nil);
}

Repo.lastrev(r: self ref Repo): (int, string)
{
	clpath := r.storedir()+"/00changelog";
	(cl, clerr) := Revlog.open(clpath);
	if(clerr != nil)
		return (-1, clerr);

	(e, rerr) := cl.lastrev();
	if(rerr != nil)
		return (-1, rerr);
	return (e.rev, nil);
}

Repo.change(r: self ref Repo, rev: int): (ref Change, string)
{
	clpath := r.storedir()+"/00changelog";
	(cl, clerr) := Revlog.open(clpath);
	if(clerr != nil)
		return (nil, clerr);
	(nil, cdata, clderr) := cl.getrev(rev);
	if(clderr != nil)
		return (nil, clderr);

	(c, cerr) := Change.parse(cdata);
	return (c, cerr);
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
	(e.p1, o) = g32(buf, o); # xxx set to ffffffff?
	(e.p2, o) = g32(buf, o); # idem
	node := array[20] of byte;
	node[:] = buf[o:o+20];
	e.nodeid = ref Nodeid(node);
	o += 20;
	if(len buf-o != 12)
		return (nil, "wrong number of superfluous bytes");
	
	return (e, nil);
}

Entry.text(e: self ref Entry): string
{
	return sprint("<Entry rev=%d, off=%bd,%bd flags=%x size=%d,%d base=%d link=%d p1=%d p2=%d nodeid=%s>", e.rev, e.offset, e.ioffset, e.flags, e.csize, e.uncsize, e.base, e.link, e.p1, e.p2, e.nodeid.text());
}


inflatebuf(src: array of byte): (array of byte, string)
{
	origsrc := src;
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
