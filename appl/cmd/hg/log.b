implement HgLog;

include "sys.m";
	sys: Sys;
	sprint: import sys;
include "draw.m";
include "arg.m";
include "bufio.m";
include "util0.m";
	util: Util0;
	max, fail, warn: import util;
include "tables.m";
include "../../lib/bdiff.m";
include "mercurial.m";
	hg: Mercurial;
	Revlog, Repo, Change, Manifest, Entry: import hg;

HgLog: module {
	init:	fn(nil: ref Draw->Context, args: list of string);
};


dflag: int;
hgpath := "";
vflag: int;
revstr := "";

init(nil: ref Draw->Context, args: list of string)
{
	sys = load Sys Sys->PATH;
	arg := load Arg Arg->PATH;
	util = load Util0 Util0->PATH;
	util->init();
	hg = load Mercurial Mercurial->PATH;
	hg->init(0);

	arg->init(args);
	arg->setusage(arg->progname()+" [-d] [-h path] [-v] [-r rev] [file ...]");
	while((c := arg->opt()) != 0)
		case c {
		'd' =>	hg->debug = dflag++;
		'h' =>	hgpath = arg->earg();
		'v' =>	vflag++;
		'r' =>	revstr = arg->earg();
		* =>	arg->usage();
		}
	args = arg->argv();

	{ init0(args); }
	exception e {
	"hg:*" =>
		fail(e[3:]);
	}
}

init0(args: list of string)
{
	repo := Repo.xfind(hgpath);
	root := repo.workroot();
	base := repo.xworkdir();

	if(args != nil) {
		untracked := 0;
		args = hg->xpathseval(root, base, args, untracked);
	}

	if(revstr != nil) {
		(rev, n) := repo.xlookup(revstr, 1);
		if(!match(args, repo, rev))
			return;
		sys->print("%s\n", hg->xentrylogtext(repo, n, vflag));
		return;
	}

	ents := repo.xchangelog().xentries();
	for(i := len ents-1; i >= 0; i--) {
		if(!match(args, repo, ents[i].rev))
			continue;
		sys->print("%s\n", hg->xentrylogtext(repo, ents[i].nodeid, vflag));
	}

}

match(l: list of string, r: ref Repo, rev: int): int
{
	if(l == nil)
		return 1;

	c := r.xchange(rev);
	for(; l != nil; l = tl l)
		if(c.hasfile(hd l))
			return 1;
	return 0;
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
