implement HgLog;

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

HgLog: module {
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
	showcount := -1;

	arg->init(args);
	arg->setusage(arg->progname()+" [-dv] [-r rev] [-n count] [-h path]");
	while((c := arg->opt()) != 0)
		case c {
		'd' =>	dflag++;
			if(dflag > 1)
				mercurial->debug++;
		'v' =>	vflag++;
		'r' =>	revision = int arg->earg();
		'h' =>	hgpath = arg->earg();
		'n' =>	showcount = int arg->earg();
		* =>	arg->usage();
		}
	args = arg->argv();
	if(len args != 0)
		arg->usage();

	(repo, rerr) := Repo.find(hgpath);
	if(rerr != nil)
		fail(rerr);
	say("found repo");

	if(revision == -1) {
		err: string;
		(revision, err) = repo.lastrev();
		if(err != nil)
			fail("look for last revision: "+err);
	}

	if(showcount == -1)
		showcount = revision+1;
	last := revision-showcount+1;
	first := 1;
	for(r := revision; r >= last; r--) {
		(change, cerr) := repo.change(r);
		if(cerr != nil)
			fail("reading change: "+cerr);

		if(first)
			first = 0;
		else
			sys->print("\n");
			
		sys->print("## revision %d\n", r);
		sys->print("%s\n", change.text());
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
