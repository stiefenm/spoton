package Plugins::SpotOn::Soloist::AccountLog;

# Plugins::SpotOn::Soloist::AccountLog -- which Spotify account a Soloist daemon is
# signed in as (90.1-02, D-01/D-02/D-04).
#
# No WebSocket frame carries the account id (auth_state: device_name, is_active,
# logged_in, type). The per-player daemon log does:
#
#     2026-11-20 12:07:18.718: logged in as <id>        (current build)
#     11:08:38.854 I [f:415 ] logged in as <id>\e[0m    (older build)
#     2026-11-20 12:07:18.457: logged out
#
# SpotOn never reads or writes the daemon's data dir for this (D-04): the log is the
# only source. A same-account transfer writes no new login line, so the reader
# remembers the LAST login of the daemon run it follows ($state->{last}); the caller
# (Control::_refreshAccount) decides when that memory may be shown.
#
# Privacy (T-90.1-03, D-06 groundwork): the raw id is dropped right after parsing.
# An event and the reader state carry only { key => 8 hex (AccountMigration->accountIdFor),
# short => the last 4 characters }. A renderer puts the "..." in front of short; the
# state carries only the 4 characters. An id of 8 characters or fewer would show most
# of itself in 4, so its short is empty.
#
# Cost bound (T-90.1-05): at most READ_MAX bytes per advance() call; the caller calls
# it at most a few rounds. A file that shrank under us (the daemon's runtime log cap)
# restarts the read at 0.
#
# Reader state: { file, start, pos, partial, last }.

use strict;
use warnings;

use constant READ_MAX => 262144;    # 256 KiB per advance() call
use constant ID_MAX   => 128;       # a longer "id" is not an id
use constant SHORT_N  => 4;

# parseText($class, $state, $text) -> list of { ev => 'in', key, short } / { ev => 'out' }
# $state (a hashref) carries a partial last line and `last` across incremental calls.
sub parseText {
    my ($class, $state, $text) = @_;
    $state ||= {};
    $text = ($state->{partial} // '') . ($text // '');
    $state->{partial} = '';

    my @lines = split /\n/, $text, -1;
    # the last element is an unfinished line (or '' after a final newline)
    $state->{partial} = pop(@lines) // '';

    my @events;
    for my $line (@lines) {
        $line =~ s/\x1b\[[0-9;]*m//g;
        $line =~ s/\r\z//;
        next if $line =~ /\A\[fakepulse/;    # the shim writes into the same file

        if ($line =~ /\blogged in as (\S{1,128})\s*\z/) {
            my $ev = _login($1);
            next unless $ev;
            $state->{last} = { key => $ev->{key}, short => $ev->{short} };
            push @events, $ev;
        }
        elsif ($line =~ /\blogged out\s*\z/) {
            $state->{last} = undef;
            push @events, { ev => 'out' };
        }
    }
    return @events;
}

# _login($id) -> { ev => 'in', key, short } | undef. The id goes out of scope here.
sub _login {
    my ($id) = @_;
    return undef unless defined $id && length $id && length $id <= ID_MAX;
    require Plugins::SpotOn::API::AccountMigration;
    my $key = Plugins::SpotOn::API::AccountMigration->accountIdFor($id);
    return undef unless defined $key && length $key;
    my $short = length($id) > 2 * SHORT_N ? substr($id, -SHORT_N) : '';
    return { ev => 'in', key => $key, short => $short };
}

# advance($class, $state) -> bytes read (0: nothing new, or no readable file)
# Reads what was appended to $state->{file} since $state->{pos} (initially
# $state->{start}), at most READ_MAX bytes, and feeds it to parseText.
sub advance {
    my ($class, $state) = @_;
    return 0 unless $state && defined $state->{file};

    my $size = -s $state->{file};
    return 0 unless defined $size;

    $state->{pos} = $state->{start} // 0 unless defined $state->{pos};
    if ($size < $state->{pos}) {
        # truncated under us (log cap) or the start offset lies past the end: start over
        $state->{pos}     = 0;
        $state->{partial} = '';
    }
    return 0 if $size <= $state->{pos};

    my $want = $size - $state->{pos};
    $want = READ_MAX if $want > READ_MAX;

    open(my $fh, '<:raw', $state->{file}) or return 0;
    seek($fh, $state->{pos}, 0) or do { close $fh; return 0 };
    my $buf = '';
    my $n = read($fh, $buf, $want);
    close $fh;
    return 0 unless $n;

    $state->{pos} += $n;
    $class->parseText($state, $buf);
    return $n;
}

1;
