Mercurial: module
{
	PATH:	con "/dis/lib/mercurial.dis";
	init:	fn();

	debug:	int;
	nullnode:	con "0000000000000000000000000000000000000000";

	checknodeid:	fn(n: string): string;
	xchecknodeid:	fn(n: string);
	createnodeid:	fn(d: array of byte, n1, n2: string): (string, string);
	xcreatenodeid:	fn(d: array of byte, n1, n2: string): string;
	unhex:		fn(n: string): array of byte;
	hex:		fn(d: array of byte): string;
	differs:	fn(r: ref Repo, size: big, mtime: int, mf: ref Manifestfile): int;
	escape:		fn(path: string): string;
	xsanitize:	fn(path: string): string;
	ensuredirs:	fn(root, path: string);
	xreaduser:	fn(r: ref Repo): string;
	xreadconfigs:	fn(r: ref Repo): ref Configs;
	xentrylogtext:	fn(r: ref Repo, ents: array of ref Entry, e: ref Entry, verbose: int): string;


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

		parse:		fn(data: array of byte, e: ref Entry): (ref Change, string);
		xparse:		fn(data: array of byte, e: ref Entry): ref Change;
		findextra:	fn(c: self ref Change, k: string): (string, string);
		text:	fn(c: self ref Change): string;
	};

	Flink, Fexec:	con 1<<iota;  # Manifestfile.flags
	Manifestfile: adt {
		path:	string;
		mode:	int;
		nodeid:	string;
		flags:	int;
	};

	Manifest: adt {
		nodeid:	string;
		files:	array of ref Manifestfile;

		xpack:	fn(m: self ref Manifest): array of byte;
		parse:	fn(data: array of byte, n: string): (ref Manifest, string);
		xparse:	fn(data: array of byte, n: string): ref Manifest;
		find:	fn(m: self ref Manifest, path: string): ref Manifestfile;
		add:	fn(m: self ref Manifest, mf: ref Manifestfile);
		del:	fn(m: self ref Manifest, path: string): int;
	};


	STnormal, STneedmerge, STremove, STadd, STuntracked: con iota; # Dirstatefile.state
	SZcheck, SZdirty: con iota;
	Dirstatefile: adt {
		state:	int;
		mode:	int;
		size:	int;
		mtime:	int;
		path:	string;
		origpath:	string;	# only non-nil in case of copy/move

		text:	fn(f: self ref Dirstatefile): string;
	};

	Dirstate: adt {
		p1, p2:	string;
		l:	list of ref Dirstatefile;

		packedsize:	fn(e: self ref Dirstate): int;
		pack:	fn(e: self ref Dirstate, buf: array of byte);
		find:	fn(d: self ref Dirstate, path: string): ref Dirstatefile;
		findall:	fn(d: self ref Dirstate, pp: string): list of ref Dirstatefile;
		add:	fn(d: self ref Dirstate, dsf: ref Dirstatefile);
	};

	workdirstate:	fn(path: string): (ref Dirstate, string);
	xworkdirstate:	fn(path: string): ref Dirstate;


	Tag: adt {
		name:	string;
		n:	string;
		rev:	int;
	};
	parsetags:	fn(r: ref Repo, s: string): (list of ref Tag, string);
	xparsetags:	fn(r: ref Repo, s: string): list of ref Tag;

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
		parse:	fn(buf: array of byte, index: int): (ref Entry, string);
		xparse:	fn(buf: array of byte, index: int): ref Entry;
		text:	fn(e: self ref Entry): string;
	};

	# Revlog.flags
	Indexonly:	con 1<<iota;
	Version0, Version1:	con iota;

	Revlog: adt {
		path:	string;
		ifd:	ref Sys->FD;
		dfd:	ref Sys->FD;  # nil when .i-only
		bd:	ref Bufio->Iobuf;
		version:int;
		flags:	int;
		ents:	array of ref Entry;

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

		open:		fn(path: string, cacheall: int): (ref Revlog, string);
		xopen:		fn(path: string, cacheall: int): ref Revlog;
		get:		fn(rl: self ref Revlog, rev: int): (array of byte, string);
		xget:		fn(rl: self ref Revlog, rev: int): array of byte;
		getnodeid:	fn(rl: self ref Revlog, n: string): (array of byte, string);
		xgetnodeid:	fn(rl: self ref Revlog, n: string): array of byte;
		lastrev:	fn(rl: self ref Revlog): (int, string);
		xlastrev:	fn(rl: self ref Revlog): int;
		find:		fn(rl: self ref Revlog, rev: int): (ref Entry, string);
		xfind:		fn(rl: self ref Revlog, rev: int): ref Entry;
		findnodeid:	fn(rl: self ref Revlog, n: string): (ref Entry, string);
		xfindnodeid:	fn(rl: self ref Revlog, n: string): ref Entry;
		delta:		fn(rl: self ref Revlog, prev, rev: int): (array of byte, string);
		xdelta:		fn(rl: self ref Revlog, prev, rev: int): array of byte;
		pread:		fn(rl: self ref Revlog, rev: int, n: int, off: big): (array of byte, string);
		xpread:		fn(rl: self ref Revlog, rev: int, n: int, off: big): array of byte;
		length:		fn(rl: self ref Revlog, rev: int): (big, string);
		xlength:	fn(rl: self ref Revlog, rev: int): big;
		xverify:	fn(rl: self ref Revlog);

		entries:	fn(rl: self ref Revlog): (array of ref Entry, string);
		xentries:	fn(rl: self ref Revlog): array of ref Entry;
		isindexonly:	fn(rl: self ref Revlog): int;
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

		open:		fn(path: string): (ref Repo, string);
		xopen:		fn(path: string): ref Repo;
		find:		fn(path: string): (ref Repo, string);
		xfind:		fn(path: string): ref Repo;
		name:		fn(r: self ref Repo): string;
		openrevlog:	fn(r: self ref Repo, path: string): (ref Revlog, string);
		xopenrevlog:	fn(r: self ref Repo, path: string): ref Revlog;
		manifest:	fn(r: self ref Repo, rev: int): (ref Change, ref Manifest, string);
		xmanifest:	fn(r: self ref Repo, rev: int): (ref Change, ref Manifest);
		lastrev:	fn(r: self ref Repo): (int, string);
		xlastrev:	fn(r: self ref Repo): int;
		change:		fn(r: self ref Repo, rev: int): (ref Change, string);
		xchange:	fn(r: self ref Repo, rev: int): ref Change;
		mtime:		fn(r: self ref Repo, rl: ref Revlog, rev: int): (int, string);
		xmtime:		fn(r: self ref Repo, rl: ref Revlog, rev: int): int;
		dirstate:	fn(r: self ref Repo): (ref Dirstate, string);
		xdirstate:	fn(r: self ref Repo): ref Dirstate;
		writedirstate:	fn(r: self ref Repo, ds: ref Dirstate): string;
		xwritedirstate:	fn(r: self ref Repo, ds: ref Dirstate);
		workroot:	fn(r: self ref Repo): string;
		xworkdir:	fn(r: self ref Repo): string;
		tags:		fn(r: self ref Repo): (list of ref Tag, string);
		xtags:		fn(r: self ref Repo): list of ref Tag;
		revtags:	fn(r: self ref Repo, revstr: string): (list of ref Tag, string);
		xrevtags:	fn(r: self ref Repo, revstr: string): list of ref Tag;
		branches:	fn(r: self ref Repo): (list of ref Branch, string);
		xbranches:	fn(r: self ref Repo): list of ref Branch;
		workbranch:	fn(r: self ref Repo): (string, string);
		xworkbranch:	fn(r: self ref Repo): string;
		writeworkbranch:	fn(r: self ref Repo, b: string): string;
		xwriteworkbranch:	fn(r: self ref Repo, b: string);
		heads:		fn(r: self ref Repo): (array of ref Entry, string);
		xheads:		fn(r: self ref Repo): array of ref Entry;
		changelog:	fn(r: self ref Repo): (ref Revlog, string);
		xchangelog:	fn(r: self ref Repo): ref Revlog;
		manifestlog:	fn(r: self ref Repo): (ref Revlog, string);
		xmanifestlog:	fn(r: self ref Repo): ref Revlog;
		lookup:		fn(r: self ref Repo, rev: string, need: int): (int, string, string);
		xlookup:	fn(r: self ref Repo, rev: string, need: int): (int, string);
		get:		fn(r: self ref Repo, revstr, path: string): (array of byte, string);
		xget:		fn(r: self ref Repo, revstr, path: string): array of byte;

		escape:		fn(r: self ref Repo, path: string): string;
		unescape:	fn(r: self ref Repo, path: string): (string, string);
		xunescape:	fn(r: self ref Repo, path: string): string;
		storedir:	fn(r: self ref Repo): string;
		isstore:	fn(r: self ref Repo): int;
		isrevlogv1:	fn(r: self ref Repo): int;

		xreadconfig:	fn(r: self ref Repo): ref Config;
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


	Hunk: adt {
		start,
		end:	int;
		buf:	array of byte;

		text:	fn(h: self ref Hunk): string;
	};

	Patch: adt {
		l:	list of ref Hunk;

		parse:	fn(d: array of byte): (ref Patch, string);
		xparse:	fn(d: array of byte): ref Patch;
		apply:	fn(p: self ref Patch, d: array of byte): array of byte;
		applymany:	fn(base: array of byte, patches: array of array of byte): (array of byte, string);
		xapplymany:	fn(base: array of byte, patches: array of array of byte): array of byte;
		sizediff:	fn(h: self ref Patch): int;
		text:	fn(h: self ref Patch): string;
	};
};
