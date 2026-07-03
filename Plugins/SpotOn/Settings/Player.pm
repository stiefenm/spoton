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
            $prefs->client($client)->set('streamFormat', $fmt);
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

        if ( Slim::Utils::PluginManager->isEnabled('Slim::Plugin::DontStopTheMusic::Plugin') ) {
            my $dstmPrefs = preferences('plugin.dontstopthemusic');
            if ($enableAutoplay) {
                $dstmPrefs->client($client)->set('provider', 'PLUGIN_SPOTON_RECOMMENDATIONS');
            } else {
                $dstmPrefs->client($client)->set('provider', 0);
            }
        }

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
        # COMPAT-01: no legacy-pref fallback chain (D-05 — streamingMode has no predecessor pref)
        $paramRef->{streamingMode} = $prefs->client($client)->get('streamingMode') || 'global';
        require Plugins::SpotOn::Helper;
        $paramRef->{canAutoplay}     = Plugins::SpotOn::Helper->getCapability('autoplay') ? 1 : 0;
        my $rawAutoplay = $prefs->client($client)->get('enableAutoplay');
        $paramRef->{autoplayEnabled} = $rawAutoplay // 1;
        if ( defined $rawAutoplay && $paramRef->{canAutoplay}
             && Slim::Utils::PluginManager->isEnabled('Slim::Plugin::DontStopTheMusic::Plugin') ) {
            my $dstmPrefs    = preferences('plugin.dontstopthemusic');
            my $dstmProvider = $dstmPrefs->client($client)->get('provider') // '';
            $paramRef->{autoplayEnabled} = ($dstmProvider eq 'PLUGIN_SPOTON_RECOMMENDATIONS') ? 1 : 0;
        }
    }

    return $class->SUPER::handler($client, $paramRef, $callback, $httpClient, $response);
}

1;
