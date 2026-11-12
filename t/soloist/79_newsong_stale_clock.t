#!/usr/bin/perl
# 261112-d2m: after a natural PCM title change Material's bar starts at the previous title's end. LMS shows
# startOffset(0) + songElapsedSeconds, squeezelite reports A's elapsed in B's start STAT, LMS holds it until the
# next STAT, and the subscriber push 0.3 s after newsong carries it (.planning/debug/resolved/beta9-balken-springt-mitte.md).
# Fix (lever A): Plugin.pm subscribes _onNewSongStaleClock to [['playlist'], ['newsong']]. For a Soloist Browse title
# (spoton://, not connect-, no Connect session, startOffset 0) whose songElapsedSeconds is > 3 s at newsong it checks
# every 0.2 s (at most 10 checks) and sends notifyFromArray($master, ['newmetadata']) on stale checks 1..9 (each one
# re-arms LMS's pending subscriber push, so the stale push never leaves) and once more on the first fresh value.
# Every Slim module is stubbed and the clock is fake, so the file passes with the LMS tree hidden. LIMIT (L1): the fake
# clock proves the SEQUENCE only; neither the extrapolation of Squeezebox2.pm nor the LMS push debounce is modelled.
use strict;
use warnings;
no warnings 'once';
use Test::More;
use File::Basename qw(dirname);
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use Cwd qw(abs_path);
use Time::HiRes ();

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
my %_ttl;
sub new    { bless {}, shift }
sub get    { $_store{$_[1]} }
sub set    { $_store{$_[1]} = $_[2]; $_ttl{$_[1]} = $_[3]; 1 }
sub remove { delete $_store{$_[1]}; delete $_ttl{$_[1]} }
sub ttl    { $_ttl{$_[1]} }
sub clear  { %_store = (); %_ttl = () }
1;
END

# Recording timers: setTimer($obj, $when, $code, @args) is kept raw in @set_calls and as an entry in @pending;
# killTimers($obj, $code) drops the entries with the same object and code, like the real Slim::Utils::Timers.
write_stub($stub_dir, 'Slim::Utils::Timers', <<'END');
package Slim::Utils::Timers;
use Scalar::Util ();
our (@pending, @set_calls);
sub setTimer {
    push @set_calls, [@_];
    my ($obj, $when, $code, @args) = @_;
    push @pending, { obj => $obj, when => $when, code => $code, args => [@args] };
}
sub killTimers {
    my ($obj, $code) = @_;
    @pending = grep {
        !( Scalar::Util::refaddr($_->{obj}) && Scalar::Util::refaddr($obj)
           && Scalar::Util::refaddr($_->{obj}) == Scalar::Util::refaddr($obj)
           && $_->{code} == $code )
    } @pending;
}
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

# notifyFromArray records [ time, @args ] (the time is the fake clock once the test installed it).
write_stub($stub_dir, 'Slim::Control::Request', <<'END');
package Slim::Control::Request;
our @subscribed   = ();   # [ handler, filter ]
our @unsubscribed = ();   # handler
our @notified     = ();   # [ time, client, command array ]
sub subscribe       { push @subscribed, [@_] }
sub unsubscribe     { push @unsubscribed, $_[0] }
sub addDispatch     { }
sub executeRequest  { }
sub notifyFromArray { push @notified, [ Time::HiRes::time(), @_ ] }
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

write_stub($stub_dir, 'Plugins::SpotOn::API::SpClient', <<'END');
package Plugins::SpotOn::API::SpClient;
use constant TRACK_META_FORMAT => 2;
sub getTrack { }
sub trackBatchSize { 200 }
1;
END

write_stub($stub_dir, 'Plugins::SpotOn::Connect', <<'END');
package Plugins::SpotOn::Connect;
our $is_connect = 0;   # what isSpotifyConnect answers
sub isSpotifyConnect { return $is_connect }
sub shutdown { }
1;
END

# The backend name the plugin asks (_isSoloistBackend): 'soloist' unless a cell switches it.
write_stub($stub_dir, 'Plugins::SpotOn::Unified::DaemonManager', <<'END');
package Plugins::SpotOn::Unified::DaemonManager;
our $name = 'soloist';
sub backendName { return $name }
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

require Slim::Control::Request;   # the plugin never loads it itself (LMS has it loaded): the stub must be in %INC
require Plugins::SpotOn::Plugin;
my $prefs = Slim::Utils::Prefs::preferences('plugin.spoton');
$prefs->init({ recentSearches => [] });

# ------------------------------------------------------------
# Fake clock: Plugin.pm calls Time::HiRes::time() qualified, so the glob is replaced.
# run_until($t) runs every pending timer due at or before $t, earliest first, with $NOW at its due time.
# ------------------------------------------------------------
our $NOW = 1000;
our $T0  = 1000;
{
    no warnings 'redefine';
    *Time::HiRes::time = sub { return $main::NOW };
}
sub run_until {
    my ($t) = @_;
    my $guard = 0;
    while ($guard++ < 1000) {
        my ($i) = sort { $Slim::Utils::Timers::pending[$a]{when} <=> $Slim::Utils::Timers::pending[$b]{when} }
                  grep { $Slim::Utils::Timers::pending[$_]{when} <= $t } 0 .. $#Slim::Utils::Timers::pending;
        last unless defined $i;
        my ($e) = splice(@Slim::Utils::Timers::pending, $i, 1);
        $NOW = $e->{when};
        $e->{code}->($e->{obj}, @{ $e->{args} });
    }
    $NOW = $t;
}

# ------------------------------------------------------------
# Fakes: request / client / song. The elapsed value of a client is a plain value or a code ref
# evaluated per read (limit L1: no LMS extrapolation is modelled).
# ------------------------------------------------------------
{
    package FakeTrack; sub new { bless { url => $_[1] }, $_[0] } sub url { $_[0]{url} }
    package FakeSong;
    sub new { my ($c, $url, %o) = @_; bless { url => $url, startOffset => $o{startOffset} // 0 }, $c }
    sub track       { FakeTrack->new($_[0]{url}) }
    sub startOffset { $_[0]{startOffset} }
    sub duration    { 200 }
    package FakeClient;
    sub new {
        my ($c, $id, %o) = @_;
        bless { id => $id, song => $o{song}, elapsed => $o{elapsed}, state => 'playing', master => undef, members => undef }, $c;
    }
    sub id                     { $_[0]{id} }
    sub master                 { $_[0]{master} // $_[0] }
    sub syncGroupActiveMembers { @{ $_[0]{members} || [ $_[0] ] } }
    sub playingSong            { $_[0]{song} }
    # Like StreamingController.pm 1676-1679: isPlaying(1) is strictly PLAYING; isPlaying() is "not stopped and not paused"
    # (so it is also true while BUFFERING / WAITING_TO_SYNC). state: playing | paused | stopped | buffering.
    sub isPlaying {
        my ($c, $really) = @_;
        my $st = $c->{state} // 'playing';
        return $really ? ($st eq 'playing' ? 1 : 0) : ($st =~ /^(?:stopped|paused)\z/ ? 0 : 1);
    }
    sub songElapsedSeconds     { my $e = $_[0]{elapsed}; return ref $e eq 'CODE' ? $e->($_[0]) : $e }
    package FakeRequest; sub new { bless { client => $_[1] }, $_[0] } sub client { $_[0]{client} }
}

sub b22 { sprintf('%022d', $_[0]) }
my $URL = 'spoton://track:' . b22(1);

sub reset_t {
    @Slim::Utils::Timers::pending   = ();
    @Slim::Utils::Timers::set_calls = ();
    @Slim::Control::Request::notified = ();
    $Plugins::SpotOn::Connect::is_connect = 0;
    $Plugins::SpotOn::Unified::DaemonManager::name = 'soloist';
    $NOW = 1000;
    $T0  = 1000;
}
sub pend  { scalar @Slim::Utils::Timers::pending }
sub nsets { scalar @Slim::Utils::Timers::set_calls }
sub nots  { @Slim::Control::Request::notified }
sub off   { sprintf('%.2f', $_[0] - $T0) }
sub mk_song   { FakeSong->new(@_) }
sub mk_client { my ($id, %o) = @_; FakeClient->new($id, %o) }
# the newsong hook, returns whether it lived
sub newsong {
    my ($client) = @_;
    return eval { Plugins::SpotOn::Plugin::_onNewSongStaleClock(FakeRequest->new($client)); 1 } ? 1 : 0;
}

my $have = defined(&Plugins::SpotOn::Plugin::_onNewSongStaleClock) ? 1 : 0;   # (the OPMLBased stub's can() answers 1 for everything)
ok($have, 'D2M-0: Plugin.pm has _onNewSongStaleClock');
if (!$have) {
    # RED: the hook does not exist yet; every behavioural cell below fails instead of dying
    *Plugins::SpotOn::Plugin::_onNewSongStaleClock = sub { };
}
ok(defined(&Plugins::SpotOn::Plugin::_newSongClockCheck), 'D2M-0: Plugin.pm has _newSongClockCheck');

# --- D2M-0 wiring (source text, comment lines excluded)
sub sub_text {
    my ($file, $name) = @_;
    open(my $fh, '<', $file) or die "$file: $!";
    local $/; my $src = <$fh>; close $fh;
    my ($body) = $src =~ /^sub \Q$name\E \{\n(.*?)^\}\n/ms;
    return join "\n", grep { !/^\s*#/ } split /\n/, ($body // '');
}
{
    my $init = sub_text("$project_dir/Plugins/SpotOn/Plugin.pm", 'initPlugin');
    my $shut = sub_text("$project_dir/Plugins/SpotOn/Plugin.pm", 'shutdownPlugin');
    like($init, qr/subscribe\(\\&_onNewSongStaleClock,\s*\[\['playlist'\],\s*\['newsong'\]\]\)/,
        'D2M-0: initPlugin subscribes _onNewSongStaleClock to playlist newsong');
    like($shut, qr/unsubscribe\(\\&_onNewSongStaleClock\)/, 'D2M-0: shutdownPlugin unsubscribes _onNewSongStaleClock');
    like($shut, qr/killTimers\([^;]*\\&_newSongClockCheck\)/, 'D2M-0: shutdownPlugin kills the pending _newSongClockCheck timers');
}

# --- D2M-1: stale at newsong, three stale checks, the fourth fresh
{
    reset_t();
    my $c = mk_client('02:00:00:aa:bb:01', song => mk_song($URL),
        elapsed => sub { my $dt = $main::NOW - $main::T0; $dt < 0.7 ? 59.7 + $dt : 1.0 });
    ok(newsong($c), 'D2M-1: the hook lives');
    is(scalar(nots()), 0, 'D2M-1: no notify in the hook itself (check 1 at +0.2 s re-arms LMS own push due at +0.3 s)');
    is(pend(), 1, 'D2M-1: exactly one check pending after a stale newsong');
    ok(pend() && abs($Slim::Utils::Timers::pending[0]{when} - ($T0 + 0.2)) < 1e-6, 'D2M-1: the pending check is due at newsong + 0.2 s');
    run_until($T0 + 3);
    my @n = nots();
    is(scalar(@n), 4, 'D2M-1: 4 notifies in total (stale checks 1-3 and the last one on the first fresh value)');
    is_deeply([ map { off($_->[0]) } @n ], [ '0.20', '0.40', '0.60', '0.80' ], 'D2M-1: the notifies sit at newsong + 0.2/0.4/0.6/0.8 s');
    is(scalar(grep { $_->[1] == $c && ref $_->[2] eq 'ARRAY' && join(',', @{ $_->[2] }) eq 'newmetadata' } @n), scalar(@n),
        'D2M-1: every notify is (client, [newmetadata])');
    my $prev = $T0; my $gap_ok = 1;
    for my $x (@n) { $gap_ok = 0 if $x->[0] - $prev >= 0.3; $prev = $x->[0]; }
    ok($gap_ok && @n, 'D2M-1: every gap (newsong to first notify, between notifies) is below 0.3 s');
    is(pend(), 0, 'D2M-1: nothing pending after the fresh value');
    is(scalar(nots()), 4, 'D2M-1: still 4 notifies at newsong + 3 s');
}

# --- D2M-2: stale through, capped at 10 checks
{
    reset_t();
    my $c = mk_client('02:00:00:aa:bb:02', song => mk_song($URL), elapsed => 59.7);
    ok(newsong($c), 'D2M-2: the hook lives');
    run_until($T0 + 3);
    my @s = @Slim::Utils::Timers::set_calls;
    is(scalar(@s), 10, 'D2M-2: exactly 10 setTimer calls (the hook plus 9 re-arms)');
    ok((scalar(@s) == 10) && !grep({ abs($s[$_ - 1][1] - ($T0 + 0.2 * $_)) >= 1e-6 } 1 .. 10),
        'D2M-2: the setTimer calls are due at newsong + 0.2 * k, k = 1..10');
    my @n = nots();
    is(scalar(@n), 9, 'D2M-2: exactly 9 notifies (stale checks 1..9)');
    ok((scalar(@n) == 9) && !grep({ abs($n[$_ - 1][0] - ($T0 + 0.2 * $_)) >= 1e-6 } 1 .. 9),
        'D2M-2: the notifies sit at newsong + 0.2 * k, k = 1..9');
    ok(!grep({ $_->[0] > $T0 + 1.9 } @n), 'D2M-2: no notify at check 10 (gave up without a push)');
    is(pend(), 0, 'D2M-2: nothing pending at newsong + 3 s');
}

# --- D2M-3: fresh at newsong
{
    reset_t();
    my $c = mk_client('02:00:00:aa:bb:03', song => mk_song($URL), elapsed => 0.3);
    ok(newsong($c), 'D2M-3: the hook lives');
    is(nsets(), 0, 'D2M-3: no timer for a fresh clock');
    run_until($T0 + 3);
    is(scalar(nots()), 0, 'D2M-3: no notify for a fresh clock');
}

# --- D2M-4: a seek (startOffset != 0) is not stale
{
    reset_t();
    my $c = mk_client('02:00:00:aa:bb:04', song => mk_song($URL, startOffset => 95), elapsed => 59.7);
    ok(newsong($c), 'D2M-4: the hook lives');
    is(nsets(), 0, 'D2M-4: no timer after a seek');
    run_until($T0 + 3);
    is(scalar(nots()), 0, 'D2M-4: no notify after a seek');
}

# --- D2M-5: librespot, Connect, connect- url, foreign url
{
    my @cases = (
        [ 'librespot backend', sub { $Plugins::SpotOn::Unified::DaemonManager::name = 'librespot'; mk_song($URL) } ],
        [ 'Connect session',   sub { $Plugins::SpotOn::Connect::is_connect = 1; mk_song($URL) } ],
        [ 'connect- url',      sub { mk_song('spoton://connect-abc') } ],
        [ 'foreign url',       sub { mk_song('file:///music/a.flac') } ],
    );
    for my $case (@cases) {
        my ($label, $setup) = @$case;
        reset_t();
        my $song = $setup->();
        my $c = mk_client('02:00:00:aa:bb:05', song => $song, elapsed => 59.7);
        newsong($c);
        is(pend() + nsets(), 0, "D2M-5: $label: no timer");
        run_until($T0 + 3);
        is(scalar(nots()), 0, "D2M-5: $label: no notify");
    }

    # Control pair of the connect- url case (WR-02): same backend, same Connect flag (off), same client, same stale clock,
    # only the url differs. The control must start the chain, the connect- url must not: so only the (?!connect-)
    # lookahead of _onNewSongStaleClock can be what rejects the second one.
    reset_t();
    my $ctl = mk_client('02:00:00:aa:bb:05', song => mk_song($URL), elapsed => 59.7);
    newsong($ctl);
    is(pend(), 1, 'D2M-5: control (spoton://track: url, everything else as the connect- url case): the chain starts');
    reset_t();
    my $con = mk_client('02:00:00:aa:bb:05', song => mk_song('spoton://connect-' . b22(1)), elapsed => 59.7);
    newsong($con);
    is(pend(), 0, 'D2M-5: connect- url alone (backend, Connect flag, clock as in the control): no chain');
}

# --- D2M-6: the song guard, stop/pause, a new newsong, a url change
{
    # (a) the song object is replaced before check 1 (the new title reads fresh)
    reset_t();
    my $c = mk_client('02:00:00:aa:bb:06', song => mk_song($URL), elapsed => 59.7);
    newsong($c);
    $c->{song}    = mk_song('spoton://track:' . b22(2));
    $c->{elapsed} = 1.0;
    run_until($T0 + 3);
    is(scalar(nots()), 0, 'D2M-6: a replaced song object gets no notify from the old check');
    is(pend(), 0, 'D2M-6: a replaced song object leaves nothing pending');

    # (b) stopped or paused: elapsed reads 0, that is not a fresh value
    reset_t();
    $c = mk_client('02:00:00:aa:bb:07', song => mk_song($URL), elapsed => 59.7);
    newsong($c);
    $c->{state}   = 'stopped';
    $c->{elapsed} = 0;
    run_until($T0 + 3);
    is(scalar(nots()), 0, 'D2M-6: stopped (elapsed 0) gets no notify');
    is(pend(), 0, 'D2M-6: stopped leaves nothing pending');

    # (b2) paused inside the window (WR-02): isPlaying(1) is strictly PLAYING, a paused player ends the chain. The
    # elapsed time of a paused player holds its (stale) value, so only the isPlaying check can end the chain here.
    reset_t();
    $c = mk_client('02:00:00:aa:bb:0d', song => mk_song($URL), elapsed => 59.7);
    newsong($c);
    run_until($T0 + 0.3);
    is(scalar(nots()), 1, 'D2M-6: paused: check 1 (still playing) notified once');
    $c->{state} = 'paused';
    run_until($T0 + 3);
    is(scalar(nots()), 1, 'D2M-6: paused inside the window: no further notify');
    is(pend(), 0, 'D2M-6: paused inside the window leaves nothing pending');

    # (b3) BUFFERING inside the window (WR-02): isPlaying() without the argument is also true while buffering, so only
    # isPlaying(1) ends the chain. This pins the strict form (a "simplification" to isPlaying() goes red).
    reset_t();
    $c = mk_client('02:00:00:aa:bb:0e', song => mk_song($URL), elapsed => 59.7);
    newsong($c);
    run_until($T0 + 0.3);
    $c->{state} = 'buffering';
    run_until($T0 + 3);
    is(scalar(nots()), 1, 'D2M-6: buffering inside the window: no notify after the state change (isPlaying(1) is strict)');
    is(pend(), 0, 'D2M-6: buffering inside the window leaves nothing pending');

    # (c) a second stale newsong with a new song object replaces the pending check
    reset_t();
    $c = mk_client('02:00:00:aa:bb:08', song => mk_song($URL), elapsed => sub { $main::NOW - $main::T0 < 0.6 ? 59.9 : 1.0 });
    newsong($c);
    run_until($T0 + 0.3);
    $c->{song} = mk_song('spoton://track:' . b22(3));
    newsong($c);
    is(pend(), 1, 'D2M-6: a second newsong leaves exactly one pending check');
    run_until($T0 + 3);
    is(scalar(nots()), 3, 'D2M-6: notifies at +0.2 (first title), +0.5 (stale) and +0.7 (fresh, last) = 3 in total');
    is(pend(), 0, 'D2M-6: nothing pending at newsong + 3 s after the replaced check');

    # (d) a newsong with a foreign url clears the pending check
    reset_t();
    $c = mk_client('02:00:00:aa:bb:09', song => mk_song($URL), elapsed => 59.7);
    newsong($c);
    run_until($T0 + 0.3);
    $c->{song} = mk_song('file:///x');
    newsong($c);
    is(pend(), 0, 'D2M-6: a newsong with a foreign url clears the pending check');
    my $at = $NOW;
    run_until($T0 + 3);
    is(scalar(grep { $_->[0] > $at + 1e-6 } nots()), 0, 'D2M-6: no notify after the foreign newsong');
}

# --- D2M-7: sync group, one master check reaches every active member
{
    reset_t();
    my $song = mk_song($URL);
    my $m = mk_client('02:00:00:aa:bb:0a', song => $song, elapsed => sub { $main::NOW - $main::T0 < 0.3 ? 59.8 : 1.0 });
    my $s = mk_client('02:00:00:aa:bb:0b', song => $song, elapsed => 0);
    $s->{master}  = $m;
    $m->{members} = [ $m, $s ];
    $s->{members} = [ $m, $s ];
    newsong($s);
    newsong($m);
    is(pend(), 1, 'D2M-7: newsong for the slave and the master leaves exactly one pending check');
    ok(pend() && $Slim::Utils::Timers::pending[0]{obj} == $m, 'D2M-7: the pending check belongs to the master');
    run_until($T0 + 3);
    # model of Queries.pm 3935-3937 / Request.pm 2032-2033 (Bug 10064): a subscriber gets the notify when it sits in
    # the syncGroupActiveMembers of the notifying client; one master notify and one notify per member both pass
    my @last = grep { abs($_->[0] - ($T0 + 0.4)) < 1e-6 } nots();
    for my $x ([ 'the master', $m ], [ 'the slave', $s ]) {
        my ($label, $sub) = @$x;
        ok(scalar(grep { my $t = $_->[1]; scalar(grep { $_ == $sub } $t->syncGroupActiveMembers) } @last),
            "D2M-7: the last notify (first fresh check) reaches the subscribers of $label");
    }
    is(pend(), 0, 'D2M-7: nothing pending after the fresh value');

    # (c) WR-02: a newsong for the SLAVE only, while the MASTER reads stale. The slave's own clock is fresh (0), so the
    # chain starts only if the hook resolves the slave to its master first, and the check belongs to the master.
    reset_t();
    $song = mk_song($URL);
    $m = mk_client('02:00:00:aa:bb:0f', song => $song, elapsed => sub { $main::NOW - $main::T0 < 0.3 ? 59.8 : 1.0 });
    $s = mk_client('02:00:00:aa:bb:10', song => $song, elapsed => 0);
    $s->{master}  = $m;
    $m->{members} = [ $m, $s ];
    $s->{members} = [ $m, $s ];
    newsong($s);
    is(pend(), 1, 'D2M-7: a newsong for the slave alone with a stale master clock leaves exactly one pending check');
    ok(pend() && $Slim::Utils::Timers::pending[0]{obj} == $m, 'D2M-7: that check is owned by the master, not the slave');
    run_until($T0 + 3);
    is(scalar(nots()), 2, 'D2M-7: stale check 1 and the first fresh value notify (2 in total)');
    ok(!grep({ $_->[1] != $m } nots()), 'D2M-7: every notify goes to the master');
    is(pend(), 0, 'D2M-7: nothing pending after the fresh value');
}

# --- D2M-8: no playingSong at newsong (the Plugin.pm watchdog case): no deferral, no die
{
    reset_t();
    my $c = mk_client('02:00:00:aa:bb:0c', song => undef, elapsed => 59.7);
    ok(newsong($c), 'D2M-8: the hook returns without die when playingSong is undef');
    is(nsets(), 0, 'D2M-8: no timer without a playing song');
    run_until($T0 + 3);
    is(scalar(nots()), 0, 'D2M-8: no notify without a playing song');
}

# --- D2M-9 (WR-01): a repeated newsong for the song object that is already playing is not a title start
{
    # (a) the title started fresh (no chain), later LMS repeats the newsong for the same song object while the elapsed
    # time is legitimately high: no chain, no notify, no timer
    reset_t();
    my $song = mk_song($URL);
    my $c = mk_client('02:00:00:aa:bb:11', song => $song, elapsed => 0.3);
    newsong($c);
    is(nsets(), 0, 'D2M-9: the title start itself (fresh clock) starts nothing');
    $NOW = $T0 + 120;
    $c->{elapsed} = 59.7;
    ok(newsong($c), 'D2M-9: the repeated newsong lives');
    is(nsets() + pend(), 0, 'D2M-9: a repeated newsong for the same song object (elapsed 59.7) starts no chain');
    run_until($T0 + 130);
    is(scalar(nots()), 0, 'D2M-9: a repeated newsong for the same song object notifies nothing');

    # (b) a NEW song object with a stale clock still starts the chain after such a repeat
    $c->{song} = mk_song('spoton://track:' . b22(7));
    $T0 = $NOW;
    @Slim::Utils::Timers::pending = ();   # independent of what cell (a) left behind
    @Slim::Control::Request::notified = ();
    newsong($c);
    is(pend(), 1, 'D2M-9: a new song object with a stale clock after a repeat still starts the chain');
    run_until($T0 + 0.3);
    is(scalar(nots()), 1, 'D2M-9: and that chain notifies at +0.2');

    # (c) a repeat while the chain of that same title is running leaves the chain alone (it is still a title start)
    reset_t();
    $c = mk_client('02:00:00:aa:bb:12', song => mk_song($URL), elapsed => sub { $main::NOW - $main::T0 < 0.7 ? 59.7 : 1.0 });
    newsong($c);
    run_until($T0 + 0.3);
    is(scalar(nots()), 1, 'D2M-9: first title start: check 1 notified');
    newsong($c);   # the same song object again
    is(pend(), 1, 'D2M-9: a repeat during the running chain leaves that chain pending');
    run_until($T0 + 3);
    is(scalar(nots()), 4, 'D2M-9: the chain runs on (+0.2, +0.4, +0.6 stale, +0.8 fresh) = 4 notifies');
    is(pend(), 0, 'D2M-9: nothing pending after the fresh value');
}

done_testing();
