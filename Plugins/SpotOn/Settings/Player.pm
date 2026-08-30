package Plugins::SpotOn::Settings::Player;

use strict;
use warnings;
use base qw(Slim::Web::Settings);

use Slim::Utils::Log;
use Slim::Utils::Prefs;

use constant SETTINGS_URL => 'plugins/SpotOn/settings/player.html';

my $log   = Slim::Utils::Log->logger('plugin.spoton');
my $prefs = preferences('plugin.spoton');

sub name {
    return Slim::Web::HTTP::CSRF->protectName('PLUGIN_SPOTON_PLAYER_SETTINGS_NAME');
}

sub needsClient {
    return 1;
}

sub page {
    return Slim::Web::HTTP::CSRF->protectURI(SETTINGS_URL);
}

sub prefs {
    return ($prefs);
}

sub handler {
    my ($class, $client, $paramRef, $callback, $httpClient, $response) = @_;

    if ($paramRef->{saveSettings} && $client) {
        my $enableConnect = $paramRef->{'pref_enableSpotifyConnect'} ? 1 : 0;
        $prefs->client($client)->set('enableSpotifyConnect', $enableConnect);

        if (defined $paramRef->{'pref_connectOggOverride'}) {
            my $override = $paramRef->{'pref_connectOggOverride'};
            $override = 'auto' unless $override =~ /^(?:auto|ogg|pcm)$/;
            $prefs->client($client)->set('connectOggOverride', $override);
        }

        if (defined $paramRef->{'pref_streamFormat'}) {
            my $fmt = $paramRef->{'pref_streamFormat'};
            $fmt = 'auto' unless $fmt =~ /^(?:auto|ogg|pcm|flac|mp3)$/;

            # WR-05 (Phase 76 review): under soloist a stored 'ogg' choice is
            # display-remapped to Auto (see the render block below), so ANY
            # save of this page posts pref_streamFormat=auto. Persisting that
            # echo would destroy the stored OGG choice the remap promises to
            # preserve for a later switch back to librespot. Only skip the
            # write for exactly this echo case; a user actively selecting a
            # different value (pcm/flac/mp3) still persists normally.
            my $stored = $prefs->client($client)->get('streamFormat')
                      || $prefs->client($client)->get('connectOggOverride')
                      || 'auto';
            my $backend = $prefs->get('backend') || 'librespot';
            unless ($backend eq 'soloist' && $stored eq 'ogg' && $fmt eq 'auto') {
                $prefs->client($client)->set('streamFormat', $fmt);
            }
        }

        if (defined $paramRef->{'pref_streamingMode'}) {
            my $mode = $paramRef->{'pref_streamingMode'};
            $mode = 'global' unless $mode =~ /^(?:global|direct|proxy)$/;
            $prefs->client($client)->set('streamingMode', $mode);
        }

        if (defined $paramRef->{'pref_bitrateOverride'}) {
            my $override = $paramRef->{'pref_bitrateOverride'} // '';
            $override = '' unless $override =~ /^(?:96|160|320)$/;
            $prefs->client($client)->set('bitrateOverride', $override);
        }

        my $disableDiscovery = $paramRef->{'pref_enableDiscovery'} ? 0 : 1;
        $prefs->client($client)->set('disableDiscovery', $disableDiscovery);

        my $enableAutoplay = $paramRef->{'pref_enableAutoplay'} ? 1 : 0;
        $prefs->client($client)->set('enableAutoplay', $enableAutoplay);

        require Plugins::SpotOn::Unified::DaemonManager;
        Plugins::SpotOn::Unified::DaemonManager->scheduleInit();
    }

    if ($client) {
        $paramRef->{connectEnabled}     = $prefs->client($client)->get('enableSpotifyConnect') // 1;
        $paramRef->{connectOggOverride} = $prefs->client($client)->get('connectOggOverride') || 'auto';
        $paramRef->{discoveryEnabled}     = $prefs->client($client)->get('disableDiscovery') ? 0 : 1;
        $paramRef->{discoveryByCrashLoop} = $prefs->client($client)->get('discoveryDisabledByCrashLoop') || 0;
        $paramRef->{bitrateOverride} = $prefs->client($client)->get('bitrateOverride') || '';
        $paramRef->{streamFormat} = $prefs->client($client)->get('streamFormat')
                                 || $prefs->client($client)->get('connectOggOverride')
                                 || 'auto';

        # D-07: OGG passthrough is librespot-exclusive -- the template hides
        # the OGG option when the global backend is soloist (server-rendered
        # TT conditional; player.html has no live backend toggle).
        $paramRef->{backend} = $prefs->get('backend') || 'librespot';

        # D-07 stored-pref edge: with backend=soloist a stored 'ogg' value is
        # resolved as 'auto' at runtime (76-04 resolveSoloistFormat maps
        # ogg->auto), so the page shows Auto as selected. Display-only -- the
        # stored pref is deliberately NOT rewritten here, so switching back
        # to librespot restores the user's OGG choice. The save handler above
        # guards the matching echo (WR-05): a posted 'auto' while the stored
        # value is 'ogg' under soloist is NOT persisted, otherwise any save of
        # this page would silently destroy the preserved OGG choice.
        if ($paramRef->{backend} eq 'soloist' && $paramRef->{streamFormat} eq 'ogg') {
            $paramRef->{streamFormat} = 'auto';
        }
        # COMPAT-01: no legacy-pref fallback chain (D-05 — streamingMode has no predecessor pref)
        $paramRef->{streamingMode} = $prefs->client($client)->get('streamingMode') || 'global';
        require Plugins::SpotOn::Helper;
        $paramRef->{canAutoplay}     = Plugins::SpotOn::Helper->getCapability('autoplay') ? 1 : 0;
        my $rawAutoplay = $prefs->client($client)->get('enableAutoplay');
        $paramRef->{autoplayEnabled} = $rawAutoplay // 1;

        my $dstmAvailable = Slim::Utils::PluginManager->isEnabled('Slim::Plugin::DontStopTheMusic::Plugin');
        $paramRef->{dstmAvailable} = $dstmAvailable ? 1 : 0;
        if ( $dstmAvailable ) {
            my $dstmPrefs    = preferences('plugin.dontstopthemusic');
            my $dstmProvider = $dstmPrefs->client($client)->get('provider') // '';
            $paramRef->{dstmIsSpotOn}  = ($dstmProvider eq 'PLUGIN_SPOTON_RECOMMENDATIONS') ? 1 : 0;
        } else {
            $paramRef->{dstmIsSpotOn}  = 0;
        }
    }

    return $class->SUPER::handler($client, $paramRef, $callback, $httpClient, $response);
}

1;
