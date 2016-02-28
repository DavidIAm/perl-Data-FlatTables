#!/usr/bin/env perl
package FlatBuffers;
use strict;
use warnings;

use feature 'say';


# little-endian everything
# they're not even buffers ffs, a better name would've been flatpack



sub strip_string (;$) {
	(shift // $_) =~ s/\A"(.*)"\Z/$1/sr
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

	return $self
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


use File::Slurp qw/ read_file /;
use Data::Dumper;

sub main {
	my ($filepath) = @_;
	my $text = read_file($filepath);

	my $parser = FlatBuffers->new;
	say Dumper $parser->parse($text);
}

caller or main(@ARGV)

