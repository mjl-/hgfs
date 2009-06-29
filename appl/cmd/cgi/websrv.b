implement HgWebsrv;

include "sys.m";
	sys: Sys;
	sprint: import sys;
include "draw.m";
include "arg.m";
include "bufio.m";
include "env.m";
	env: Env;
include "string.m";
	str: String;
include "lists.m";
	lists: Lists;
include "cgi.m";
	cgi: Cgi;
	Fields: import cgi;

dflag: int;
fields: ref Fields;
baseurl: string;

HgWebsrv: module {
	init:	fn(nil: ref Draw->Context, args: list of string);
};

init(nil: ref Draw->Context, args: list of string)
{
	sys = load Sys Sys->PATH;
	arg := load Arg Arg->PATH;
	env = load Env Env->PATH;
	str = load String String->PATH;
	lists = load Lists Lists->PATH;
	cgi = load Cgi Cgi->PATH;
	cgi->init();

	arg->init(args);
	arg->setusage(arg->progname()+" [-d] [-u baseurl] /n/hg [repo1 ...]");
	while((c := arg->opt()) != 0)
		case c {
		'd' =>	dflag++;
		'u' =>	baseurl = arg->earg();
		* =>	arg->usage();
		}
	args = arg->argv();
	if(len args < 1)
		arg->usage();
	root := hd args;
	repos := tl args;

	pi := env->getenv("PATH_INFO");
	name: string;
	hgpath: string;
	if(pi != nil) {
		elems := sys->tokenize(pi, "/").t1;
		if(elems == nil)
			fail(sprint("bad PATH_INFO %#q, cannot determine repo name", pi));
		name = hd lists->reverse(elems);
		if(repos != nil && !has(repos, name))
			fail("no such repository");
		hgpath = root+"/"+name+"/wire";
		say(sprint("hgpath %q", hgpath));
	}

	qs := env->getenv("QUERY_STRING");
	fields = cgi->unpack(qs);
	if(!fields.has("cmd") || name == nil) {
		msg := "<p>this location just serves mercurial repositories using the mercurial wire protocol over http.\nno html frontend here.\n</p>\n";
		if(baseurl != nil && name != nil) {
			url := cgi->htmlescape(baseurl+name);
			msg = sprint("<p>this location just serves mercurial repositories using the mercurial wire protocol over http.\nfor a html frontend, try:</p><p style=\"padding-left: 8em;\"><a href=\"%s\">%s</a></p>\n", url, url);
		}
		sys->print("status: 200 OK\r\ncontent-type: text/html; charset=utf-8\r\n\r\n%s", msg);
		return;
	}


	fd := sys->open(hgpath, Sys->ORDWR);
	if(fd == nil)
		fail("no such repository");

	cmd := fields.get("cmd");
	case cmd {
	"lookup"	=>
		if(sys->fprint(fd, "lookup\n%s", getarg("key", 1)) < 0) {
			okay();
			sys->print("0 %r\n");
		} else {
			okay();
			sys->print("1 ");
			sys->stream(fd, sys->fildes(1), 128);
			sys->print("\n");
		}
	"capabilities"	=> command(fd, "capabilities\n");
	"heads"		=> command(fd, "heads\n");
	"branches"	=> command(fd, "branches\n"+getarg("nodes", 1));
	"between"	=> command(fd, "between\n"+getarg("pairs", 1));
	"changegroup"	=> command(fd, "changegroup\n"+getarg("roots", 0));
	"changegroupsubset"	=>
		if(fields.has("bases") && fields.get("bases") == nil || fields.has("heads") && fields.get("heads") == nil)
			fail("bases/heads must have one valid nodeid when specified");
		command(fd, "changegroupsubset\n"+getarg("bases", 0)+getarg("heads", 0));
	* =>
		fail(sprint("unrecognized command %#q", cmd));
	}
}

stream(f, t: ref Sys->FD, n: int): int
{
	d := array[n] of byte;
	total := 0;
	for(;;) {
		nn := sys->read(f, d, n);
		if(nn < 0)
			return nn;
		if(nn == 0)
			break;
		if(sys->write(t, d, nn) != nn)
			return -1;
		total += nn;
	}
	return total;
}

getarg(s: string, must: int): string
{
	if(must && !fields.has(s))
		fail(sprint("missing parameter %#q", s));
	return fields.get(s)+"\n";
}

command(fd: ref Sys->FD, s: string)
{
	say("writing command:");
	say(sprint("%q", s));
	d := array of byte s;
	if(sys->write(fd, d, len d) != len d)
		fail(sprint("write wire rpc: %r"));
	if(okay() >= 0)
		sys->stream(fd, sys->fildes(1), 32*1024);
}

has(l: list of string, s: string): int
{
	for(; l != nil; l = tl l)
		if(hd l == s)
			return 1;
	return 0;
}

warn(s: string)
{
	sys->fprint(sys->fildes(2), "hg/websrv: %s\n", s);
}

say(s: string)
{
	if(dflag)
		warn(s);
}

okay(): int
{
	return sys->print("status: 200 OK\r\ncontent-type: application/mercurial-0.1\r\n\r\n");
}

fail(s: string)
{
	warn(s);
	sys->print("status: 500 hg wire error\r\ncontent-type: text/plain\r\n\r\n%s\n", s);
	raise "fail:"+s;
}
