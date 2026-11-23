#!/usr/bin/perl

# t/soloist/86_dstm_connect.t
#
# 90.1-06 (GH #234, D-13): Don't Stop the Music must not take a Soloist
# player out of the Spotify app's session.
#   Layer 2 (variant disableDSTM, the user's choice in 90.1-05): LMS's own
#   conflict hook. install.xml carries <canConflictWithDSTM>1</canConflictWithDSTM>
#   and Plugins::SpotOn::Plugin->disableDSTM($client) answers true while the
#   player's role mode is 'connect' (DSTM Plugin.pm 14-27, 176-240).
#   Both rest on Plugins::SpotOn::DontStopTheMusic::connectSessionActive.
#
# Offline: no LMS tree, no daemon. Every Slim:: module DontStopTheMusic.pm
# loads and Plugins::SpotOn::Unified::DaemonManager are stubs in a temp lib,
# so the file also passes with /usr/share/perl5 removed from @INC
# (PERL5OPT='-M-lib=/usr/share/perl5', the CI shape).

use strict;
use warnings;
use Test::More;
use File::Basename qw(dirname);
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use Cwd qw(abs_path);

my $test_dir    = dirname(abs_path($0));
my $project_dir = dirname(dirname($test_dir));   # t/soloist/x.t -> repo root
die "wrong project root: $project_dir" unless -f "$project_dir/Plugins/SpotOn/Plugin.pm";

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

# Slim::Utils::Log with the real calling convention (Log.pm 281-284):
# logger() is a plain function whose FIRST argument is the category, so a
# method call Slim::Utils::Log->logger('x') gets category 'Slim::Utils::Log'.
write_stub($stub_dir, 'Slim::Utils::Log', <<'END');
package Slim::Utils::Log;
use Exporter 'import';
our @EXPORT = qw(logger);
our @CATEGORIES;
our %LINES;
sub logger {
    my $category = shift;
    push @CATEGORIES, $category;
    return bless { cat => $category }, 'Slim::Utils::Log::Cat';
}
package Slim::Utils::Log::Cat;
sub _rec { my ($self, $lvl, $msg) = @_; push @{ $Slim::Utils::Log::LINES{ $self->{cat} }{$lvl} }, $msg; return }
sub info  { $_[0]->_rec('info',  $_[1]) }
sub warn  { $_[0]->_rec('warn',  $_[1]) }
sub error { $_[0]->_rec('error', $_[1]) }
sub debug { $_[0]->_rec('debug', $_[1]) }
sub is_info  { 1 }
sub is_debug { 0 }
1;
END

write_stub($stub_dir, 'Slim::Utils::Prefs', <<'END');
package Slim::Utils::Prefs;
sub preferences { return bless { ns => $_[0] }, 'Slim::Utils::Prefs' }
sub client { return $_[0] }
sub get    { return undef }
1;
END

write_stub($stub_dir, 'Slim::Utils::Cache', <<'END');
package Slim::Utils::Cache;
sub new { return bless {}, $_[0] }
sub get { return undef }
sub set { return }
1;
END

write_stub($stub_dir, 'Slim::Utils::Timers', <<'END');
package Slim::Utils::Timers;
sub setTimer   { return }
sub killTimers { return }
1;
END

write_stub($stub_dir, 'Slim::Plugin::DontStopTheMusic::Plugin', <<'END');
package Slim::Plugin::DontStopTheMusic::Plugin;
our $MIX_CALLS = 0;
our $SEEDS     = [];
sub registerHandler { return }
sub getMixableProperties { $MIX_CALLS++; return $SEEDS }
1;
END

# backendFor($client) -> a role whose state->{mode} the test sets;
# $DIE makes backendFor die, $NOROLE makes it answer undef.
write_stub($stub_dir, 'Plugins::SpotOn::Unified::DaemonManager', <<'END');
package Plugins::SpotOn::Unified::DaemonManager;
our ($MODE, $DIE, $NOROLE);
our @ASKED;
sub backendFor {
    my ($class, $client) = @_;
    push @ASKED, $client;
    die "backendFor exploded\n" if $DIE;
    return undef if $NOROLE;
    return bless {}, 'Test::StubRole';
}
package Test::StubRole;
sub state { return { mode => $Plugins::SpotOn::Unified::DaemonManager::MODE } }
1;
END

BEGIN {
    no warnings 'once';
    *main::INFOLOG  = sub () { 1 };
    *main::DEBUGLOG = sub () { 0 };
}

# DontStopTheMusic.pm reads the cache version at load; Plugin.pm itself is
# not loaded (D2 evaluates only the source text of its disableDSTM).
{ no warnings 'once'; *Plugins::SpotOn::Plugin::SPOTON_CACHE_VERSION = sub { 4 }; }

unshift @INC, $stub_dir, $project_dir;

my $M = 'Plugins::SpotOn::DontStopTheMusic';
my $loaded = eval { require Plugins::SpotOn::DontStopTheMusic; 1 };
ok($loaded, 'DontStopTheMusic.pm loads against the stubs') or diag($@);

{
    package Test::Client;
    sub new    { return bless { id => $_[1] }, $_[0] }
    sub id     { return $_[0]{id} }
    sub master { return $_[0] }
    sub name   { return 'stub-' . $_[0]{id} }
}

my $client = Test::Client->new('00:04:20:aa:bb:cc');

# Each case: [label, mode, die, norole, expected]
my @CASES = (
    [ 'role mode connect',            'connect', 0, 0, 1 ],
    [ 'role mode browse',             'browse',  0, 0, 0 ],
    [ 'role mode idle',               'idle',    0, 0, 0 ],
    [ 'mode undef (librespot shape)', undef,     0, 0, 0 ],
    [ 'backendFor dies',              'connect', 1, 0, 0 ],
    [ 'no role for the player',       'connect', 0, 1, 0 ],
);

sub _setRole {
    my ($mode, $die, $norole) = @_;
    $Plugins::SpotOn::Unified::DaemonManager::MODE   = $mode;
    $Plugins::SpotOn::Unified::DaemonManager::DIE    = $die;
    $Plugins::SpotOn::Unified::DaemonManager::NOROLE = $norole;
}

# ------------------------------------------------------------
# D1: connectSessionActive($client)
# ------------------------------------------------------------
my $csa = $loaded ? $M->can('connectSessionActive') : undef;
ok($csa, '90.1-06 D1: Plugins::SpotOn::DontStopTheMusic::connectSessionActive exists');
for my $c (@CASES) {
    my ($label, $mode, $die, $norole, $want) = @$c;
    _setRole($mode, $die, $norole);
    my $got = $csa ? eval { $csa->($client) } : undef;
    is($got, $want, "90.1-06 D1: connectSessionActive is $want for $label (no die escapes)");
}
{
    _setRole('connect', 0, 0);
    @Plugins::SpotOn::Unified::DaemonManager::ASKED = ();
    $csa->($client) if $csa;
    is($Plugins::SpotOn::Unified::DaemonManager::ASKED[0], $client,
        '90.1-06 D1: the role is looked up for the client DSTM passed in');
    is($csa ? eval { $csa->(undef) } : undef, 0, '90.1-06 D1: no client -> 0');
}

# ------------------------------------------------------------
# D2: Plugins::SpotOn::Plugin->disableDSTM($client), source text from
# Plugin.pm evaluated in a harness package; it delegates to D1.
# ------------------------------------------------------------
my $pluginSrc = do { local $/; open(my $fh, '<', "$project_dir/Plugins/SpotOn/Plugin.pm") or die $!; <$fh> };
my ($disableSrc) = $pluginSrc =~ /^(sub disableDSTM \{.*?\n\})\n/ms;
ok(defined $disableSrc, '90.1-06 D2: Plugin.pm defines sub disableDSTM');
my $harnessOk = defined $disableSrc
    && eval("package Test::PluginHarness;\nuse strict; use warnings;\n$disableSrc\n1;");
ok($harnessOk, '90.1-06 D2: disableDSTM compiles in a harness package') or diag($@);
for my $c (@CASES) {
    my ($label, $mode, $die, $norole, $want) = @$c;
    _setRole($mode, $die, $norole);
    my $got = $harnessOk ? eval { Test::PluginHarness->disableDSTM($client) } : undef;
    is(($got ? 1 : 0), $want, "90.1-06 D2: disableDSTM is " . ($want ? 'true' : 'false') . " for $label");
}

# ------------------------------------------------------------
# D3: install.xml carries the conflict flag once, inside <extension>
# ------------------------------------------------------------
my $xml = do { local $/; open(my $fh, '<', "$project_dir/Plugins/SpotOn/install.xml") or die $!; <$fh> };
my $flagCount = () = $xml =~ m{<canConflictWithDSTM>1</canConflictWithDSTM>}g;
is($flagCount, 1, '90.1-06 D3: install.xml carries exactly one <canConflictWithDSTM>1</canConflictWithDSTM>');
like($xml, qr{<extension>.*<canConflictWithDSTM>1</canConflictWithDSTM>.*</extension>}s,
    '90.1-06 D3: the flag sits inside the <extension> element');

# ------------------------------------------------------------
# D4-D6: layer 1, SpotOn's own provider dontStopTheMusic($client, $cb)
# ------------------------------------------------------------
my $INFO_RE = qr/DSTM: no recommendations while the Spotify app controls \Q00:04:20:aa:bb:cc\E \(D-13\)/;

sub _runProvider {
    my ($mode, $die) = @_;
    _setRole($mode, $die, 0);
    $Slim::Plugin::DontStopTheMusic::Plugin::MIX_CALLS = 0;
    $Slim::Plugin::DontStopTheMusic::Plugin::SEEDS     = [];
    %Slim::Utils::Log::LINES = ();
    my @calls;
    my $cb = sub { push @calls, [@_] };
    my $fn = $loaded ? $M->can('dontStopTheMusic') : undef;
    my $ok = $fn ? eval { $fn->($client, $cb); 1 } : 0;
    diag("dontStopTheMusic died: $@") if $fn && !$ok;
    my @info = grep { $_ =~ $INFO_RE } map { @{ $_->{info} || [] } } values %Slim::Utils::Log::LINES;
    return {
        calls => \@calls,
        mix   => $Slim::Plugin::DontStopTheMusic::Plugin::MIX_CALLS,
        info  => scalar(@info),
    };
}

{
    my $r = _runProvider('connect', 0);
    is(scalar(@{ $r->{calls} }), 1, '90.1-06 D4: connect - $cb is called exactly once');
    ok(@{ $r->{calls} } && @{ $r->{calls}[0] } == 1 && $r->{calls}[0][0] == $client,
        '90.1-06 D4: connect - $cb gets the client and no tracks');
    is($r->{mix}, 0, '90.1-06 D4: connect - seed tracks are not even read (no getMixableProperties)');
    ok(!$INC{'Plugins/SpotOn/API/SpClient.pm'}, '90.1-06 D4: connect - SpClient is never required');
    is($r->{info}, 1, '90.1-06 D4: connect - the D-13 INFO line is logged once');
}
{
    my $r = _runProvider('browse', 0);
    is($r->{mix}, 1, '90.1-06 D5: browse - the provider reads seed tracks as before');
    is(scalar(@{ $r->{calls} }), 1, '90.1-06 D5: browse - no seeds -> $cb once (the existing early-out)');
    is($r->{info}, 0, '90.1-06 D5: browse - no D-13 INFO line');

    my $d = _runProvider('connect', 1);
    is($d->{mix}, 1, '90.1-06 D5: backendFor dies - the provider runs as before');
    is(scalar(@{ $d->{calls} }), 1, '90.1-06 D5: backendFor dies - $cb once');
}
{
    my $r = _runProvider(undef, 0);
    is($r->{mix}, 1, '90.1-06 D6: librespot shape (mode undef) - seed tracks read as before');
    is(scalar(@{ $r->{calls} }), 1, '90.1-06 D6: librespot shape - $cb once');
    is($r->{info}, 0, '90.1-06 D6: librespot shape - no D-13 INFO line');
}

# ------------------------------------------------------------
# L1: FINDING_FOR_06 - the provider's log handle is category plugin.spoton.
# The old Slim::Utils::Log->logger('plugin.spoton') passed the class name as
# the category (Log.pm 281-284), so every INFO line of the provider was lost.
# ------------------------------------------------------------
ok((grep { $_ eq 'plugin.spoton' } @Slim::Utils::Log::CATEGORIES),
    '90.1-06 L1: DontStopTheMusic.pm asks for the logger category plugin.spoton');
ok(!(grep { $_ eq 'Slim::Utils::Log' } @Slim::Utils::Log::CATEGORIES),
    "90.1-06 L1: no logger with the class name as category ('Slim::Utils::Log')");
{
    _runProvider('connect', 0);
    my @onSpoton = grep { $_ =~ $INFO_RE } @{ $Slim::Utils::Log::LINES{'plugin.spoton'}{info} || [] };
    is(scalar(@onSpoton), 1, '90.1-06 L1: the D-13 INFO line reaches category plugin.spoton');
}

# ------------------------------------------------------------
# 90.1 review WR-04 (D5): the answer must not depend on the order of LMS's
# `playlist newsong` listeners. A foreign title (a local file) the user
# starts from LMS ends the Connect session in Connect.pm's _onNewSong, but
# DSTM's onPlaylistChange may run first and still read role mode connect.
# The app does not control a player whose current LMS song is not SpotOn's.
# ------------------------------------------------------------
{
    package Test::SongClient;
    sub new         { my ($c, %a) = @_; return bless { %a }, $c }
    sub id          { return '00:04:20:aa:bb:dd' }
    sub master      { return $_[0] }
    sub playingSong { die "playingSong exploded\n" if $_[0]{die}; return $_[0]{playing} }
    sub streamingSong { return $_[0]{streaming} }
    package Test::Song;
    sub new   { return bless { url => $_[1] }, $_[0] }
    sub track { my $s = shift; return defined $s->{url} ? bless({ url => $s->{url} }, 'Test::SongTrack') : undef }
    package Test::SongTrack;
    sub url   { return $_[0]{url} }
}
{
    my @D5 = (
        [ 'current song a local file',              Test::SongClient->new(playing => Test::Song->new('file:///music/one.flac')), 0 ],
        [ 'current song a radio stream',            Test::SongClient->new(playing => Test::Song->new('http://radio.example/stream')), 0 ],
        [ 'current song SpotOn\'s',                 Test::SongClient->new(playing => Test::Song->new('spoton://track:4uLU6hMCjMI75M1A2tKUQC')), 1 ],
        [ 'no playing song, streaming SpotOn\'s',   Test::SongClient->new(streaming => Test::Song->new('spoton://track:4uLU6hMCjMI75M1A2tKUQC')), 1 ],
        [ 'no playing song, streaming a local file', Test::SongClient->new(streaming => Test::Song->new('file:///music/one.flac')), 0 ],
        [ 'no song at all',                         Test::SongClient->new(), 1 ],
        [ 'the song lookup dies',                   Test::SongClient->new(die => 1), 0 ],
    );
    for my $c (@D5) {
        my ($label, $cl, $want) = @$c;
        _setRole('connect', 0, 0);
        my $got = $csa ? eval { $csa->($cl) } : undef;
        is($got, $want, "90.1 WR-04 D5: role mode connect, $label - connectSessionActive is $want");
        my $hook = $harnessOk ? eval { Test::PluginHarness->disableDSTM($cl) } : undef;
        is(($hook ? 1 : 0), $want, "90.1 WR-04 D5: role mode connect, $label - disableDSTM is " . ($want ? 'true' : 'false'));
    }
    _setRole('browse', 0, 0);
    my $b = Test::SongClient->new(playing => Test::Song->new('spoton://track:4uLU6hMCjMI75M1A2tKUQC'));
    is(($csa ? $csa->($b) : undef), 0, '90.1 WR-04 D5: role mode browse with SpotOn\'s song - still 0 (the song never makes a session)');
}

# ------------------------------------------------------------
# 90.1 review WR-03 (b): the session is checked again when the fetch chain
# delivers. getTopTracks and up to three searches 0.2 s apart take seconds;
# a take-over inside that window must not end in ten SpotOn tracks appended
# to the app's session. (Placed last: the stubs below register SpClient and
# Plugin.pm in %INC, which D4 checks is never required.)
# ------------------------------------------------------------
{
    no warnings 'once';
    $INC{'Plugins/SpotOn/Plugin.pm'}         = __FILE__;
    $INC{'Plugins/SpotOn/API/SpClient.pm'}   = __FILE__;
    *Plugins::SpotOn::Plugin::_typeShortForClient     = sub { 'ogg' };
    *Plugins::SpotOn::Plugin::_bitrateLabelForClient  = sub { '320' };
    *Plugins::SpotOn::Plugin::_releaseYear            = sub { '' };
    *Plugins::SpotOn::Plugin::_extractTrackIds        = sub { () };
    *Plugins::SpotOn::API::SpClient::TRACK_META_FORMAT = sub { 1 };
}
my @WR03_TRACKS = map {
    { uri => "spotify:track:wr03fixture$_", name => "Title $_", artists => [ { name => "Artist $_" } ],
      album => { name => 'Album', images => [] }, duration_ms => 180000 }
} 1 .. 3;
sub _runFinalize {
    my ($mode) = @_;
    _setRole($mode, 0, 0);
    %Slim::Utils::Log::LINES = ();
    my @calls;
    my $fn = $loaded ? $M->can('_finalizeResults') : undef;
    my $ok = $fn ? eval { $fn->($client, [ @WR03_TRACKS ], [], {}, sub { push @calls, [@_] }); 1 } : 0;
    diag("_finalizeResults died: $@") if $fn && !$ok;
    return \@calls;
}
{
    my $b = _runFinalize('browse');
    is(scalar(@$b), 1, '90.1 WR-03 F1 control: browse - $cb once');
    ok(@$b && ref($b->[0][1]) eq 'ARRAY' && @{ $b->[0][1] } == 3, '90.1 WR-03 F1 control: browse - the three tracks are delivered');

    my $c = _runFinalize('connect');
    is(scalar(@$c), 1, '90.1 WR-03 F1: a session that began during the fetch - $cb exactly once');
    ok(@$c && @{ $c->[0] } == 1 && $c->[0][0] == $client, '90.1 WR-03 F1: ... with the client and no tracks');
    my @info = @{ $Slim::Utils::Log::LINES{'plugin.spoton'}{info} || [] };
    is(scalar(grep { /SpotOn DSTM: queuing/ } @info), 0, '90.1 WR-03 F1: no "queuing" INFO line');
    is(scalar(grep { /DSTM: .*Spotify app controls \Q00:04:20:aa:bb:cc\E.*\(D-13\)/ } @info), 1,
        '90.1 WR-03 F1: one D-13 INFO line names the dropped result');
}

done_testing();
