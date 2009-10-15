implement HgVerify;

include "sys.m";
	sys: Sys;
	sprint: import sys;
include "draw.m";
include "arg.m";
include "bufio.m";
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
	readfile, l2a, inssort, warn, fail: import util;

HgVerify: module {
	init:	fn(nil: ref Draw->Context, args: list of string);
};


dflag: int;
repo: ref Repo;
hgpath := "";

init(nil: ref Draw->Context, args: list of string)
{
	sys = load Sys Sys->PATH;
	arg := load Arg Arg->PATH;
	str = load String String->PATH;
	tables = load Tables Tables->PATH;
	util = load Util0 Util0->PATH;
	util->init();
	hg = load Mercurial Mercurial->PATH;
	hg->init();

	arg->init(args);
	arg->setusage(arg->progname()+" [-d] [-h path]");
	while((c := arg->opt()) != 0)
		case c {
		'd' =>	hg->debug = dflag++;
		'h' =>	hgpath = arg->earg();
		* =>	arg->usage();
		}
	args = arg->argv();
	if(len args != 0)
		arg->usage();

	{ init0(); }
	exception e {
	"hg:*" =>
		fail(e[3:]);
	}
}

init0()
{
	repo = Repo.xfind(hgpath);

	cl := repo.xchangelog();
	nrevs := len cl.xentries();
	say("verifying changelog");
	cl.xverify();
	say("verifying manifest");
	ml := repo.xmanifestlog();
	ml.xverify();

	files: ref Strhash[ref Strhash[string]];
	files = files.new(31, nil);

	for(i := 0; i < nrevs; i++) {
		(nil, m) := repo.xmanifest(i);
		for(j := 0; j < len m.files; j++) {
			mf := m.files[j];
			ntab := files.find(mf.path);
			if(ntab == nil) {
				ntab = Strhash[string].new(31, nil);
				files.add(mf.path, ntab);
			}
			if(ntab.find(mf.nodeid) == nil)
				ntab.add(mf.nodeid, mf.nodeid);
		}
	}

	for(i = 0; i < len files.items; i++) {
		for(l := files.items[i]; l != nil; l = tl l) {
			(path, tab) := hd l;
			say(sprint("inspecting %q", path));
			rl := repo.xopenrevlog(path);
			rl.xverify();
			for(j := 0; j < len tab.items; j++) {
				for(ll := tab.items[j]; ll != nil; ll = tl ll) {
					(n, nil) := hd ll;
					say(sprint("nodeid %q", n));
					rl.xfindnodeid(n, 1);
				}
			}
		}
	}
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
