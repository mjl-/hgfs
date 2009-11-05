implement HgTar;

include "sys.m";
	sys: Sys;
	sprint: import sys;
include "draw.m";
include "arg.m";
include "bufio.m";
include "string.m";
	str: String;
include "tables.m";
include "../../lib/bdiff.m";
include "mercurial.m";
	hg: Mercurial;
	Revlog, Repo, Change: import hg;

HgTar: module {
	init:	fn(nil: ref Draw->Context, args: list of string);
};


dflag: int;
vflag: int;
revision := -1;
hgpath := "";

init(nil: ref Draw->Context, args: list of string)
{
	sys = load Sys Sys->PATH;
	arg := load Arg Arg->PATH;
	str = load String String->PATH;
	hg = load Mercurial Mercurial->PATH;
	hg->init(0);

	arg->init(args);
	arg->setusage(arg->progname()+" [-dv] [-r rev] [-h path]");
	while((c := arg->opt()) != 0)
		case c {
		'd' =>	hg->debug = dflag++;
		'v' =>	vflag++;
		'r' =>	revision = int arg->earg();
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
	repo := Repo.xfind(hgpath);
	say("found repo");
	(c, m) := repo.xrevision(revision);
	say("have change & manifest");

	if(vflag) {
		warn(sprint("%s\n", c.text()));
		warn(sprint("manifest:\n"));
		for(i := 0; i < len m.files; i++) {
			file := m.files[i];
			warn(sprint("%q %q\n", file.nodeid, file.path));
		}
		warn("\n");
	}

	for(i := 0; i < len m.files; i++) {
		file := m.files[i];
		say(sprint("reading file %q, nodeid %q", file.path, file.nodeid));
		rl := repo.xopenrevlog(file.path);
		d := rl.xgetn(file.nodeid);
		say("file read...");
		say(sprint("%q, %q: %d bytes\n", file.nodeid, file.path, len d));

		# note: it seems we don't have to write directories

		# write header.  512 bytes, has file name, mode, size, checksum, some more.
		hdr := tarhdr(file.path, big len d, c.when+c.tzoff);
		if(sys->write(sys->fildes(1), hdr, len hdr) != len hdr)
			fail(sprint("writing header: %r"));

		# and write the file
		if(sys->write(sys->fildes(1), d, len d) != len d)
			fail(sprint("writing: %r"));

		# pad file with zero bytes to next 512-byte boundary
		pad := array[512 - len d % 512] of {* => byte 0};
		if(sys->write(sys->fildes(1), pad, len pad) != len pad)
			fail(sprint("writing padding: %r"));
	}

	# write end of file
	end := array[2*512] of {* => byte 0};
	if(sys->write(sys->fildes(1), end, len end) != len end)
		fail(sprint("writin trailer: %r"));
}

TARPATH:	con 0;
TARMODE:	con 100;
TARUID:		con 108;
TARGID:		con 116;
TARSIZE:	con 124;
TARMTIME:	con 136;
TARCHECKSUM:	con 148;
TARLINK:	con 156;
tarhdr(path: string, size: big, mtime: int): array of byte
{
	d := array[512] of {* => byte 0};
	d[TARPATH:] = array of byte path;
	d[TARMODE:] = sys->aprint("%8o", 8r644);
	d[TARUID:] = sys->aprint("%8o", 0);
	d[TARGID:] = sys->aprint("%8o", 0);
	d[TARSIZE:] = sys->aprint("%12bo", size);
	d[TARMTIME:] = sys->aprint("%12o", mtime);
	d[TARLINK] = byte '0'; # '0' is normal file;  '5' is directory

	d[TARCHECKSUM:] = array[8] of {* => byte ' '};
	sum := 0;
	for(i := 0; i < len d; i++)
		sum += int d[i];
	d[TARCHECKSUM:] = sys->aprint("%6o", sum);
	d[TARCHECKSUM+6:] = array[] of {byte 0, byte ' '};
	return d;
}

say(s: string)
{
	if(dflag)
		warn(s);
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
