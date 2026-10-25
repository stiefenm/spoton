#!/usr/bin/perl
# Phase 85 plan 10 Task 3 (D-02, D-03): one-way migration of existing accounts.
#
# AccountMigration->run() keeps an account whose credentials.json username
# already hashes to its id (D-02 silent), re-keys one whose username hashes to
# another id (D-03) with a write-ahead journal, and marks accounts without
# usable ZeroConf credentials needsPairing (hint, nothing deleted).
#
# The re-key order is: (1) prefs entry + activeAccount (global and per player)
# + journal entry in ONE prefs save (savenow), (2) directory rename,
# (3) old-id cache keys, (4) journal cleared (savenow). The rename and the
# cache-removal step are injectable ($RENAME_STEP / $CACHE_STEP) so a test can
# make each die -- the "crash" tests below.
#
# Stubs: temp cachedir, prefs with per-client prefs + recorded savenow, cache
# recording remove(), log recording (level, message), SpClient with SET_MAP.
use strict;
use warnings;
use Test::More;
use File::Basename qw(dirname);
use File::Temp qw(tempdir);
use File::Path qw(make_path remove_tree);
use Cwd qw(abs_path);
use Digest::MD5 qw(md5_hex);
use File::Spec::Functions qw(catdir catfile);

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

# ---- Slim::Utils::Log: records (level, message) ----
write_stub($stub_dir, 'Slim::Utils::Log', <<'END');
package Slim::Utils::Log;
our @logged = ();      # [level, message]
sub import {
    my $class = shift;
    my $caller = caller;
    no strict 'refs';
    *{"${caller}::logger"} = \&logger;
}
sub addLogCategory { return bless {}, 'Slim::Utils::Log' }
sub logger { return bless {}, 'Slim::Utils::Log' }
sub info  { push @logged, ['info',  $_[1]] if defined $_[1]; }
sub warn  { push @logged, ['warn',  $_[1]] if defined $_[1]; }
sub error { push @logged, ['error', $_[1]] if defined $_[1]; }
sub debug { push @logged, ['debug', $_[1]] if defined $_[1]; }
sub is_info  { 1 }
sub is_debug { 0 }
sub AUTOLOAD { }
sub can { 1 }
1;
END

# ---- Slim::Utils::Prefs: namespaces, per-client prefs, recorded savenow ----
write_stub($stub_dir, 'Slim::Utils::Prefs', <<'END');
package Slim::Utils::Prefs;
our %store;          # ns => key => value
our %clientstore;    # ns => clientid => { key => value }
our %server = ();    # the 'server' namespace (cachedir)
sub import {
    my $class = shift;
    my $caller = caller;
    no strict 'refs';
    *{"${caller}::preferences"} = \&preferences;
}
sub preferences {
    my $ns = $_[0] eq 'Slim::Utils::Prefs' ? $_[1] : $_[0];
    return bless { _ns => $ns }, 'Slim::Utils::Prefs';
}
sub get {
    my ($self, $key) = @_;
    return $server{$key} if $self->{_ns} eq 'server';
    return $store{ $self->{_ns} }{$key};
}
sub set {
    my ($self, $key, $val) = @_;
    if ($self->{_ns} eq 'server') { $server{$key} = $val; return; }
    $store{ $self->{_ns} }{$key} = $val;
}
sub remove { my ($self, $key) = @_; delete $store{ $self->{_ns} }{$key}; }
sub client {
    my ($self, $c) = @_;
    my $id = ref $c ? $c->{id} : $c;
    return bless { _ns => $self->{_ns}, _cid => $id }, 'Slim::Utils::Prefs::ClientObj';
}
sub allClients {
    my ($self) = @_;
    return map { bless { _ns => $self->{_ns}, _cid => $_ }, 'Slim::Utils::Prefs::ClientObj' }
        sort keys %{ $clientstore{ $self->{_ns} } || {} };
}
sub savenow { push @main::EVENTS, 'savenow'; }
sub setChange { }
sub AUTOLOAD  { }

package Slim::Utils::Prefs::ClientObj;
sub get {
    my ($self, $key) = @_;
    return $Slim::Utils::Prefs::clientstore{ $self->{_ns} }{ $self->{_cid} }{$key};
}
sub set {
    my ($self, $key, $val) = @_;
    $Slim::Utils::Prefs::clientstore{ $self->{_ns} }{ $self->{_cid} }{$key} = $val;
}
sub remove {
    my ($self, $key) = @_;
    delete $Slim::Utils::Prefs::clientstore{ $self->{_ns} }{ $self->{_cid} }{$key};
}
1;
END

write_stub($stub_dir, 'Slim::Utils::Cache', <<'END');
package Slim::Utils::Cache;
our %_store;
our @removed = ();
sub new    { bless {}, shift }
sub get    { $_store{$_[1]} }
sub set    { $_store{$_[1]} = $_[2]; 1 }
sub remove { push @removed, $_[1]; delete $_store{$_[1]} }
sub clear  { %_store = () }
1;
END

write_stub($stub_dir, 'Slim::Utils::Timers', <<'END');
package Slim::Utils::Timers;
sub setTimer  { }
sub killTimers { }
1;
END

write_stub($stub_dir, 'JSON::XS::VersionOneAndTwo', <<'END');
package JSON::XS::VersionOneAndTwo;
use parent 'Exporter';
our @EXPORT = qw(from_json to_json);
use JSON::PP ();
sub from_json { JSON::PP::decode_json($_[0]) }
sub to_json   { JSON::PP::encode_json($_[0]) }
1;
END

# SpClient: only SET_MAP matters (same shape as the real constant).
write_stub($stub_dir, 'Plugins::SpotOn::API::SpClient', <<'END');
package Plugins::SpotOn::API::SpClient;
use constant SET_MAP => {
    albums           => 'collection',
    liked_tracks     => 'collection',
    artists          => 'artist',
    shows            => 'show',
    pinned_playlists => 'ylpin',
    saved_episodes   => 'listenlater',
};
1;
END

BEGIN {
    no warnings 'redefine';
    *main::TRANSCODING = sub () { 0 };
    *main::WEBUI       = sub () { 0 };
    *main::SCANNER     = sub () { 0 };
    *main::INFOLOG     = sub () { 1 };
    *main::ISWINDOWS   = sub () { 0 };
    *main::ISMAC       = sub () { 0 };
    *main::PERFMON     = sub () { 0 };
}
BEGIN {
    package Plugins::SpotOn::Plugin;
    use constant SPOTON_CACHE_VERSION => 4;
}

unshift @INC, $stub_dir, $project_dir;

require Slim::Utils::Prefs;   Slim::Utils::Prefs->import();
require Slim::Utils::Log;     Slim::Utils::Log->import();
require Slim::Utils::Cache;
require Slim::Utils::Timers;
require JSON::PP;
require Plugins::SpotOn::API::SpClient;

$Slim::Utils::Prefs::server{cachedir} = $cache_dir;

our @EVENTS = ();

my $prefs = preferences('plugin.spoton');

my $LOADED = eval { require Plugins::SpotOn::API::Credentials; require Plugins::SpotOn::API::AccountMigration; 1 };
diag("load error: $@") unless $LOADED;
ok($LOADED, 'AccountMigration.pm and Credentials.pm load');
my $AM = 'Plugins::SpotOn::API::AccountMigration';

# ---- helpers ----
sub id_for      { substr(md5_hex($_[0]), 0, 8) }
sub mask        { substr($_[0], 0, 4) . '****' }
sub account_dir { catdir($cache_dir, 'spoton', $_[0]) }
sub slurp       { open(my $fh, '<', $_[0]) or die "slurp $_[0]: $!"; local $/; my $c = <$fh>; close($fh); $c }

sub write_json {
    my ($dir, $name, $data) = @_;
    make_path($dir) unless -d $dir;
    my $file = catfile($dir, $name);
    open(my $fh, '>', $file) or die "write_json: $!";
    print $fh JSON::PP::encode_json($data);
    close($fh);
    return $file;
}

sub reset_world {
    remove_tree(catdir($cache_dir, 'spoton'));
    %Slim::Utils::Prefs::store       = ();
    %Slim::Utils::Prefs::clientstore = ();
    %Slim::Utils::Cache::_store      = ();
    @Slim::Utils::Cache::removed     = ();
    @Slim::Utils::Log::logged        = ();
    @EVENTS = ();
    $prefs->set(accounts              => {});
    $prefs->set(activeAccount         => '');
    $prefs->set(authChainRekeyPending => {});
    $prefs->set(clientId              => 'KEEP-CLIENT-ID');
    {
        no warnings 'once';
        $Plugins::SpotOn::API::AccountMigration::RENAME_STEP = \&Plugins::SpotOn::API::AccountMigration::_renameDir;
        $Plugins::SpotOn::API::AccountMigration::CACHE_STEP  = \&Plugins::SpotOn::API::AccountMigration::_removeCacheKeys;
    }
}

# seed_account(id => ..., username => ..., source => 'zeroconf'|''|..., nocreds => 1)
sub seed_account {
    my (%a) = @_;
    my $source = exists $a{source} ? $a{source} : 'zeroconf';
    my $accounts = $prefs->get('accounts') || {};
    $accounts->{ $a{id} } = {
        displayName   => "Name-$a{id}",
        sp_dc         => "spdc-$a{id}",
        spotifyUserId => 'legacy-me-id',
        ($source ? (playbackCredSource => $source) : ()),
    };
    $prefs->set(accounts => $accounts);
    my $dir = account_dir($a{id});
    make_path($dir);
    write_json($dir, 'pkce_tokens.json', { access_token => "tok-$a{id}" });
    write_json($dir, 'credentials.json',
        { auth_type => 1, username => $a{username}, auth_data => 'QUFB' }) unless $a{nocreds};
}

my @SET_VALUES = qw(collection artist show ylpin listenlater);
sub old_cache_keys {
    my ($id) = @_;
    return (
        (map { "spoton_${_}_$id" } qw(token needs_reauth needs_playback_auth login5_token
                                      last_api_call spclient_liked
                                      wp_token wp_client_token wp_state)),
        (map { "spoton_spclient_coll_${id}_$_" } @SET_VALUES),
    );
}
sub seed_cache_keys {
    my ($id) = @_;
    # The playback-auth flag is not seeded: a flagged account is not re-keyed (it
    # gets needsPairing), so a re-keyed account never carries one.
    Slim::Utils::Cache->new->set($_, "v-$_") for grep { !/needs_playback_auth/ } old_cache_keys($id);
}
sub cache_leftovers {
    my ($id) = @_;
    my $c = Slim::Utils::Cache->new;
    return grep { defined $c->get($_) } old_cache_keys($id);
}

sub wlog {   # [level, message] entries whose message matches
    my ($re) = @_;
    return grep { $_->[1] =~ $re } @Slim::Utils::Log::logged;
}

sub list_files {
    my @out;
    my $root = catdir($cache_dir, 'spoton');
    return () unless -d $root;
    require File::Find;
    File::Find::find({ no_chdir => 1, wanted => sub {
        my $rel = substr($File::Find::name, length($root));
        push @out, $rel if length $rel;
    } }, $root);
    return sort @out;
}

sub snapshot {
    my $json = JSON::PP->new->canonical(1);
    return $json->encode({
        accounts => $prefs->get('accounts'),
        active   => $prefs->get('activeAccount'),
        clients  => $Slim::Utils::Prefs::clientstore{'plugin.spoton'},
        journal  => $prefs->get('authChainRekeyPending'),
        client_id => $prefs->get('clientId'),
        files    => [ list_files() ],
    });
}

# The fixture of the re-key scenarios: account 'bbbbbbbb' whose credentials
# username (bob) hashes to another id; global + two players point at it, a
# third player points elsewhere.
my $OLD   = 'bbbbbbbb';
my $NEW   = id_for('bob');
my $OTHER = 'dddddddd';

sub seed_rekey_world {
    reset_world();
    seed_account(id => $OLD, username => 'bob');
    seed_account(id => $OTHER, username => 'dave-not-hashing-to-dddddddd', nocreds => 1);
    $prefs->set(activeAccount => $OLD);
    $Slim::Utils::Prefs::clientstore{'plugin.spoton'} = {
        'aa:aa' => { activeAccount => $OLD },
        'bb:bb' => { activeAccount => $OLD },
        'cc:cc' => { activeAccount => $OTHER },
    };
    seed_cache_keys($OLD);
    Slim::Utils::Cache->new->set("spoton_token_$OTHER", 'survivor');
    @Slim::Utils::Cache::removed = ();
    @EVENTS = ();
}

# Run a block, report a death as a diag so a RED run shows the cause.
sub attempt (&) {
    my ($code) = @_;
    my $r = eval { $code->() };
    diag("died: $@") if $@;
    return $r;   # always exactly one value, so is(attempt {...}, ...) keeps its argument positions
}

# ============================================================
# accountIdFor
# ============================================================
is(attempt { $AM->accountIdFor('alice') }, substr(md5_hex('alice'), 0, 8),
    'accountIdFor: first 8 hex of md5(username)');

{
    my $wide = "J\x{fc}rgen\x{263a}";
    my $id = attempt { $AM->accountIdFor($wide) };
    like($id // '', qr/\A[0-9a-f]{8}\z/, 'accountIdFor: a wide-character username is UTF-8 encoded, not a croak');
}

is(attempt { Plugins::SpotOn::API::Credentials::_accountIdForUsername('alice') },
    attempt { $AM->accountIdFor('alice') },
    'Credentials::_accountIdForUsername delegates to the single definition');

# ============================================================
# same id (D-02 silent)
# ============================================================
{
    my $ALICE = id_for('alice');
    reset_world();
    seed_account(id => $ALICE, username => 'alice');
    my $before_pkce = slurp(catfile(account_dir($ALICE), 'pkce_tokens.json'));
    attempt { $AM->run };

    my $acct = ($prefs->get('accounts') || {})->{$ALICE} || {};
    is($acct->{spotifyUserId}, 'alice', 'same id: spotifyUserId is set to the credentials username');
    ok(!$acct->{needsPairing}, 'same id: needsPairing absent');
    is($acct->{displayName} . '|' . $acct->{sp_dc} . '|' . $acct->{playbackCredSource},
        "Name-$ALICE|spdc-$ALICE|zeroconf", 'same id: displayName / sp_dc / playbackCredSource untouched');
    ok(slurp(catfile(account_dir($ALICE), 'pkce_tokens.json')) eq $before_pkce
        && $prefs->get('clientId') eq 'KEEP-CLIENT-ID',
        'same id: the PKCE token file and the clientId pref are untouched (85-13/85-14)');
    my @l = wlog(qr/\AAuth chain migration: account \Q@{[mask($ALICE)]}\E kept \(same id\)\z/);
    is(scalar(@l) . ':' . ($l[0] ? $l[0][0] : 'none'), '1:warn',
        'same id: summary line "kept (same id)" is logged at WARN level');
}

# ============================================================
# re-key (D-03)
# ============================================================
{
    seed_rekey_world();
    my $orig_dir_pkce = slurp(catfile(account_dir($OLD), 'pkce_tokens.json'));
    # record the call order of the three side-effecting steps
    {
        no warnings 'redefine';
        my $r = $Plugins::SpotOn::API::AccountMigration::RENAME_STEP;
        my $c = $Plugins::SpotOn::API::AccountMigration::CACHE_STEP;
        $Plugins::SpotOn::API::AccountMigration::RENAME_STEP = sub { push @EVENTS, 'rename'; $r->(@_) };
        $Plugins::SpotOn::API::AccountMigration::CACHE_STEP  = sub { push @EVENTS, 'cache';  $c->(@_) };
    }
    attempt { $AM->run };
    my $accounts = $prefs->get('accounts') || {};

    ok(!exists $accounts->{$OLD} && exists $accounts->{$NEW},
        're-key: prefs entry moved from the old to the new id');
    is(join('|', map { $accounts->{$NEW}{$_} // '' } qw(displayName sp_dc playbackCredSource spotifyUserId)),
        "Name-$OLD|spdc-$OLD|zeroconf|bob",
        're-key: displayName / sp_dc / playbackCredSource kept, spotifyUserId = username');
    is($prefs->get('activeAccount'), $NEW, 're-key: global activeAccount rewritten');
    my $cl = $Slim::Utils::Prefs::clientstore{'plugin.spoton'} || {};
    is(join('|', map { $cl->{$_}{activeAccount} // '' } qw(aa:aa bb:bb cc:cc)), "$NEW|$NEW|$OTHER",
        're-key: per-client activeAccount of both players rewritten, a player on another account untouched');
    ok(!-d account_dir($OLD) && -f catfile(account_dir($NEW), 'credentials.json')
        && slurp(catfile(account_dir($NEW), 'pkce_tokens.json')) eq $orig_dir_pkce,
        're-key: directory renamed, credentials.json and the PKCE token file moved with it');
    is(join(',', cache_leftovers($OLD)), '', 're-key: every old-id cache key removed');
    is(Slim::Utils::Cache->new->get("spoton_token_$OTHER"), 'survivor',
        're-key: a cache key of another account survives');
    is_deeply($prefs->get('authChainRekeyPending'), {}, 're-key: journal empty afterwards');
    my @l = wlog(qr/\AAuth chain migration: account \Q@{[mask($OLD)]}\E re-keyed to \Q@{[mask($NEW)]}\E\z/);
    is(scalar(@l) . ':' . ($l[0] ? $l[0][0] : 'none'), '1:warn',
        're-key: WARN log names the masked old and new id');
    is(join(',', @EVENTS), 'savenow,rename,cache,savenow',
        're-key: prefs + journal saved with savenow BEFORE the rename; cache removal; journal cleared with savenow');
}

# ============================================================
# crash between steps
# ============================================================
my $uninterrupted;
{
    seed_rekey_world();
    attempt { $AM->run };
    $uninterrupted = snapshot();
    my @removed = sort keys %{{ map { $_ => 1 } @Slim::Utils::Cache::removed }};
    $uninterrupted .= '|' . join(',', @removed);
}
# The reference must itself be a real end state, or the equality checks below
# would pass vacuously on two identical empty runs.
like($uninterrupted, qr/"\Q$NEW\E"/, 'uninterrupted run: the reference end state holds the re-keyed account');

{
    seed_rekey_world();
    {
        no warnings 'once';
        $Plugins::SpotOn::API::AccountMigration::RENAME_STEP = sub { die "simulated crash before the rename\n" };
    }
    attempt { $AM->run };
    my $accounts = $prefs->get('accounts') || {};
    my $j = $prefs->get('authChainRekeyPending') || {};
    ok(exists $accounts->{$NEW} && !exists $accounts->{$OLD} && ($j->{$OLD} // '') eq $NEW && -d account_dir($OLD) && !-d account_dir($NEW),
        'crash after the prefs save: prefs show the new id + journal entry, directory still the old one');

    {
        no warnings 'once';
        $Plugins::SpotOn::API::AccountMigration::RENAME_STEP = \&Plugins::SpotOn::API::AccountMigration::_renameDir;
    }
    attempt { $AM->run };
    my @removed = sort keys %{{ map { $_ => 1 } @Slim::Utils::Cache::removed }};
    is(snapshot() . '|' . join(',', @removed), $uninterrupted,
        'crash after the prefs save: the second run() finishes with the same end state as an uninterrupted run');
}

{
    seed_rekey_world();
    {
        no warnings 'once';
        $Plugins::SpotOn::API::AccountMigration::CACHE_STEP = sub { die "simulated crash before the cache removal\n" };
    }
    attempt { $AM->run };
    my $j = $prefs->get('authChainRekeyPending') || {};
    ok(-d account_dir($NEW) && !-d account_dir($OLD) && ($j->{$OLD} // '') eq $NEW && scalar(cache_leftovers($OLD)) > 0,
        'crash after the rename: directory renamed, journal entry and old cache keys still there');

    {
        no warnings 'once';
        $Plugins::SpotOn::API::AccountMigration::CACHE_STEP = \&Plugins::SpotOn::API::AccountMigration::_removeCacheKeys;
    }
    attempt { $AM->run };
    my @removed = sort keys %{{ map { $_ => 1 } @Slim::Utils::Cache::removed }};
    is(snapshot() . '|' . join(',', @removed), $uninterrupted,
        'crash after the rename: the second run() removes the keys, clears the journal, same end state');
}

{
    seed_rekey_world();
    # state as left by a run that crashed after the rename AND the key removal:
    # journal entry, old dir gone, new dir present
    my $accounts = $prefs->get('accounts');
    $accounts->{$NEW} = delete $accounts->{$OLD};
    $accounts->{$NEW}{spotifyUserId} = 'bob';
    $prefs->set(accounts => $accounts);
    $prefs->set(activeAccount => $NEW);
    rename(account_dir($OLD), account_dir($NEW)) or die "fixture rename: $!";
    $prefs->set(authChainRekeyPending => { $OLD => $NEW });
    @EVENTS = ();
    {
        no warnings 'redefine';
        my $r = $Plugins::SpotOn::API::AccountMigration::RENAME_STEP;
        $Plugins::SpotOn::API::AccountMigration::RENAME_STEP = sub { push @EVENTS, 'rename-called'; $r->(@_) };
    }
    my $files_before = join(',', list_files());
    attempt { $AM->run };
    is(join(',', list_files()), $files_before, 'journal resume (old dir gone, new dir present): nothing renamed');
    ok(scalar(cache_leftovers($OLD)) == 0 && !%{ $prefs->get('authChainRekeyPending') || {} },
        'journal resume (old dir gone, new dir present): keys removed, journal cleared');
}

# ============================================================
# refusals and hints
# ============================================================
{
    seed_rekey_world();
    # the target dir exists with credentials of ANOTHER user
    write_json(account_dir($NEW), 'credentials.json', { auth_type => 1, username => 'someone-else', auth_data => 'QUFB' });
    my $before = join(',', list_files());
    my $new_creds = slurp(catfile(account_dir($NEW), 'credentials.json'));
    attempt { $AM->run };
    my $acct = ($prefs->get('accounts') || {})->{$OLD} || {};
    ok($acct->{needsPairing} && !exists(($prefs->get('accounts') || {})->{$NEW})
        && join(',', list_files()) eq $before
        && slurp(catfile(account_dir($NEW), 'credentials.json')) eq $new_creds
        && !%{ $prefs->get('authChainRekeyPending') || {} },
        're-key refused (target holds another user\'s credentials): needsPairing, nothing moved, no journal entry');
    my @l = wlog(qr/\AAuth chain migration: account \Q@{[mask($OLD)]}\E re-key refused/);
    is(scalar(@l) . ':' . ($l[0] ? $l[0][0] : 'none'), '1:warn', 're-key refused: logged at WARN level');
}

{
    my $A = id_for('alice');
    reset_world();
    seed_account(id => $A, username => 'alice', nocreds => 1);
    my $before = join(',', list_files());
    attempt { $AM->run };
    my $acct = ($prefs->get('accounts') || {})->{$A} || {};
    ok($acct->{needsPairing} && join(',', list_files()) eq $before,
        'no credentials.json: needsPairing = 1 (D-02 hint), nothing deleted');
    my @l = wlog(qr/\AAuth chain migration: account \Q@{[mask($A)]}\E needs pairing\z/);
    is(scalar(@l) . ':' . ($l[0] ? $l[0][0] : 'none'), '1:warn', 'needs pairing: summary line is logged at WARN level');
}

{
    my $A = id_for('alice');
    reset_world();
    seed_account(id => $A, username => 'alice', source => '');
    attempt { $AM->run };
    my $acct = ($prefs->get('accounts') || {})->{$A} || {};
    ok($acct->{needsPairing} && -f catfile(account_dir($A), 'credentials.json'),
        'credentials without playbackCredSource: needsPairing = 1, credentials.json kept');
}

{
    my $A = id_for('alice');
    reset_world();
    seed_account(id => $A, username => 'alice');
    Plugins::SpotOn::API::Credentials->markNeedsPlaybackAuth($A, 'credential_error') if $LOADED;
    attempt { $AM->run };
    my $acct = ($prefs->get('accounts') || {})->{$A} || {};
    ok($acct->{needsPairing} && -f catfile(account_dir($A), 'credentials.json'),
        'needsPlaybackAuth set: needsPairing = 1, credentials.json kept');
}

{
    my $A = id_for('alice');
    reset_world();
    seed_account(id => $A, username => 'alice', source => 'bogus');
    attempt { $AM->run };
    ok((($prefs->get('accounts') || {})->{$A} || {})->{needsPairing},
        'an unknown playbackCredSource is not usable: needsPairing = 1');
    for my $src (qw(keymaster discover)) {
        reset_world();
        seed_account(id => $A, username => 'alice', source => $src);
        attempt { $AM->run };
        my $acct = ($prefs->get('accounts') || {})->{$A} || {};
        ok(!$acct->{needsPairing} && ($acct->{spotifyUserId} // '') eq 'alice',
            "playbackCredSource $src counts as usable: kept");
    }
}

{
    my $A = id_for('alice');
    reset_world();
    seed_account(id => $A, username => 'alice', nocreds => 1);
    attempt { $AM->migrateAccount($A) } for 1 .. 3;
    is(scalar(wlog(qr/needs pairing/)), 1, 'needs pairing is logged once, not on every repeated call (DaemonManager calls per start)');
}

{
    reset_world();
    is((attempt { $AM->migrateAccount('eeeeeeee') }) // 'undef', 'skipped', 'migrateAccount: an unknown account id is skipped');
    is((attempt { $AM->migrateAccount('../../etc') }) // 'undef', 'skipped', 'migrateAccount: an id that is not 8 hex is skipped (never path-joined)');
}

{
    reset_world();
    $prefs->set(authChainRekeyPending => { '../../evil' => $NEW, 'aaaaaaaa' => '../x' });
    my $files_before = join(',', list_files());
    attempt { $AM->run };
    ok(!%{ $prefs->get('authChainRekeyPending') || {} } && join(',', list_files()) eq $files_before
        && scalar(wlog(qr/journal entry .* dropped/)) == 2,
        'journal entries with ids that are not 8 hex are dropped with a WARN, never used in a path');
}

# ============================================================
# idempotency
# ============================================================
{
    seed_rekey_world();
    attempt { $AM->run };
    my $first = snapshot();
    attempt { $AM->run };
    is(snapshot(), $first, 'run() twice yields identical prefs and directory state (idempotent)');
    is_deeply($prefs->get('authChainRekeyPending'), {}, 'a run that ends with an empty journal leaves the journal empty (authChainMigrated may be set)');
}

# ============================================================
# WR-01: an interrupted RUNTIME re-key is finished on every start
# ============================================================
ok($AM->can('resumeJournal'), 'WR-01: AccountMigration exposes resumeJournal');
{
    # migrateAccount is the runtime path DaemonManager->startHelper uses.
    seed_rekey_world();
    {
        no warnings 'once';
        $Plugins::SpotOn::API::AccountMigration::RENAME_STEP = sub { die "simulated rename failure (permission)\n" };
    }
    attempt { $AM->migrateAccount($OLD) };
    my $j = $prefs->get('authChainRekeyPending') || {};
    ok(($j->{$OLD} // '') eq $NEW && -d account_dir($OLD) && !-d account_dir($NEW),
        'WR-01 precondition: a dying rename in the runtime re-key leaves the journal entry and the old directory');

    {
        no warnings 'once';
        $Plugins::SpotOn::API::AccountMigration::RENAME_STEP = \&Plugins::SpotOn::API::AccountMigration::_renameDir;
    }
    @Slim::Utils::Cache::removed = ();
    attempt { $AM->can('resumeJournal') ? $AM->resumeJournal() : die "no resumeJournal\n" };
    ok(-d account_dir($NEW) && !-d account_dir($OLD),
        'WR-01: resumeJournal alone moves the account directory to the re-keyed id');
    is_deeply($prefs->get('authChainRekeyPending') || {}, {}, 'WR-01: resumeJournal alone empties the journal');
    my %removed = map { $_ => 1 } @Slim::Utils::Cache::removed;
    ok($removed{"spoton_token_$OLD"} && !$removed{"spoton_token_$OTHER"},
        'WR-01: resumeJournal alone removes the old-id cache keys and leaves the other account alone');
    ok(!(($prefs->get('accounts') || {})->{$OTHER}{needsPairing}),
        'WR-01: resumeJournal runs no per-account migration (the credential-less other account gets no needsPairing)');
}
{
    seed_rekey_world();
    my $before = snapshot();
    attempt { $AM->can('resumeJournal') ? $AM->resumeJournal() : die "no resumeJournal\n" };
    ok($AM->can('resumeJournal') && snapshot() eq $before,
        'WR-01: resumeJournal on an empty journal changes nothing (prefs, clients and files equal)');
}
{
    my $pl = slurp("$project_dir/Plugins/SpotOn/Plugin.pm");
    my ($body) = $pl =~ /(sub _startUnifiedDaemons \{.*?\n\})/s;
    $body //= '';
    $body =~ s/^\s*#.*$//mg;   # comments must not satisfy the ordering check
    my $resume = index($body, 'AccountMigration->resumeJournal()');
    my $mig    = index($body, "get('authChainMigrated')");
    my $init   = rindex($body, 'DaemonManager->init()');
    ok($resume > 0 && $mig > $resume && $init > $mig
        && substr($body, 0, $resume) =~ /eval\s*\{[^}]*\z/,
        'WR-01: _startUnifiedDaemons calls AccountMigration->resumeJournal() inside an eval, before the authChainMigrated gate and the last DaemonManager->init()');
}

# ============================================================
# wiring (source checks)
# ============================================================
{
    my $dm = slurp("$project_dir/Plugins/SpotOn/Unified/DaemonManager.pm");
    ok($dm !~ /unlink \$credFile/ && $dm =~ /AccountMigration->migrateAccount\(\$activeAccountId\)/,
        'DaemonManager startHelper: a mismatching credentials.json is no longer unlinked; migrateAccount is called instead');

    my $pl = slurp("$project_dir/Plugins/SpotOn/Plugin.pm");
    my ($body) = $pl =~ /(sub _startUnifiedDaemons \{.*?\n\})/s;
    $body //= '';
    my $mig  = index($body, "get('authChainMigrated')");
    my $init = rindex($body, 'DaemonManager->init()');   # the call, not the comments above it
    ok($mig > 0 && $init > $mig && $body =~ /AccountMigration->run/ && $body =~ /authChainRekeyPending/
        && $pl =~ /authChainMigrated\s*=>\s*0/ && $pl =~ /authChainRekeyPending\s*=>\s*\{\}/,
        'Plugin.pm: the authChainMigrated one-shot runs before DaemonManager->init(); both prefs have defaults');
}

done_testing();
