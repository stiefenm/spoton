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
use URI;

use Slim::Utils::Log;
use Slim::Utils::Prefs;
use Slim::Utils::Strings qw(string);
use Plugins::SpotOn::Helper;

use constant SETTINGS_URL => 'plugins/SpotOn/settings/basic.html';

# T-71-02/D-11: Soloist.pm exposes no read-back API for the stored spak-key
# (by design -- storeKey/hasKey/clearKey only), so unlike sp_dc's per-account
# WebPlayer->spDcMaskedPreview (first 4 chars + '****'), the template can only
# ever show this fixed placeholder when a key is present. Shared between the
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

    # Register PKCE OAuth endpoints (AUTH-01, AUTH-02)
    Slim::Web::Pages->addRawFunction(
        'plugins/SpotOn/settings/pkce/start',
        \&_pkceStartHandler
    );
    Slim::Web::Pages->addRawFunction(
        'plugins/SpotOn/settings/pkce/callback',
        \&_pkceCallbackHandler
    );
    Slim::Web::Pages->addRawFunction(
        'plugins/SpotOn/settings/pkce/manual',
        \&_pkceManualHandler
    );
    # Spotify loopback redirect URIs use the `/login` path (both the bundled
    # default identity and the playerauth Keymaster fallback whitelist only
    # this path). Route it to the PKCE callback handler.
    Slim::Web::Pages->addRawFunction(
        'login',
        \&_pkceCallbackHandler
    );

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

    # Keymaster browser-fallback playback authorization for mDNS-unreachable
    # environments -- Docker, VLANs, pCP/IPv6 (GH #147 plan 65-03, D-02
    # secondary path)
    Slim::Web::Pages->addRawFunction(
        'plugins/SpotOn/settings/playerauth/browser/start',
        \&_playerAuthBrowserStartHandler
    );
    Slim::Web::Pages->addRawFunction(
        'plugins/SpotOn/settings/playerauth/browser/manual',
        \&_playerAuthBrowserManualHandler
    );

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
    # clientId and backend are saved manually with sanitization in handler() —
    # not listed here to prevent Slim::Web::Settings::handler from overwriting
    # with raw form input (backend: whitelist against %valid_backends, D-08/T-71-05).
    return ($prefs, 'bitrate', 'binary', 'normalization', 'diagnosticMode');
}

sub handler {
    my ($class, $client, $paramRef, $callback, $httpClient, $response) = @_;

    my ($helperPath, $helperVersion) = Plugins::SpotOn::Helper->get();

    # Pass binary status to template. D-07: the librespot binary-missing hint
    # is librespot-specific state -- under backend=soloist it lives inside
    # the now-hidden #librespot-fields group, so a soloist-only install (no
    # librespot binary ever fetched) must not surface a red warning for a
    # binary it will never need.
    $paramRef->{helperMissing} = string('PLUGIN_SPOTON_BINARY_MISSING')
        if !$helperPath && (($prefs->get('backend') || 'librespot') ne 'soloist');
    $paramRef->{binaryVersion} = $helperVersion || '';
    $paramRef->{binaryPath}    = $helperPath    || '';
    $paramRef->{isMac}         = main::ISMAC ? 1 : 0;

    # D-08 Channel 2: Settings page re-auth warning banner — show when any
    # account needs re-authentication. Uses the LMS core $paramRef->{'warning'}
    # idiom, rendered automatically by the settings/header.html template.
    require Plugins::SpotOn::API::TokenManager;
    if (Plugins::SpotOn::API::TokenManager->anyAccountNeedsReauth()) {
        $paramRef->{'warning'} = string('PLUGIN_SPOTON_REAUTH_REQUIRED_SETTINGS');
    }

    # D-06/D-08: Made For You (sp_dc) — save handling + status params below
    # both go through WebPlayer, never a raw pref key (T-52-02).
    require Plugins::SpotOn::API::WebPlayer;

    if ($paramRef->{saveSettings}) {
        my %valid_bitrates = map { $_ => 1 } (96, 160, 320);
        my $bitrate = $paramRef->{'pref_bitrate'} // 320;
        $bitrate = 320 unless $valid_bitrates{$bitrate};
        $prefs->set('bitrate', $bitrate);

        # Save normalization pref (STR-08, T-04-05)
        # Checkbox: browser sends no value when unchecked — treat undef/empty as 0
        my $norm = $paramRef->{'pref_normalization'} ? 1 : 0;
        $prefs->set('normalization', $norm);

        # Normalization change flips passthrough mode (OGG↔PCM) — restart daemons
        # immediately so formatOverride() and daemon output stay in sync.
        require Plugins::SpotOn::Unified::DaemonManager;
        Plugins::SpotOn::Unified::DaemonManager->scheduleInit();

        # Save backend pref (D-08/Phase 71, T-71-05): whitelist against the
        # known enum before persisting — an unknown/tampered POST value falls
        # back to 'librespot'. NOT part of the base prefs() list (see comment
        # there) so Slim::Web::Settings::handler cannot overwrite this with
        # unsanitized raw form input. A backend switch restarts daemons via
        # the same scheduleInit() pattern used above for normalization.
        if (defined $paramRef->{'pref_backend'}) {
            my %valid_backends = map { $_ => 1 } qw(librespot soloist);
            my $backend = $paramRef->{'pref_backend'} // '';
            $backend = 'librespot' unless $valid_backends{$backend};
            $prefs->set('backend', $backend);

            # CR-01: trigger the auto-download pipeline (D-03) the moment
            # Soloist is activated -- ensureBinary() is a no-op when a
            # working, version-matched binary is already cached (D-04).
            # Without this call, ensureBinary()/downloadBinary() have no
            # production call site and the backend can never leave the
            # soloist_missing_binary state (startHelper() only ever reads
            # the prerequisite state, it never triggers a download).
            if ($backend eq 'soloist') {
                require Plugins::SpotOn::Soloist;
                Plugins::SpotOn::Soloist::ensureBinary();
            }

            Plugins::SpotOn::Unified::DaemonManager->scheduleInit();
        }

        # Save spak-key for the Soloist backend (D-11, T-71-06). Fail-closed
        # format validation before Soloist->storeKey persists it: trim
        # whitespace, restrict to the sp_dc-style known charset (also strips
        # newlines and shell metacharacters), cap length. Deliberately NOT
        # part of the base prefs() list (mirrors pref_clientId/pref_spDc) —
        # the raw key must never round-trip into $paramRef/the rendered
        # template (T-71-02); only the fixed masked placeholder or an empty
        # field is ever shown. The "unchanged" comparison MUST happen against
        # the raw (whitespace-trimmed only) submitted value BEFORE charset
        # sanitization strips the placeholder's asterisks — otherwise every
        # unrelated settings save would resubmit the placeholder, have it
        # charset-filtered down to empty, and incorrectly clear the real
        # stored key (mirrors the pref_spDc unchanged-resubmit guard above).
        # Empty submission clears an existing key (WR-03 pattern).
        if (defined $paramRef->{'pref_soloistKey'}) {
            my $raw = $paramRef->{'pref_soloistKey'} // '';
            $raw =~ s/^\s+|\s+$//g;    # trim whitespace only, for comparison

            require Plugins::SpotOn::Soloist;
            if (length $raw) {
                my $currentMasked = Plugins::SpotOn::Soloist::hasKey() ? SOLOIST_KEY_MASKED_PREVIEW : '';
                if ($raw ne $currentMasked) {
                    # WR-03: reject instead of silently stripping
                    # disallowed characters -- a charset-filtered key was
                    # previously stored with no user-visible error, only
                    # discoverable later when pairing fails with no
                    # traceable cause (also silently destroyed a valid
                    # key if the user edited the masked placeholder
                    # instead of replacing it). The real spak-key
                    # alphabet is unverified (RESEARCH.md A1/A5); this
                    # whitelist + minimum length is a conservative
                    # placeholder pending empirical confirmation against
                    # a real key (T-71-06).
                    if ($raw =~ /^[A-Za-z0-9_\-\.]{16,8192}\z/) {
                        # WR-08: storeKey() returns (0, 'write_failed') on a
                        # print/close/rename failure (WR-06) -- that status
                        # was previously dropped here, so a failed write
                        # (full disk, read-only cachedir) looked identical
                        # to a successful save at the UI, and in the
                        # rename+move double-failure path the old key had
                        # already been unlinked with zero user-visible
                        # signal. Surface it via the same warning channel
                        # the invalid-format path (WR-03) uses.
                        my ($ok) = Plugins::SpotOn::Soloist->storeKey($raw);
                        $paramRef->{'warning'} = string('PLUGIN_SPOTON_SOLOIST_KEY_WRITE_FAILED')
                            unless $ok;
                    }
                    else {
                        $paramRef->{'warning'} = string('PLUGIN_SPOTON_SOLOIST_KEY_INVALID');
                    }
                }
            }
            elsif (Plugins::SpotOn::Soloist::hasKey()) {
                Plugins::SpotOn::Soloist::clearKey();
            }
        }

        # Save Client-ID pref (D-02, T-04.4-01)
        # T-04.4-01: Input validation — alphanumeric only, max 32 chars.
        # Spotify Client-IDs are exactly 32 hex chars — regex + length check
        # eliminates shell metacharacter injection vectors for --client-id flag.
        if (defined $paramRef->{pref_clientId}) {
            my $id = $paramRef->{pref_clientId} // '';
            $id =~ s/[^a-zA-Z0-9]//g;  # T-04.4-01: alphanumeric only (injection guard)
            $id = substr($id, 0, 32);   # T-04.4-01: max 32 chars (Spotify Client-ID format)
            my $oldId = $prefs->get('clientId') || '';
            $prefs->set('clientId', $id);

            if ($id ne $oldId) {
                require Plugins::SpotOn::API::TokenManager;
                require Plugins::SpotOn::API::PKCE;
                for my $acctId (Plugins::SpotOn::API::TokenManager->getAccountIds()) {
                    Plugins::SpotOn::API::PKCE::deleteTokens($acctId);
                    Plugins::SpotOn::API::TokenManager->clearCachedToken($acctId);
                }
                Plugins::SpotOn::API::Client->reset();
                $log->warn("Settings: Client ID changed — PKCE tokens invalidated, API limits reset, re-auth required");
            }
        }

        # Save sp_dc cookie for Made For You (D-08/D-09). Deliberately NOT
        # part of the base prefs() list (mirrors pref_clientId) -- sanitized
        # here and routed through WebPlayer->storeSpDc rather than a raw
        # $prefs->set() so masking/cache-invalidation stay centralized in
        # WebPlayer (T-52-02). The template only ever echoes back a masked
        # preview (spDcMasked below, containing literal '*' characters), so
        # the "unchanged" comparison MUST happen against the raw
        # (whitespace-trimmed only) submitted value BEFORE charset
        # sanitization strips those asterisks -- otherwise a resubmit of an
        # untouched field would never equal the placeholder and would
        # incorrectly overwrite the stored cookie.
        if (defined $paramRef->{pref_spDc}) {
            my $raw = $paramRef->{pref_spDc} // '';
            $raw =~ s/^\s+|\s+$//g;    # trim whitespace only, for comparison

            my $activeAccountId = $prefs->get('activeAccount') || '';
            if ($activeAccountId && length $raw) {
                my $currentMasked = Plugins::SpotOn::API::WebPlayer->spDcMaskedPreview($activeAccountId);
                if ($raw ne $currentMasked) {
                    my $spdc = $raw;
                    $spdc =~ s/[^A-Za-z0-9_\-\.]//g;    # restrict to sp_dc's known charset
                    $spdc = substr($spdc, 0, 512);      # length cap
                    Plugins::SpotOn::API::WebPlayer->storeSpDc($activeAccountId, $spdc) if length $spdc;
                }
            }
            elsif ($activeAccountId && !length($raw)) {
                # WR-03: empty submission clears a previously stored sp_dc.
                # Only act if there IS a stored cookie to clear (avoid no-op
                # storeSpDc calls on accounts that never had sp_dc).
                if (Plugins::SpotOn::API::WebPlayer->hasSpDc($activeAccountId)) {
                    Plugins::SpotOn::API::WebPlayer->storeSpDc($activeAccountId, '');
                }
            }
        }

        # Save Pathfinder GraphQL persisted-query hash (D-07, CR-01 gap
        # closure -- Plan 52-06). Hex-only charset validation + length cap
        # (128 chars, T-52-GC-02): the hash is not a secret, just a query
        # identifier, but validation still guards against storing unexpected
        # bytes in the pref. An empty submission clears the pref.
        if (defined $paramRef->{pref_pathfinderHash}) {
            my $hash = $paramRef->{pref_pathfinderHash} // '';
            $hash =~ s/^\s+|\s+$//g;        # trim whitespace
            $hash =~ s/[^0-9a-fA-F]//g;     # hex-only charset guard
            $hash = substr($hash, 0, 128);  # length cap
            $prefs->set('pathfinderHash', $hash);
        }

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
    }

    my $serverPrefs = preferences('server');

    # Pass account data to template for all requests
    $paramRef->{accounts}         = $prefs->get('accounts') || {};
    $paramRef->{activeAccount}    = $prefs->get('activeAccount') || '';

    # Client-ID and mode status for template (D-05: bundled=full-access,
    # custom+devmode=degraded -- semantics inverted from the old
    # degradedMode flag).
    $paramRef->{customClientId} = $prefs->get('clientId') || '';
    $paramRef->{clientIdMode}   = $prefs->get('clientId') ? 'custom' : 'bundled';

    if ($paramRef->{clientIdMode} eq 'bundled') {
        $paramRef->{quotaState} = 'extended';
    } else {
        require Plugins::SpotOn::API::Client;
        $paramRef->{quotaState} =
            (Plugins::SpotOn::API::Client->limitsProbed() && Plugins::SpotOn::API::Client->getLimit('search') <= 10)
            ? 'devmode' : 'extended';
    }

    # D-06: reason for the active account's reauth flag (if any), e.g.
    # 'bundled_id_unavailable' when the bundled ncspot Client-ID is revoked --
    # lets the template show a targeted message instead of the generic one.
    $paramRef->{reauthReason} = Plugins::SpotOn::API::TokenManager->reauthReason($paramRef->{activeAccount}) || '';

    # PKCE auth status for template (AUTH-01): has any account completed the
    # PKCE OAuth flow (has a pkce_tokens.json)? Drives which setup guide/CTA
    # the template shows.
    $paramRef->{pkceConfigured} = _isPkceConfigured();

    # Accounts exist but no PKCE tokens → user changed Client ID and needs
    # to re-authorize.  Drives a prominent orange banner at the top.
    $paramRef->{needsPkceReauth} =
        (keys %{$paramRef->{accounts}} && !$paramRef->{pkceConfigured}) ? 1 : 0;

    # GH #147 plan 65-02: playback-authorization state for the ACTIVE account.
    # 'none'     -- no accounts at all (setup guide handles this case)
    # 'required' -- flagged by the crash escalation (plan 65-01), OR the
    #               account has PKCE tokens but no credentials.json yet
    #               (fresh auth after the D-04 eager-derivation removal)
    # 'ok'       -- otherwise
    require Plugins::SpotOn::API::Credentials;
    require Plugins::SpotOn::API::PKCE;
    {
        my $activeId = $paramRef->{activeAccount};
        if (!$activeId) {
            $paramRef->{playbackAuthState} = 'none';
        }
        elsif (Plugins::SpotOn::API::Credentials->needsPlaybackAuth($activeId)
            || (!-f Plugins::SpotOn::API::Credentials->credentialsPathFor($activeId)
                && Plugins::SpotOn::API::PKCE::loadTokens($activeId))) {
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

    # D-04 Channel 2 (AUTH-07, Plan 03 Task 3): Settings migration banner --
    # global check across ALL known accounts (deliberate asymmetry vs.
    # Plugin.pm's OPML hint, which checks only the active account since
    # Browse/Library always operates on it; Settings is a global config page
    # where any account's migration state is relevant).
    require Plugins::SpotOn::API::TokenManager;
    $paramRef->{needsMigration} = Plugins::SpotOn::API::TokenManager->anyAccountNeedsMigration();

    # D-13: redirect URI for the Client-ID PKCE setup wizard, read from the
    # single-source-of-truth constant (never a second hardcoded literal --
    # Pitfall 4).
    require Plugins::SpotOn::API::PKCE;
    $paramRef->{redirectUri} = Plugins::SpotOn::API::PKCE::GITHUB_PAGES_REDIRECT_URI();

    # D-04/D-08: Made For You (sp_dc) status for template -- masked preview
    # (never the raw cookie, T-52-02) and the empty/valid/expired/secrets_down
    # degradation state (Settings channel of the 3-channel D-04 display).
    $paramRef->{spDcMasked}      = Plugins::SpotOn::API::WebPlayer->spDcMaskedPreview($paramRef->{activeAccount});
    $paramRef->{madeForYouState} = Plugins::SpotOn::API::WebPlayer->state($paramRef->{activeAccount});

    # D-07/CR-01: Pathfinder GraphQL persisted-query hash for template --
    # exposes the currently stored value (or empty string) so the Settings
    # field can be pre-filled (Plan 52-06).
    $paramRef->{pathfinderHash} = $prefs->get('pathfinderHash') || '';

    # D-08/D-09 (Phase 71): Soloist backend selection + status warnings for
    # template. backend value drives the select#pref_backend pre-selection;
    # the four soloist* flags drive the conditional status lines inside
    # div#soloist-fields (unsupported OS / binary missing / key missing /
    # version-ready), covering all D-09 degraded states while activation
    # itself always stays possible.
    require Plugins::SpotOn::Soloist;
    $paramRef->{backend}              = $prefs->get('backend') || 'librespot';
    $paramRef->{soloistUnsupportedOS} = (main::ISWINDOWS || main::ISMAC) ? 1 : 0;
    my ($soloistBinary, $soloistVersion) = Plugins::SpotOn::Soloist->get();
    $paramRef->{soloistVersion}       = $soloistVersion || '';
    $paramRef->{soloistMissing}       = $soloistBinary ? 0 : 1;
    my $soloistHasKey                 = Plugins::SpotOn::Soloist->hasKey() ? 1 : 0;
    $paramRef->{soloistKeyMissing}    = $soloistHasKey ? 0 : 1;
    # T-71-02: fixed placeholder only when a key is stored — the raw key is
    # never read back (Soloist.pm exposes no accessor for it).
    $paramRef->{soloistKeyMasked}     = $soloistHasKey ? SOLOIST_KEY_MASKED_PREVIEW : '';

    # D-07 (Phase 72 Plan 02): pairing state for the Settings pairing-status
    # block -- isPaired() drives the paired/not-paired status line,
    # launcherPath() is the exact command the not-paired hint tells the user
    # to run (same generated wrapper the sol-flc/sol-pcm convert rules spawn,
    # so a --pair run here writes into the SAME dataDir() the wrapper reads —
    # RESEARCH A3).
    $paramRef->{soloistPaired}        = Plugins::SpotOn::Soloist::isPaired() ? 1 : 0;
    $paramRef->{soloistLauncherPath}  = Plugins::SpotOn::Soloist::launcherPath() || '';

    # Diagnostic mode status for template (#3)
    $paramRef->{diagnosticEnabled} = $prefs->get('diagnosticMode') ? 1 : 0;

    # Global streaming mode default status for template (COMPAT-01, GH #96 scope extension)
    $paramRef->{globalStreamingMode} = $prefs->get('streamingMode') || 'direct';

    my $logTotal = 0;
    my $spotonDir = catdir($serverPrefs->get('cachedir'), 'spoton');
    for my $pattern ('*-connect.log', '*-unified.log') {
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
# PKCE OAuth: /plugins/SpotOn/settings/pkce/start
# AJAX endpoint (AUTH-01, T-49-08). Generates a fresh code_verifier/challenge
# pair, stashes the verifier under a nonce (bridges this request to the
# later /pkce/callback or /pkce/manual request), and returns the Spotify
# authorization URL for the browser to open in a new tab. The verifier
# itself never leaves LMS (edge case A, urknall #176).
# ============================================================
sub _pkceStartHandler {
    my ($httpClient, $response) = @_;

    return unless _csrfCheck($httpClient, $response);

    # clientId pref empty => default (bundled ncspot Extended-Quota identity)
    # mode, filled => custom mode (GH #147 plan 66-01, D-01).
    my $clientId  = _pkceClientId();
    my $isBundled = $prefs->get('clientId') ? 0 : 1;

    require Plugins::SpotOn::API::PKCE;

    # Default mode uses the dynamic loopback redirect pointing at LMS's own
    # pkce/callback endpoint: the redirect CAN reach LMS when the browser
    # runs on the LMS host; copy-paste remains the path for remote browsers.
    # Custom mode keeps the GitHub Pages relay (custom Developer Apps
    # register it as their redirect URI, per user decision). Scopes stay the
    # full PKCE_SCOPES default -- the 'streaming' scope is still required by
    # the playerauth browser fallback's derive path (D-03), not by this flow;
    # this account-PKCE flow never derives playback credentials from its own
    # token (D-02).
    my $redirectUri = $isBundled
        ? Plugins::SpotOn::API::PKCE::loopbackCallbackRedirectUri()
        : Plugins::SpotOn::API::PKCE::GITHUB_PAGES_REDIRECT_URI();

    my $verifier  = Plugins::SpotOn::API::PKCE::generateCodeVerifier();
    my $challenge = Plugins::SpotOn::API::PKCE::generateCodeChallenge($verifier);

    # Nonce keys the one-time verifier cache and round-trips through the
    # state parameter across the GitHub Pages relay. WR-04: use
    # cryptographic randomness — the nonce->verifier binding is the CSRF
    # guard for the callback endpoint (RFC 6749 sec 10.12).
    require Crypt::OpenSSL::Random;
    my $nonce = unpack('H16', Crypt::OpenSSL::Random::random_bytes(8));

    my $request = $response->request;
    my $host    = ($request && $request->header('Host')) || 'localhost';
    my $scheme  = ($request && $request->header('X-Forwarded-Proto')) || 'http';
    my $callbackUrl = $scheme . '://' . $host . '/plugins/SpotOn/settings/pkce/callback';

    my $state = Plugins::SpotOn::API::PKCE::buildState($callbackUrl, $nonce);

    # D-04: enrich the verifier cache with redirect_uri + client_id so the
    # callback/manual handlers are race-free if the user switches bundled/
    # custom mode mid-flow (they read these cached values instead of
    # re-deriving them from live prefs at callback time).
    Plugins::SpotOn::API::PKCE::storeVerifier($nonce,
        { verifier => $verifier, redirect_uri => $redirectUri, client_id => $clientId });

    my $authUrl = Plugins::SpotOn::API::PKCE::buildAuthorizationUrl($clientId, $challenge, $state, $redirectUri);

    main::INFOLOG && $log->is_info && $log->info(
        "Settings: PKCE auth flow started [nonce=" . substr($nonce, 0, 8) . "..."
        . ", mode=" . ($isBundled ? 'bundled' : 'custom') . "]");

    # 'bundled' means the ncspot Extended-Quota default identity again
    # (D-01). The dynamic loopback redirect CAN reach LMS (browser on the
    # LMS host), so the JS always arms the reload timer and no longer
    # branches on this flag -- kept for payload compatibility only.
    _jsonResponse($httpClient, $response, { url => $authUrl, nonce => $nonce, bundled => ($isBundled ? 1 : 0) });
}

# ============================================================
# PKCE OAuth: /plugins/SpotOn/settings/pkce/callback
# Browser redirect target (AUTH-01, AUTH-02) reached via the GitHub Pages
# relay after the user authorizes on accounts.spotify.com. This is a plain
# browser GET navigation, NOT an AJAX call — there is no X-Requested-With
# header to check, so it is intentionally exempt from _csrfCheck (T-49-09).
# Security instead comes from the one-time-use verifier cache: a request
# can only succeed once per /pkce/start call.
# ============================================================
sub _pkceCallbackHandler {
    my ($httpClient, $response) = @_;

    require Plugins::SpotOn::API::PKCE;

    my $request = $response->request;
    my %params  = $request ? $request->uri->query_form : ();

    if (my $err = $params{error}) {
        $log->warn("Settings: PKCE callback returned OAuth error: $err");
        _renderPkceResultPage($httpClient, $response, string('PLUGIN_SPOTON_PKCE_ERROR'),
            string('PLUGIN_SPOTON_PKCE_ERROR'), 1);
        return;
    }

    my $code  = $params{code};
    my $state = $params{state};

    unless ($code) {
        $log->warn("Settings: PKCE callback missing authorization code");
        _renderPkceResultPage($httpClient, $response, string('PLUGIN_SPOTON_PKCE_ERROR'),
            'No authorization code received.', 1);
        return;
    }

    my $verifierData = _pkceLoadVerifierDataFromState($state);
    unless ($verifierData) {
        $log->warn("Settings: PKCE callback — no verifier found for state (expired/reused)");
        _renderPkceResultPage($httpClient, $response, string('PLUGIN_SPOTON_PKCE_ERROR'),
            'Authorization session expired or already used. Please try again from the Settings page.', 1);
        return;
    }

    # T-65-11/T-65-13 (plan 65-03): reject purpose-tagged nonces -- a
    # playerauth (Keymaster browser fallback) authorization must never
    # complete through the account PKCE flow, whose finish path would
    # overwrite the account's working Web API token file with the
    # streaming-only Keymaster token pair.
    if (($verifierData->{purpose} // '') ne '') {
        $log->warn("Settings: PKCE callback — nonce belongs to the playback-authorization flow, rejected");
        _renderPkceResultPage($httpClient, $response, string('PLUGIN_SPOTON_PKCE_ERROR'),
            'This authorization belongs to the playback-authorization flow. Please paste it into the Authorize Playback section instead.', 1);
        return;
    }

    # D-04: read verifier/client_id/redirect_uri from the enriched cache
    # entry (stored at /pkce/start), not from live prefs -- race-free if the
    # user toggled bundled/custom mode mid-flow.
    my $verifier    = $verifierData->{verifier};
    my $clientId    = $verifierData->{client_id};
    my $redirectUri = $verifierData->{redirect_uri};

    Plugins::SpotOn::API::PKCE::exchangeCode($code, $clientId, $verifier, $redirectUri, sub {
        my ($tokenData, $err) = @_;

        unless ($tokenData) {
            $log->error("Settings: PKCE token exchange failed: " . ($err || 'unknown'));
            _renderPkceResultPage($httpClient, $response, string('PLUGIN_SPOTON_PKCE_ERROR'),
                string('PLUGIN_SPOTON_PKCE_ERROR'), 1);
            return;
        }

        _pkceFinishAuth($httpClient, $response, $tokenData, $clientId, 0);
    });
}

# ============================================================
# PKCE OAuth: /plugins/SpotOn/settings/pkce/manual
# AJAX copy-paste fallback (edge case D, urknall #176) for when the browser
# auto-redirect from the GitHub Pages relay never reaches LMS (e.g. relay
# cannot resolve/reach a private-network LMS host from the user's phone).
# The pasted URL is only ever parsed for its code/state query parameters —
# it is never fetched or redirected to (T-49-10).
# ============================================================
sub _pkceManualHandler {
    my ($httpClient, $response) = @_;

    return unless _csrfCheck($httpClient, $response);

    require Plugins::SpotOn::API::PKCE;

    my $callbackUrl = _postParam($response->request, 'callback_url');
    unless ($callbackUrl) {
        _jsonResponse($httpClient, $response, { status => 'error', message => 'No callback URL provided' });
        return;
    }

    my %params = eval { URI->new($callbackUrl)->query_form };
    if ($@ || !%params) {
        _jsonResponse($httpClient, $response, { status => 'error', message => 'Could not parse callback URL' });
        return;
    }

    my $code  = $params{code};
    my $state = $params{state};

    unless ($code && $state) {
        _jsonResponse($httpClient, $response,
            { status => 'error', message => 'Callback URL is missing code or state parameters' });
        return;
    }

    my $verifierData = _pkceLoadVerifierDataFromState($state);
    unless ($verifierData) {
        _jsonResponse($httpClient, $response,
            { status => 'error', message => 'Authorization session expired or already used' });
        return;
    }

    # T-65-11/T-65-13 (plan 65-03): reject purpose-tagged nonces -- see the
    # matching guard in _pkceCallbackHandler. Without this, pasting the
    # playerauth loopback URL into THIS field would store the streaming-only
    # Keymaster token pair over the account's working Web API tokens.
    if (($verifierData->{purpose} // '') ne '') {
        _jsonResponse($httpClient, $response,
            { status => 'error', message => 'This URL belongs to the playback-authorization flow — paste it into the Authorize Playback section instead' });
        return;
    }

    # D-04: read verifier/client_id/redirect_uri from the enriched cache
    # entry (stored at /pkce/start), not from live prefs -- race-free if the
    # user toggled bundled/custom mode mid-flow.
    my $verifier    = $verifierData->{verifier};
    my $clientId    = $verifierData->{client_id};
    my $redirectUri = $verifierData->{redirect_uri};

    Plugins::SpotOn::API::PKCE::exchangeCode($code, $clientId, $verifier, $redirectUri, sub {
        my ($tokenData, $err) = @_;

        unless ($tokenData) {
            $log->error("Settings: PKCE manual token exchange failed: " . ($err || 'unknown'));
            _jsonResponse($httpClient, $response, { status => 'error', message => 'Token exchange failed' });
            return;
        }

        _pkceFinishAuth($httpClient, $response, $tokenData, $clientId, 1);
    });
}

# ============================================================
# ZeroConf playback-authorization pairing (GH #147 plan 65-02)
# /plugins/SpotOn/settings/playerauth/start (POST, CSRF-guarded)
# Starts a --discover-once pairing helper for the given (or active) account.
# accountId is validated with the same WR-03 discipline as removeAccount:
# 8-char hex AND existence in the accounts pref, before it reaches any
# filesystem path construction. Responses carry the symbolic reason enum
# only, never raw stderr (T-65-07).
# ============================================================
sub _playerAuthStartHandler {
    my ($httpClient, $response) = @_;

    return unless _csrfCheck($httpClient, $response);

    require Plugins::SpotOn::API::Credentials;

    my $accountId = _postParam($response->request, 'accountId');
    $accountId = $prefs->get('activeAccount')
        unless defined $accountId && length $accountId;

    my $accounts = $prefs->get('accounts') || {};
    unless (defined $accountId
        && $accountId =~ /\A[0-9a-f]{8}\z/
        && exists $accounts->{$accountId}) {
        _jsonResponse($httpClient, $response,
            { status => 'error', reason => 'unknown_account' });
        return;
    }

    my ($ok, $reason) = Plugins::SpotOn::API::Credentials->startPairing($accountId);

    if ($ok) {
        _jsonResponse($httpClient, $response, {
            status     => 'ok',
            deviceName => Plugins::SpotOn::API::Credentials->pairingDeviceName(),
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
# Keymaster browser fallback (GH #147 plan 65-03, D-02 secondary path)
# /plugins/SpotOn/settings/playerauth/browser/start (POST, CSRF-guarded)
# For environments where mDNS pairing cannot work (Docker, VLANs, pCP/IPv6):
# starts a PKCE authorization against Spotify's Keymaster client_id with
# scope=streaming ONLY (the MA-verified recipe -- the 15 Web API scopes
# belong to the account's own PKCE flow, not this one) and the loopback
# redirect URI (gotcha 4: Spotify rejects non-loopback redirect URIs for
# the Keymaster client_id, so the GitHub Pages relay is unusable here by
# design). The resulting access token has the provenance Login5 accepts,
# so --token-login derivation works again (deriveCredentialsFromToken).
# ============================================================
sub _playerAuthBrowserStartHandler {
    my ($httpClient, $response) = @_;

    return unless _csrfCheck($httpClient, $response);

    require Plugins::SpotOn::API::PKCE;

    # Resolve target account like playerauth/start: validated param or
    # activeAccount (WR-03 discipline -- 8-char hex AND existence check
    # before the id reaches any downstream use).
    my $accountId = _postParam($response->request, 'accountId');
    $accountId = $prefs->get('activeAccount')
        unless defined $accountId && length $accountId;

    my $accounts = $prefs->get('accounts') || {};
    unless (defined $accountId
        && $accountId =~ /\A[0-9a-f]{8}\z/
        && exists $accounts->{$accountId}) {
        _jsonResponse($httpClient, $response,
            { status => 'error', reason => 'unknown_account' });
        return;
    }

    # WR-04 discipline: cryptographic randomness for verifier and nonce --
    # the nonce->verifier binding is the CSRF guard for the manual endpoint.
    my $verifier  = Plugins::SpotOn::API::PKCE::generateCodeVerifier();
    my $challenge = Plugins::SpotOn::API::PKCE::generateCodeChallenge($verifier);

    require Crypt::OpenSSL::Random;
    my $nonce = unpack('H16', Crypt::OpenSSL::Random::random_bytes(8));

    # State only needs to round-trip the nonce back through the pasted URL;
    # the embedded callback_url is never navigated to (the loopback redirect
    # never reaches LMS -- copy-paste is the only completion path).
    my $request = $response->request;
    my $host    = ($request && $request->header('Host')) || 'localhost';
    my $scheme  = ($request && $request->header('X-Forwarded-Proto')) || 'http';
    my $callbackUrl = $scheme . '://' . $host . '/plugins/SpotOn/settings/pkce/callback';
    my $state = Plugins::SpotOn::API::PKCE::buildState($callbackUrl, $nonce);

    # purpose='playerauth' tags this nonce for the browser/manual handler
    # ONLY (T-65-11): the regular PKCE flow's handlers reject it, and the
    # manual handler below rejects untagged (regular-PKCE) nonces -- one-time
    # verifiers can never be replayed across the two flows.
    Plugins::SpotOn::API::PKCE::storeVerifier($nonce, {
        verifier     => $verifier,
        redirect_uri => Plugins::SpotOn::API::PKCE::LOOPBACK_REDIRECT_URI(),
        client_id    => Plugins::SpotOn::API::PKCE::KEYMASTER_CLIENT_ID(),
        account_id   => $accountId,
        purpose      => 'playerauth',
    });

    my $authUrl = Plugins::SpotOn::API::PKCE::buildAuthorizationUrl(
        Plugins::SpotOn::API::PKCE::KEYMASTER_CLIENT_ID(),
        $challenge,
        $state,
        Plugins::SpotOn::API::PKCE::LOOPBACK_REDIRECT_URI(),
        ['streaming'],
    );

    main::INFOLOG && $log->is_info && $log->info(
        "Settings: playerauth browser fallback started [nonce=" . substr($nonce, 0, 8) . "...]");

    _jsonResponse($httpClient, $response, { url => $authUrl, nonce => $nonce });
}

# ============================================================
# /plugins/SpotOn/settings/playerauth/browser/manual (POST, CSRF-guarded)
# Completion endpoint for the browser fallback: the user pastes the
# 127.0.0.1 URL their browser landed on after approving. The pasted URL is
# only ever parsed for its code/state query parameters -- never fetched or
# redirected to (T-49-10). Exchanges the code with the cached Keymaster
# client_id/verifier/redirect_uri, then derives Login5-accepted credentials
# via deriveCredentialsFromToken.
#
# CRITICAL (T-65-13): the Keymaster token pair is used once for derivation
# and discarded -- it must NEVER be persisted to the account's token file,
# which holds the still-working Web API refresh token. There is deliberately
# no token-persistence call anywhere in this handler (region gate in
# t/09_settings.t / plan verify enforces this).
# ============================================================
sub _playerAuthBrowserManualHandler {
    my ($httpClient, $response) = @_;

    return unless _csrfCheck($httpClient, $response);

    require Plugins::SpotOn::API::PKCE;

    my $callbackUrl = _postParam($response->request, 'callback_url');
    unless ($callbackUrl) {
        _jsonResponse($httpClient, $response,
            { status => 'error', reason => 'missing_url' });
        return;
    }

    my %params = eval { URI->new($callbackUrl)->query_form };
    if ($@ || !%params) {
        _jsonResponse($httpClient, $response,
            { status => 'error', reason => 'parse_error' });
        return;
    }

    my $code  = $params{code};
    my $state = $params{state};

    unless ($code && $state) {
        _jsonResponse($httpClient, $response,
            { status => 'error', reason => 'missing_code' });
        return;
    }

    my $verifierData = _pkceLoadVerifierDataFromState($state);

    # REQUIRE purpose eq 'playerauth' (T-65-11): a nonce minted by the
    # regular PKCE flow must never complete through this endpoint -- the two
    # flows' one-time verifiers cannot be replayed across purposes.
    unless ($verifierData && ($verifierData->{purpose} // '') eq 'playerauth') {
        $log->warn("Settings: playerauth browser/manual -- no matching verifier for state "
            . "(expired/reused/wrong flow)");
        _jsonResponse($httpClient, $response,
            { status => 'error', reason => 'session_expired' });
        return;
    }

    my $verifier    = $verifierData->{verifier};
    my $clientId    = $verifierData->{client_id};      # KEYMASTER_CLIENT_ID, cached at browser/start
    my $redirectUri = $verifierData->{redirect_uri};   # loopback, cached at browser/start
    my $accountId   = $verifierData->{account_id};

    Plugins::SpotOn::API::PKCE::exchangeCode($code, $clientId, $verifier, $redirectUri, sub {
        my ($tokenData, $err) = @_;

        unless ($tokenData) {
            $log->error("Settings: playerauth browser token exchange failed: " . ($err || 'unknown'));
            _jsonResponse($httpClient, $response,
                { status => 'error', reason => 'exchange_failed' });
            return;
        }

        require Plugins::SpotOn::API::Credentials;
        Plugins::SpotOn::API::Credentials->clearRateLimit($accountId);
        Plugins::SpotOn::API::Credentials->deriveCredentialsFromToken(
            $accountId, $tokenData->{access_token}, sub {
                my ($ok, $reason) = @_;

                if ($ok) {
                    _jsonResponse($httpClient, $response, { status => 'ok' });
                } else {
                    # Symbolic reason enum only (T-65-07) -- never stderr.
                    _jsonResponse($httpClient, $response,
                        { status => 'error', reason => $reason });
                }
            });
    });
}

# ============================================================
# _pkceLoadVerifierDataFromState($state)
# Parses the state parameter and pops the matching verifier-data hashref
# {verifier, redirect_uri, client_id} (D-04) from the one-time-use cache.
# Returns undef (safely) on any malformed/missing input.
# ============================================================
sub _pkceLoadVerifierDataFromState {
    my ($state) = @_;
    return undef unless $state;

    my $stateData = Plugins::SpotOn::API::PKCE::parseState($state);
    my $nonce = $stateData ? $stateData->{nonce} : undef;
    return undef unless $nonce;

    my $data = Plugins::SpotOn::API::PKCE::loadAndDeleteVerifier($nonce);
    return undef unless ref $data eq 'HASH';
    return $data;
}

# ============================================================
# _pkceFinishAuth($httpClient, $response, $tokenData, $clientId, $isJson)
# Shared tail of the callback/manual handlers: looks up the Spotify user
# profile to derive a stable accountId, persists the PKCE tokens, and
# creates/updates the account in prefs. Responds with JSON (manual, AJAX
# fallback) or an HTML result page (callback, browser redirect).
# ============================================================
sub _pkceFinishAuth {
    my ($httpClient, $response, $tokenData, $clientId, $isJson) = @_;

    require Slim::Networking::SimpleAsyncHTTP;

    Slim::Networking::SimpleAsyncHTTP->new(
        sub {
            my $http    = shift;
            my $profile = eval { from_json($http->content) };
            my $userId  = $profile && $profile->{id};
            unless ($userId) {
                $log->error("Settings: PKCE /me lookup returned no user ID — cannot create account");
                if ($isJson) {
                    _jsonResponse($httpClient, $response,
                        { status => 'error', message => 'Spotify profile lookup failed — please try again' });
                } else {
                    _renderPkceResultPage($httpClient, $response, string('PLUGIN_SPOTON_PKCE_ERROR'),
                        'Could not retrieve Spotify profile. Please try again.', 1);
                }
                return;
            }
            my $displayName = $profile->{display_name} || $userId;
            _pkceStoreAccount($httpClient, $response, $tokenData, $clientId, $userId, $displayName, $isJson);
        },
        sub {
            my ($http, $error) = @_;
            $log->error("Settings: PKCE /me lookup failed: $error — cannot create account without user identity");
            if ($isJson) {
                _jsonResponse($httpClient, $response,
                    { status => 'error', message => 'Spotify profile lookup failed — please try again' });
            } else {
                _renderPkceResultPage($httpClient, $response, string('PLUGIN_SPOTON_PKCE_ERROR'),
                    'Could not retrieve Spotify profile. Please try again.', 1);
            }
        },
        { timeout => 30 }
    )->get(
        'https://api.spotify.com/v1/me',
        'Authorization' => "Bearer $tokenData->{access_token}",
        'Accept'        => 'application/json',
    );
}

# ============================================================
# _pkceStoreAccount(...)
# Derives accountId, persists PKCE tokens (chmod 0600 file via PKCE.pm),
# secures the account directory (chmod 0700, T-04.3-07 pattern), and stores
# the account in prefs via TokenManager's existing _storeAccountPrefs (sets
# activeAccount + triggers daemon start if this is the first account).
# ============================================================
sub _pkceStoreAccount {
    my ($httpClient, $response, $tokenData, $clientId, $userId, $displayName, $isJson) = @_;

    my $accountId = substr(md5_hex($userId), 0, 8);
    my $expiresAt = time() + ($tokenData->{expires_in} || 3600);

    require Plugins::SpotOn::API::PKCE;
    my $stored = Plugins::SpotOn::API::PKCE::storeTokens($accountId, {
        access_token  => $tokenData->{access_token},
        refresh_token => $tokenData->{refresh_token},
        expires_at    => $expiresAt,
        client_id     => $clientId,
        scope         => $tokenData->{scope},
    });

    # IN-05: consistent accountId masking (T-50-01 discipline) — never log
    # the full accountId; use the same substr(0,4).'****' pattern as the
    # failure branch below.
    my $maskedId = substr($accountId, 0, 4) . '****';

    unless ($stored) {
        $log->error("Settings: PKCE token storage failed for account $maskedId — aborting account creation");
        if ($isJson) {
            _jsonResponse($httpClient, $response, { status => 'error', message => 'Token storage failed' });
        } else {
            _renderPkceResultPage($httpClient, $response, string('PLUGIN_SPOTON_PKCE_ERROR'),
                'Token storage failed — check disk space and cache directory permissions.', 1);
        }
        return;
    }

    my $serverPrefs = preferences('server');
    my $accountDir  = catdir($serverPrefs->get('cachedir'), 'spoton', $accountId);
    chmod(0700, $accountDir) if -d $accountDir;

    require Plugins::SpotOn::API::TokenManager;
    Plugins::SpotOn::API::TokenManager->_storeAccountPrefs($accountId, $userId, $displayName, sub {
        main::INFOLOG && $log->is_info && $log->info(
            "Settings: PKCE account $maskedId connected (displayName=$displayName)");

        # T-50-11: clear the persistent needsReauth flag immediately on a
        # successful (re-)authentication rather than waiting for the next
        # refresh timer cycle.
        Plugins::SpotOn::API::TokenManager->clearNeedsReauth($accountId);

        # GH #139: refresh Material Skin home rows now that auth is complete.
        # Fires for both first-time auth and re-auth.  Daemon lifecycle is
        # intentionally not signaled — rows carry no daemon-derived content.
        Plugins::SpotOn::HomeExtras::refresh() if $INC{'Plugins/SpotOn/HomeExtras.pm'};

        # scheduleInit stays: harmless without playback credentials
        # (startHelper skips accounts without a usable credentials.json),
        # and required so an account that ALREADY has valid ZeroConf-paired
        # credentials gets its daemon after a token re-auth (D-06/D-07:
        # unconditional trigger, never the first-account-only
        # $needsDaemonStart conditional in _storeAccountPrefs; Pitfall 6).
        require Plugins::SpotOn::Unified::DaemonManager;
        Plugins::SpotOn::Unified::DaemonManager->scheduleInit();

        require Plugins::SpotOn::API::Client;
        unless (Plugins::SpotOn::API::Client->limitsProbed()) {
            Plugins::SpotOn::API::Client->probeEndpointLimits($accountId, sub {});
        }

        # D-02 (the core of phase 66): account-PKCE tokens are NEVER
        # derivation input, for any client_id -- an account-PKCE token has
        # the wrong provenance for Login5, so ZeroConf pairing (65-02) is the
        # REQUIRED second auth step (the 65-05 hypothesis test proved this
        # restriction is server-side and client_id-based, not fixable by
        # picking a "better" client_id). The playerauth browser fallback
        # (65-03) remains the alternate playback path for mDNS-unreachable
        # networks (D-03). The response reports honest, already-known state:
        # a re-auth of an already-paired account reports ready; a fresh
        # account reports playback authorization required. The access token
        # appears in no log line and is persisted nowhere beyond the
        # storeTokens call above (T-65-09).
        require Plugins::SpotOn::API::Credentials;
        my $hasPlayback = (-f Plugins::SpotOn::API::Credentials->credentialsPathFor($accountId))
            && !Plugins::SpotOn::API::Credentials->needsPlaybackAuth($accountId);

        if ($isJson) {
            _jsonResponse($httpClient, $response,
                { status => 'ok', accountId => $accountId,
                  connectReady => ($hasPlayback ? 1 : 0),
                  playbackAuthRequired => ($hasPlayback ? 0 : 1) });
        } else {
            _renderPkceResultPage($httpClient, $response,
                string('PLUGIN_SPOTON_PKCE_SUCCESS'),
                string('PLUGIN_SPOTON_PKCE_SUCCESS'), 0);
        }
    });
}

# ============================================================
# _pkceClientId()
# Resolves the Client-ID to use for PKCE requests: the user's own Spotify
# Developer App Client-ID if configured, otherwise SpotOn's bundled
# Extended-Quota Client ID (GH #147 plan 66-01, D-01). The bundled identity
# has its OWN rate-limit bucket, unlike the previous default which shared
# one global bucket with every librespot/Spotify Desktop user worldwide --
# that shared bucket caused the severe 429 blockade this plan reverts.
# Tokens minted with the bundled ID have the wrong provenance for Login5 and
# are therefore never used for playback-credential derivation (phase-65 D-04
# discipline re-instated) -- ZeroConf pairing (65-02) is the required second
# auth step.
# ============================================================
sub _pkceClientId {
    my $custom = $prefs->get('clientId');
    return $custom if $custom;

    require Plugins::SpotOn::API::Client;
    return Plugins::SpotOn::API::Client::SPOTON_DEFAULT_CLIENT_ID();
}

# ============================================================
# _isPkceConfigured()
# True if any known account has completed the PKCE OAuth flow (has a
# pkce_tokens.json). Drives which setup guide/CTA the template shows.
# ============================================================
sub _isPkceConfigured {
    require Plugins::SpotOn::API::TokenManager;
    require Plugins::SpotOn::API::PKCE;

    for my $id (Plugins::SpotOn::API::TokenManager->getAccountIds()) {
        return 1 if Plugins::SpotOn::API::PKCE::loadTokens($id);
    }
    return 0;
}

# ============================================================
# _postParam($request, $key)
# Extracts a single application/x-www-form-urlencoded POST body parameter.
# Returns undef if the request/body is missing or the key is absent.
# ============================================================
sub _postParam {
    my ($request, $key) = @_;
    return undef unless $request;

    my $body = $request->content;
    return undef unless defined $body && length $body;

    my %params = eval { URI->new("?$body")->query_form };
    return undef if $@;
    return $params{$key};
}

# ============================================================
# _htmlEscape($str)
# Minimal HTML entity escaping for values interpolated into
# _renderPkceResultPage — the OAuth 'error' query parameter is attacker/
# Spotify controlled and must not be reflected unescaped (Rule 2, XSS).
# ============================================================
sub _htmlEscape {
    my ($s) = @_;
    return '' unless defined $s;
    $s =~ s/&/&amp;/g;
    $s =~ s/</&lt;/g;
    $s =~ s/>/&gt;/g;
    $s =~ s/"/&quot;/g;
    return $s;
}

# ============================================================
# _renderPkceResultPage($httpClient, $response, $title, $message, $isError)
# Renders a minimal centered-card HTML result page for the /pkce/callback
# browser redirect flow. This page is opened via window.open() as a popup/
# new tab and has no LMS navigation frame, so on success it self-closes
# (window.close()) after 2 seconds instead of redirecting itself to Settings
# -- a self-redirect here would strand the user on a bare Settings page
# without the Material Skin wrapper. Error pages show a link back to
# Settings instead (the user may need to read the error before leaving).
#
# D-06 (forum #257): Classic Skin's ORIGINAL Settings tab (window.opener --
# same-origin, since it's the LMS host that opened this popup) does not
# auto-refresh after OAuth completes, leaving it showing stale
# not-connected state until the user manually reloads. On success we
# navigate window.opener to the Settings page (triggering a fresh render
# with the new account state) before self-closing this popup. Material
# Skin already refreshes its own Settings view via AJAX, so the extra
# opener navigation is harmless there.
# ============================================================
sub _renderPkceResultPage {
    my ($httpClient, $response, $title, $message, $isError) = @_;

    my $safeTitle   = _htmlEscape($title);
    my $safeMessage = _htmlEscape($message);
    my $settingsUrl = '/' . SETTINGS_URL;

    my $action = $isError
        ? qq{<p><a href="$settingsUrl">} . _htmlEscape(string('PLUGIN_SPOTON_NAME')) . qq{</a></p>}
        : qq{<script>
setTimeout(function() {
    try {
        if (window.opener && !window.opener.closed) {
            window.opener.location.href = "$settingsUrl";
        }
    } catch (e) {}
    try { window.close(); } catch (e) {}
}, 2000);
</script>
<p style="color:#b3b3b3; font-size:0.9em">This tab will close automatically and your SpotOn Settings page will refresh. If not, close it manually and refresh Settings yourself.</p>};

    my $html = qq{<!DOCTYPE html>
<html>
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>$safeTitle</title>
$action
<style>
  body { font-family: -apple-system, Helvetica, Arial, sans-serif; background: #191414;
         color: #fff; display: flex; align-items: center; justify-content: center;
         min-height: 100vh; margin: 0; }
  .card { background: #282828; border-radius: 12px; padding: 2em 2.5em; max-width: 420px;
          text-align: center; }
  a { color: #1db954; }
</style>
</head>
<body>
  <div class="card">
    <h2>$safeTitle</h2>
    <p>$safeMessage</p>
  </div>
</body>
</html>
};

    my $bytes = encode('UTF-8', $html);
    $response->header('Content-Length' => length($bytes));
    $response->code($isError ? 400 : 200);
    $response->header('Connection' => 'close');
    $response->content_type('text/html; charset=utf-8');
    Slim::Web::HTTP::addHTTPResponse($httpClient, $response, \$bytes);
}

# ============================================================
# Diagnostic bundle endpoint (#3): /plugins/SpotOn/settings/diagnosticBundle
# Returns a downloadable text file with system info + daemon logs.
# Only works when diagnosticMode pref is enabled (403 otherwise).
# ============================================================
sub _diagnosticBundleHandler {
    my ($httpClient, $response) = @_;

    unless ($prefs->get('diagnosticMode')) {
        _jsonResponse($httpClient, $response, { error => 'Diagnostic mode not enabled' }, 403);
        return;
    }

    my $serverPrefs = preferences('server');
    my $spotonDir   = catdir($serverPrefs->get('cachedir'), 'spoton');

    # Collect all daemon logs (connect + unified)
    my @logFiles = (
        bsd_glob(catfile($spotonDir, '*-connect.log')),
        bsd_glob(catfile($spotonDir, '*-unified.log')),
    );

    # Build header with system info
    my $activeId = $prefs->get('activeAccount') || '';
    my $redactedId = $activeId ? substr($activeId, 0, 4) . '****' : 'none';
    my $clientId = $prefs->get('clientId') || '';
    my $redactedClientId = $clientId ? substr($clientId, 0, 4) . '****' : 'none';

    my @playerList;
    for my $c (Slim::Player::Client::clients()) {
        push @playerList, sprintf('  %s | %s | %s', $c->name, $c->id, $c->model);
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
        "Bitrate: " . ($prefs->get('bitrate') || 320),
        "Normalization: " . ($prefs->get('normalization') ? 'on' : 'off'),
        "Client-ID: $redactedClientId",
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
        require Plugins::SpotOn::API::Client;
        my $snapshot = Plugins::SpotOn::API::Client->statusSnapshot() || {};
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
        $logs .= _readLogTail($logFile, $maxBytes);
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
            $logs .= join('', @spotonLines) || "(no SpotOn entries found)\n";
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
# Deletes all *-connect.log files in the spoton cache directory.
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
    );

    my $deleted = 0;
    for my $logFile (@logFiles) {
        if (unlink $logFile) {
            $deleted++;
        } else {
            $log->warn("clearLogs: failed to delete $logFile: $!");
        }
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
