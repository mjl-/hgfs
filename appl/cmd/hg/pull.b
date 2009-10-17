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
include "mercurial.m";
	hg: Mercurial;
	Dirstate, Dsfile, Revlog, Repo, Change, Manifest, Mfile, Entry, Patch, Configs: import hg;
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
			say(sprint("looking at branches result, tip %s, base %s, p1 %s, p2 %s", fmtnode(tip), fmtnode(base), fmtnode(p1), fmtnode(p2)));
			if(isknown(base)) {
				say(sprint("base known, scheduling for between"));
				betweens = ref (tip, base)::betweens;
			} else if(p1 == hg->nullnode) {
				say(sprint("base is first revision that we don't know, going to fetch nullnode"));
				if(!hasstr(cgbases, hg->nullnode))
					cgbases = hg->nullnode::cgbases;
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

	(cfd, err) := filtertool->push(inflate, "z", fd, 0);
	if(err != nil)
		error(err);
	b := bufio->fopen(cfd, Bufio->OREAD);
	if(b == nil)
		error("fopen");

	warn("adding changesets");
	cl := repo.xchangelog();
	chtab := revlogwrite(b, cl, 1, nil);

	warn("adding manifests");
	ml := repo.xmanifestlog();
	revlogwrite(b, ml, 0, chtab);
	
	warn("adding file changes");
	for(;;) {
		i := bg32(b);
		if(i == 0)
			break;

		namebuf := breadn(b, i-4);
		name := string namebuf;
		rl := repo.xopenrevlog(name);
		revlogwrite(b, rl, 0, chtab);
	}

	case b.getc() {
	Bufio->EOF =>	;
	Bufio->ERROR =>	error(sprint("error reading end of changegroup: %r"));
	* =>		error(sprint("data past end of changegroup..."));
	}

	#warn(sprint("added %d changesets with %d changes to %d files", tablength(chtab), nchanges, nfiles));
	warn(sprint("added l changesets with m changes to n files"));
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

revlogwrite(b: ref Iobuf, rl: ref Revlog, ischlog: int, chtab: ref Strhash[ref Entry]): ref Strhash[ref Entry]
{
	tab := Strhash[ref Entry].new(31, nil);
	ents := rl.xentries();
	for(i := 0; i < len ents; i++)
		tab.add(ents[i].nodeid, ents[i]);

	if(ischlog)
		chtab = tab;

	indexonly := rl.isindexonly();
	ipath := rl.path+".i";
	repo.xensuredirs(ipath);
	ib := hg->xbopencreate(ipath, Sys->OWRITE, 8r666);
	if(ib.seek(big 0, Bufio->SEEKEND) < big 0)
		error(sprint("seek %q: %r", ipath));
	db: ref Iobuf;
	if(!indexonly) {
		dpath := rl.path+".d";
		db = hg->xbopencreate(dpath, Sys->OWRITE, 8r666);
		if(ib.seek(big 0, Bufio->SEEKEND) < big 0)
			error(sprint("seek %q: %r", dpath));
	}

	base := firstrev := nents := len ents;
	current: array of byte;
	offset := big 0;
	if(len ents > 0) {
		ee := ents[len ents-1];
		offset = ee.offset+big ee.csize;
	}
	deltasizes := 0;

	for(;;) {
		i = bg32(b);
		if(i == 0)
			break;

		(rev, p1, p2, link, delta) := breadchunk(b, i);
		if(dflag) {
			say(sprint("\trev=%s", rev));
			say(sprint("\tp1=%s", p1));
			say(sprint("\tp2=%s", p2));
			say(sprint("\tlink=%s", link));
			say(sprint("\tlen delta=%d", len delta));
		}

		if(ischlog && rev != link)
			error(sprint("changelog entry %s with bogus link %s", rev, link));
		if(!ischlog && chtab.find(link) == nil)
			error(sprint("entry %s references absent changelog link %s", rev, link));

		p := Patch.xparse(delta);
		if(dflag) {
			say(sprint("\tpatch, sizediff %d", p.sizediff()));
			say(sprint("\t%s", p.text()));
		}
		
		p1rev := p2rev := -1;
		if(p1 != hg->nullnode)
			p1rev = (p1e := findentry("p1", rev, tab, p1)).rev;
		if(p2 != hg->nullnode)
			p2rev = findentry("p2", rev, tab, p2).rev;

		selfrev := nents++;
		linkrev := selfrev;
		if(!ischlog)
			linkrev = findentry("link", rev, chtab, link).rev;

		if(selfrev == firstrev) {
			if(p1rev >= 0) {
				# first change, relative to p1
				base = p1e.base;
				current = rl.xget(p1rev);
				say(sprint("first change relative to p1 %s (%d, base %d)", p1, p1rev, base));
				say(sprint("first data is %q", string current));
			} else {
				if(len p.l != 1 || (c := hd p.l).start != 0 || c.end != 0)
					error(sprint("first chunk is not full version"));
			}
			deltasizes = 0; # xxx fix
		}

		say(sprint("new entry: selfrev %d p1rev %d p2rev %d linkrev %d (base %d)", selfrev, p1rev, p2rev, linkrev, base));

		data: array of byte;
		if(len p.l == 1 && (c := hd p.l).start == 0 && c.end == len current) {
			say("patch covers entire file, storing full copy");
			base = selfrev;
			data = current = (hd p.l).buf;
			deltasizes = 0;

			compr := compress(data);
			if(len compr < len data*90/100) {
				data = compr;
			} else {
				nd := array[1+len data] of byte;
				nd[0] = byte 'u';
				nd[1:] = data;
				data = nd;
			}
		} else {
			current = p.apply(current);
			if(selfrev == firstrev && p1rev >= 0 && p1rev != selfrev-1 || deltasizes+len delta > 2*len current) {
				say("delta against p1 which is not previous or delta's too big, storing full copy");
				base = selfrev;
				data = current;
				deltasizes = 0;

				compr := compress(data);
				if(len compr < len data*90/100) {
					data = compr;
				} else {
					nd := array[1+len data] of byte;
					nd[0] = byte 'u';
					nd[1:] = data;
					data = nd;
				}
			} else {
				say("storing delta");
				data = delta;
				deltasizes += len delta;

				compr := compress(data);
				if(len compr < len data*90/100)
					data = compr;
			}
		}
		nrev := hg->xcreatenodeid(current, p1, p2);
		if(nrev != rev)
			error(sprint("nodeid mismatch, expected %s saw %s", rev, nrev));

		say(sprint("new base %d", base));
		flags := 0;
		e := ref Entry(selfrev, offset, big 0, flags, len data, len current, base, linkrev, p1rev, p2rev, rev);

		ebuf := array[hg->Entrysize] of byte;
		e.xpack(ebuf, indexonly);
		if(ib.write(ebuf, len ebuf) != len ebuf)
			error(sprint("write: %r"));
		if(indexonly) {
			if(ib.write(data, len data) != len data)
				error(sprint("write: %r"));
		} else {
			if(db.write(data, len data) != len data)
				error(sprint("write: %r"));
		}

		offset += big len data;
		tab.add(e.nodeid, e);
	}

	if(ib.flush() == Bufio->ERROR)
		error(sprint("write: %r"));
	if(db != nil && db.flush() == Bufio->ERROR)
		error(sprint("write: %r"));
	return tab;
}

findentry(name, rev: string, tab: ref Strhash[ref Entry], n: string): ref Entry
{
	e := tab.find(n);
	if(e == nil)
		error(sprint("missing %s %s for nodeid %s", name, n, rev));
	return e;
}

bg32(b: ref Iobuf): int
{
	return g32i(breadn(b, 4), 0).t0;
}

breadchunk(b: ref Iobuf, n: int): (string, string, string, string, array of byte)
{
	n -= 4;
	if(n < 4*20)
		error("short chunk");
	buf := breadn(b, n);
	o := 0;
	rev := buf[o:o+20];
	o += 20;
	p1 := buf[o:o+20];
	o += 20;
	p2 := buf[o:o+20];
	o += 20;
	link := buf[o:o+20];
	o += 20;
	delta := buf[o:];
	return (hex(rev), hex(p1), hex(p2), hex(link), delta);
}

breadn(b: ref Iobuf, n: int): array of byte
{
	buf := array[n] of byte;
	h := 0;
	while(h < n) {
		nn := b.read(buf[h:], n-h);
		if(nn == Bufio->EOF)
			error("premature eof");
		if(nn == Bufio->ERROR)
			error(sprint("reading: %r"));
		h += nn;
	}
	return buf;
}

compress(d: array of byte): array of byte
{
	(nd, err) := filtertool->convert(deflate, "z", d);
	if(err != nil)
		error("deflate: "+err);
	return nd;
}

tablength(t: ref Strhash[ref Entry]): int
{
	n := 0;
	for(i := 0; i < len t.items; i++)
		n += len t.items[i];
	return n;
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
