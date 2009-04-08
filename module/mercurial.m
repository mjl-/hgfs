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
	};

	Change: adt {
		rev:	int;
		nodeid:	ref Nodeid;
		p1, p2:	int;
		manifestnodeid:	ref Nodeid;
		who:	string;
		when, tzoff:	int;
		files:	list of string;
		msg:	string;

		parse:	fn(data: array of byte, e: ref Entry): (ref Change, string);
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
	Indexonly: con 1<<iota;

	Revlog: adt {
		path:	string;
		ifd, dfd:	ref Sys->FD;
		version, flags: int;
		nodeidcache:	array of ref Nodeid;
		entrycache:	array of ref Entry;  # only when Indexonly
		icacheoff:	big;  # offset in .i-file where uncached entries start

		open:	fn(path: string): (ref Revlog, string);
		isindexonly:	fn(rl: self ref Revlog): int;
		get:	fn(rl: self ref Revlog, rev: int, nodeid: ref Nodeid): (array of byte, ref Entry, string);
		getrev:	fn(rl: self ref Revlog, rev: int): (array of byte, string);
		getnodeid:	fn(rl: self ref Revlog, nodeid: ref Nodeid): (array of byte, string);
		lastrev:	fn(rl: self ref Revlog): (int, string);
		find:	fn(rl: self ref Revlog, rev: int, nodeid: ref Nodeid): (ref Entry, string);
		findnodeid:	fn(rl: self ref Revlog, nodeid: ref Nodeid): (ref Entry, string);
		findrev:	fn(rl: self ref Revlog, rev: int): (ref Entry, string);
		filelength:	fn(rl: self ref Revlog, nodeid: ref Nodeid): (big, string);
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

	Repo: adt {
		path:	string;
		requires:	list of string;
		reponame: 	string;
		lastrevision:	int;
		lastmtime:	int;

		open:		fn(path: string): (ref Repo, string);
		find:		fn(path: string): (ref Repo, string);
		name:		fn(r: self ref Repo): string;
		isstore:	fn(r: self ref Repo): int;
		isrevlogv1:	fn(r: self ref Repo): int;
		escape:	fn(r: self ref Repo, path: string): string;
		storedir:	fn(r: self ref Repo): string;
		openrevlog:	fn(r: self ref Repo, path: string): (ref Revlog, string);
		manifest:	fn(r: self ref Repo, rev: int): (ref Change, ref Manifest, string);
		readfile:	fn(r: self ref Repo, path: string, n: ref Nodeid): (array of byte, string);
		lastrev:	fn(r: self ref Repo): (int, string);
		change:		fn(r: self ref Repo, rev: int): (ref Change, string);
		filelength:	fn(r: self ref Repo, path: string, n: ref Nodeid): (big, string);
		filemtime:	fn(r: self ref Repo, path: string, n: ref Nodeid): (int, string);
		dirstate:	fn(r: self ref Repo): (ref Dirstate, string);
		workroot:	fn(r: self ref Repo): string;
		tags:		fn(r: self ref Repo): (list of ref Tag, string);
		branches:	fn(r: self ref Repo): (list of ref Branch, string);
	};
};
