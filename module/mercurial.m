Mercurial: module {

	PATH:	con "/dis/lib/mercurial.dis";
	init:	fn();

	debug:	int;

	Nodeid: adt {
		d:	array of byte;

		parse:	fn(s: string): (ref Nodeid, string);
		create:	fn(d: array of byte, n1, n2: ref Nodeid): ref Nodeid;
		text:	fn(n: self ref Nodeid): string;
		cmp:	fn(n1, n2: ref Nodeid): int;
		isnull:	fn(n: self ref Nodeid): int;
	};
	nullnode: ref Nodeid;


	Change: adt {
		rev:	int;
		nodeid:	ref Nodeid;
		p1, p2:	int;
		manifestnodeid:	ref Nodeid;
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
		nodeid:	ref Nodeid;
		flags:	int;
	};

	Manifest: adt {
		nodeid:	ref Nodeid;
		files:	list of ref Manifestfile;

		parse:	fn(data: array of byte, n: ref Nodeid): (ref Manifest, string);
	};


	STnormal, STneedmerge, STremove, STadd, STuntracked: con iota; # Dirstatefile.state
	SZcheck, SZdirty: con iota;
	Dirstatefile: adt {
		state:	int;
		mode:	int;
		size:	int;
		mtime:	int;
		name:	string;
		origname:	string;	# only non-nil in case of copy/move

		text:	fn(f: self ref Dirstatefile): string;
	};

	Dirstate: adt {
		p1, p2:	ref Nodeid;
		l:	list of ref Dirstatefile;
	};

	workdirstate:	fn(path: string): (ref Dirstate, string);


	Tag: adt {
		name:	string;
		n:	ref Nodeid;
		rev:	int;
	};

	Branch: adt {
		name:	string;
		n:	ref Nodeid;
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
		nodeid:	ref Nodeid;

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
		getnodeid:	fn(rl: self ref Revlog, n: ref Nodeid): (array of byte, string);
		lastrev:	fn(rl: self ref Revlog): (int, string);
		find:		fn(rl: self ref Revlog, rev: int): (ref Entry, string);
		findnodeid:	fn(rl: self ref Revlog, nodeid: ref Nodeid): (ref Entry, string);
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
		workroot:	fn(r: self ref Repo): string;
		tags:		fn(r: self ref Repo): (list of ref Tag, string);
		branches:	fn(r: self ref Repo): (list of ref Branch, string);
		heads:		fn(r: self ref Repo): (array of ref Entry, string);
		changelog:	fn(r: self ref Repo): (ref Revlog, string);
		manifestlog:	fn(r: self ref Repo): (ref Revlog, string);
		lookup:		fn(r: self ref Repo, rev: string): (int, ref Nodeid, string);

		escape:		fn(r: self ref Repo, path: string): string;
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
