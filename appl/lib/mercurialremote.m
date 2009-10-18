Mercurialremote: module
{
	PATH:	con "/dis/lib/mercurialremote.dis";
	init:	fn();
	dflag:	int;

	Remrepo: adt {
		r:	ref Repo;
		path:	string;
		pick {
		Http =>
			url:	ref Http->Url;
		Ssh =>
			user,
			host,
			port,
			dir:	string;
			tossh,
			fromssh:ref Sys->FD;
			b:	ref Bufio->Iobuf;
		}

		xnew:		fn(r: ref Repo, path: string): ref Remrepo;
		xname:		fn(rr: self ref Remrepo): string;
		xlookup:	fn(rr: self ref Remrepo, revstr: string): string;
		xheads:		fn(rr: self ref Remrepo): list of string;
		xcapabilities:	fn(rr: self ref Remrepo): list of string;
		xbranches:	fn(rr: self ref Remrepo, nodes: list of string): list of ref (string, string, string, string);
		xbetween:	fn(rr: self ref Remrepo, pairs: list of ref (string, string)): list of list of string;
		xchangegroup:	fn(rr: self ref Remrepo, roots: list of string): ref Sys->FD;
		xchangegroupsubset:	fn(rr: self ref Remrepo, bases, heads: list of string): ref Sys->FD;
		iscompressed:	fn(rr: self ref Remrepo): int;
	};
};
