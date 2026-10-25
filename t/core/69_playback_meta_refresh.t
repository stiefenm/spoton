#!/usr/bin/perl
# 79-27 (D-20): a track that starts playing is fetched fresh. Plugin.pm subscribes _onNewSongRefreshMeta to
# [['playlist'], ['newsong']]; for a Browse player playing spoton://track:<22 base62> it calls
# SpClient->getTrack(..., { refresh => 1 }) (debounced per track id for 60 s, Connect sessions skipped) and
# rewrites an existing spoton_meta_<md5 url> record. Connect.pm _fetchTrackMetadata passes refresh too.
# Every Slim module is stubbed below, so the file passes with the LMS tree hidden.
use strict;
use warnings;
no warnings 'once';
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
my %_ttl;
our @SET_LOG = ();   # every set(): [ key, value, expiry ]
sub new    { bless {}, shift }
sub get    { $_store{$_[1]} }
sub set    { push @SET_LOG, [ $_[1], $_[2], $_[3] ]; $_store{$_[1]} = $_[2]; $_ttl{$_[1]} = $_[3]; 1 }
sub remove { delete $_store{$_[1]}; delete $_ttl{$_[1]} }
sub ttl    { $_ttl{$_[1]} }
sub clear  { %_store = (); %_ttl = (); @SET_LOG = () }
1;
END

write_stub($stub_dir, 'Slim::Utils::Timers', <<'END');
package Slim::Utils::Timers;
our @set_calls = ();
sub setTimer   { push @set_calls, [@_] }
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
our @subscribed   = ();   # [ handler, filter ]
our @unsubscribed = ();   # handler
sub subscribe       { push @subscribed, [@_] }
sub unsubscribe     { push @unsubscribed, $_[0] }
sub addDispatch     { }
sub executeRequest  { }
sub notifyFromArray { }
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
# 79-27 D-20: records getTrack calls; the test completes them by hand
our @getTrack_calls = ();   # { account, id, opts, cb }
sub getTrack {
    my ($class, $account, $id, $cb, $opts) = @_;
    push @getTrack_calls, { account => $account, id => $id, opts => $opts, cb => $cb };
}
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

require Plugins::SpotOn::Plugin;
my $prefs = Slim::Utils::Prefs::preferences('plugin.spoton');
$prefs->init({ recentSearches => [] });
$prefs->set('activeAccount', 'acctD20');

use Digest::MD5 qw(md5_hex);

# ------------------------------------------------------------
# Fakes: request / client / song
# ------------------------------------------------------------
{
    package FakeTrack; sub new { bless { url => $_[1] }, $_[0] } sub url { $_[0]{url} }
    package FakeSong;  sub new { bless { url => $_[1] }, $_[0] } sub track { FakeTrack->new($_[0]{url}) } sub duration { 200 }
    package FakeClient;
    sub new { bless { id => $_[1], url => $_[2] }, $_[0] }
    sub id { $_[0]{id} }
    sub master { $_[0] }
    sub playingSong { $_[0]{url} ? FakeSong->new($_[0]{url}) : undef }
    package FakeRequest; sub new { bless { client => $_[1] }, $_[0] } sub client { $_[0]{client} }
}

my $SP    = 'Plugins::SpotOn::API::SpClient';
my $cache = Slim::Utils::Cache->new();
sub calls { return @Plugins::SpotOn::API::SpClient::getTrack_calls }
sub reset_t69 {
    @Plugins::SpotOn::API::SpClient::getTrack_calls = ();
    $cache->clear();
    $Plugins::SpotOn::Connect::is_connect = 0;
    @Slim::Utils::Timers::set_calls = ();
}
sub newsong {
    my ($url, %o) = @_;
    my $client = FakeClient->new($o{mac} // '02:00:00:aa:bb:01', $url);
    Plugins::SpotOn::Plugin::_onNewSongRefreshMeta(FakeRequest->new($client));
}
sub b22 { sprintf('%022d', $_[0]) }

my $have = defined(&Plugins::SpotOn::Plugin::_onNewSongRefreshMeta) ? 1 : 0;   # (the OPMLBased stub's can() answers 1 for everything)
ok($have, '79-27 D-20: Plugin.pm has _onNewSongRefreshMeta');
if (!$have) {
    # RED: the handler does not exist yet; every behavioural cell below fails instead of dying
    *Plugins::SpotOn::Plugin::_onNewSongRefreshMeta = sub { };
}

# --- a Browse track start calls getTrack with refresh once and rewrites the record
{
    reset_t69();
    my $id  = b22(11);
    my $url = "spoton://track:$id";
    my $key = 'spoton_meta_' . md5_hex($url);
    $cache->set($key, {
        title => 'Old Title', artist => 'Old Artist', album => 'Old Album', duration => 100, cover => 'old.jpg', icon => 'old.jpg',
        year => '1999', bitrate => '320k', type => 'Spotify Browse', artistId => 'ART1', albumId => 'ALB1',
    }, 604800);
    newsong($url);
    my @c = calls();
    is(scalar(@c) . '/' . ($c[0] && $c[0]{account} // '?') . '/' . ($c[0] && $c[0]{id} // '?') . '/' . ($c[0] && ref $c[0]{opts} eq 'HASH' && $c[0]{opts}{refresh} ? 'refresh' : 'plain'),
        "1/acctD20/$id/refresh", '79-27 D-20: playlist newsong for a Browse player playing spoton://track:<id> calls getTrack with refresh exactly once');
    @Slim::Utils::Cache::SET_LOG = ();
    $c[0]{cb}->({
        id => $id, uri => "spotify:track:$id", name => 'New Title', duration_ms => 215000,
        artists => [ { name => 'New Artist' }, { name => 'Second' } ],
        album => { name => 'New Album', images => [ { url => 'small.jpg', width => 64, height => 64 }, { url => 'big.jpg', width => 640, height => 640 } ] },
    }) if @c;
    my $rec = $cache->get($key) || {};
    is(join('|', map { $rec->{$_} // '?' } qw(title artist album duration cover icon)), 'New Title|New Artist, Second|New Album|215|big.jpg|big.jpg',
        '79-27 D-20: on success title, artist, album, duration, cover and icon of the existing spoton_meta_ record are rewritten');
    is(join('|', map { $rec->{$_} // '?' } qw(type bitrate year artistId albumId)), 'Spotify Browse|320k|1999|ART1|ALB1',
        '79-27 D-20: type, bitrate and the id fields of the record stay');
    my ($set) = grep { $_->[0] eq $key } @Slim::Utils::Cache::SET_LOG;
    is($set ? $set->[2] : '?', 604800, '79-27 D-20: the record is rewritten with the 7-day TTL');
}
# --- no record -> no write; an error is dropped
{
    reset_t69();
    my $id = b22(12);
    newsong("spoton://track:$id");
    my @c = calls();
    @Slim::Utils::Cache::SET_LOG = ();
    $c[0]{cb}->({ id => $id, name => 'N', duration_ms => 1000, artists => [], album => { name => 'A', images => [] } }) if @c;
    is(scalar(@Slim::Utils::Cache::SET_LOG), 0, '79-27 D-20: no spoton_meta_ record -> no write');
    reset_t69();
    my $id2 = b22(13);
    my $key2 = 'spoton_meta_' . md5_hex("spoton://track:$id2");
    $cache->set($key2, { title => 'Keep' }, 604800);
    newsong("spoton://track:$id2");
    @c = calls();
    @Slim::Utils::Cache::SET_LOG = ();
    my $died = !eval { $c[0]{cb}->(undef, { error => 'rate_limited', code => 429 }) if @c; 1 };
    is(($died ? 'DIED' : 'ok') . '/' . scalar(@Slim::Utils::Cache::SET_LOG) . '/' . ($cache->get($key2)->{title} // '?'), 'ok/0/Keep',
        '79-27 D-20: an error from getTrack is dropped (no write, no die, the old record stays)');
}
# --- debounce: a second newsong for the same id within 60 s fetches nothing; another id fetches
{
    reset_t69();
    my ($a, $b) = (b22(21), b22(22));
    newsong("spoton://track:$a");
    newsong("spoton://track:$a");
    is(scalar(calls()), 1, '79-27 D-20: a second newsong for the same id within 60 s fetches nothing');
    newsong("spoton://track:$b");
    is(scalar(calls()), 2, '79-27 D-20: another track id fetches');
}
# --- guards: Connect session, connect- url, episode url, no song, other plugin
{
    reset_t69();
    $Plugins::SpotOn::Connect::is_connect = 1;
    newsong('spoton://track:' . b22(31));
    is(scalar(calls()), 0, '79-27 D-20: a Connect session (isSpotifyConnect true) fetches nothing from this hook');
    $Plugins::SpotOn::Connect::is_connect = 0;
    newsong('spoton://connect-1790000000');
    newsong('spoton://episode:' . b22(32));
    newsong('file:///music/a.flac');
    newsong(undef);
    is(scalar(calls()), 0, '79-27 D-20: a spoton://connect- url, an episode url, a foreign url and no song fetch nothing');
}

# --- wiring (source text, comment lines excluded)
sub sub_text {
    my ($file, $name) = @_;
    open(my $fh, '<', $file) or die "$file: $!";
    local $/; my $src = <$fh>; close $fh;
    my ($body) = $src =~ /^sub \Q$name\E \{\n(.*?)^\}\n/ms;
    return join "\n", grep { !/^\s*#/ } split /\n/, ($body // '');
}
{
    my $t = sub_text("$project_dir/Plugins/SpotOn/Connect.pm", '_fetchTrackMetadata');
    like($t, qr/SpClient->getTrack\(\$accountId,\s*\$trackId,\s*sub\s*\{.*\},\s*\{\s*refresh\s*=>\s*1\s*\}\s*\)/s,
        '79-27 D-20: Connect.pm _fetchTrackMetadata passes { refresh => 1 } to getTrack');
    open(my $fh, '<', "$project_dir/Plugins/SpotOn/Plugin.pm") or die; local $/; my $src = <$fh>; close $fh;
    my $init = join "\n", grep { !/^\s*#/ } split /\n/, ($src =~ /^sub initPlugin \{\n(.*?)^\}\n/ms)[0] // '';
    my $shut = join "\n", grep { !/^\s*#/ } split /\n/, ($src =~ /^sub shutdownPlugin \{\n(.*?)^\}\n/ms)[0] // '';
    like($init, qr/subscribe\(\\&_onNewSongRefreshMeta,\s*\[\['playlist'\],\s*\['newsong'\]\]\)/, '79-27 D-20: initPlugin subscribes _onNewSongRefreshMeta to playlist newsong');
    like($shut, qr/unsubscribe\(\\&_onNewSongRefreshMeta\)/, '79-27 D-20: shutdownPlugin unsubscribes _onNewSongRefreshMeta');
}

done_testing();
