implement HgFs;

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
include "util0.m";
	util: Util0;
	min, fail, warn, l2a, kill, killgrp, suffix: import util;
include "../../lib/bdiff.m";
include "mercurial.m";
	hg: Mercurial;
	Branch, Tag, Revlog, Repo, Entry, Change, Manifest, Mfile: import hg;
include "../../lib/mercurialwire.m";
	hgwire: Mercurialwire;

HgFs: module {
	init:	fn(nil: ref Draw->Context, args: list of string);
};


dflag: int;

Qroot, Qlastrev, Qfiles, Qchanges, Qlog, Qmanifest, Qmanifestfull, Qtags, Qbranches, Qtgz, Qstate, Qwire, Qfilesrev, Qlogrev, Qmanifestrev, Qmanifestfullrev, Qtgzrev: con iota;
tab := array[] of {
	(Qroot,		"<reponame>",	Sys->DMDIR|8r555),
	(Qlastrev,	"lastrev",	8r444),
	(Qfiles,	"files",	Sys->DMDIR|8r555),
	(Qchanges,	"changes",	Sys->DMDIR|8r555),
	(Qlog,		"log",		Sys->DMDIR|8r555),
	(Qmanifest,	"manifest",	Sys->DMDIR|8r555),
	(Qmanifestfull,	"manifestfull",	Sys->DMDIR|8r555),
	(Qtags,		"tags",		8r444),
	(Qbranches,	"branches",	8r444),
	(Qtgz,		"tgz",		Sys->DMDIR|8r555),
	(Qstate,	"state",	8r444),
	(Qwire,		"wire",		8r666),
	(Qfilesrev,	"<filesrev>",	Sys->DMDIR|8r555),
	(Qlogrev,	"<logrev>",	8r444),
	(Qmanifestrev,	"<manifestrev>",	8r444),
	(Qmanifestfullrev,	"<manifestfullrev>",	8r444),
	(Qtgzrev,	"<tgzrev>",	8r444),
};

# Qfilesrev are the individual files in a particular revision.
# qids for files in a revision are composed of:
# 8 bits qtype
# 24 bits manifest file generation number (<<8)
# 24 bits revision (<<32)
# when opening a revision, the file list in the revlog manifest is parsed,
# and a full file tree (only path names) is created.  gens are assigned
# incrementally, the root dir has gen 0.  Qtgz, Qlog, Qmanifest, Qmanifestfull always have gen 0.
# this ensures qids are permanent for a repository.

Changefile: adt {
	qpath,
	version,
	mtime,
	mode:	int;
	name,
	path:	string;
	files:	cyclic array of ref Changefile;
	pqpath:	int;

	dir:	fn(c: self ref Changefile): ref Sys->Dir;
};

srv: ref Styxserver;
repo: ref Repo;
reponame: string;
time0: int;

tgztab: ref Table[ref Tgz];
wiretab: ref Table[ref Sys->FD];
changetab: ref Table[ref Changefile];  # qid.path -> Changefile, populated on demand
changegen := 0;

revtreetab: ref Table[ref Revtree];
revtreesize := 0;
revtreemax := 64;

revloglock: chan of int;
revlogmax: con 16;
revlogtab := array[revlogmax] of (string, ref Revlog, int);  # path, revlog, lastuse
Revlogtimeout: con 5*60;  # time after last use that cached revlog is scheduled for remove

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
	util = load Util0 Util0->PATH;
	util->init();
	hg = load Mercurial Mercurial->PATH;
	hg->init(1);
	hgwire = load Mercurialwire Mercurialwire->PATH;
	hgwire->init();

	hgpath := "";

	sys->pctl(Sys->NEWPGRP, nil);

	arg->init(args);
	arg->setusage(arg->progname()+" [-Dd] [-T revcache] [-h path]");
	while((c := arg->opt()) != 0)
		case c {
		'D' =>	styxservers->traceset(1);
		'T' =>	revtreemax = int arg->earg();
		'd' =>	hg->debug = hgwire->dflag = dflag++;
		'h' =>	hgpath = arg->earg();
		* =>	arg->usage();
		}
	args = arg->argv();
	if(len args != 0)
		arg->usage();

	time0 = daytime->now();

	revloglock = chan[1] of int;
	revloglock <-= 1;

	{ repo = Repo.xfind(hgpath); }
	exception x { "hg:*" => fail(x[3:]); }
	say("found repo");

	reponame = repo.name();
	tab[Qroot].t1 = reponame;
	tgztab = tgztab.new(32, nil);
	revtreetab = revtreetab.new(1+revtreemax/16, nil);

	wiretab = wiretab.new(32, nil);
	changetab = changetab.new(31, nil);
	rootchange := ref Changefile (Qchanges+(changegen++<<8), 0, 0, 8r555|Sys->DMDIR, "changes", "", array[0] of ref Changefile, 0);
	changetab.add(rootchange.qpath, rootchange);

	navch := chan of ref Navop;
	spawn navigator(navch);

	nav := Navigator.new(navch);
	msgc: chan of ref Tmsg;
	(msgc, srv) = Styxserver.new(sys->fildes(0), nav, big Qroot);

	spawn styxsrv(msgc);
	spawn revlogcleaner();
}

styxsrv(msgc: chan of ref Tmsg)
{
done:
	for(;;) alt {
	gm := <-msgc =>
		if(gm == nil)
			break done;
		pick m := gm {
		Readerror =>
			warn("read error: "+m.error);
			break done;
		}
		dostyx(gm);
	}
	killgrp(sys->pctl(0, nil));
}

wirefidstr(m: ref Tmsg.Write, t: (string, string))
{
	p := array[2] of ref Sys->FD;
	(s, err) := t;
	if(err == nil && sys->pipe(p) < 0)
		err = sprint("pipe: %r");
	# data will be small and easily fit in the pipe buffer,
	# thus this write won't block even though we don't have a reader yet
	if(err == nil && sys->write(p[0], d := array of byte s, len d) != len d)
		err = sprint("pipe write: %r");
	wirefidfd(m, (p[1], err));
}

wirefidfd(m: ref Tmsg.Write, t: (ref Sys->FD, string))
{
	(fd, err) := t;
	if(err != nil)
		return replyerror(m, err);
	wiretab.add(m.fid, fd);
	srv.reply(ref Rmsg.Write (m.tag, len m.data));
}

wireargs(s: string, keys: list of string): (list of string, string)
{
	v: list of string;
	while(s != nil) {
		l: string;
		(l, s) = str->splitstrl(s, "\n");
		if(s != nil)
			s = s[1:];
		v = l::v;
	}
	if(len keys != len v)
		return (nil, sprint("wrong number of arguments, want %d, got %d", len keys, len v));
	return (util->rev(v), nil);
}

dostyx(gm: ref Tmsg)
{
	pick m := gm {
	Write =>
		# write on Qwire sets the new command.  we spawn a prog that writes the output to a pipe.
		# each next styx read will take data from the pipe.
		f := srv.getfid(m.fid);
		q := int f.path&16rff;
		if(q != Qwire) {
			srv.default(m);
			return;
		}
		s := string m.data;
		cmd: string;
		(cmd, s) = str->splitstrl(s, "\n");
		if(s != nil)
			s = s[1:];
		say(sprint("write wire, cmd %q, s %q", cmd, s));
		keys: list of string;
		case cmd {
		"branches"	=> keys = "nodes"::nil;
		"between"	=> keys = "pairs"::nil;
		"lookup"	=> keys = "key"::nil;
		"changegroup"	=> keys = "roots"::nil;
		"changegroupsubset"	=> keys = "bases"::"heads"::nil;
		"revision"	=> keys = "key"::nil;
		}

		(args, err) := wireargs(s, keys);
		if(err != nil)
			return replyerror(m, err);
		case cmd {
		"capabilities"	=> wirefidstr(m, ("lookup changegroupsubset", nil));
		"heads"		=> wirefidstr(m, hgwire->heads(repo));
		"branches"	=> wirefidstr(m, hgwire->branches(repo, hd args));
		"between"	=> wirefidstr(m, hgwire->between(repo, hd args));
		"lookup"	=> wirefidstr(m, hgwire->lookup(repo, hd args));
		"changegroup"	=> wirefidfd(m, hgwire->changegroup(repo, hd args));
		"changegroupsubset"	=> wirefidfd(m, hgwire->changegroupsubset(repo, hd args, hd tl args));
		"revision" 	=>
			{
				(rev, nil) := repo.xlookup(hd args, 1);
				wirefidstr(m, (string rev, nil));
			} exception x {
			"hg:*" =>
				wirefidstr(m, (nil, x[3:]));
			}
		* =>	return replyerror(m, sprint("unknown command %#q", cmd));
		}

	Read =>
		{
			xdoread(m);
		} exception x {
		"hg:*" =>
			return replyerror(m, x[3:]);
		}

	Clunk or
	Remove =>
		f := srv.getfid(m.fid);
		q := int f.path&16rff;

		case q {
		Qtgzrev =>	tgztab.del(f.fid);
		Qwire =>	wiretab.del(f.fid);
		}
		srv.default(gm);

	* =>
		srv.default(gm);
	}
}

xdoread(m: ref Tmsg.Read)
{
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
		lastrev := repo.xlastrev();
		srv.reply(styxservers->readstr(m, string lastrev));

	Qtags =>
		if(m.offset == big 0 || f.data == nil) {
			tags := repo.xtags();
			s := "";
			for(l := tags; l != nil; l = tl l) {
				t := hd l;
				s += sprint("%q %s %d\n", t.n, t.name, t.rev);
			}
			f.data = array of byte s;
		}
		srv.reply(styxservers->readbytes(m, f.data));

	Qbranches =>
		if(m.offset == big 0 || f.data == nil) {
			branches := repo.xbranches();
			s := "";
			for(l := branches; l != nil; l = tl l) {
				b := hd l;
				s += sprint("%q %s %d\n", b.n, b.name, b.rev);
			}
			f.data = array of byte s;
		}
		srv.reply(styxservers->readbytes(m, f.data));

	Qlogrev =>
		if(m.offset == big 0 || f.data == nil) {
			(rev, nil) := revgen(f.path);
			s := repo.xchange(rev).text();
			f.data = array of byte s;
		}
		srv.reply(styxservers->readbytes(m, f.data));

	Qmanifestrev =>
		if(m.offset == big 0 || f.data == nil) {
			(rev, nil) := revgen(f.path);
			(nil, mm) := repo.xrevision(rev);
			f.data = array of byte manifesttext(mm);
		}
		srv.reply(styxservers->readbytes(m, f.data));

	Qmanifestfullrev =>
		if(m.offset == big 0 || f.data == nil) {
			(rev, nil) := revgen(f.path);
			(nil, mm) := repo.xrevision(rev);
			f.data = array of byte manifestfulltext(mm);
		}
		srv.reply(styxservers->readbytes(m, f.data));

	Qtgzrev =>
		tgz := tgztab.find(f.fid);
		if(tgz == nil) {
			if(m.offset != big 0)
				return replyerror(m, "random reads on .tgz's not supported");

			(rev, nil) := revgen(f.path);
			tgz = Tgz.new(rev);
			tgztab.add(f.fid, tgz);
		}
		buf := tgz.read(m.count, m.offset);
		srv.reply(ref Rmsg.Read(m.tag, buf));

	Qfilesrev =>
		(rev, gen) := revgen(f.path);
		d := fileread(treeget(rev), gen, m.count, m.offset);
		srv.reply(ref Rmsg.Read (m.tag, d));

	Qchanges =>
		if(m.offset == big 0 || f.data == nil) {
			c := changetab.find(int f.path);
			f.data = array of byte xchangehist(c);
		}
		srv.reply(styxservers->readbytes(m, f.data));

	Qstate =>
		if(m.offset == big 0 || f.data == nil) {
			s := sprint("reponame %q\nrevtree size %d max %d\n", reponame, revtreesize, revtreemax);

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
			f.data = array of byte s;
		}
		srv.reply(styxservers->readbytes(m, f.data));

	Qwire =>
		fd := wiretab.find(f.fid);
		if(fd == nil)
			return replyerror(m, "no command");
		buf := array[m.count] of byte;
		n := sys->read(fd, buf, len buf);
		if(n < 0)
			return replyerror(m, sprint("read: %r"));
		srv.reply(ref Rmsg.Read (m.tag, buf[:n]));

	* =>
		replyerror(m, styxservers->Eperm);
	}
}

navigator(c: chan of ref Navop)
{
	for(;;)
		navigate(<-c);
}

opreply(op: ref Navop, d: ref Sys->Dir)
{
	op.reply <-= (d, nil);
}

operror(op: ref Navop, err: string)
{
	op.reply <-= (nil, err);
}

navigate(navop: ref Navop)
{
	q := int navop.path&16rff;
	(rev, gen) := revgen(navop.path);
	say(sprint("have navop, tag %d, q %d, rev %d, gen %d", tagof navop, q, rev, gen));

	pick op := navop {
	Stat =>
		say("stat");
		case q {
		Qfilesrev =>
			{
				op.reply <-= treeget(rev).stat(gen);
			} exception x {
			"hg:*" =>
				op.reply <-= (nil, x[3:]);
			}

		Qchanges =>
			c := changetab.find(int op.path);
			if(c == nil)
				return operror(op, "no such Qchange");
			opreply(op, c.dir());
			
		* =>
			op.reply <-= (dir(op.path, time0), nil);
		}

	Walk =>
		say(sprint("walk, name %q", op.name));

		case q {
		Qfilesrev =>
			{
				op.reply <-= treeget(rev).walk(gen, op.name);
			} exception x {
			"hg:*" =>
				op.reply <-= (nil, x[3:]);
			}
			return;

		Qchanges =>
			c := changetab.find(int op.path);
			if(op.name == "..") {
				if(c.pqpath == 0)
					return opreply(op, dir(big Qroot, time0));
				return opreply(op, changetab.find(c.pqpath).dir());
			}
			changeupdate(c);
			for(i := 0; i < len c.files; i++)
				if(c.files[i].name == op.name)
					return opreply(op, c.files[i].dir());
			return operror(op, styxservers->Enotfound);
		}

		if(op.name == "..") {
			nq: int;
			case q {
			Qlogrev =>	nq = Qlog;
			Qmanifestrev =>	nq = Qmanifest;
			Qmanifestfullrev =>	nq = Qmanifestfull;
			Qtgzrev =>	nq = Qtgz;
			* =>		nq = Qroot;
			}
			op.reply <-= (dir(big nq, time0), nil);
			return;
		}

		case q {
		Qroot =>
			for(i := Qlastrev; i <= Qwire; i++)
				if(tab[i].t1 == op.name) {
					op.reply <-= (dir(big tab[i].t0, time0), nil);
					return;
				}
			op.reply <-= (nil, styxservers->Enotfound);

		Qfiles =>
			nrev: int;
			{
				nrev = parserev(op.name);
			} exception x {
			"hg:*" =>
				op.reply <-= (nil, x[3:]);
				return;
			}

			say("walk to files/<rev>/");
			{
				op.reply <-= treeget(nrev).stat(0);
			} exception x {
			"hg:*" =>
				op.reply <-= (nil, x[3:]);
			}

		Qlog or
		Qmanifest or
		Qmanifestfull =>
			nrev: int;
			{
				nrev = parserev(op.name);
				op.reply <-= (dir(child(q)|big nrev<<32, revmtime(nrev)), nil);
			} exception x {
			"hg:*" =>
				op.reply <-= (nil, x[3:]);
				return;
			}

		Qtgz =>
			name := reponame+"-";
			if(!str->prefix(name, op.name) || !suffix(".tgz", op.name)) {
				op.reply <-= (nil, styxservers->Enotfound);
				return;
			}
			revstr := op.name[len name:len op.name-len ".tgz"];
			nrev: int;
			{
				if(revstr == "latest") {
					nrev = repo.xlastrev();
				} else {
					# look for branch-rev
					(nil, brrev) := str->splitstrl(revstr, "-");
					if(brrev != nil)
						revstr = brrev[1:];
					nrev = parserev(revstr);
				}
				if(nrev < 0)
					op.reply <-= (nil, styxservers->Enotfound);
				else
					op.reply <-= (dir(child(q)|big nrev<<32, revmtime(nrev)), nil);
			} exception {
			"hg:*" =>
				op.reply <-= (nil, styxservers->Enotfound);
			}

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
				op.reply <-= (dir(big (Qlastrev+i), time0), nil);
				have++;
			}
		Qfiles or
		Qlog or
		Qmanifest or
		Qmanifestfull or
		Qtgz =>
			# tip, branch tips, tags
			{
				t := repo.xtags();
				b := repo.xbranches();
				trev := repo.xlastrev();
				say(sprint("list revisions, %d tags, %d branches, 1 lastrev", len t, len b));
				if(trev < 0)
					break;
				r := array[1+len b+len t] of (int, string, int);
				i := 0;
				Ttip, Tbranch, Ttag: con iota;
				r[i++] = (Ttip, "tip", trev);
				for(; b != nil; b = tl b)
					r[i++] = (Tbranch, (hd b).name, (hd b).rev);
				for(; t != nil; t = tl t)
					r[i++] = (Ttag, (hd t).name, (hd t).rev);

				s := op.offset;
				if(s > len r)
					s = len r;
				e := s+op.count;
				if(e > len r)
					e = len r;
				say(sprint("list revisions, len r %d, s %d, e %d", len r, s, e));
				while(s < e) {
					(typ, name, rrev) := r[s++];
					mtime := revmtime(rrev);
					d := dir(big child(q)|big rrev<<32, mtime);
					case q {
					Qfiles or
					Qlog or
					Qmanifest or
					Qmanifestfull =>
						d.name = name;
						if(typ == Tbranch)
							d.name = d.name+"-tip";
					Qtgz =>
						case typ {
						Ttip =>
							d.name = sprint("%s-%d.tgz", reponame, rrev);
						Tbranch =>
							d.name = sprint("%s-%s-%d.tgz", reponame, name, rrev);
						Ttag =>
							d.name = sprint("%s-%s.tgz", reponame, name);
						}
					}
					op.reply <-= (d, nil);
				}
			} exception x {
			"hg:*" =>
				warn(sprint("list revisions, err %q", x[3:]));
				op.reply <-= (nil, x[3:]);
				return;
			}

		Qchanges =>
			c := changetab.find(int op.path);
			if(op.offset == 0)
				changeupdate(c);
			end := min(len c.files, op.offset+op.count);
			for(i := op.offset; i < end; i++)
				op.reply <-= (c.files[i].dir(), nil);

		Qfilesrev =>
			{
				if(!treeget(rev).readdir(gen, op))
					return;
			} exception x {
			"hg:*" =>
				op.reply <-= (nil, x[3:]);
			}

		* =>
			raise sprint("unhandled case for readdir %d", q);
		}

		op.reply <-= (nil, nil);
	}
}

changenodeid(ents: array of ref Entry, rev: int): string
{
	if(rev < 0)
		return "''";
	return ents[rev].nodeid;
}

xchangehist(c: ref Changefile): string
{
	rl := repo.xopenrevlog(c.path);
	ents := rl.xentries();
	s := "";
	for(i := 0; i < len ents; i++) {
		e := ents[i];
		s += sprint("%d %d %s %d %d", e.link, e.rev, e.nodeid, e.p1, e.p2);
		s += " "+changenodeid(ents, e.p1);
		s += " "+changenodeid(ents, e.p2);
		s += "\n";
	}
	return s;
}

changeupdate(c: ref Changefile)
{
	if((c.mode & Sys->DMDIR) == 0)
		return;

	f := repo.storedir();
	isstore := repo.isstore();
	if(isstore)
		f += "/data";
	f += c.path;
	fd := sys->open(f, Sys->OREAD);
	if(fd == nil)
		return warn(sprint("open %q: %r", f));
	(ok, dir) := sys->fstat(fd);
	if(ok < 0 || dir.qid.vers == c.version && dir.mtime == c.mtime)
		return;
	c.version = dir.qid.vers;
	c.mtime = dir.mtime;
	for(;;) {
		(n, a) := sys->dirread(fd);
		if(n == 0)
			break;
		if(n < 0)
			return warn(sprint("dirread %q: %r", f));
	File:
		for(i := 0; i < len a; i++) {
			d := a[i];

			name: string;
			{
				name = repo.xunescape(d.name);
			} exception x {
			"hg:*" =>
				return warn(x[3:]);
			}
			if(len name >= 2 && name[len name-2:] == ".d")
				continue;
			if(len name >= 2 && name[len name-2:] == ".i")
				name = name[:len name-2];
			if(!isstore && (name == "00changelog" || name == "00manifest"))
				continue;

			for(j := 0; j < len c.files; j++)
				if(c.files[j].name == name)
					continue File;

			mode := 8r444;
			if(d.mode & Sys->DMDIR)
				mode = 8r555|Sys->DMDIR;
			nc := ref Changefile (Qchanges+(changegen++<<8), 0, 0, mode, name, c.path+"/"+name, array[0] of ref Changefile, c.qpath);
			changetab.add(nc.qpath, nc);
			nfiles := array[len c.files+1] of ref Changefile;
			nfiles[:] = c.files;
			nfiles[len c.files] = nc;
			c.files = nfiles;
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
	{
		c := repo.xchange(rev);
		return c.when+c.tzoff;
	} exception {
	"hg:*" => ;
	}
	return 0;
}

child(q: int): big
{
	case q {
	Qfiles =>	return big Qfilesrev;
	Qlog =>		return big Qlogrev;
	Qmanifest =>	return big Qmanifestrev;
	Qmanifestfull =>	return big Qmanifestfullrev;
	Qtgz =>		return big Qtgzrev;
	* =>	raise sprint("bogus call 'child' on q %d", q);
	}
}

parserev(s: string): int
{
	if(s == "last")
		return repo.xlastrev();
	if(suffix("-tip", s))
		s = s[:len s-len "-tip"];
	(rev, nil) := repo.xlookup(s, 1);
	if(rev < 0)
		error("no such revision");
	return rev;
}

dir(path: big, mtime: int): ref Sys->Dir
{
	q := int path&16rff;
	(rev, nil) := revgen(path);
	(nil, name, perm) := tab[q];
	#say(sprint("dir, path %bd, name %q, rev %d, gen %d", path, name, rev, gen));

	d := ref sys->zerodir;
	d.name = name;
	if(q == Qlogrev || q == Qmanifestrev || q == Qmanifestfullrev)
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
	return d;
}

Changefile.dir(c: self ref Changefile): ref Sys->Dir
{
	d := ref sys->zerodir;
	d.name = c.name;
	d.uid = d.gid = "hg";
	d.qid.path = big c.qpath;
	if(c.mode & Sys->DMDIR) {
		d.qid.qtype = Sys->QTDIR;
		d.mode = 8r555|Sys->DMDIR;
	} else {
		d.qid.qtype = Sys->QTFILE;
		d.mode = 8r444;
	}
	d.mtime = d.atime = time0;
	return d;
}

replyerror(m: ref Tmsg, s: string)
{
	srv.reply(ref Rmsg.Error(m.tag, s));
}

manifesttext(m: ref Manifest): string
{
	s := "";
	for(i := 0; i < len m.files; i++)
		s += m.files[i].path+"\n";
	return s;
}

manifestfulltext(m: ref Manifest): string
{
	s := "";
	for(i := 0; i < len m.files; i++)
		s += m.files[i].nodeid+" "+m.files[i].path+"\n";
	return s;
}


fileread(r: ref Revtree, gen: int, n: int, off: big): array of byte
{
	if(srv.msize > 0 && n > srv.msize)
		n = srv.msize;
	return r.pread(gen, n, off);
}


revlogcleaner()
{
	for(;;) {
		sys->sleep(120*1000);
		<-revloglock;
		cut := daytime->now()-Revlogtimeout;
		for(i := len revlogtab-1; i >= 0; i--) {
			(nil, nil, lastuse) := revlogtab[i];
			if(lastuse <= cut)
				revlogtab[i] = (nil, nil, 0);
		}
		revloglock <-= 1;
	}
}

openrevlog(path: string): ref Revlog
{
	<-revloglock;
	for(i := 0; i < len revlogtab; i++) {
		(rlpath, rl, nil) := revlogtab[i];
		if(rlpath == path) {
			revlogtab[i].t2 = daytime->now();
			revloglock <-= 1;
			return rl;
		}
	}

	{
		rl := repo.xopenrevlog(path);
		revlogtab[1:] = revlogtab[:len revlogtab-1];
		revlogtab[0] = (path, rl, daytime->now());
		revloglock <-= 1;
		return rl;
	} exception {
	"hg:*" =>
		revloglock <-= 1;
		raise;
	}
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
treeget(rev: int): ref Revtree
{
	rt := revtreetab.find(rev);
	if(rt == nil) {
		(c, m) := repo.xrevision(rev);
		rt = Revtree.new(c, m, rev);
		if(revtreesize >= revtreemax)
			treepurge();
		else
			revtreesize++;
		revtreetab.add(rev, rt);
	}
	rt.used = treeusegen++;
	return rt;
}


# file in a revtree
File: adt {
	gen:	int;	# gen
	pgen:	int;	# parent gen, for dotdot
	path:	string;
	name:	string;
	mode:	int;
	pick {
	Plain =>
		nodeid:	string;
		rev:	int;	# -1 => not yet valid
		length:	int;	# idem
		mtime:	int;	# idem
	Dir =>
		files:	list of int;	# gens of children
	}

	new:	fn(gen, pgen: int, path: string, nodeid: string, flags: int): ref File;
	getplain:	fn(f: self ref File): ref File.Plain;
	getdir:	fn(f: self ref File): ref File.Dir;
	text:	fn(f: self ref File): string;
};

File.new(gen, pgen: int, path: string, nodeid: string, flags: int): ref File
{
	name := str->splitstrr(path, "/").t1;
	if(nodeid == nil)
		return ref File.Dir (gen, pgen, path, name, 8r555|Sys->DMDIR, nil);

	mode := 8r444;
	if(flags & Mercurial->Flink)
		mode |= 8r111;
	return ref File.Plain (gen, pgen, path, name, mode, nodeid, -1, -1, -1);
}

File.getplain(ff: self ref File): ref File.Plain
{
	pick f := ff {
	Plain =>	return f;
	}
	raise "file not plain";
}

File.getdir(ff: self ref File): ref File.Dir
{
	pick f := ff {
	Dir =>	return f;
	}
	raise "file not dir";
}

File.text(f: self ref File): string
{
	pick ff := f {
	Plain =>
		return sprint("<file.plain gen %d,%d, name %q, path %q, nodeid %s, rev %d, length %d, mtime %d>",
			f.gen, f.pgen, f.name, f.path, ff.nodeid, ff.rev, ff.length, ff.mtime);
	Dir =>	return sprint("<file.dir gen %d,%d, name %q, path %q>", f.gen, f.pgen, f.name, f.path);
	}
}


# all paths of a tree of a single revision
Revtree: adt {
	rev:	int;
	tree:	array of ref File;
	mtime:	int;
	used:	int;

	new:	fn(c: ref Change, mf: ref Manifest, rev: int): ref Revtree;
	readdir:	fn(r: self ref Revtree, gen: int, op: ref Navop.Readdir): int;
	pread:	fn(r: self ref Revtree, gen: int, n: int, off: big): array of byte;
	stat:	fn(r: self ref Revtree, gen: int): (ref Sys->Dir, string);
	walk:	fn(r: self ref Revtree, gen: int, name: string): (ref Sys->Dir, string);
};


findgen(p: string, l: list of ref File): ref File.Dir
{
	for(; l != nil; l = tl l)
		if((hd l).path == p)
			return (hd l).getdir();
	return nil;
}

# add as directories:  the parent of path, then path itself
# return the gen of path and an updated list of files
dirgen(path: string, r: list of ref File): (ref File.Dir, list of ref File)
{
	pf := findgen(path, r);
	if(pf != nil)
		return (pf, r);  # already present

	ppath := str->splitstrr(path, "/").t0;
	if(ppath != nil)
		ppath = ppath[:len ppath-1];
	(pf, r) = dirgen(ppath, r);
	f := File.new((hd r).gen+1, pf.gen, path, nil, 0);
	pf.files = f.gen::pf.files;
	r = f::r;
	return (f.getdir(), r);
}

Revtree.new(c: ref Change, m: ref Manifest, rev: int): ref Revtree
{
	say("revtree.new");

	# the file list is sorted and only contains files, not directories.
	# the revtree does explicitly have directories,
	# so before adding a file, we add directories that we haven't seen yet.

	# root dir, special with its gen==pgen and name not from path
	rf: ref File;
	rf = ref File.Dir (0, 0, nil, string rev, 8r555|Sys->DMDIR, nil);
	r := rf::nil;

	for(i := 0; i < len m.files; i++) {
		mf := m.files[i];
		dpath := str->splitstrr(mf.path, "/").t0;
		if(dpath != nil)
			dpath = dpath[:len dpath-1];
		pf: ref File.Dir;
		(pf, r) = dirgen(dpath, r);

		f := File.new((hd r).gen+1, pf.gen, mf.path, mf.nodeid, mf.flags);
		r = f::r;
		pf.files = f.gen::pf.files;
	}
	rt := ref Revtree (rev, l2a(util->rev(r)), c.when+c.tzoff, 0);

	if(dflag) {
		say(sprint("revtree.new done, have %d paths:", len r));
		for(i = 0; i < len rt.tree; i++)
			say(sprint("\t%s", rt.tree[i].text()));
		say("eol");
	}

	return rt;
}

Revtree.readdir(r: self ref Revtree, gen: int, op: ref Navop.Readdir): int
{
	f := r.tree[gen].getdir();
	if(dflag)say(sprint("revtree.readdir, for %s", f.text()));

	say(sprint("revtree.readdir, len files %d, op.count %d, op.offset %d", len f.files, op.count, op.offset));
	a := revinta(f.files);
	s := op.offset;
	if(s > len a)
		s = len a;
	e := len a;
	if(e > s+op.count)
		e = s+op.count;
	while(s < e) {
		(d, err) := r.stat(a[s++]);
		op.reply <-= (d, err);
		if(err != nil) {
			say("revtree.readdir, stopped after error: "+err);
			return 0;
		}
	}
	say(sprint("revtree.readdir done, end %d", e));
	return 1;
}

revinta(l: list of int): array of int
{
	a := array[len l] of int;
	i := len a-1;
	for(; l != nil; l = tl l)
		a[i--] = hd l;
	return a;
}

Revtree.walk(r: self ref Revtree, gen: int, name: string): (ref Sys->Dir, string)
{
	f := r.tree[gen];
	if(dflag)say(sprint("revtree.walk, name %q, file %s", name, f.text()));
	if(name == "..") {
		if(f.gen == 0)
			return (dir(big Qfiles, time0), nil);
		return r.stat(f.pgen);
	}

	pick ff := f {
	Dir =>
		for(l := ff.files; l != nil; l = tl l)
			if(r.tree[hd l].name == name)
				return r.stat(hd l);
	}

	say(sprint("revtree.walk, no hit for %q in %q", name, f.path));
	return (nil, styxservers->Enotfound);
}

filerev(rl: ref Revlog, f: ref File.Plain): int
{
	if(f.rev < 0) {
		e := rl.xfindn(f.nodeid, 1);
		f.rev = e.rev;
	}
	return f.rev;
}

Revtree.pread(r: self ref Revtree, gen: int, n: int, off: big): array of byte
{
	f := r.tree[gen].getplain();
	if(dflag)say(sprint("revtree.read, f %s", f.text()));

	rl := openrevlog(f.path);
	rev := filerev(rl, f);
	return rl.xpread(rev, n, off);
}

Revtree.stat(r: self ref Revtree, gen: int): (ref Sys->Dir, string)
{
	f := r.tree[gen];
	if(dflag)say(sprint("revtree.stat, rev %d, file %s", r.rev, f.text()));

	d := ref sys->zerodir;
	d.name = f.name;
	d.uid = d.gid = "hg";
	d.qid.path = big Qfilesrev|big gen<<8|big r.rev<<32;

	pick ff := f {
	Plain =>
		d.qid.qtype = Sys->QTFILE;

		if(ff.length < 0) {
			rl := openrevlog(f.path);
			rev := filerev(rl, ff);
			ff.mtime = repo.xmtime(rl, rev);
			length := rl.xlength(rev);
			ff.length = int length;
		}

		d.length = big ff.length;
		d.mtime = d.atime = ff.mtime;
	Dir =>
		d.qid.qtype = Sys->QTDIR;
		d.length = big 0;
		d.mtime = d.atime = r.mtime;
	}

	d.mode = f.mode;
	say("revtree.stat, done");
	return (d, nil);
}



Tgz: adt {
	rev:	int;
	tgzoff:	big;
	pid:	int;  # of filter
	rq:	chan of ref Rq;
	manifest:	ref Manifest;

	data:	array of byte;  # of file-in-progress
	mf:	array of ref Mfile;  # files
	mfi:	int;	# index in files

	tgzdata:	array of byte;  # output from filter
	eof:	int;  # whether we've seen filters finished message
	dir:	string;

	new:	fn(rev: int): ref Tgz;
	read:	fn(t: self ref Tgz, n: int, off: big): array of byte;
	close:	fn(t: self ref Tgz);
};

Tgz.new(rev: int): ref Tgz
{
	(nil, mm) := repo.xrevision(rev);

	rq := deflate->start("h");
	msg := <-rq;
	pid: int;
	pick m := msg {
	Start =>	pid = m.pid;
	* =>		fail(sprint("bogus first message from deflate"));
	}

	dir := sprint("%s-%d/", reponame, rev);
	t := ref Tgz(rev, big 0, pid, rq, mm, array[0] of byte, mm.files, 0, array[0] of byte, 0, dir);
	return t;
}

Tgz.read(t: self ref Tgz, n: int, off: big): array of byte
{
	say(sprint("tgz.read, n %d off %bd", n, off));

	if(off != t.tgzoff)
		error("random reads on .tgz's not supported");

	if(!t.eof && len t.tgzdata == 0) {
		# handle filter msgs until we find either result, finished, or error
	next:
		for(;;)
		pick m := <-t.rq {
		Fill =>
			if(len t.data == 0) {
				if(t.mfi >= len t.mf) {
					m.reply <-= 0;
					continue next;
				}

				f := t.mf[t.mfi++];

				say(sprint("tgz.read, starting on next file, %q", f.path));

				rl := openrevlog(f.path);
				e := rl.xfindn(f.nodeid, 1);
				mtime := repo.xmtime(rl, e.rev);
				d := rl.xget(e.rev);

				last := 0;
				if(t.mfi >= len t.mf)
					last = 2*512;

				hdr := tarhdr(t.dir+f.path, big len d, mtime);
				pad := len d % 512;
				if(pad != 0)
					pad = 512-pad;
				t.data = array[len hdr+len d+pad+last] of byte;
				t.data[len t.data-(pad+last):] = array[pad+last] of {* => byte 0};
				t.data[:] = hdr;
				t.data[len hdr:] = d;
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
			say("deflate info: "+m.msg);

		Error =>
			error(m.e);
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
	return r;
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
	d[TARMODE:] = sys->aprint("%8o", 8r644);
	d[TARUID:] = sys->aprint("%8o", 0);
	d[TARGID:] = sys->aprint("%8o", 0);
	d[TARSIZE:] = sys->aprint("%12bo", size);
	d[TARMTIME:] = sys->aprint("%12o", mtime);
	d[TARLINK] = byte '0'; # '0' is normal file;  '5' is directory

	d[TARCHECKSUM:] = array[8] of {* => byte ' '};
	sum := 0;
	for(i := 0; i < len d; i++)
		sum += int d[i];
	d[TARCHECKSUM:] = sys->aprint("%6o", sum);
	d[TARCHECKSUM+6:] = array[] of {byte 0, byte ' '};
	return d;
}

has(s: string, c: int): int
{
	for(i := 0; i < len s; i++)
		if(s[i] == c)
			return 1;
	return 0;
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
