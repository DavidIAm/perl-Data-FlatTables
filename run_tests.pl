#!/usr/bin/env perl
use strict;
use warnings;

use feature qw/ say state /;

use File::Slurper qw/ read_text write_binary /;
use JSON;

use FlatBuffers;



# settings
my $flatbuffers_compiler = 'flatc';



sub test_to_flatbuffers {
	my ($class, $file, $data) = @_;

	state %loaded; # prevent double loading files
	FlatBuffers->load($file) unless exists $loaded{$file};
	$loaded{$file} = 1;

	# serialize and write to file
	write_binary('out', $class->new(%$data)->serialize);
	# have flatbuffers parse it to json
	`$flatbuffers_compiler -t --strict-json --raw-binary $file -- out`;
	# read the json
	my $res = decode_json read_text('out.json');

	# compare start to result
	for my $field (keys %$res, keys %$data) {
		die "incorrect decoding for field '$field': $data->{$field} <=> $res->{$field}" if $data->{$field} ne $res->{$field};
	}
	say "all correct for class $class with file $file";

	# cleanup
	unlink 'out';
	unlink 'out.json';
}










test_to_flatbuffers('Test1::Table1' => 'fbs/test1.fbs', { type => 26, id => 15, val => 1337, key => 6000000000 });
test_to_flatbuffers('Test1::Table1' => 'fbs/test1.fbs', { type => 26, val => 1337 });
test_to_flatbuffers('Test1::Table1' => 'fbs/test1.fbs', {});
test_to_flatbuffers('Test1::Table1' => 'fbs/test1.fbs', { id => -15, val => 0xffffffff });


