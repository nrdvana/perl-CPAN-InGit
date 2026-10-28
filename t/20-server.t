use FindBin;
use lib "$FindBin::Bin/lib";
use Test2AndUtils;
use File::Temp;
use Git::Raw;
use Test::Mojo;
use Time::Piece;
use CPAN::InGit;
use CPAN::InGit::Server;
use v5.36;

my $repodir= $ENV{TEST_CPAN_INGIT_GIT_DIR}
   // File::Temp->newdir(CLEANUP => $ENV{TEST_CPAN_INGIT_CLEANUP} // 1);
my $git_repo= Git::Raw::Repository->init($repodir, 1); # new bare repo in tmpdir
note "repo at $repodir";
my $cpan_repo= CPAN::InGit->new(git_repo => $git_repo);

my $package_details_txt= <<'END';
File:         02packages.details.txt
URL:          http://www.cpan.org/modules/02packages.details.txt
Description:  Package names found in directory $CPAN/authors/id/
Columns:      package name, version, path
Intended-For: Automated fetch routines, namespace documentation.
Written-By:   PAUSE version 1.005
Line-Count:   9
Last-Updated: Wed, 19 Nov 2025 23:29:01 GMT

A1z::Html                          0.04  C/CE/CEEJAY/A1z-Html-0.04.tar.gz
A1z::HTML5::Template               0.22  C/CE/CEEJAY/A1z-HTML5-Template-0.22.tar.gz
A_Third_Package                   undef  C/CL/CLEMBURG/Test-Unit-0.13.tar.gz
AAA::Demo                         undef  J/JW/JWACH/Apache-FastForward-1.1.tar.gz
AAA::eBay                         undef  J/JW/JWACH/Apache-FastForward-1.1.tar.gz
AAAA                              undef  P/PR/PRBRENAN/Data-Table-Text-20210818.tar.gz
AAAA::Crypt::DH                    0.06  B/BI/BINGOS/AAAA-Crypt-DH-0.06.tar.gz
AAAA::Mail::SpamAssassin          0.002  S/SC/SCHWIGON/AAAA-Mail-SpamAssassin-0.002.tar.gz
AAAAAAAAA                          1.01  M/MS/MSCHWERN/AAAAAAAAA-1.01.tar.gz
END
my $AAAAAAAAA_meta= <<'END';
---
abstract: 'Aaaaaa aaaaa aa aaaaaa Aaaaa aaaa'
author:
  - 'Aaaaaaa A Aaaaaaa <schwern@pobox.com>'
build_requires: {}
configure_requires:
  A_Third_Package: 0.13
dynamic_config: 1
generated_by: 'Module::Build version 0.38, CPAN::Meta::Converter version 2.110930'
license: perl
meta-spec:
  url: http://module-build.sourceforge.net/META-spec-v1.4.html
  version: 1.4
name: AAAAAAAAA
provides:
  AAAAAAAAA:
    file: aaa/AAAAAAAAA.pm
    version: 1.00
resources:
  license: http://dev.perl.org/licenses/
version: 1.00
END

subtest repository_index => sub {
   my $dir= File::Temp->newdir;
   my $repo= CPAN::InGit->new(repo => Git::Raw::Repository->init($dir, 1));
   my $hidden= Test::Mojo->new('Mojolicious');
   CPAN::InGit::Server->mount($hidden->app->routes->any('/'), $repo);
   $hidden->get_ok('/~static/archive_tree_index.js')->status_is(200);
   $hidden->get_ok('/')->status_is(200)->text_is('h1', 'CPAN::InGit repository')
      ->element_exists('a[href="https://metacpan.org/pod/CPAN::InGit"]')
      ->element_count_is('#branch-index', 0);
   $hidden->get_ok('/?index_branches=1')->status_is(200)->element_count_is('#branch-index', 0);

   my $listed= Test::Mojo->new('Mojolicious');
   CPAN::InGit::Server->mount($listed->app->routes->any('/pan'), $repo, index_branches => 1);
   $listed->get_ok('/pan/')->status_is(200)->element_exists('#branch-index')
      ->text_like('#branch-index p', qr/No CPAN archive branches/);
   $repo->create_archive_tree('zeta');
   $repo->create_archive_tree('alpha');
   $repo->create_archive_tree('feature/demo');
   my $ordinary= CPAN::InGit::MutableTree->new(parent => $repo);
   $ordinary->set_path('README', \'An ordinary Git branch');
   $ordinary->commit('Non-archive branch', create_branch => 'ordinary');
   $listed->get_ok('/pan')->status_is(200)->element_count_is('#branch-index li', 3)
      ->element_exists('#branch-index a[href="/pan/alpha/"]')
      ->element_exists('#branch-index a[href="/pan/feature%2Fdemo/"]');
   is( [map $_->text, $listed->tx->res->dom->find('#branch-index a')->each],
      [qw(alpha feature/demo zeta)], 'local archive branches sorted by name' );
   $listed->get_ok('/pan/feature%2Fdemo/')->status_is(200)->text_is('h1', 'feature/demo');
   $listed->get_ok('/pan/feature/demo/modules/')->status_is(200)->json_is('/complete', JSON::PP::true);
   $listed->get_ok('/pan/feature/demo/modules/02packages.details.txt')->status_is(200);
   $hidden->get_ok('/')->status_is(200)->element_count_is('#branch-index', 0)->content_unlike(qr/zeta/);

   # Single-tree mounts keep their archive index even when branch listing is enabled.
   my $fixed= Test::Mojo->new('Mojolicious');
   CPAN::InGit::Server->mount($fixed->app->routes->any('/'), $repo,
      archive_tree => $repo->get_archive_tree('alpha'), index_branches => 1);
   $fixed->get_ok('/')->status_is(200)->text_is('h1', 'alpha')->element_count_is('#branch-index', 0);

   for my $enabled (0, 1) {
      local $ENV{MOJO_LOG_LEVEL}= 'fatal';
      my @args= ($^X, "-I$FindBin::Bin/../lib", "$FindBin::Bin/../bin/cpangit-server",
         "--git-dir=$dir", '--path-base=/pan', ($enabled? ('--index-branches') : ()), 'get', '/pan/');
      open my $pipe, '-|', @args or die "start cpangit-server: $!";
      my $html= do { local $/; <$pipe> };
      close $pipe;
      is( $?, 0, "cpangit-server get succeeds (index_branches=$enabled)" );
      my $dom= Mojo::DOM->new($html);
      is( $dom->find('#branch-index li')->size, $enabled? 3 : 0,
         'command-line option controls branch listing' );
   }
};

subtest all_branches => sub {
   my $mtree= CPAN::InGit::MutableTree->new(parent => $cpan_repo);
   $mtree->set_path('modules/02packages.details.txt', \$package_details_txt);
   $mtree->set_path('cpan_ingit.json', \q{{"corelist_perl_version":"5.016","default_import_sources":[]}});
   $mtree->set_path('authors/id/M/MS/MSCHWERN/AAAAAAAAA-1.01.meta', \$AAAAAAAAA_meta);
   $mtree->set_path('authors/id/M/MS/MSCHWERN/AAAAAAAAA-1.01/META.yml', \$AAAAAAAAA_meta);
   $mtree->set_path('authors/id/LOCAL/Example-0.001.meta', \q{{"name":"Example"}});
   $mtree->set_path('authors/id/LOCAL/modules', \'A real file named modules');
   my $initial_commit= $mtree->commit("Initial Commit", create_branch => 'test');

   my $t= Test::Mojo->new('Mojolicious');
   CPAN::InGit::Server->mount($t->app->routes->get('/'), $cpan_repo);

   $t->get_ok('/test/')->status_is(200)
      ->element_exists('input[name="filter"]')
      ->text_is('#commit-date', gmtime($initial_commit->time)->strftime('%a, %d %b %Y %H:%M:%S GMT'))
      ->text_is('#index-updated', 'Wed, 19 Nov 2025 23:29:01 GMT')
      ->element_count_is('#module-rows tr', 9)
      ->element_exists('a[href="/test/authors/id/M/MS/MSCHWERN/AAAAAAAAA-1.01.tar.gz"]');
   $t->get_ok('/test/modules/')->status_is(200)->json_is('/complete', JSON::PP::true)
      ->json_is('/next_after', undef)->json_is('/previous_before', undef);
   for my $filter ('a1Z', 'cEeJaY', '0.04', '[.*', 'not-present') {
      $t->get_ok(Mojo::URL->new('/test/modules/')->query(filter => $filter))->status_is(200)
         ->json_is('/filter', $filter)->json_is('/complete', JSON::PP::true);
      my @expected= sort grep index(lc $_, lc $filter) >= 0,
         grep /^\S+\s+\S+\s+\S+$/, split /\n/, (split /\n\n/, $package_details_txt, 2)[1];
      is( [map $_->{text}, $t->tx->res->json->{modules}->@*], \@expected, "literal row filter: $filter" );
   }
   $t->get_ok('/test/?filter=ceeJAY')->status_is(200)->element_count_is('#module-rows tr', 2);
   $t->get_ok('/~static/archive_tree_index.js')->status_is(200)->content_type_like(qr/javascript/);
   is( $t->tx->res->body, slurp("$FindBin::Bin/../share/public/archive_tree_index.js"), 'JavaScript served verbatim' );
   my $etag= $t->tx->res->headers->etag;
   $t->get_ok('/~static/archive_tree_index.js' => {'If-None-Match' => $etag})->status_is(304);
   $t->get_ok('/~static/archive_tree_index.html.ep')->status_is(404);
   $t->get_ok('/missing/')->status_is(404);
   $t->get_ok('/missing/modules/')->status_is(404);

   $t->get_ok('/test/modules/02packages.details.txt')->status_is(200)->content_is($package_details_txt);
   $t->get_ok('/test/modules/02packages.details.txt.gz')->status_is(200);
   $t->get_ok('/test/authors/id/M/MS/MSCHWERN/AAAAAAAAA-1.01.meta')->status_is(200)->content_is($AAAAAAAAA_meta);
   $t->get_ok('/test/authors/id/M/MS/MSCHWERN/AAAAAAAAA-1.01.tar.gz')->status_is(200);
   $t->get_ok('/test/authors/id/LOCAL/Example-0.001.meta')->status_is(200)->json_is('/name' => "Example");
   $t->get_ok('/test/authors/id/LOCAL/modules')->status_is(200)->content_is('A real file named modules');
   
   # Test cache invalidation
   $mtree->set_path('authors/id/LOCAL/Example-0.002.meta', \q{{"name":"Example"}});
   $mtree->commit("Upgrade Example to 0.002");
   $t->get_ok('/test/authors/id/LOCAL/Example-0.002.meta')->status_is(200)->json_is('/name' => "Example");

   # Refresh the cached rows when the branch's package index changes.
   $mtree= CPAN::InGit::MutableTree->new(parent => $cpan_repo, branch => 'test');
   my $updated= $package_details_txt =~ s/AAAAAAAAA\s+1\.01/AAAAAAAAA                          1.02/r;
   $mtree->set_path('modules/02packages.details.txt', \$updated);
   $mtree->commit('Update package index');
   $t->get_ok('/test/modules/?filter=AAAAAAAAA')->status_is(200)
      ->json_is('/modules/0/version', '1.02');
};

subtest module_pagination => sub {
   my $mtree= CPAN::InGit::MutableTree->new(parent => $cpan_repo);
   my $large= "Last-Updated: Wed, 19 Nov 2025 23:29:01 GMT\n\n";
   $large .= join '', map sprintf("Example::M%04d 1.00 L/LO/LOCAL/Example-%d.tar.gz\n", $_, $_), 1..1001;
   $mtree->set_path('modules/02packages.details.txt', \$large);
   $mtree->set_path('cpan_ingit.json', \'{}');
   $mtree->commit('Large package index', create_branch => 'large');
   my $t= Test::Mojo->new('Mojolicious');
   CPAN::InGit::Server->mount($t->app->routes->any('/pan'), $cpan_repo);

   $t->get_ok('/pan/large')->status_is(200)->element_count_is('#module-rows tr', 500)
      ->element_exists('main[data-json-url="/pan/large/modules/"]')
      ->element_exists('script[src="/~static/archive_tree_index.js"]');
   $t->get_ok('/pan/large/modules/')->status_is(200)
      ->json_is('/complete', JSON::PP::false)->json_is('/next_after', 'Example::M0500')
      ->json_is('/previous_before', undef);
   my @names= map $_->{name}, $t->tx->res->json->{modules}->@*;
   is( scalar @names, 500, 'first JSON page capped at 500 modules' );
   $t->get_ok('/pan/large/modules/?after=Example::M0500')->status_is(200)
      ->json_is('/modules/0/name', 'Example::M0501')->json_is('/next_after', 'Example::M1000')
      ->json_is('/previous_before', 'Example::M0501')->json_is('/complete', JSON::PP::false);
   push @names, map $_->{name}, $t->tx->res->json->{modules}->@*;
   $t->get_ok('/pan/large/modules/?after=Example::M1000')->status_is(200)
      ->json_is('/modules/0/name', 'Example::M1001')->json_is('/next_after', undef)
      ->json_is('/complete', JSON::PP::false);
   push @names, map $_->{name}, $t->tx->res->json->{modules}->@*;
   is( \@names, [map sprintf('Example::M%04d', $_), 1..1001], 'paging has no gaps or duplicate modules' );
   $t->get_ok('/pan/large/modules/?before=Example::M1001')->status_is(200)
      ->json_is('/modules/0/name', 'Example::M0501')->json_is('/modules/499/name', 'Example::M1000');
   $t->get_ok('/pan/large/modules/?before=Example::M0501')->status_is(200)
      ->json_is('/modules/0/name', 'Example::M0001')->json_is('/modules/499/name', 'Example::M0500');
   $t->get_ok('/pan/large/modules/?after=Example::M1001')->status_is(200)->json_is('/modules', [])
      ->json_is('/complete', JSON::PP::false);
   $t->get_ok('/pan/large/modules/?before=Example::M0001')->status_is(200)->json_is('/modules', []);
   $t->get_ok('/pan/large/modules/?after=A&before=Z')->status_is(400);
   $t->get_ok('/pan/large/modules/?filter=eXaMpLe::m000')->status_is(200)
      ->json_is('/complete', JSON::PP::true);
   is( scalar $t->tx->res->json->{modules}->@*, 9, 'filter applied before pagination' );
   # A boundary need not name an existing module, and remains exclusive when filtering.
   $t->get_ok('/pan/large/modules/?filter=EXAMPLE::M000&after=Example::M0004z')->status_is(200)
      ->json_is('/modules/0/name', 'Example::M0005')->json_is('/complete', JSON::PP::false);

   my $fixed= Test::Mojo->new('Mojolicious');
   CPAN::InGit::Server->mount($fixed->app->routes->any('/mirror'), $cpan_repo,
      archive_tree => $cpan_repo->get_archive_tree('large'));
   $fixed->get_ok('/mirror/')->status_is(200)->element_count_is('#module-rows tr', 500)
      ->element_exists('main[data-json-url="/mirror/modules/"]');
   $fixed->get_ok('/mirror/modules/?filter=m1001')->status_is(200)
      ->json_is('/modules/0/name', 'Example::M1001')->json_is('/complete', JSON::PP::true);
};

subtest index_variants => sub {
   my $mtree= CPAN::InGit::MutableTree->new(parent => $cpan_repo);
   my $content= "Last-Updated: Wed, 19 Nov 2025 23:29:01 GMT\n\n";
   $content .= join '', map sprintf("Exact::M%04d 1.00 L/LO/LOCAL/Exact-%d.tar.gz\n", $_, $_), 1..500;
   $mtree->set_path('modules/02packages.details.txt', \$content);
   $mtree->set_path('cpan_ingit.json', \'{}');
   my $commit= $mtree->commit('Exactly 500 modules', create_branch => 'exact');
   my $t= Test::Mojo->new('Mojolicious');
   CPAN::InGit::Server->mount($t->app->routes->any('/'), $cpan_repo);
   $t->get_ok('/exact/modules/')->status_is(200)->json_is('/complete', JSON::PP::true)
      ->json_is('/next_after', undef)->json_is('/modules/499/name', 'Exact::M0500');
   $t->get_ok('/exact/')->status_is(200)->element_exists('#load-more[hidden]');
   $t->get_ok('/'.$commit->id.'/')->status_is(200)
      ->text_is('#commit-date', gmtime($commit->time)->strftime('%a, %d %b %Y %H:%M:%S GMT'));

   # A fixed commit mount retains its reference for commit metadata as well.
   my $fixed= Test::Mojo->new('Mojolicious');
   CPAN::InGit::Server->mount($fixed->app->routes->any('/'), $cpan_repo,
      archive_tree => $cpan_repo->get_archive_tree($commit->id));
   $fixed->get_ok('/')->status_is(200)
      ->text_is('#commit-date', gmtime($commit->time)->strftime('%a, %d %b %Y %H:%M:%S GMT'))
      ->attr_is('main', 'data-json-url', '/modules/');
   $fixed->get_ok('/modules/')->status_is(200)->json_is('/complete', JSON::PP::true);

   my $empty= $cpan_repo->create_archive_tree('empty');
   $t->get_ok('/empty/')->status_is(200)->element_count_is('#module-rows tr', 0);
   $t->get_ok('/empty/modules/')->status_is(200)->json_is('/modules', [])
      ->json_is('/complete', JSON::PP::true);
   my $missing= CPAN::InGit::MutableTree->new(parent => $cpan_repo);
   $missing->set_path('cpan_ingit.json', \'{}');
   $missing->commit('No package index', create_branch => 'noindex');
   $t->get_ok('/noindex/')->status_is(404);
   $t->get_ok('/noindex/modules/')->status_is(404);

   my $unsafe= "Last-Updated: unknown\n\nExample::<b> undef L/LO/LOCAL/Example-<b>&\".tar.gz\n";
   my $escape= CPAN::InGit::MutableTree->new(parent => $cpan_repo);
   $escape->set_path('cpan_ingit.json', \'{}');
   $escape->set_path('modules/02packages.details.txt', \$unsafe);
   $escape->commit('Untrusted index content', create_branch => 'escape');
   $t->get_ok(Mojo::URL->new('/escape/')->query(filter => '<b>'))->status_is(200)
      ->element_count_is('#module-rows tr', 1)->element_count_is('#module-rows b', 0)
      ->text_is('#module-rows tr td', 'Example::<b>')
      ->element_exists('input[value="<b>"]');
};

subtest endpoint_names => sub {
   my $dir= File::Temp->newdir;
   my $repo= CPAN::InGit->new(repo => Git::Raw::Repository->init($dir, 1));
   $repo->create_archive_tree($_) for qw(other feature/modules.json feature/index.js public);
   my $t= Test::Mojo->new('Mojolicious');
   CPAN::InGit::Server->mount($t->app->routes->any('/pan'), $repo);
   $t->get_ok('/pan/other/modules/')->status_is(200)->json_is('/modules', []);
   $t->get_ok('/pan/feature/modules.json/')->status_is(200)->text_is('h1', 'feature/modules.json');
   $t->get_ok('/pan/feature/index.js/')->status_is(200)->text_is('h1', 'feature/index.js');
   $t->get_ok('/~static/archive_tree_index.js')->status_is(200);
   my $root= Test::Mojo->new('Mojolicious');
   CPAN::InGit::Server->mount($root->app->routes->any('/'), $repo);
   $root->get_ok('/public/')->status_is(200)->text_is('h1', 'public')
      ->element_exists('script[src="/~static/archive_tree_index.js"]');
   $root->get_ok('/public/modules/')->status_is(200)->json_is('/modules', []);
   $root->get_ok('/~static/archive_tree_index.js')->status_is(200);
};

done_testing;
