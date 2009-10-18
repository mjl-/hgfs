implement Mercurial;

include "sys.m";
	sys: Sys;
	sprint: import sys;
include "bufio.m";
	bufio: Bufio;
	Iobuf: import bufio;
include "env.m";
	env: Env;
include "filter.m";
	inflate: Filter;
	deflate: Filter;
include "filtertool.m";
	filtertool: Filtertool;
include "keyring.m";
	keyring: Keyring;
	DigestState: import keyring;
include "string.m";
	str: String;
include "daytime.m";
	daytime: Daytime;
include "tables.m";
	tables: Tables;
	Strhash: import tables;
include "util0.m";
	util: Util0;
	eq, hasstr, p32, p32i, p16, stripws, prefix, suffix, rev, max, l2a, readfile, writefile: import util;
include "mercurial.m";


Cachemax:	con 64;  # max number of cached items in a revlog

init()
{
	sys = load Sys Sys->PATH;
	bufio = load Bufio Bufio->PATH;
	bufio->open("/dev/null", Bufio->OREAD); # xxx ensure bufio is properly initialized
	env = load Env Env->PATH;
	keyring = load Keyring Keyring->PATH;
	str = load String String->PATH;
	daytime = load Daytime Daytime->PATH;
	tables = load Tables Tables->PATH;
	inflate = load Filter Filter->INFLATEPATH;
	inflate->init();
	deflate = load Filter Filter->DEFLATEPATH;
	deflate->init();
	filtertool = load Filtertool Filtertool->PATH;
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


differs(repo: ref Repo, mf: ref Mfile): int
{
	f := repo.workroot()+"/"+mf.path;
	(ok, dir) := sys->stat(f);
	if(ok != 0)
		return 1;

	mfx := (mf.flags & Fexec) != 0;
	fx := (dir.mode & 8r100) != 0;
	if(mfx != fx)
		return 1;

	buf := readfile(f, -1);
	if(buf == nil)
		return 1;

	{
		rl := repo.xopenrevlog(mf.path);
		e := rl.xfindnodeid(mf.nodeid, 1);
		p1 := p2 := nullnode;
		if(e.p1 >= 0) {
			p1 = rl.xfind(e.p1).nodeid;
			if(e.p2 >= 0)
				p2 = rl.xfind(e.p2).nodeid;
		}

		return mf.nodeid != xcreatenodeid(buf, p1, p2);
	} exception x {
	"hg:*" =>
		warn(sprint("%q: %s", mf.path, x[3:]));
		return 1;
	}
}

escape(s: string): string
{
	fa := array of byte s;
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

xsanitize(s: string): string
{
	slash := str->prefix("/", s);
	r: list of string;
	for(l := sys->tokenize(s, "/").t1; l != nil; l = tl l)
		case hd l {
		"." =>	;
		".." =>
			if(r == nil)
				error("bogus .. in path");
			r = tl r;
		* =>
			r = hd l::r;
		}
	s = "";
	for(l = rev(r); l != nil; l = tl l)
		s += "/"+hd l;
	if(s != nil)
		s = s[1:];
	if(slash)
		s = "/"+s;
	if(s == nil)
		s = ".";
	return s;
}

ensuredirs(base, path: string)
{
	s := base;
	for(l := sys->tokenize(str->splitstrr(path, "/").t0, "/").t1; l != nil; l = tl l) {
		s += "/"+hd l;
		if(sys->create(s, Sys->OREAD, 8r777|Sys->DMDIR) == nil)
			say(sprint("create %q failed: %r", s));
	}
}

xreaduser(r: ref Repo): string
{
	c := xreadconfigs(r);
	(has, user) := c.find("ui", "username");
	if(!has)
		 user = sprint("%s@%s", string readfile("/dev/user", -1), string readfile("/dev/sysname", -1));
	return user;
}

dumpconfigs(c: ref Configs)
{
	say("configs:");
	for(l := c.l; l != nil; l = tl l) {
		say("config:");
		cc := hd l;
		for(ll := cc.l; ll != nil; ll = tl ll) {
			sec := hd ll;
			say(sprint("section %q", sec.name));
			for(p := sec.l; p != nil; p = tl p)
				say(sprint("%s = %q", (hd p).t0, (hd p).t1));
			say("");
		}
		say("");
	}
}

xreadconfigs(r: ref Repo): ref Configs
{
	c0 := xreadconfig(env->getenv("home")+"/lib/hgrc");
	c1 := r.xreadconfig();
	c := ref Configs;
	if(c1 != nil)
		c.l = c1::c.l;
	if(c0 != nil)
		c.l = c0::c.l;
	#dumpconfigs(c);
	return c;
}


xentrylogtext(r: ref Repo, ents: array of ref Entry, e: ref Entry, verbose: int): string
{
	ch := r.xchange(e.rev);
	s := "";
	s += entrylogkey("changeset", sprint("%d:%s", e.rev, e.nodeid[:12]));
	(k, branch) := ch.findextra("branch");
	if(k != nil)
		s += entrylogkey("branch", branch);
	for(tags := r.xrevtags(e.nodeid); tags != nil; tags = tl tags)
		s += entrylogkey("tag", (hd tags).name);
	if((e.p1 >= 0 && e.p1 != e.rev-1) || (e.p2 >= 0 && e.p2 != e.rev-1)) {
		if(e.p1 >= 0)
			s += entrylogkey("parent", sprint("%d:%s", ents[e.p1].rev, ents[e.p1].nodeid[:12]));
		if(e.p2 >= 0)
			s += entrylogkey("parent", sprint("%d:%s", ents[e.p2].rev, ents[e.p2].nodeid[:12]));
	} else if(e.p1 < 0 && e.rev != e.p1+1)
		s += entrylogkey("parent", "-1:000000000000");
	s += entrylogkey("user", ch.who);
	s += entrylogkey("date", sprint("%s %+d", daytime->text(daytime->gmt(ch.when+ch.tzoff)), ch.tzoff));
	if(verbose) {
		files := "";
		for(l := ch.files; l != nil; l = tl l)
			files += sprint(" %q", hd l);
		if(files != nil)
			files = files[1:];
		s += entrylogkey("files", files);
		s += "description:\n"+ch.msg;
	} else
		s += entrylogkey("summary", str->splitstrl(ch.msg, "\n").t0);
	s += "\n";
	return s;
}

entrylogkey(k, v: string): string
{
	return sprint("%-12s %s\n", k+":", v);
}

xopencreate(f: string, mode, perm: int): ref Sys->FD
{
	fd := sys->create(f, mode|Sys->OEXCL, perm);
	if(fd == nil) {
		fd = sys->open(f, mode);
		if(fd == nil)
			error(sprint("open %q: %r", f));
	}
	return fd;
}

xopen(f: string, mode: int): ref Sys->FD
{
	fd := sys->open(f, mode);
	if(fd == nil)
		error(sprint("open %q: %r", f));
	return fd;
}

xcreate(f: string, mode, perm: int): ref Sys->FD
{
	fd := sys->create(f, mode, perm);
	if(fd == nil)
		error(sprint("create %q: %r", f));
	return fd;
}

xbopencreate(f: string, mode, perm: int): ref Iobuf
{
	fd := xopencreate(f, mode, perm);
	b := bufio->fopen(fd, mode);
	if(b == nil)
		error(sprint("fopen %q: %r", f));
	return b;
}

xdirstate(r: ref Repo, all: int): ref Dirstate
{
	path := r.path+"/dirstate";
	b := bufio->open(path, Bufio->OREAD);
	if(b == nil)
		return ref Dirstate (1, nullnode, nullnode, nil, nil);

	n1 := b.read(p1d := array[20] of byte, len p1d);
	n2 := b.read(p2d := array[20] of byte, len p2d);
	if(n1 != len p1d || n2 != len p2d)
		error(sprint("reading parents: %r"));
	p1 := hex(p1d);
	p2 := hex(p2d); 
	if(p1 == nullnode && p2 != nullnode)
		error(sprint("p1 nullnode but p2 not, %s", p2));
	r.xlookup(p1, 1);
	r.xlookup(p2, 1);

	root := r.workroot();

	buf := array[1+4+4+4+4] of byte;
	now := daytime->now();
	tab := Strhash[ref Dsfile].new(101, nil);
	ds := ref Dirstate (0, p1, p2, nil, nil);
	for(;;) {
		off := b.offset();
		n := b.read(buf, len buf);
		if(n == 0)
			break;
		if(n != len buf)
			error(sprint("bad dirstate, early eof for path header, want %d, saw %d", len buf, n));
		dsf := ref Dsfile;
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
		dsf.missing = 0;

		f := root+"/"+dsf.path;
		(ok, dir) := sys->stat(f);
		if(ok != 0) {
			if(dsf.state != STremove)
				dsf.missing = 1;
		} else {
			case dsf.state {
			STremove or
			STadd or
			STneedmerge =>
				;
			STnormal =>
				if(dsf.size >= 0 && big dsf.size != dir.length) {
					dsf.mtime = dir.mtime;
					dsf.size = SZdirty;
				} else if(dsf.size == SZcheck || dsf.mtime != now || dsf.mtime >= now-4) {
					exp := r.xread(dsf.path, ds);
					cur := xreadfile(f);
					if(eq(exp, cur))
						dsf.size = int dir.length;
					else
						dsf.size = SZdirty;
					dsf.mtime = dir.mtime;
					ds.dirty++;
				}
			}
		}
		tab.add(dsf.path, dsf);
		ds.l = dsf::ds.l;
	}

	if(all)
		xdirstatewalk(root, "", ds, tab);
	ds.l = util->rev(ds.l);
	return ds;
}

xdirstatewalk(root, path: string, ds: ref Dirstate, tab: ref Strhash[ref Dsfile])
{
say(sprint("xdirstatewalk, %q", path));
	if(path == ".hg")
		return;

	f := root;
	if(path != nil)
		f += "/"+path;
	fd := sys->open(f, Sys->OREAD);
	if(fd == nil)
		error(sprint("open %q: %r", f));

	for(;;) {
		(n, dirs) := sys->dirread(fd);
		if(n < 0)
			error(sprint("dirread %q: %r", f));
		if(n == 0)
			break;
		for(i := 0; i < n; i++) {
			d := dirs[i];
			npath := path;
			if(npath != nil)
				npath += "/";
			npath += d.name;
			if(tab.find(npath) != nil)
				continue;
			if((d.mode&Sys->DMDIR) == 0) {
				dsf := ref Dsfile (STuntracked, d.mode&8r777, SZcheck, d.mtime, npath, nil, 0);
				ds.l = dsf::ds.l;
say(sprint("xdirstatewalk, untracked file %q", npath));
			} else
				xdirstatewalk(root, npath, ds, tab);
		}
	}
}


getline(b: ref Iobuf): string
{
	l := b.gets('\n');
	if(l != nil && l[len l-1] == '\n')
		l = l[:len l-1];
	return l;
}

nullchange: Change;

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

Manifest.xpack(m: self ref Manifest): array of byte
{
	s := "";
	for(i := 0; i < len m.files; i++) {
		mf := m.files[i];
		s += mf.path+"\0"+mf.nodeid;
		if(mf.flags & Flink)
			s += "l";
		if(mf.flags & Fexec)
			s += "x";
		s += "\n";
	}
	return array of byte s;
}

Manifest.xparse(d: array of byte, n: string): ref Manifest
{
	files: list of ref Mfile;

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
		mf := ref Mfile(string path, 0, string nodeid, flags);
		files = mf::files;
	}
	return ref Manifest(n, l2a(util->rev(files)));
}

Manifest.find(m: self ref Manifest, path: string): ref Mfile
{
	for(i := 0; i < len m.files; i++)
		if(m.files[i].path == path)
			return m.files[i];
	return nil;
}

Manifest.add(m: self ref Manifest, mf: ref Mfile)
{
	for(i := 0; i < len m.files; i++)
		if(mf.path < m.files[i].path)
			break;
	nf := array[len m.files+1] of ref Mfile;
	nf[:] = m.files[:i];
	nf[i] = mf;
	nf[i+1:] = m.files[i:];
	m.files = nf;
}

Manifest.del(m: self ref Manifest, path: string): int
{
	for(i := 0; i < len m.files; i++)
		if(m.files[i].path == path) {
			m.files[i:] = m.files[i+1:];
			m.files = m.files[:len m.files-1];
			return 1;
		}
	return 0;
}

xreopen(rl: ref Revlog)
{
	if(rl.ifd == nil) {
		f := rl.path+".i";
		rl.ifd = sys->open(f, Sys->OREAD);
		if(rl.ifd == nil) {
			rl.flags = Indexonly;
			err := sprint("open %q: %r", f);
			(ok, nil) := sys->stat(f);
			if(ok != 0)
				return;  # absent file is okay, xxx perhaps check error string?
			error(err);
		}
	}

	# test whether we need to reread index files
	(ok, dir) := sys->fstat(rl.ifd);
	if(ok < 0)
		error(sprint("%r"));
	if(dir.length == rl.ilength && dir.mtime == rl.imtime && dir.qid.vers == rl.ivers)
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
		rl.dfd = xopen(dpath, Sys->OREAD);
		# xxx verify .d file is as expected?
	}

	xreadrevlog(rl, ib);
	rl.ilength = dir.length;
	rl.imtime = dir.mtime;
	rl.imtime = dir.qid.vers;
}

# read through the entire revlog, store all entries in rl.entries.
# revlog's are usually very small.
xreadrevlog(rl: ref Revlog, ib: ref Iobuf)
{
	indexonly := isindexonly(rl);

	ib.seek(big 0, Bufio->SEEKSTART);

	l: list of ref Entry;
	rl.tab = rl.tab.new(101, nil);
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
		rl.tab.add(e.nodeid, e);
	}
	rl.ents = l2a(util->rev(l));
	rl.cache = array[len rl.ents] of array of byte;
	rl.ncache = 0;
	rl.full = nil;
	rl.fullrev = -1;
say(sprint("readrevlog, len ents %d", len rl.ents));
}


Revlog.xopen(storedir, path: string, cacheall: int): ref Revlog
{
	say(sprint("revlog.open %q", path));
	rl := ref Revlog;
	rl.storedir = storedir;
	rl.rlpath = path;
	rl.path = storedir+"/"+path;
	rl.fullrev = -1;
	rl.cacheall = cacheall;

	rl.ilength = ~big 0;
	rl.imtime = ~0;
	rl.ivers = ~0;
	rl.tab = rl.tab.new(101, nil);

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
	"hg:*" =>
		;
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
		error(sprint("nodeid mismatch in %q, have %q, header claims %q, (p1 %q p2 %q, len %d, entry %s)", rl.path, n, e.nodeid, pn1, pn2, len d, e.text()));
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
	0 =>	return d;	# common case for patches
	* =>	return xinflate(d);
	}
}

compress(d: array of byte): array of byte
{
	(nd, err) := filtertool->convert(deflate, "z", d);
	if(err != nil)
		error("deflate: "+err);
	return nd;
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

Revlog.xget(rl: self ref Revlog, rev: int): array of byte
{
	e := rl.xfind(rev);
	return xget(rl, e, 0);
}

Revlog.xgetnodeid(rl: self ref Revlog, n: string): array of byte
{
	e := rl.xfindnodeid(n, 1);
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

	if(prev >= 0 && prev == e.rev-1 && e.base != e.rev)
		return xgetdata(rl, e);

	buf := xget(rl, e, 1);
	obuflen := 0;
	if(prev >= 0) {
		pe := rl.xfind(prev);
		obuflen = pe.uncsize;
	}
	#say(sprint("delta with full contents, start %d end %d size %d, e %s", 0, obuflen, len buf, e.text()));
	delta := array[3*4+len buf] of byte;
	o := 0;
	o = p32i(delta, o, 0); # start
	o = p32i(delta, o, obuflen); # end
	o = p32i(delta, o, len buf); # size
	delta[o:] = buf;
	return delta;
}

Revlog.xstorebuf(rl: self ref Revlog, buf: array of byte, rev: int): (int, array of byte)
{
	# xxx actually make the delta, return base != rev.

	compr := compress(buf);
	if(0 && len compr < len buf*90/100) {
		return (rev, compr);
	} else {
		nbuf := array[1+len buf] of byte;
		nbuf[0] = byte 'u';
		nbuf[1:] = buf;
		return (rev, nbuf);
	}
}

Revlog.xlength(rl: self ref Revlog, rev: int): big
{
	return big rl.xfind(rev).uncsize;
}

Revlog.xfind(rl: self ref Revlog, rev: int): ref Entry
{
	xreopen(rl);

	# looking for last entry
	# xxx is this really needed?
	if(rev < 0) {
		if(len rl.ents == 0)
			error("no revisions yet");
		return rl.ents[len rl.ents-1];
	}
	if(rev >= len rl.ents)
		error(sprint("unknown revision %d", rev));
	return rl.ents[rev];
}


Revlog.xfindnodeid(rl: self ref Revlog, n: string, need: int): ref Entry
{
	xreopen(rl);
	e := rl.tab.find(n);
	if(e == nil && need)
		error(sprint("no nodeid %q", n));
	return e;
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

Revlog.xappend(rl: self ref Revlog, r: ref Repo, tr: ref Transact, p1, p2: string, link: int, buf: array of byte): ref Entry
{
	xreopen(rl);

	p1rev := p2rev := -1;
	if(p1 != nullnode) {
		p1rev = rl.xfindnodeid(p1, 1).rev;
		if(p2 != nullnode)
			p2rev = rl.xfindnodeid(p2, 1).rev;
	}
	nodeid := xcreatenodeid(buf, p1, p2);

	e := rl.xfindnodeid(nodeid, 0);
	if(e != nil)
		return e;

	ipath := rl.path+".i";
	dpath := rl.path+".d";
	isize := dsize := big 0;
	orev := -1;
	nrev := 0;
	offset := big 0;
	if(len rl.ents > 0) {
		orev = len rl.ents-1;
		nrev = orev+1;
		ee := rl.ents[orev];
		offset = ee.offset+big ee.csize;
		if(rl.isindexonly()) {
			isize = ee.ioffset+big ee.csize;
		} else {
			isize = big (len rl.ents*Entrysize);
			dsize = ee.offset+big ee.csize;
		}
	}

	if(!tr.has(ipath))
		tr.add(rl.rlpath+".i", isize);

	# verify files are what we expect them to be, for sanity
	if(isize != big 0) {
		(ok, dir) := sys->stat(ipath);
		if(ok != 0)
			error(sprint("%q: %r", ipath));
		if(dir.length != isize)
			error(sprint("%q: unexpected length %bd, expected %bd", ipath, dir.length, isize));
	}
	if(dsize != big 0) {
		(ok, dir) := sys->stat(dpath);
		if(ok != 0)
			error(sprint("%q: %r", dpath));
		if(dir.length != dsize)
			error(sprint("%q: unexpected length %bd, expected %bd", dpath, dir.length, dsize));
	}

	uncsize := len buf;
	base: int;
	(base, buf) = rl.xstorebuf(buf, nrev);

	# if we grow a .i-only revlog to beyond 128k, create a .d and rewrite the .i
	isindexonly := rl.isindexonly();
	if(isindexonly && isize+big Entrysize+big len buf >= big (128*1024)) {
		say(sprint("no longer indexonly, writing %q", dpath));

		ifd := xopen(ipath, Sys->OREAD);
		n := sys->readn(ifd, ibuf := array[int isize] of byte, len ibuf);
		if(n < 0)
			error(sprint("read %q: %r", ipath));
		if(n != len ibuf)
			error(sprint("short read on %q, expected %d, got %d", ipath, n, len ibuf));

		nipath := ipath+".new";
		r.xensuredirs(nipath);
		nifd := xcreate(nipath, Sys->OWRITE|Sys->OEXCL, 8r666);
		ib := bufio->fopen(nifd, Sys->OWRITE);

		dfd := xcreate(dpath, Sys->OWRITE|Sys->OEXCL, 8r666);
		db := bufio->fopen(dfd, Sys->OWRITE);
		isize = big 0;
		dsize = big 0;
		for(i := 0; i < len rl.ents; i++) {
			e = rl.ents[i];

			if(i == 0)
				p16(ibuf, 0, 0); # clear the Indexonly bits

			ioff := int e.ioffset;
			if(ib.write(ibuf[ioff-Entrysize:ioff], Entrysize) != Entrysize)
				error(sprint("write %q: %r", nipath));

			if(db.write(ibuf[ioff:ioff+e.csize], e.csize) != e.csize)
				error(sprint("write %q: %r", dpath));

			dsize += big e.csize;
			e.ioffset = big 0;
		}
		isize = big (len rl.ents*Entrysize);
		if(ib.flush() == Bufio->ERROR)
			error(sprint("write %q: %r", ipath));
		if(db.flush() == Bufio->ERROR)
			error(sprint("write %q: %r", dpath));

		# xxx styx cannot do this atomically...
		say(sprint("removing current, renaming new, %q and %q", ipath, nipath));
		ndir := sys->nulldir;
		ndir.name = str->splitstrr(ipath, "/").t1;
		if(sys->remove(ipath) != 0 || sys->fwstat(nifd, ndir) != 0)
			error(sprint("remove %q and rename of %q failed: %r", ipath, nipath));

		isindexonly = 0;

		tr.add(rl.rlpath+".d", dsize);
		tr.add(rl.rlpath+".i", isize);
	}

	ioffset := big 0;
	if(isindexonly)
		ioffset = isize+big Entrysize;

	flags := 0;
	e = ref Entry (nrev, offset, ioffset, flags, len buf, uncsize, base, link, p1rev, p2rev, nodeid);
say(sprint("revlog %q, will be adding %s", rl.path, e.text()));
	ebuf := array[Entrysize] of byte;
	e.xpack(ebuf, isindexonly);
	nents := array[len rl.ents+1] of ref Entry;
	nents[:] = rl.ents;
	nents[len rl.ents] = e;
	rl.ents = nents;
	rl.tab.add(e.nodeid, e);

	r.xensuredirs(ipath);
	ifd := xopencreate(ipath, Sys->OWRITE, 8r666);
	if(sys->pwrite(ifd, ebuf, len ebuf, isize) != len ebuf)
		error(sprint("write %q: %r", ipath));
	isize += big Entrysize;
	if(isindexonly) {
		if(sys->pwrite(ifd, buf, len buf, isize) != len buf)
			error(sprint("write %q: %r", ipath));
	} else {
		if(!tr.has(dpath))
			tr.add(rl.rlpath+".d", dsize);
		dfd := xopencreate(dpath, Sys->OWRITE, 8r666);
		if(sys->pwrite(dfd, buf, len buf, dsize) != len buf)
			error(sprint("write %q: %r", dpath));
	}
	return e;
}

xreadlines(b: ref Iobuf): list of string
{
	l: list of string;
	for(;;) {
		s := b.gets('\n');
		if(s == nil)
			break;
		if(s[len s-1] == '\n')
			s = s[:len s-1];
		l = s::l;
	}
	return l;
}

Repo.xopen(path: string): ref Repo
{
	say("repo.open");

	reqpath := path+"/requires";
	b := bufio->open(reqpath, Bufio->OREAD);
	if(b == nil)
		error(sprint("repo \"requires\" file: %r"));
	requires := xreadlines(b);

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
	return escape(path);
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
	return Revlog.xopen(r.storedir(), "data/"+r.escape(path), 0);
}

Repo.xrevision(r: self ref Repo, rev: int): (ref Change, ref Manifest)
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

Repo.xmanifest(r: self ref Repo, n: string): ref Manifest
{
	if(n == nullnode)
		return ref Manifest (n, array[0] of ref Mfile);
	rev := r.xlookup(n, 1).t0;
	c := r.xchange(rev);
	ml := r.xmanifestlog();
	md := ml.xgetnodeid(c.manifestnodeid);
	return Manifest.xparse(md, c.manifestnodeid);
}

Repo.xlastrev(r: self ref Repo): int
{
	return r.xchangelog().xlastrev();
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

Dirstate.packedsize(ds: self ref Dirstate): int
{
	n := 20+20;
	for(l := ds.l; l != nil; l = tl l) {
		f := hd l;
		if(f.state == STuntracked)
			continue;
		n += 1+4+4+4+4+len array of byte f.path;
		if(f.origpath != nil)
			n += 1+len array of byte f.origpath;
	}
	return n;
}

Dirstate.pack(ds: self ref Dirstate, buf: array of byte)
{
	if(len ds.p1 != 40)
		error(sprint("bad dirstate p1 %#q", ds.p1));
	if(len ds.p2 != 40)
		error(sprint("bad dirstate p2 %#q", ds.p2));

	o := 0;
	buf[o:] = unhex(ds.p1);
	o += 20;
	buf[o:] = unhex(ds.p2);
	o += 20;
	for(l := ds.l; l != nil; l = tl l) {
		f := hd l;
		if(f.state == STuntracked)
			continue;
		buf[o++] = byte statestrs[f.state][0];
		o = p32i(buf, o, f.mode);
		o = p32i(buf, o, f.size);
		o = p32i(buf, o, f.mtime);
		path := f.path;
		if(f.origpath != nil)
			path += "\0"+f.origpath;
		pathbuf := array of byte path;
		o = p32i(buf, o, len pathbuf);
		buf[o:] = pathbuf;
		o += len pathbuf;
	}
}

Dirstate.find(ds: self ref Dirstate, path: string): ref Dsfile
{
	for(l := ds.l; l != nil; l = tl l)
		if((hd l).path == path)
			return hd l;
	return nil;
}

Dirstate.findall(ds: self ref Dirstate, pp: string, untracked: int): list of ref Dsfile
{
	pp = xsanitize(pp);
	if(pp == ".")
		dir := pp = "";
	else
		dir = pp+"/";
	r: list of ref Dsfile;
	for(l := ds.l; l != nil; l = tl l) {
		dsf := hd l;
		if((dsf.state != STuntracked || untracked) && (dsf.path == pp || str->prefix(dir, dsf.path)))
			r = hd l::r;
	}
	return rev(r);
}

Dirstate.enumerate(ds: self ref Dirstate, base: string, paths: list of string, untracked, vflag: int): (list of string, list of ref Dsfile)
{
	if(paths == nil) {
		l := ds.findall(base, untracked);
		if(l == nil)
			return (base::nil, nil);
		return (nil, l);
	}

	tab := Strhash[ref Dsfile].new(101, nil);
	r: list of ref Dsfile;
	nomatch: list of string;
	for(; paths != nil; paths = tl paths) {
		p := base+"/"+hd paths;
		n := 0;
		for(l := ds.findall(p, untracked); l != nil; l = tl l) {
			dsf := hd l;
			if(dsf.state != STuntracked)
				n++;
			if(tab.find(dsf.path) != nil)
				continue;
			tab.add(dsf.path, dsf);
			r = dsf::r;
		}
		if(n == 0) {
			if(vflag)
				sys->fprint(sys->fildes(2), "%q: not tracked\n", hd paths);
			nomatch = hd paths::nomatch;
		}
	}
	return (rev(nomatch), rev(r));
}

Dirstate.add(ds: self ref Dirstate, dsf: ref Dsfile)
{
	ds.l = dsf::ds.l;
}

Dirstate.del(ds: self ref Dirstate, path: string)
{
	r: list of ref Dsfile;
	for(l := ds.l; l != nil; l = tl l)
		if((hd l).path != path)
			r = hd l::r;
	ds.l = rev(r);
}

Dirstate.haschanges(ds: self ref Dirstate): int
{
	for(l := ds.l; l != nil; l = tl l)
		if((hd l).isdirty())
			return 1;
	return 0;
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
		return "default";
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

Repo.xworkdir(r: self ref Repo): string
{
	root := r.workroot();
	cwd := sys->fd2path(sys->open(".", Sys->OREAD));
	if(!str->prefix(root, cwd))
		error(sprint("cannot determine current directory in repository, workroot %q, cwd %q", root, cwd));
	base := cwd[len root:];
	base = str->drop(base, "/");
	if(base == nil)
		base = ".";
	return base;
}

Repo.xtags(r: self ref Repo): list of ref Tag
{
	tags: list of ref Tag;
	tagtab := Strhash[ref Tag].new(31, nil);
	heads := r.xheads();
	for(i := len heads-1; i >= 0; i--) {
		e := heads[i];
		(nil, m) := r.xrevision(e.rev);
		mf := m.find(".hgtags");
		if(mf == nil)
			continue;
		buf := r.xget(mf.nodeid, ".hgtags");
		for(l := xparsetags(r, string buf); l != nil; l = tl l) {
			t := hd l;
			if(tagtab.find(t.name) == nil) {
				tags = t::tags;
				tagtab.add(t.name, t);
			}
		}
	}
	tagtab = nil;
	return tags;
}

Repo.xrevtags(r: self ref Repo, revstr: string): list of ref Tag
{
	(rev, n) := r.xlookup(revstr, 1);

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
		buf: array of byte;
		{
			buf = r.xget(e.nodeid, ".hgtags");
		} exception {
		"hg:*" =>
			continue;
		}
		l := xparsetags(r, string buf);
		for(; l != nil; l = tl l) {
			t := hd l;
			if(t.n == n)
				tags = t::tags;
		}
	}
	if(len ents > 0 && ents[len ents-1].rev == rev)
		tags = ref Tag ("tip", n, rev)::tags;
	return tags;
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
		e := cl.xfindnodeid(n, 1);
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
		e := cl.xfindnodeid(n, 1);
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
		r.cl = Revlog.xopen(r.storedir(), "00changelog", 0);
	return r.cl;
}

Repo.xmanifestlog(r: self ref Repo): ref Revlog
{
	if(r.ml == nil)
		r.ml = Revlog.xopen(r.storedir(), "00manifest", 0);
	return r.ml;
}

Repo.xlookup(r: self ref Repo, s: string, need: int): (int, string)
{
	if(s == "null" || s == nullnode)
		return (-1, nullnode);

	cl := r.xchangelog();
	ents := cl.xentries();

	if(s == "tip" || s == ".") {
		if(len ents == 0)
			return (-1, "null");  # should this raise error if need is set?
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
			e := cl.xfindnodeid(s, 0);
			if(e == nil) {
				if(need)
					error("no such nodeid "+s);
				return (-1, nil);
			}
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

	if(need)
		error(sprint("no such revision %#q", s));
	return (-1, nil);
}

Repo.xget(r: self ref Repo, revstr, path: string): array of byte
{
	(rev, nil) := r.xlookup(revstr, 1);
	(nil, m) := r.xrevision(rev);
	mf := m.find(path);
	if(mf == nil)
		error(sprint("file %#q not in revision %q", path, revstr));
	rl := r.xopenrevlog(path);
	return rl.xgetnodeid(mf.nodeid);
}

xgetmanifest(r: ref Repo, n: string): ref Manifest
{
	if(n == nullnode)
		return ref Manifest (n, array[0] of ref Mfile);
	return r.xrevision(r.xlookup(n, 1).t0).t1;
}

Repo.xread(r: self ref Repo, path: string, ds: ref Dirstate): array of byte
{
	# xxx replace xgetmanifest with r.xmanifest when it accepts a nodeid
	if(ds.context == nil)
		ds.context = ref Context;

	if(ds.context.m1 == nil)
		ds.context.m1 = xgetmanifest(r, ds.p1);
	mf1 := ds.context.m1.find(path);
	if(mf1 != nil)
		return r.xopenrevlog(path).xgetnodeid(mf1.nodeid);

	if(ds.context.m2 == nil)
		ds.context.m2 = xgetmanifest(r, ds.p2);
	mf2 := ds.context.m2.find(path);
	if(mf2 != nil)
		return r.xopenrevlog(path).xgetnodeid(mf2.nodeid);

	error(sprint("%q does not exist in parents", path));
	return nil; # not reached
}

Repo.xensuredirs(r: self ref Repo, fullrlpath: string)
{
	pre := r.storedir()+"/";
	if(!str->prefix(pre, fullrlpath))
		error(sprint("revlog path %#q not in store path %#q", fullrlpath, pre));
	fullrlpath = "./"+str->drop(fullrlpath[len pre:], "/");
	ensuredirs(pre, fullrlpath);

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
	error(sprint("bogus state %d", i));
	return nil; # not reached
}

Dsfile.isdirty(f: self ref Dsfile): int
{
	case f.state {
	STneedmerge or
	STremove or
	STadd =>
		return 1;
	STuntracked =>
		return 0;
	STnormal =>
		return f.size == SZdirty;
	}
	raise "missing case";
}

Dsfile.text(f: self ref Dsfile): string
{
	tm := daytime->local(daytime->now());
	timestr := sprint("%04d-%02d-%02d %2d:%2d:%2d", tm.year+1900, tm.mon+1, tm.mday, tm.hour, tm.min, tm.sec);
	s := sprint("%s %03uo %10d %s %q", statestr(f.state), 8r777&f.mode, f.size, timestr, f.path);
	if(f.origpath != nil)
		s += sprint(" (from %q)", f.origpath);
	s += sprint(" missing %d", f.missing);
	return s;
}


Hunk.text(h: self ref Hunk): string
{
	#return sprint("<hunk s=%d e=%d length=%d buf=%q>", h.start, h.end, len h.buf, string h.buf);
	return sprint("<hunk s=%d e=%d length=%d>", h.start, h.end, len h.buf);
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
			error("bad patch: "+e[len "group:":]);
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
		s += sprint(" %s", (hd l).text());
	if(s != nil)
		s = s[1:];
	return s;
}

nullentry: Entry;

Entry.xpack(e: self ref Entry, buf: array of byte, indexonly: int)
{
	if(len buf < Entrysize)
		error("short Entry buffer");
	o := 0;
	off := e.offset;
	if(e.rev == 0) {
		if(indexonly)
			off |= big Indexonly<<32;
		off |= big Version1<<16;
	}
	o = p48(buf, o, off);
	o = p16(buf, o, e.flags);
	o = p32i(buf, o, e.csize);
	o = p32i(buf, o, e.uncsize);
	o = p32i(buf, o, e.base);
	o = p32i(buf, o, e.link);
	o = p32i(buf, o, e.p1);
	o = p32i(buf, o, e.p2);
	buf[o:] = unhex(e.nodeid);
	o += 20;
	buf[o:] = array[12] of {* => byte 0};
	o += 12;
	if(o != Entrysize)
		error("Entry.pack error");
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


xinflate(d: array of byte): array of byte
{
	(nd, err) := filtertool->convert(inflate, "z", d);
	if(err != nil)
		error("decompress: "+err);
	return nd;
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


Repo.xreadconfig(r: self ref Repo): ref Config
{
	return xreadconfig(r.path+"/hgrc");
}

xreadconfig(path: string): ref Config
{
	b := bufio->open(path, Bufio->OREAD);
	if(b == nil)
		return ref Config; # absence of file is not an error

	sec := ref Section;
	c := ref Config;
	for(;;) {
		s := b.gets('\n');
		if(s == nil)
			break;
		if(!suffix("\n", s))
			error("missing newline at end of file");
		s = s[:len s-1];
		if(s == nil || str->in(s[0], " \t#;")) {
			continue;
		} else if(prefix("[", s)) {
			if(!suffix("]", s))
				error(sprint("missing ']' in section line: %#q", s));
			if(sec.name != nil || sec.l != nil) {
				sec.l = rev(sec.l);
				c.l = sec::c.l;
				sec = ref Section;
			}
			sec.name = s[1:len s-1];
		} else {
			(k, v) := str->splitl(s, "=:");
			if(v == nil)
				error(sprint("missing separator on line: %#q", s));;
			k = stripws(k);
			v = str->drop(v[1:], " \t");
			for(;;) {
				ch := b.getb();
				if(ch != ' ' && ch != '\t') {
					if(ch != bufio->EOF && ch != bufio->ERROR)
						b.ungetb();
					break;
				}
				s = b.gets('\n');
				if(s == nil || s[len s-1] != '\n')
					error("missing newline at end of file");
				v += s[:len s-1];
			}
			sec.l = ref (k, v)::sec.l;
		}
	}
	if(sec.name != nil || sec.l != nil) {
		sec.l = rev(sec.l);
		c.l = sec::c.l;
	}
	c.l = rev(c.l);
	return c;
}

Repo.xtransact(r: self ref Repo): ref Transact
{
	f := r.storedir()+"/undo";
	tr := ref Transact;
	tr.fd = xcreate(f, Sys->OWRITE|Sys->OTRUNC, 8r666);
	tr.tab = tr.tab.new(101, nil);
	return tr;
}

Repo.xrollback(r: self ref Repo, tr: ref Transact)
{
	err: string;
	seen := tr.tab.new(101, nil);
	dir := sys->nulldir;
	storedir := r.storedir();
	for(l := tr.l; l != nil; l = tl l) {
		rs := hd l;
		if(seen.find(rs.path) != nil)
			continue;
		dir.length = rs.off;
		f := storedir+"/"+rs.path;
		if(sys->wstat(f, dir) != 0 && err == nil)
			err = sprint("rollback %q to %bd", rs.path, rs.off);
	}
	f := r.storedir()+"/undo";
	if(sys->remove(f) != 0 && err == nil)
		err = sprint("remove %q: %r", f);
	if(err != nil)
		error(err);
}

Repo.xcommit(r: self ref Repo, nil: ref Transact)
{
	f := r.storedir()+"/undo";
	if(sys->wstat(f, sys->nulldir) != 0)
		error(sprint("sync: %r"));
}

Transact.has(tr: self ref Transact, path: string): int
{
	return tr.tab.find(path) != nil;
}

Transact.add(tr: self ref Transact, path: string, off: big)
{
	line := array of byte (path+"\0"+string off+"\n");
	if(sys->write(tr.fd, line, len line) != len line)
		error(sprint("writing undo: %r"));
	rs := ref Revlogstate (path, off);
	if(tr.tab.find(rs.path) == nil)
		tr.tab.add(rs.path, rs);  # only one entry is enough
	tr.l = rs::tr.l;
}

Config.find(c: self ref Config, sec, name: string): (int, string)
{
	for(l := c.l; l != nil; l = tl l) {
		s := hd l;
		if(s.name != sec)
			continue;
		for(ll := s.l; ll != nil; ll = tl ll) {
			(k, v) := *hd ll;
			if(k == name)
				return (1, v);
		}
	}
	return (0, nil);
}

Configs.has(c: self ref Configs, sec, name: string): int
{
	return c.find(sec, name).t0;
}

Configs.get(c: self ref Configs, sec, name: string): string
{
	return c.find(sec, name).t1;
}

Configs.find(c: self ref Configs, sec, name: string): (int, string)
{
	for(l := c.l; l != nil; l = tl l) {
		(h, v) := (hd l).find(sec, name);
		if(h)
			return (h, v);
	}
	return (0, nil);
}

xreadfile(p: string): array of byte
{
	buf := readfile(p, -1);
	if(buf == nil)
		error(sprint("%r"));
	return buf;
}

p48(buf: array of byte, o: int, v: big): int
{
	o = p32(buf, o, v>>16);
	return p16(buf, o, int v);
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
