#!/usr/bin/env perl
use strict;
use warnings;

use feature qw/ say /;

use File::Slurper qw/ read_text write_binary write_text read_binary /;
use JSON;

use FlatBuffers;


# bool values cannot be tested properly because the JSON package decodes boolean as strings instead of 0/1
# 0 integer values are mostly incompatible with flatbuffers because flatbuffers for some reason just skips the fields 0 value when serializing
# flatbuffers forbids anything but scalars and struct fields


# settings
my $flatbuffers_compiler = 'flatc';

my %loaded_files; # prevent double loading files



sub compare_hashes {
	my ($hash1, $hash2) = @_;
	for my $field (keys %$hash1, keys %$hash2) {
		if (not defined $hash2->{$field}) {
			die "incorrect decoding for field '$field': undef <=> $hash1->{$field}" if defined $hash1->{$field};
		} elsif (ref $hash1->{$field} eq 'HASH') {
			compare_hashes($hash1->{$field}, $hash2->{$field});
		} else {
			die "incorrect decoding for field '$field': $hash2->{$field} <=> $hash1->{$field}" if $hash2->{$field} ne $hash1->{$field};
		}
	}
}

sub test_perl_to_perl {
	my ($class, $file, $data) = @_;

	FlatBuffers->load($file) unless exists $loaded_files{$file};
	$loaded_files{$file} = 1;

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
	my ($class, $file, $data) = @_;

	FlatBuffers->load($file) unless exists $loaded_files{$file};
	$loaded_files{$file} = 1;

	# serialize and write to file
	write_binary('out.bin', $class->new(%$data)->serialize);
	# have flatbuffers parse it to json
	`$flatbuffers_compiler -t --strict-json --raw-binary $file -- out.bin`;
	# read the json
	my $res = decode_json read_text('out.json');

	compare_hashes($data, $res);

	say "all correct perl to flatbuffers for class $class with file $file";

	# cleanup
	unlink 'out.bin';
	unlink 'out.json';
}

sub test_flatbuffers_to_perl {
	my ($class, $file, $data) = @_;

	FlatBuffers->load($file) unless exists $loaded_files{$file};
	$loaded_files{$file} = 1;

	# write a neat json file
	write_text('out.json', encode_json $data);

	# compile it to binary with flatbuffers
	`$flatbuffers_compiler -b $file out.json`;

	# deserialize the binary with perl FlatBuffers
	my $serialized_data = read_binary('out.bin');
	my $res = $class->deserialize($serialized_data);

	compare_hashes($data, $res);

	say "all correct flatbuffers to perl for class $class with file $file";

	# cleanup
	unlink 'out.json';
	unlink 'out.bin';
}









test_perl_to_perl('Test1::Table1' => 'fbs/test1.fbs', { type => 26, id => 15, val => 1337, key => 6000000000 });
test_perl_to_perl('Test1::Table1' => 'fbs/test1.fbs', { type => 26, val => 1337 });
test_perl_to_perl('Test1::Table1' => 'fbs/test1.fbs', {});
test_perl_to_perl('Test1::Table1' => 'fbs/test1.fbs', { id => -15, val => 0xffffffff });


test_perl_to_flatbuffers('Test1::Table1' => 'fbs/test1.fbs', { type => 26, id => 15, val => 1337, key => 6000000000 });
test_perl_to_flatbuffers('Test1::Table1' => 'fbs/test1.fbs', { type => 26, val => 1337 });
test_perl_to_flatbuffers('Test1::Table1' => 'fbs/test1.fbs', {});
test_perl_to_flatbuffers('Test1::Table1' => 'fbs/test1.fbs', { id => -15, val => 0xffffffff });

test_flatbuffers_to_perl('Test1::Table1' => 'fbs/test1.fbs', { type => 26, id => 15, val => 1337, key => 6000000000 });
test_flatbuffers_to_perl('Test1::Table1' => 'fbs/test1.fbs', { type => 26, val => 1337 });
test_flatbuffers_to_perl('Test1::Table1' => 'fbs/test1.fbs', {});
test_flatbuffers_to_perl('Test1::Table1' => 'fbs/test1.fbs', { id => -15, val => 0xffffffff });



test_perl_to_perl('Test1::TableWithStrings' => 'fbs/stringy.fbs', { val => 'asdf' });
test_perl_to_perl('Test1::TableWithStrings' => 'fbs/stringy.fbs', { val => 'lol' x 256 });
test_perl_to_perl('Test1::TableWithStrings' => 'fbs/stringy.fbs', { type => 14, val => 'lol' x 256, ending => 500 });
test_perl_to_perl('Test1::TableWithStrings' => 'fbs/stringy.fbs', { val => 'asdf', val2 => 'qwerty', val15 => '' });
test_perl_to_perl('Test1::TableWithStrings' => 'fbs/stringy.fbs', { val => "12456789", val2 => '', val15 => 'asdfasdfasd', padding => 0, padding2 => 0x7fffffff });

test_perl_to_flatbuffers('Test1::TableWithStrings' => 'fbs/stringy.fbs', { val => 'asdf' });
test_perl_to_flatbuffers('Test1::TableWithStrings' => 'fbs/stringy.fbs', { val => 'lol' x 256 });
test_perl_to_flatbuffers('Test1::TableWithStrings' => 'fbs/stringy.fbs', { type => 14, val => 'lol' x 256, ending => 500 });
test_perl_to_flatbuffers('Test1::TableWithStrings' => 'fbs/stringy.fbs', { val => 'asdf', val2 => 'qwerty', val15 => '' });
test_perl_to_flatbuffers('Test1::TableWithStrings' => 'fbs/stringy.fbs', { val => "12456789", val2 => '', val15 => 'asdfasdfasd', padding => 0, padding2 => 0x7fffffff });

test_flatbuffers_to_perl('Test1::TableWithStrings' => 'fbs/stringy.fbs', { val => 'asdf' });
test_flatbuffers_to_perl('Test1::TableWithStrings' => 'fbs/stringy.fbs', { val => 'lol' x 256 });
test_flatbuffers_to_perl('Test1::TableWithStrings' => 'fbs/stringy.fbs', { type => 14, val => 'lol' x 256, ending => 500 });
test_flatbuffers_to_perl('Test1::TableWithStrings' => 'fbs/stringy.fbs', { val => 'asdf', val2 => 'qwerty', val15 => '' });
# test skipped because flatbuffers arbitrarily skips serializing fields with a value of 0, thus making this test always fail
# test_flatbuffers_to_perl('Test1::TableWithStrings' => 'fbs/stringy.fbs', { val => "12456789", val2 => '', val15 => 'asdfasdfasd', padding => 0, padding2 => 0x7fffffff });

test_perl_to_perl('Test1::asdf' => 'fbs/subtable.fbs', { subtable => { a => 15, b => 30 } });
test_perl_to_perl('Test1::asdf' => 'fbs/subtable.fbs', { id => 1, subtable => { a => 15 }, pad => 100 });
test_perl_to_perl('Test1::asdf' => 'fbs/subtable.fbs', { id => 1, pad => 100 });

test_perl_to_flatbuffers('Test1::asdf' => 'fbs/subtable.fbs', { subtable => { a => 15, b => 30 } });
test_perl_to_flatbuffers('Test1::asdf' => 'fbs/subtable.fbs', { id => 1, subtable => { a => 15 }, pad => 100 });
test_perl_to_flatbuffers('Test1::asdf' => 'fbs/subtable.fbs', { id => 1, pad => 100 });

test_flatbuffers_to_perl('Test1::asdf' => 'fbs/subtable.fbs', { subtable => { a => 15, b => 30 } });
test_flatbuffers_to_perl('Test1::asdf' => 'fbs/subtable.fbs', { id => 1, subtable => { a => 15 }, pad => 100 });
test_flatbuffers_to_perl('Test1::asdf' => 'fbs/subtable.fbs', { id => 1, pad => 100 });



test_perl_to_perl('Test1::RecursiveTable' => 'fbs/recursive_subtable.fbs', { val => 5 });
test_perl_to_perl('Test1::RecursiveTable' => 'fbs/recursive_subtable.fbs', { val => 500, sub => { val => 15 } });
test_perl_to_perl('Test1::RecursiveTable' => 'fbs/recursive_subtable.fbs', { val => -1, sub => { sub => { val => -100 } } });
test_perl_to_perl('Test1::RecursiveTable' => 'fbs/recursive_subtable.fbs', { sub => { sub => { sub => { val => 1337 } } } });

test_perl_to_flatbuffers('Test1::RecursiveTable' => 'fbs/recursive_subtable.fbs', { val => 5 });
test_perl_to_flatbuffers('Test1::RecursiveTable' => 'fbs/recursive_subtable.fbs', { val => 500, sub => { val => 15 } });
test_perl_to_flatbuffers('Test1::RecursiveTable' => 'fbs/recursive_subtable.fbs', { val => -1, sub => { sub => { val => -100 } } });
test_perl_to_flatbuffers('Test1::RecursiveTable' => 'fbs/recursive_subtable.fbs', { sub => { sub => { sub => { val => 1337 } } } });

test_flatbuffers_to_perl('Test1::RecursiveTable' => 'fbs/recursive_subtable.fbs', { val => 5 });
test_flatbuffers_to_perl('Test1::RecursiveTable' => 'fbs/recursive_subtable.fbs', { val => 500, sub => { val => 15 } });
test_flatbuffers_to_perl('Test1::RecursiveTable' => 'fbs/recursive_subtable.fbs', { val => -1, sub => { sub => { val => -100 } } });
test_flatbuffers_to_perl('Test1::RecursiveTable' => 'fbs/recursive_subtable.fbs', { sub => { sub => { sub => { val => 1337 } } } });



test_perl_to_perl('Test1::TableWithStruct' => 'fbs/struct.fbs', { obj => { key => 15, val => 400 } });
test_perl_to_perl('Test1::TableWithStruct' => 'fbs/struct.fbs', { obj => { key => 15, val => 400 }, obj2 => { key => -5, val => -500 } });
test_perl_to_perl('Test1::TableWithStruct' => 'fbs/struct.fbs', { id => 8, obj2 => { key => -5, val => -500 }, pad => -8 });

test_perl_to_flatbuffers('Test1::TableWithStruct' => 'fbs/struct.fbs', { obj => { key => 15, val => 400 } });
test_perl_to_flatbuffers('Test1::TableWithStruct' => 'fbs/struct.fbs', { obj => { key => 15, val => 400 }, obj2 => { key => -5, val => -500 } });
test_perl_to_flatbuffers('Test1::TableWithStruct' => 'fbs/struct.fbs', { id => 8, obj2 => { key => -5, val => -500 }, pad => -8 });

test_flatbuffers_to_perl('Test1::TableWithStruct' => 'fbs/struct.fbs', { obj => { key => 15, val => 400 } });
test_flatbuffers_to_perl('Test1::TableWithStruct' => 'fbs/struct.fbs', { obj => { key => 15, val => 400 }, obj2 => { key => -5, val => -500 } });
test_flatbuffers_to_perl('Test1::TableWithStruct' => 'fbs/struct.fbs', { id => 8, obj2 => { key => -5, val => -500 }, pad => -8 });



test_perl_to_perl('Test1::TableWithComplexStruct' => 'fbs/complex_struct.fbs', {
	data => { id => 15, subdata1 => { test => 1, val => 2 }, subdata2 => { test => -4, val => -5 } },
});
test_perl_to_perl('Test1::TableWithComplexStruct' => 'fbs/complex_struct.fbs', {
	name => 'test',
	data => { id => 215, subdata1 => { test => 21, val => 22 }, subdata2 => { test => -24, val => -25 } },
	testdata => { test => 1337, val => 7331 },
	padding => 111111,
});
test_perl_to_perl('Test1::TableWithComplexStruct' => 'fbs/complex_struct.fbs', {
	name => 'no data',
	testdata => { test => -1, val => -2 },
	padding => -111111,
});

test_perl_to_flatbuffers('Test1::TableWithComplexStruct' => 'fbs/complex_struct.fbs', {
	data => { id => 15, subdata1 => { test => 1, val => 2 }, subdata2 => { test => -4, val => -5 } },
});
test_perl_to_flatbuffers('Test1::TableWithComplexStruct' => 'fbs/complex_struct.fbs', {
	name => 'test',
	data => { id => 215, subdata1 => { test => 21, val => 22 }, subdata2 => { test => -24, val => -25 } },
	testdata => { test => 1337, val => 7331 },
	padding => 111111,
});
test_perl_to_flatbuffers('Test1::TableWithComplexStruct' => 'fbs/complex_struct.fbs', {
	name => 'no data',
	testdata => { test => -1, val => -2 },
	padding => -111111,
});

test_flatbuffers_to_perl('Test1::TableWithComplexStruct' => 'fbs/complex_struct.fbs', {
	data => { id => 15, subdata1 => { test => 1, val => 2 }, subdata2 => { test => -4, val => -5 } },
});
test_flatbuffers_to_perl('Test1::TableWithComplexStruct' => 'fbs/complex_struct.fbs', {
	name => 'test',
	data => { id => 215, subdata1 => { test => 21, val => 22 }, subdata2 => { test => -24, val => -25 } },
	testdata => { test => 1337, val => 7331 },
	padding => 111111,
});
test_flatbuffers_to_perl('Test1::TableWithComplexStruct' => 'fbs/complex_struct.fbs', {
	name => 'no data',
	testdata => { test => -1, val => -2 },
	padding => -111111,
});


# test_perl_to_perl('Test1::TableWithPointingStruct' => 'fbs/pointing_struct.fbs', {
# 	data => { name => 'name', value => 'value', child1 => {}, child2 => {} },
# });

