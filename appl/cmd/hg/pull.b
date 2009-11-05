implement HgPull;

include "sys.m";
	sys: Sys;
	sprint: import sys;
include "draw.m";
include "arg.m";
include "bufio.m";
	bufio: Bufio;
	Iobuf: import bufio;
include "filter.m";
	inflate: Filter;
	deflate: Filter;
include "filtertool.m";
	filtertool: Filtertool;
include "string.m";
	str: String;
include "tables.m";
	tables: Tables;
	Strhash: import tables;
include "util0.m";
	util: Util0;
	max, g32i, hex, hasstr, rev, join, prefix, suffix, readfd, l2a, inssort, warn, fail: import util;
include "../../lib/bdiff.m";
include "mercurial.m";
	hg: Mercurial;
	Dirstate, Dsfile, Revlog, Repo, Change, Manifest, Mfile, Entry, Configs: import hg;
include "mhttp.m";
include "../../lib/mercurialremote.m";
	hgrem: Mercurialremote;
	Remrepo: import hgrem;

HgPull: module {
	init:	fn(nil: ref Draw->Context, args: list of string);
};


dflag: int;
fflag: int;
repo: ref Repo;
hgpath := "";
revstr: string;
source: string;

init(nil: ref Draw->Context, args: list of string)
{
	sys = load Sys Sys->PATH;
	arg := load Arg Arg->PATH;
	bufio = load Bufio Bufio->PATH;
	bufio->open("/dev/null", Bufio->OREAD);
	inflate = load Filter Filter->INFLATEPATH;
	inflate->init();
	deflate = load Filter Filter->DEFLATEPATH;
	deflate->init();
	filtertool = load Filtertool Filtertool->PATH;
	str = load String String->PATH;
	tables = load Tables Tables->PATH;
	util = load Util0 Util0->PATH;
	util->init();
	hg = load Mercurial Mercurial->PATH;
	hg->init(0);
	hgrem = load Mercurialremote Mercurialremote->PATH;
	hgrem->init();

	arg->init(args);
	arg->setusage(arg->progname()+" [-d] [-h path] [-f] [-r rev] [source]");
	while((c := arg->opt()) != 0)
		case c {
		'd' =>	hg->debug = hgrem->dflag = dflag++;
		'h' =>	hgpath = arg->earg();
		'f' =>	fflag++;
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
	warn(sprint("pulling from %q", source));

	warn("searching for changes");
	remrepo := Remrepo.xnew(repo, source);
	newheads: list of string;
	if(revstr != nil)
		heads := remrepo.xlookup(revstr)::nil;
	else
		heads = remrepo.xheads();
	for(; heads != nil; heads = tl heads) {
		say(sprint("looking up remote head %s in local repo", fmtnode(hd heads)));
		if(!isknown(hd heads))
			newheads = hd heads::newheads;
	}
	if(newheads == nil)
		return warn("no changes found");

	say("newheads: "+fmtnodelist(newheads));

	nodes := newheads;
	betweens: list of ref (string, string);
	cgbases: list of string;
	while(nodes != nil) {
		newnodes: list of string;
		for(l := remrepo.xbranches(nodes); l != nil; l = tl l) {
			(tip, base, p1, p2) := *hd l;
			say(sprint("looking at branches result"));
			say(sprint("\ttip  %s", tip));
			say(sprint("\tbase %s", base));
			say(sprint("\tp1   %s", p1));
			say(sprint("\tp2   %s", p2));
			if(isknown(base)) {
				say(sprint("base known, scheduling for between"));
				betweens = ref (tip, base)::betweens;
			} else if(p1 == hg->nullnode) {
				if(repo.xlastrev() >= 0 && !fflag)
					error(sprint("refusing to pull from unrelated repository without -f"));
				if(!hasstr(cgbases, p1))
					cgbases = p1::cgbases;
			} else {
				say(sprint("base is unknown, will be asking for %s and %s in next round", fmtnode(p1), fmtnode(p2)));
				if(!hasstr(newnodes, p1))
					newnodes = p1::newnodes;
				if(!hasstr(newnodes, p2))
					newnodes = p2::newnodes;
			}
		}
		nodes = newnodes;
		say("end of branches round, new nodes: "+fmtnodelist(nodes));
	}

	say("after branches, before betweens:");
	say("cgbase: "+fmtnodelist(cgbases));
	say("betweens:");
	for(l := betweens; l != nil; l = tl l)
		say(sprint("\ttip %s base %s", fmtnode((hd l).t0), fmtnode((hd l).t1)));

	while(betweens != nil) {
		newbetweens: list of ref (string, string);
		ll := remrepo.xbetween(betweens);
		if(len ll != len betweens)
			error("wrong number of response lines to 'between'");
		for(; ll != nil; ll = tl ll) {
			(tip, base) := *hd betweens;
			betweens = tl betweens;

			nn := array[1+len hd ll+1] of string;
			nn[0] = tip;
			nn[1:] = l2a(hd ll);
			nn[len nn-1] = base;
			(high, low) := findbetween(nn);
			if(high != low) {
				newbetweens = ref (high, low)::newbetweens;
			} else {
				if(!hasstr(cgbases, high))
					cgbases = high::cgbases;
			}
		}
		betweens = newbetweens;
	}

	caps := remrepo.xcapabilities();
	if(!hasstr(caps, "changegroupsubset"))
		error("changegroupsubset not supported by server, changegroup not supported yet, aborting");

	say(sprint("changegroupsubset, bases %s;  heads %s", fmtnodelist(cgbases), fmtnodelist(newheads)));
	fd := remrepo.xchangegroupsubset(cgbases, newheads);

	if(remrepo.iscompressed()) {
		err: string;
		(fd, err) = filtertool->push(inflate, "z", fd, 0);
		if(err != nil)
			error(err);
	}
	b := bufio->fopen(fd, Bufio->OREAD);
	if(b == nil)
		error("fopen");

	hg->xstreamin(repo, b);
}

isknown(n: string): int
{
	return repo.xlookup(n, 0).t0 >= 0;
}

# first in nodes[] is tip, last in nodes[] base
# in between are the indexes 1,2,4,8 etc
# if we know about nodes[1] we are looking for nodes[0]
# if we know about nodes[2] we are looking for nodes[1]
# otherwise we have to refine our search, between the last known node and the one before it
findbetween(nodes: array of string): (string, string)
{
	if(isknown(nodes[1]))
		return (nodes[0], nodes[0]);
	if(isknown(nodes[2]))
		return (nodes[1], nodes[1]);

	for(i := len nodes-1-1; i >= 0; i--)
		if(!isknown(nodes[i]))
			break;
	return (nodes[i], nodes[i+1]);
}

fmtnodelist(l: list of string): string
{
	s := "";	
	for(; l != nil; l = tl l)
		s += " "+fmtnode(hd l);
	if(s != nil)
		s = s[1:];
	return s;
}

fmtnode(s: string): string
{
	return s[:12];
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
