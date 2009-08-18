implement HgGet;

include "sys.m";
	sys: Sys;
	sprint: import sys;
include "draw.m";
include "arg.m";
include "bufio.m";
include "string.m";
	str: String;
include "mercurial.m";
	hg: Mercurial;
	Revlog, Repo, Change: import hg;

dflag: int;
vflag: int;

HgGet: module {
	init:	fn(nil: ref Draw->Context, args: list of string);
};

init(nil: ref Draw->Context, args: list of string)
{
	sys = load Sys Sys->PATH;
	arg := load Arg Arg->PATH;
	str = load String String->PATH;
	hg = load Mercurial Mercurial->PATH;
	hg->init();

	revision := -1;
	hgpath := "";

	arg->init(args);
	arg->setusage(arg->progname()+" [-dv] [-r rev] [-h path]");
	while((c := arg->opt()) != 0)
		case c {
		'd' =>	dflag++;
			if(dflag > 1)
				hg->debug++;
		'v' =>	vflag++;
		'r' =>	revision = int arg->earg();
		'h' =>	hgpath = arg->earg();
		* =>	arg->usage();
		}
	args = arg->argv();
	if(len args != 0)
		arg->usage();

	(repo, rerr) := Repo.find(hgpath);
	if(rerr != nil)
		fail(rerr);
	say("found repo");

	(change, manifest, merr) := repo.manifest(revision);
	if(merr != nil)
		fail(merr);
	say("have change & manifest");

	if(vflag) {
		warn(sprint("%s\n", change.text()));
		warn(sprint("manifest:\n"));
		for(l := manifest.files; l != nil; l = tl l) {
			file := hd l;
			warn(sprint("%q %q\n", file.nodeid, file.path));
		}
		warn("\n");
	}

	for(l := manifest.files; l != nil; l = tl l) {
		file := hd l;
		say(sprint("reading file %q, nodeid %q", file.path, file.nodeid));
		(rl, rlerr) := repo.openrevlog(file.path);
		if(rlerr != nil)
			fail(rlerr);
		(d, derr) := rl.getnodeid(file.nodeid);
		if(derr != nil)
			fail(derr);
		say("file read...");
		warn(sprint("%q, %q: %d bytes\n", file.nodeid, file.path, len d));

		(fd, err) := createfile(file.path);
		if(fd == nil)
			fail(sprint("creating %q: %s", file.path, err));
		if(sys->write(fd, d, len d) != len d)
			fail(sprint("writing: %r"));
	}
}

createdirs(dirs: string): string
{
	path := "";
	for(l := sys->tokenize(dirs, "/").t1; l != nil; l = tl l) {
		path += "/"+hd l;
		say("createdirs, "+path[1:]);
		sys->create(path[1:], Sys->OREAD, 8r777|Sys->DMDIR);
	}
	return nil;
}

createfile(path: string): (ref Sys->FD, string)
{
	(dir, nil) := str->splitstrr(path, "/");
	if(dir != nil) {
		err := createdirs(dir);
		if(err != nil)
			return (nil, err);
	}

	say("create, "+path);
	fd := sys->create(path, Sys->OWRITE, 8r666);
	if(fd == nil)
		return (nil, sprint("create %q: %r", path));
	return (fd, nil);
}

say(s: string)
{
	if(dflag)
		warn(s);
}

warn(s: string)
{
	sys->fprint(sys->fildes(2), "%s\n", s);
}

fail(s: string)
{
	warn(s);
	raise "fail:"+s;
}
