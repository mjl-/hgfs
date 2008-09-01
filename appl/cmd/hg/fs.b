implement HgFs;

# todo
# - improve bookkeeping for revtree:  don't store full path, and keep track of gen of higher directory, for quick walk to ..

include "sys.m";
	sys: Sys;
	sprint: import sys;
include "draw.m";
include "arg.m";
include "bufio.m";
	bufio: Bufio;
	Iobuf: import bufio;
include "string.m";
	str: String;
include "daytime.m";
	daytime: Daytime;
include "styx.m";
	styx: Styx;
	Tmsg, Rmsg: import Styx;
include "styxservers.m";
	styxservers: Styxservers;
	Styxserver, Fid, Navigator, Navop: import styxservers;
include "filter.m";
	deflate: Filter;
	Rq: import Filter;
include "tables.m";
	tables: Tables;
	Table, Strhash: import tables;
include "lists.m";
	lists: Lists;
include "mercurial.m";
	mercurial: Mercurial;
	Revlog, Repo, Nodeid, Change, Manifest, Manifestfile: import mercurial;


Dflag, dflag: int;
vflag: int;

Qroot, Qlastrev, Qfiles, Qlog, Qtgz, Qstate, Qrepofile, Qlogrev, Qtgzrev: con iota;
tab := array[] of {
	(Qroot,		"<reponame>",	Sys->DMDIR|8r555),
	(Qlastrev,	"lastrev",	8r444),
	(Qfiles,	"files",	Sys->DMDIR|8r555),
	(Qlog,		"log",		Sys->DMDIR|8r555),
	(Qtgz,		"tgz",		Sys->DMDIR|8r555),
	(Qstate,	"state",	8r444),
	(Qrepofile,	"<repofile>",	8r555),
	(Qlogrev,	"<logrev>",	8r444),
	(Qtgzrev,	"<tgzrev>",	8r444),
};

# Qrepofiles are the individual files in a particular revision.
# qids for files in a revision are composed of:
# 8 bits qtype
# 24 bits manifest file generation number (<<8)
# 24 bits revision (<<32)
# when opening a revision, the file list in the revlog manifest is parsed,
# and a full file tree (only path names) is created.  gens are assigned
# incrementally, the root dir has gen 0.  Qtgz and Qlog always have gen 0.
# this ensures qids are permanent for a repository.

srv: ref Styxserver;
repo: ref Repo;
reponame: string;
starttime: int;
tgztab: ref Table[ref Tgz];
revtreetab: ref Table[ref Revtree];
revtreesize := 0;
revtreemax := 64;
filetab: ref Strhash[ref Node];
filecachesize := 0;
filecachemax := 512*1024;

HgFs: module {
	init:	fn(nil: ref Draw->Context, args: list of string);
};

init(nil: ref Draw->Context, args: list of string)
{
	sys = load Sys Sys->PATH;
	arg := load Arg Arg->PATH;
	bufio = load Bufio Bufio->PATH;
	str = load String String->PATH;
	styx = load Styx Styx->PATH;
	styx->init();
	styxservers = load Styxservers Styxservers->PATH;
	styxservers->init(styx);
	daytime = load Daytime Daytime->PATH;
	deflate = load Filter Filter->DEFLATEPATH;
	deflate->init();
	tables = load Tables Tables->PATH;
	lists = load Lists Lists->PATH;
	mercurial = load Mercurial Mercurial->PATH;
	mercurial->init();

	hgpath := "";

	sys->pctl(Sys->NEWPGRP, nil);

	arg->init(args);
	arg->setusage(arg->progname()+" [-Ddv] [-c revcache] [-C filecache] [-h path]");
	while((c := arg->opt()) != 0)
		case c {
		'D' =>	Dflag++;
			styxservers->traceset(Dflag);
		'c' =>	revtreemax = int arg->earg();
		'C' =>	filecachemax = int arg->earg();
		'd' =>	dflag++;
			if(dflag > 1)
				mercurial->debug++;
		'v' =>	vflag++;
		'h' =>	hgpath = arg->earg();
		* =>	arg->usage();
		}
	args = arg->argv();
	if(len args != 0)
		arg->usage();

	starttime = daytime->now();

	err: string;
	(repo, err) = Repo.find(hgpath);
	if(err != nil)
		fail(err);
	say("found repo");

	reponame = repo.name();
	tab[Qroot].t1 = reponame;
	tgztab = tgztab.new(32, nil);
	revtreetab = revtreetab.new(1+revtreemax/16, nil);
	filetab = filetab.new(1+filecachemax/16, nil);

	navch := chan of ref Navop;
	spawn navigator(navch);

	nav := Navigator.new(navch);
	msgc: chan of ref Tmsg;
	(msgc, srv) = Styxserver.new(sys->fildes(0), nav, big Qroot);

done:
	for(;;) alt {
	gm := <-msgc =>
		if(gm == nil)
			break;
		pick m := gm {
		Readerror =>
			warn("read error: "+m.error);
			break done;
		}
		dostyx(gm);
	}
}

dostyx(gm: ref Tmsg)
{
	pick m := gm {
	Open =>
		(fid, mode, nil, err) := srv.canopen(m);
		if(fid == nil)
			return replyerror(m, err);
		q := int fid.path&16rff;
		id := int fid.path>>8;

		srv.default(m);

	Read =>
		f := srv.getfid(m.fid);
		if(f.qtype & Sys->QTDIR) {
			# pass to navigator, to readdir
			srv.default(m);
			return;
		}
		say(sprint("read f.path=%bd", f.path));
		q := int f.path&16rff;

		case q {
		Qlastrev =>
			(rev, err) := repo.lastrev();
			if(err != nil)
				return replyerror(m, err);
			srv.reply(styxservers->readstr(m, sprint("%d", rev)));

		Qlogrev =>
			(rev, nil) := revgen(f.path);
			(change, err) := repo.change(rev);
			if(err != nil)
				return replyerror(m, err);
			srv.reply(styxservers->readstr(m, change.text()));

		Qtgzrev =>
			(rev, nil) := revgen(f.path);

			tgz := tgztab.find(f.fid);
			if(tgz == nil) {
				if(m.offset != big 0)
					return replyerror(m, "random reads on .tgz's not supported");

				err: string;
				(tgz, err) = Tgz.new(rev);
				if(err != nil)
					return replyerror(m, err);
				tgztab.add(f.fid, tgz);
			}
			(buf, err) := tgz.read(m.count, m.offset);
			if(err != nil)
				return replyerror(m, err);
			srv.reply(ref Rmsg.Read(m.tag, buf));

		Qrepofile  =>
			(rev, gen) := revgen(f.path);
			(r, err) := treeget(rev);

			d: array of byte;
			(d, err) = fileget(r, gen);
			if(err != nil)
				return replyerror(m, err);
			srv.reply(styxservers->readbytes(m, d));

		Qstate =>
			s := sprint("reponame %q\nrevtree size %d max %d\nfiles size %d max %d\n", reponame, revtreesize, revtreemax, filecachesize, filecachemax);

			tgzstr := "";
			ntgz := 0;
			for(i := 0; i < len tgztab.items; i++) {
				for(l := tgztab.items[i]; l != nil; l = tl l) {
					e := (hd l).t1;
					tgzstr += sprint("tgz rev %d tgzoff %bd eof %d len data %d len tgzdata %d\n", e.rev, e.tgzoff, e.eof, len e.data, len e.tgzdata);
					ntgz++;
				}
			}
			s += sprint("tgztab: %d files\n", ntgz)+tgzstr;

			rtstr := "";
			nrt := 0;
			for(i = 0; i < len revtreetab.items; i++) {
				for(l := revtreetab.items[i]; l != nil; l = tl l) {
					rt := (hd l).t1;
					rtstr += sprint("revtree rev %d nfiles %d mtime %d used %d\n", rt.rev, len rt.tree, rt.mtime, rt.used);
					nrt++;
				}
			}
			s += sprint("revtreetab: %d revtrees\n", nrt)+rtstr;

			nodestr := "";
			nnodes := 0;
			for(i = 0; i < len filetab.items; i++) {
				for(l := filetab.items[i]; l != nil; l = tl l) {
					n := (hd l).t1;
					nodestr += sprint("file nodeid %s len data %d used %d\n", n.nodeid.text(), len n.data, n.used);
					nnodes++;
				}
			}
			s += sprint("filetab: %d files\n", nnodes)+nodestr;

			srv.reply(styxservers->readstr(m, s));

		* =>
			replyerror(m, styxservers->Eperm);
		}

	Clunk or Remove =>
		f := srv.getfid(m.fid);
		q := int f.path&16rff;

		case q {
		Qtgzrev =>
			tgztab.del(f.fid);
		}
		srv.default(gm);

	* =>
		srv.default(gm);
	}
}

navigator(c: chan of ref Navop)
{
again:
	for(;;) {
		navop := <-c;
		q := int navop.path&16rff;
		(rev, gen) := revgen(navop.path);
		say(sprint("have navop, tag %d, q %d, rev %d, gen %d", tagof navop, q, rev, gen));

		pick op := navop {
		Stat =>
			say("stat");
			case q {
			Qrepofile =>
				(r, err) := treeget(rev);
				say(sprint("navigator, stat, op.path %bd, rev %d, gen %d", op.path, rev, gen));
				d: ref Sys->Dir;
				if(err == nil)
					(d, err) = r.stat(gen);
				op.reply <-= (d, err);
			* =>
				op.reply <-= (dir(op.path, starttime), nil);
			}

		Walk =>
			say(sprint("walk, name %q", op.name));

			# handle repository files first, other are handled below
			case q {
			Qrepofile =>
				(r, err) := treeget(rev);
				d: ref Sys->Dir;
				if(err == nil)
					(d, err) = r.walk(gen, op.name);
				op.reply <-= (d, err);
				continue again;
			}

			if(op.name == "..") {
				nq: int;
				case q {
				Qlogrev =>	nq = Qlog;
				Qtgzrev =>	nq = Qtgz;
				* =>		nq = Qroot;
				}
				op.reply <-= (dir(big nq, starttime), nil);
				continue again;
			}

			case q {
			Qroot =>
				for(i := Qlastrev; i <= Qstate; i++)
					if(tab[i].t1 == op.name) {
						op.reply <-= (dir(big tab[i].t0, starttime), nil);
						continue again;
					}
				op.reply <-= (nil, styxservers->Enotfound);

			Qfiles =>
				rev: int;
				err: string;
				if(op.name == "last")
					(rev, err) = repo.lastrev();
				else
					(rev, err) = parserev(op.name);
				if(err != nil) {
					op.reply <-= (nil, err);
					continue again;
				}
				(change, manifest, merr) := repo.manifest(rev);
				if(merr != nil) {
					op.reply <-= (nil, merr);
					continue again;
				}

				say("walk to files/<rev>/");
				(r, rerr) := treeget(rev);
				if(rerr != nil)
					op.reply <-= (nil, rerr);
				else
					op.reply <-= r.stat(0);

			Qlog =>
				err: string;
				if(op.name == "last")
					(rev, err) = repo.lastrev();
				else
					(rev, err) = parserev(op.name);

				if(err != nil) {
					op.reply <-= (nil, err);
					continue again;
				}

				op.reply <-= (dir(child(q)|big rev<<32, revmtime(rev)), nil);

			Qtgz =>
				name := reponame+"-";
				if(!str->prefix(name, op.name) || !suffix(".tgz", op.name)) {
					op.reply <-= (nil, styxservers->Enotfound);
					continue again;
				}
				revstr := op.name[len name:len op.name-len ".tgz"];
				err: string;
				(rev, err) = parserev(revstr);
				if(err != nil) {
					op.reply <-= (nil, styxservers->Enotfound);
					continue again;
				}
				op.reply <-= (dir(child(q)|big rev<<32, revmtime(rev)), err);

			* =>
				raise sprint("unhandled case in walk %q, from %d", op.name, q);
			}

		Readdir =>
			say("readdir");
			case q {
			Qroot =>
				n := Qtgz+1-Qlastrev;
				have := 0;
				for(i := 0; have < op.count && op.offset+i < n; i++) {
					op.reply <-= (dir(big (Qlastrev+i), starttime), nil);
					have++;
				}
			Qfiles or Qlog or Qtgz =>
				if(op.offset == 0 && op.count > 0) {
					(npath, mtime, err) := last(q);
					if(err != nil) {
						op.reply <-= (nil, err);
						continue again;
					}
					d := dir(npath, mtime);
					if(q == Qfiles || q == Qlog)
						d.name = "last";
					op.reply <-= (d, nil);
				}

			Qrepofile =>
				(r, err) := treeget(rev);
				if(err != nil) {
					op.reply <-= (nil, err);
					continue again;
				} else
					r.readdir(gen, op);

			* =>
				raise sprint("unhandled case for readdir %d", q);
			}

			op.reply <-= (nil, nil);
		}
	}
}

revgen(path: big): (int, int)
{
	rev := int (path>>32) & 16rffffff;
	gen := int (path>>8) & 16rffffff;
	return (rev, gen);
}

revmtime(rev: int): int
{
	(rt, err) := treeget(rev);
	if(err != nil)
		return -1;
	return rt.mtime;
}


last(q: int): (big, int, string)
{
	(rev, err) := repo.lastrev();
	if(err != nil)
		return (big 0, 0, err);

	nq: int;
	case q {
	Qfiles => 	nq = Qrepofile;
	Qlog =>		nq = Qlogrev;
	Qtgz =>		nq = Qtgzrev;
	* =>		raise sprint("bogus call 'last' on q %d", q);
	}
	return (big nq|big rev<<32, revmtime(rev), nil);
}

child(q: int): big
{
	case q {
	Qfiles =>	return big Qrepofile;
	Qlog =>		return big Qlogrev;
	Qtgz =>		return big Qtgzrev;
	* =>	raise sprint("bogus call 'child' on q %d", q);
	}
}

parserev(s: string): (int, string)
{
	if(s == "0")
		return (0, nil);
	if(str->drop(s, "0-9") != "")
		return (0, sprint("malformed revision (non-numeric str %q)", str->drop(s, "0-9")));
	(rev, rem) := str->toint(s, 10);
	if(rem != nil)
		return (0, sprint("malformed revision (trailing str %q)", rem));
	return (rev, nil);
}

dir(path: big, mtime: int): ref Sys->Dir
{
	q := int path&16rff;
	(rev, gen) := revgen(path);
	(nil, name, perm) := tab[q];
	say(sprint("dir, path %bd, name %q, rev %d, gen %d", path, name, rev, gen));

	d := ref sys->zerodir;
	d.name = name;
	if(q == Qlogrev)
		d.name = sprint("%d", rev);
	if(q == Qtgzrev)
		d.name = sprint("%s-%d.tgz", reponame, rev);
	d.uid = d.gid = "hg";
	d.qid.path = path;
	if(perm&Sys->DMDIR)
		d.qid.qtype = Sys->QTDIR;
	else
		d.qid.qtype = Sys->QTFILE;
	d.mtime = d.atime = mtime;
	d.mode = perm;
	say("dir, done");
	return d;
}

replyerror(m: ref Tmsg, s: string)
{
	srv.reply(ref Rmsg.Error(m.tag, s));
}

# lru, should be done more efficiently
treepurge()
{
	a := revtreetab.items;
	lastrev := -1;
	used := -1;
	for(i := 0; i < len a; i++)
		for(l := a[i]; l != nil; l = tl l) {
			(rev, rt) := hd l;
			if(lastrev == -1 || rt.used < used) {
				lastrev = rev;
				used = rt.used;
			}
		}
	if(lastrev != -1)
		revtreetab.del(lastrev);
}

treeusegen := 0;
treeget(rev: int): (ref Revtree, string)
{
	rt := revtreetab.find(rev);
	if(rt == nil) {
		(change, manifest, err) := repo.manifest(rev);
		if(err != nil)
			return (nil, err);
		rt = Revtree.new(change, manifest, rev);
		if(revtreesize >= revtreemax)
			treepurge();
		else
			revtreesize++;
		revtreetab.add(rev, rt);
	}
	rt.used = treeusegen++;
	return (rt, nil);
}

# lru, inefficient..
filepurge()
{
	a := filetab.items;
	last: string;
	node: ref Node;
	used := -1;
	for(i := 0; i < len a; i++)
		for(l := a[i]; l != nil; l = tl l) {
			(s, n) := hd l;
			if(last == nil || n.used < used) {
				last = s;
				used = n.used;
				node = n;
			}
		}
	if(node != nil) {
		filetab.del(last);
		say(sprint("filepurge, removing %d/%d bytes from cache, node %s", len node.data, filecachesize, last));
		filecachesize -= len node.data;
		node.data = nil;
	}
}

fileusegen := 0;
fileget(r: ref Revtree, gen: int): (array of byte, string)
{
	d: array of byte;

	f := r.plainfile(gen);
	s := f.nodeid.text();
	n := filetab.find(s);
	if(n == nil) {
		while(filecachesize >= filecachemax && filecachesize > 0)
			filepurge();
		err: string;
		(d, err) = r.read(gen);
		if(err != nil)
			return (nil, err);
		filecachesize += len d;
		n = ref Node(f.nodeid, d, 0);
		filetab.add(s, n);
	} else
		d = n.data;
	n.used = fileusegen++;
	return (d, nil);
}

Node: adt {
	nodeid:	ref Nodeid;
	data:	array of byte;
	used:	int;
};

# file in a revtree
File: adt {
	gen:	int;
	path:	string;
	pick {
	Plain =>
		nodeid:	ref Nodeid;	# nil for directories
		length:	int;	# -1 => not yet valid
		mtime:	int;	# -1 => not yet valid
	Dir =>
		files:	array of int;	# gens of files
	}

	new:	fn(gen: int, path: string, nodeid: ref Nodeid): ref File;
	mode:	fn(f: self ref File): int;
	text:	fn(f: self ref File): string;
};

File.new(gen: int, path: string, nodeid: ref Nodeid): ref File
{
	if(nodeid == nil)
		return ref File.Dir(gen, path, nil);
	else
		return ref File.Plain(gen, path, nodeid, -1, -1);
}

File.mode(f: self ref File): int
{
	pick ff := f {
	Plain =>	return 8r444;
	Dir =>		return 8r555|Sys->DMDIR;
	}
}

File.text(f: self ref File): string
{
	pick ff := f {
	Plain =>
		return sprint("<file.plain gen %d, path %q, nodeid %s, length %d, mtime %d>", f.gen, f.path, ff.nodeid.text(), ff.length, ff.mtime);
	Dir =>	return sprint("<file.dir gen %d, path %q>", f.gen, f.path);
	}
}


# all paths of a tree of a single revision
Revtree: adt {
	rev:	int;
	tree:	array of ref File;
	mtime:	int;
	used:	int;

	new:	fn(c: ref Change, mf: ref Manifest, rev: int): ref Revtree;
	readdir:	fn(r: self ref Revtree, gen: int, op: ref Navop.Readdir);
	read:	fn(r: self ref Revtree, gen: int): (array of byte, string);
	stat:	fn(r: self ref Revtree, gen: int): (ref Sys->Dir, string);
	walk:	fn(r: self ref Revtree, gen: int, name: string): (ref Sys->Dir, string);
	plainfile:	fn(r: self ref Revtree, gen: int): ref File.Plain;
	dirfile:	fn(r: self ref Revtree, gen: int): ref File.Dir;
};

gendirs(prevdir: string, gen: int, path: string): (string, int, list of ref File)
{
	(path, nil) = str->splitstrr(path, "/");
	if(path == nil)
		return (prevdir, gen, nil);

	if(path[len path-1] != '/')
		raise "wuh?";
	path = path[:len path-1];
	if(str->prefix(path, prevdir))
		return (prevdir, gen, nil);

	dirs: list of ref File;
	s: string;
	for(el := sys->tokenize(path, "/").t1; el != nil; el = tl el) {
		s += "/"+hd el;
		if(str->prefix(s[1:], prevdir))
			continue;  # already present
		dirs = File.new(gen++, s[1:], nil)::dirs;
	}

	return (path, gen, dirs);
}

Revtree.new(c: ref Change, mf: ref Manifest, rev: int): ref Revtree
{
	say("revtree.new");
	prevdir: string;  # previous dir we generated

	gen := 0;
	r := File.new(gen++, "", nil)::nil;
	for(l := mf.files; l != nil; l = tl l) {
		m := hd l;
		(nprevdir, ngen, dirs) := gendirs(prevdir, gen, m.path);
		(prevdir, gen) = (nprevdir, ngen);
		r = lists->concat(dirs, r);
		r = File.new(gen++, m.path, m.nodeid)::r;
	}
	rt := ref Revtree (rev, l2a(lists->reverse(r)), c.when+c.tzoff, 0);
	say(sprint("revtree.new done, have %d paths:", len r));
	for(i := 0; i < len rt.tree; i++)
		say(sprint("\t%s", rt.tree[i].text()));
	say("eol");
	return rt;
}

dirfiles(r: ref Revtree, gen: int): array of int
{
	bf := r.tree[gen];
	a := array[len r.tree-gen] of int; # max possible length
	path := bf.path;
	if(path != nil)
		path = "/"+path;
	have := 0;
	prevelem: string;
	for(i := gen; i < len r.tree; i++) {
		p := "/"+r.tree[i].path;
		say(sprint("checking %q against %q", path, p));
		if(str->prefix(path+"/", p) && !has(p[len path+1:], '/')) {
			elem := p[len path+1:];
			if(elem != nil && elem != prevelem) {
				say(sprint("adding gen %d", i));
				a[have++] = i;
				prevelem = elem;
			}
		}
	}
	a = a[:have];
	say(sprint("dirfiles, have %d elems", len a));
	return a;
}

Revtree.readdir(r: self ref Revtree, gen: int, op: ref Navop.Readdir)
{
	f := r.dirfile(gen);
	say(sprint("revtree.readdir, for %s", f.text()));

	if(f.files == nil)
		f.files = dirfiles(r, gen);

	say(sprint("revtree.readdir, len files %d, op.count %d, op.offset %d", len f.files, op.count, op.offset));
	have := 0;
	for(i := 0; have < op.count && op.offset+i < len f.files; i++) {
		(d, err) := r.stat(f.files[i]);
		op.reply <-= (d, err);
		if(err != nil)
			return say("revtree.readdir, stopped after error: "+err);
		have++;
	}
	say(sprint("revtree.readdir done, have %d, i %d", have, i));
}

Revtree.walk(r: self ref Revtree, gen: int, name: string): (ref Sys->Dir, string)
{
	f := r.tree[gen];
	say(sprint("revtree.walk, name %q, file %s", name, f.text()));
	npath := f.path;
	if(name == "..") {
		if(gen == 0)
			return (dir(big Qfiles, starttime), nil);
		(npath, nil) = str->splitstrr(f.path, "/");
		if(npath != nil) {
			if(!suffix("/", npath))
				raise sprint("npath does not have / at end?, npath %q", npath);
			npath = npath[:len npath-1];
		}
	} else {
		if(npath != nil)
			npath += "/";
		npath += name;
	}

	# xxx could be done more efficiently
	for(i := 0; i < len r.tree; i++)
		if(r.tree[i].path == npath)
			return r.stat(i);
	say(sprint("revtree.walk, no hit for %q in %q", npath, f.path));
	return (nil, styxservers->Enotfound);
}

Revtree.read(r: self ref Revtree, gen: int): (array of byte, string)
{
	f := r.plainfile(gen);
	say(sprint("revtree.read, f %s", f.text()));
	(data, err) := repo.readfile(f.path, f.nodeid);
	if(err == nil && f.length < 0)
		f.length = len data;
	return (data, err);
}

Revtree.stat(r: self ref Revtree, gen: int): (ref Sys->Dir, string)
{
	f := r.tree[gen];
	say(sprint("revtree.stat, rev %d, file %s", r.rev, f.text()));

	q := Qrepofile;
	d := ref sys->zerodir;

	if(gen == 0)
		d.name = sprint("%d", r.rev);
	else
		d.name = str->splitstrr(f.path, "/").t1;

	d.uid = d.gid = "hg";
	d.qid.path = big Qrepofile|big gen<<8|big r.rev<<32;

	pick ff := f {
	Plain =>
		d.qid.qtype = Sys->QTFILE;

		if(ff.length < 0) {
			(length, err) := repo.filelength(f.path, ff.nodeid);
			if(err != nil)
				return (nil, err);
			ff.length = int length;
		}
		d.length = big ff.length;

		if(ff.mtime < 0) {
			(mtime, err) := repo.filemtime(f.path, ff.nodeid);
			if(err != nil)
				return (nil, err);
			ff.mtime = mtime;
		}
		d.mtime = d.atime = ff.mtime;
	Dir =>
		d.qid.qtype = Sys->QTDIR;
		d.length = big 0;
		d.mtime = d.atime = r.mtime;
	}

	d.mode = f.mode();
	say("revtree.stat, done");
	return (d, nil);
}

Revtree.plainfile(r: self ref Revtree, gen: int): ref File.Plain
{
	pick f := r.tree[gen] {
	Plain =>	return f;
	* =>	raise "file not plain file";
	}
}

Revtree.dirfile(r: self ref Revtree, gen: int): ref File.Dir
{
	pick f := r.tree[gen] {
	Dir =>	return f;
	* =>	raise "file not directory";
	}
}


Tgz: adt {
	rev:	int;
	tgzoff:	big;
	pid:	int;  # of filter
	rq:	chan of ref Rq;
	manifest:	ref Manifest;

	data:	array of byte;  # of file-in-progress
	mf:	list of ref Manifestfile;  # remaining files

	tgzdata:	array of byte;  # output from filter
	eof:	int;  # whether we've seen filters finished message

	new:	fn(rev: int): (ref Tgz, string);
	read:	fn(t: self ref Tgz, n: int, off: big): (array of byte, string);
	close:	fn(t: self ref Tgz);
};

Tgz.new(rev: int): (ref Tgz, string)
{
	(nil, manifest, err) := repo.manifest(rev);
	if(err != nil)
		return (nil, err);

	rq := deflate->start("h");
	msg := <-rq;
	pid: int;
	pick m := msg {
	Start =>	pid = m.pid;
	* =>		fail(sprint("bogus first message from deflate"));
	}

	t := ref Tgz(rev, big 0, pid, rq, manifest, array[0] of byte, manifest.files, array[0] of byte, 0);
	return (t, nil);
}

Tgz.read(t: self ref Tgz, n: int, off: big): (array of byte, string)
{
	say(sprint("tgz.read, n %d off %bd", n, off));

	if(off != t.tgzoff)
		return (nil, "random reads on .tgz's not supported");

	if(!t.eof && len t.tgzdata == 0) {
		# handle filter msgs until we find either result, finished, or error
	next:
		for(;;) {
			pick m := (msg := <-t.rq) {
			Fill =>
				if(len t.data == 0) {
					if(t.mf == nil) {
						m.reply <-= 0;
						continue next;
					}

					f := hd t.mf;
					t.mf = tl t.mf;

					say(sprint("tgz.read, starting on next file, %q", f.path));
					(data, err) := repo.readfile(f.path, f.nodeid);
					if(err != nil)
						return (nil, err);

					last := 0;
					if(t.mf == nil)
						last = 2*512;

					hdr := tarhdr(f.path, big len data, 0);
					pad := len data % 512;
					if(pad != 0)
						pad = 512-pad;
					t.data = array[len hdr+len data+pad+last] of byte;
					t.data[len t.data-(pad+last):] = array[pad+last] of {* => byte 0};
					t.data[:] = hdr;
					t.data[len hdr:] = data;
				}

				give := len m.buf;
				if(len t.data < give)
					give = len t.data;
				m.buf[:] = t.data[:give];
				t.data = t.data[give:];
				m.reply <-= give;
				
			Result =>
				t.tgzdata = array[len m.buf] of byte;
				t.tgzdata[:] = m.buf;
				m.reply <-= 1;
				break next;

			Finished =>
				if(len m.buf != 0)
					raise "deflate had leftover data...";
				say("tgz.read, finished...");
				t.eof = 1;
				break next;

			Info =>
				say("inflate info: "+m.msg);

			Error =>
				return (nil, m.e);
			}
		}
	}

	give := n;
	if(len t.tgzdata < give)
		give = len t.tgzdata;
	rem := array[len t.tgzdata-give] of byte;
	rem[:] = t.tgzdata[give:];
	r := array[give] of byte;
	r[:] = t.tgzdata[:give];
	t.tgzdata = rem;
	t.tgzoff += big give;
	say(sprint("tgz.read, gave %d bytes, remaining len t.tgzdata %d", give, len t.tgzdata));
	return (r, nil);
}

Tgz.close(t: self ref Tgz)
{
	if(t.pid >= 0)
		kill(t.pid);
	t.pid = -1;
}


TARPATH:	con 0;
TARMODE:	con 100;
TARUID:		con 108;
TARGID:		con 116;
TARSIZE:	con 124;
TARMTIME:	con 136;
TARCHECKSUM:	con 148;
TARLINK:	con 156;
tarhdr(path: string, size: big, mtime: int): array of byte
{
	d := array[512] of {* => byte 0};
	d[TARPATH:] = array of byte path;
	d[TARMODE:] = array of byte string sprint("%8o", 8r644);
	d[TARUID:] = array of byte string sprint("%8o", 0);
	d[TARGID:] = array of byte string sprint("%8o", 0);
	d[TARSIZE:] = array of byte sprint("%12bo", size);
	d[TARMTIME:] = array of byte sprint("%12o", mtime);
	d[TARLINK] = byte '0'; # '0' is normal file;  '5' is directory

	d[TARCHECKSUM:] = array[8] of {* => byte ' '};
	sum := 0;
	for(i := 0; i < len d; i++)
		sum += int d[i];
	d[TARCHECKSUM:] = array of byte sprint("%6o", sum);
	d[TARCHECKSUM+6:] = array[] of {byte 0, byte ' '};
	return d;
}


suffix(suf, s: string): int
{
	return len suf <= len s && suf == s[len s-len suf:];
}

has(s: string, c: int): int
{
	for(i := 0; i < len s; i++)
		if(s[i] == c)
			return 1;
	return 0;
}

l2a[T](l: list of T): array of T
{
	a := array[len l] of T;
	i := 0;
	for(; l != nil; l = tl l)
		a[i++] = hd l;
	return a;
}

kill(pid: int)
{
	fd := sys->open(sprint("/prog/%d/ctl", pid), Sys->OWRITE);
	if(fd != nil)
		sys->fprint(fd, "kill");
}

warn(s: string)
{
	sys->fprint(sys->fildes(2), "%s\n", s);
}

say(s: string)
{
	if(dflag)
		warn(s);
}

fail(s: string)
{
	warn(s);
	raise "fail:"+s;
}
