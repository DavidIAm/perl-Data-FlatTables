package Data::FlatTables::Table;
use strict;
use warnings;




my %basic_types = (
	bool => { format => 'C', length => 1 },
	byte => { format => 'c', length => 1 },
	ubyte => { format => 'C', length => 1 },
	short => { format => 's<', length => 2 },
	ushort => { format => 'S<', length => 2 },
	int => { format => 'l<', length => 4 },
	uint => { format => 'L<', length => 4 },
	float => { format => 'f<', length => 4 },
	long => { format => 'q<', length => 8 },
	ulong => { format => 'Q<', length => 8 },
	double => { format => 'd<', length => 8 },
);


sub deserialize_string {
	my ($self, $data, $offset) = @_;

	my $string_offset = $offset + unpack "L<", substr $data, $offset, 4; # dereference the string pointer
	my $string_length = unpack "L<", substr $data, $string_offset, 4; # get the length
	return substr $data, $string_offset + 4, $string_length # return a substring
}

sub deserialize_array {
	my ($self, $array_type, $data, $offset) = @_;

	$array_type = $array_type =~ s/\A\[(.*)\]\Z/$1/sr;

	$offset = $offset + unpack "L<", substr $data, $offset, 4; # dereference the array pointer
	my $array_length = unpack "L<", substr $data, $offset, 4; # get the length
	$offset += 4;

	my @array;
	if (exists $basic_types{$array_type}) { # if its an array of numerics
		@array = map { unpack $basic_types{$array_type}{format}, $_ }
			map { substr $data, $offset + $_, $basic_types{$array_type}{length} }
			map $_ * $basic_types{$array_type}{length},
			0 .. ($array_length - 1);
	
	} elsif ($array_type eq "string") { # if its an array of strings
		@array = map { $self->deserialize_string($data, $offset + $_) }
			map $_ * 4,
			0 .. ($array_length - 1);

	} elsif ($array_type =~ /\A\[/) { # if its an array of strings
		@array = map { $self->deserialize_array($array_type, $data, $offset + $_) }
			map $_ * 4,
			0 .. ($array_length - 1);
	
	} else { # if its an array of objects
		if ($array_type->flatbuffers_type eq "table") {
			@array = map { $array_type->deserialize($data, $offset + $_) }
				map $_ * 4,
				0 .. ($array_length - 1);
		} elsif ($array_type->flatbuffers_type eq "struct") {
			my $length = $array_type->flatbuffers_struct_length;
			@array = map { $array_type->deserialize($data, $offset + $_) }
				map $_ * $length,
				0 .. ($array_length - 1);
		} else {
			...
		}
	}

	return \@array
}



sub serialize_objects {
	my ($self, @objects) = @_;


	my $data = "";
	my $offset = 0;

	# concatentate the data
	for my $object (@objects) {
		$object->{serialized_offset} = $offset;
		$data .= $object->{data};
		$offset += length $object->{data};
	}

	# second pass for writing offsets to other parts
	for my $object (@objects) {
		if (defined $object->{reloc}) {
			# perform address relocation
			for my $reloc (@{$object->{reloc}}) {
				my $value;
				if (defined $reloc->{lambda}) { # allow the reloc to have a custom format
					$value = $reloc->{lambda}($object, $reloc);
				} elsif (defined $reloc->{type} and $reloc->{type} eq "unsigned delta") {
					$value = pack "L<", $reloc->{item}{serialized_offset} - $object->{serialized_offset} - $reloc->{offset};
				} elsif (defined $reloc->{type} and $reloc->{type} eq "signed negative delta") {
					$value = pack "l<", $object->{serialized_offset} + $reloc->{offset} - $reloc->{item}{serialized_offset};
				} else {
					...
				}
				substr $data, $object->{serialized_offset} + $reloc->{offset}, length($value), $value;
			}
		}
	}

	# done, the data is now ready to be deserialized
	return $data
}

sub serialize_vtable {
	my ($self, @lengths) = @_;

	my $offset = 4;
	my @table;

	for (@lengths) { # parse table offsets
		push @table, $_ ? $offset : 0;
		$offset += $_;
	}

	unshift @table, $offset; # prefix data length
	unshift @table, 2 * (@table + 1); #prefix vtable length
	push @table, 0 if @table % 2; # pad if odd count
	# compile object
	return { type => "vtable", data => pack "S<" x @table, @table }
}

sub serialize_string {
	my ($self, $string) = @_;

	my $len = pack "L<", length $string;
	$string .= "\0"; # null termination byte because why the fuck not (it's part of flatbuffers)

	my $data = "$len$string";
	$data .= pack "x" x (4 - (length ($data) % 4)) if length ($data) % 4; # pad to 4 byte boundary

	return { type => "string", data => $data }
}


sub serialize_array {
	my ($self, $array_type, $array) = @_;

	$array_type = $array_type =~ s/\A\[(.*)\]\Z/$1/sr;

	my $data = pack "L<", scalar @$array;
	my @array_objects;
	my @reloc;

	if (exists $basic_types{$array_type}) { # array of scalar values
		$data .= join "", map { pack $basic_types{$array_type}{format}, $_ } @$array;

	} elsif ($array_type eq "string") { # array of strings
		$data .= "\0\0\0\0" x @$array;
		for my $i (0 .. $#$array) {
			my $string_object = $self->serialize_string($array->[$i]);
			push @array_objects, $string_object;
			push @reloc, { offset => 4 + $i * 4, item => $string_object, type => "unsigned delta" };
		}
	} elsif ($array_type =~ /\A\[/) { # array of arrays
		$data .= "\0\0\0\0" x @$array;
		for my $i (0 .. $#$array) {
			my ($array_object, @child_array_objects) = $self->serialize_array($array_type, $array->[$i]);
			push @array_objects, $array_object, @child_array_objects;
			push @reloc, { offset => 4 + $i * 4, item => $array_object, type => "unsigned delta" };
		}

	} else { # else an array of objects
		if ($array_type->flatbuffers_type eq "table") {
			$data .= "\0\0\0\0" x @$array;
			for my $i (0 .. $#$array) {
				my ($root_object, @table_objects) = $array->[$i]->serialize_data;
				push @array_objects, $root_object, @table_objects;
				push @reloc, { offset => 4 + $i * 4, item => $root_object, type => "unsigned delta" };
			}
		} elsif ($array_type->flatbuffers_type eq "struct") {
			for my $i (0 .. $#$array) {
				my ($root_object, @struct_objects) = $array->[$i]->serialize_data;
				push @array_objects, @struct_objects;
				push @reloc, map { $_->{offset} += length ($data); $_ } @{$root_object->{reloc}};
				$data .= $root_object->{data};

			}
		} else {
			...
		}
	}

	return { type => "array", data => $data, reloc => \@reloc }, @array_objects
}



1
