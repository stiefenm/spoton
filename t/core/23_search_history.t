#!/usr/bin/perl
use strict;
use warnings;
use Test::More;
use File::Basename qw(dirname);
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use Cwd qw(abs_path);

my $test_dir    = dirname(abs_path($0));
my $project_dir = dirname(dirname($test_dir));   # t/<group>/x.t -> repo root
die "wrong project root: $project_dir" unless -f "$project_dir/Plugins/SpotOn/Plugin.pm";

my $stub_dir  = tempdir(CLEANUP => 1);
my $cache_dir = tempdir(CLEANUP => 1);

sub write_stub {
    my ($dir, $pkg, $code) = @_;
    my @parts = split /::/, $pkg;
    my $file  = pop @parts;
    my $path  = $dir . '/' . join('/', @parts);
    make_path($path) unless -d $path;
    open(my $fh, '>', "$path/$file.pm") or die "Cannot write stub $pkg: $!";
    print $fh $code;
    close($fh);
}

write_stub($stub_dir, 'Log::Log4perl::Logger', <<'END');
package Log::Log4perl::Logger;
sub new     { bless {}, shift }
sub AUTOLOAD { }
sub can     { 1 }
1;
END

write_stub($stub_dir, 'Log::Log4perl', <<'END');
package Log::Log4perl;
sub get_logger { return bless {}, 'Log::Log4perl::Logger' }
sub init { }
1;
END

write_stub($stub_dir, 'Slim::Utils::Log', <<'END');
package Slim::Utils::Log;
use parent 'Exporter';
our @EXPORT_OK = qw(logger);
sub import {
    my $class = shift;
    my $caller = caller;
    no strict 'refs';
    *{"${caller}::logger"} = \&logger;
}
sub addLogCategory { return bless {}, 'Slim::Utils::Log' }
sub logger { return bless {}, 'Slim::Utils::Log' }
sub info     { }
sub warn     { }
sub error    { }
sub debug    { }
sub is_info  { 0 }
sub is_debug { 0 }
sub AUTOLOAD { }
sub can      { 1 }
1;
END

my $prefs_cache_dir = $cache_dir;
write_stub($stub_dir, 'Slim::Utils::Prefs', <<"END");
package Slim::Utils::Prefs;
my %_store;
my %_ns_store = ( server => { cachedir => '$prefs_cache_dir' } );

sub import {
    my \$class = shift;
    my \$caller = caller;
    no strict 'refs';
    *{"\${caller}::preferences"} = \\&preferences;
}

sub preferences {
    my \$ns = \$_[0] eq 'Slim::Utils::Prefs' ? \$_[1] : \$_[0];
    return bless { _ns => \$ns }, 'Slim::Utils::Prefs';
}

sub init {
    my (\$self, \$defaults) = \@_;
    for my \$k (keys \%{\$defaults}) {
        \$_store{ \$self->{_ns} }{\$k} //= \$defaults->{\$k};
    }
}

sub get {
    my (\$self, \$key) = \@_;
    if (exists \$_ns_store{ \$self->{_ns} }) {
        return \$_ns_store{ \$self->{_ns} }{\$key};
    }
    return \$_store{ \$self->{_ns} }{\$key};
}

sub set {
    my (\$self, \$key, \$val) = \@_;
    \$_store{ \$self->{_ns} }{\$key} = \$val;
}

sub client {
    my (\$self, \$client) = \@_;
    my \$client_id = ref \$client ? "\$client" : (\$client // 'default');
    return bless { _ns => \$self->{_ns} . '_client_' . \$client_id }, 'Slim::Utils::Prefs';
}

sub setChange { }
sub AUTOLOAD  { }
1;
END

write_stub($stub_dir, 'Slim::Utils::Cache', <<'END');
package Slim::Utils::Cache;
my %_store;
sub new    { bless {}, shift }
sub get    { $_store{$_[1]} }
sub set    { $_store{$_[1]} = $_[2]; 1 }
sub remove { delete $_store{$_[1]} }
sub clear  { %_store = () }
1;
END

write_stub($stub_dir, 'Slim::Utils::Timers', <<'END');
package Slim::Utils::Timers;
sub setTimer   { }
sub killTimers { }
1;
END

write_stub($stub_dir, 'Slim::Utils::Strings', <<'END');
package Slim::Utils::Strings;
use parent 'Exporter';
our @EXPORT_OK = qw(string cstring);
sub import {
    my $class = shift;
    my $caller = caller;
    no strict 'refs';
    for my $fn (@_) {
        *{"${caller}::${fn}"} = \&{$fn};
    }
}
sub string  { $_[-1] }
sub cstring { $_[-1] }
1;
END

write_stub($stub_dir, 'Slim::Utils::Unicode', <<'END');
package Slim::Utils::Unicode;
sub utf8toLatin1Transliterate { $_[1] }
1;
END

write_stub($stub_dir, 'Slim::Networking::SimpleAsyncHTTP', <<'END');
package Slim::Networking::SimpleAsyncHTTP;
sub new  { bless {}, shift }
sub get  { }
sub post { }
1;
END

write_stub($stub_dir, 'Slim::Control::Request', <<'END');
package Slim::Control::Request;
sub subscribe       { }
sub addDispatch     { }
sub executeRequest  { }
1;
END

write_stub($stub_dir, 'Slim::Plugin::OPMLBased', <<'END');
package Slim::Plugin::OPMLBased;
sub new  { bless {}, shift }
sub initPlugin { }
sub can  { 1 }
sub AUTOLOAD { }
1;
END

write_stub($stub_dir, 'Slim::Utils::PluginManager', <<'END');
package Slim::Utils::PluginManager;
sub isEnabled { 1 }
1;
END

write_stub($stub_dir, 'JSON::XS', <<'END');
package JSON::XS;
use parent 'Exporter';
our @EXPORT_OK = qw(encode_json decode_json);
sub encode_json { '{}' }
sub decode_json { {} }
1;
END

write_stub($stub_dir, 'Digest::MD5', <<'END');
package Digest::MD5;
use parent 'Exporter';
our @EXPORT_OK = qw(md5_hex);
sub md5_hex { 'deadbeef' }
1;
END

BEGIN {
    no warnings 'redefine';
    *main::TRANSCODING = sub () { 0 };
    *main::WEBUI       = sub () { 0 };
    *main::SCANNER     = sub () { 0 };
    *main::INFOLOG     = sub () { 0 };
    *main::DEBUGLOG    = sub () { 0 };
    *main::ISWINDOWS   = sub () { 0 };
    *main::ISMAC       = sub () { 0 };
    *main::PERFMON     = sub () { 0 };
}

unshift @INC, $stub_dir, $project_dir;

# Load the module and initialize prefs
require Plugins::SpotOn::Plugin;

my $prefs = Slim::Utils::Prefs::preferences('plugin.spoton');
$prefs->init({ recentSearches => [] });

# ============================================================
# _addRecentSearch tests
# ============================================================

subtest '_addRecentSearch basics' => sub {
    $prefs->set('recentSearches', []);

    Plugins::SpotOn::Plugin::_addRecentSearch('alpha');
    is_deeply($prefs->get('recentSearches'), ['alpha'], 'single add');

    Plugins::SpotOn::Plugin::_addRecentSearch('beta');
    is_deeply($prefs->get('recentSearches'), ['alpha', 'beta'], 'second add appended');

    Plugins::SpotOn::Plugin::_addRecentSearch('gamma');
    is_deeply($prefs->get('recentSearches'), ['alpha', 'beta', 'gamma'], 'third add appended');
};

subtest '_addRecentSearch dedup moves to newest' => sub {
    $prefs->set('recentSearches', ['alpha', 'beta', 'gamma']);

    Plugins::SpotOn::Plugin::_addRecentSearch('alpha');
    is_deeply($prefs->get('recentSearches'), ['beta', 'gamma', 'alpha'], 'alpha moved to end');
};

subtest '_addRecentSearch no-op when already newest' => sub {
    $prefs->set('recentSearches', ['beta', 'gamma', 'alpha']);

    Plugins::SpotOn::Plugin::_addRecentSearch('alpha');
    is_deeply($prefs->get('recentSearches'), ['beta', 'gamma', 'alpha'], 'no change when already newest');
};

subtest '_addRecentSearch cap at MAX_RECENT_SEARCHES' => sub {
    my @entries = map { "query_$_" } 1..50;
    $prefs->set('recentSearches', \@entries);
    is(scalar @{$prefs->get('recentSearches')}, 50, 'starts at 50');

    Plugins::SpotOn::Plugin::_addRecentSearch('query_51');
    my $list = $prefs->get('recentSearches');
    is(scalar @$list, 50, 'still capped at 50');
    is($list->[0], 'query_2', 'oldest dropped');
    is($list->[-1], 'query_51', 'newest at end');
};

subtest '_addRecentSearch edge cases' => sub {
    $prefs->set('recentSearches', ['existing']);

    Plugins::SpotOn::Plugin::_addRecentSearch(undef);
    is_deeply($prefs->get('recentSearches'), ['existing'], 'undef ignored');

    Plugins::SpotOn::Plugin::_addRecentSearch('');
    is_deeply($prefs->get('recentSearches'), ['existing'], 'empty string ignored');

    Plugins::SpotOn::Plugin::_addRecentSearch('   ');
    is_deeply($prefs->get('recentSearches'), ['existing'], 'whitespace-only ignored');

    Plugins::SpotOn::Plugin::_addRecentSearch('x' x 257);
    is_deeply($prefs->get('recentSearches'), ['existing'], 'oversized query ignored');

    Plugins::SpotOn::Plugin::_addRecentSearch('  trimmed  ');
    is_deeply($prefs->get('recentSearches'), ['existing', 'trimmed'], 'whitespace trimmed');
};

# ============================================================
# _recentSearches accessor tests
# ============================================================

subtest '_recentSearches accessor' => sub {
    $prefs->set('recentSearches', ['a', 'b']);
    is_deeply(Plugins::SpotOn::Plugin::_recentSearches(), ['a', 'b'], 'returns list');

    $prefs->set('recentSearches', undef);
    is_deeply(Plugins::SpotOn::Plugin::_recentSearches(), [], 'undef returns empty');

    $prefs->set('recentSearches', 'not_an_array');
    is_deeply(Plugins::SpotOn::Plugin::_recentSearches(), [], 'non-array returns empty');
};

# ============================================================
# _recentSearchesCLI tests
# ============================================================

{
    package FakeRequest;
    sub new {
        my ($class, %params) = @_;
        bless { params => \%params, status => undef, results => {} }, $class;
    }
    sub client { undef }
    sub isNotQuery {
        my ($self, $match) = @_;
        return 0;
    }
    sub getParam {
        my ($self, $key) = @_;
        return $self->{params}{$key};
    }
    sub setStatusDone      { $_[0]->{status} = 'done' }
    sub setStatusBadParams { $_[0]->{status} = 'bad_params' }
    sub setStatusBadDispatch { $_[0]->{status} = 'bad_dispatch' }
    sub addResult {
        my ($self, $key, $val) = @_;
        $self->{results}{$key} = $val;
    }
}

subtest 'CLI confirm_delete by value' => sub {
    $prefs->set('recentSearches', ['alpha', 'beta', 'gamma']);

    my $req = FakeRequest->new(confirm_delete => 'beta');
    Plugins::SpotOn::Plugin::_recentSearchesCLI($req);
    is($req->{status}, 'done', 'status done');
    is_deeply($prefs->get('recentSearches'), ['alpha', 'gamma'], 'beta removed by value');
};

subtest 'CLI confirm_delete nonexistent is no-op' => sub {
    $prefs->set('recentSearches', ['alpha', 'gamma']);

    my $req = FakeRequest->new(confirm_delete => 'nonexistent');
    Plugins::SpotOn::Plugin::_recentSearchesCLI($req);
    is($req->{status}, 'done', 'status done');
    is_deeply($prefs->get('recentSearches'), ['alpha', 'gamma'], 'list unchanged');
};

subtest 'CLI deleteAll' => sub {
    $prefs->set('recentSearches', ['alpha', 'beta', 'gamma']);

    my $req = FakeRequest->new(deleteAll => 1);
    Plugins::SpotOn::Plugin::_recentSearchesCLI($req);
    is($req->{status}, 'done', 'status done');
    is_deeply($prefs->get('recentSearches'), [], 'list cleared');
};

subtest 'CLI delete shows context menu' => sub {
    $prefs->set('recentSearches', ['alpha', 'beta']);

    my $req = FakeRequest->new(delete => 'alpha');
    Plugins::SpotOn::Plugin::_recentSearchesCLI($req);
    is($req->{status}, 'done', 'status done');
    is($req->{results}{count}, 2, 'context menu has 2 items');
    ok($req->{results}{item_loop}, 'item_loop present');
};

subtest 'CLI delete nonexistent entry rejects' => sub {
    $prefs->set('recentSearches', ['alpha']);

    my $req = FakeRequest->new(delete => 'nonexistent');
    Plugins::SpotOn::Plugin::_recentSearchesCLI($req);
    is($req->{status}, 'bad_params', 'bad_params for unknown entry');
};

subtest 'CLI no params rejects' => sub {
    my $req = FakeRequest->new();
    Plugins::SpotOn::Plugin::_recentSearchesCLI($req);
    is($req->{status}, 'bad_params', 'bad_params when no mode given');
};

# ============================================================
# H-01 regression: delete must target the correct entry even after reordering
# ============================================================

subtest 'H-01 regression: delete after reorder' => sub {
    $prefs->set('recentSearches', ['alpha', 'beta', 'gamma']);

    Plugins::SpotOn::Plugin::_addRecentSearch('alpha');
    is_deeply($prefs->get('recentSearches'), ['beta', 'gamma', 'alpha'],
        'alpha moved to newest');

    my $req = FakeRequest->new(confirm_delete => 'alpha');
    Plugins::SpotOn::Plugin::_recentSearchesCLI($req);
    is_deeply($prefs->get('recentSearches'), ['beta', 'gamma'],
        'alpha deleted by value regardless of position');
};

done_testing;
