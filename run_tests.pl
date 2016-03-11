#!/usr/bin/env perl
use strict;
use warnings;

use feature qw/ say /;

use File::Slurper qw/ read_text write_binary write_text read_binary /;
use JSON;
use Data::Dumper;

use Data::FlatTables;


# bool values cannot be tested properly because the JSON package decodes boolean as strings instead of 0/1
# 0 integer values are mostly incompatible with flatbuffers because flatbuffers for some reason just skips the fields 0 value when serializing
# flatbuffers forbids anything but scalars and struct fields inside structs
# flatbuffers doesnt support nested arrays


# settings
my $flatbuffers_compiler = 'flatc';

my %loaded_files; # prevent double loading files


sub compare_arrays {
	my ($array1, $array2) = @_;
	for my $i (0 .. $#$array1, 0 .. $#$array2) {
		if (not defined $array2->[$i]) {
			die "incorrect decoding for index #$i: undef <=> $array1->[$i]" if defined $array1->[$i];
		} elsif (ref $array1->[$i] eq 'HASH') {
			die "lack of hash at index $i" if not defined $array2->[$i];
			compare_hashes($array1->[$i], $array2->[$i]);
		} elsif (ref $array1->[$i] eq 'ARRAY') {
			die "lack of array at index $i" if not defined $array2->[$i];
			compare_arrays($array1->[$i], $array2->[$i]);
		} else {
			die "incorrect decoding for index #$i: $array2->[$i] <=> $array1->[$i]" if $array2->[$i] ne $array1->[$i];
		}
	}
}


sub compare_hashes {
	my ($hash1, $hash2) = @_;
	for my $field (keys %$hash1, keys %$hash2) {
		if (not defined $hash2->{$field}) {
			die "incorrect decoding for field '$field': undef <=> $hash1->{$field}" if defined $hash1->{$field};
		} elsif (ref $hash1->{$field} eq 'HASH') {
			die "lack of hash at index '$field'" if not defined $hash2->{$field};
			compare_hashes($hash1->{$field}, $hash2->{$field});
		} elsif (ref $hash1->{$field} eq 'ARRAY') {
			die "lack of array at index '$field'" if not defined $hash2->{$field};
			compare_arrays($hash1->{$field}, $hash2->{$field});
		} else {
			die "incorrect decoding for field '$field': $hash2->{$field} <=> $hash1->{$field}" if $hash2->{$field} ne $hash1->{$field};
		}
	}
}

sub test_perl_to_perl {
	my ($file, $data) = @_;

	$loaded_files{$file} = Data::FlatTables->load($file) unless exists $loaded_files{$file};
	my $class = $loaded_files{$file};

	# serialize the data
	my $serialized_data = $class->new(%$data)->serialize;
	write_binary('out.bin', $serialized_data);

	my $res = $class->deserialize($serialized_data);

	compare_hashes($data, $res);

	say "all correct perl to perl for class $class with file $file";

	# cleanup
	unlink 'out.bin';
}


sub test_perl_to_flatbuffers {
	my ($file, $data) = @_;

	$loaded_files{$file} = Data::FlatTables->load($file) unless exists $loaded_files{$file};
	my $class = $loaded_files{$file};

	# serialize and write to file
	write_binary('out.bin', $class->new(%$data)->serialize);
	# have flatbuffers parse it to json
	print `$flatbuffers_compiler -t --strict-json --raw-binary $file -- out.bin`;
	# read the json
	my $res = decode_json read_text('out.json');

	compare_hashes($data, $res);

	say "all correct perl to flatbuffers for class $class with file $file";

	# cleanup
	unlink 'out.bin';
	unlink 'out.json';
}

sub test_flatbuffers_to_perl {
	my ($file, $data) = @_;

	$loaded_files{$file} = Data::FlatTables->load($file) unless exists $loaded_files{$file};
	my $class = $loaded_files{$file};

	# write a neat json file
	write_text('out.json', encode_json $data);

	# compile it to binary with flatbuffers
	print `$flatbuffers_compiler -b $file out.json`;

	# deserialize the binary with perl FlatBuffers
	my $serialized_data = read_binary('out.bin');
	my $res = $class->deserialize($serialized_data);

	compare_hashes($data, $res);

	say "all correct flatbuffers to perl for class $class with file $file";

	# cleanup
	unlink 'out.json';
	unlink 'out.bin';
}









test_perl_to_perl('fbs/test1.fbs' => { type => 26, id => 15, val => 1337, key => 6000000000 });
test_perl_to_perl('fbs/test1.fbs' => { type => 26, val => 1337 });
test_perl_to_perl('fbs/test1.fbs' => {});
test_perl_to_perl('fbs/test1.fbs' => { id => -15, val => 0xffffffff });


test_perl_to_flatbuffers('fbs/test1.fbs' => { type => 26, id => 15, val => 1337, key => 6000000000 });
test_perl_to_flatbuffers('fbs/test1.fbs' => { type => 26, val => 1337 });
test_perl_to_flatbuffers('fbs/test1.fbs' => {});
test_perl_to_flatbuffers('fbs/test1.fbs' => { id => -15, val => 0xffffffff });

test_flatbuffers_to_perl('fbs/test1.fbs' => { type => 26, id => 15, val => 1337, key => 6000000000 });
test_flatbuffers_to_perl('fbs/test1.fbs' => { type => 26, val => 1337 });
test_flatbuffers_to_perl('fbs/test1.fbs' => {});
test_flatbuffers_to_perl('fbs/test1.fbs' => { id => -15, val => 0xffffffff });



test_perl_to_perl('fbs/stringy.fbs' => { val => 'asdf' });
test_perl_to_perl('fbs/stringy.fbs' => { val => 'lol' x 256 });
test_perl_to_perl('fbs/stringy.fbs' => { type => 14, val => 'lol' x 256, ending => 500 });
test_perl_to_perl('fbs/stringy.fbs' => { val => 'asdf', val2 => 'qwerty', val15 => '' });
test_perl_to_perl('fbs/stringy.fbs' => { val => "12456789", val2 => '', val15 => 'asdfasdfasd', padding => 0, padding2 => 0x7fffffff });

test_perl_to_flatbuffers('fbs/stringy.fbs' => { val => 'asdf' });
test_perl_to_flatbuffers('fbs/stringy.fbs' => { val => 'lol' x 256 });
test_perl_to_flatbuffers('fbs/stringy.fbs' => { type => 14, val => 'lol' x 256, ending => 500 });
test_perl_to_flatbuffers('fbs/stringy.fbs' => { val => 'asdf', val2 => 'qwerty', val15 => '' });
test_perl_to_flatbuffers('fbs/stringy.fbs' => { val => "12456789", val2 => '', val15 => 'asdfasdfasd', padding => 0, padding2 => 0x7fffffff });

test_flatbuffers_to_perl('fbs/stringy.fbs' => { val => 'asdf' });
test_flatbuffers_to_perl('fbs/stringy.fbs' => { val => 'lol' x 256 });
test_flatbuffers_to_perl('fbs/stringy.fbs' => { type => 14, val => 'lol' x 256, ending => 500 });
test_flatbuffers_to_perl('fbs/stringy.fbs' => { val => 'asdf', val2 => 'qwerty', val15 => '' });
# test skipped because flatbuffers arbitrarily skips serializing fields with a value of 0, thus making this test always fail

test_perl_to_perl('fbs/subtable.fbs' => { subtable => { a => 15, b => 30 } });
test_perl_to_perl('fbs/subtable.fbs' => { id => 1, subtable => { a => 15 }, pad => 100 });
test_perl_to_perl('fbs/subtable.fbs' => { id => 1, pad => 100 });

test_perl_to_flatbuffers('fbs/subtable.fbs' => { subtable => { a => 15, b => 30 } });
test_perl_to_flatbuffers('fbs/subtable.fbs' => { id => 1, subtable => { a => 15 }, pad => 100 });
test_perl_to_flatbuffers('fbs/subtable.fbs' => { id => 1, pad => 100 });

test_flatbuffers_to_perl('fbs/subtable.fbs' => { subtable => { a => 15, b => 30 } });
test_flatbuffers_to_perl('fbs/subtable.fbs' => { id => 1, subtable => { a => 15 }, pad => 100 });
test_flatbuffers_to_perl('fbs/subtable.fbs' => { id => 1, pad => 100 });



test_perl_to_perl('fbs/recursive_subtable.fbs' => { val => 5 });
test_perl_to_perl('fbs/recursive_subtable.fbs' => { val => 500, sub => { val => 15 } });
test_perl_to_perl('fbs/recursive_subtable.fbs' => { val => -1, sub => { sub => { val => -100 } } });
test_perl_to_perl('fbs/recursive_subtable.fbs' => { sub => { sub => { sub => { val => 1337 } } } });

test_perl_to_flatbuffers('fbs/recursive_subtable.fbs' => { val => 5 });
test_perl_to_flatbuffers('fbs/recursive_subtable.fbs' => { val => 500, sub => { val => 15 } });
test_perl_to_flatbuffers('fbs/recursive_subtable.fbs' => { val => -1, sub => { sub => { val => -100 } } });
test_perl_to_flatbuffers('fbs/recursive_subtable.fbs' => { sub => { sub => { sub => { val => 1337 } } } });

test_flatbuffers_to_perl('fbs/recursive_subtable.fbs' => { val => 5 });
test_flatbuffers_to_perl('fbs/recursive_subtable.fbs' => { val => 500, sub => { val => 15 } });
test_flatbuffers_to_perl('fbs/recursive_subtable.fbs' => { val => -1, sub => { sub => { val => -100 } } });
test_flatbuffers_to_perl('fbs/recursive_subtable.fbs' => { sub => { sub => { sub => { val => 1337 } } } });



test_perl_to_perl('fbs/struct.fbs' => { obj => { key => 15, val => 400 } });
test_perl_to_perl('fbs/struct.fbs' => { obj => { key => 15, val => 400 }, obj2 => { key => -5, val => -500 } });
test_perl_to_perl('fbs/struct.fbs' => { id => 8, obj2 => { key => -5, val => -500 }, pad => -8 });

test_perl_to_flatbuffers('fbs/struct.fbs' => { obj => { key => 15, val => 400 } });
test_perl_to_flatbuffers('fbs/struct.fbs' => { obj => { key => 15, val => 400 }, obj2 => { key => -5, val => -500 } });
test_perl_to_flatbuffers('fbs/struct.fbs' => { id => 8, obj2 => { key => -5, val => -500 }, pad => -8 });

test_flatbuffers_to_perl('fbs/struct.fbs' => { obj => { key => 15, val => 400 } });
test_flatbuffers_to_perl('fbs/struct.fbs' => { obj => { key => 15, val => 400 }, obj2 => { key => -5, val => -500 } });
test_flatbuffers_to_perl('fbs/struct.fbs' => { id => 8, obj2 => { key => -5, val => -500 }, pad => -8 });



test_perl_to_perl('fbs/complex_struct.fbs' => {
	data => { id => 15, subdata1 => { test => 1, val => 2 }, subdata2 => { test => -4, val => -5 } },
});
test_perl_to_perl('fbs/complex_struct.fbs' => {
	name => 'test',
	data => { id => 215, subdata1 => { test => 21, val => 22 }, subdata2 => { test => -24, val => -25 } },
	testdata => { test => 1337, val => 7331 },
	padding => 111111,
});
test_perl_to_perl('fbs/complex_struct.fbs' => {
	name => 'no data',
	testdata => { test => -1, val => -2 },
	padding => -111111,
});

test_perl_to_flatbuffers('fbs/complex_struct.fbs' => {
	data => { id => 15, subdata1 => { test => 1, val => 2 }, subdata2 => { test => -4, val => -5 } },
});
test_perl_to_flatbuffers('fbs/complex_struct.fbs' => {
	name => 'test',
	data => { id => 215, subdata1 => { test => 21, val => 22 }, subdata2 => { test => -24, val => -25 } },
	testdata => { test => 1337, val => 7331 },
	padding => 111111,
});
test_perl_to_flatbuffers('fbs/complex_struct.fbs' => {
	name => 'no data',
	testdata => { test => -1, val => -2 },
	padding => -111111,
});

test_flatbuffers_to_perl('fbs/complex_struct.fbs' => {
	data => { id => 15, subdata1 => { test => 1, val => 2 }, subdata2 => { test => -4, val => -5 } },
});
test_flatbuffers_to_perl('fbs/complex_struct.fbs' => {
	name => 'test',
	data => { id => 215, subdata1 => { test => 21, val => 22 }, subdata2 => { test => -24, val => -25 } },
	testdata => { test => 1337, val => 7331 },
	padding => 111111,
});
test_flatbuffers_to_perl('fbs/complex_struct.fbs' => {
	name => 'no data',
	testdata => { test => -1, val => -2 },
	padding => -111111,
});


test_perl_to_perl('fbs/pointing_struct.fbs' => {
	data => { name => 'name', value => 'value', child1 => {}, child2 => {} },
});
test_perl_to_perl('fbs/pointing_struct.fbs' => {
	data => { name => 'qwerty', value => 'uiop', child1 => {}, child2 => {} },
	more => { name => 'test', value => 'asdf', child1 => {}, child2 => {} },
});
test_perl_to_perl('fbs/pointing_struct.fbs' => {
	data => { name => 'name', value => 'value', child1 => {
		data => { name => 'wwgaerge', value => '', child1 => {}, child2 => {} }
		}, child2 => {} },
	more => { name => 'test', value => 'asdf', child1 => {}, child2 => {} },
});


# no testing of pointing_struct.fbs with flatbuffers because flatbuffers doesn't support structs with string or table values






test_perl_to_perl('fbs/vectory.fbs' => { vals => [1, 3, 5, 16, 0], });
test_perl_to_perl('fbs/vectory.fbs' => { vals => [-50 .. 50], });
test_perl_to_perl('fbs/vectory.fbs' => { id => 15, name => 'test', vals => [-50 .. 50], padding => 500 });
test_perl_to_perl('fbs/vectory.fbs' => { id => 1, name => 'emptytest', padding => 400 });

test_perl_to_flatbuffers('fbs/vectory.fbs' => { vals => [1, 3, 5, 16, 0], });
test_perl_to_flatbuffers('fbs/vectory.fbs' => { vals => [-50 .. 50], });
test_perl_to_flatbuffers('fbs/vectory.fbs' => { id => 15, name => 'test', vals => [-50 .. 50], padding => 500 });
test_perl_to_flatbuffers('fbs/vectory.fbs' => { id => 1, name => 'emptytest', padding => 400 });

test_flatbuffers_to_perl('fbs/vectory.fbs' => { vals => [1, 3, 5, 16, 0], });
test_flatbuffers_to_perl('fbs/vectory.fbs' => { vals => [-50 .. 50], });
test_flatbuffers_to_perl('fbs/vectory.fbs' => { id => 15, name => 'test', vals => [-50 .. 50], padding => 500 });
test_flatbuffers_to_perl('fbs/vectory.fbs' => { id => 1, name => 'emptytest', padding => 400 });



test_perl_to_perl('fbs/string_vectors.fbs' => { keys => [qw/ a /], vals => [qw/ b /], });
test_perl_to_perl('fbs/string_vectors.fbs' => { keys => [qw/ apple bananna cherry /], vals => [qw/ a b c /], });
test_perl_to_perl('fbs/string_vectors.fbs' => { id => 5, keys => ['a' .. 'z'], vals => ['A' .. 'Z'], pad2 => 15, });
test_perl_to_perl('fbs/string_vectors.fbs' => { id => 7, keys => [], pad2 => -1, });

test_perl_to_flatbuffers('fbs/string_vectors.fbs' => { keys => [qw/ a /], vals => [qw/ b /], });
test_perl_to_flatbuffers('fbs/string_vectors.fbs' => { keys => [qw/ apple bananna cherry /], vals => [qw/ a b c /], });
test_perl_to_flatbuffers('fbs/string_vectors.fbs' => { id => 5, keys => ['a' .. 'z'], vals => ['A' .. 'Z'], pad2 => 15, });
test_perl_to_flatbuffers('fbs/string_vectors.fbs' => { id => 7, keys => [], pad2 => -1, });

test_flatbuffers_to_perl('fbs/string_vectors.fbs' => { keys => [qw/ a /], vals => [qw/ b /], });
test_flatbuffers_to_perl('fbs/string_vectors.fbs' => { keys => [qw/ apple bananna cherry /], vals => [qw/ a b c /], });
test_flatbuffers_to_perl('fbs/string_vectors.fbs' => { id => 5, keys => ['a' .. 'z'], vals => ['A' .. 'Z'], pad2 => 15, });
test_flatbuffers_to_perl('fbs/string_vectors.fbs' => { id => 7, keys => [], pad2 => -1, });



test_perl_to_perl('fbs/vector_vectors.fbs' => { vals => [ [5, 9, 13, 17], [ 1, 5, 7], [500, 400, 300] ], });
test_perl_to_perl('fbs/vector_vectors.fbs' => { vals => [ [],[],[],[] ], morevals => [
	[ [5, 9, 13, 17], [ 1, 5, 7], [500, 400, 300] ],
	[ [1 .. 50],[400 .. 410],[100 .. 112],[] ],
	[ [-50 .. -20], ],
]});
test_perl_to_perl('fbs/vector_vectors.fbs' => { morevals => [
	[ [], [], [] ],
	[ [], [], [], [], [] ],
	[ [], [], [], [], [], [], [] ],
], stringvals => [ [qw/ apple bannana cherry /], ['a' .. 'c'], [qw/ int int int int /] ] });

# no testing of fbs/vector_vectors.fbs because flatbuffers doesnt support nested arrays




test_perl_to_perl('fbs/array_struct.fbs' => { id => 5, struct => {
	keys => [5, 9, 13, 17],
	vals => [ [qw/ apple bannana cherry /], ['a' .. 'c'], [qw/ int int int int /] ],
	subtables => [{ key => 'test', val => 1515 }, { key => 'a', val => 1313 },  { val => -1 },  {}, { key => '300000000000000000' }, ],
}, padding => 15});
test_perl_to_perl('fbs/array_struct.fbs' => { struct => {
	keys => [],
	vals => [ [], [], [], [] ],
	subtables => [],
},});
test_perl_to_perl('fbs/array_struct.fbs' => { struct => {
	keys => [1 .. 1000],
	vals => [],
	subtables => [ { key => 'key', val => 41414141 }, ],
},});
test_perl_to_perl('fbs/array_struct.fbs' => { id => 101 });

# no testing of array_struct.fbs with flatbuffers because flatbuffers doesn't support arrays inside structs





test_perl_to_perl('fbs/table_vectors.fbs' => { vec => [
	{ key => 'asdf', val => 1 }, { key => '', val => 3 }, { val => 5 }, { key => 'really long' x 5, val => 17 }, { val => -19 },
] });
test_perl_to_perl('fbs/table_vectors.fbs' => { vec => [] });
test_perl_to_perl('fbs/table_vectors.fbs' => {});
test_perl_to_perl('fbs/table_vectors.fbs' => { vec => [
	{}, {}, { key => 'key' }, {}, { val => 15 }
] });

test_perl_to_flatbuffers('fbs/table_vectors.fbs' => { vec => [
	{ key => 'asdf', val => 1 }, { key => '', val => 3 }, { val => 5 }, { key => 'really long' x 5, val => 17 }, { val => -19 },
] });
test_perl_to_flatbuffers('fbs/table_vectors.fbs' => { vec => [] });
test_perl_to_flatbuffers('fbs/table_vectors.fbs' => {});
test_perl_to_flatbuffers('fbs/table_vectors.fbs' => { vec => [
	{}, {}, { key => 'key' }, {}, { val => 15 }
] });
test_flatbuffers_to_perl('fbs/table_vectors.fbs' => { vec => [
	{ key => 'asdf', val => 1 }, { key => '', val => 3 }, { val => 5 }, { key => 'really long' x 5, val => 17 }, { val => -19 },
] });
test_flatbuffers_to_perl('fbs/table_vectors.fbs' => { vec => [] });
test_flatbuffers_to_perl('fbs/table_vectors.fbs' => {});
test_flatbuffers_to_perl('fbs/table_vectors.fbs' => { vec => [
	{}, {}, { key => 'key' }, {}, { val => 15 }
] });



test_perl_to_perl('fbs/nested_table_vectors.fbs' => { vec => [
	[], [{ val => 1 }, { val => 3 },], [{}, {}], [{ val => 5 }, { val => 16 }, { val => 0 },]
] });
# no testing with flatbuffers because flatbuffers doesnt support nested vectors



test_perl_to_perl('fbs/struct_vector.fbs' => { vec => [
	{ val => 5, val2 => 50 }, { val => 150, val2 => 250 }, { val => 200, val2 => 400 },
] });
test_perl_to_perl('fbs/struct_vector.fbs' => { vec => [] });
test_perl_to_perl('fbs/struct_vector.fbs' => { vec => [
	{ val => -500, val2 => -1 },
] });

test_perl_to_flatbuffers('fbs/struct_vector.fbs' => { vec => [
	{ val => 5, val2 => 50 }, { val => 150, val2 => 250 }, { val => 200, val2 => 400 },
] });
test_perl_to_flatbuffers('fbs/struct_vector.fbs' => { vec => [] });
test_perl_to_flatbuffers('fbs/struct_vector.fbs' => { vec => [
	{ val => -500, val2 => -1 },
] });

test_flatbuffers_to_perl('fbs/struct_vector.fbs' => { vec => [
	{ val => 5, val2 => 50 }, { val => 150, val2 => 250 }, { val => 200, val2 => 400 },
] });
test_flatbuffers_to_perl('fbs/struct_vector.fbs' => { vec => [] });
test_flatbuffers_to_perl('fbs/struct_vector.fbs' => { vec => [
	{ val => -500, val2 => -1 },
] });




test_perl_to_perl('fbs/struct_vector_struct.fbs' => { obj => { vec => [
	{ val => 5, val2 => 50 }, { val => 150, val2 => 250 }, { val => 200, val2 => 400 },
] }, });
# flatbuffers doesn't support vectors inside structs


test_perl_to_perl('fbs/identifier.fbs' => { val => 15 });
test_perl_to_flatbuffers('fbs/identifier.fbs' => { val => 15 });
test_flatbuffers_to_perl('fbs/identifier.fbs' => { val => 15 });


test_perl_to_perl('fbs/including_file.fbs' => { val => 15, subtable => { includedkey => 'asdf', includedval => 1337 } });
test_perl_to_flatbuffers('fbs/including_file.fbs' => { val => 15, subtable => { includedkey => 'asdf', includedval => 1337 } });
test_flatbuffers_to_perl('fbs/including_file.fbs' => { val => 15, subtable => { includedkey => 'asdf', includedval => 1337 } });

test_perl_to_perl('fbs/complex_namespaces.fbs' => { val => 15 });
test_perl_to_flatbuffers('fbs/complex_namespaces.fbs' => { val => 15 });
test_flatbuffers_to_perl('fbs/complex_namespaces.fbs' => { val => 15 });

test_perl_to_perl('fbs/inline_namespacing.fbs' => { val => 15 });
# flatbuffers doesn't support inline namespacing
