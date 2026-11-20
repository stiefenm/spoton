package Plugins::SpotOn::PlayerMessage;

# Plugins::SpotOn::PlayerMessage -- tell the user of one player something (89-12,
# gap of the 89-05 eye check: the refused-key stop message reached no web UI).
#
# show() keeps the player channel as it was: $client->showBriefly with the Jive
# popup (SqueezePlay devices: Touch, Radio, Controller) and, when the caller asks
# for it, the display lines (Squeezebox 2/3, Boom, Transporter). LMS hands those
# display lines to its Default web interface too, but only for a player that has
# a display: for every other player (squeezelite, the SqueezePlay family, the
# Receiver) Slim::Display::NoDisplay keeps no copy, so the Default skin has
# nothing to show there.
#
# In addition show() sends Material Skin's notification when the Material plugin
# is enabled. Material dropped showBriefly in 2.10.2; a plugin's text reaches it
# only as `material-skin notification <type> <msg> <title> <player id> <seconds>`
# and is shown only in a browser whose selected player is that id.
#
# Material shows the text of an `error` notification properly from 6.5.0 on. Up
# to 6.4.14 (the last release, 2026-10-16) the text lands in the wrong argument
# of Material's error handler: 6.4.9 to 6.4.14 show "Something went wrong!" or
# the bare timeout and never the text, 5.11.0 shows it in brackets behind
# "Something went wrong!". Fixed upstream on 2026-11-05 (lms-material commit
# 55dfdc4e, #1299); the ChangeLog head of master reads 6.5.0. So a message asked
# for as `error` goes out as `error` only to a Material that shows its text;
# every other version gets the same text as `info`.
#
# Never dies. No require of an LMS module: PluginManager and Request are loaded
# in every running LMS, and a test that defines neither sees no notification.

use strict;
use warnings;

use Slim::Utils::Log;

use constant MATERIAL_PLUGIN      => 'Plugins::MaterialSkin::Plugin';
use constant MATERIAL_ERROR_SINCE => '6.5.0';
use constant MATERIAL_TIMEOUT_S   => 15;    # Material honours 1 to 30 s, anything else falls back to its 2.5 s

my $log = logger('plugin.spoton');

# show($client, \@text, \%opts) -> undef | error text of the display call
#   type     => 'info' | 'error'   how Material shows it (see above); default info
#   line     => 1                  also put the text on the player's display lines
#   duration => <seconds>          handed to showBriefly as it is; absent = LMS default
# The Material notification goes out whether or not the display call worked.
sub show {
    my ($client, $text, $opts) = @_;
    $opts = {} unless ref $opts eq 'HASH';

    my @text = grep { defined $_ && length $_ } (ref $text eq 'ARRAY' ? @$text : ($text));
    return unless $client && @text;

    my $err;
    eval {
        my $parts = { jive => { type => 'popupplay', text => [@text] } };
        $parts->{line} = [@text] if $opts->{line};
        $client->showBriefly($parts, defined $opts->{duration} ? { duration => $opts->{duration} } : ());
        1;
    } or $err = "$@" || 'unknown error';

    _notifyMaterial($client, \@text, $opts->{type});

    return $err;
}

# _notifyMaterial($client, \@text, $type)
# One line for Material: the text parts joined with ' - '.
sub _notifyMaterial {
    my ($client, $text, $asked) = @_;

    eval {
        my $pm = 'Slim::Utils::PluginManager';
        return 1 unless $pm->can('isEnabled') && defined &Slim::Control::Request::notifyFromArray;

        my $data = $pm->isEnabled(MATERIAL_PLUGIN) or return 1;
        my $version = ref $data eq 'HASH' ? $data->{version} : undef;

        my $type = (defined $asked && $asked eq 'error' && _atLeast($version, MATERIAL_ERROR_SINCE))
            ? 'error' : 'info';

        Slim::Control::Request::notifyFromArray(undef, [
            'material-skin', 'notification', $type, join(' - ', @$text), undef, $client->id, MATERIAL_TIMEOUT_S,
        ]);
        1;
    } or $log->warn('SpotOn: Material notification failed: ' . ($@ || 'unknown error'));

    return;
}

# _atLeast($version, $min) -> 1 | 0
# Dotted decimal only ('6.4.9'). Anything else (undef, 'DEVELOPMENT', a git
# build) is 0: nothing says that such a Material shows an error's text.
sub _atLeast {
    my ($version, $min) = @_;
    return 0 unless defined $version && $version =~ /\A[0-9]+(?:\.[0-9]+)*\z/;

    my @have = split /\./, $version;
    my @want = split /\./, $min;
    while (@have || @want) {
        my $h = shift @have;
        my $w = shift @want;
        $h = 0 unless defined $h;
        $w = 0 unless defined $w;
        return 1 if $h > $w;
        return 0 if $h < $w;
    }
    return 1;
}

1;
