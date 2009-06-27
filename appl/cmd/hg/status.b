implement HgStatus;

include "sys.m";
	sys: Sys;
	sprint: import sys;
include "draw.m";
include "arg.m";
include "bufio.m";
include "string.m";
	str: String;
include "mercurial.m";
	hg: Mercurial;
	Dirstate, Dirstatefile, Revlog, Repo, Nodeid, Change: import hg;

dflag: int;
vflag: int;

HgStatus: module {
	init:	fn(nil: ref Draw->Context, args: list of string);
};

init(nil: ref Draw->Context, args: list of string)
{
	sys = load Sys Sys->PATH;
	arg := load Arg Arg->PATH;
	str = load String String->PATH;
	hg = load Mercurial Mercurial->PATH;
	hg->init();

	hgpath := "";

	arg->init(args);
	arg->setusage(arg->progname()+" [-dv] [-h path]");
	while((c := arg->opt()) != 0)
		case c {
		'd' =>	dflag++;
			if(dflag > 1)
				hg->debug++;
		'v' =>	vflag++;
		'h' =>	hgpath = arg->earg();
		* =>	arg->usage();
		}
	args = arg->argv();
	if(len args != 0)
		arg->usage();

	(repo, rerr) := Repo.find(hgpath);
	if(rerr != nil)
		fail(rerr);

	root := repo.workroot();
	(wds, err) := hg->workdirstate(root);
	if(err != nil)
		fail("workdirstate: "+err);

	ds: ref Dirstate;
	(ds, err) = repo.dirstate();
	if(err != nil)
		fail("dirstate: "+err);

	# first print status for all known files
	dsf := l2a(ds.l);
	sort(dsf, statepathge);
	for(i := 0; i < len dsf; i++) {
		e := dsf[i];
		if(e.state != hg->STremove && e.state != hg->STuntracked && !exists(root+"/"+e.name)) {
			sys->print("! %q\n", e.name);
			continue;
		}
		case e.state {
		hg->STneedmerge =>	sys->print("M %q\n", e.name);
		hg->STremove =>	sys->print("R %q\n", e.name);
		hg->STadd =>	sys->print("A %q\n", e.name);
		hg->STnormal =>
			dirty := e.size == hg->SZdirty || isdirty(root+"/"+e.name, e);
			# xxx when e.size == SZcheck, we should check contents, not meta
			if(dirty)
				sys->print("M %q\n", e.name);
		hg->STuntracked =>	sys->print("? %q\n", e.name);
		* =>	raise "missing case";
		}
	}

	# print all remaining paths as unknown
	wdsf := l2a(wds.l);
	sort(wdsf, pathge);
	sort(dsf, pathge);
	i = 0;
	wi := 0;
	while(wi < len wdsf) {
		while(dsf[i].name < wdsf[wi].name)
			i++;

		if(dsf[i].name == wdsf[wi].name) {
			i++;
			wi++;
			continue;
		}

		sys->print("? %q\n", wdsf[wi].name);
		wi++;
	}
}

isdirty(path: string, dsf: ref Dirstatefile): int
{
	(ok, dir) := sys->stat(path);
	if(ok != 0) {
		warn(sprint("stat %q: %r", path));
		return 1;
	}
	return (dir.mode&8r777) == dsf.mode && (dsf.size < 0 || int dir.length == dsf.size) && dir.mtime == dsf.mtime;
}

exists(e: string): int
{
	(ok, dir) := sys->stat(e);
	return ok == 0 && (dir.mode&Sys->DMDIR) == 0;
}

sort[T](a: array of T, ge: ref fn(a, b: T): int)
{
	for(i := 1; i < len a; i++) {
		tmp := a[i];
		for(j := i; j > 0 && ge(a[j-1], tmp); j--)
			a[j] = a[j-1];
		a[j] = tmp;
	}
}

statepathge(a, b: ref Dirstatefile): int
{
	if(a.state != b.state)
		return a.state >= b.state;
	return pathge(a, b);
}

pathge(a, b: ref Dirstatefile): int
{
	return a.name >= b.name;
}

l2a[T](l: list of T): array of T
{
	a := array[len l] of T;
	i := 0;
	for(; l != nil; l = tl l)
		a[i++] = hd l;
	return a;
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
