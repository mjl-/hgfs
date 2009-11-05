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
include "../../lib/bdiff.m";
include "mercurial.m";
	hg: Mercurial;
	Dirstate, Dsfile, Revlog, Repo, Change, Manifest, Mfile, Entry: import hg;
include "util0.m";
	util: Util0;
	rev, join, max, readfile, l2a, inssort, warn, fail: import util;

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
	hg->init(0);

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

	Missing: con -2;

	cl := repo.xchangelog();
	cents := cl.xentries();
	say(sprint("verifying changelog, %d entries", len cents));
	mneed := Tab.new(max(1, len cents/4), Missing);
	cseen := Strhash[string].new(max(1, len cents/4), nil);
	for(i := 0; i < len cents; i++) {
		e := cents[i];
		if(cseen.find(e.nodeid) != nil)
			error(sprint("duplicate changelog nodeid %s, second at rev %d", e.nodeid, e.rev));
		cseen.add(e.nodeid, e.nodeid);

		cbuf := cl.xget(i);
		c := Change.xparse(cbuf, e);
		if(mneed.find(c.manifestnodeid) == Missing)
			mneed.add(c.manifestnodeid, e.rev);
	}
	cseen = nil;

	ml := repo.xmanifestlog();
	ments := ml.xentries();
	say(sprint("verifying manifest, %d entries", len ments));
	mseen := Strhash[string].new(max(1, len cents/4), nil);
	needpaths: ref Strhash[ref Tab];
	needpaths = needpaths.new(31, nil);
	for(i = 0; i < len ments; i++) {
		e := ments[i];
		if(mseen.find(e.nodeid) != nil)
			error(sprint("duplicate manifestlog nodeid %s, second at rev %d", e.nodeid, e.rev));
		mseen.add(e.nodeid, e.nodeid);

		link := mneed.find(e.nodeid);
		if(link == Missing)
			error(sprint("manifest nodeid %s, rev %d not referenced from changelog", e.nodeid, e.rev));
		mneed.del(e.nodeid);

		if(link != e.link)
			error(sprint("manifest nodeid %s has bad link %d, expected %d", e.nodeid, e.link, link));

		mbuf := ml.xget(i);
		m := Manifest.xparse(mbuf, ments[i].nodeid);
		for(j := 0; j < len m.files; j++) {
			mf := m.files[j];
			f := needpaths.find(mf.path);
			if(f == nil) {
				f = Tab.new(31, Missing);
				needpaths.add(mf.path, f);
			}
			if(f.find(mf.nodeid) < -1)
				f.add(mf.nodeid, link);
		}
	}

	mmissing := mneed.keys();
	if(mmissing != nil)
		error("missing manifest nodeids: "+join(mmissing, " "));

	files := tablist(needpaths);
	say(sprint("verifying %d files", len files));
	for(; files != nil; files = tl files) {
		(path, fneed) := hd files;
		rl := repo.xopenrevlog(path);
		fents := rl.xentries();
		say(sprint("verifying file %q, %d entries", path, len fents));

		fseen := Strhash[string].new(31, nil);
		for(i = 0; i < len fents; i++) {
			e := fents[i];
			if(fseen.find(e.nodeid) != nil)
				error(sprint("duplicate nodeid %s in revlog %q, second at rev %d", e.nodeid, path, e.rev));
			fseen.add(e.nodeid, e.nodeid);

			link := fneed.find(e.nodeid);
			if(link < -1)
				error(sprint("file %q nodeid %s, rev %d not referenced from manifest", path, e.nodeid, e.rev));
			if(link != e.link)
				error(sprint("file %q nodeid %s has bad link %d, expected %d", path, e.nodeid, e.link, link));
			fneed.del(e.nodeid);

			rl.xget(i);
		}

		fmissing := fneed.keys();
		if(fmissing != nil)
			error("missing file %q nodeids: "+join(fmissing, " "));
	}
}

Tab: adt {
	items:	array of list of (string, int);
	nilval:	int;

	new:	fn(size, nilval: int): ref Tab;
	add:	fn(t: self ref Tab, n: string, link: int);
	del:	fn(t: self ref Tab, n: string);
	find:	fn(t: self ref Tab, n: string): int;
	keys:	fn(t: self ref Tab): list of string;
};

Tab.new(size, nilval: int): ref Tab
{
	return ref Tab (array[size] of list of (string, int), nilval);
}

Tab.add(t: self ref Tab, n: string, link: int)
{
	i := tables->hash(n, len t.items);
	t.items[i] = (n, link)::t.items[i];
}

Tab.del(t: self ref Tab, n: string)
{
	i := tables->hash(n, len t.items);
	r: list of (string, int);
	for(l := t.items[i]; l != nil; l = tl l)
		if((hd l).t0 != n)
			r = hd l::r;
	t.items[i] = r;
}

Tab.find(t: self ref Tab, n: string): int
{
	i := tables->hash(n, len t.items);
	for(l := t.items[i]; l != nil; l = tl l)
		if((hd l).t0 == n)
			return (hd l).t1;
	return t.nilval;
}

Tab.keys(t: self ref Tab): list of string
{
	l: list of string;
	for(i := 0; i < len t.items; i++)
		for(ll := t.items[i]; ll != nil; ll = tl ll)
			l = (hd ll).t0::l;
	return l;
}

tablist[T](t: ref Strhash[T]): list of (string, T)
{
	r: list of (string, T);
	for(i := 0; i < len t.items; i++)
		for(l := t.items[i]; l != nil; l = tl l)
			r = hd l::r;
	return r;
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
