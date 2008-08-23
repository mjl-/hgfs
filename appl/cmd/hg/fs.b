implement HgFs;

# todo
# - set Dir.length in Qrepofiles.  is this info in the revlog?  we may have to parse patches for this...
# - list both "last" and the last revision in readdir on /log & /files?
# - clean out the mftab more often
# - don't keep an Mf per walked-to file.  the qids allow us to reconstruct all info.  first read on plain file -> read data. first read on directory -> generate list of dirs, with file sizes.
# - make Files more authoritative?  i.e. use Table of rev -> Files, extract rev,gen from qid.  find Files (using rev), find repo file/dir using gen (just an array index) (if nil, make new one).  when reading from entry, generate data if necessary
# - fix walk to .. in files/<rev>/
# - remove Bigtable
# - make Mf.readdir not call Mf.walk all the time, it can do with less info
# - check (and probably fix) accounting of open fids/qids, at least for repofiles, but also for tgz files

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
	Table: import tables;
include "lists.m";
	lists: Lists;
include "mercurial.m";
	mercurial: Mercurial;
	Revlog, Repo, Nodeid, Change, Manifest, Manifestfile: import mercurial;



Dflag, dflag: int;
vflag: int;

Qroot, Qlastrev, Qfiles, Qlog, Qtgz, Qfilesrev, Qfilesrevlast, Qrepofile, Qlogrev, Qlogrevlast, Qtgzrev, Qtgzrevlast: con iota;
tab := array[] of {
	(Qroot,		".",		Sys->DMDIR|8r555),
	(Qlastrev,	"lastrev",	8r444),
	(Qfiles,	"files",	Sys->DMDIR|8r555),
	(Qlog,		"log",		Sys->DMDIR|8r555),
	(Qtgz,		"tgz",		Sys->DMDIR|8r555),
	(Qfilesrev,	"<rev>",	Sys->DMDIR|8r555),
	(Qfilesrevlast,	"last",		Sys->DMDIR|8r555),
	(Qrepofile,	"<repofile>",	8r555),
	(Qlogrev,	"<logrev>",	8r444),
	(Qlogrevlast,	"last",		8r444),
	(Qtgzrev,	"<tgzrev>",	8r444),
	(Qtgzrevlast,	"<XXX-rev.tgz>",	8r444),
};

# Qlogrev & Qtlogrevlast are essentially the same.
# so are Qtgzrev & Qtgzrevlast.
# and Qfilesrev, Qfilesrevlast & Qrepofile.  these are the individual files in a particular revision.
# qids for files in a revision are composed of:
# 8 bits qtype
# 24 bits manifest file generation number (<<8)
# 24 bits revision (<<32)
# this ensures qids are permanent for a repository

srv: ref Styxserver;
repo: ref Repo;
reponame: string;
starttime: int;
Norev: con 16r7fffff;
tgztab: ref Table[ref Tgz];
mftab: ref Bigtable[ref Mf];

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
	arg->setusage(arg->progname()+" [-Ddv] [-h path]");
	while((c := arg->opt()) != 0)
		case c {
		'D' =>	Dflag++;
			styxservers->traceset(Dflag);
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
	mftab = mftab.new(32, nil);

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
			srv.default(m);
			return;
		}
		say(sprint("read f.path=%bd", f.path));
		q := int f.path&16rff;
		id := int f.path>>8;

		case q {
		Qlastrev =>
			(rev, err) := repo.lastrev();
			if(err != nil)
				return replyerror(m, err);
			srv.reply(styxservers->readstr(m, sprint("%d", rev)));

		Qlogrevlast or Qlogrev =>
			(change, err) := repo.change(id);
			if(err != nil)
				return replyerror(m, err);
			srv.reply(styxservers->readstr(m, change.text()));

		Qtgzrevlast or Qtgzrev =>
			# find fid record
			# if no fid record:  if offset is 0, otherwise error out
			# if fid record:  if offset not what we expect, error out
			# if we have fid record, we ask for another x bytes (in read), and respond

			tgz := tgztab.find(f.fid);
			if(tgz == nil) {
				if(m.offset == big 0) {
					err: string;
					(tgz, err) = Tgz.new(id);
					if(err != nil)
						return replyerror(m, err);
					tgztab.add(f.fid, tgz);
				} else
					return replyerror(m, "random reads on .tgz's not supported");
			}
			(buf, err) := tgz.read(m.count, m.offset);
			if(err != nil)
				return replyerror(m, err);
			srv.reply(ref Rmsg.Read(m.tag, buf));

		Qrepofile or Qfilesrev or Qfilesrevlast =>
			mf := mftab.find(f.path);
			(data, err) := mf.read();
			if(err != nil)
				return replyerror(m, err);
			srv.reply(styxservers->readbytes(m, data));

		* =>
			replyerror(m, styxservers->Eperm);
		}

	Clunk =>  # flush, remove too?
		f := srv.getfid(m.fid);
		q := int f.path&16rff;
		id := int f.path>>8;

		case q {
		Qtgzrevlast or Qtgzrev =>
			tgztab.del(f.fid);
			srv.default(gm);
		* =>
			srv.default(gm);
		}

	* =>
		srv.default(gm);
	}
}

navigator(c: chan of ref Navop)
{
again:
	for(;;) {
		navop := <-c;
		id := int navop.path>>8;
		q := int navop.path&16rff;
		say(sprint("have navop, tag %d, q %d, id %d", tagof navop, q, id));

		pick op := navop {
		Stat =>
			say("stat");
			case q {
			Qfilesrev or Qfilesrevlast or Qrepofile =>
				mf := mftab.find(op.path);
				say(sprint("navigator, stat, op.path %bd, mf nil %d", op.path, mf == nil));
				op.reply <-= (mf.stat(), nil);
			* =>
				op.reply <-= (dir(int op.path, 0), nil);
			}

		Walk =>
			say(sprint("walk, name %q", op.name));

			# handle repository files, other are handled below
			case q {
			Qfilesrev or Qfilesrevlast or Qrepofile =>
				mf := mftab.find(op.path);
				(nmf, mfdir, err) := mf.walk(op.name);
				if(err != nil) {
					op.reply <-= (nil, err);
				} else {
					op.reply <-= (mfdir, nil);
					say(sprint("mftab, adding qidpath %bd, mf path %q", nmf.qidpath, nmf.path));
					mftab.add(nmf.qidpath, nmf);
				}
				continue again;
			}

			if(op.name == "..") {
				nq: int;
				case q {
				Qlogrev =>
					nq = Qlog;
				Qtgzrev =>
					nq = Qtgz;
				Qroot or Qlastrev or Qfiles or Qlog or Qtgz =>
					nq = Qroot;
				* =>
					raise sprint("unhandled case in walk .., q %d", q);
				}
				op.reply <-= (dir(nq, 0), nil);
				continue again;
			}

			case q {
			Qroot =>
				for(i := Qlastrev; i <= Qtgz; i++)
					if(tab[i].t1 == op.name) {
						op.reply <-= (dir(tab[i].t0, starttime), nil);
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
				(change, manifest, merr) := repo.manifest(rev);
				if(merr != nil) {
					op.reply <-= (nil, merr);
					continue again;
				}

				say("walk to files/<rev>/");
				mf := Mf.new(rev, manifest);
				say(sprint("mftab, adding qidpath %bd, mf path %q", mf.qidpath, mf.path));
				mftab.add(mf.qidpath, mf);
				say(sprint("walk okay, op.path %bd", op.path));
				op.reply <-= (mf.stat(), nil);

			Qlog =>
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

				op.reply <-= (dir(child(q)|rev<<8, 0), nil);

			Qtgz =>
				# check for reponame-rev.tgz
				if(!str->prefix(reponame+"-", op.name) || !suffix(".tgz", op.name)) {
					op.reply <-= (nil, styxservers->Enotfound);
					continue again;
				}
				revstr := op.name[len reponame+1:len op.name-len ".tgz"];
				(rev, err) := parserev(revstr);
				if(err != nil) {
					op.reply <-= (nil, err);
					continue again;
				}
					
				op.reply <-= (dir(child(q)|rev<<8, 0), nil);

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
					op.reply <-= (dir(Qlastrev+i, 0), nil);
					have++;
				}
			Qfiles or Qlog =>
				if(op.offset == 0 && op.count > 0)
					op.reply <-= (dir(last(q)|Norev<<8, 0), nil);
			Qtgz =>
				if(op.offset == 0 && op.count > 0) {
					(rev, err) := repo.lastrev();
					if(err != nil) {
						op.reply <-= (nil, err);
						continue again;
					}
					op.reply <-= (dir(last(q)|rev<<8, 0), nil);
				}

			Qfilesrev or Qfilesrevlast or Qrepofile =>
				mf := mftab.find(op.path);
				mf.readdir(op);

			* =>
				raise sprint("unhandled case for readdir %d", q);
			}

			op.reply <-= (nil, nil);
		}
	}
}

last(q: int): int
{
	case q {
	Qfiles =>	return Qfilesrevlast;
	Qlog =>		return Qlogrevlast;
	Qtgz =>		return Qtgzrevlast;
	* =>	raise sprint("bogus call 'last' on q %d", q);
	}
}

child(q: int): int
{
	case q {
	Qfiles =>	return Qfilesrev;
	Qlog =>		return Qlogrev;
	Qtgz =>		return Qtgzrev;
	Qfilesrev =>	return Qrepofile;
	* =>	raise sprint("bogus call 'child' on q %d", q);
	}
}

parserev(s: string): (int, string)
{
	if(s == "0")
		return (0, nil);
	if(str->take(s, "0") != "")
		return (0, "bogus leading zeroes");
	(rev, rem) := str->toint(s, 10);
	if(rem != nil)
		return (0, "bogus trailing characters after revision");
	return (rev, nil);
}

dir(path, mtime: int): ref Sys->Dir
{
	q := path&16rff;
	id := path>>8;
	(nil, name, perm) := tab[q];
	say(sprint("dir, path %d, name %q", path, name));

	d := ref sys->zerodir;
	d.name = name;
	if(id != Norev && (q == Qfilesrevlast || q == Qfilesrev || q == Qlogrevlast || q == Qlogrev))
		d.name = sprint("%d", id);
	if(id != Norev && (q == Qtgzrevlast || q == Qtgzrev))
		d.name = sprint("%s-%d.tgz", reponame, id);
	d.uid = d.gid = "hgfs";
	d.qid.path = big path;
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


Files: adt {
	mf:	ref Manifest;
	files:	list of ref (string, int, int, big, int, ref Nodeid);  # has both normal files and directories.  dirs don't have a nodeid.  dirs end in a slash.

	new:	fn(mf: ref Manifest): ref Files;
	dirs:	fn(f: self ref Files, path: string): array of string;  # xxx (name, isdir, gen, size, q)
	walk:	fn(f: self ref Files, path, name: string): ref (string, int, int, big, int, ref Nodeid);  # new path, isdir, gen, q, nodeid
};


gendirs(prevdir: string, gen: int, path: string): (string, int, list of ref (string, int, int, big, int, ref Nodeid))
{
	(path, nil) = str->splitstrr(path, "/");
	if(path == nil)
		return (prevdir, gen, nil);

	if(path[len path-1] != '/')
		raise "wuh?";
	path = path[:len path-1];
	if(str->prefix(path, prevdir))
		return (prevdir, gen, nil);

	dirs: list of ref (string, int, int, big, int, ref Nodeid);
	s: string;
	for(el := sys->tokenize(path, "/").t1; el != nil; el = tl el) {
		s += "/"+hd el;
		if(str->prefix(s[1:], prevdir))
			continue;  # already present
		dirs = ref (s[1:], 1, gen++, big 0, 0, nil)::dirs;
	}

	return (path, gen, dirs);
}

Files.new(mf: ref Manifest): ref Files
{
	say("files.new");
	r: list of ref (string, int, int, big, int, ref Nodeid);
	prevdir: string;  # previous dir we generated
	gen := 1;

	r = ref ("", 1, gen++, big 0, Qrepofile, nil)::r;
	for(l := mf.files; l != nil; l = tl l) {
		m := hd l;

		dirs: list of ref (string, int, int, big, int, ref Nodeid);
		(prevdir, gen, dirs) = gendirs(prevdir, gen, m.path);
		r = lists->concat(dirs, r);

		r = ref (m.path, 0, gen++, big 0, Qrepofile, m.nodeid)::r;
	}
	say(sprint("files.new done, have %d paths:", len r));
	f := ref Files (mf, lists->reverse(r));
	return f;
}

Files.dirs(f: self ref Files, path: string): array of string
{
	say(sprint("files.dirs, for path %q", path));
	r: list of string;
	if(path != nil)
		path = "/"+path;
	for(l := f.files; l != nil; l = tl l) {
		p := "/"+(hd l).t0;
		say(sprint("checking %q against %q", path, p));
		if(str->prefix(path+"/", p) && !has(p[len path+1:], '/')) {
			elem := p[len path+1:];
			if(elem != nil && (r == nil || hd r != elem)) {
				say(sprint("adding elem %q", elem));
				r = elem::r;
			}
		}
	}
	say(sprint("files.dirs, have %d elems", len r));
	return l2a(r);
}

Files.walk(f: self ref Files, path, name: string): ref (string, int, int, big, int, ref Nodeid)
{
	say(sprint("files.walk, path %q, name %q", path, name));
	npath := path;
	if(name == "..") {
		# xxx handle .. from files/<rev>/
		if(path == "")
			raise "xxx not yet implemented";
		(npath, nil) = str->splitstrr(path, "/");
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

	for(l := f.files; l != nil; l = tl l)
		if((hd l).t0 == npath)
			return hd l;
	say(sprint("files.walk, no hit for %q in %q", npath, path));
	return nil;
}


Mf: adt {
	rev:	int;
	path:	string;
	nodeid:	ref Nodeid;
	qidpath:	big;
	mode:	int;
	mtime:	int;
	data:	array of byte;
	dirs:	array of string; # file names
	files:	ref Files;

	new:	fn(rev: int, manifest: ref Manifest): ref Mf;
	walk:	fn(mf: self ref Mf, name: string): (ref Mf, ref Sys->Dir, string);
	read:	fn(mf: self ref Mf): (array of byte, string);
	readdir:	fn(mf: self ref Mf, op: ref Navop.Readdir);
	stat:	fn(mf: self ref Mf): ref Sys->Dir;
};

Mf.new(rev: int, manifest: ref Manifest): ref Mf
{
	files := Files.new(manifest);
	gen := 0;
	return ref Mf(rev, "", nil, big Qrepofile|big gen<<8|big rev<<32, 8r555|Sys->DMDIR, 0, nil, nil, files);
}

Mf.walk(mf: self ref Mf, name: string): (ref Mf, ref Sys->Dir, string)
{
	r := mf.files.walk(mf.path, name);
	if(r == nil)
		return (nil, nil, styxservers->Enotfound);
	(npath, isdir, gen, size, newq, nodeid) := *r;
	nqidpath := big Qrepofile|big gen<<8|big mf.rev<<32;
	say(sprint("mf.walk, from path %q qidpath %bd, to npath %q qidpath %bd (gen %d)", mf.path, mf.qidpath, npath, nqidpath, gen));
	mode := 8r444;
	if(isdir)
		mode = 8r555|Sys->DMDIR;
	nmf := ref Mf(mf.rev, npath, nodeid, nqidpath, mode, mf.mtime, nil, nil, mf.files);
	return (nmf, nmf.stat(), nil);
}

Mf.read(mf: self ref Mf): (array of byte, string)
{
	if(mf.data == nil) {
		(data, err) := repo.readfile(mf.path, mf.nodeid);
		if(err != nil)
			return (nil, err);
		mf.data = data;
	}
	return (mf.data, nil);
}

Mf.readdir(mf: self ref Mf, op: ref Navop.Readdir)
{
	say("mf.readdir");

	if(mf.dirs == nil) {
		say(sprint("calling mf.files.dirs for path %q", mf.path));
		mf.dirs = mf.files.dirs(mf.path);
	}

	say(sprint("mf.readdir, len mf.dirs %d, op.count %d, op.offset %d", len mf.dirs, op.count, op.offset));
	have := 0;
	for(i := 0; have < op.count && op.offset+i < len mf.dirs; i++) {
		say(sprint("mf.readdir, looking up %q", mf.dirs[i]));
		d := mf.walk(mf.dirs[i]).t1;
		if(d == nil)
			raise sprint("could not find dir for file %q", mf.dirs[i]);
		say(sprint("sending dir d.name %q", d.name));
		op.reply <-= (d, nil); # xxx make something called mfdir(), which is like dir() & Mf.walk()
		have++;
	}
	say(sprint("mf.readdir done, have %d, i %d", have, i));
}

# xxx merge with dir()?
Mf.stat(mf: self ref Mf): ref Sys->Dir
{
	say(sprint("mf.stat, rev %d, path %q, qidpath %bd, mode %o", mf.rev, mf.path, mf.qidpath, mf.mode));
	q := int (mf.qidpath & big 16rff);

	d := ref sys->zerodir;

	if(mf.path == nil)
		d.name = sprint("%d", mf.rev);
	else
		d.name = str->splitstrr(mf.path, "/").t1;

	d.uid = d.gid = "hgfs";
	d.qid.path = mf.qidpath;
	if(mf.mode&Sys->DMDIR)
		d.qid.qtype = Sys->QTDIR;
	else
		d.qid.qtype = Sys->QTFILE;
	d.mtime = d.atime = mf.mtime;
	d.mode = mf.mode;
	say("mf.stat, done");
	return d;
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

	t := ref Tgz(rev, big 0, pid, rq, manifest, array[0] of byte, manifest.files, array[0] of byte);
	return (t, nil);
}

Tgz.read(t: self ref Tgz, n: int, off: big): (array of byte, string)
{
	say(sprint("tgz.read, n %d off %bd", n, off));

	if(off != t.tgzoff)
		return (nil, "random reads on .tgz's not supported");

	if(t.mf == nil && len t.data == 0)
		return (array[0] of byte, nil);

	if(len t.tgzdata == 0) {
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


Bigtable: adt[T] {
	items:	array of list of (big, T);
	nilval:	T;

	new:	fn(nslots: int, nilval: T): ref Bigtable[T];
	add:	fn(t: self ref Bigtable, id: big, x: T): int;
	del:	fn(t: self ref Bigtable, id: big): int;
	find:	fn(t: self ref Bigtable, id: big): T;
};

Bigtable[T].new(nslots: int, nilval: T): ref Bigtable[T]
{
	# xxx actually hash...
	items := array[1] of list of (big, T);
	return ref Bigtable[T](items, nilval);
}

Bigtable[T].add(t: self ref Bigtable, id: big, x: T): int
{
	t.items[0] = (id, x)::t.items[0];
	return 1;
}

Bigtable[T].del(t: self ref Bigtable, id: big): int
{
	r: list of (big, T);
	for(l := t.items[0]; l != nil; l = tl l)
		if((hd l).t0 != id)
			r = hd l::r;
	t.items[0] = r;
	return 1;
}

Bigtable[T].find(t: self ref Bigtable, id: big): T
{
	for(l := t.items[0]; l != nil; l = tl l)
		if((hd l).t0 == id)
			return (hd l).t1;
	return t.nilval;
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
