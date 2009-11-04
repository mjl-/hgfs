Bdiff: module
{
	PATH:	con "/dis/lib/bdiff.dis";

	init:	fn();

	Patch: adt {
		s,
		e:	int;
		d:	array of byte;

		text:	fn(p: self ref Patch): string;
	};

	Delta: adt {
		l:	list of ref Patch;

		pack:		fn(d: self ref Delta): array of byte;
		parse:		fn(buf: array of byte): (ref Delta, string);
		apply:		fn(d: self ref Delta, buf: array of byte): array of byte;
		applymany:	fn(base: array of byte, deltas: array of array of byte): (array of byte, string);
		sizediff:	fn(d: self ref Delta): int;
		replaces:	fn(d: self ref Delta, n: int): int;
		text:		fn(d: self ref Delta): string;
	};

	diff:	fn(a, b: array of byte): ref Delta;
};
