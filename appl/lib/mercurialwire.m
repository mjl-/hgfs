Mercurialwire: module 
{
	PATH:	con "/dis/lib/mercurialwire.dis";

	dflag:	int;
	init:	fn();

	heads:		fn(r: ref Mercurial->Repo): (string, string);
	branches:	fn(r: ref Mercurial->Repo, nodes: string): (string, string);
	between:	fn(r: ref Mercurial->Repo, pairs: string): (string, string);
	lookup:		fn(r: ref Mercurial->Repo, key: string): (string, string);
	changegroup:	fn(r: ref Mercurial->Repo, roots: string): (ref Sys->FD, string);
	changegroupsubset:	fn(r: ref Mercurial->Repo, bases, heads: string): (ref Sys->FD, string);
};
