#!/usr/bin/env perl
package Data::FlatTables;
use strict;
use warnings;

use feature 'say';

use File::Slurp qw/ read_file write_file /;
use List::Util qw/ any none /;
use Data::Dumper;



# TODO:
	# anonymous package creation
	# source filter for transparent creation
	# superclass creation instead of self-contained class to prevent code pollution
	# enum support
	# strict flatbuffers-compatible mode
	# default values for strings
	# re-linking objects that have the same data or are the same, during compile time
	# caching compiled objects during compilation










# compiles and loads packages from a given fbs file
# returns the package name of the root object declared in the fbs file (undef if no root object was declared)
sub load {
	my ($self, $filepath) = @_;
	$self = $self->new unless ref $self;
	my $compiled = $self->compile_file($filepath);

	$self->load_perl_packages($compiled->{compiled_types});

	return $compiled->{root_type}
}



# compiles a fbs file and writes perl packages in the current directory
# returns the package name of the root object declared in the fbs file (undef if no root object was declared)
sub create_packages {
	my ($self, $filepath) = @_;
	$self = $self->new unless ref $self;
	my $compiled = $self->compile_file($filepath);

	$self->create_perl_packages($compiled->{compiled_types});
	return $compiled->{root_type}
}













# these weren't defined in the grammar. gj google
my $regex_string_constant = qr/"[^"]*"/xs;
my $regex_ident = qr/[a-zA-Z_][a-zA-Z_\d]*(\.[a-zA-Z_][a-zA-Z_\d]*)*/x;

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






my %flattables_reserved_methods = map { $_ => 1 }
qw/
	new
	flatbuffers_struct_length
	flatbuffers_type
	deserialize
	deserialize_string
	deserialize_array
	serialize
	serialize_vtable
	serialize_data
	serialize_string
	serialize_array
/;




sub new {
	my ($class, %args) = @_;
	my $self = bless {}, $class;

	$self->standalone_packages($args{standalone_packages} // 1);
	$self->toplevel_namespace($args{toplevel_namespace});
	$self->table_types({});

	return $self
}

sub standalone_packages { @_ > 1 ? $_[0]{standalone_packages} = $_[1] : $_[0]{standalone_packages} }
sub toplevel_namespace { @_ > 1 ? $_[0]{toplevel_namespace} = $_[1] : $_[0]{toplevel_namespace} }

sub current_namespace { @_ > 1 ? $_[0]{current_namespace} = $_[1] : $_[0]{current_namespace} }
sub table_types { @_ > 1 ? $_[0]{table_types} = $_[1] : $_[0]{table_types} }


sub compile_file {
	my ($self, $filepath) = @_;

	my $compiler_state = { filepath => $filepath };

	my $text = read_file($filepath);

	my $syntax = $self->parse($compiler_state, $text);
	$self->compile($compiler_state, $syntax);
	return $compiler_state
}




sub strip_string (;$) {
	(@_ ? $_[0] : $_) =~ s/\A"(.*)"\Z/$1/sr
}


sub parse {
	my ($self, $compiler_state, $text) = @_;

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
			push @statements, { type => 'file_extension_decl', name => $file_extension_name };
		} elsif (defined $file_identifier_name) {
			$file_identifier_name = strip_string $file_identifier_name;
			push @statements, { type => 'file_identifier_decl', name => $file_identifier_name };
		} elsif (defined $include_name) {
			$include_name = strip_string $include_name;
			push @statements, { type => 'include', filepath => $include_name };
		} elsif (defined $namespace_name) {
			push @statements, { type => 'namespace_decl', name => $namespace_name };
		} elsif (defined $root_name) {
			push @statements, { type => 'root_decl', name => $root_name };
		} elsif (defined $attribute_name) {
			$attribute_name = strip_string $attribute_name;
			push @statements, { type => 'attribute_decl', name => $attribute_name };
		} elsif (defined $enum_declaration) {
			# push @statements, { type => 'enum_decl', name => $attribute_name };
			...
		} elsif (defined $type_declaration) {
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
		my $field = {
			name => $field_name,
			type => $field_type,
		};
		$field->{default} = $default_value if defined $default_value;
		die "default values are unsupported for anything other than numeric types" if defined $field->{default} and not $self->is_basic_type($field->{type});
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
	my ($self, $compiler_state, $code) = @_;

	$compiler_state->{root_type} = undef;
	$compiler_state->{file_identifier} = undef;

	my %parsed_types;

	my $include_section = 1;

	# interpret the statements
	for my $statement (@$code) {
		$include_section = 0 unless $statement->{type} eq 'include'; # keep track of whether we can make an include

		if ($statement->{type} eq 'include') { # include another file
			die "all includes must come before any other statement" unless $include_section;

			my $filepath = $statement->{filepath};
			$filepath = ($compiler_state->{filepath} =~ s/\A(.*)\/[^\/]*\Z/$1/r) . "/$filepath" unless $filepath =~ /\A\//;

			my $compiled_file = $self->compile_file($filepath) // die "failed to include file $statement->{filepath}";
			$compiler_state->{compiled_types} = [@{$compiler_state->{compiled_types} // []}, @{$compiled_file->{compiled_types}}];

		} elsif ($statement->{type} eq 'namespace_decl') { # set a new current namespace
			$self->current_namespace($statement->{name} =~ s/\./::/gr);

		} elsif ($statement->{type} eq 'type_decl') { # interpret a type declaration
			# get the top name with appropriate namespacing
			my $typename = $statement->{struct}{name} =~ s/\./::/gr;
			$typename = $self->current_namespace ."::$typename" if defined $self->current_namespace;
			$typename = $self->toplevel_namespace . "::$typename" if defined $self->toplevel_namespace;

			$statement->{struct}{typename} = $typename;

			my $named_type = $statement->{struct}{name};
			$named_type = ($self->current_namespace =~ s/::/\./gr) .".$named_type" if defined $self->current_namespace;

			$parsed_types{$named_type} = $statement->{struct};

		} elsif ($statement->{type} eq 'file_identifier_decl') { # set a file identifier stub
			die "file identifier must be 4 characters long" unless 4 == length $statement->{name};
			$compiler_state->{file_identifier} = $statement->{name};

		} elsif ($statement->{type} eq 'root_decl') { # set the root object type
			die "error: multiple root type declarations: '$compiler_state->{root_type}' and $statement->{name}" if defined $compiler_state->{root_type};
			$compiler_state->{root_type} = $statement->{name};
		}
	}

	# say "debug created type $_" for keys %parsed_types;

	# append the new parsed types
	$self->table_types({%{$self->table_types}, %parsed_types});
	
	# parse the root_type declaration to a package name
	$compiler_state->{root_type} = $self->get_object_type($compiler_state->{root_type})->{typename} if defined $compiler_state->{root_type};

	# parse the size of structs
	for my $table_type (grep $_->{type} eq 'struct', values %parsed_types) {
		$self->calculate_struct_length($table_type);
	}

	# parse all types for their dependancies
	for my $table_type (values %parsed_types) {
		for my $field (@{$table_type->{fields}}) {
			if ($self->is_object_type($field->{type})) {
				my $type = $self->translate_object_type($field->{type});
				push @{$table_type->{dependancies}}, $type if none { $type eq $_ } @{$table_type->{dependancies}};
			} elsif ($self->is_object_array_type($field->{type})) {
				my $type = $self->translate_object_type($self->is_object_array_type($field->{type}));
				push @{$table_type->{dependancies}}, $type if none { $type eq $_ } @{$table_type->{dependancies}};
			}
		}
	}


	# compile the tables and structs
	my @compiled_types;
	for my $table_type (values %parsed_types) {
		# compile and add it to the compiled types list
		if ($table_type->{type} eq 'table') {
			push @compiled_types, $self->compile_table_type($compiler_state, $table_type);
		} elsif ($table_type->{type} eq 'struct') {
			push @compiled_types, $self->compile_struct_type($compiler_state, $table_type);
		} else {
			...
		}
	}

	$compiler_state->{compiled_types} = [ @{$compiler_state->{compiled_types} // []}, @compiled_types ];

	return $compiler_state #$compiler_state->{root_type}, \@compiled_types
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

sub is_method_reserved {
	my ($self, $name) = @_;
	return exists $flattables_reserved_methods{$name}
}

sub is_basic_type {
	my ($self, $type) = @_;
	return exists $flatbuffers_basic_types{$type}
}

sub is_string_type {
	my ($self, $type) = @_;
	return $type eq 'string'
}

sub is_array_type {
	my ($self, $type) = @_;
	return $type =~ /\A\[/
}

sub is_object_type {
	my ($self, $type) = @_;
	if ($self->is_basic_type($type) or $self->is_string_type($type) or $self->is_array_type($type)) {
		return 0
	} else {
		return 1
	}
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

	# if a non-namespaced or namespace-referenced type by this name exists, return it
	return $self->table_types->{$type} if defined $self->table_types->{$type};
	die "no such type found: $type" if $type =~ /\./; # make sure there is no namespace prepended yet
	# otherwise a try to prepend the current namespace and find it
	$type = ($self->current_namespace =~ s/::/\./gr) . ".$type";
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
	my ($self, $compiler_state, $data) = @_;
	
	# code header
	my $code = "package $data->{typename};
# table package auto-generated by Data::FlatTables
use strict;
use warnings;
";
	# inject parenthood if we aren't writing standalone packages
	$code .= "
use parent 'Data::FlatTables::Table';
" unless $self->standalone_packages;

	# new method preamble
	$code .= '
sub new {
	my ($class, %args) = @_;
	my $self = bless {}, $class;

';
	# setting all fields from args
	for my $field (@{$data->{fields}}) {
		my $type = $field->{type};
		if ($self->is_basic_type($type)) {
			my $default = int ($field->{default} // 0);
			$code .= "\t\$self->{$field->{name}} = \$args{$field->{name}} if defined \$args{$field->{name}} and \$args{$field->{name}} != $default;\n";
		} elsif ($self->is_string_type($type)) {
			$code .= "\t\$self->{$field->{name}} = \$args{$field->{name}} if defined \$args{$field->{name}};\n";
		} elsif ($self->is_array_type($type)) {
			if ($self->is_object_array_type($type)) {
				$type = $self->translate_object_type($type);

				... unless $type =~ /\A(\[+)/;
				my $nest_levels = length $1;

				my $true_type = $type;
				$true_type = $self->strip_array_brackets($true_type) for 1 .. $nest_levels;

				$code .= "\t\$self->{$field->{name}} = \n";
				$code .= "\t\t". "[ map { " x $nest_levels;

				$code .= "\n\t\t\t$true_type->new(\%\$_)\n";

				$code .= "\t\t". " } \@\$_ ] " x ($nest_levels - 1);
				$code .= "} \@{\$args{$field->{name}}} ]\n\tif exists \$args{$field->{name}};\n";

			} else {
				$code .= "\t\$self->{$field->{name}} = \$args{$field->{name}} if exists \$args{$field->{name}};\n";
			}
		} else {
			my $table_type = $self->get_object_type($type);
			my $typename = $table_type->{typename};
			$code .= "\t\$self->{$field->{name}} = $typename->new(%{\$args{$field->{name}}}) if exists \$args{$field->{name}};\n";
		}
	}

	# new method closing
	$code .= '
	return $self;
}
';

	# type accessor
	$code .= "
sub flatbuffers_type { '$data->{type}' }
";

	# types for serialization
	$code .= "
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
" if $self->standalone_packages;

	# field getter/setter functions
	for my $field (@{$data->{fields}}) {
		if ($self->is_method_reserved($field->{name})) {
			warn "Warning: '$field->{name}' is a reserved name and will not get an getter/setter method";
		} else {
			my $type = $field->{type};
			if ($self->is_basic_type($type)) {
				my $default = int ($field->{default} // 0);
				$code .= "sub $field->{name} { \@_ > 1 ? \$_[0]{$field->{name}} = ( \$_[1] == $default ? undef : \$_[1]) : \$_[0]{$field->{name}} // $default }\n";

			} elsif ($self->is_object_type($type)) {
				my $table_type = $self->get_object_type($type);
				my $typename = $table_type->{typename};
				$code .= "sub $field->{name} {
	my (\$self, \$val) = \@_;
	\$val = $typename->new(\%\$val) if defined \$val and not UNIVERSAL::can(\$val, 'can'); # bless it if not yet blessed
	return \@_ > 1 ? \$self->{$field->{name}} = \$val : \$self->{$field->{name}};
}
";
			} elsif ($self->is_object_array_type($type)) {
				$type = $self->translate_object_type($type);

				... unless $type =~ /\A(\[+)/;
				my $nest_levels = length $1;

				my $true_type = $type;
				$true_type = $self->strip_array_brackets($true_type) for 1 .. $nest_levels;

				$code .= "sub $field->{name} { 
	\@_ > 1 ? \$_[0]{$field->{name}} = 
";
				$code .= "\t\t". "[ map { " x $nest_levels;

				$code .= "\n\t\t\t(ref and not UNIVERSAL::can(\$_, 'can')) ? $true_type->new(\%\$_) : \$_\n";

				$code .= "\t\t". " } \@\$_ ] " x ($nest_levels - 1);
				$code .= "} \@{\$_[1]} ]\n\t : \$_[0]{$field->{name}}
}\n";

			} else {
				$code .= "sub $field->{name} { \@_ > 1 ? \$_[0]{$field->{name}} = \$_[1] : \$_[0]{$field->{name}} }\n";
			}
		}
	}

	my $vtable_item_count = 2 + scalar @{$data->{fields}};


	# deserialize function
	$code .= '
sub deserialize {
	my ($self, $data, $offset) = @_;
	$offset //= 0;
	$self = $self->new unless ref $self;
';
	if (defined $compiler_state->{root_type} and $data->{typename} eq $compiler_state->{root_type}) {
		if (defined $compiler_state->{file_identifier}) {
			$code .= "
	# verify file identifier
	if (\$offset == 0 and '$compiler_state->{file_identifier}' ne substr \$data, 4, 4) {
		die 'invalid fbs file identifier, \"$compiler_state->{file_identifier}\" expected';
	}
";
		}
	}

	$code .= '
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
			$code .= "\$self->{$field->{name}} = unpack '$type->{format}', substr \$data, \$object_offset + \$offset, $type->{length};";

		} elsif ($self->is_string_type($type)) {
			$code .= "\$self->{$field->{name}} = \$self->deserialize_string(\$data, \$object_offset + \$offset);";

		} elsif ($self->is_array_type($type)) {
			$type = $self->translate_object_type($type) if $self->is_object_array_type($type);
			$code .= "\$self->{$field->{name}} = \$self->deserialize_array('$type', \$data, \$object_offset + \$offset);";

		} else {
			my $table_type = $self->get_object_type($type);
			my $typename = $table_type->{typename};
			$code .= "\$self->{$field->{name}} = $typename->deserialize(\$data, \$object_offset + \$offset);";
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

' if $self->standalone_packages;


	# serialize function
	$code .= '
sub serialize {
	my ($self) = @_;

	my @parts = $self->serialize_data;
	my $root = $parts[0]; # get the root data structure
';

	if (defined $compiler_state->{root_type} and $data->{typename} eq $compiler_state->{root_type}) {
		if (defined $compiler_state->{file_identifier}) {
			$code .= "
	# insert file identifier
	unshift \@parts, { type => 'file_identifier', data => '$compiler_state->{file_identifier}' };
";
		}
	}

	$code .= '
	# header pointer to root data structure
	unshift @parts, { type => "header", data => "\0\0\0\0", reloc => [{ offset => 0, item => $root, type => "unsigned delta" }] };

	return $self->serialize_objects(@parts);
}
';

# 	# serialize_vtable header
# 	$code .= '
# sub serialize_vtable {
# 	my ($self) = @_;

# 	my @data;
# 	my $offset = 4;
# ';

# 	# field offset serializers
# 	for my $field (@{$data->{fields}}) {
# 		my $type = $field->{type};
# 		if ($self->is_basic_type($type) or $self->is_string_type($type) or $self->is_array_type($type)) {
# 			$code .= "
# 	if (defined \$self->{$field->{name}}) {
# 		push \@data, \$offset;
# 		\$offset += $field->{length};
# 	} else {
# 		push \@data, 0;
# 	}
# ";
# 		} else {
# 			my $table_type = $self->get_object_type($type);
# 			if ($table_type->{type} eq 'table') {
# 			$code .= "
# 	if (defined \$self->{$field->{name}}) {
# 		push \@data, \$offset;
# 		\$offset += $field->{length};
# 	} else {
# 		push \@data, 0;
# 	}
# ";
# 			} elsif ($table_type->{type} eq 'struct') {
# 			$code .= "
# 	if (defined \$self->{$field->{name}}) {
# 		push \@data, \$offset;
# 		\$offset += $table_type->{typename}->flatbuffers_struct_length;
# 	} else {
# 		push \@data, 0;
# 	}
# ";
# 			} else {
# 				...
# 			}
# 		}
# 	}

# 	$code .= "
# 	push \@data, 0; # pad to 4 byte boundary
# " if @{$data->{fields}} % 2; # add padding code if there is an odd field count

# 	# serialize_vtable footer
# 	$code .= "

# 	unshift \@data, \$offset;
# 	unshift \@data, 2 * $vtable_item_count;

# 	return { type => 'vtable', data => pack 'S<' x \@data, \@data }
# }
# ";


	# serialize_data header
	$code .= '
sub serialize_data {
	my ($self) = @_;

	my $vtable = $self->serialize_vtable(
';
	
	for my $field (@{$data->{fields}}) {
		if ($self->is_object_type($field->{type}) and $self->get_object_type($field->{type})->{type} eq 'struct') {
			my $table_type = $self->get_object_type($field->{type});
			$code .= "\t\tdefined \$self->{$field->{name}} ? $table_type->{typename}->flatbuffers_struct_length : 0,\n";
		} else {
			$code .= "\t\tdefined \$self->{$field->{name}} ? $field->{length} : 0,\n";
		}
	}

	$code .= '	);
	my $data = "\0\0\0\0";

	my @reloc = ({ offset => 0, item => $vtable, type => "signed negative delta" });
	# flatbuffers vtable offset is stored in negative form
	my @objects = ($vtable);

';




	# field data serializers
	for my $field (@{$data->{fields}}) {
		$code .= "
	if (defined \$self->{$field->{name}}) {
		";
		my $type = $field->{type};
		if ($self->is_basic_type($type)) {
			$code .= "\$data .= pack '$flatbuffers_basic_types{$type}{format}', \$self->{$field->{name}};";

		} elsif ($self->is_string_type($type)) {
			$code .= qq/my \$string_object = \$self->serialize_string(\$self->{$field->{name}});
		push \@objects, \$string_object;
		push \@reloc, { offset => length (\$data), item => \$string_object, type => 'unsigned delta'};
		\$data .= \"\\0\\0\\0\\0\";/;

		} elsif ($self->is_array_type($type)) {
			my $type = $type;
			$type = $self->translate_object_type($type) if $self->is_object_array_type($type);
			$code .= qq/my (\$array_object, \@array_objects) = \$self->serialize_array('$type', \$self->{$field->{name}});
		push \@objects, \$array_object, \@array_objects;
		push \@reloc, { offset => length (\$data), item => \$array_object, type => 'unsigned delta'};
		\$data .= \"\\0\\0\\0\\0\";/;

		} else { # table serialization
			my $table_type = $self->get_object_type($type);
			
			if ($table_type->{type} eq 'table') {
				$code .= qq/my (\$root_object, \@table_objects) = \$self->{$field->{name}}->serialize_data;
		push \@objects, \$root_object, \@table_objects;
		push \@reloc, { offset => length (\$data), item => \$root_object, type => 'unsigned delta' };
		\$data .= \"\\0\\0\\0\\0\";/;
			} elsif ($table_type->{type} eq 'struct') {
				$code .= qq/my (\$root_object, \@struct_objects) = \$self->{$field->{name}}->serialize_data;
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

	# return table data and other objects that we\'ve created
	return { type => "table", data => $data, reloc => \@reloc }, @objects
}
	';


	$code .= '

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
	$string .= "\0"; # null termination byte because why the fuck not (it\'s part of flatbuffers)

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

' if $self->standalone_packages;

	# package footer
	$code .= "

1 # true return from package

";

	# compile usage statements for all package dependancies
	my $usages = '';
	$usages .= join '', map "use $_;\n", @{$data->{dependancies}} if defined $data->{dependancies};

	return { type => $data->{struct}{type}, package_name => $data->{typename}, code => $code, usages => $usages }
}




sub compile_struct_type {
	my ($self, $compiler_state, $data) = @_;

	# code header
	my $code = "package $data->{typename};
# struct package auto-generated by Data::FlatTables
use strict;
use warnings;
";

	# inject parenthood if we aren't writing standalone packages
	$code .= "
use parent 'Data::FlatTables::Table';
" unless $self->standalone_packages;

	# new method preamble
	$code .= '
sub new {
	my ($class, %args) = @_;
	my $self = bless {}, $class;

';
	# setting all fields from args
	for my $field (@{$data->{fields}}) {
		my $type = $field->{type};
		if ($self->is_basic_type($type) or $self->is_string_type($type)) {
			$code .= "\t\$self->{$field->{name}} = \$args{$field->{name}};\n";
		} elsif ($self->is_array_type($type)) {
			if ($self->is_object_array_type($type)) {
				my $type = $self->translate_object_type($type);

				... unless $type =~ /\A(\[+)/;
				my $nest_levels = length $1;

				my $true_type = $type;
				$true_type = $self->strip_array_brackets($true_type) for 1 .. $nest_levels;

				$code .= "\t\$self->{$field->{name}} = \n";
				$code .= "\t\t". "[ map { " x $nest_levels;

				$code .= "\n\t\t\t$true_type->new(\%\$_)\n";

				$code .= "\t\t". " } \@\$_ ] " x ($nest_levels - 1);
				$code .= "} \@{\$args{$field->{name}}} ];\n";

			} else {
				$code .= "\t\$self->{$field->{name}} = \$args{$field->{name}};\n";
			}
		} else {
			my $table_type = $self->get_object_type($type);
			my $typename = $table_type->{typename};
			$code .= "\t\$self->{$field->{name}} = $typename->new(%{\$args{$field->{name}}});\n";
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
	
	# flatbuffers types description
	$code .= "
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
" if $self->standalone_packages;

	# field getter/setter functions
	for my $field (@{$data->{fields}}) {
		my $type = $field->{type};
		if ($self->is_method_reserved($field->{name})) {
			warn "Warning: '$field->{name}' is a reserved name and will not get an getter/setter method";
		} elsif ($self->is_object_type($type)) {
				my $table_type = $self->get_object_type($type);
				my $typename = $table_type->{typename};
				$code .= "sub $field->{name} {
	my (\$self, \$val) = \@_;
	\$val = $typename->new(\%\$val) if defined \$val and not UNIVERSAL::can(\$val, 'can'); # bless it if not yet blessed
	return \@_ > 1 ? \$self->{$field->{name}} = \$val : \$self->{$field->{name}};
}
";
		} elsif ($self->is_object_array_type($type)) {
			$type = $self->translate_object_type($type);

			... unless $type =~ /\A(\[+)/;
			my $nest_levels = length $1;

			my $true_type = $type;
			$true_type = $self->strip_array_brackets($true_type) for 1 .. $nest_levels;

			$code .= "sub $field->{name} { 
	\@_ > 1 ? \$_[0]{$field->{name}} = 
";
			$code .= "\t\t". "[ map { " x $nest_levels;

			$code .= "\n\t\t\t(ref and not UNIVERSAL::can(\$_, 'can')) ? $true_type->new(\%\$_) : \$_\n";

			$code .= "\t\t". " } \@\$_ ] " x ($nest_levels - 1);
			$code .= "} \@{\$_[1]} ]\n\t : \$_[0]{$field->{name}}
}\n";
		} else {
			$code .= "sub $field->{name} { \@_ > 1 ? \$_[0]{$field->{name}} = \$_[1] : \$_[0]{$field->{name}} }\n";
		}
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
			$code .= "\$self->{$field->{name}} = unpack '$type->{format}', substr \$data, \$offset + $offset, $type->{length};";

		} elsif ($self->is_string_type($type)) {
			$code .= "\$self->{$field->{name}} = \$self->deserialize_string(\$data, \$offset + $offset);";
		} elsif ($self->is_array_type($type)) {
			$type = $self->translate_object_type($type) if $self->is_object_array_type($type);
			$code .= "\$self->{$field->{name}} = \$self->deserialize_array('$type', \$data, \$offset + $offset);";

		} else {
			my $table_type = $self->get_object_type($type);
			my $typename = $table_type->{typename};
			$code .= "\$self->{$field->{name}} = $typename->deserialize(\$data, \$offset + $offset);";
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

' if $self->standalone_packages;


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
			$code .= "\$data .= pack '$type->{format}', \$self->{$field->{name}} // die 'struct $data->{typename} requires field $field->{name}';";

		} elsif ($self->is_string_type($type)) {
			$code .= qq/do {
		my \$string_object = \$self->serialize_string(\$self->{$field->{name}});
		push \@objects, \$string_object;
		push \@reloc, { offset => length (\$data), item => \$string_object, type => 'unsigned delta'};
		\$data .= \"\\0\\0\\0\\0\";
	};/;

		} elsif ($self->is_array_type($type)) {
			$type = $self->translate_object_type($type) if $self->is_object_array_type($type);
			$code .= qq/do {
		my (\$array_object, \@array_objects) = \$self->serialize_array('$type', \$self->{$field->{name}});
		push \@objects, \$array_object, \@array_objects;
		push \@reloc, { offset => length (\$data), item => \$array_object, type => 'unsigned delta'};
		\$data .= \"\\0\\0\\0\\0\";
	};/;

		} else { # table serialization
			my $table_type = $self->get_object_type($type);
			
			if ($table_type->{type} eq 'table') {
				$code .= qq/do {
		my (\$root_object, \@table_objects) = \$self->{$field->{name}}->serialize_data;
		push \@objects, \$root_object, \@table_objects;
		push \@reloc, { offset => length (\$data), item => \$root_object, type => 'unsigned delta' };
		\$data .= \"\\0\\0\\0\\0\";
	};/;

			} elsif ($table_type->{type} eq 'struct') {
				$code .= qq/do {
		my (\$root_object, \@struct_objects) = \$self->{$field->{name}}->serialize_data;
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

sub flatbuffers_struct_length { $offset }

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
' if $self->standalone_packages;


	# package footer
	$code .= "

1 # true return from package

";

	# compile usage statements for all package dependancies
	my $usages = '';
	$usages .= join '', map "use $_;\n", @{$data->{dependancies}} if defined $data->{dependancies};

	return { type => $data->{struct}{type}, package_name => $data->{typename}, code => $code, usages => $usages }
}



# load packages from compiled packages
sub load_perl_packages {
	my ($self, $compiled) = @_;

	for my $file (@$compiled) {
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
		write_file(join ('/', @path) . '.pm', $file->{usages} . $file->{code});
	}
}



sub main {
	my $compiler = Data::FlatTables->new;
	while (@_) {
		my $arg = shift @_;
		if ($arg =~ /\A-/) {
			if ($arg eq '-p') {
				$compiler->standalone_packages(0);
			} else {
				die "unknown option : '$arg'";
			}
		} else {
			$compiler->create_packages($arg);
		}
	}
}

caller or main(@ARGV)

