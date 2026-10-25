package Plugins::SpotOn::Settings::Player;

use strict;
use warnings;
use base qw(Slim::Web::Settings);

use Slim::Utils::Log;
use Slim::Utils::Prefs;
use Slim::Utils::Strings qw(string);

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
        # 84-21 (D-31 (2)): the three checkbox prefs are written ONLY when their
        # `has_<name>` presence marker is posted. A browser omits an unchecked
        # checkbox, so "pref_ absent" cannot tell "unchecked" from "this form
        # does not carry the field" -- a partial POST (one field) used to flip
        # all three. The markers are hidden inputs rendered next to each
        # checkbox, inside the same template condition (no marker for a
        # disabled discovery box or an absent autoplay box). The names carry no
        # `pref_` prefix: LMS' Settings.pm only reads `pref_<name>` for the
        # names prefs() lists, and this page lists none.
        if (defined $paramRef->{'has_enableSpotifyConnect'}) {
            my $enableConnect = $paramRef->{'pref_enableSpotifyConnect'} ? 1 : 0;
            $prefs->client($client)->set('enableSpotifyConnect', $enableConnect);
        }

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

        # 83.3 D-12/D-13: per-player Spotify streaming-quality override, same
        # 'global' sentinel idiom as streamingMode. Change-detect + async
        # apply only (never blocking the handler, RESEARCH Pitfall 4) --
        # switching back to 'global' re-applies the global level.
        # 84-13 (SEAM-6.2, D-17 second half): validated against and written
        # through this player's backend role (qualityInfo / quality(scope =>
        # 'player')), like the global save in Settings.pm; a backend without
        # the Spotify quality control (librespot) answers supported => 0
        # and nothing is stored or sent.
        if (defined $paramRef->{'pref_soloistQuality'}) {
            require Plugins::SpotOn::Unified::DaemonManager;
            my $role = Plugins::SpotOn::Unified::DaemonManager->backendFor($client);
            my $qi   = $role ? $role->qualityInfo : undef;
            if ($qi && $qi->{supported}) {
                my %valid = map { $_ => 1 } ('global', @{ $qi->{validLevels} || [] });
                my $v = $paramRef->{'pref_soloistQuality'} // '';
                $v = 'global' unless $valid{$v};
                my $stored = $prefs->client($client)->get('soloistQuality') || 'global';
                if ($v ne $stored) {
                    $prefs->client($client)->set('soloistQuality', $v);
                    # client passed explicitly: backendFor resolves a sync
                    # slave to its master's role, the write is THIS player's.
                    $role->quality(scope => 'player', client => $client, level => $v);
                }
            }
        }

        if (defined $paramRef->{'pref_bitrateOverride'}) {
            my $override = $paramRef->{'pref_bitrateOverride'} // '';
            $override = '' unless $override =~ /^(?:96|160|320)$/;
            $prefs->client($client)->set('bitrateOverride', $override);
        }

        if (defined $paramRef->{'has_enableDiscovery'}) {
            my $disableDiscovery = $paramRef->{'pref_enableDiscovery'} ? 0 : 1;
            $prefs->client($client)->set('disableDiscovery', $disableDiscovery);
        }

        if (defined $paramRef->{'has_enableAutoplay'}) {
            my $enableAutoplay = $paramRef->{'pref_enableAutoplay'} ? 1 : 0;
            $prefs->client($client)->set('enableAutoplay', $enableAutoplay);
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

        # 83.3 D-12/D-13/D-15: per-player Spotify streaming-quality override.
        # 84-13 (SEAM-6.2): the whole block comes from this player's backend
        # role -- qualityInfo($client) answers supported => 0 for a backend
        # without it (librespot: no section, matches the template's
        # backend-conditional block); labels and the notice text arrive
        # already rendered.
        require Plugins::SpotOn::Unified::DaemonManager;
        my $role = Plugins::SpotOn::Unified::DaemonManager->backendFor($client);
        my $q    = $role ? $role->qualityInfo($client) : undef;
        if ($q && $q->{supported}) {
            $paramRef->{soloistQuality}               = $q->{stored};
            $paramRef->{soloistQualityLevels}         = $q->{levels};
            # Bare label -- template applies SET_IN_APP via the TT `string`
            # filter's dynamic-arg form (see Settings.pm's matching comment).
            $paramRef->{soloistQualityStoredLabel}    = $q->{storedLabel};
            $paramRef->{soloistQualityAvailable}      = $q->{deviceKnown};
            $paramRef->{soloistQualityEffective}      = $q->{effective};
            $paramRef->{soloistQualityEffectiveLabel} = $q->{effectiveLabel};
            $paramRef->{soloistQualityDiffers}        = $q->{differs};
            $paramRef->{soloistQualityNotice}         = $q->{noticeText};
        }

        # 74b-02 (D-08): what this player really receives. The whole line comes
        # from DaemonManager->effectiveOutput (the same mapping playback uses,
        # 74b-01); the template never computes it. A failing resolver read must
        # not take the page down, so the block is eval-guarded and simply
        # leaves the three params unset.
        eval {
            my $eo = Plugins::SpotOn::Unified::DaemonManager->effectiveOutput($client);
            if (ref $eo eq 'HASH' && $eo->{effective}) {
                my $label = sub { return string('PLUGIN_SPOTON_STREAM_FORMAT_' . uc($_[0])) };
                my $effLabel = $label->($eo->{effective});
                my $path     = $eo->{path} || '';
                my $via      = $path eq 'direct' ? string('PLUGIN_SPOTON_STREAM_FORMAT_VIA_DIRECT')
                             : $path eq 'proxy'  ? string('PLUGIN_SPOTON_STREAM_FORMAT_VIA_PROXY')
                             :                     '';
                my $line = sprintf(string('PLUGIN_SPOTON_STREAM_FORMAT_LINE'),
                                   $label->($paramRef->{streamFormat}), $effLabel, $via);
                $line =~ s/\s+$//;
                $paramRef->{streamFormatEffective} = $line;

                my $reason = $eo->{reason} || '';
                # D-15: explicit FLAC without a FLAC player (not an error);
                # D-10: MP3 stays selectable, lame is missing, no fallback.
                if ($reason eq 'flac_no_flc') {
                    $paramRef->{streamFormatReason} = string('PLUGIN_SPOTON_STREAM_FORMAT_REASON_NO_FLC');
                }
                elsif ($reason eq 'no_lame') {
                    $paramRef->{streamFormatReason} = string('PLUGIN_SPOTON_STREAM_FORMAT_REASON_NO_LAME');
                }
                elsif ($reason eq 'rule_unavailable') {
                    $paramRef->{streamFormatReason} = sprintf(string('PLUGIN_SPOTON_STREAM_FORMAT_REASON_RULE'), $effLabel);
                }

                # D-11/D-18: the lossy-MP3 note only when the effective format is
                # MP3 and the Spotify quality is EXPLICITLY Lossless (5) or Very
                # high (4) - `wanted` is the level SpotOn writes, role-provided.
                if ($eo->{effective} eq 'mp3' && $q && $q->{supported}
                    && defined $q->{wanted} && ($q->{wanted} == 4 || $q->{wanted} == 5)) {
                    $paramRef->{streamFormatNote} = string('PLUGIN_SPOTON_STREAM_FORMAT_MP3_NOTE');
                }
            }
            1;
        } or $log->debug("effective-format line unavailable: " . ($@ || 'unknown'));

        # 84-13: the Autoplay checkbox follows the backend's capability (a
        # failing capability read must not take the page down).
        my $caps = $role ? (eval { $role->capabilities } || {}) : {};
        $paramRef->{canAutoplay}     = $caps->{autoplay} ? 1 : 0;
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
