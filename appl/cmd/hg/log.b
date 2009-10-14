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
	hg->init();

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

	rev := -1;
	if(revstr != nil) {
		n: string;
		(rev, n) = repo.xlookup(revstr, 1);
	}
	ents := repo.xchangelog().xentries();

	for(i := len ents-1; i >= 0; i--) {
		if(rev >= 0 && ents[i].rev != rev)
			continue;

		if(args != nil && !filechanged(repo, ents[i], args))
			continue;
		sys->print("%s\n", hg->xentrylogtext(repo, ents, ents[i], vflag));
	}

}

filechanged(r: ref Repo, e: ref Entry, args: list of string): int
{
	c := r.xchange(e.rev);
	for(l := args; l != nil; l = tl l)
		for(ll := c.files; ll != nil; ll = tl ll)
			if(hd ll == hd l)
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
