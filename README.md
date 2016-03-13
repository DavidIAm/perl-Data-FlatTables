# Data::FlatTables
A package compiler with built-in serialization and deserialization functionality.

To create a package, first write a flatbuffers .fbs file (see https://github.com/google/flatbuffers) and then compile it with Data::FlatTables like so:
`./Data/FlatTables.pm my_awesome_table.fbs`

This will create a self-contained .pm package in the current directory for each table and struct in the flatbuffers code which is ready to use:
```perl
use MyAwesomeTable;
# create an instance of the table
my $table = MyAwesomeTable->new(val => 15, key => 'hello world!');

print "my val is ", $table->val, "\n";
# change the value of val
$table->val(30);
```
This compiled package immediately comes with support for flatbuffers-compatible serialization and deserialization:
```perl
# write the serialized output of $table to output.bin
write_binary('output.bin', $table->serialize);

# deserialize the binary string from input.bin as a MyAwesomeTable instance
my $new_table = MyAwesomeTable->deserialize(read_binary('input.bin'));
```

Alternatively, you can inline a fbs schema with Data::FlatTables::Transparent to avoid compiling any files manually:
```perl
use Data::FlatTables::Transparent;
table MyAwesomeTable {
  key : string;
  val : int;
}
no Data::FlatTables::Transparent;

my $table = MyAwesomeTable->new(val => 15, key => 'hello world!');
write_binary('output.bin', $table->serialize);
```

## Major Compatability Notes:
These are major differences between FlatTables and FlatBuffers which cause incompatability if used:
 - FlatTables is still missing support for FlatBuffers enums
 - FlatTables extends the abilities of FlatBuffers with extra features:
   - FlatTables structs can support all value types (FlatBuffer struct only supports scalar and struct values)
   - FlatTables supports nested arrays (e.g. `val : [[int]];`)(FlatBuffers only supports one dimentional arrays)
   - FlatTables supports inline namespacing for tables an structs (e.g. `table MyNamespace.MyAwesomeTable {}`)(FlatBuffers doesn't)

## Minor Compatability Notes:
These are minor differences notable only to someone looking at the guts of FlatTables or FlatBuffers:
 - FlatTables doesn't immediately store data in binary form, unlike FlatBuffers
 - FlatBuffers always tries to place a vtable before table data in a binary, where as FlatTables design always places the table data first
