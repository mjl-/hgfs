implement HgGet;

include "sys.m";
	sys: Sys;
	sprint: import sys;
include "draw.m";
include "arg.m";
include "bufio.m";
include "string.m";
	str: String;
include "tables.m";
include "../../lib/bdiff.m";
include "mercurial.m";
	hg: Mercurial;
	Revlog, Repo, Change: import hg;

HgGet: module {
	init:	fn(nil: ref Draw->Context, args: list of string);
};


dflag: int;
vflag: int;
revision := -1;
hgpath := "";

init(nil: ref Draw->Context, args: list of string)
{
	sys = load Sys Sys->PATH;
	arg := load Arg Arg->PATH;
	str = load String String->PATH;
	hg = load Mercurial Mercurial->PATH;
	hg->init(0);

	arg->init(args);
	arg->setusage(arg->progname()+" [-d] [-h path] [-v] [-r rev]");
	while((c := arg->opt()) != 0)
		case c {
		'd' =>	hg->debug = dflag++;
		'h' =>	hgpath = arg->earg();
		'v' =>	vflag++;
		'r' =>	revision = int arg->earg();
		* =>	arg->usage();
		}
	args = arg->argv();
	if(len args != 0)
		arg->usage();

	{ init0();
	} exception e {
	"hg:*" =>
		fail(e[3:]);
	}
}

init0()
{
	repo := Repo.xfind(hgpath);
	say("found repo");
	(c, m) := repo.xrevision(revision);
	say("have change & manifest");

	if(vflag) {
		warn(sprint("%s\n", c.text()));
		warn(sprint("manifest:\n"));
		for(i := 0; i < len m.files; i++) {
			file := m.files[i];
			warn(sprint("%q %q\n", file.nodeid, file.path));
		}
		warn("\n");
	}

	for(i := 0; i < len m.files; i++) {
		file := m.files[i];
		say(sprint("reading file %q, nodeid %q", file.path, file.nodeid));
		rl := repo.xopenrevlog(file.path);
		d := rl.xgetn(file.nodeid);
		say("file read...");
		warn(sprint("%q, %q: %d bytes\n", file.nodeid, file.path, len d));

		fd := xcreatefile(file.path);
		if(sys->write(fd, d, len d) != len d)
			error(sprint("writing: %r"));
	}
}

xcreatedirs(dirs: string)
{
	path := "";
	for(l := sys->tokenize(dirs, "/").t1; l != nil; l = tl l) {
		path += "/"+hd l;
		say("createdirs, "+path[1:]);
		sys->create(path[1:], Sys->OREAD, 8r777|Sys->DMDIR);
	}
}

xcreatefile(path: string): ref Sys->FD
{
	(dir, nil) := str->splitstrr(path, "/");
	if(dir != nil)
		xcreatedirs(dir);

	say("create, "+path);
	fd := sys->create(path, Sys->OWRITE, 8r666);
	if(fd == nil)
		error(sprint("create %q: %r", path));
	return fd;
}

error(s: string)
{
	raise "hg:"+s;
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
