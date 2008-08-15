Mercurial: module {

	PATH:	con "/dis/lib/mercurial.dis";
	init:	fn();

	debug:	int;

	Nodeid: adt {
		d:	array of byte;

		text:	fn(n: self ref Nodeid): string;
		cmp:	fn(n1, n2: ref Nodeid): int;
	};

	Change: adt {
		manifestnodeid:	ref Nodeid;
		who:	string;
		when, tzoff:	int;
		files:	list of string;
		msg:	string;

		parse:	fn(data: array of byte): (ref Change, string);
		text:	fn(c: self ref Change): string;
	};

	Manifestfile: adt {
		path:	string;
		mode:	int;
		nodeid:	ref Nodeid;
	};

	Manifest: adt {
		files:	list of ref Manifestfile;

		parse:	fn(data: array of byte): (ref Manifest, string);
	};

	Entry: adt {
		rev:	int;
		offset:	big;
		ioffset:	big;  # when .d is not present, offset has value as if it were.  ioffset is compensated for that, and points to real data offset in .i file
		flags:	int;
		csize:	int;
		uncsize:	int;
		base, link, p1, p2:     int;
		nodeid:	ref Nodeid;

		parse:	fn(buf: array of byte): (ref Entry, string);
		text:	fn(e: self ref Entry): string;
	};

	Revlog: adt {
		path:	string;
		fd:	ref Sys->FD;
		flags:	int;  # todo
		nodes:	list of (int, ref Nodeid);

		open:	fn(path: string): (ref Revlog, string);
		isindexonly:	fn(rl: self ref Revlog): int;
		findrev:	fn(rl: self ref Revlog, rev: int): (ref Entry, string);
		findnodeid:	fn(rl: self ref Revlog, n: ref Nodeid): (ref Entry, string);
		getentry:	fn(rl: self ref Revlog, e: ref Entry): (array of byte, string);
		getfile:	fn(rl: self ref Revlog, e: ref Entry): (array of byte, string);
		getrev:	fn(rl: self ref Revlog, rev: int): (ref Entry, array of byte, string);
		getnodeid:	fn(rl: self ref Revlog, n: ref Nodeid): (ref Entry, array of byte, string);
	};

	Repo: adt {
		path:	string;
		requires:	list of string;

		open:		fn(path: string): (ref Repo, string);
		find:		fn(path: string): (ref Repo, string);
		isstore:	fn(r: self ref Repo): int;
		isrevlogv1:	fn(r: self ref Repo): int;
		escape:	fn(r: self ref Repo, path: string): string;
		storedir:	fn(r: self ref Repo): string;
		openrevlog:	fn(r: self ref Repo, path: string): (ref Revlog, string);
		manifest:	fn(r: self ref Repo, rev: int): (ref Change, ref Manifest, string);
		readfile:	fn(r: self ref Repo, path: string, nodeid: ref Nodeid): (array of byte, string);
	};
};
