implement HgGet;

include "sys.m";
	sys: Sys;
	sprint: import sys;
include "draw.m";
include "arg.m";
include "string.m";
	str: String;
include "mercurial.m";
	mercurial: Mercurial;
	Revlog, Repo, Nodeid, Change: import mercurial;

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
	mercurial = load Mercurial Mercurial->PATH;
	mercurial->init();

	revision := -1;
	hgpath := "";

	arg->init(args);
	arg->setusage(arg->progname()+" [-dv] [-r rev] [-h path]");
	while((c := arg->opt()) != 0)
		case c {
		'd' =>	dflag++;
			if(dflag > 1)
				mercurial->debug++;
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
		sys->print("%s\n", change.text());
		sys->print("manifest:\n");
		for(l := manifest.files; l != nil; l = tl l) {
			file := hd l;
			sys->print("%s %q\n", file.nodeid.text(), file.path);
		}
		sys->print("\n");
	}

	for(l := manifest.files; l != nil; l = tl l) {
		file := hd l;
		say(sprint("reading file %q, nodeid %s", file.path, file.nodeid.text()));
		(data, derr) := repo.readfile(file.path, file.nodeid);
		if(derr != nil)
			fail(derr);
		say("file read...");
		sys->print("%s, %q: %d bytes\n", file.nodeid.text(), file.path, len data);

		(fd, err) := createfile(file.path);
		if(fd == nil)
			fail(sprint("creating %q: %s", file.path, err));
		if(sys->write(fd, data, len data) != len data)
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
