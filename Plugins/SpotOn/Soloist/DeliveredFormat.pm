package Plugins::SpotOn::Soloist::DeliveredFormat;

# Plugins::SpotOn::Soloist::DeliveredFormat -- what Spotify really delivered for
# the playing track under Soloist (79-60, forum #333 and the beta.3 format label).
#
# Source: the per-player daemon log (<cachedir>/spoton/<mac without colons>-soloist.log).
# For every track player the daemon opens, it logs
#
#     ...]     Creating track player for track (playback_id <hex>)
#     ...]         track_uri: spotify:track:<id>
#     ...
#     ...] Opening sink for playback.
#     ...]     codec: flac|vorbis
#     ...]     bitrate: <n> bits/s
#
# Binding rule (79-60 Task 1, measured on 897 real sink blocks of three daemon
# logs): a sink belongs to the NEAREST PRECEDING `track_uri:` line. The nearest
# preceding `playing|paused spotify:track:` ticker line is the wrong rule (491 of
# 897): a prefetched next track opens its sink while the ticker still names the
# current one. A sink with no track_uri line before it in the read slice yields
# nothing, and so does a sink whose next lines are not exactly codec then bitrate:
# a parse miss never produces a value, the caller falls back to the visibly marked
# setting.
#
# Cost bound (T-79-251): one read window per player and track, starting BACK_OFF
# bytes before the log size at the song start (the daemon can open the sink before
# LMS starts the song: Connect, prefetch) and never reading more than READ_MAX bytes
# in total; reads are incremental (only bytes appended since the last call). At
# most MEMO_MAX windows are kept. Menu items never come here.
#
# No Slim::* at load beyond the logger: the server prefs are required at run time.

use strict;
use warnings;

use File::Spec::Functions qw(catfile);
use Slim::Utils::Log;

use constant READ_MAX => 256 * 1024;
use constant BACK_OFF => 64 * 1024;
use constant MEMO_MAX => 50;

my $log = logger('plugin.spoton');

my %CODEC_OK = map { $_ => 1 } qw(flac vorbis mp3);

my %_entry;        # "mac|uri" -> { mac, uri, file, start, pos, state, rec }
my @_entryOrder;   # keys, oldest first
my %_lastNoted;    # mac -> uri of the last noteSongStart

# _macOf($clientOrMac) -> mac string of the player (a client resolves to its sync master)
sub _macOf {
    my ($clientOrMac) = @_;
    return undef unless defined $clientOrMac;
    if (ref $clientOrMac) {
        my $client = $clientOrMac;
        $client = $client->master if $client->can('master') && $client->master;
        return $client->id;
    }
    return $clientOrMac;
}

# logPathFor($class, $mac) -> the daemon log path SoloistDaemon writes
# (SoloistDaemon.pm: catfile(cachedir, 'spoton', $self->id . '-soloist.log'), id = mac without colons)
sub logPathFor {
    my ($class, $mac) = @_;
    return undef unless defined $mac && length $mac;
    (my $id = $mac) =~ s/://g;
    require Slim::Utils::Prefs;
    my $cachedir = Slim::Utils::Prefs::preferences('server')->get('cachedir');
    return undef unless defined $cachedir && length $cachedir;
    return catfile($cachedir, 'spoton', $id . '-soloist.log');
}

# parseLog($class, $text [, $state]) -> list of { uri, codec, bitrate }
# $state (a hashref) carries a partial last line and the parser position across
# incremental calls; without it $text is parsed as one complete piece.
sub parseLog {
    my ($class, $text, $state) = @_;
    my $oneShot = !$state;
    $state ||= {};
    $text = ($state->{partial} // '') . ($text // '');
    $state->{partial} = '';

    my @lines = split /\n/, $text, -1;
    # the last element is an unfinished line (or '' after a final newline)
    my $tail = pop @lines;
    if ($oneShot) { push @lines, $tail if defined $tail && length $tail; }
    else          { $state->{partial} = $tail // ''; }

    my @records;
    for my $line (@lines) {
        $line =~ s/\x1b\[[0-9;]*m//g;
        $line =~ s/\r\z//;
        next if $line =~ /\A\[fakepulse/;    # the shim writes into the same file; never part of a block

        my $expect = $state->{expect} // '';
        if ($expect eq 'codec') {
            if ($line =~ /\]\s+codec: (\w+)\s*\z/ && $CODEC_OK{$1}) {
                $state->{codec}  = $1;
                $state->{expect} = 'bitrate';
                next;
            }
            delete @{$state}{qw(expect codec sinkUri)};    # shape miss: no record
        }
        elsif ($expect eq 'bitrate') {
            if ($line =~ /\]\s+bitrate: (\d+) bits\/s\s*\z/) {
                push @records, { uri => $state->{sinkUri}, codec => $state->{codec}, bitrate => $1 + 0 }
                    if defined $state->{sinkUri};
            }
            delete @{$state}{qw(expect codec sinkUri)};
            next;
        }

        if ($line =~ /\]\s+track_uri: (spotify:(?:track|episode):[A-Za-z0-9]+)\s*\z/) {
            $state->{uri} = $1;
        }
        elsif ($line =~ /\] Opening sink for playback\.\s*\z/) {
            $state->{expect}  = 'codec';
            $state->{sinkUri} = $state->{uri};    # undef when no track_uri line came first: no record
        }
    }
    return @records;
}

# noteSongStart($class, $clientOrMac, $uri) -- a new song starts on this player:
# open a fresh read window for it. A repeated call for the same uri (seek,
# rewind, reconnect: onStream fires for each) keeps the window and its record.
sub noteSongStart {
    my ($class, $clientOrMac, $uri) = @_;
    my $mac = _macOf($clientOrMac);
    return unless defined $mac && defined $uri && $uri =~ /\Aspotify:(?:track|episode):[A-Za-z0-9]+\z/;
    return if defined $_lastNoted{$mac} && $_lastNoted{$mac} eq $uri;
    $_lastNoted{$mac} = $uri;
    $class->_openWindow($mac, $uri);
    return;
}

sub _openWindow {
    my ($class, $mac, $uri) = @_;
    my $file = $class->logPathFor($mac);
    return undef unless defined $file;
    my $size  = -s $file;
    $size     = 0 unless defined $size;
    my $start = $size > BACK_OFF ? $size - BACK_OFF : 0;
    my $key   = "$mac|$uri";

    @_entryOrder = grep { $_ ne $key } @_entryOrder;
    push @_entryOrder, $key;
    $_entry{$key} = { mac => $mac, uri => $uri, file => $file, start => $start, pos => $start, state => {}, rec => undef };
    while (@_entryOrder > MEMO_MAX) {
        my $old = shift @_entryOrder;
        delete $_entry{$old};
    }
    return $_entry{$key};
}

# deliveredFor($class, $clientOrMac, $uri) -> { codec, bitrate } | undef
# The last sink record of this track inside its read window; undef when none
# (cached track, shape miss, window exhausted before the sink was logged).
sub deliveredFor {
    my ($class, $clientOrMac, $uri) = @_;
    my $mac = _macOf($clientOrMac);
    return undef unless defined $mac && defined $uri && length $uri;

    my $e = $_entry{"$mac|$uri"} || $class->_openWindow($mac, $uri) or return undef;
    $class->_advance($e);
    return $e->{rec} ? { %{ $e->{rec} } } : undef;
}

sub _advance {
    my ($class, $e) = @_;
    my $size = -s $e->{file};
    return unless defined $size;

    if ($size < $e->{pos}) {
        # truncated or rotated under us: restart the bounded window near the new end
        $e->{start} = $size > BACK_OFF ? $size - BACK_OFF : 0;
        $e->{pos}   = $e->{start};
        $e->{state} = {};
    }

    my $limit = $e->{start} + READ_MAX;
    my $to    = $size < $limit ? $size : $limit;
    return if $to <= $e->{pos};

    open(my $fh, '<:raw', $e->{file}) or return;
    seek($fh, $e->{pos}, 0) or do { close $fh; return };
    my $buf = '';
    my $n = read($fh, $buf, $to - $e->{pos});
    close $fh;
    return unless $n;
    $e->{pos} += $n;

    for my $r ($class->parseLog($buf, $e->{state})) {
        next unless $r->{uri} eq $e->{uri};
        $e->{rec} = { codec => $r->{codec}, bitrate => $r->{bitrate} };
    }
    main::DEBUGLOG && $log->is_debug && $log->debug(
        "DeliveredFormat: $e->{uri} read to $e->{pos} -> " . ($e->{rec} ? "$e->{rec}{codec} $e->{rec}{bitrate}" : 'none')
    );
    return;
}

# _windowCount() / _hasWindow($mac, $uri) -- tests only.
sub _windowCount { return scalar @_entryOrder }
sub _hasWindow   { my ($class, $mac, $uri) = @_; return exists $_entry{"$mac|$uri"} ? 1 : 0 }

# _reset() -- tests only: forget every window.
sub _reset {
    %_entry = ();
    @_entryOrder = ();
    %_lastNoted = ();
    return;
}

1;
