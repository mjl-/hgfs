Mercurial: module
{
	PATH:	con "/dis/lib/mercurial.dis";
	init:	fn(readonly: int);

	debug:	int;
	readonly:	int;
	nullnode:	con "0000000000000000000000000000000000000000";

	checknodeid:	fn(n: string): string;
	xchecknodeid:	fn(n: string);
	createnodeid:	fn(d: array of byte, n1, n2: string): (string, string);
	xcreatenodeid:	fn(d: array of byte, n1, n2: string): string;
	unhex:		fn(n: string): array of byte;
	hex:		fn(d: array of byte): string;
	differs:	fn(r: ref Repo, mf: ref Mfile): int;
	escape:		fn(path: string): string;
	xsanitize:	fn(path: string): string;
	ensuredirs:	fn(root, path: string);
	xreaduser:	fn(r: ref Repo): string;
	xreadconfigs:	fn(r: ref Repo): ref Configs;
	xentrylogtext:	fn(r: ref Repo, n: string, verbose: int): string;
	xopencreate:	fn(f: string, mode, perm: int): ref Sys->FD;
	xbopencreate:	fn(f: string, mode, perm: int): ref Bufio->Iobuf;
	xdirstate:	fn(r: ref Repo, all: int): ref Dirstate;
	xparsetags:	fn(r: ref Repo, s: string): list of ref Tag;
	xstreamin:	fn(r: ref Repo, b: ref Bufio->Iobuf);

	Entrysize:	con 64;

	Change: adt {
		rev:	int;
		nodeid:	string;
		p1, p2:	int;
		manifestnodeid:	string;
		who:	string;
		when, tzoff:	int;
		extra:	list of (string, string);
		files:	list of string;
		msg:	string;

		xparse:		fn(data: array of byte, e: ref Entry): ref Change;
		findextra:	fn(c: self ref Change, k: string): (string, string);
		hasfile:	fn(c: self ref Change, f: string): int;
		findfiles:	fn(c: self ref Change, f: string): list of string;
		text:	fn(c: self ref Change): string;
	};

	Flink, Fexec:	con 1<<iota;  # Mfile.flags
	Mfile: adt {
		path:	string;
		mode:	int;
		nodeid:	string;
		flags:	int;
	};

	Manifest: adt {
		nodeid:	string;
		files:	array of ref Mfile;

		xpack:	fn(m: self ref Manifest): array of byte;
		xparse:	fn(data: array of byte, n: string): ref Manifest;
		find:	fn(m: self ref Manifest, path: string): ref Mfile;
		add:	fn(m: self ref Manifest, mf: ref Mfile);
		del:	fn(m: self ref Manifest, path: string): int;
	};


	# note: STuntracked is not stored in file, only for internal purposes
	STnormal, STneedmerge, STremove, STadd, STuntracked: con iota; # Dsfile.state
	SZcheck, SZdirty: con -1-iota;
	Dsfile: adt {
		state:	int;
		mode:	int;
		size:	int;
		mtime:	int;
		path:	string;
		origpath:	string;	# only non-nil in case of copy/move
		missing:	int;  # note: not in dir state file.  not set for STremove

		isdirty:fn(f: self ref Dsfile): int;
		text:	fn(f: self ref Dsfile): string;
	};

	Context: adt {
		m1, m2:	ref Manifest;	# initially both nil, filled by Repo.xread
	};

	Dirstate: adt {
		dirty:	int;
		p1, p2:	string;
		l:	list of ref Dsfile;
		context:	ref Context;

		packedsize:	fn(e: self ref Dirstate): int;
		pack:	fn(e: self ref Dirstate, buf: array of byte);
		find:	fn(d: self ref Dirstate, path: string): ref Dsfile;
		findall:	fn(d: self ref Dirstate, pp: string, untracked: int): list of ref Dsfile;
		enumerate:	fn(d: self ref Dirstate, base: string, paths: list of string, untracked, vflag: int): (list of string, list of ref Dsfile);
		add:	fn(d: self ref Dirstate, dsf: ref Dsfile);
		del:	fn(d: self ref Dirstate, path: string);
		haschanges:	fn(d: self ref Dirstate): int;
	};


	Tag: adt {
		name:	string;
		n:	string;
		rev:	int;
	};

	Branch: adt {
		name:	string;
		n:	string;
		rev:	int;
	};


	Entry: adt {
		rev:	int;
		offset:	big;
		ioffset:	big;  # when .d is not present, offset has value as if it were.  ioffset is compensates for that, and points to real data offset in .i file
		flags:	int;
		csize:	int;
		uncsize:	int;
		base, link, p1, p2:     int;
		nodeid:	string;

		xpack:	fn(e: self ref Entry, buf: array of byte, indexonly: int);
		xparse:	fn(buf: array of byte, index: int): ref Entry;
		text:	fn(e: self ref Entry): string;
	};

	# Revlog.flags
	Indexonly:	con 1<<iota;
	Version0, Version1:	con iota;

	Revlog: adt {
		storedir,	# of repo
		rlpath,		# relative to store
		path:	string;	# full path
		ifd:	ref Sys->FD;
		dfd:	ref Sys->FD;  # nil when .i-only
		bd:	ref Bufio->Iobuf;
		version:int;
		flags:	int;
		ents:	array of ref Entry;
		tab:	ref Tables->Strhash[ref Entry];

		# cache of decompressed revisions (delta's).
		# cacheall caches all of them, for changelog & manifest.
		cache:	array of array of byte;
		ncache:	int;
		cacheall:	int;

		# cached last fully reconstructed revision, fullrev -1 means invalid
		full:	array of byte;
		fullrev:int;

		# .i time & length of latest reread, for determining freshness
		ilength:	big;
		imtime:	int;
		ivers:	int;

		xopen:		fn(storedir, path: string, cacheall: int): ref Revlog;
		xget:		fn(rl: self ref Revlog, rev: int): array of byte;
		xgetn:		fn(rl: self ref Revlog, n: string): array of byte;
		xlastrev:	fn(rl: self ref Revlog): int;
		xfind:		fn(rl: self ref Revlog, rev: int): ref Entry;
		xfindn:		fn(rl: self ref Revlog, n: string, need: int): ref Entry;
		xdelta:		fn(rl: self ref Revlog, prev, rev: int): array of byte;
		xstorebuf:	fn(rl: self ref Revlog, buf: array of byte, rev: int, pbuf, delta: array of byte, d: ref Bdiff->Delta): (int, array of byte);
		xpread:		fn(rl: self ref Revlog, rev: int, n: int, off: big): array of byte;
		xlength:	fn(rl: self ref Revlog, rev: int): big;

		xentries:	fn(rl: self ref Revlog): array of ref Entry;
		isindexonly:	fn(rl: self ref Revlog): int;
		xappend:	fn(rl: self ref Revlog, r: ref Repo, tr: ref Transact, nodeid, p1, p2: string, link: int, buf, pbuf, delta: array of byte, d: ref Bdiff->Delta): ref Entry;
		xstream:	fn(rl: self ref Revlog, r: ref Repo, tr: ref Transact, b: ref Bufio->Iobuf, ischlog: int, cl: ref Revlog): int;
	};

	Repo: adt {
		path:	string;
		requires:	list of string;
		reponame: 	string;
		lastrevision:	int;
		lastmtime:	int;

		# cached
		cl:		ref Revlog;
		ml:		ref Revlog;

		name:		fn(r: self ref Repo): string;
		workroot:	fn(r: self ref Repo): string;
		storedir:	fn(r: self ref Repo): string;
		isstore:	fn(r: self ref Repo): int;
		isrevlogv1:	fn(r: self ref Repo): int;

		xopen:		fn(path: string): ref Repo;
		xfind:		fn(path: string): ref Repo;
		xopenrevlog:	fn(r: self ref Repo, path: string): ref Revlog;
		xrevision:	fn(r: self ref Repo, rev: int): (ref Change, ref Manifest);
		xrevisionn:	fn(r: self ref Repo, n: string): (ref Change, ref Manifest);
		xlastrev:	fn(r: self ref Repo): int;
		xchange:	fn(r: self ref Repo, rev: int): ref Change;
		xchangen:	fn(r: self ref Repo, n: string): ref Change;
		xmtime:		fn(r: self ref Repo, rl: ref Revlog, rev: int): int;
		xwritedirstate:	fn(r: self ref Repo, ds: ref Dirstate);
		xworkdir:	fn(r: self ref Repo): string;
		xtags:		fn(r: self ref Repo): list of ref Tag;
		xrevtags:	fn(r: self ref Repo, revstr: string): list of ref Tag;
		xbranches:	fn(r: self ref Repo): list of ref Branch;
		xworkbranch:	fn(r: self ref Repo): string;
		xwriteworkbranch:	fn(r: self ref Repo, b: string);
		xheads:		fn(r: self ref Repo): list of string;
		xchangelog:	fn(r: self ref Repo): ref Revlog;
		xmanifestlog:	fn(r: self ref Repo): ref Revlog;
		xlookup:	fn(r: self ref Repo, rev: string, need: int): (int, string);
		xget:		fn(r: self ref Repo, revstr, path: string): array of byte;
		xread:		fn(r: self ref Repo, path: string, ds: ref Dirstate): array of byte;
		escape:		fn(r: self ref Repo, path: string): string;
		xunescape:	fn(r: self ref Repo, path: string): string;
		xensuredirs:	fn(r: self ref Repo, fullrlpath: string);
		xreadconfig:	fn(r: self ref Repo): ref Config;
		xtransact:	fn(r: self ref Repo): ref Transact;
		xrollback:	fn(r: self ref Repo, tr: ref Transact);
		xcommit:	fn(r: self ref Repo, tr: ref Transact);
	};

	Revlogstate: adt {
		path:	string;
		off:	big;
	};

	Transact: adt {
		fd:	ref Sys->FD;
		tab:	ref Tables->Strhash[ref Revlogstate];
		l:	list of ref Revlogstate;

		has:	fn(tr: self ref Transact, path: string): int;
		add:	fn(tr: self ref Transact, path: string, off: big);
	};

	Section: adt {
		name:	string;
		l:	list of ref (string, string); # key, value
	};

	Config: adt {
		l:	list of ref Section;

		find:	fn(c: self ref Config, sec, name: string): (int, string);
	};

	Configs: adt {
		l:	list of ref Config;

		has:	fn(c: self ref Configs, sec, name: string): int;
		get:	fn(c: self ref Configs, sec, name: string): string;
		find:	fn(c: self ref Configs, sec, name: string): (int, string);
	};
};
