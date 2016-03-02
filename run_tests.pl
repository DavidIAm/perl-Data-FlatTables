#!/usr/bin/env perl
use strict;
use warnings;

use feature qw/ say /;

use File::Slurper qw/ read_text write_binary write_text read_binary /;
use JSON;

use FlatBuffers;


# bool values cannot be tested properly because the JSON package decodes boolean as strings instead of 0/1
# 0 integer values are mostly incompatible with flatbuffers because flatbuffers for some reason just skips the fields 0 value when serializing


# settings
my $flatbuffers_compiler = 'flatc';

my %loaded_files; # prevent double loading files



sub test_perl_to_perl {
	my ($class, $file, $data) = @_;

	FlatBuffers->load($file) unless exists $loaded_files{$file};
	$loaded_files{$file} = 1;

	# serialize the data
	my $serialized_data = $class->new(%$data)->serialize;
	my $res = $class->deserialize($serialized_data);

	for my $field (keys %$res, keys %$data) {
		if (not defined $data->{$field}) {
			die "incorrect decoding for field '$field': undef <=> $res->{$field}" if defined $res->{$field};
		} else {
			die "incorrect decoding for field '$field': $data->{$field} <=> $res->{$field}" if $data->{$field} ne $res->{$field};
		}
	}
	say "all correct perl to perl for class $class with file $file";
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

	# compare start to result
	for my $field (keys %$res, keys %$data) {
		if (not defined $data->{$field}) {
			die "incorrect decoding for field '$field': undef <=> $res->{$field}" if defined $res->{$field};
		} else {
			die "incorrect decoding for field '$field': $data->{$field} <=> $res->{$field}" if $data->{$field} ne $res->{$field};
		}
	}
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

	# compare start to results
	for my $field (keys %$res, keys %$data) {
		if (not defined $data->{$field}) {
			die "[$file] incorrect decoding for field '$field': undef <=> $res->{$field}" if defined $res->{$field};
		} else {
			die "[$file] incorrect decoding for field '$field': $data->{$field} <=> $res->{$field}" if $data->{$field} ne $res->{$field};
		}
	}
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


