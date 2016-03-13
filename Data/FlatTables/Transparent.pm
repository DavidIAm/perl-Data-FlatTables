package Data::FlatTables::Transparent;
use Filter::Simple;
use Data::FlatTables;

FILTER {
	s/\A(.*)\Z/\n1;\n/s or die "failed to extract test";
	Data::FlatTables->load_text($1)
};

1
