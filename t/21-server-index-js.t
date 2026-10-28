use FindBin;
use lib "$FindBin::Bin/lib";
use Test2AndUtils;
use File::Spec;
use v5.36;

my ($node)= grep -x $_, map File::Spec->catfile($_, 'node'), File::Spec->path;
plan skip_all => 'Node.js is needed to test the index JavaScript' unless $node;
is( system($node, "$FindBin::Bin/js/server-index.cjs", "$FindBin::Bin/../share/public/archive_tree_index.js"),
   0, 'browser pagination and filtering behavior' );
done_testing;
