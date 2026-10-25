#!/usr/bin/perl
use strict;
use warnings;
no warnings 'once';
use Test::More;
use File::Basename qw(dirname);
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use Cwd qw(abs_path);

# 74b-01 Task 3 (D-08): the truth table of DaemonManager->effectiveOutput and
# ->effectiveFormat over the REAL DaemonManager, the REAL ProtocolHandler and
# the REAL backend role classes. Only the LMS framework around them is stubbed.
# Every row asserts three things:
#   - effectiveOutput's (effective, type, path, reason) answer,
#   - ProtocolHandler->formatOverride($song) equals effectiveOutput->{type}
#     (D-08: display and playback use one mapping, never two copies),
#   - (effectiveFormat($client))[0] equals effectiveOutput->{effective}.
# effectiveFormat is the cheap read for callers that run once per menu item:
# a counting checkBin stub proves it never diagnoses.

my $test_dir    = dirname(abs_path($0));
my $project_dir = dirname(dirname($test_dir));   # t/<group>/x.t -> repo root
die "wrong project root: $project_dir" unless -f "$project_dir/Plugins/SpotOn/Plugin.pm";

# 79-25 (D-08, NA-x): which backend-side leg is this tree? The committed manifests
# tools/ci/amputation/<side>.files (entries under Plugins/SpotOn/) are the single source:
# all paths present = normal tree ('present'), none present = that side was removed on purpose
# ('amputated', the CI amputation leg), some present = broken checkout (die, never skip).
sub amputation_state {
    my ($root, $side) = @_;
    my $manifest = "$project_dir/tools/ci/amputation/$side.files";
    open(my $mfh, '<', $manifest)
        or die "$manifest: $! -- wrong project root or broken checkout (die, never skip)\n";
    my @paths;
    while (my $line = <$mfh>) {
        chomp $line;
        next if $line =~ /^\s*(?:#|$)/;
        next unless $line =~ m{^Plugins/SpotOn/};
        $line =~ s{/+\z}{};
        push @paths, $line;
    }
    close($mfh);
    die "$manifest holds no Plugins/SpotOn entries -- wrong project root or broken checkout (die, never skip)\n"
        unless @paths;
    my $here = grep { -e "$root/$_" } @paths;
    return 'present'   if $here == @paths;
    return 'amputated' if $here == 0;
    die "partial $side side ($here of " . scalar(@paths) . " paths present) -- broken checkout (die, never skip)\n";
}

for my $rel (qw(Unified/DaemonManager.pm ProtocolHandler.pm Backend/Soloist.pm)) {
    die "Plugins/SpotOn/$rel is missing -- wrong project root or broken checkout (die, never skip)\n"
        unless -f "$project_dir/Plugins/SpotOn/$rel";
}
# 79-25 (NA-2): Backend/Librespot.pm follows the leg. 'amputated' is the CI librespot-removed leg
# (the file is gone on purpose); a tree that lost only this file dies "partial librespot side".
my $librespot_state = amputation_state($project_dir, 'librespot');

my $stub_dir = tempdir(CLEANUP => 1);

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

# ------------------------------------------------------------
# LMS framework stubs (the set t/soloist/28 needs to load the real
# DaemonManager, plus the ones t/soloist/29 needs for the real
# ProtocolHandler).
# ------------------------------------------------------------
write_stub($stub_dir, 'Log::Log4perl::Logger', <<'END');
package Log::Log4perl::Logger;
sub new { bless {}, shift }
sub AUTOLOAD { }
sub can { 1 }
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
our @WARNINGS;
sub import {
    my $class = shift;
    my $caller = caller;
    no strict 'refs';
    *{"${caller}::logger"} = \&logger;
}
sub logger { return bless {}, 'Slim::Utils::Log' }
sub info  { }
sub warn  { shift; push @WARNINGS, [@_]; }
sub error { }
sub debug { }
sub is_info  { 1 }
sub is_debug { 0 }
sub is_warn  { 1 }
sub AUTOLOAD { }
sub can { 1 }
1;
END

# One backing hash for plugin prefs AND per-client prefs (the real code reads
# both through the same keys; a row sets exactly the keys it needs).
write_stub($stub_dir, 'Slim::Utils::Prefs', <<'END');
package Slim::Utils::Prefs;
our %FAKE_VALUES;
sub import {
    my $class = shift;
    my $caller = caller;
    no strict 'refs';
    *{"${caller}::preferences"} = \&preferences;
}
sub preferences { return bless { _ns => $_[0] }, 'Slim::Utils::Prefs' }
sub get      { my ($self, $key) = @_; return $FAKE_VALUES{$key}; }
sub set      { my ($self, $key, $val) = @_; $FAKE_VALUES{$key} = $val; }
sub client   { return bless {}, 'Slim::Utils::Prefs' }
sub setChange { }
1;
END

write_stub($stub_dir, 'Slim::Utils::Cache', <<'END');
package Slim::Utils::Cache;
sub new    { return bless {}, shift }
sub get    { return undef }
sub set    { }
sub remove { }
1;
END

write_stub($stub_dir, 'Slim::Utils::Strings', <<'END');
package Slim::Utils::Strings;
sub import {
    my $class = shift;
    my $caller = caller;
    no strict 'refs';
    *{"${caller}::cstring"} = sub { '' };
    *{"${caller}::string"}  = sub { '' };
}
1;
END

write_stub($stub_dir, 'Slim::Utils::Timers', <<'END');
package Slim::Utils::Timers;
sub killTimers { }
sub setTimer   { }
1;
END

write_stub($stub_dir, 'Slim::Networking::SimpleAsyncHTTP', <<'END');
package Slim::Networking::SimpleAsyncHTTP;
sub new { return bless {}, shift }
sub get { }
sub post { }
1;
END

write_stub($stub_dir, 'JSON::XS::VersionOneAndTwo', <<'END');
package JSON::XS::VersionOneAndTwo;
sub import {
    my $class = shift;
    my $caller = caller;
    no strict 'refs';
    *{"${caller}::to_json"}   = sub { '{}' };
    *{"${caller}::from_json"} = sub { {} };
}
1;
END

write_stub($stub_dir, 'Plugins::SpotOn::Plugin', <<'END');
package Plugins::SpotOn::Plugin;
use constant SPOTON_CACHE_VERSION => 4;
sub _pluginDataFor { return 'test-basedir' }
1;
END

# The librespot role reads the binary's passthrough capability lazily through
# the Helper (eval-guarded); a controllable stand-in decides it per row.
write_stub($stub_dir, 'Plugins::SpotOn::Helper', <<'END');
package Plugins::SpotOn::Helper;
our $PASSTHROUGH_CAP = 0;
sub getCapability { my ($class, $key) = @_; return $key eq 'passthrough' ? $PASSTHROUGH_CAP : 0; }
1;
END

# ProtocolHandler dependencies (t/soloist/29's set).
write_stub($stub_dir, 'Slim::Utils::Versions', <<'END');
package Slim::Utils::Versions;
sub compareVersions { return 1 }
1;
END

write_stub($stub_dir, 'Slim::Utils::Network', <<'END');
package Slim::Utils::Network;
sub serverAddr { return '127.0.0.1' }
1;
END

write_stub($stub_dir, 'Slim::Utils::Misc', <<'END');
package Slim::Utils::Misc;
sub crackURL         { return ('127.0.0.1', 80, '/') }
sub findbin           { }
sub addFindBinPaths   { }
1;
END

write_stub($stub_dir, 'Slim::Music::Info', <<'END');
package Slim::Music::Info;
sub setCurrentTitle { }
1;
END

write_stub($stub_dir, 'Slim::Schema::RemoteTrack', <<'END');
package Slim::Schema::RemoteTrack;
sub fetch { return undef }
1;
END

write_stub($stub_dir, 'Slim::Formats::RemoteStream', <<'END');
package Slim::Formats::RemoteStream;
sub new      { return bless {}, shift }
sub AUTOLOAD { }
sub can      { 1 }
1;
END

write_stub($stub_dir, 'Slim::Player::Protocols::HTTP', <<'END');
package Slim::Player::Protocols::HTTP;
sub new { my ($class, $args) = @_; return bless { %$args }, $class; }
1;
END

BEGIN {
    no warnings 'redefine';
    *main::TRANSCODING = sub () { 0 };
    *main::WEBUI       = sub () { 0 };
    *main::SCANNER     = sub () { 0 };
    *main::INFOLOG     = sub () { 0 };
    *main::DEBUGLOG    = sub () { 0 };
    *main::PERFMON     = sub () { 0 };
    *main::ISWINDOWS   = sub () { 0 };
    *main::ISMAC       = sub () { 0 };
}
$::VERSION = '9.0.0';

# ------------------------------------------------------------
# Test doubles (plain in-process packages, as in t/soloist/28)
# ------------------------------------------------------------
{
    package Test::EOClient;
    sub new {
        my ($class, %args) = @_;
        my $self = bless {
            id      => $args{id},
            synced  => $args{synced} // 0,
            master  => $args{master},
            formats => $args{formats} // [],
        }, $class;
        $self->{master} = $self unless $args{slave};    # LMS: master() on a master/unsynced player is itself
        return $self;
    }
    sub id       { return $_[0]->{id}; }
    sub isSynced { return $_[0]->{synced}; }
    sub master   { return $_[0]->{master}; }
    sub formats  { return @{ $_[0]->{formats} }; }

    package Test::EOTrack;
    sub new { my ($class, $url) = @_; return bless { url => $url }, $class; }
    sub url { return $_[0]->{url}; }

    package Test::EOSong;
    sub new { my ($class, %a) = @_; return bless { %a }, $class; }
    sub master { return $_[0]->{master}; }
    sub track  { return $_[0]->{track}; }
}

{
    package Slim::Player::Sync;
    our @SLAVES = ();
    sub slaves { return @SLAVES; }
}

# checkBin stub: profile -> 1 (usable) | 'binary name' (missing, put into $@
# like the real one) | undef (profile missing or disabled, $@ untouched).
# The real function takes ($profile, $ignoreprefsettings) and is a plain
# function, not a method.
{
    package Slim::Player::TranscodingHelper;
    our %TABLE;
    our $CALLS = 0;
    sub checkBin {
        my ($profile) = @_;
        $CALLS++;
        my $r = $TABLE{$profile};
        return 1 if defined $r && $r eq '1';
        $@ = $r if defined $r;
        return undef;
    }
}
my $SMP = 'smp-mp3-*-*';
my $SOF = 'sof-flc-*-*';

unshift @INC, $stub_dir, $project_dir;

require_ok('Plugins::SpotOn::Plugin') or BAIL_OUT("Failed to load the Plugins::SpotOn::Plugin stub");
require_ok('Plugins::SpotOn::Unified::DaemonManager') or BAIL_OUT("Failed to load the real DaemonManager");
require_ok('Plugins::SpotOn::ProtocolHandler') or BAIL_OUT("Failed to load the real ProtocolHandler");
require_ok('Plugins::SpotOn::Backend::Soloist') or BAIL_OUT("Failed to load the real Backend::Soloist");
if ($librespot_state eq 'present') {
    require_ok('Plugins::SpotOn::Backend::Librespot') or BAIL_OUT("Failed to load the real Backend::Librespot");
}
else {
    ok(!eval { require Plugins::SpotOn::Backend::Librespot; 1 },
        "librespot side amputated: Backend::Librespot does not load (leg check)");
}

my $DM = 'Plugins::SpotOn::Unified::DaemonManager';
my $PH = 'Plugins::SpotOn::ProtocolHandler';

# The staging answer is switched per row through a local glob, so no row
# depends on the shipped constant and the test never reads it.
my $STAGED = 0;
{
    no warnings 'redefine';
    *Plugins::SpotOn::Unified::DaemonManager::autoFlacEnabled = sub { return $STAGED };
}

sub reset_world {
    %Slim::Utils::Prefs::FAKE_VALUES = ();
    @Slim::Player::Sync::SLAVES = ();
    %Slim::Player::TranscodingHelper::TABLE = ();
    $Plugins::SpotOn::Helper::PASSTHROUGH_CAP = 0;
    $STAGED = 0;
}

# ------------------------------------------------------------
# The table. Fields:
#   name, backend, chosen (stored streamFormat, undef = unset), formats
#   (player), slave (formats of one sync slave, undef = unsynced), mode
#   (streamingMode), staged (autoFlacEnabled), bin (profile => checkBin
#   answer), cap (librespot passthrough capability), expect
#   [effective, type, path, reason].
# ------------------------------------------------------------
my @ROWS = (
    # ---- Soloist ----
    { name => 'soloist auto [flc,pcm] direct, staging 0 -> PCM via proxy (D-22, as today)',
      backend => 'soloist', chosen => 'auto', formats => [qw(flc pcm)], mode => 'direct', staged => 0,
      expect => [qw(pcm soc proxy), ''] },
    { name => 'soloist auto [flc,pcm] direct, staging 1 -> FLAC via proxy (D-16)',
      backend => 'soloist', chosen => 'auto', formats => [qw(flc pcm)], mode => 'direct', staged => 1,
      bin => { $SOF => 1 }, expect => [qw(flac sof proxy), ''] },
    { name => 'soloist auto [flc,pcm] proxy mode, staging 1 -> FLAC via proxy',
      backend => 'soloist', chosen => 'auto', formats => [qw(flc pcm)], mode => 'proxy', staged => 1,
      bin => { $SOF => 1 }, expect => [qw(flac sof proxy), ''] },
    { name => 'soloist auto [pcm] direct, staging 0 -> PCM direct',
      backend => 'soloist', chosen => 'auto', formats => [qw(pcm)], mode => 'direct', staged => 0,
      expect => [qw(pcm soc direct), ''] },
    { name => 'soloist auto [pcm] direct, staging 1 -> PCM direct',
      backend => 'soloist', chosen => 'auto', formats => [qw(pcm)], mode => 'direct', staged => 1,
      expect => [qw(pcm soc direct), ''] },
    { name => 'soloist pcm [flc,pcm] direct -> PCM direct (explicit PCM never FLAC, D-03)',
      backend => 'soloist', chosen => 'pcm', formats => [qw(flc pcm)], mode => 'direct', staged => 1,
      expect => [qw(pcm soc direct), ''] },
    { name => 'soloist flac [flc,pcm] direct, staging 0 -> FLAC via proxy (explicit FLAC before the flip)',
      backend => 'soloist', chosen => 'flac', formats => [qw(flc pcm)], mode => 'direct', staged => 0,
      bin => { $SOF => 1 }, expect => [qw(flac sof proxy), ''] },
    { name => 'soloist flac [pcm] direct -> PCM direct, flac_no_flc (D-15)',
      backend => 'soloist', chosen => 'flac', formats => [qw(pcm)], mode => 'direct', staged => 0,
      expect => [qw(pcm soc direct flac_no_flc)] },
    { name => 'soloist flac, master [flc] + slave [pcm] synced -> PCM via proxy, flac_no_flc (D-15)',
      backend => 'soloist', chosen => 'flac', formats => [qw(flc)], slave => [qw(pcm)], mode => 'direct', staged => 0,
      expect => [qw(pcm soc proxy flac_no_flc)] },
    { name => 'soloist mp3, lame missing -> MP3 via proxy, no_lame (D-10)',
      backend => 'soloist', chosen => 'mp3', formats => [qw(flc pcm mp3)], mode => 'direct', staged => 0,
      bin => { $SMP => 'lame' }, expect => [qw(mp3 smp proxy no_lame)] },
    { name => 'soloist mp3, smp rule ok -> MP3 via proxy',
      backend => 'soloist', chosen => 'mp3', formats => [qw(flc pcm mp3)], mode => 'direct', staged => 0,
      bin => { $SMP => 1 }, expect => [qw(mp3 smp proxy), ''] },
    { name => 'soloist mp3, smp rule disabled -> MP3 via proxy, rule_unavailable',
      backend => 'soloist', chosen => 'mp3', formats => [qw(flc pcm mp3)], mode => 'direct', staged => 0,
      bin => {}, expect => [qw(mp3 smp proxy rule_unavailable)] },
    { name => 'soloist flac [flc], sof rule disabled -> FLAC via proxy, rule_unavailable',
      backend => 'soloist', chosen => 'flac', formats => [qw(flc)], mode => 'direct', staged => 0,
      bin => {}, expect => [qw(flac sof proxy rule_unavailable)] },
    { name => 'soloist stored ogg behaves as auto, staging 0 -> PCM via proxy',
      backend => 'soloist', chosen => 'ogg', formats => [qw(ogg flc pcm)], mode => 'direct', staged => 0,
      expect => [qw(pcm soc proxy), ''] },
    { name => 'soloist stored ogg behaves as auto, staging 1 -> FLAC via proxy',
      backend => 'soloist', chosen => 'ogg', formats => [qw(ogg flc pcm)], mode => 'direct', staged => 1,
      bin => { $SOF => 1 }, expect => [qw(flac sof proxy), ''] },
    { name => 'soloist unset pref behaves as auto, staging 0 -> PCM via proxy',
      backend => 'soloist', chosen => undef, formats => [qw(flc pcm)], mode => 'direct', staged => 0,
      expect => [qw(pcm soc proxy), ''] },
    { name => 'soloist auto, synced group all flc, staging 1 -> FLAC via proxy',
      backend => 'soloist', chosen => 'auto', formats => [qw(flc pcm)], slave => [qw(flc pcm)], mode => 'direct', staged => 1,
      bin => { $SOF => 1 }, expect => [qw(flac sof proxy), ''] },

    # ---- librespot (role resolver resolvePassthroughForClient) ----
    { name => 'librespot flac [flc,pcm], no passthrough -> FLAC via proxy (D-04 code side)',
      backend => 'librespot', chosen => 'flac', formats => [qw(flc pcm)], mode => 'direct', cap => 0,
      bin => { $SOF => 1 }, expect => [qw(flac sof proxy), ''] },
    { name => 'librespot flac [pcm] -> PCM via proxy, flac_no_flc (D-15)',
      backend => 'librespot', chosen => 'flac', formats => [qw(pcm)], mode => 'direct', cap => 0,
      expect => [qw(pcm soc proxy flac_no_flc)] },
    { name => 'librespot auto with ogg + passthrough capability -> OGG direct (Auto unchanged)',
      backend => 'librespot', chosen => 'auto', formats => [qw(ogg flc pcm)], mode => 'direct', cap => 1,
      expect => [qw(ogg son direct), ''] },
    { name => 'librespot auto [flc,pcm], no passthrough -> PCM direct (Auto unchanged)',
      backend => 'librespot', chosen => 'auto', formats => [qw(flc pcm)], mode => 'direct', cap => 0,
      expect => [qw(pcm soc direct), ''] },
    { name => 'librespot mp3, lame ok -> MP3 via proxy',
      backend => 'librespot', chosen => 'mp3', formats => [qw(flc pcm mp3)], mode => 'direct', cap => 1,
      bin => { $SMP => 1 }, expect => [qw(mp3 smp proxy), ''] },
    { name => 'librespot pcm -> PCM via proxy (explicit pcm/flac/mp3 force transcoding under librespot)',
      backend => 'librespot', chosen => 'pcm', formats => [qw(flc pcm)], mode => 'direct', cap => 1,
      expect => [qw(pcm soc proxy), ''] },
);

# 79-25 (NA-2): on the librespot-removed leg the librespot rows have no backend to run against;
# they are dropped (order kept, the soloist rows and their $ROWS[n] indices are unchanged).
if ($librespot_state eq 'amputated') {
    my $before = scalar @ROWS;
    @ROWS = grep { $_->{backend} ne 'librespot' } @ROWS;
    note("librespot side amputated: dropped " . ($before - @ROWS) . " librespot rows of $before");
}

# Build a row's client (and its song), apply its prefs/world.
sub setup_row {
    my ($row, $n) = @_;
    reset_world();
    $Slim::Utils::Prefs::FAKE_VALUES{backend}       = $row->{backend};
    $Slim::Utils::Prefs::FAKE_VALUES{streamingMode} = $row->{mode};
    $Slim::Utils::Prefs::FAKE_VALUES{streamFormat}  = $row->{chosen} if defined $row->{chosen};
    $STAGED = $row->{staged} // 0;
    $Plugins::SpotOn::Helper::PASSTHROUGH_CAP = $row->{cap} // 0;
    %Slim::Player::TranscodingHelper::TABLE = %{ $row->{bin} || {} };

    my $client;
    if ($row->{slave}) {
        $client = Test::EOClient->new(id => "eo:m$n", synced => 1, formats => $row->{formats});
        my $slave = Test::EOClient->new(id => "eo:s$n", synced => 1, slave => 1, master => $client,
                                        formats => $row->{slave});
        @Slim::Player::Sync::SLAVES = ($slave);
    }
    else {
        $client = Test::EOClient->new(id => "eo:c$n", formats => $row->{formats});
    }
    return $client;
}

my $n = 0;
for my $row (@ROWS) {
    $n++;
    my $client = setup_row($row, $n);
    my $song   = Test::EOSong->new(master => $client, track => Test::EOTrack->new('spoton://track:abc123'));

    my $out = eval { $DM->effectiveOutput($client) };
    my $err = $@;
    my @exp = @{ $row->{expect} };

    is(ref $out, 'HASH', "$row->{name}: effectiveOutput returns a hashref") or diag("died: $err");
    $out = {} unless ref $out eq 'HASH';

    is_deeply(
        [ map { $out->{$_} // '<undef>' } qw(effective type path reason) ],
        \@exp,
        "$row->{name}: (effective, type, path, reason)"
    );

    # D-08: the playback mapping is the display mapping.
    is($PH->formatOverride($song), $out->{type} // '<undef>',
        "$row->{name}: formatOverride equals effectiveOutput->{type}");

    # The cheap part agrees with the full answer.
    my @fmt = eval { $DM->effectiveFormat($client) };
    is($fmt[0] // '<undef>', $out->{effective} // '<undef>',
        "$row->{name}: (effectiveFormat)[0] equals effectiveOutput->{effective}");
    is($fmt[1] // '<undef>', $out->{type} // '<undef>',
        "$row->{name}: (effectiveFormat)[1] equals effectiveOutput->{type}");
}

# chosen / resolved fields, spot-checked on named rows.
{
    my $client = setup_row($ROWS[0], 101);
    my $out = $DM->effectiveOutput($client);
    is($out->{chosen},   'auto', "chosen reports the stored choice (auto)");
    is($out->{resolved}, 'flac', "resolved reports the resolver's answer for Auto on an flc player (the PATH decision, D-22)");

    $client = setup_row($ROWS[13], 102);    # stored ogg
    $out = $DM->effectiveOutput($client);
    is($out->{chosen}, 'ogg', "chosen reports the stored value as is (ogg under soloist)");

    $client = setup_row($ROWS[15], 103);    # unset
    $out = $DM->effectiveOutput($client);
    is($out->{chosen}, 'auto', "chosen falls back to auto for an unset pref (WR-04 chain)");
}

# Asked on a sync slave, the answer is the master's (normalised like Plugin.pm _typeString).
{
    my ($row) = grep { $_->{name} =~ /master \[flc\] \+ slave \[pcm\]/ } @ROWS;
    my $master = setup_row($row, 104);
    my ($slave) = Slim::Player::Sync::slaves($master);
    my $viaMaster = $DM->effectiveOutput($master);
    my $viaSlave  = $DM->effectiveOutput($slave);
    is_deeply($viaSlave, $viaMaster, "effectiveOutput asked on a slave equals the master's answer");
}

# undef client: documented defaults, no die.
{
    reset_world();
    my $out = eval { $DM->effectiveOutput(undef) };
    is_deeply($out, { chosen => 'auto', resolved => '', effective => 'pcm', type => 'soc', path => 'none', reason => '' },
        "effectiveOutput(undef client) -> documented defaults");
    my @f = eval { $DM->effectiveFormat(undef) };
    is_deeply(\@f, [ 'pcm', 'soc', '', '' ], "effectiveFormat(undef client) -> (pcm, soc, '', '')");
}

# effectiveFormat never calls checkBin, over every row including the mp3 row
# with lame missing; effectiveOutput does (so the counter can move).
{
    my $viaFormat = 0;
    $n = 200;
    for my $row (@ROWS) {
        my $client = setup_row($row, ++$n);
        $Slim::Player::TranscodingHelper::CALLS = 0;
        my @f = eval { $DM->effectiveFormat($client) };
        $viaFormat += $Slim::Player::TranscodingHelper::CALLS;
    }
    is($viaFormat, 0, "effectiveFormat calls checkBin 0 times over all " . scalar(@ROWS) . " rows (per-menu-item callers log nothing)");

    my ($mp3) = grep { $_->{name} =~ /lame missing/ } @ROWS;
    my $client = setup_row($mp3, 300);
    $Slim::Player::TranscodingHelper::CALLS = 0;
    $DM->effectiveOutput($client);
    cmp_ok($Slim::Player::TranscodingHelper::CALLS, '>=', 1,
        "effectiveOutput does diagnose (the counter moves for the smp row)");
}

# Invariant: each of soc, sof, smp, son has exactly one rule header in
# custom-convert.conf and exactly one row in custom-types.conf.
{
    my $slurp = sub {
        open(my $fh, '<', $_[0]) or die "Cannot open $_[0]: $!";
        local $/; return <$fh>;
    };
    my $convert = $slurp->("$project_dir/Plugins/SpotOn/custom-convert.conf");
    my $types   = $slurp->("$project_dir/Plugins/SpotOn/custom-types.conf");
    for my $t (qw(soc sof smp son)) {
        my @h = $convert =~ m{^\Q$t\E [a-z0-9]+ \* \*$}mg;
        is(scalar(@h), 1, "custom-convert.conf has exactly one '$t' rule header");
        my @r = $types =~ m{^\Q$t\E\t}mg;
        is(scalar(@r), 1, "custom-types.conf has exactly one '$t' row");
    }
}

done_testing();
