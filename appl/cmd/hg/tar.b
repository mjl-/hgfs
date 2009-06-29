implement HgTar;

include "sys.m";
	sys: Sys;
	sprint: import sys;
include "draw.m";
include "arg.m";
include "bufio.m";
include "string.m";
	str: String;
include "mercurial.m";
	mercurial: Mercurial;
	Revlog, Repo, Nodeid, Change: import mercurial;

dflag: int;
vflag: int;

HgTar: module {
	init:	fn(nil: ref Draw->Context, args: list of string);
};

init(nil: ref Draw->Context, args: list of string)
{
	sys = load Sys Sys->PATH;
	arg := load Arg Arg->PATH;
	str = load String String->PATH;
	mercurial = load Mercurial Mercurial->PATH;
	mercurial->init();

	revision := -1;
	hgpath := "";

	arg->init(args);
	arg->setusage(arg->progname()+" [-dv] [-r rev] [-h path]");
	while((c := arg->opt()) != 0)
		case c {
		'd' =>	dflag++;
			if(dflag > 1)
				mercurial->debug++;
		'v' =>	vflag++;
		'r' =>	revision = int arg->earg();
		'h' =>	hgpath = arg->earg();
		* =>	arg->usage();
		}
	args = arg->argv();
	if(len args != 0)
		arg->usage();

	(repo, rerr) := Repo.find(hgpath);
	if(rerr != nil)
		fail(rerr);
	say("found repo");

	(change, manifest, merr) := repo.manifest(revision);
	if(merr != nil)
		fail(merr);
	say("have change & manifest");

	if(vflag) {
		warn(sprint("%s\n", change.text()));
		warn(sprint("manifest:\n"));
		for(l := manifest.files; l != nil; l = tl l) {
			file := hd l;
			warn(sprint("%s %q\n", file.nodeid.text(), file.path));
		}
		warn("\n");
	}

	for(l := manifest.files; l != nil; l = tl l) {
		file := hd l;
		say(sprint("reading file %q, nodeid %s", file.path, file.nodeid.text()));
		(rl, rlerr) := repo.openrevlog(file.path);
		if(rlerr != nil)
			fail(rlerr);
		(d, derr) := rl.getnodeid(file.nodeid);
		if(derr != nil)
			fail(derr);
		say("file read...");
		say(sprint("%s, %q: %d bytes\n", file.nodeid.text(), file.path, len d));

		# note: it seems we don't have to write directories

		# write header.  512 bytes, has file name, mode, size, checksum, some more.
		hdr := tarhdr(file.path, big len d, change.when+change.tzoff);
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
