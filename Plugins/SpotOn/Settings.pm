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
use Plugins::SpotOn::Helper;

use constant SETTINGS_URL => 'plugins/SpotOn/settings/basic.html';

my $log   = Slim::Utils::Log->logger('plugin.spoton');
my $prefs = preferences('plugin.spoton');

sub new {
    my $class = shift;
    my $self  = $class->SUPER::new(@_);

    # Register AJAX discoveryStatus endpoint (addRawFunction pattern from Spotty/Settings/Auth.pm)
    require Slim::Web::Pages;
    Slim::Web::Pages->addRawFunction(
        'plugins/SpotOn/settings/discoveryStatus',
        \&_discoveryStatusHandler
    );

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

    # Register AJAX discovery start/stop endpoints (ZC-01)
    Slim::Web::Pages->addRawFunction(
        'plugins/SpotOn/settings/discovery/start',
        \&_discoveryStartHandler
    );
    Slim::Web::Pages->addRawFunction(
        'plugins/SpotOn/settings/discovery/stop',
        \&_discoveryStopHandler
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
    # clientId is saved manually with sanitization in handler() — not listed here
    # to prevent Slim::Web::Settings::handler from overwriting with raw form input.
    return ($prefs, 'bitrate', 'binary', 'normalization', 'diagnosticMode');
}

sub handler {
    my ($class, $client, $paramRef, $callback, $httpClient, $response) = @_;

    my ($helperPath, $helperVersion) = Plugins::SpotOn::Helper->get();

    # Pass binary status to template
    $paramRef->{helperMissing} = string('PLUGIN_SPOTON_BINARY_MISSING') unless $helperPath;
    $paramRef->{binaryVersion} = $helperVersion || '';
    $paramRef->{binaryPath}    = $helperPath    || '';
    $paramRef->{isMac}         = main::ISMAC ? 1 : 0;

    if ($paramRef->{saveSettings}) {
        my %valid_bitrates = map { $_ => 1 } (96, 160, 320);
        my $bitrate = $paramRef->{'pref_bitrate'} // 320;
        $bitrate = 320 unless $valid_bitrates{$bitrate};
        $prefs->set('bitrate', $bitrate);

        # Save normalization pref (STR-08, T-04-05)
        # Checkbox: browser sends no value when unchecked — treat undef/empty as 0
        my $norm = $paramRef->{'pref_normalization'} ? 1 : 0;
        $prefs->set('normalization', $norm);

        # Save Client-ID pref (D-02, T-04.4-01)
        # T-04.4-01: Input validation — alphanumeric only, max 32 chars.
        # Spotify Client-IDs are exactly 32 hex chars — regex + length check
        # eliminates shell metacharacter injection vectors for --client-id flag.
        if (defined $paramRef->{pref_clientId}) {
            my $id = $paramRef->{pref_clientId} // '';
            $id =~ s/[^a-zA-Z0-9]//g;  # T-04.4-01: alphanumeric only (injection guard)
            $id = substr($id, 0, 32);   # T-04.4-01: max 32 chars (Spotify Client-ID format)
            $prefs->set('clientId', $id);
        }

        # Discovery start/stop moved to AJAX endpoints (_discoveryStartHandler,
        # _discoveryStopHandler) to avoid "changes saved" banner on form POST.

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
            }
        }

        # Save diagnosticMode (global pref, not per-player) (#3)
        my $diagMode = $paramRef->{'pref_diagnosticMode'} ? 1 : 0;
        $prefs->set('diagnosticMode', $diagMode);
    }

    # Auto-setup fallback for GET requests (manual reload, first visit).
    # The primary check runs earlier (before startDiscovery) for POST requests.
    my $serverPrefs = preferences('server');
    my $discoverCredsFile = catfile(
        $serverPrefs->get('cachedir'), 'spoton', '__DISCOVER__', 'credentials.json');

    if (-f $discoverCredsFile) {
        require Plugins::SpotOn::API::TokenManager;
        Plugins::SpotOn::API::TokenManager->stopDiscovery();
        _autoSetupAccount($discoverCredsFile, $serverPrefs);
    }

    # Pass account and discovery data to template for all requests
    $paramRef->{accounts}         = $prefs->get('accounts') || {};
    $paramRef->{activeAccount}    = $prefs->get('activeAccount') || '';
    $paramRef->{discoveryRunning} = _isDiscoveryRunning() ? 1 : 0;

    # Client-ID and degraded-mode status for template (D-02, D-03)
    $paramRef->{customClientId} = $prefs->get('clientId') || '';
    $paramRef->{degradedMode}   = _isDegradedMode();

    # Diagnostic mode status for template (#3)
    $paramRef->{diagnosticEnabled} = $prefs->get('diagnosticMode') ? 1 : 0;

    my $logTotal = 0;
    my $spotonDir = catdir($serverPrefs->get('cachedir'), 'spoton');
    for my $pattern ('*-connect.log', '*-unified.log', 'browse-errors.log') {
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
# Auto-setup: synchronous account creation from __DISCOVER__/credentials.json.
# Reads credentials, derives accountId, renames dir, stores prefs immediately.
# Display name is fetched asynchronously afterwards (may update on next page load).
# ============================================================
sub _autoSetupAccount {
    my ($credsFile, $serverPrefs) = @_;

    open(my $fh, '<', $credsFile) or do {
        $log->error("Settings: cannot read $credsFile: $!");
        return;
    };
    local $/;
    my $json = <$fh>;
    close $fh;

    my $creds = eval { from_json($json) };
    if ($@ || !$creds->{username}) {
        $log->error("Settings: credentials.json parse failed: $@");
        return;
    }

    my $username  = $creds->{username};
    my $accountId = substr(md5_hex($username), 0, 8);
    my $baseDir   = catdir($serverPrefs->get('cachedir'), 'spoton');
    my $discoverDir = catdir($baseDir, '__DISCOVER__');
    my $finalDir    = catdir($baseDir, $accountId);

    if (-d $finalDir) {
        require File::Path;
        File::Path::remove_tree($finalDir);
    }
    require File::Copy;
    File::Copy::move($discoverDir, $finalDir) or do {
        $log->error("Settings: dir rename __DISCOVER__ -> $accountId failed: $!");
        return;
    };
    chmod(0700, $finalDir);

    my $accounts = $prefs->get('accounts') || {};
    $accounts->{$accountId} = {
        displayName   => $username,
        spotifyUserId => $username,
    };
    $prefs->set('accounts', $accounts);

    unless ($prefs->get('activeAccount')) {
        $prefs->set('activeAccount', $accountId);

        require Plugins::SpotOn::Unified::DaemonManager;
        Plugins::SpotOn::Unified::DaemonManager->scheduleInit();
    }

    $log->info("Settings: account $accountId created from ZeroConf discovery (user=$username)");

    # Fire async /me fetch to get the real display name
    Plugins::SpotOn::API::TokenManager->_fetchDisplayName(
        $accountId, $username, sub { });
}

# ============================================================
# AJAX endpoint: /plugins/SpotOn/settings/discoveryStatus
# Returns JSON with status: 'connected' | 'waiting' | 'idle'
# Source pattern: Spotty/Settings/Auth.pm::checkCredentials (addRawFunction pattern)
# ============================================================
sub _discoveryStatusHandler {
    my ($httpClient, $response) = @_;

    my $serverPrefs = preferences('server');
    my $discoverDir = catdir($serverPrefs->get('cachedir'), 'spoton', '__DISCOVER__');
    my $credsFile   = catfile($discoverDir, 'credentials.json');

    my $result;
    if (-f $credsFile) {
        $result = { status => 'connected' };
    } elsif (_isDiscoveryRunning()) {
        $result = { status => 'waiting' };
    } else {
        $result = { status => 'idle' };
    }

    _jsonResponse($httpClient, $response, $result);
}

# ============================================================
# AJAX endpoint: /plugins/SpotOn/settings/discovery/start
# Starts ZeroConf discovery without form POST (no "changes saved" banner).
# ============================================================
sub _discoveryStartHandler {
    my ($httpClient, $response) = @_;

    return unless _csrfCheck($httpClient, $response);

    require Plugins::SpotOn::API::TokenManager;
    Plugins::SpotOn::API::TokenManager->startDiscovery();

    _jsonResponse($httpClient, $response, { status => 'ok' });
}

# ============================================================
# AJAX endpoint: /plugins/SpotOn/settings/discovery/stop
# Stops ZeroConf discovery without form POST.
# ============================================================
sub _discoveryStopHandler {
    my ($httpClient, $response) = @_;

    return unless _csrfCheck($httpClient, $response);

    require Plugins::SpotOn::API::TokenManager;
    Plugins::SpotOn::API::TokenManager->stopDiscovery();

    _jsonResponse($httpClient, $response, { status => 'ok' });
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

    $logs .= "--- Browse Errors ---\n";
    my $browseErrLog = catfile($spotonDir, 'browse-errors.log');
    if (-f $browseErrLog && -s $browseErrLog) {
        $logs .= _readLogTail($browseErrLog, $maxBytes);
    } else {
        $logs .= "(no browse error log found)\n";
    }
    $logs .= "\n";

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

    # Also delete browse-errors.log if present
    my $browseErrLog = catfile($spotonDir, 'browse-errors.log');
    if (-f $browseErrLog) {
        if (unlink $browseErrLog) {
            $deleted++;
        } else {
            $log->warn("clearLogs: failed to delete browse-errors.log: $!");
        }
    }

    main::INFOLOG && $log->is_info && $log->info("clearLogs: deleted $deleted log file(s)");

    _jsonResponse($httpClient, $response, { status => 'ok', deleted => $deleted });
}

sub _jsonResponse {
    my ($httpClient, $response, $data, $code) = @_;
    $code //= 200;
    my $bytes = encode('UTF-8', to_json($data));
    $response->header('Content-Length' => length($bytes));
    $response->code($code);
    $response->header('Connection' => 'close');
    $response->content_type('application/json');
    Slim::Web::HTTP::addHTTPResponse($httpClient, $response, \$bytes);
}

# ============================================================
# Helper: check degraded mode (D-03)
# Degraded = no custom Client-ID configured.
# Shows a hint in Settings so the user can enter their own Spotify Developer App.
# Analogous to _isDiscoveryRunning below.
# ============================================================
sub _isDegradedMode {
    my $customId = $prefs->get('clientId') || '';
    return $customId ? 0 : 1;
}

# ============================================================
# Helper: check if ZeroConf discovery process is alive
# Delegates to TokenManager which owns the $discoveryProc package var
# ============================================================
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

sub _isDiscoveryRunning {
    # Lazy-load TokenManager to avoid circular dependency issues at startup
    # If TokenManager is not loaded yet, discovery is not running
    return 0 unless $INC{'Plugins/SpotOn/API/TokenManager.pm'};
    return Plugins::SpotOn::API::TokenManager->isDiscoveryRunning();
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
