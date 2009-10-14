implement HgRemove;

include "sys.m";
	sys: Sys;
	sprint: import sys;
include "draw.m";
include "arg.m";
include "bufio.m";
include "readdir.m";
	readdir: Readdir;
include "string.m";
	str: String;
include "tables.m";
	tables: Tables;
	Strhash: import tables;
include "mercurial.m";
	hg: Mercurial;
	Dirstate, Dirstatefile, Revlog, Repo, Change, Manifest, Manifestfile, Entry: import hg;
include "util0.m";
	util: Util0;
	rev, readfile, l2a, inssort, warn, fail: import util;

HgRemove: module {
	init:	fn(nil: ref Draw->Context, args: list of string);
};


dflag: int;
fflag: int;
repo: ref Repo;
hgpath := "";

init(nil: ref Draw->Context, args: list of string)
{
	sys = load Sys Sys->PATH;
	arg := load Arg Arg->PATH;
	readdir = load Readdir Readdir->PATH;
	str = load String String->PATH;
	tables = load Tables Tables->PATH;
	util = load Util0 Util0->PATH;
	util->init();
	hg = load Mercurial Mercurial->PATH;
	hg->init();

	arg->init(args);
	arg->setusage(arg->progname()+" [-d] [-h path] [-f] path ...");
	while((c := arg->opt()) != 0)
		case c {
		'd' =>	hg->debug = dflag++;
		'h' =>	hgpath = arg->earg();
		'f' =>	fflag++;
		* =>	arg->usage();
		}
	args = arg->argv();
	if(args == nil)
		arg->usage();

	{ init0(args); }
	exception e {
	"hg:*" =>
		fail(e[3:]);
	}
}

dirty: int;
init0(args: list of string)
{
	repo = Repo.xfind(hgpath);

	ds := repo.xdirstate();
	if(ds.p2 != hg->nullnode)
		error("checkout has two parents, is in merge, refusing to update");
	# xxx make sure dirstate is complete & correct

	root := repo.workroot();

	dirty = 0;
	base := repo.xworkdir();
	say(sprint("base %q", base));
	pathtab := Strhash[string].new(31, nil);
	for(l := args; l != nil; l = tl l) {
		path := hg->xsanitize(base+"/"+hd l);
		if(path == ".")
			path = "";
		ll := ds.findall(path);
		if(ll == nil) {
			warn(sprint("%q: file not found", path));
			continue;
		}
		for(; ll != nil; ll = tl ll) {
			dsf := hd ll;
			p := dsf.path;
			if(pathtab.find(p) != nil)
				continue;
			pathtab.add(p, p);

			# xxx need case for modified, missing?
			case dsf.state {
			hg->STnormal =>
				dsf.state = hg->STremove;
				dirty++;
				if(sys->remove(hg->xsanitize(root+"/"+p)) != 0)
					warn(sprint("removing %q: %r", p));
			hg->STneedmerge =>
				if(fflag) {
					dsf.state = hg->STremove;
					dirty++;
				} else
					warn(sprint("%q: file marked as needmerge, ignoring", p));
			hg->STremove =>
				;
			hg->STadd =>
				if(fflag) {
					dsf.state = hg->STremove;
					dirty++;
				} else
					warn(sprint("%q: file marked for add, ignoring", p));
			hg->STuntracked =>
				warn(sprint("%q: file not tracked, leaving as it is", p));
			* =>
				error(sprint("missing case for dirstate file state %d", dsf.state));
			}
		}
	}

	if(dirty)
		repo.xwritedirstate(ds);
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
