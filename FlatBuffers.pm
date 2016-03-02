#!/usr/bin/env perl
package FlatBuffers;
use strict;
use warnings;

use feature 'say';

use File::Slurp qw/ read_file write_file /;
use Data::Dumper;


# little-endian everything
# they're not even buffers ffs, a better name would've been flatpack


# TODO:
	# perl file creating
	# transparent package creation
	# anonymous package creation
	# source filter for transparent creation











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



sub new {
	my $class = shift;
	my %args = @_;
	my $self = bless {}, $class;

	$self->toplevel_namespace($args{toplevel_namespace});

	return $self
}

sub toplevel_namespace { @_ > 1 ? $_[0]{toplevel_namespace} = $_[1] : $_[0]{toplevel_namespace} }


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


sub compile {
	my ($self, $code) = @_;

	my $current_namespace;
	my $root_type;

	my @compiled_types;

	for my $statement (@$code) {
		if ($statement->{type} eq 'namespace_decl') {
			# set a new current namespace
			$current_namespace = $statement->{name} =~ s/\./::/gr;

		} elsif ($statement->{type} eq 'type_decl') {
			# get the top name with appropriate namespacing
			my $typename = $statement->{struct}{name};
			$typename = "${current_namespace}::$typename" if defined $current_namespace;
			$typename = $self->toplevel_namespace . "::$typename" if defined $self->toplevel_namespace;

			# compile and add it to the compiled types list
			push @compiled_types, $self->compile_type($statement->{struct}, $typename);

		} elsif ($statement->{type} eq 'root_decl') {
			# set the root object type
			my $typename = $statement->{name};
			$typename = "${current_namespace}::$typename" if defined $current_namespace;
			$typename = $self->toplevel_namespace . "::$typename" if defined $self->toplevel_namespace;

			die "error: multiple root type declarations: '$root_type' and $typename" if defined $root_type;
			$root_type = $typename
		}
	}

	return $root_type, \@compiled_types
}

# bool | byte | ubyte | short | ushort | int | uint | float | long | ulong | double | string | \[\s*(?&regex_type_recurse)\s*\] | $regex_ident ) /x;

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

sub compile_type {
	my ($self, $data, $typename) = @_;
	
	# code header
	my $code = "package $typename;
# package auto-generated by FlatBuffers
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
		$code .= "\t\$self->$field->{name}(\$args{$field->{name}});\n";
	}

	# new method closing
	$code .= '
	return $self;
}
';

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
		if ($field->{type} eq 'bool') {
			$code .= "\$self->$field->{name}(unpack 'C', substr \$data, \$object_offset + \$offset, 1);";
		} elsif ($field->{type} eq 'byte') {
			$code .= "\$self->$field->{name}(unpack 'c', substr \$data, \$object_offset + \$offset, 1);";
		} elsif ($field->{type} eq 'ubyte') {
			$code .= "\$self->$field->{name}(unpack 'C', substr \$data, \$object_offset + \$offset, 1);";
		} elsif ($field->{type} eq 'short') {
			$code .= "\$self->$field->{name}(unpack 's<', substr \$data, \$object_offset + \$offset, 2);";
		} elsif ($field->{type} eq 'ushort') {
			$code .= "\$self->$field->{name}(unpack 'S<', substr \$data, \$object_offset + \$offset, 2);";
		} elsif ($field->{type} eq 'int') {
			$code .= "\$self->$field->{name}(unpack 'l<', substr \$data, \$object_offset + \$offset, 4);";
		} elsif ($field->{type} eq 'uint') {
			$code .= "\$self->$field->{name}(unpack 'L<', substr \$data, \$object_offset + \$offset, 4);";
		} elsif ($field->{type} eq 'float') {
			$code .= "\$self->$field->{name}(unpack 'f<', substr \$data, \$object_offset + \$offset, 4);";
		} elsif ($field->{type} eq 'long') {
			$code .= "\$self->$field->{name}(unpack 'q<', substr \$data, \$object_offset + \$offset, 8);";
		} elsif ($field->{type} eq 'ulong') {
			$code .= "\$self->$field->{name}(unpack 'Q<', substr \$data, \$object_offset + \$offset, 8);";
		} elsif ($field->{type} eq 'double') {
			$code .= "\$self->$field->{name}(unpack 'd<', substr \$data, \$object_offset + \$offset, 8);";
		} elsif ($field->{type} eq 'string') {
			$code .= 'my $string_offset = $object_offset + $offset + unpack "L<", substr $data, $object_offset + $offset, 4;
		my $string_length = unpack "L<", substr $data, $string_offset, 4;';
			$code .= "
		\$self->$field->{name}(substr \$data, \$string_offset + 4, \$string_length);";
		} else {
			...
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


	# serialize function
	$code .= '
sub serialize {
	my ($self) = @_;

	my @parts = $self->serialize_data;
	my $root = $parts[0]; # get the root data structure

	# header pointer to root data structure
	unshift @parts, { type => "header", data => "\0\0\0\0", reloc => [{ offset => 0, item => $root }] };

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
				my $value = $reloc->{item}{serialized_offset};
				if (defined $reloc->{lambda}) { # allow the reloc to have a custom format
					$value = $reloc->{lambda}($value);
				} else {
					$value = pack "l<", $value;
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
		$code .= "
	if (defined \$self->$field->{name}) {
		push \@data, \$offset;
		\$offset += $field->{length};
	} else {
		push \@data, 0;
	}
";
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
	my $offset = 0;

	my $data_object = { type => "table" };

	my @reloc = ({ offset => $offset, item => $vtable, lambda => sub { pack "l<", $data_object->{serialized_offset} - $_[0] } });
	# flatbuffers vtable offset is stored in negative form
	my @objects = ($vtable);

	$offset += 4;

';




	# field data serializers
	for my $field (@{$data->{fields}}) {
		$code .= "
	if (defined \$self->$field->{name}) {
		";
		if ($field->{type} eq 'bool') {
			$code .= "\$data .= pack 'C', \$self->$field->{name};";
		} elsif ($field->{type} eq 'byte') {
			$code .= "\$data .= pack 'c', \$self->$field->{name};";
		} elsif ($field->{type} eq 'ubyte') {
			$code .= "\$data .= pack 'C', \$self->$field->{name};";
		} elsif ($field->{type} eq 'short') {
			$code .= "\$data .= pack 's<', \$self->$field->{name};";
		} elsif ($field->{type} eq 'ushort') {
			$code .= "\$data .= pack 'S<', \$self->$field->{name};";
		} elsif ($field->{type} eq 'int') {
			$code .= "\$data .= pack 'l<', \$self->$field->{name};";
		} elsif ($field->{type} eq 'uint') {
			$code .= "\$data .= pack 'L<', \$self->$field->{name};";
		} elsif ($field->{type} eq 'float') {
			$code .= "\$data .= pack 'f<', \$self->$field->{name};";
		} elsif ($field->{type} eq 'long') {
			$code .= "\$data .= pack 'q<', \$self->$field->{name};";
		} elsif ($field->{type} eq 'ulong') {
			$code .= "\$data .= pack 'Q<', \$self->$field->{name};";
		} elsif ($field->{type} eq 'double') {
			$code .= "\$data .= pack 'd<', \$self->$field->{name};";
		} elsif ($field->{type} eq 'string') {
			$code .= '$data .= "\0\0\0\0";';
			$code .= "
		my \$string_object = \$self->serialize_string(\$self->$field->{name});
		push \@objects, \$string_object;
		my \$closured_offset = \$offset; # necessary, otherwise a changed offset will be closured
		push \@reloc, { offset => \$offset, item => \$string_object, lambda => sub { pack 'L<', \$_[0] - \$data_object->{serialized_offset} - \$closured_offset } };";
		} else {
			...
		}
		$code .= "
		\$offset += $field->{length};
	}
";
	}

	# end of serialize_data
	$code .= '
	# pad to 4 byte boundary
	$data .= pack "x" x (4 - (length ($data) % 4)) if length ($data) % 4;

	$data_object->{data} = $data;
	$data_object->{reloc} = \@reloc;
	# return table data and other objects that we\'ve created
	return $data_object, @objects
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
';

	# package footer
	$code .= "

1 # true return from package

";

	return { type => $data->{struct}{type}, package_name => $typename, code => $code }
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

