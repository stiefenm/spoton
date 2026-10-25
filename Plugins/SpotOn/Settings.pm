package Plugins::SpotOn::Settings;

use strict;
use warnings;
use base qw(Slim::Web::Settings);

use Digest::MD5 qw(md5_hex);
use Encode qw(encode);
use File::Basename qw(basename);
use File::Glob qw(bsd_glob);
use File::Spec::Functions qw(catdir catfile);
use JSON::XS::VersionOneAndTwo;

use Slim::Utils::Log;
use Slim::Utils::Prefs;
use Slim::Utils::Strings qw(string);
# 84-08 (SEAM-6.2, G3): no compile-time `use` of a backend or helper module
# -- the librespot binary status comes from its role's settingsInfo (below),
# backend modules are loaded only through the registry.

use constant SETTINGS_URL => 'plugins/SpotOn/settings/basic.html';

# T-71-02/D-11: the Soloist key store exposes no read-back API for the stored
# spak-key (by design -- the role's keyState/storeKey/clearKey only, 84-13),
# so the template can only ever show this fixed placeholder when a key is
# present (no partial preview of the stored value). Shared between the
# template-value assignment and the save-handler's unchanged-resubmit guard
# below -- an unrelated settings save must never overwrite/clear an existing
# key just because this field round-tripped its own masked placeholder.
use constant SOLOIST_KEY_MASKED_PREVIEW => '********';

my $log   = Slim::Utils::Log->logger('plugin.spoton');
my $prefs = preferences('plugin.spoton');

sub new {
    my $class = shift;
    my $self  = $class->SUPER::new(@_);

    require Slim::Web::Pages;

    # Register diagnostic bundle download endpoint (#3)
    Slim::Web::Pages->addRawFunction(
        'plugins/SpotOn/settings/diagnosticBundle',
        \&_diagnosticBundleHandler
    );

    # Register clear logs endpoint (GT-07)
    Slim::Web::Pages->addRawFunction(
        'plugins/SpotOn/settings/clearLogs',
        \&_clearLogsHandler
    );

    # 85-13 (D-01): the three PKCE routes and the raw
    # route `login` are gone. `login` was registered as an UNANCHORED regex
    # key (Tie::RegexpHash, RESEARCH P10) and so matched any path containing
    # "login"; it existed only for the PKCE loopback redirect. Accounts now
    # come from ZeroConf pairing (85-10) -- there is no emergency path.

    # Register ZeroConf playback-authorization pairing endpoints
    # (GH #147 plan 65-02, D-02 primary path)
    Slim::Web::Pages->addRawFunction(
        'plugins/SpotOn/settings/playerauth/start',
        \&_playerAuthStartHandler
    );
    Slim::Web::Pages->addRawFunction(
        'plugins/SpotOn/settings/playerauth/status',
        \&_playerAuthStatusHandler
    );
    Slim::Web::Pages->addRawFunction(
        'plugins/SpotOn/settings/playerauth/cancel',
        \&_playerAuthCancelHandler
    );

    # 85-13 (D-01, assumption A11): the Keymaster browser fallback
    # (the two former browser routes) was a PKCE flow and is removed with it;
    # the mDNS-free substitute is the discover folder (85-11, D-23).

    # Backend routes (Phase 83.3 plan 03, D-04: the Soloist "Renew now"
    # button's manual trigger + status poll; 84-13 SEAM-6.2: owned by the
    # backend role). Every AVAILABLE backend's routes() are registered,
    # whatever the `backend` pref says -- a switch without LMS restart must
    # still find its routes (W7). Each entry gets its own generic wrapper:
    # _csrfCheck runs for every entry whose method is not 'GET' (fail-
    # closed: an unlabeled or misspelled method is still checked), then
    # _jsonResponse answers with the role's plain data -- the role never
    # sees the HTTP objects (B6).
    #
    # Registration ORDER matters here (Phase 83.3 plan 06 live-check fix,
    # Rule 1 -- bug): Slim::Web::Pages->addRawFunction stores its regexp key
    # in a Tie::RegexpHash (Slim/Web/Pages.pm %rawFunctions), which resolves
    # BOTH inserts and lookups via UNANCHORED substring regex matching
    # (Tie/RegexpHash.pm _find: "$key !~ m/$storedRegex/"), not literal
    # string equality. 'soloistRenewStatus' contains 'soloistRenew' as a
    # prefix, so registering the shorter path FIRST meant the second
    # addRawFunction call for 'soloistRenewStatus' matched the ALREADY-
    # stored 'soloistRenew' regex at add() time and silently OVERWROTE its
    # handler -- both routes then dispatched to the status handler,
    # discovered live against the real server. The role's routes() list
    # therefore carries the LONGER, more specific path first, and the
    # entries are registered in list order.
    require Plugins::SpotOn::Backend;
    for my $name (Plugins::SpotOn::Backend::available()) {
        my $role = Plugins::SpotOn::Backend::classFor($name);
        for my $entry (@{ $role->routes() || [] }) {
            my $route = $entry;
            Slim::Web::Pages->addRawFunction($route->{path}, sub {
                my ($httpClient, $response) = @_;
                if (($route->{method} // '') ne 'GET') {
                    return unless _csrfCheck($httpClient, $response);
                }
                _jsonResponse($httpClient, $response, $route->{handler}->());
            });
        }
    }

    return $self;
}

sub name {
    return Slim::Web::HTTP::CSRF->protectName('PLUGIN_SPOTON_NAME');
}

sub needsClient {
    return 0;
}

sub page {
    return Slim::Web::HTTP::CSRF->protectURI(SETTINGS_URL);
}

sub prefs {
    # backend is saved manually with sanitization in handler() -- not listed
    # here to prevent Slim::Web::Settings::handler from overwriting with raw
    # form input (backend: whitelist against %valid_backends, D-08/T-71-05).
    # binary is not listed either (74b-04): no form field renders it, so the
    # LMS base handler would store undef on every save and blank a custom
    # binary path (Helper.pm is its only reader). bitrate and normalization
    # stay listed because the template reads them back from prefs.pref_*;
    # handler() writes the sanitized values into pref_bitrate and
    # pref_normalization before the base handler stores them (T-74b-12).
    return ($prefs, 'bitrate', 'normalization', 'diagnosticMode');
}

sub handler {
    my ($class, $client, $paramRef, $callback, $httpClient, $response) = @_;

    # 85-11 (D-23, 3fd1632 layer 2): a credentials.json dropped into the discover
    # folder (Docker/VLAN setups without mDNS) becomes an account on this page
    # load. FIRST statement on purpose: the intake must finish before any other
    # handling, so the accounts read further down already contain the new
    # account and a save in the same request cannot race it. The result only
    # drives the one-line notice under step 1; (0, 'none') is the normal case.
    require Plugins::SpotOn::API::Credentials;
    my ($discoverOk, $discoverResult) = Plugins::SpotOn::API::Credentials->intakeDiscoverFolder();
    $paramRef->{discoverResult} = $discoverOk ? 1 : 0;
    $paramRef->{discoverError}  = (!$discoverOk && ($discoverResult // 'none') ne 'none') ? $discoverResult : '';

    # 84-08: the binary status (helperMissing/binaryVersion/binaryPath) is
    # filled by the backend roles' settingsInfo further down.
    $paramRef->{isMac}         = main::ISMAC ? 1 : 0;

    # 85-13 (D-01): the banner no longer speaks of re-authentication (a PKCE
    # notion). An account the 85-10 migration flagged because it has no usable
    # credentials gets the pairing hint instead. Uses the LMS core
    # $paramRef->{'warning'} idiom, rendered by the settings/header.html template.
    {
        my $accts = $prefs->get('accounts') || {};
        if (grep { ref $accts->{$_} eq 'HASH' && $accts->{$_}{needsPairing} } keys %{$accts}) {
            $paramRef->{'warning'} = string('PLUGIN_SPOTON_ACCOUNT_NEEDS_PAIRING');
        }
    }

    if ($paramRef->{saveSettings}) {
        my %valid_bitrates = map { $_ => 1 } (96, 160, 320);
        # A POST without the bitrate field keeps the stored bitrate (320 only
        # when nothing is stored); a value outside 96/160/320 becomes 320.
        my $bitrate = $paramRef->{'pref_bitrate'} // $prefs->get('bitrate') // 320;
        $bitrate = 320 unless $valid_bitrates{$bitrate};
        $prefs->set('bitrate', $bitrate);

        # Save normalization pref (STR-08, T-04-05)
        # Checkbox: browser sends no value when unchecked — treat undef/empty as 0
        my $norm = $paramRef->{'pref_normalization'} ? 1 : 0;
        $prefs->set('normalization', $norm);

        # 74b-04 (T-74b-12): the LMS base handler runs later and stores
        # pref_NAME for every name in prefs() unconditionally, so hand it the
        # sanitized values; the template reads them back from prefs.pref_*.
        $paramRef->{'pref_bitrate'}       = $bitrate;
        $paramRef->{'pref_normalization'} = $norm;

        # Normalization change flips passthrough mode (OGG↔PCM) — restart daemons
        # immediately so formatOverride() and daemon output stay in sync.
        require Plugins::SpotOn::Unified::DaemonManager;
        Plugins::SpotOn::Unified::DaemonManager->scheduleInit();

        # 79-05 (D-12, T-79-09): the one-click switch from librespot to Soloist.
        # The default backend stays librespot and SpotOn never switches on its
        # own: only a POSTed switchBackendSoloist (the button of the offer)
        # gets here, and the server re-checks everything the offer showed --
        # 'soloist' in available(), the role's platformFit and a stored key --
        # before it hands pref_backend=soloist to the whitelist/bootstrap path
        # right below. Anything else is ignored. The role is reached by its
        # registry name only (the core names no Soloist package, refcheck).
        if (delete $paramRef->{'switchBackendSoloist'}) {
            require Plugins::SpotOn::Backend;
            my $allowed = eval {
                (grep { $_ eq 'soloist' } Plugins::SpotOn::Backend::available())
                    && do {
                        my $role = Plugins::SpotOn::Backend::classFor('soloist');
                        $role->platformFit && $role->keyState->{present} ? 1 : 0;
                    };
            } ? 1 : 0;
            if ($allowed) {
                $paramRef->{'pref_backend'} = 'soloist';
            }
            else {
                main::INFOLOG && $log->is_info && $log->info('Settings: switchBackendSoloist ignored (not available, not fit, or no key stored)');
            }
        }

        # Save backend pref (D-08/Phase 71, T-71-05): whitelist against the
        # known enum before persisting — an unknown/tampered POST value falls
        # back to 'librespot'. NOT part of the base prefs() list (see comment
        # there) so Slim::Web::Settings::handler cannot overwrite this with
        # unsanitized raw form input. A backend switch restarts daemons via
        # the same scheduleInit() pattern used above for normalization.
        if (defined $paramRef->{'pref_backend'}) {
            # 84-13 (B3, T-84-162): the enum is the set of AVAILABLE backends
            # (Backend::available() -- registered AND role module loads), not
            # every registered name: on an amputated install (§6.3.2) an
            # absent backend must never be saved, nor reach classFor (which
            # dies on an unloadable name) through its bootstrap below.
            require Plugins::SpotOn::Backend;
            my %valid_backends = map { $_ => 1 } Plugins::SpotOn::Backend::available();
            my $backend = $paramRef->{'pref_backend'} // '';
            $backend = 'librespot' unless $valid_backends{$backend};
            $prefs->set('backend', $backend);

            # CR-01: trigger the newly selected backend's bootstrap the moment
            # it is activated -- for Soloist the auto-download pipeline (D-03;
            # ensureBinary() is a no-op when a working, version-matched
            # binary is already cached, D-04). Without this call the backend
            # could never leave the soloist_missing_binary state (startHelper()
            # only ever reads the prerequisite state, it never triggers a
            # download). 84-08: through the role of the VALIDATED name;
            # 84-13: only for a name in available().
            Plugins::SpotOn::Backend::classFor($backend)->bootstrap()
                if $valid_backends{$backend};

            Plugins::SpotOn::Unified::DaemonManager->scheduleInit();
        }

        # Save spak-key for the Soloist backend (D-11, T-71-06). Fail-closed
        # format validation before the role's storeKey persists it: trim
        # whitespace, restrict to a conservative token charset (also strips
        # newlines and shell metacharacters), cap length. Deliberately NOT
        # part of the base prefs() list (a raw secret is never a flat pref) —
        # the raw key must never round-trip into $paramRef/the rendered
        # template (T-71-02); only the fixed masked placeholder or an empty
        # field is ever shown. The "unchanged" comparison MUST happen against
        # the raw (whitespace-trimmed only) submitted value BEFORE charset
        # sanitization strips the placeholder's asterisks — otherwise every
        # unrelated settings save would resubmit the placeholder, have it
        # charset-filtered down to empty, and incorrectly clear the real
        # stored key.
        # Empty submission clears an existing key (WR-03 pattern).
        # 84-13 (SEAM-6.2): the key store is a role capability of the ACTIVE
        # backend (keyState/storeKey/clearKey through backendClass()); a
        # backend without one (librespot: supported 0) skips the block and
        # loads no backend module of the other side.
        #
        # 79-05 (D-12, T-79-71): the hint under librespot has its own key input.
        # It is read into a local exactly once and removed from $paramRef right
        # away (the page re-renders from $paramRef; a left-over would echo the
        # raw key), so every outcome below -- stored, invalid, empty, unfit,
        # amputated, superseded -- has already dropped it.
        my $hintKey = delete $paramRef->{'soloistHintKey'};
        $hintKey = '' unless defined $hintKey;
        $hintKey =~ s/^\s+|\s+$//g;

        my $keyRole  = (defined $paramRef->{'pref_soloistKey'} || length $hintKey)
            ? Plugins::SpotOn::Unified::DaemonManager->backendClass() : undef;
        my $keyState = $keyRole ? $keyRole->keyState : undef;
        if ($keyState && $keyState->{supported}) {
            my $raw = $paramRef->{'pref_soloistKey'} // '';
            $raw =~ s/^\s+|\s+$//g;    # trim whitespace only, for comparison
            # An empty pref_soloistKey does not clear when the hint input carries
            # a key (the select was switched to Soloist before saving).
            $raw = $hintKey if !length $raw && length $hintKey;

            if (length $raw) {
                my $currentMasked = $keyState->{present} ? SOLOIST_KEY_MASKED_PREVIEW : '';
                _storeSpakKey($paramRef, $keyRole, $raw) if $raw ne $currentMasked;
            }
            elsif ($keyState->{present}) {
                $keyRole->clearKey();
            }
        }
        elsif (length $hintKey) {
            # The active backend has no key store (librespot): store the key
            # through the Soloist role, but only where Soloist can run. No
            # pref write, no bootstrap, no scheduleInit -- the backend stays
            # as it is; the next render offers the switch. Never clears.
            require Plugins::SpotOn::Backend;
            if (grep { $_ eq 'soloist' } Plugins::SpotOn::Backend::available()) {
                my $soloistRole = eval { Plugins::SpotOn::Backend::classFor('soloist') };
                if ($soloistRole && eval { $soloistRole->platformFit }) {
                    _storeSpakKey($paramRef, $soloistRole, $hintKey);
                    main::INFOLOG && $log->is_info && $log->info('Settings: Soloist key submitted in the hint, backend unchanged');
                }
            }
        }

        # 85-13 (D-01): no Client-ID pref. A stale settings page that still posts
        # the old Client-ID field is simply not read -- nothing is stored.

        # 85-12 (decision-D17 pathfinder-login5-plus-rootlist, cookie-free; D-19):
        # Made for You needs neither a cookie nor a hand-entered Pathfinder hash,
        # so a stale settings page that still posts the two old fields (the cookie
        # and the hand-entered hash) is simply not read -- nothing is stored,
        # nothing dies (T-85-53). The hashes are scraped into the
        # spoton_pf_hash_<op> cache keys, not a pref.

        # Account remove (CR-03, WR-03).
        # WR-03: validate that removeId is an 8-char hex string that actually
        # exists in the accounts pref before acting on it.  This prevents a
        # crafted POST with e.g. removeAccount=../../etc from reaching _cacheDir
        # and potentially deleting directories outside the SpotOn data dir.
        # CR-03: determine the new activeAccount BEFORE calling removeAccount,
        # because removeAccount clears activeAccount to '' before returning —
        # checking it afterwards would always yield '' and never auto-select a
        # replacement.
        if (my $removeId = $paramRef->{removeAccount}) {
            my $accounts = $prefs->get('accounts') || {};
            if (exists $accounts->{$removeId} && $removeId =~ /\A[0-9a-f]{8}\z/) {
                my $newActive;
                if (($prefs->get('activeAccount') || '') eq $removeId) {
                    # Removed account was active — pick a replacement from the
                    # remaining accounts (sorted for determinism).
                    my @remaining = sort grep { $_ ne $removeId } keys %{$accounts};
                    $newActive = @remaining ? $remaining[0] : '';
                }

                require Plugins::SpotOn::API::TokenManager;
                Plugins::SpotOn::API::TokenManager->removeAccount($removeId);

                # Apply the pre-computed replacement if one was needed.
                # (removeAccount already set activeAccount to '' if it was active;
                # we overwrite that '' with the proper replacement here.)
                if (defined $newActive) {
                    $prefs->set('activeAccount', $newActive);
                }

                # Clear per-client prefs pointing to the removed account so players
                # fall back to the new global. Prefs pointing to other accounts are
                # left intact (those per-client settings remain valid).
                for my $c (Slim::Player::Client::clients()) {
                    my $clientAcct = $prefs->client($c)->get('activeAccount') // '';
                    if ($clientAcct eq $removeId) {
                        $prefs->client($c)->remove('activeAccount');
                    }
                }

                # GH #139: refresh Material Skin home rows after account removal.
                Plugins::SpotOn::HomeExtras::refresh() if $INC{'Plugins/SpotOn/HomeExtras.pm'};
            }
        }

        # Account switch (WR-04).
        # Validate that switchId is a known account before setting it as active.
        # Without this check an attacker with a valid LMS session could set
        # activeAccount to an arbitrary string, which could confuse code that
        # reads the preference and assumes it points to a real account.
        if (my $switchId = $paramRef->{switchAccount}) {
            my $accounts = $prefs->get('accounts') || {};
            if (exists $accounts->{$switchId}) {
                $prefs->set('activeAccount', $switchId);
                # Clear per-client overrides for all connected players so they fall back
                # to the new global setting. _getAccountId() checks per-client first, so
                # without this, the Settings switch has no effect on players that already
                # have a per-client activeAccount pref set via the OPML account switcher.
                for my $c (Slim::Player::Client::clients()) {
                    $prefs->client($c)->remove('activeAccount');
                }

                # GH #139: refresh Material Skin home rows after Settings account switch.
                Plugins::SpotOn::HomeExtras::refresh() if $INC{'Plugins/SpotOn/HomeExtras.pm'};
            }
        }

        # Save diagnosticMode (global pref, not per-player) (#3)
        my $diagMode = $paramRef->{'pref_diagnosticMode'} ? 1 : 0;
        $prefs->set('diagnosticMode', $diagMode);

        # Save global streamingMode default (COMPAT-01, GH #96 scope extension).
        # Deliberately NOT in the prefs() return list (see comment there) — validated
        # here and written directly so the base class handler cannot overwrite it
        # with unsanitized raw form input.
        if (defined $paramRef->{'pref_streamingMode'}) {
            my $mode = $paramRef->{'pref_streamingMode'};
            $mode = 'direct' unless $mode =~ /^(?:direct|proxy)$/;
            $prefs->set('streamingMode', $mode);
        }

        # Save global Spotify streaming-quality default (83.3 D-12/D-13).
        # Deliberately NOT in the prefs() return list (see comment there) --
        # whitelisted here and written directly, then applied async so the
        # save handler never blocks on a network round-trip (RESEARCH
        # Pitfall 4). Only writes to the server when the value actually
        # changed (change-detect, D-12: never fight the app on every save).
        # D-17 (84-08): validated against and written through the active
        # backend role (qualityInfo / quality); a backend without the
        # Spotify quality control answers supported => 0 and nothing is
        # stored or sent.
        if (defined $paramRef->{'pref_soloistQuality'}) {
            require Plugins::SpotOn::Unified::DaemonManager;
            my $role = Plugins::SpotOn::Unified::DaemonManager->backendClass();
            my $qi   = $role->qualityInfo;
            if ($qi->{supported}) {
                my %valid = map { $_ => 1 } @{ $qi->{validLevels} || [] };
                my $raw = $paramRef->{'pref_soloistQuality'};
                my $q = (defined $raw && $valid{$raw}) ? $raw : 0;
                my $old = $prefs->get('soloistQuality') // 0;
                if ($q ne $old) {
                    $prefs->set('soloistQuality', $q);
                    $role->quality(scope => 'global', level => $q);
                }
            }
        }
    }

    my $serverPrefs = preferences('server');

    # Pass account data to template for all requests
    $paramRef->{accounts}         = $prefs->get('accounts') || {};
    $paramRef->{activeAccount}    = $prefs->get('activeAccount') || '';

    # GH #147 plan 65-02: playback-authorization state for the ACTIVE account.
    # 'none'     -- no accounts at all (setup guide handles this case)
    # 'required' -- flagged by the crash escalation (plan 65-01)
    # 'ok'       -- otherwise
    # 85-13 (D-01): the former "has PKCE tokens but no credentials.json" arm is
    # gone with the PKCE token files; a credential-less account is the 85-10
    # migration's needsPairing flag, surfaced by the banner above.
    require Plugins::SpotOn::API::Credentials;
    require Plugins::SpotOn::API::TokenManager;
    {
        my $activeId = $paramRef->{activeAccount};
        if (!$activeId) {
            $paramRef->{playbackAuthState} = 'none';
        }
        elsif (Plugins::SpotOn::API::Credentials->needsPlaybackAuth($activeId)) {
            $paramRef->{playbackAuthState} = 'required';
        }
        else {
            $paramRef->{playbackAuthState} = 'ok';
        }

        # 66-02 D-08: source of the active account's playback credentials
        # ('zeroconf' | 'keymaster' | '' when unset/legacy) -- lets the
        # template show which pairing path last provisioned playback,
        # without a second Credentials.pm round-trip (the marker lives on
        # the accounts pref entry itself, written by _installPairedCredentials).
        $paramRef->{playbackCredSource} =
            ($activeId && $paramRef->{accounts}{$activeId})
            ? ($paramRef->{accounts}{$activeId}{playbackCredSource} || '')
            : '';
    }
    # Computed by the same single source of truth startPairing uses, so the
    # on-page instructions show the exact device label the user must pick.
    $paramRef->{pairingDeviceName} = Plugins::SpotOn::API::Credentials->pairingDeviceName();

    # 85-11 (D-21/D-24/D-02): the two-step setup block.
    # pairingWindowSeconds drives the countdown, accountStepOk the step-1
    # check mark (any account whose login chain is usable), and
    # needsPairingAccounts the "Bitte Konto einmal koppeln" hint (accounts the
    # 85-10 migration flagged because they have no usable credentials).
    # playerStepOk (step 2) is filled after the backend roles ran, since the
    # Soloist role builds the per-player list.
    $paramRef->{pairingWindowSeconds} = Plugins::SpotOn::API::Credentials::PAIRING_WINDOW_SECONDS();
    $paramRef->{accountStepOk} =
        (grep { Plugins::SpotOn::API::TokenManager->hasValidLogin($_) } keys %{ $paramRef->{accounts} })
        ? 1 : 0;
    $paramRef->{needsPairingAccounts} =
        [ sort grep { $paramRef->{accounts}{$_}{needsPairing} } keys %{ $paramRef->{accounts} } ];

    # D-08/D-09 (Phase 71): backend selection + per-backend status for the
    # template. `backend` (the SAVED pref) drives the select#pref_backend
    # pre-selection. 84-08 (SEAM-6.2): every registered backend fills its
    # own template keys through its role's settingsInfo -- the other
    # backend's div is rendered hidden and shown by the select's listener,
    # so its status lines need their keys whatever backend is saved. A
    # backend whose files are absent (the §6.3.2 amputation) is skipped:
    # its role fails to load, the page still renders (T-84-28).
    $paramRef->{backend} = $prefs->get('backend') || 'librespot';
    # 84-13 (B3): the backend <select> offers only the available backends
    # (registered AND role module loads) -- basic.html loops over this list.
    require Plugins::SpotOn::Backend;
    $paramRef->{availableBackends} = [ Plugins::SpotOn::Backend::available() ];
    {
        require Plugins::SpotOn::Backend;
        for my $name (Plugins::SpotOn::Backend::names()) {
            my $role = eval { Plugins::SpotOn::Backend::classFor($name) } or do {
                main::INFOLOG && $log->is_info && $log->info("Settings: backend '$name' not available: $@");
                next;
            };
            eval {
                $role->settingsInfo($paramRef,
                    formatHealthNotice  => \&_formatHealthNotice,
                    keyMaskedPreview    => SOLOIST_KEY_MASKED_PREVIEW,
                );
                1;
            } or $log->warn("Settings: settingsInfo of backend '$name' failed: $@");
        }
    }

    # 85-11 (D-24) step 2: only Soloist needs a per-player pairing (it exports
    # no tokens); the librespot backend is covered by the account pairing.
    $paramRef->{playerStepOk} =
        ($paramRef->{backend} eq 'soloist')
        ? ((grep { !$_->{paired} } @{ $paramRef->{soloistPlayers} || [] }) ? 0 : 1)
        : 1;

    # Diagnostic mode status for template (#3)
    $paramRef->{diagnosticEnabled} = $prefs->get('diagnosticMode') ? 1 : 0;

    # Global streaming mode default status for template (COMPAT-01, GH #96 scope extension)
    $paramRef->{globalStreamingMode} = $prefs->get('streamingMode') || 'direct';

    my $logTotal = 0;
    my $spotonDir = catdir($serverPrefs->get('cachedir'), 'spoton');
    # 74b-04: the Soloist log (<id>-soloist.log) and its one rotated
    # generation (.1) count as well.
    for my $pattern ('*-connect.log', '*-unified.log', '*-soloist.log', '*-soloist.log.1') {
        for my $f (bsd_glob(catfile($spotonDir, $pattern))) {
            $logTotal += -s $f || 0;
        }
    }
    $paramRef->{connectLogSize} = $logTotal >= 1048576 ? sprintf('%.1f MB', $logTotal / 1048576)
                                : $logTotal >= 1024    ? sprintf('%.1f KB', $logTotal / 1024)
                                :                        "$logTotal B";

    return $class->SUPER::handler($client, $paramRef, $callback, $httpClient, $response);
}

# ============================================================
# ZeroConf playback-authorization pairing (GH #147 plan 65-02)
# /plugins/SpotOn/settings/playerauth/start (POST, CSRF-guarded)
# Starts a --discover-once pairing helper (85-10, D-05: account-less -- the
# account is created from the credentials the Spotify app hands over, so the
# request carries no accountId). Responses carry the symbolic reason enum
# only, never raw stderr (T-65-07).
# ============================================================
sub _playerAuthStartHandler {
    my ($httpClient, $response) = @_;

    return unless _csrfCheck($httpClient, $response);

    require Plugins::SpotOn::API::Credentials;

    # 85-10 (D-05): account-less. The account is created from the credentials
    # the Spotify app hands over, so no accountId is read from the request.
    my ($ok, $reason) = Plugins::SpotOn::API::Credentials->startPairing();

    if ($ok) {
        _jsonResponse($httpClient, $response, {
            status        => 'ok',
            deviceName    => Plugins::SpotOn::API::Credentials->pairingDeviceName(),
            windowSeconds => Plugins::SpotOn::API::Credentials::PAIRING_WINDOW_SECONDS(),
        });
    } else {
        _jsonResponse($httpClient, $response,
            { status => 'error', reason => $reason });
    }
}

# ============================================================
# /plugins/SpotOn/settings/playerauth/status (GET, read-only)
# JSON passthrough of Credentials->pairingStatus(). Same unguarded class as
# diagnosticBundle: read-only, exposes symbolic state only (T-65-07).
# ============================================================
sub _playerAuthStatusHandler {
    my ($httpClient, $response) = @_;

    require Plugins::SpotOn::API::Credentials;
    _jsonResponse($httpClient, $response,
        Plugins::SpotOn::API::Credentials->pairingStatus());
}

# ============================================================
# /plugins/SpotOn/settings/playerauth/cancel (POST, CSRF-guarded)
# Cancels a running pairing (idempotent when idle). Also the target of the
# pagehide keepalive request in basic.html (gotcha 6).
# ============================================================
sub _playerAuthCancelHandler {
    my ($httpClient, $response) = @_;

    return unless _csrfCheck($httpClient, $response);

    require Plugins::SpotOn::API::Credentials;
    Plugins::SpotOn::API::Credentials->cancelPairing();

    _jsonResponse($httpClient, $response, { status => 'ok' });
}

# ============================================================
# _storeSpakKey($paramRef, $role, $raw)
# 79-05 (D-12): the one validate-and-store step of the spak key, shared by the
# active-role key block and the hint-key fallback. $raw is the trimmed,
# not-the-masked-placeholder value. WR-03: reject instead of silently
# stripping disallowed characters (a charset-filtered key was previously
# stored with no user-visible error, only discoverable later when pairing
# failed with no traceable cause). The real spak-key alphabet is unverified
# (RESEARCH.md A1/A5); this whitelist + minimum length is a conservative
# placeholder pending empirical confirmation against a real key (T-71-06).
# WR-08: storeKey() returns (0, 'write_failed') on a print/close/rename
# failure; surface it through the same warning channel as the invalid-format
# path. The raw key is never logged and never copied into $paramRef.
# ============================================================
sub _storeSpakKey {
    my ($paramRef, $role, $raw) = @_;

    if ($raw =~ /^[A-Za-z0-9_\-\.]{16,8192}\z/) {
        my ($ok) = $role->storeKey($raw);
        $paramRef->{'warning'} = string('PLUGIN_SPOTON_SOLOIST_KEY_WRITE_FAILED')
            unless $ok;
    }
    else {
        $paramRef->{'warning'} = string('PLUGIN_SPOTON_SOLOIST_KEY_INVALID');
    }
    return;
}

# ============================================================
# _formatHealthNotice($mac)
# 84.1 plan 03 (D-04): renders DaemonManager->soloistHealthFor($mac) into
# the pre-formatted string the soloistPlayers row displays (next to
# qualityNotice), or '' when the health tick has never stopped this MAC.
# T-84.1-02: built ONLY from the player name, a fixed reason string, and a
# clock time -- no argv, no data-dir path, no MAC-derived filesystem path.
# ============================================================
sub _formatHealthNotice {
    my ($mac) = @_;

    require Plugins::SpotOn::Unified::DaemonManager;
    my $health = Plugins::SpotOn::Unified::DaemonManager->soloistHealthFor($mac) or return '';

    my $client     = Slim::Player::Client::getClient($mac);
    my $playerName = ($client && $client->can('name')) ? ($client->name // $mac) : $mac;

    # 84.1-08 (WR-03 notice, D-04): a three-way choice -- ws_unreachable
    # gets its own reason key instead of falling through to NO_LOGIN with
    # every other non-no_answer reason.
    my $lastReason = $health->{last_reason} // '';
    my $reasonKey  = $lastReason eq 'no_answer'      ? 'PLUGIN_SPOTON_SOLOIST_HEALTH_REASON_NO_ANSWER'
                    : $lastReason eq 'ws_unreachable' ? 'PLUGIN_SPOTON_SOLOIST_HEALTH_REASON_WS_UNREACHABLE'
                    :                                   'PLUGIN_SPOTON_SOLOIST_HEALTH_REASON_NO_LOGIN';

    require POSIX;
    # 84.1-08 (WR-06, D-04): a date AND a clock time -- the notice can now
    # persist past the day it was created (WR-06 ages it out, not the
    # calendar), so the bare %H:%M used to read as "today" no matter when.
    my $timeText = $health->{last_at} ? POSIX::strftime('%Y-%m-%d %H:%M', localtime($health->{last_at})) : '?';

    return sprintf(string('PLUGIN_SPOTON_SOLOIST_HEALTH_RESTARTED'),
        $playerName, string($reasonKey), $timeText);
}

# ============================================================
# Diagnostic bundle endpoint (#3): /plugins/SpotOn/settings/diagnosticBundle
# Returns a downloadable text file with system info + daemon logs.
# Only works when diagnosticMode pref is enabled (403 otherwise).
# 74b-03 (D-07): at the Soloist state - backend, Soloist version/expiry/key
# state, stored stream quality, glibc, per-player effective format and path,
# the live *-soloist.log tails - and every log tail and the server.log
# extract pass through _redactBundleText (T-74b-07).
# ============================================================

# The repo's secret pattern, copied verbatim from tools/uat/extract-run.pl
# ($REDACT_RE): Soloist keys, auth_data values and Bearer tokens.
my $BUNDLE_REDACT_RE = qr/spak_[A-Za-z0-9_-]*|auth_data[^ ]*|Bearer [A-Za-z0-9._-]+/;

sub _redactBundleText {
    my ($text) = @_;
    return $text unless defined $text;
    $text =~ s/$BUNDLE_REDACT_RE/[REDACTED]/g;
    return $text;
}

sub _diagnosticBundleHandler {
    my ($httpClient, $response) = @_;

    unless ($prefs->get('diagnosticMode')) {
        _jsonResponse($httpClient, $response, { error => 'Diagnostic mode not enabled' }, 403);
        return;
    }

    my $serverPrefs = preferences('server');
    my $spotonDir   = catdir($serverPrefs->get('cachedir'), 'spoton');

    # Collect all daemon logs (connect + unified + soloist). Live files only:
    # the *-soloist.log.1 generation stays out to keep the bundle bounded.
    my @logFiles = (
        bsd_glob(catfile($spotonDir, '*-connect.log')),
        bsd_glob(catfile($spotonDir, '*-unified.log')),
        bsd_glob(catfile($spotonDir, '*-soloist.log')),
    );

    # Build header with system info
    my $activeId = $prefs->get('activeAccount') || '';
    my $redactedId = $activeId ? substr($activeId, 0, 4) . '****' : 'none';

    require Plugins::SpotOn::Unified::DaemonManager;
    my $DM          = 'Plugins::SpotOn::Unified::DaemonManager';
    my $backendName = eval { $DM->backendName() } // 'unknown';
    my $isSoloist   = $backendName eq 'soloist';
    my $role        = eval { $DM->backendClass() };

    # Backend block (D-07). Every read is eval-guarded: a broken role must
    # not take the whole bundle down.
    my @backendLines = ("Backend: $backendName");
    if ($isSoloist) {
        my %info;
        eval {
            $role->settingsInfo(\%info,
                formatHealthNotice => \&_formatHealthNotice,
                keyMaskedPreview   => SOLOIST_KEY_MASKED_PREVIEW,
            );
            1;
        };
        push @backendLines, 'Soloist version: ' . ($info{soloistMissing} ? '(not installed)' : ($info{soloistVersion} || 'unknown'));
        push @backendLines, 'Soloist expiry: ' . ($info{soloistExpired} ? 'EXPIRED' : ($info{soloistExpiryText} || 'unknown'));
        my $keyState = eval { $role->keyState() } || {};
        push @backendLines, 'Soloist key: ' . ($keyState->{present} ? 'present' : 'missing');
        push @backendLines, 'Spotify quality (stored): ' . ($prefs->get('soloistQuality') // 'unknown');
    }
    my $glibc = eval { $DM->glibcVersion() };
    push @backendLines, 'glibc: ' . (defined $glibc ? $glibc : 'not detected');
    my $glibcProblem = eval { $DM->soloistGlibcProblem() };
    # 79-24 (RF-74b-IN-03): say what was checked. soloistGlibcProblem() is undef
    # for "backend not soloist", "glibc undetectable" and "glibc fine" alike, so
    # the line branches on the values read above, not on that return alone.
    if (!$isSoloist) {
        push @backendLines, "glibc check: not applicable (backend $backendName)";
    }
    elsif (!defined $glibc) {
        push @backendLines, 'glibc check: not run (glibc not detected)';
    }
    elsif (defined $glibcProblem && length $glibcProblem) {
        push @backendLines, "glibc check: $glibcProblem";
    }
    else {
        push @backendLines, 'glibc check: ok';
    }
    unless ($isSoloist) {
        push @backendLines, 'Bitrate: ' . ($prefs->get('bitrate') || 320);
        push @backendLines, 'Normalization: ' . ($prefs->get('normalization') ? 'on' : 'off');
    }

    my @playerList;
    for my $c (Slim::Player::Client::clients()) {
        my $line = sprintf('  %s | %s | %s', $c->name, $c->id, $c->model);
        eval {
            my $out = $DM->effectiveOutput($c);
            $line .= sprintf(' | format chosen=%s effective=%s type=%s path=%s',
                $out->{chosen} // '?', $out->{effective} // '?', $out->{type} // '?', $out->{path} // '?');
            $line .= ' reason=' . $out->{reason} if $out->{reason};
            1;
        };
        if ($isSoloist) {
            my $q = eval { $role->qualityInfo($c) } || {};
            $line .= ' quality=' . ($q->{effectiveLabel} || 'unknown');
        }
        push @playerList, $line;
    }

    require POSIX;
    my $timestamp = POSIX::strftime('%Y%m%d-%H%M%S', localtime);

    my $header = join("\n",
        '=== SpotOn Diagnostic Bundle ===',
        "Generated: $timestamp",
        '',
        '--- System Info ---',
        "LMS version: $::VERSION",
        "OS: $^O",
        "Perl: $]",
        "SpotOn version: " . (Plugins::SpotOn::Plugin->_pluginDataFor('version') || 'unknown'),
        "Active account: $redactedId",
        @backendLines,
        "diagnosticMode: 1",
        '',
        '--- Players ---',
        (@playerList ? join("\n", @playerList) : '  (none)'),
        '',
        '=' x 50,
        '',
    );

    # --- Token & API Status ---
    my @tokenStatus;
    eval {
        require Plugins::SpotOn::API::SpClient;
        my $snapshot = Plugins::SpotOn::API::SpClient->statusSnapshot() || {};
        push @tokenStatus, '--- Token & API Status ---';

        my $accounts = $prefs->get('accounts') || {};
        my $displayName = 'unknown';
        if ($activeId && $accounts->{$activeId}) {
            $displayName = $accounts->{$activeId}{displayName} || $accounts->{$activeId}{spotifyUserId} || 'unknown';
        }
        push @tokenStatus, "  Display name: $displayName";
        push @tokenStatus, "  API requests: " . ($snapshot->{apiRequestCount} || 0);
        push @tokenStatus, "  429 responses: " . ($snapshot->{api429Count} || 0);
        push @tokenStatus, "  Rate limited: " . ($snapshot->{rateLimited} ? 'YES' : 'no');
        push @tokenStatus, "  spclient host: " . ($snapshot->{spclientHost} // '(not resolved)');
        push @tokenStatus, "  Last error: " . ($snapshot->{lastErrorClass} // '(none)');
        for my $acctId (sort keys %{ $snapshot->{login5} || {} }) {
            push @tokenStatus, "  login5 state (" . substr($acctId, 0, 4) . "****): " . ($snapshot->{login5}{$acctId} // 'unknown');
        }

        if ($INC{'Plugins/SpotOn/Status.pm'}) {
            my $errors = Plugins::SpotOn::Status->getErrorHistory() || [];
            my @tokenErrors = grep { $_->{module} && ($_->{module} eq 'Token' || $_->{module} eq 'Auth') } @$errors;
            if (@tokenErrors) {
                push @tokenStatus, '';
                push @tokenStatus, '  Recent token errors (' . scalar(@tokenErrors) . '):';
                for my $err (@tokenErrors[0 .. ($#tokenErrors > 9 ? 9 : $#tokenErrors)]) {
                    my $ts = POSIX::strftime('%Y-%m-%d %H:%M:%S', localtime($err->{ts}));
                    push @tokenStatus, "    [$ts] $err->{message}";
                }
            } else {
                push @tokenStatus, '  Recent token errors: (none)';
            }
        }
    };
    if ($@) {
        @tokenStatus = ('--- Token & API Status ---');
        push @tokenStatus, "  (could not collect: $@)";
    }
    $header .= join("\n", @tokenStatus) . "\n\n";

    # Append each log file (cap at 500KB per file)
    my $maxBytes = 500 * 1024;
    my $logs = '';
    for my $logFile (@logFiles) {
        my $basename = basename($logFile);
        $logs .= "--- Log: $basename ---\n";
        $logs .= _redactBundleText(_readLogTail($logFile, $maxBytes));
        $logs .= "\n";
    }

    if (!@logFiles) {
        $logs = "--- No daemon log files found ---\n";
    }

    # Extract SpotOn-related lines from LMS server.log
    my $logdir = $serverPrefs->get('logdir');
    my $serverLogFile = $logdir ? catfile($logdir, 'server.log') : undef;
    if ($serverLogFile && -f $serverLogFile) {
        $logs .= "--- LMS server.log (SpotOn entries, last 200) ---\n";
        if (open(my $sfh, '<', $serverLogFile)) {
            my @spotonLines;
            while (my $line = <$sfh>) {
                push @spotonLines, $line if $line =~ /SpotOn|spoton/i;
                shift @spotonLines if @spotonLines > 200;
            }
            close $sfh;
            $logs .= _redactBundleText(join('', @spotonLines)) || "(no SpotOn entries found)\n";
        } else {
            $logs .= "(could not open server.log: $!)\n";
        }
        $logs .= "\n";
    }

    my $content = $header . $logs;
    my $filename = "spoton-diag-$timestamp.txt";

    my $bytes = encode('UTF-8', $content);
    $response->header('Content-Length' => length($bytes));
    $response->code(200);
    $response->header('Connection' => 'close');
    $response->content_type('text/plain; charset=utf-8');
    $response->header('Content-Disposition' => "attachment; filename=\"$filename\"");
    Slim::Web::HTTP::addHTTPResponse($httpClient, $response, \$bytes);
}

# ============================================================
# Clear logs endpoint (GT-07): /plugins/SpotOn/settings/clearLogs
# Deletes the *-connect.log, *-unified.log, *-soloist.log.1 and
# *-soloist.log.1.tmp files in the spoton cache directory and TRUNCATES the live *-soloist.log files to 0
# (74b-04): a running Soloist daemon keeps its append-mode file handle, an
# unlinked file would swallow its output until the next daemon start. The
# deleted count covers every file removed or truncated.
# ============================================================
sub _clearLogsHandler {
    my ($httpClient, $response) = @_;

    return unless _csrfCheck($httpClient, $response);

    my $serverPrefs = preferences('server');
    my $spotonDir   = catdir($serverPrefs->get('cachedir'), 'spoton');
    # W1: bsd_glob — plain glob() splits on whitespace (fails for paths with spaces)
    my @logFiles = (
        bsd_glob(catfile($spotonDir, '*-connect.log')),
        bsd_glob(catfile($spotonDir, '*-unified.log')),
        bsd_glob(catfile($spotonDir, '*-soloist.log.1')),
        bsd_glob(catfile($spotonDir, '*-soloist.log.1.tmp')),
    );
    my @liveSoloistLogs = bsd_glob(catfile($spotonDir, '*-soloist.log'));

    my $deleted = 0;
    for my $logFile (@logFiles) {
        if (unlink $logFile) {
            $deleted++;
        } else {
            $log->warn("clearLogs: failed to delete $logFile: $!");
        }
    }
    for my $logFile (@liveSoloistLogs) {
        my $fh;
        if (open($fh, '+<', $logFile) && truncate($fh, 0)) {
            $deleted++;
        } else {
            $log->warn("clearLogs: failed to truncate $logFile: $!");
        }
        close($fh) if $fh;
    }

    main::INFOLOG && $log->is_info && $log->info("clearLogs: deleted $deleted log file(s)");

    _jsonResponse($httpClient, $response, { status => 'ok', deleted => $deleted });
}

sub _jsonResponse {
    my ($httpClient, $response, $data, $code) = @_;
    $code //= 200;
    my $bytes = to_json($data);
    $response->header('Content-Length' => length($bytes));
    $response->code($code);
    $response->header('Connection' => 'close');
    $response->content_type('application/json');
    Slim::Web::HTTP::addHTTPResponse($httpClient, $response, \$bytes);
}

sub _readLogTail {
    my ($path, $maxBytes) = @_;
    if (open my $fh, '<', $path) {
        my $size = -s $path;
        my $content = '';
        if ($size > $maxBytes) {
            seek($fh, -$maxBytes, 2);
            <$fh>;
            $content .= "[...truncated to last 500KB...]\n";
        }
        local $/;
        $content .= <$fh> // '';
        close $fh;
        return $content;
    }
    return "(could not read " . basename($path) . ": $!)\n";
}

# ============================================================
# CSRF guard for write endpoints (P-CR-03)
# addRawFunction handlers bypass LMS's built-in CSRF protection
# (Slim::Web::HTTP dispatches raw functions before CSRF check on line 512).
# This guard validates X-Requested-With: XMLHttpRequest for write endpoints
# when LMS has csrfProtectionLevel enabled.
# Read-only endpoints (discoveryStatus, diagnosticBundle) are not guarded.
# ============================================================
sub _csrfCheck {
    my ($httpClient, $response) = @_;

    my $serverPrefs = preferences('server');
    return 1 unless $serverPrefs->get('csrfProtectionLevel');

    my $request = $response->request;
    return 1 if $request
        && $request->header('X-Requested-With')
        && $request->header('X-Requested-With') eq 'XMLHttpRequest';

    $response->code(403);
    $response->header('Content-Length' => 0);
    $response->header('Connection' => 'close');
    $response->content_type('text/plain');
    Slim::Web::HTTP::addHTTPResponse($httpClient, $response, \'');
    return 0;
}

1;
