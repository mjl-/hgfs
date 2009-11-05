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
	g16, g32i, eq, hasstr, p32, p32i, p16, stripws, prefix, suffix, rev, max, l2a, readfile, writefile: import util;
include "bdiff.m";
	bdiff: Bdiff;
	Delta: import bdiff;
include "mercurial.m";


Cachemax:	con 64;  # max number of cached items in a revlog

init(rdonly: int)
{
	sys = load Sys Sys->PATH;
	bufio = load Bufio Bufio->PATH;
	bufio->open("/dev/null", Bufio->OREAD); # ensure bufio is properly initialized
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
	bdiff = load Bdiff Bdiff->PATH;
	bdiff->init();

	readonly = rdonly;
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
		e := rl.xfindn(mf.nodeid, 1);
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
	(ok, dir) := sys->stat(base+"/"+str->splitstrr(path, "/").t0);
	if(ok == 0 && (dir.mode & Sys->DMDIR))
		return;
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


xentrylogtext(r: ref Repo, n: string, verbose: int): string
{
	cl := r.xchangelog();
	ents := cl.xentries();
	rev := p1 := p2 := -1;
	if(n != nullnode) {
		e := cl.xfindn(n, 1);
		rev = e.rev;
		p1 = e.p1;
		p2 = e.p2;
	}
	ch := r.xchangen(n);
	s := "";
	s += entrylogkey("changeset", sprint("%d:%s", rev, n[:12]));
	(k, branch) := ch.findextra("branch");
	if(k != nil)
		s += entrylogkey("branch", branch);
	for(tags := r.xrevtags(n); tags != nil; tags = tl tags)
		s += entrylogkey("tag", (hd tags).name);
	if((p1 >= 0 && p1 != rev-1) || (p2 >= 0 && p2 != rev-1)) {
		if(p1 >= 0)
			s += entrylogkey("parent", sprint("%d:%s", ents[p1].rev, ents[p1].nodeid[:12]));
		if(p2 >= 0)
			s += entrylogkey("parent", sprint("%d:%s", ents[p2].rev, ents[p2].nodeid[:12]));
	} else if(p1 < 0 && rev != p1+1 && rev >= 0)
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
say("xdirstate");
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
		(dsf.mode, o) = g32i(buf, o);
		(dsf.size, o) = g32i(buf, o);
		(dsf.mtime, o) = g32i(buf, o);
		length: int;
		(length, o) = g32i(buf, o);
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
			# say(sprint("xdirstate, checking path %q, state %d, size %d (length %bd), mtime %d (%d)", dsf.path, dsf.state, dsf.size, dir.length, dsf.mtime, dir.mtime));
			case dsf.state {
			STremove or
			STadd or
			STneedmerge =>
				;
			STnormal =>
				if(dsf.size >= 0 && big dsf.size != dir.length) {
					dsf.mtime = dir.mtime;
					dsf.size = SZdirty;
				} else if(dsf.size == SZcheck ||  dsf.mtime >= now-4) {
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
say("xdirstate done");
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

Change.hasfile(c: self ref Change, f: string): int
{
	dir := f+"/";
	for(l := c.files; l != nil; l = tl l)
		if(hd l == f || prefix(dir, hd l))
			return 1;
	return 0;
}

Change.findfiles(c: self ref Change, f: string): list of string
{
	dir := f+"/";
	r: list of string;
	for(l := c.files; l != nil; l = tl l)
		if(hd l == f || prefix(dir, hd l))
			r = hd l::r;
	return rev(r);
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

say(sprint("xreopen, path %q, is dirty, going to read", rl.path));

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
	rl.ivers = dir.qid.vers;
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
	rl.ncache = 0;
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

xreconstruct(rl: ref Revlog, e: ref Entry, base: array of byte, deltas: array of array of byte): array of byte
{
	# first is base, later are patches
	(d, err) := Delta.applymany(base, deltas);
	if(err != nil)
		error("applying patch: "+err);

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
		if(isindexonly(rl))
			fd = rl.ifd;
		rl.bd = bufio->fopen(fd, Bufio->OREAD);
	}

	if(rl.bd.seek(e.ioffset, Bufio->SEEKSTART) != e.ioffset)
		error(sprint("seek %q %bd: %r", rl.path, e.ioffset));
	if(breadn(rl.bd, buf := array[e.csize] of byte, len buf) != len buf)
		error(sprint("read %q: %r", rl.path));
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
	say(sprint("getbufs, rev %d, base %d, fullrev %d", e.rev, e.base, rl.fullrev));
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

# return the revision data
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

Revlog.xgetn(rl: self ref Revlog, n: string): array of byte
{
	e := rl.xfindn(n, 1);
	return rl.xget(e.rev);
}


# create delta from prev to rev.  prev may be -1.
# the typical and easy case is that prev is rev's predecessor and rev is not a base,
# and we can use the delta from the revlog.
# otherwise we'll have to create a patch.  for prev -1 this simply means making
# a patch with the entire file contents.
# for prev >= 0, we generate a delta.
Revlog.xdelta(rl: self ref Revlog, prev, rev: int): array of byte
{
	#say(sprint("delta, prev %d, rev %d", prev, rev));
	e := rl.xfind(rev);

	if(prev >= 0 && prev == e.rev-1 && e.base != e.rev)
		return xgetdata(rl, e);

	buf := xget(rl, e, 1);
	obuf := array[0] of byte;
	if(prev >= 0) {
		pe := rl.xfind(prev);
		obuf = xget(rl, pe, 1);
	}
	delta := bdiff->diff(obuf, buf);
	return delta.pack();
}

deltasize(ents: array of ref Entry): int
{
	n := 0;
	for(i := 0; i < len ents; i++)
		n += ents[i].csize;
	return n;
}

Revlog.xstorebuf(rl: self ref Revlog, buf: array of byte, nrev: int, pbuf, delta: array of byte, d: ref Delta): (int, array of byte)
{
	prev := nrev-1;
	if(prev >= 0) {
		pe := rl.xfind(prev);
		if(pbuf == nil)
			pbuf = xget(rl, pe, 1);

		# see if the patch we got (if any) is useful.  if not, create our own
		if(delta == nil || d == nil || d.replaces(len pbuf)) {
			d = bdiff->diff(pbuf, buf);
			delta = nil;
		}

		if(!d.replaces(len pbuf)) {
			if(delta == nil)
				delta = d.pack();
			compr := compress(delta);
			if(len compr < len delta*90/100)
				delta = compr;
			if(deltasize(rl.ents[pe.base+1:nrev])+len delta < 2*len buf)
				return (pe.base, delta);
		}
	}

	compr := compress(buf);
	if(len compr < len buf*90/100)
		return (nrev, compr);

	nbuf := array[1+len buf] of byte;
	nbuf[0] = byte 'u';
	nbuf[1:] = buf;
	return (nrev, nbuf);
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


Revlog.xfindn(rl: self ref Revlog, n: string, need: int): ref Entry
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

xstreamin(r: ref Repo, b: ref Iobuf)
{
	tr := r.xtransact();
	{
		xstreamin0(r, tr, b);
		r.xcommit(tr);
	} exception {
	"hg:*" =>
		sys->fprint(sys->fildes(2), "error, rolling back...\n");
		r.xrollback(tr);
		raise;
	}
}

xstreamin0(r: ref Repo, tr: ref Transact, b: ref Iobuf)
{
	sys->fprint(sys->fildes(2), "adding changesets\n");
	cl := r.xchangelog();
	nheads := len r.xheads();
	nchangesets := cl.xstream(r, tr, b, 1, cl);
	nnheads := len r.xheads()-nheads;

	sys->fprint(sys->fildes(2), "adding manifests\n");
	ml := r.xmanifestlog();
	ml.xstream(r, tr, b, 0, cl);
	
	sys->fprint(sys->fildes(2), "adding file changes\n");
	nfiles := 0;
	nchanges := 0;
	for(;;) {
		i := bg32(b);
		if(i == 0)
			break;

		namebuf := breadn0(b, i-4);
		name := string namebuf;
		rl := r.xopenrevlog(name);
		nchanges += rl.xstream(r, tr, b, 0, cl);
		nfiles++;
	}

	msg := sprint("added %d changesets with %d changes to %d files", nchangesets, nchanges, nfiles);
	if(nnheads != 0) {
		if(nnheads > 0)
			s := "+"+string nnheads;
		else
			s = string nnheads;
		msg += sprint(", %s heads", s);
	}
	sys->fprint(sys->fildes(2), "%s\n", msg);
}

Revlog.xappend(rl: self ref Revlog, r: ref Repo, tr: ref Transact, nodeid, p1, p2: string, link: int, buf, pbuf, delta: array of byte, d: ref Delta): ref Entry
{
	if(readonly)
		error("repository opened readonly");

	xreopen(rl);

	p1rev := p2rev := -1;
	if(p1 != nullnode)
		p1rev = rl.xfindn(p1, 1).rev;
	if(p2 != nullnode)
		p2rev = rl.xfindn(p2, 1).rev;

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
		if(isindexonly(rl)) {
			isize = ee.ioffset+big ee.csize;
		} else {
			isize = big (len rl.ents*Entrysize);
			dsize = ee.offset+big ee.csize;
		}
	}
	if(link < 0)
		link = nrev;

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

	(base, storebuf) := rl.xstorebuf(buf, nrev, pbuf, delta, d);

	# if we grow a .i-only revlog to beyond 128k, create a .d and rewrite the .i
	convert := isindexonly(rl) && isize+big Entrysize+big len storebuf >= big (128*1024);
	if(convert && nrev == 0) {
		rl.flags &= ~Indexonly;
		tr.add(rl.rlpath+".d", big 0);
	} else if(convert) {
		say(sprint("no longer indexonly, writing %q", dpath));

		ifd := xopen(ipath, Sys->OREAD);
		n := sys->readn(ifd, ibuf := array[int isize] of byte, len ibuf);
		if(n < 0)
			error(sprint("read %q: %r", ipath));
		if(n != len ibuf)
			error(sprint("short read on %q, expected %d, got %d", ipath, n, len ibuf));

		nipath := ipath+".new";
		nifd := xcreate(nipath, Sys->OWRITE|Sys->OEXCL, 8r666);
		ib := bufio->fopen(nifd, Sys->OWRITE);

		dfd := xcreate(dpath, Sys->OWRITE|Sys->OEXCL, 8r666);
		db := bufio->fopen(dfd, Sys->OWRITE);
		isize = big 0;
		dsize = big 0;
		for(i := 0; i < len rl.ents; i++) {
			e := rl.ents[i];

			if(i == 0)
				p16(ibuf, 0, 0); # clear the Indexonly bits

			ioff := int e.ioffset;
			if(ib.write(ibuf[ioff-Entrysize:ioff], Entrysize) != Entrysize)
				error(sprint("write %q: %r", nipath));

			if(db.write(ibuf[ioff:ioff+e.csize], e.csize) != e.csize)
				error(sprint("write %q: %r", dpath));

			isize += big Entrysize;
			dsize += big e.csize;
			e.ioffset = e.offset;
		}
		if(ib.flush() == Bufio->ERROR)
			error(sprint("flush %q: %r", ipath));
		if(db.flush() == Bufio->ERROR)
			error(sprint("flush %q: %r", dpath));

		# xxx styx cannot do this atomically...
		say(sprint("removing current, renaming new, %q and %q", ipath, nipath));
		ndir := sys->nulldir;
		ndir.name = str->splitstrr(ipath, "/").t1;
		if(sys->remove(ipath) != 0 || sys->fwstat(nifd, ndir) != 0)
			error(sprint("remove %q and rename of %q failed: %r", ipath, nipath));

		rl.flags &= ~Indexonly;
		rl.ifd = xopen(ipath, Sys->OREAD);
		rl.dfd = xopen(dpath, Sys->OREAD);
		rl.bd = bufio->fopen(rl.dfd, Bufio->OREAD);

		tr.add(rl.rlpath+".d", dsize);
		tr.add(rl.rlpath+".i", isize);
	}

	ioffset: big;
	if(isindexonly(rl))
		ioffset = isize+big Entrysize;
	else
		ioffset = dsize;

	flags := 0;
	e := ref Entry (nrev, offset, ioffset, flags, len storebuf, len buf, base, link, p1rev, p2rev, nodeid);
say(sprint("revlog %q, will be adding %s", rl.path, e.text()));
	ebuf := array[Entrysize] of byte;
	e.xpack(ebuf, isindexonly(rl));
	nents := array[len rl.ents+1] of ref Entry;
	nents[:] = rl.ents;
	nents[len rl.ents] = e;
	rl.ents = nents;

	ncache := array[len rl.cache+1] of array of byte;
	ncache[:] = rl.cache;
	rl.cache = ncache;

	rl.full = buf;
	rl.fullrev = e.rev;

	rl.tab.add(e.nodeid, e);

	r.xensuredirs(ipath);
	ifd := xopencreate(ipath, Sys->OWRITE, 8r666);
	if(sys->pwrite(ifd, ebuf, len ebuf, isize) != len ebuf)
		error(sprint("write %q: %r", ipath));
	isize += big Entrysize;
	if(isindexonly(rl)) {
		if(sys->pwrite(ifd, storebuf, len storebuf, isize) != len storebuf)
			error(sprint("write %q: %r", ipath));
	} else {
		if(!tr.has(dpath))
			tr.add(rl.rlpath+".d", dsize);
		dfd := xopencreate(dpath, Sys->OWRITE, 8r666);
		if(sys->pwrite(dfd, storebuf, len storebuf, dsize) != len storebuf)
			error(sprint("write %q: %r", dpath));
	}

	if(rl.ifd == nil)
		rl.ifd = xopen(ipath, Sys->OREAD);
	if(!isindexonly(rl) && rl.dfd == nil) {
		rl.dfd = xopen(dpath, Sys->OREAD);
		rl.bd = bufio->fopen(rl.dfd, Bufio->OREAD);
	}

	(ok, dir) := sys->fstat(rl.ifd);
	if(ok == 0) {
		rl.ilength = dir.length;
		rl.imtime = dir.mtime;
		rl.ivers = dir.qid.vers;
	}

	return e;
}

Revlog.xstream(rl: self ref Revlog, r: ref Repo, tr: ref Transact, b: ref Bufio->Iobuf, ischlog: int, cl: ref Revlog): int
{
	buf: array of byte;
	nchanges := 0;
	for(;;) {
		i := bg32(b);
		if(i == 0)
			break;

		(rev, p1, p2, link, delta) := breadchunk(b, i);
		say(sprint("\trev=%s", rev));
		say(sprint("\tp1=%s", p1));
		say(sprint("\tp2=%s", p2));
		say(sprint("\tlink=%s", link));
		say(sprint("\tlen delta=%d", len delta));

		if(ischlog && rev != link)
			error(sprint("changelog entry %s with bogus link %s", rev, link));
		if(!ischlog && cl.xfindn(link, 0) == nil)
			error(sprint("nodeid %s references unknown changelog link %s", rev, link));

		(d, err) := Delta.parse(delta);
		if(err != nil)
			error("parsing patch: "+err);
		say(sprint("\tdelta, sizediff %d", d.sizediff()));
		say(sprint("\t%s", d.text()));
		
		linkrev := -1;
		if(!ischlog)
			linkrev = cl.xfindn(link, 1).rev;

		pbuf := buf;
		if(buf == nil) {
			if(p1 != nullnode) {
				buf = rl.xgetn(p1);
			} else {
				if(!d.replaces(0))
					error(sprint("first chunk is not full version"));
				buf = array[0] of byte;
			}
		}

		buf = d.apply(buf);

		nodeid := xcreatenodeid(buf, p1, p2);
		if(nodeid != rev)
			error(sprint("nodeid mismatch, expected %s saw %s", rev, nodeid));

		if(rl.xfindn(nodeid, 0) != nil)
			continue;

		rl.xappend(r, tr, nodeid, p1, p2, linkrev, buf, pbuf, delta, d);
		nchanges++;
	}
	return nchanges;
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
say("repo.xrevision");
	n := r.xchangelog().xfind(rev).nodeid;
	return r.xrevisionn(n);
}

Repo.xrevisionn(r: self ref Repo, n: string): (ref Change, ref Manifest)
{
	c := r.xchangen(n);
	m := ref Manifest (nullnode, array[0] of ref Mfile);
	if(c.manifestnodeid != nullnode) {
		ml := r.xmanifestlog();
		mbuf := ml.xgetn(c.manifestnodeid);
		m = Manifest.xparse(mbuf, c.manifestnodeid);
	}
	return (c, m);
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

Repo.xchangen(r: self ref Repo, n: string): ref Change
{
	if(n == nullnode)
		return ref Change (-1, n, -1, -1, nullnode, "", 0, 0, nil, nil, nil);
	cl := r.xchangelog();
	ce := cl.xfindn(n, 1);
	cd := cl.xget(ce.rev);
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
	if(readonly)
		error("repository opened readonly");

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
	l := r.xheads();
	if(l == nil)
		return nil;
	rlt := r.xopenrevlog(".hgtags");
	for(; l != nil; l = tl l) {
		n := hd l;
		(nil, m) := r.xrevisionn(n);
		mf := m.find(".hgtags");
		if(mf == nil)
			continue;
		buf := rlt.xgetn(mf.nodeid);
		for(ll := xparsetags(r, string buf); ll != nil; ll = tl ll) {
			t := hd ll;
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
	if(rev != -1)
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
	if(len ents == 0 || len ents > 0 && ents[len ents-1].rev == rev)
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
		e := cl.xfindn(n, 1);
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
say("repo.xbranches");
	path := r.path+"/branch.cache";
	br := bufio->open(path, Bufio->OREAD);
	# br nil is okay, we're sure not to read from it if so below

	cl := r.xchangelog();

	# first line has nodeid+revision of tip.  used for seeing if the cache is up to date.
	branches: list of ref Branch;
	branchtab := Strhash[ref Branch].new(13, nil);
	i := 0;
	lastcacherev := 0;
	for(;; i++) {
		if(br == nil)
			break;

		s := br.gets('\n');
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
		e := cl.xfindn(n, 1);
		if(branchtab.find(name) != nil)
			error(sprint("duplicate branch name %#q", name));
		b := ref Branch (name, n, e.rev);
		branches = b::branches;
		branchtab.add(b.name, b);
	}

	# read the changelog for entries not in the cache
	lrev := r.xlastrev();
	new := lastcacherev < lrev;
	for(lastcacherev++; lastcacherev <= lrev; lastcacherev++) {
		c := r.xchange(lastcacherev);
		(nil, name) := c.findextra("branch");
		if(name == nil)
			name = "default";
		b := branchtab.find(name);
		if(b == nil) {
			b = ref Branch (name, c.nodeid, c.rev);
			branchtab.add(name, b);
			branches = b::branches;
		} else {
			b.n = c.nodeid;
			b.rev = c.rev;
		}
	}

	# if no branches, fake one
	if(branches == nil && len cl.ents > 0) {
		rev := cl.xlastrev();
		e := cl.xfind(rev);
		branches = ref Branch ("default", e.nodeid, e.rev)::nil;
	}

	if(!readonly && new && len cl.ents > 0) {
		fd := sys->create(path, Sys->OWRITE|Sys->OTRUNC, 8r666);
		if(fd == nil) {
			warn(sprint("create %q: %r", path));
		} else {
			ee := cl.ents[len cl.ents-1];
			s := sprint("%s %d\n", ee.nodeid, ee.rev);
			for(l := branches; l != nil; l = tl l) {
				b := hd l;
				s += sprint("%s %s\n", b.n, b.name);
			}
			buf := array of byte s;
			if(sys->write(fd, buf, len buf) != len buf)
				warn(sprint("writing new %q: %r", path));
		}
	}

	return branches;
}

Repo.xheads(r: self ref Repo): list of string
{
	cl := r.xchangelog();
	a := cl.xentries();

	if(len a == 0)
		return nullnode::nil;

	for(i := 0; i < len a; i++) {
		e := a[i];
		if(e.p1 >= 0)
			a[e.p1] = nil;
		if(e.p2 >= 0)
			a[e.p2] = nil;
	}

	l: list of string;
	for(i = 0; i < len a; i++)
		if(a[i] != nil)
			l = a[i].nodeid::l;
	return l;
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
			return (-1, "null");
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
			e := cl.xfindn(s, 0);
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
	(nil, m) := r.xrevisionn(revstr);
	mf := m.find(path);
	if(mf == nil)
		error(sprint("file %#q not in revision %q", path, revstr));
	rl := r.xopenrevlog(path);
	return rl.xgetn(mf.nodeid);
}

Repo.xread(r: self ref Repo, path: string, ds: ref Dirstate): array of byte
{
	if(ds.context == nil)
		ds.context = ref Context;

	if(ds.context.m1 == nil)
		(nil, ds.context.m1) = r.xrevisionn(ds.p1);
	mf1 := ds.context.m1.find(path);
	if(mf1 != nil)
		return r.xopenrevlog(path).xgetn(mf1.nodeid);

	if(ds.context.m2 == nil)
		(nil, ds.context.m2) = r.xrevisionn(ds.p2);
	mf2 := ds.context.m2.find(path);
	if(mf2 != nil)
		return r.xopenrevlog(path).xgetn(mf2.nodeid);

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
	(e.csize, o) = g32i(buf, o);
	(e.uncsize, o) = g32i(buf, o);
	(e.base, o) = g32i(buf, o);
	(e.link, o) = g32i(buf, o);
	(e.p1, o) = g32i(buf, o);
	(e.p2, o) = g32i(buf, o);
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
	if(readonly)
		error("repository opened readonly");

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
		if(rs.off == big 0) {
			if(sys->remove(f) != 0 && err == nil)
				err = sprint("rollback %q to %bd (remove)", f, rs.off);
		} else {
			if(sys->wstat(f, dir) != 0 && err == nil)
				err = sprint("rollback %q to %bd", rs.path, rs.off);
		} 
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


breadn0(b: ref Iobuf, n: int): array of byte
{
	nn := breadn(b, d := array[n] of byte, n);
	if(nn < 0)
		error(sprint("reading: %r"));
	if(nn != n)
		error("short read");
	return d;
}

bg32(b: ref Iobuf): int
{
	return g32i(breadn0(b, 4), 0).t0;
}

breadchunk(b: ref Iobuf, n: int): (string, string, string, string, array of byte)
{
	n -= 4;
	if(n < 4*20)
		error("short chunk");
	buf := breadn0(b, n);
	o := 0;
	rev := buf[o:o+20];
	o += 20;
	p1 := buf[o:o+20];
	o += 20;
	p2 := buf[o:o+20];
	o += 20;
	link := buf[o:o+20];
	o += 20;
	delta := buf[o:];
	return (hex(rev), hex(p1), hex(p2), hex(link), delta);
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
