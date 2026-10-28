package CPAN::InGit::Server;
# VERSION
# ABSTRACT: A Mojolicious::Controller that serves the ArchiveTrees from a git repo

=head1 DESCRIPTION

This controller serves paths that can be used directly as a CPAN Mirror by tools like 'cpanm'.
By default, it serves all branches, but you can also configure it to serve only a single branch.
It serves content directly from the Git repo and does not need a working directory checked out.

=cut

use Carp;
use Scalar::Util 'refaddr', 'blessed';
use JSON::PP;
use Time::Piece;
use Log::Any '$log';
use Archive::Tar;
use IO::Compress::Gzip qw( gzip $GzipError );
use CPAN::InGit;
use File::ShareDir ();
use Mojo::File 'path';
use Mojolicious::Static;
use Mojo::Base 'Mojolicious::Controller';
use v5.36;

=attribute cpan_repo

Reference to the CPAN::InGit object from which files will be served

=attribute archive_tree

Reference to an L<ArchvieTree|CPAN::InGit::ArchvieTree> object.  If set, the controller
will serve only the tree of this branch from whatever path it was rooted at.  If not set,
this attribute will be lazy-built from attribute C<branch_name> and cached in C<branch_cache>.
The lazy-building of this attribute may return C<undef>, and should be checked I<before>
dispatching to an action.

=attribute branch_name

Name of branch to be lazy-loaded by the C<archive_tree> accessor.

=attribute branch_cache

A hashref or L<Tree::RB::XS> object storing a cache of ArchiveTree objects.  This needs to be
supplied in the stash if you are loading branches by name at runtime, or else it will be
creating an ArchiveTree object on every request.

=attribute branch_head_only

If true, this prevents serving files from a Git::Raw tree which is not the HEAD of a branch.
By default, any Git sha-1, tag, or branch name may be used so long as it references a tree that
meets the requirements for an ArchiveTree.

=attribute index_branches

If true, list the available local CPAN archive branches on the repository index.
Disabled by default; only applies when serving multiple trees.

=cut

sub cpan_repo($c) { $c->stash('cpan_repo') }

sub archive_tree($c) {
   $c->stash->{archive_tree} //= do {
      my $branch_name= $c->branch_name;
      my $cache= $c->branch_cache;
      my $atree= $cache->{$branch_name};
      if ($atree) {
         # check whether branch has updated since cached
         my $current_tree= $c->cpan_repo->lookup_tree($branch_name);
         unless (defined $current_tree and $atree->tree->id eq $current_tree->id) {
            delete $cache->{$branch_name};
            $atree= undef;
         }
      }
      if (!$atree && ($atree= $c->cpan_repo->get_archive_tree($branch_name))) {
         if ($c->branch_head_only && !defined $atree->branch) {
            $c->log->debug("Branch '$branch_name' is not a branch HEAD");
            $atree= undef;
         } else {
            $cache->{$branch_name}= $atree;
         }
      }
      $atree;
   };
}

sub branch_name($c) { $c->stash('branch_name') }

sub branch_cache($c) {
   $c->stash->{branch_cache} //= do {
      warn "no branch_cache, creating temporary";
      $c->_new_cache
   }
}

sub branch_head_only($c) { $c->stash('branch_head_only') }
sub index_branches($c) { $c->stash('index_branches') }

sub _share_dir {
   state $dir= do {
      my $relative= path(__FILE__)->sibling('..', '..', '..', 'share');
      -f $relative->child('archive_tree_index.html.ep')? $relative->realpath
         : path(File::ShareDir::dist_dir('CPAN-InGit'));
   };
   return $dir;
}

sub _new_cache {
   # the 'recent_limit' feature was added in 0.20
   state $have_tree_rb_xs= eval 'use Tree::RB::XS 0.20';
   my %hash;
   tie %hash, 'Tree::RB::XS', track_recent => 1, recent_limit => 20
      if $have_tree_rb_xs;
   \%hash;
}

=head1 ROUTES

=head2 Cpan Mirror Paths

A functioning CPAN mirror requires a file C<< /modules/02packages.details.txt.gz >> which lists
the full contents of the latest version of every module.  That file also lists the author paths
for each module, which are relative to C<< /authors/id/ >>

In CPAN::InGit, C<< /modules/02packages.details.txt >> is stored uncompressed, and
gzipped as it is served.  Each author dist is stored as a .tar.gz file and a metadata file with
extension .meta and may also optionally be unpacked at a directory of the same name minus the
.tar.gz extension.  A special author "LOCAL" is used for custom overrides of upstream packages.

Summary:

  /                                                       # repository index
  /~static/...                                            # static files served publicly
  /:branch/                                               # browsable tree index
  /:branch/modules/?filter=TEXT&after=MODULE              # filtered module list
  /:branch/modules/02packages.details.txt                 # index of the mirror
  /:branch/authors/id/D/DP/DPARIS/Crypt-DES-2.07.tar.gz   # copy of upstream
  /:branch/authors/id/D/DP/DPARIS/Crypt-DES-2.07.meta     # extracted metadata
  /:branch/authors/id/L/LO/LOCAL/Crypt-DES-2.07_01/...    # untarred customized dist
  /:branch/authors/id/L/LO/LOCAL/Crypt-DES-2.07_01.meta   # untarred customized dist's metadata

=head2 mount

  my $route= app->routes->any('/pan');
  my $repo= CPAN::InGit->new(git_repo => '/path/to/.git');
  CPAN::InGit::Server->mount($route, $repo, %options);
  # %options:
  #   archive_tree => $ArchiveTree_obj,
  #   branch_cache => $branch_cache,
  #   index_branches => 1, # optionally list local CPAN archive branches

This class method sets up the routes for serving the mirror under a provided route.
C<$route> is the route under which you want to serve the 'PAN.

If you specify 'archive_tree', that tree will be directly mounted at the route without the '/:branch'
selector portion of the paths.
Otherwise, the route's root serves a repository index; C<index_branches> enables
branch links on that page and defaults to false.
Files in C<share/public> are served verbatim under C</~static/> using Mojo's static
file handler, regardless of the mount path.

=cut

sub mount($class, $base_route, $cpan_repo, %options) {
   my $root= $base_route->root;
   unless ($root->{_cpan_ingit_public}) {
      my $static= Mojolicious::Static->new(
         paths => [$class->_share_dir->child('public')->to_string], prefix => '/~static');
      $root->get('/~static/*asset')->to(cb => sub($c) {
         $static->dispatch($c) || $c->reply->not_found;
      });
      # Static files must take precedence over the catch-all branch index.
      unshift $root->children->@*, pop $root->children->@*;
      $root->{_cpan_ingit_public}= $static;
   }
   my $atree= $options{archive_tree};
   if ($atree) {
      croak "Not an ArchiveTree"
         unless blessed($atree) && $atree->can('get_path');
   } else {
      # Ensure there is a cache if serving all branches
      $options{branch_cache} //= $class->_new_cache;
   }
   $base_route= $base_route->to(namespace => '', controller => $class, cpan_repo => $cpan_repo, %options);
   $base_route->get('/')->to(action => 'serve_repo_index') unless $atree;
   # Keep each suffix in the same pattern as the branch wildcard, so Git branch
   # names containing slashes can be matched without consuming the file path.
   my $prefix= $atree? '' : '/*branch_name';
   $base_route->get("$prefix/modules/02packages.details", [ format => ['txt','txt.gz'] ])
      ->to(action => 'serve_package_details');
   $base_route->get("$prefix/authors/id/*author_path")->to(action => 'serve_author_file');
   $base_route->get("$prefix/modules/")->to(action => 'serve_module_list');
   $base_route->get($atree? '/' : $prefix, [ branch_name => qr{.+?(?=/?$)}, format => 0 ])
      ->to(action => 'serve_index');
}

=method serve_repo_index

Serve the repository landing page.  Local branches containing CPAN configuration
and a package index are listed only when C<index_branches> is enabled in the stash.

=cut

sub serve_repo_index($c) {
   my @branches;
   my $index_branches= $c->index_branches // 0;
   if ($index_branches) {
      my $base= $c->url_for->query(undef);
      my $base_path= $base->path->to_string =~ s{/*$}{/}r;
      for my $branch (sort { $a->shorthand cmp $b->shorthand } $c->cpan_repo->git_repo->branches('local')) {
         my $tree= $branch->peel('tree');
         next unless $tree->entry_bypath('cpan_ingit.json')
            && $tree->entry_bypath('modules/02packages.details.txt');
         my $name= $branch->shorthand;
         push @branches, { name => $name, url => $base->clone->path($base_path.Mojo::Util::url_escape($name).'/') };
      }
   }
   $c->render(inline => $c->_share_dir->child('repo_index.html.ep')->slurp('UTF-8'), handler => 'ep', format => 'html',
      index_branches => $index_branches, branches => \@branches);
}

=method serve_index

Serve an HTML index for a CPAN tree, including its commit date, package index date,
and the first 500 matching modules.

=method serve_module_list

Serve C<modules/> as JSON.  C<filter> is a case-insensitive literal substring matched
against the entire original 02packages row (module, version, and distribution path).
C<after> and C<before> are exclusive module-name boundaries; supply at most one.
Rows are sorted by module name, with at most 500 returned per request.

The response contains C<modules> (objects with C<name>, C<version>, C<path>, and
C<text>), the applied C<filter>, the Git C<tree> ID, and C<next_after> and
C<previous_before> cursors (null at either end).  C<complete> is true only when
this response includes every row matching the filter, including rows outside
the requested boundary.  A client may then narrow that filter locally.

=cut

sub _module_index($c) {
   my $atree= $c->archive_tree;
   my $blob= $atree->package_details_blob;
   return undef unless $blob;
   my $index= $atree->{_server_module_index};
   unless ($index && $index->{blob_id} eq $blob->id) {
      my ($headers, $body)= split /\r?\n\r?\n/, $blob->content, 2;
      my ($updated)= $headers =~ /^Last-Updated:\s*([^\r\n]*)/m;
      my @rows;
      for my $line (split /\r?\n/, $body // '') {
         next unless $line =~ /^(\S+)\s+(\S+)\s+(\S+)\s*$/;
         push @rows, { name => $1, version => $2, path => $3, text => $line };
      }
      @rows= sort { $a->{name} cmp $b->{name} } @rows;
      $index= $atree->{_server_module_index}= { blob_id => $blob->id, updated => $updated, rows => \@rows };
   }
   return $index;
}

sub _module_page($c, $index) {
   my $filter= $c->param('filter') // '';
   my $needle= lc $filter;
   my @matches= grep index(lc $_->{text}, $needle) >= 0, $index->{rows}->@*;
   my ($after, $before)= map $c->param($_), qw(after before);
   my ($start, $end)= (0, scalar @matches);
   if (defined $before) {
      --$end while $end && $matches[$end-1]{name} ge $before;
      $start= $end > 500? $end-500 : 0;
   } else {
      ++$start while $start < $end && defined $after && $matches[$start]{name} le $after;
      $end= $start+500 if $end > $start+500;
   }
   my @rows= @matches[$start .. $end-1];
   return {
      modules => \@rows,
      filter => $filter,
      tree => $c->archive_tree->tree->id,
      complete => $start == 0 && $end == @matches? JSON::PP::true : JSON::PP::false,
      next_after => @rows && $end < @matches? $rows[-1]{name} : undef,
      previous_before => @rows && $start > 0? $rows[0]{name} : undef,
   };
}

sub serve_module_list($c) {
   return undef unless $c->check_branch_exists;
   return $c->render(status => 400, json => { error => 'Supply only one of after and before' })
      if defined $c->param('after') && defined $c->param('before');
   my $index= $c->_module_index
      or return $c->render(status => 404, json => { error => 'No package index in this tree' });
   $c->render(json => $c->_module_page($index));
}

sub serve_index($c) {
   return undef unless $c->check_branch_exists;
   my $index= $c->_module_index
      or return $c->render(status => 404, text => 'No package index in this tree');
   my $atree= $c->archive_tree;
   my $origin= $atree->branch;
   (undef, $origin)= $c->cpan_repo->lookup_tree($c->branch_name // $atree->name)
      unless $origin;
   $origin= $origin->target while $origin && $origin->isa('Git::Raw::Tag');
   my $commit= !$origin? undef
      : $origin->isa('Git::Raw::Commit')? $origin : $origin->peel('commit');
   my $base= $c->url_for->query(undef);
   my $base_path= $base->path->to_string =~ s{/*$}{/}r;
   $c->render(inline => $c->_share_dir->child('archive_tree_index.html.ep')->slurp('UTF-8'), handler => 'ep', format => 'html',
      module_page => $c->_module_page($index), index_updated => $index->{updated},
      commit_date => $commit? gmtime($commit->time)->strftime('%a, %d %b %Y %H:%M:%S GMT') : undef,
      tree_name => $c->branch_name // $atree->name,
      json_url => $base->clone->path($base_path.'modules/'),
      script_url => $c->url_for('/~static/archive_tree_index.js'),
      authors_url => $base->clone->path($base_path.'authors/id/'));
}

=method check_branch_exists

This checks that the L</branch_name> could be successfully resolved to a L</archive_tree>.
It returns true, or sets a 404 error and returns undef, and can be used as C<< ->under(\&check_branch_exists) >>.

=cut

sub check_branch_exists($c) {
   unless ($c->archive_tree) {
      $c->render(text => 'Git branch does not exist', status => 404);
      return undef;
   }
   return 1;
}

=method serve_package_details

Serve C<< modules/02packages.details.txt[.gz] >>.

=cut

sub serve_package_details($c) {
   return undef unless $c->check_branch_exists;
   my $blob= $c->archive_tree->package_details_blob;
   $c->respond_to(
      txt      => sub { $c->render(text => $blob->content) },
      'txt.gz' => sub { $c->render_gzipped($blob->content, '02packages.details.txt.gz') },
   );
}

=method serve_author_file

Serve all files under C<< authors/id/... >>.  (All files in that path of the git branch are considered public)
This performs automatic creation of .tar.gz files if a directory and matching .meta file exist,
allowing distributions to be unpacked within the git repo, but served as .tar.gz files.

=cut

sub serve_author_file($c) {
   return undef unless $c->check_branch_exists;
   my $path= 'authors/id/'.$c->stash->{author_path};
   # cpanm adds extra '/' when the path name doesn't match the expected A/AU/AUTHOR format
   $path =~ s,//+,/,g;
   my ($basename)= ($path =~ m,([^/]+)\z,);
   # Does the exact file exist?
   my $ent= $c->archive_tree->get_path($path);
   $c->log->debug("Path $path is ".($ent? ($ent->[0]->is_blob? 'blob ':'tree ').$ent->[0]->id : '<undef>'));
   if ($ent) {
      if ($ent->[0]->is_blob) {
         $c->res->headers->content_disposition(qq{attachment; filename="$basename"});
         $c->render(data => $ent->[0]->content);
      } else {
         $c->render(status => 403, text => 'not a file');
      }
   }
   elsif ($path =~ /(.*?)\.gz\z/
      && ($ent= $c->archive_tree->get_path($1)) && $ent->[0]->is_blob
   ) {
      $c->log->debug("Path $1 is ".$ent->[0]->id.', will gzip it');
      $c->render_gzipped($ent->[0]->content, $basename);
   }
   elsif ($path =~ /(.*?)\.tar\.gz\z/
      # Don't auto-tar trees that don't look like distributions
      && ($ent= $c->archive_tree->get_path("$1.meta")) && $ent->[0]->is_blob
      && ($ent= $c->archive_tree->get_path($1)) && $ent->[0]->is_tree
   ) {
      $c->log->debug("Path $1 is ".$ent->[0]->id.', will tar+gzip it');
      my $tar= Archive::Tar->new;
      $c->cpan_repo->add_git_tree_to_tar($tar, substr($basename, 0, -7), $ent->[0]);
      $c->render_gzipped($tar->write, $basename);
   }
   else {
      $c->render(status => 404, text => 'No such path in branch');
   }
}

=method render_gzipped

Serve content after gzipping it and setting the content type to C<< application/gzip >>.

=cut

sub render_gzipped($c, $data, $filename='') {
   my $gzipped;
   gzip \$data => \$gzipped
     or return $c->reply->exception("gzip failed: $GzipError");
   $c->res->headers->content_type('application/gzip');
   $c->res->headers->content_disposition(qq{attachment; filename="$filename"})
      if length $filename;
   return $c->render(data => $gzipped);
}

1;
