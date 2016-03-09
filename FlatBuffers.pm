#!/usr/bin/env perl
package FlatBuffers;
use strict;
use warnings;

use feature 'say';

use File::Slurp qw/ read_file write_file /;
use List::Util qw/ any /;
use Data::Dumper;


# little-endian everything
# they're not even buffers ffs, a better name would've been flatpack


# TODO:
	# anonymous package creation
	# source filter for transparent creation
	# superclass creation instead of self-contained class to prevent code pollution
	# verify that the method names that we are creating arent reserved
	# enum support
	# file identifier support
	# file inclusion
	# vector support
	# more complex namespace handling
	# use statements in compiled and written files










# compiles and loads packages from a given fbs file
# returns the package name of the root object declared in the fbs file (undef if no root object was declared)
sub load {
	my ($self, $filepath) = @_;
	my $parser = FlatBuffers->new;
	my ($root_type, $compiled) = $parser->compile_file($filepath);

	$parser->load_perl_packages($compiled);

	return $root_type
}



# compiles a fbs file and writes perl packages in the current directory
# returns the package name of the root object declared in the fbs file (undef if no root object was declared)
sub create_packages {
	my ($self, $filepath) = @_;
	my $parser = FlatBuffers->new;
	my ($root_type, $compiled) = $parser->compile_file($filepath);

	$parser->create_perl_packages($compiled);
	return $root_type
}













# these weren't defined in the grammar. gj google
my $regex_string_constant = qr/"[^"]*"/xs;
my $regex_ident = qr/[a-zA-Z_][a-zA-Z_\d]*/x;

# definition taken from https://google.github.io/flatbuffers/flatbuffers_grammar.html

my $regex_integer_constant = qr/ -?\d+ | true | false /x;
my $regex_float_constant = qr/ -?\d+\.\d+([eE][+\-]?\d+)? /x; 
my $regex_type = qr/ (?<regex_type_recurse> 
	bool | byte | ubyte | short | ushort | int | uint | float | long | ulong | double | string | \[\s*(?&regex_type_recurse)\s*\] | $regex_ident ) /x;

my $regex_scalar = qr/ $regex_integer_constant | $regex_float_constant/x;
my $regex_single_value = qr/ $regex_scalar | $regex_string_constant /x;
my $regex_metadata = qr/ (\(\s*$regex_ident (\s*:\s*$regex_single_value )? (\s*,\s*$regex_ident (\s*:\s*$regex_single_value )? )* \s* \) )? /x;

my $regex_file_extension_decl = qr/ file_extension\s+(?<file_extension_name> $regex_string_constant)\s*; /x;
my $regex_file_identifier_decl = qr/ file_identifier\s+(?<file_identifier_name> $regex_string_constant)\s*; /x;
my $regex_include = qr/ include\s+(?<include_name> $regex_string_constant)\s*; /x;
my $regex_namespace_decl = qr/ namespace\s+(?<namespace_name> $regex_ident ( \. $regex_ident )*)\s*; /x;
my $regex_root_decl = qr/ root_type\s+(?<root_name> $regex_ident)\s*; /x;
my $regex_attribute_decl = qr/ attribute\s+(?<attribute_name> $regex_string_constant)\s*; /x;

my $regex_enumval_decl = qr/ $regex_ident (\s*=\s*$regex_integer_constant)? /x;
my $regex_enum_decl = qr/ ( enum | union )\s+$regex_ident\s*(:\s*$regex_type\s+)? $regex_metadata \{ ($regex_enumval_decl (\s*,\s*$regex_enumval_decl)*)? \} /x;

my $regex_field_decl = qr/ $regex_ident\s*:\s*$regex_type\s*(=\s*$regex_scalar\s*)? $regex_metadata\s*;/x;
my $regex_type_decl = qr/ ( table | struct )\s+$regex_ident\s+$regex_metadata\s*\{\s*($regex_field_decl\s*)+\} /x;


# schema = include* ( namespace_decl | type_decl | enum_decl | root_decl | file_extension_decl | file_identifier_decl | attribute_decl | object )*

# i have no clue what object is, the {} aren't strings in the schema, and i can't seem to find an explanation on what they are in scheme
# object = { commasep( ident : value ) }
# value = single_value | object | [ commasep( value ) ]

# commasep(x) = [ x ( , x )* ] # nope # this can actually be done using a function, but why would i?





my %flatbuffers_basic_types = (
	bool => { format => "C", length => 1 },
	byte => { format => "c", length => 1 },
	ubyte => { format => "C", length => 1 },
	short => { format => "s<", length => 2 },
	ushort => { format => "S<", length => 2 },
	int => { format => "l<", length => 4 },
	uint => { format => "L<", length => 4 },
	float => { format => "f<", length => 4 },
	long => { format => "q<", length => 8 },
	ulong => { format => "Q<", length => 8 },
	double => { format => "d<", length => 8 },
);







sub new {
	my $class = shift;
	my %args = @_;
	my $self = bless {}, $class;

	$self->toplevel_namespace($args{toplevel_namespace});
	$self->table_types({});

	return $self
}

sub toplevel_namespace { @_ > 1 ? $_[0]{toplevel_namespace} = $_[1] : $_[0]{toplevel_namespace} }

sub current_namespace { @_ > 1 ? $_[0]{current_namespace} = $_[1] : $_[0]{current_namespace} }
sub table_types { @_ > 1 ? $_[0]{table_types} = $_[1] : $_[0]{table_types} }


sub compile_file {
	my ($self, $filepath) = @_;

	my $text = read_file($filepath);

	my $syntax = $self->parse($text);
	return $self->compile($syntax);
}




sub strip_string (;$) {
	(@_ ? $_[0] : $_) =~ s/\A"(.*)"\Z/$1/sr
}


sub parse {
	my ($self, $text) = @_;

	my @statements;

	my $lastpos;
	while ($text =~ /\G \s*(
		$regex_file_extension_decl |
		$regex_file_identifier_decl |
		$regex_include |
		$regex_namespace_decl |
		$regex_root_decl |
		$regex_attribute_decl |

		(?<enum_declaration>$regex_enum_decl) |
		(?<type_declaration>$regex_type_decl)
	) \s* /xg) {
		$lastpos = pos $text;
		
		my (
			$file_extension_name,
			$file_identifier_name,
			$include_name,
			$namespace_name,
			$root_name,
			$attribute_name,
			$enum_declaration,
			$type_declaration,
		) = @+{qw/
			file_extension_name
			file_identifier_name
			include_name
			namespace_name
			root_name
			attribute_name
			enum_declaration
			type_declaration
		/};

		if (defined $file_extension_name) {
			$file_extension_name = strip_string $file_extension_name;
			# say "got file extension: $file_extension_name";
			push @statements, { type => 'file_extension_decl', name => $file_extension_name };
		} elsif (defined $file_identifier_name) {
			$file_identifier_name = strip_string $file_identifier_name;
			# say "got file identifier: $file_identifier_name";
			push @statements, { type => 'file_identifier_decl', name => $file_identifier_name };
		} elsif (defined $include_name) {
			$include_name = strip_string $include_name;
			# say "got include: $include_name";
			push @statements, { type => 'include', filepath => $include_name };
		} elsif (defined $namespace_name) {
			# say "got namespace: $namespace_name";
			push @statements, { type => 'namespace_decl', name => $namespace_name };
		} elsif (defined $root_name) {
			# say "got root: $root_name";
			push @statements, { type => 'root_decl', name => $root_name };
		} elsif (defined $attribute_name) {
			$attribute_name = strip_string $attribute_name;
			# say "got attribute: $attribute_name";
			push @statements, { type => 'attribute_decl', name => $attribute_name };
		} elsif (defined $enum_declaration) {
			# say "got enum_declaration: $enum_declaration";
			# push @statements, { type => 'attribute_decl', name => $attribute_name };
			...
		} elsif (defined $type_declaration) {
			# say "got type_declaration: $type_declaration";
			my $type = $self->parse_type_decl($type_declaration);
			push @statements, { type => 'type_decl', struct => $type };
		} else {
			...
		}
	}

	if ($lastpos != length $text) {
		warn "failed to parse file!!!!!!!!!!!!!!!!!!!!!!";
		warn "error at file position $lastpos:\n";
		warn substr $text, $lastpos, 100;
		die "failed to parse file";
	}

	return \@statements
}


sub parse_type_decl {
	my ($self, $text) = @_;
	

	$text =~ /\A(?<type_type> table | struct )\s+(?<type_name>$regex_ident)\s+(?<type_meta>$regex_metadata)\s*\{\s* /gx or die "not a type decl: $text";
	my ($type_type, $type_name, $type_meta) = @+{qw/ type_type type_name type_meta /};

	my %type_decl;
	$type_decl{type} = $type_type;
	$type_decl{name} = $type_name;
	$type_decl{meta} = $self->parse_metadata($type_meta) if $type_meta ne '';

	my @fields;
	while ($text =~ /\G 
		(?<field_name> $regex_ident)\s*:\s*(?<field_type> $regex_type)\s*(=\s*(?<default_value> $regex_scalar)\s*)? (?<field_meta> $regex_metadata)\s*;\s*
		|(?<end_decl> \}\s*\Z)
		/gx) {
		my ($field_name, $field_type, $default_value, $field_meta, $end_decl) = @+{qw/ field_name field_type default_value field_meta end_decl /};
		last if defined $end_decl;
		# say "\tgot field: $field_name, $field_type";
		# say "\t\tdefault value: $default_value" if defined $default_value;
		# say "\t\tmeta: $field_meta" if defined $field_meta and $field_meta ne '';
		my $field = {
			name => $field_name,
			type => $field_type,
		};
		$field->{default} = $default_value if defined $default_value;
		$field->{meta} = $self->parse_metadata($field_meta) if defined $field_meta and $field_meta ne '';
		$field->{length} = $self->get_type_length($field->{type});
		push @fields, $field;
	}
	$type_decl{fields} = \@fields;

	die "invalid type declaration: $text" if pos $text != length $text;

	return \%type_decl
}


sub parse_metadata {
	my ($self, $text) = @_;

	$text =~ /\A\s*\(\s*/g or die "not metadata: $text";

	my @metadata;
	while ($text =~ /\G (?<name> $regex_ident) (\s*:\s*(?<value> $regex_single_value) )? \s*(?<more>,\s*)? /gx) {
		my ($name, $value, $more) = @+{qw/ name value more /};
		my $meta = { name => $name };
		$meta->{value} = $value if defined $value;
		push @metadata, $meta;
		last unless defined $more;
	}

	$text =~ /\)\s*\Z/g or die "invalid metadata: $text";

	return \@metadata
}


sub calculate_struct_length {
	my ($self, $struct) = @_;

	die "recursive struct" if defined $struct->{is_calculating_length};
	$struct->{is_calculating_length} = 1;

	my $length = 0;
	for my $field (@{$struct->{fields}}) {
		my $type = $field->{type};
		if ($self->is_basic_type($type)) {
			$length += $field->{length};
		} elsif ($self->is_string_type($type)) {
			$length += 4;
		} elsif ($self->is_array_type($type)) {
			$length += 4;
		} else {
			my $table_type = $self->get_object_type($type);
			if ($table_type->{type} eq 'table') {
				$length += 4;
			} elsif ($table_type->{type} eq 'struct') {
				$self->calculate_struct_length($table_type) unless defined $table_type->{struct_length};
				$length += $table_type->{struct_length};
			} else {
				...
			}
		}
	}

	$struct->{struct_length} = $length;
	$struct->{is_calculating_length} = undef;
}


sub compile {
	my ($self, $code) = @_;

	# my $current_namespace;
	my $root_type;

	my %parsed_types;

	# parse statements
	for my $statement (@$code) {
		if ($statement->{type} eq 'namespace_decl') {
			# set a new current namespace
			$self->current_namespace($statement->{name} =~ s/\./::/gr);

		} elsif ($statement->{type} eq 'type_decl') {
			# get the top name with appropriate namespacing
			my $typename = $statement->{struct}{name};
			$typename = $self->current_namespace ."::$typename" if defined $self->current_namespace;
			$typename = $self->toplevel_namespace . "::$typename" if defined $self->toplevel_namespace;

			$statement->{struct}{typename} = $typename;
			$parsed_types{$statement->{struct}{name}} = $statement->{struct};

		} elsif ($statement->{type} eq 'root_decl') {
			# set the root object type
			my $typename = $statement->{name};
			$typename = $self->current_namespace ."::$typename" if defined $self->current_namespace;
			$typename = $self->toplevel_namespace . "::$typename" if defined $self->toplevel_namespace;

			die "error: multiple root type declarations: '$root_type' and $typename" if defined $root_type;
			$root_type = $typename
		}
	}


	$self->table_types(\%parsed_types);
	
	# parse the size of structs
	for my $table_type (grep $_->{type} eq 'struct', values %{$self->table_types}) {
		$self->calculate_struct_length($table_type);
	}


	# compile the tables and structs
	my @compiled_types;
	for my $table_type (values %{$self->table_types}) {
		# compile and add it to the compiled types list
		if ($table_type->{type} eq 'table') {
			push @compiled_types, $self->compile_table_type($table_type);
		} elsif ($table_type->{type} eq 'struct') {
			push @compiled_types, $self->compile_struct_type($table_type);
		} else {
			...
		}
	}

	return $root_type, \@compiled_types
}



sub get_type_length {
	my ($self, $type) = @_;
	if ($type eq 'bool' or $type eq 'byte' or $type eq 'ubyte') {
		return 1
	} elsif ($type eq 'short' or $type eq 'ushort') {
		return 2
	} elsif ($type eq 'int' or $type eq 'uint' or $type eq 'float') {
		return 4
	} elsif ($type eq 'long' or $type eq 'ulong' or $type eq 'double') {
		return 8
	} else {
		return 4
	}
}

sub is_basic_type {
	my ($self, $type) = @_;
	return exists $flatbuffers_basic_types{$type}
	# return any { $type eq $_ } qw/
	# 	bool byte ubyte
	# 	short ushort
	# 	int uint float
	# 	long ulong double
	# /
}

sub is_string_type {
	my ($self, $type) = @_;
	return $type eq 'string'
}

sub is_array_type {
	my ($self, $type) = @_;
	return $type =~ /\A\[/
}

sub is_object_array_type {
	my ($self, $type) = @_;
	if ($self->is_basic_type($type) or $self->is_string_type($type)) { # if its a basic type or string type, then no
		return
	} elsif ($self->is_array_type($type)) { # if its an array, strip the brackets and recurse
		return $self->is_object_array_type($self->strip_array_brackets($type))
	} else { # if its an object, return the object typename
		return $type
	}
}

sub get_object_type {
	my ($self, $type) = @_;
	return $self->table_types->{$type} // die "no such type found: $type";
}

sub translate_object_type {
	my ($self, $type) = @_;
	if ($self->is_array_type($type)) {
		return '[' . $self->translate_object_type($self->strip_array_brackets($type)) . ']';
	} else {
		return $self->get_object_type($type)->{typename};
	}
}

sub strip_array_brackets {
	my ($self, $type) = @_;
	return $type =~ s/\A\[(.*)\]\Z/$1/sr
}

sub compile_table_type {
	my ($self, $data) = @_;
	
	# code header
	my $code = "package $data->{typename};
# table package auto-generated by FlatBuffers
use strict;
use warnings;
";
	# new method preamble
	$code .= '
sub new {
	my $class = shift;
	my %args = @_;
	my $self = bless {}, $class;

';
	# setting all fields from args
	for my $field (@{$data->{fields}}) {
		my $type = $field->{type};
		if ($self->is_basic_type($type) or $self->is_string_type($type)) {
			$code .= "\t\$self->$field->{name}(\$args{$field->{name}}) if exists \$args{$field->{name}};\n";
		} elsif ($self->is_array_type($type)) {
			if ($self->is_object_array_type($type)) {
				$type = $self->translate_object_type($type);

				... unless $type =~ /\A(\[+)/;
				my $nest_levels = length $1;

				my $true_type = $type;
				$true_type = $self->strip_array_brackets($true_type) for 1 .. $nest_levels;

				$code .= "\t\$self->$field->{name}(\n";
				$code .= "\t\t". "[ map { " x $nest_levels;

				$code .= "\n\t\t\t$true_type->new(\%\$_)\n";

				$code .= "\t\t". " } \@\$_ ] " x ($nest_levels - 1);
				$code .= "} \@{\$args{$field->{name}}} ]\n\t) if exists \$args{$field->{name}};\n";

			} else {
				$code .= "\t\$self->$field->{name}(\$args{$field->{name}}) if exists \$args{$field->{name}};\n";
			}
		} else {
			my $table_type = $self->get_object_type($type);
			my $typename = $table_type->{typename};
			$code .= "\t\$self->$field->{name}($typename->new(%{\$args{$field->{name}}})) if exists \$args{$field->{name}};\n";
		}
	}

	# new method closing
	$code .= '
	return $self;
}
';

	# type definition
	$code .= "
sub flatbuffers_type { '$data->{type}' }
";

	# field getter/setter functions
	for my $field (@{$data->{fields}}) {
		$code .= "sub $field->{name} { \@_ > 1 ? \$_[0]{$field->{name}} = \$_[1] : \$_[0]{$field->{name}} }\n";
	}

	my $vtable_item_count = 2 + scalar @{$data->{fields}};


	# deserialize function
	$code .= '
sub deserialize {
	my ($self, $data, $offset) = @_;
	$offset //= 0;
	$self = $self->new unless ref $self;

	my $object_offset = $offset + unpack "L<", substr $data, $offset, 4;
	my $vtable_offset = $object_offset - unpack "l<", substr $data, $object_offset, 4;

';

	# field data deserializers
	my $vtable_iterator = 4;
	for my $field (@{$data->{fields}}) {
		$code .= "
	\$offset = unpack 'S<', substr \$data, \$vtable_offset + $vtable_iterator, 2;
	if (\$offset != 0) {
		";
		my $type = $field->{type};
		if ($self->is_basic_type($type)) {
			my $type = $flatbuffers_basic_types{$type};
			$code .= "\$self->$field->{name}(unpack '$type->{format}', substr \$data, \$object_offset + \$offset, $type->{length});";

		} elsif ($self->is_string_type($type)) {
			$code .= "\$self->$field->{name}(\$self->deserialize_string(\$data, \$object_offset + \$offset));";

		} elsif ($self->is_array_type($type)) {
			$type = $self->translate_object_type($type) if $self->is_object_array_type($type);
			$code .= "\$self->$field->{name}(\$self->deserialize_array('$type', \$data, \$object_offset + \$offset));";

		} else {
			my $table_type = $self->get_object_type($type);
			my $typename = $table_type->{typename};
			$code .= "\$self->$field->{name}($typename->deserialize(\$data, \$object_offset + \$offset));";
		}
		$code .= "
	}
";
		$vtable_iterator += 2;
	}

	# end of deserialize function
	$code .= '
	return $self
}
';

	$code .= '


sub deserialize_string {
	my ($self, $data, $offset) = @_;

	my $string_offset = $offset + unpack "L<", substr $data, $offset, 4; # dereference the string pointer
	my $string_length = unpack "L<", substr $data, $string_offset, 4; # get the length
	return substr $data, $string_offset + 4, $string_length # return a substring
}



my %basic_types = (
	bool => { format => "C", length => 1 },
	byte => { format => "c", length => 1 },
	ubyte => { format => "C", length => 1 },
	short => { format => "s<", length => 2 },
	ushort => { format => "S<", length => 2 },
	int => { format => "l<", length => 4 },
	uint => { format => "L<", length => 4 },
	float => { format => "f<", length => 4 },
	long => { format => "q<", length => 8 },
	ulong => { format => "Q<", length => 8 },
	double => { format => "d<", length => 8 },
);

sub is_array_type {
	my ($self, $type) = @_;
	return $type =~ /\A\[/
}

sub strip_array_brackets {
	my ($self, $type) = @_;
	return $type =~ s/\A\[(.*)\]\Z/$1/sr
}

sub deserialize_array {
	my ($self, $array_type, $data, $offset) = @_;

	$array_type = $self->strip_array_brackets($array_type);

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

	} elsif ($self->is_array_type($array_type)) { # if its an array of strings
		@array = map { $self->deserialize_array($array_type, $data, $offset + $_) }
			map $_ * 4,
			0 .. ($array_length - 1);
	
	} else { # if its an array of objects
		if ($array_type->flatbuffers_type eq "table") {
			@array = map { $array_type->deserialize($data, $offset + $_) }
				map $_ * 4,
				0 .. ($array_length - 1);
		} elsif ($array_type->flatbuffers_type eq "struct") {
			my $length = $array_type->struct_length;
			@array = map { $array_type->deserialize($data, $offset + $_) }
				map $_ * $length,
				0 .. ($array_length - 1);
		} else {
			...
		}
	}

	return \@array
}

';


	# serialize function
	$code .= '
sub serialize {
	my ($self) = @_;

	my @parts = $self->serialize_data;
	my $root = $parts[0]; # get the root data structure

	# header pointer to root data structure
	unshift @parts, { type => "header", data => "\0\0\0\0", reloc => [{ offset => 0, item => $root, type => "unsigned delta" }] };

	my $data = "";
	my $offset = 0;

	# concatentate the data
	for my $part (@parts) {
		$part->{serialized_offset} = $offset;
		$data .= $part->{data};
		$offset += length $part->{data};
	}

	# second pass for writing offsets to other parts
	for my $part (@parts) {
		if (defined $part->{reloc}) {
			# perform address relocation
			for my $reloc (@{$part->{reloc}}) {
				my $value;
				if (defined $reloc->{lambda}) { # allow the reloc to have a custom format
					$value = $reloc->{lambda}($part, $reloc);
				} elsif (defined $reloc->{type} and $reloc->{type} eq "unsigned delta") {
					$value = pack "L<", $reloc->{item}{serialized_offset} - $part->{serialized_offset} - $reloc->{offset};
				} elsif (defined $reloc->{type} and $reloc->{type} eq "signed negative delta") {
					$value = pack "l<", $part->{serialized_offset} + $reloc->{offset} - $reloc->{item}{serialized_offset};
				} else {
					...
				}
				substr $data, $part->{serialized_offset} + $reloc->{offset}, length($value), $value;
			}
		}
	}

	# done, the data is now ready to be deserialized
	return $data
}
';

	# serialize_vtable header
	$code .= '
sub serialize_vtable {
	my ($self) = @_;

	my @data;
	my $offset = 4;
';

	# field offset serializers
	for my $field (@{$data->{fields}}) {
		my $type = $field->{type};
		if ($self->is_basic_type($type) or $self->is_string_type($type) or $self->is_array_type($type)) {
			$code .= "
	if (defined \$self->$field->{name}) {
		push \@data, \$offset;
		\$offset += $field->{length};
	} else {
		push \@data, 0;
	}
";
		} else {
			my $table_type = $self->get_object_type($type);
			if ($table_type->{type} eq 'table') {
			$code .= "
	if (defined \$self->$field->{name}) {
		push \@data, \$offset;
		\$offset += $field->{length};
	} else {
		push \@data, 0;
	}
";
			} elsif ($table_type->{type} eq 'struct') {
			$code .= "
	if (defined \$self->$field->{name}) {
		push \@data, \$offset;
		\$offset += $table_type->{typename}->struct_length;
	} else {
		push \@data, 0;
	}
";
			} else {
				...
			}
		}
	}

	$code .= "
	push \@data, 0; # pad to 4 byte boundary
" if @{$data->{fields}} % 2; # add padding code if there is an odd field count

	# serialize_vtable footer
	$code .= "

	unshift \@data, \$offset;
	unshift \@data, 2 * $vtable_item_count;

	return { type => 'vtable', data => pack 'S<' x \@data, \@data }
}
";


	# serialize_data header
	$code .= '
sub serialize_data {
	my ($self) = @_;

	my $vtable = $self->serialize_vtable;
	my $data = "\0\0\0\0";

	# my $data_object = { type => "table" };

	my @reloc = ({ offset => 0, item => $vtable, type => "signed negative delta" });
	# flatbuffers vtable offset is stored in negative form
	my @objects = ($vtable);

	# $offset += 4;

';




	# field data serializers
	for my $field (@{$data->{fields}}) {
		$code .= "
	if (defined \$self->$field->{name}) {
		";
		my $type = $field->{type};
		if ($self->is_basic_type($type)) {
			$code .= "\$data .= pack '$flatbuffers_basic_types{$type}{format}', \$self->$field->{name};";

		} elsif ($self->is_string_type($type)) {
			$code .= qq/my \$string_object = \$self->serialize_string(\$self->$field->{name});
		push \@objects, \$string_object;
		push \@reloc, { offset => length (\$data), item => \$string_object, type => 'unsigned delta'};
		\$data .= \"\\0\\0\\0\\0\";/;

		} elsif ($self->is_array_type($type)) {
			my $type = $type;
			$type = $self->translate_object_type($type) if $self->is_object_array_type($type);
			$code .= qq/my (\$array_object, \@array_objects) = \$self->serialize_array('$type', \$self->$field->{name});
		push \@objects, \$array_object, \@array_objects;
		push \@reloc, { offset => length (\$data), item => \$array_object, type => 'unsigned delta'};
		\$data .= \"\\0\\0\\0\\0\";/;

		} else { # table serialization
			my $table_type = $self->get_object_type($type);
			
			if ($table_type->{type} eq 'table') {
				$code .= qq/my (\$root_object, \@table_objects) = \$self->$field->{name}->serialize_data;
		push \@objects, \$root_object, \@table_objects;
		push \@reloc, { offset => length (\$data), item => \$root_object, type => 'unsigned delta' };
		\$data .= \"\\0\\0\\0\\0\";/;
			} elsif ($table_type->{type} eq 'struct') {
				$code .= qq/my (\$root_object, \@struct_objects) = \$self->$field->{name}->serialize_data;
		push \@objects, \@struct_objects;
		push \@reloc, map { \$_->{offset} += length (\$data); \$_ } \@{\$root_object->{reloc}};
		\$data .= \$root_object->{data};/;
			} else {
				...
			}
		}
		$code .= "
	}
";
	}

	# end of serialize_data
	$code .= '
	# pad to 4 byte boundary
	$data .= pack "x" x (4 - (length ($data) % 4)) if length ($data) % 4;

	# $data_object->{data} = $data;
	# $data_object->{reloc} = \@reloc;
	# return table data and other objects that we\'ve created
	return { type => "table", data => $data, reloc => \@reloc }, @objects
}
	';


	$code .= '
sub serialize_string {
	my ($self, $string) = @_;

	my $len = pack "L<", length $string;
	$string .= "\0"; # null termination byte because why the fuck not (it\'s part of flatbuffers)

	my $data = "$len$string";
	$data .= pack "x" x (4 - (length ($data) % 4)) if length ($data) % 4; # pad to 4 byte boundary

	return { type => "string", data => $data }
}


sub serialize_array {
	my ($self, $array_type, $array) = @_;

	$array_type = $self->strip_array_brackets($array_type);

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
	} elsif ($self->is_array_type($array_type)) { # array of arrays
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

';

	# package footer
	$code .= "

1 # true return from package

";

	return { type => $data->{struct}{type}, package_name => $data->{typename}, code => $code }
}




sub compile_struct_type {
	my ($self, $data) = @_;

	# code header
	my $code = "package $data->{typename};
# struct package auto-generated by FlatBuffers
use strict;
use warnings;
";
	# new method preamble
	$code .= '
sub new {
	my $class = shift;
	my %args = @_;
	my $self = bless {}, $class;

';
	# setting all fields from args
	for my $field (@{$data->{fields}}) {
		my $type = $field->{type};
		if ($self->is_basic_type($type)) {
			$code .= "\t\$self->$field->{name}(\$args{$field->{name}});\n";
		} elsif ($self->is_string_type($type)) {
			$code .= "\t\$self->$field->{name}(\$args{$field->{name}});\n";
		} elsif ($self->is_array_type($type)) {
			# $code .= "\t\$self->$field->{name}(\$args{$field->{name}});\n";
			if ($self->is_object_array_type($type)) {
				my $type = $self->translate_object_type($type);

				... unless $type =~ /\A(\[+)/;
				my $nest_levels = length $1;

				my $true_type = $type;
				$true_type = $self->strip_array_brackets($true_type) for 1 .. $nest_levels;

				$code .= "\t\$self->$field->{name}(\n";
				$code .= "\t\t". "[ map { " x $nest_levels;

				$code .= "\n\t\t\t$true_type->new(\%\$_)\n";

				$code .= "\t\t". " } \@\$_ ] " x ($nest_levels - 1);
				$code .= "} \@{\$args{$field->{name}}} ]\n\t);\n";

			} else {
				$code .= "\t\$self->$field->{name}(\$args{$field->{name}});\n";
			}
		} else {
			my $table_type = $self->get_object_type($type);
			my $typename = $table_type->{typename};
			$code .= "\t\$self->$field->{name}($typename->new(%{\$args{$field->{name}}}));\n";
		}
	}

	# new method closing
	$code .= '
	return $self;
}
';

	# type definition
	$code .= "
sub flatbuffers_type { '$data->{type}' }
";

	# field getter/setter functions
	for my $field (@{$data->{fields}}) {
		$code .= "sub $field->{name} { \@_ > 1 ? \$_[0]{$field->{name}} = \$_[1] : \$_[0]{$field->{name}} }\n";
	}






	# deserialize function
	$code .= '
sub deserialize {
	my ($self, $data, $offset) = @_;
	$offset //= 0;
	$self = $self->new unless ref $self;
';
	my $offset = 0;

	# field data deserializers
	for my $field (@{$data->{fields}}) {
		$code .= "
	";
		my $type = $field->{type};
		if ($self->is_basic_type($type)) {
			my $type = $flatbuffers_basic_types{$type};
			$code .= "\$self->$field->{name}(unpack '$type->{format}', substr \$data, \$offset + $offset, $type->{length});";

		} elsif ($self->is_string_type($type)) {
			$code .= "\$self->$field->{name}(\$self->deserialize_string(\$data, \$offset + $offset));";
		} elsif ($self->is_array_type($type)) {
			$type = $self->translate_object_type($type) if $self->is_object_array_type($type);
			$code .= "\$self->$field->{name}(\$self->deserialize_array('$type', \$data, \$offset + $offset));";

		} else {
			my $table_type = $self->get_object_type($type);
			my $typename = $table_type->{typename};
			$code .= "\$self->$field->{name}($typename->deserialize(\$data, \$offset + $offset));";
			$offset += $table_type->{struct_length} - 4 if $table_type->{type} eq 'struct';
		}
		$offset += $field->{length};
	}

	# end of deserialize function
	$code .= '

	return $self
}
';

	$code .= '

sub deserialize_string {
	my ($self, $data, $offset) = @_;

	my $string_offset = $offset + unpack "L<", substr $data, $offset, 4; # dereference the string pointer
	my $string_length = unpack "L<", substr $data, $string_offset, 4; # get the length
	return substr $data, $string_offset + 4, $string_length # return a substring
}



my %basic_types = (
	bool => { format => "C", length => 1 },
	byte => { format => "c", length => 1 },
	ubyte => { format => "C", length => 1 },
	short => { format => "s<", length => 2 },
	ushort => { format => "S<", length => 2 },
	int => { format => "l<", length => 4 },
	uint => { format => "L<", length => 4 },
	float => { format => "f<", length => 4 },
	long => { format => "q<", length => 8 },
	ulong => { format => "Q<", length => 8 },
	double => { format => "d<", length => 8 },
);

sub is_array_type {
	my ($self, $type) = @_;
	return $type =~ /\A\[/
}

sub strip_array_brackets {
	my ($self, $type) = @_;
	return $type =~ s/\A\[(.*)\]\Z/$1/sr
}

sub deserialize_array {
	my ($self, $array_type, $data, $offset) = @_;

	$array_type = $self->strip_array_brackets($array_type);

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

	} elsif ($self->is_array_type($array_type)) { # if its an array of strings
		@array = map { $self->deserialize_array($array_type, $data, $offset + $_) }
			map $_ * 4,
			0 .. ($array_length - 1);
	
	} else { # if its an array of objects
		if ($array_type->flatbuffers_type eq "table") {
			@array = map { $array_type->deserialize($data, $offset + $_) }
				map $_ * 4,
				0 .. ($array_length - 1);
		} elsif ($array_type->flatbuffers_type eq "struct") {
			my $length = $array_type->struct_length;
			@array = map { $array_type->deserialize($data, $offset + $_) }
				map $_ * $length,
				0 .. ($array_length - 1);
		} else {
			...
		}
	}

	return \@array
}

';


	# serialize_data header
	$code .= '
sub serialize_data {
	my ($self) = @_;

	my $data = "";
	my @reloc;

	my @objects;

';



	# field data serializers
	for my $field (@{$data->{fields}}) {
		$code .= "
	";
		my $type = $field->{type};
		if ($self->is_basic_type($type)) {
			my $type = $flatbuffers_basic_types{$type};
			$code .= "\$data .= pack '$type->{format}', \$self->$field->{name} // die 'struct $data->{typename} requires field $field->{name}';";

		} elsif ($self->is_string_type($type)) {
			$code .= qq/do {
			my \$string_object = \$self->serialize_string(\$self->$field->{name});
			push \@objects, \$string_object;
			push \@reloc, { offset => length (\$data), item => \$string_object, type => 'unsigned delta'};
			\$data .= \"\\0\\0\\0\\0\";
		};/;

		} elsif ($self->is_array_type($type)) {
			$type = $self->translate_object_type($type) if $self->is_object_array_type($type);
			$code .= qq/do {
			my (\$array_object, \@array_objects) = \$self->serialize_array('$type', \$self->$field->{name});
			push \@objects, \$array_object, \@array_objects;
			push \@reloc, { offset => length (\$data), item => \$array_object, type => 'unsigned delta'};
			\$data .= \"\\0\\0\\0\\0\";
		};/;

		} else { # table serialization
			my $table_type = $self->get_object_type($type);
			
			if ($table_type->{type} eq 'table') {
				$code .= qq/do {
			my (\$root_object, \@table_objects) = \$self->$field->{name}->serialize_data;
			push \@objects, \$root_object, \@table_objects;
			push \@reloc, { offset => length (\$data), item => \$root_object, type => 'unsigned delta' };
			\$data .= \"\\0\\0\\0\\0\";
		};/;

			} elsif ($table_type->{type} eq 'struct') {
				$code .= qq/do {
			my (\$root_object, \@struct_objects) = \$self->$field->{name}->serialize_data;
			push \@objects, \@struct_objects;
			push \@reloc, map { \$_->{offset} += length (\$data); \$_ } \@{\$root_object->{reloc}};
			\$data .= \$root_object->{data};
		};/;

			} else {
				...
			}
		}
	}

	# end of serialize_data
	$code .= '


	# pad to 4 byte boundary
	$data .= pack "x" x (4 - (length ($data) % 4)) if length ($data) % 4;

	# return struct data and other objects that we\'ve created
	return { type => "struct", data => $data, reloc => \@reloc }, @objects
}
	';



	# struct length constant
	$code .= "

sub struct_length { $offset }

";


	$code .= '
sub serialize_string {
	my ($self, $string) = @_;

	my $len = pack "L<", length $string;
	$string .= "\0"; # null termination byte because why the fuck not (it\'s part of flatbuffers)

	my $data = "$len$string";
	$data .= pack "x" x (4 - (length ($data) % 4)) if length ($data) % 4; # pad to 4 byte boundary

	return { type => "string", data => $data }
}




sub serialize_array {
	my ($self, $array_type, $array) = @_;

	$array_type = $self->strip_array_brackets($array_type);

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
	} elsif ($self->is_array_type($array_type)) { # array of arrays
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
';


	# package footer
	$code .= "

1 # true return from package

";

	return { type => $data->{struct}{type}, package_name => $data->{typename}, code => $code }
}



# load packages from compiled packages
sub load_perl_packages {
	my ($self, $compiled) = @_;

	for my $file (@$compiled) {
		# say "compiled file: $file->{code}";
		eval $file->{code};
		if ($@) {
			die "compiled table died [$file->{package_name}]: $@";
		}
	}
}



# creates files from compiled packages
sub create_perl_packages {
	my ($self, $compiled) = @_;

	for my $file (@$compiled) {
		my @path = split '::', $file->{package_name};
		for my $path_length (0 .. $#path - 1) {
			mkdir join '/', @path[0 .. $path_length];
		}
		write_file(join ('/', @path) . '.pm', $file->{code});
	}
}

sub main {
	for my $filepath (@_) {
		FlatBuffers->create_packages($filepath);
	}
}

caller or main(@ARGV)

