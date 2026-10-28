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
   $listed->get_ok('/pan/feature/demo/modules.json')->status_is(200)->json_is('/complete', JSON::PP::true);
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
   $mtree->commit("Initial Commit", create_branch => 'test');

   my $t= Test::Mojo->new('Mojolicious');
   CPAN::InGit::Server->mount($t->app->routes->get('/'), $cpan_repo);

   $t->get_ok('/test/modules/02packages.details.txt')->status_is(200)->content_is($package_details_txt);
   $t->get_ok('/test/modules/02packages.details.txt.gz')->status_is(200);
   $t->get_ok('/test/authors/id/M/MS/MSCHWERN/AAAAAAAAA-1.01.meta')->status_is(200)->content_is($AAAAAAAAA_meta);
   $t->get_ok('/test/authors/id/M/MS/MSCHWERN/AAAAAAAAA-1.01.tar.gz')->status_is(200);
   $t->get_ok('/test/authors/id/LOCAL/Example-0.001.meta')->status_is(200)->json_is('/name' => "Example");
   
   # Test cache invalidation
   $mtree->set_path('authors/id/LOCAL/Example-0.002.meta', \q{{"name":"Example"}});
   $mtree->commit("Upgrade Example to 0.002");
   $t->get_ok('/test/authors/id/LOCAL/Example-0.002.meta')->status_is(200)->json_is('/name' => "Example");
};

done_testing;
