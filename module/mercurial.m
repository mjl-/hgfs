Mercurial: module
{
	PATH:	con "/dis/lib/mercurial.dis";
	init:	fn();

	debug:	int;
	nullnode:	con "0000000000000000000000000000000000000000";

	checknodeid:	fn(n: string): string;
	createnodeid:	fn(d: array of byte, n1, n2: string): (string, string);
	unhex:		fn(n: string): array of byte;
	hex:		fn(d: array of byte): string;
	differs:	fn(r: ref Repo, size: big, mtime: int, mf: ref Manifestfile): int;

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

		parse:	fn(data: array of byte, e: ref Entry): (ref Change, string);
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
		files:	list of ref Manifestfile;

		parse:	fn(data: array of byte, n: string): (ref Manifest, string);
		find:	fn(m: self ref Manifest, path: string): ref Manifestfile;
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
	};

	workdirstate:	fn(path: string): (ref Dirstate, string);


	Tag: adt {
		name:	string;
		n:	string;
		rev:	int;
	};
	parsetags:	fn(r: ref Repo, s: string): (list of ref Tag, string);

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

		parse:	fn(buf: array of byte, index: int): (ref Entry, string);
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
		get:		fn(rl: self ref Revlog, rev: int): (array of byte, string);
		getnodeid:	fn(rl: self ref Revlog, n: string): (array of byte, string);
		lastrev:	fn(rl: self ref Revlog): (int, string);
		find:		fn(rl: self ref Revlog, rev: int): (ref Entry, string);
		findnodeid:	fn(rl: self ref Revlog, n: string): (ref Entry, string);
		delta:		fn(rl: self ref Revlog, prev, rev: int): (array of byte, string);
		pread:		fn(rl: self ref Revlog, rev: int, n: int, off: big): (array of byte, string);
		length:		fn(rl: self ref Revlog, rev: int): (big, string);

		entries:	fn(rl: self ref Revlog): (array of ref Entry, string);
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
		find:		fn(path: string): (ref Repo, string);
		name:		fn(r: self ref Repo): string;
		openrevlog:	fn(r: self ref Repo, path: string): (ref Revlog, string);
		manifest:	fn(r: self ref Repo, rev: int): (ref Change, ref Manifest, string);
		lastrev:	fn(r: self ref Repo): (int, string);
		change:		fn(r: self ref Repo, rev: int): (ref Change, string);
		mtime:		fn(r: self ref Repo, rl: ref Revlog, rev: int): (int, string);
		dirstate:	fn(r: self ref Repo): (ref Dirstate, string);
		writedirstate:	fn(r: self ref Repo, ds: ref Dirstate): string;
		workroot:	fn(r: self ref Repo): string;
		tags:		fn(r: self ref Repo): (list of ref Tag, string);
		revtags:	fn(r: self ref Repo, revstr: string): (list of ref Tag, string);
		branches:	fn(r: self ref Repo): (list of ref Branch, string);
		workbranch:	fn(r: self ref Repo): (string, string);
		writeworkbranch:	fn(r: self ref Repo, b: string): string;
		heads:		fn(r: self ref Repo): (array of ref Entry, string);
		changelog:	fn(r: self ref Repo): (ref Revlog, string);
		manifestlog:	fn(r: self ref Repo): (ref Revlog, string);
		lookup:		fn(r: self ref Repo, rev: string): (int, string, string);
		get:		fn(r: self ref Repo, revstr, path: string): (array of byte, string);

		escape:		fn(r: self ref Repo, path: string): string;
		unescape:	fn(r: self ref Repo, path: string): (string, string);
		storedir:	fn(r: self ref Repo): string;
		isstore:	fn(r: self ref Repo): int;
		isrevlogv1:	fn(r: self ref Repo): int;
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
		apply:	fn(p: self ref Patch, d: array of byte): array of byte;
		applymany:	fn(base: array of byte, patches: array of array of byte): (array of byte, string);
		sizediff:	fn(h: self ref Patch): int;
		text:	fn(h: self ref Patch): string;
	};
};
