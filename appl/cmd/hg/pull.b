implement HgPull;

include "sys.m";
	sys: Sys;
	sprint: import sys;
include "draw.m";
include "arg.m";
include "bufio.m";
	bufio: Bufio;
include "string.m";
	str: String;
include "tables.m";
	tables: Tables;
	Strhash: import tables;
include "util0.m";
	util: Util0;
	hasstr, rev, join, prefix, suffix, readfd, l2a, inssort, warn, fail: import util;
include "mercurial.m";
	hg: Mercurial;
	Dirstate, Dirstatefile, Revlog, Repo, Change, Manifest, Manifestfile, Entry, Configs: import hg;
include "mhttp.m";
include "../../lib/mercurialremote.m";
	hgrem: Mercurialremote;
	Remrepo: import hgrem;

HgPull: module {
	init:	fn(nil: ref Draw->Context, args: list of string);
};


dflag: int;
Cflag: int;
repo: ref Repo;
hgpath := "";
revstr := "tip";
source: string;

init(nil: ref Draw->Context, args: list of string)
{
	sys = load Sys Sys->PATH;
	arg := load Arg Arg->PATH;
	bufio = load Bufio Bufio->PATH;
	bufio->open("/dev/null", Bufio->OREAD);
	str = load String String->PATH;
	tables = load Tables Tables->PATH;
	util = load Util0 Util0->PATH;
	util->init();
	hg = load Mercurial Mercurial->PATH;
	hg->init();
	hgrem = load Mercurialremote Mercurialremote->PATH;
	hgrem->init();

	arg->init(args);
	arg->setusage(arg->progname()+" [-d] [-h path] [-r rev] [source]");
	while((c := arg->opt()) != 0)
		case c {
		'd' =>	hg->debug = dflag++;
		'C' =>	Cflag++;
		'h' =>	hgpath = arg->earg();
		'r' =>	revstr = arg->earg();
		* =>	arg->usage();
		}
	args = arg->argv();
	if(len args > 1)
		arg->usage();
	if(len args == 1)
		source = hd args;

	{ init0(); }
	exception e {
	"hg:*" =>
		fail(e[3:]);
	}
}

init0()
{
	repo = Repo.xfind(hgpath);
	c := hg->xreadconfigs(repo);
	if(source == nil) {
		source = c.get("paths", "default");
		if(source == nil)
			fail("no default path to pull from");
	}
	say(sprint("pulling from %q", source));

	warn("searching for changes");
	remrepo := Remrepo.xnew(repo, source);

	warn("lookup tip: "+remrepo.xlookup("tip"));
	warn("capabilities: "+join(remrepo.xcapabilities(), ", "));
	bl := remrepo.xbranches(list of {"e588cf1024ba514d460f71d36969410afa7336b4"});
	for(; bl != nil; bl = tl bl) {
		(tip, base, p1, p2) := *hd bl;
		warn(sprint("branch: tip=%s base=%s p1=%s p2=%s", tip, base, p1, p2));
	}

	btl := remrepo.xbetween(list of {ref ("e588cf1024ba514d460f71d36969410afa7336b4", "e550a19f3f399f038268cfc6278c1f510fcb4aac")});
	for(; btl != nil; btl = tl btl)
		warn("between: "+join(hd btl, ", "));

	heads := remrepo.xheads();
	for(l := heads; l != nil; l = tl l)
		warn(sprint("head %q", hd l));

	cl := repo.xchangelog();
	ents := cl.xentries();
	newheads: list of string;
	for(l = heads; l != nil; l = tl l) {
		i := findentry(ents, hd l);
		if(i < 0)
			newheads = hd l::newheads;
	}
	if(newheads == nil) {
		warn("no changes found");
		return;
	}
	say(sprint("new heads %s", join(newheads, ",")));

}

findentry(ents: array of ref Entry, n: string): int
{
	for(i := 0; i < len ents; i++)
		if(ents[i].nodeid == n)
			return i;
	return -1;
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
