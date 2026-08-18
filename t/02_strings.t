#!/usr/bin/perl
use strict;
use warnings;
use Test::More;
use File::Basename qw(dirname);
use Cwd qw(abs_path);

# Resolve the project root: t/ is directly under the project root
my $test_dir     = dirname(abs_path($0));
my $project_dir  = dirname($test_dir);
my $strings_file = "$project_dir/Plugins/SpotOn/strings.txt";

ok(-f $strings_file, "strings.txt exists at $strings_file");

SKIP: {
    skip "strings.txt not found", 1 unless -f $strings_file;

    open(my $fh, '<:encoding(UTF-8)', $strings_file)
        or die "Cannot open $strings_file: $!";
    my $content = do { local $/; <$fh> };
    close($fh);

    # Required keys that must have both EN and DE
    # Updated in Plan 04.3-03: PKCE strings removed, ZeroConf strings added
    my @bilingual_keys = qw(
        PLUGIN_SPOTON
        PLUGIN_SPOTON_NAME
        PLUGIN_SPOTON_BINARY_MISSING
        PLUGIN_SPOTON_BINARY_STATUS
        PLUGIN_SPOTON_ACCOUNT_SETTINGS
        PLUGIN_SPOTON_BITRATE
        PLUGIN_SPOTON_ACTIVE_ACCOUNT
        PLUGIN_SPOTON_RATE_LIMIT_HINT
        PLUGIN_SPOTON_ACCOUNT_NONE
        PLUGIN_SPOTON_ACCOUNT_ACTIVE
        PLUGIN_SPOTON_ACCOUNT_SWITCH
        PLUGIN_SPOTON_ACCOUNT_REMOVE
        PLUGIN_SPOTON_AUTH_ERROR
        PLUGIN_SPOTON_ADD_ANOTHER
        PLUGIN_SPOTON_CONNECTED_AS
        PLUGIN_SPOTON_ACCOUNT_REMOVE_CONFIRM
        PLUGIN_SPOTON_STEP1_TITLE
        PLUGIN_SPOTON_STEP2_TITLE
        PLUGIN_SPOTON_ZEROCONF_SETUP
        PLUGIN_SPOTON_ZEROCONF_STEP1
        PLUGIN_SPOTON_ZEROCONF_INSTRUCTIONS
        PLUGIN_SPOTON_WAITING_FOR_CONNECTION
        PLUGIN_SPOTON_START_DISCOVERY
        PLUGIN_SPOTON_STOP_DISCOVERY
        PLUGIN_SPOTON_CONNECT_HINT_ALT
        PLUGIN_SPOTON_NORMALIZATION
        PLUGIN_SPOTON_NORMALIZATION_DESC
        PLUGIN_SPOTON_NORMALIZATION_LABEL
        PLUGIN_SPOTON_LIKE
        PLUGIN_SPOTON_UNLIKE
        PLUGIN_SPOTON_ACCOUNT_SWITCHED
        PLUGIN_SPOTON_LIKED
        PLUGIN_SPOTON_UNLIKED
        PLUGIN_SPOTON_LIKE_ERROR
        PLUGIN_SPOTON_LIKE_ERROR_SCOPE
        PLUGIN_SPOTON_MANAGE_LIKE
        PLUGIN_SPOTON_HOME
        PLUGIN_SPOTON_SEARCH
        PLUGIN_SPOTON_LIBRARY
        PLUGIN_SPOTON_ALBUMS
        PLUGIN_SPOTON_ARTISTS
        PLUGIN_SPOTON_PLAYLISTS
        PLUGIN_SPOTON_LIKED_SONGS
        PLUGIN_SPOTON_RECENTLY_PLAYED
        PLUGIN_SPOTON_MADE_FOR_YOU
        PLUGIN_SPOTON_TOP_TRACKS
        PLUGIN_SPOTON_NO_RESULTS
        PLUGIN_SPOTON_TRACKS
        PLUGIN_SPOTON_TOP_RESULT
        PLUGIN_SPOTON_SINGLES
        PLUGIN_SPOTON_COMPILATIONS
        PLUGIN_SPOTON_APPEARS_ON
        PLUGIN_SPOTON_ARTIST_VIEW
        PLUGIN_SPOTON_ALBUM_VIEW
        PLUGIN_SPOTON_PODCASTS
        PLUGIN_SPOTON_MY_PODCASTS
        PLUGIN_SPOTON_PODCAST_SEARCH
        PLUGIN_SPOTON_SHOWS
        PLUGIN_SPOTON_EPISODES
        PLUGIN_SPOTON_N_RESULTS
        PLUGIN_SPOTON_MANAGE_FOLLOW
        PLUGIN_SPOTON_FOLLOW_SHOW
        PLUGIN_SPOTON_UNFOLLOW_SHOW
        PLUGIN_SPOTON_SHOW_FOLLOWED
        PLUGIN_SPOTON_SHOW_UNFOLLOWED
        PLUGIN_SPOTON_SHOW_ACTION_ERROR
        PLUGIN_SPOTON_SHOW_VIEW
        PLUGIN_SPOTON_DURATION_HM
        PLUGIN_SPOTON_DURATION_M
        PLUGIN_SPOTON_DATE_TODAY
        PLUGIN_SPOTON_DATE_YESTERDAY
        PLUGIN_SPOTON_DATE_N_DAYS_AGO
        PLUGIN_SPOTON_MONTH_1
        PLUGIN_SPOTON_MONTH_2
        PLUGIN_SPOTON_MONTH_3
        PLUGIN_SPOTON_MONTH_4
        PLUGIN_SPOTON_MONTH_5
        PLUGIN_SPOTON_MONTH_6
        PLUGIN_SPOTON_MONTH_7
        PLUGIN_SPOTON_MONTH_8
        PLUGIN_SPOTON_MONTH_9
        PLUGIN_SPOTON_MONTH_10
        PLUGIN_SPOTON_MONTH_11
        PLUGIN_SPOTON_MONTH_12
        PLUGIN_SPOTON_EXPLICIT
        PLUGIN_SPOTON_RESUME_UNPLAYED
        PLUGIN_SPOTON_RESUME_IN_PROGRESS
        PLUGIN_SPOTON_RESUME_FINISHED
        PLUGIN_SPOTON_PKCE_AUTH
        PLUGIN_SPOTON_PKCE_AUTH_DESC
        PLUGIN_SPOTON_PKCE_CONNECT_BTN
        PLUGIN_SPOTON_PKCE_NEEDS_CLIENT_ID
        PLUGIN_SPOTON_PKCE_OPENING
        PLUGIN_SPOTON_PKCE_SUCCESS
        PLUGIN_SPOTON_PKCE_ERROR
        PLUGIN_SPOTON_PKCE_MANUAL_TITLE
        PLUGIN_SPOTON_PKCE_MANUAL_DESC
        PLUGIN_SPOTON_PKCE_MANUAL_BTN
        PLUGIN_SPOTON_PKCE_REDIRECT_NOTE
        PLUGIN_SPOTON_SETUP_PKCE_TITLE
        PLUGIN_SPOTON_SETUP_PKCE_DESC
        PLUGIN_SPOTON_REAUTH_REQUIRED
        PLUGIN_SPOTON_REAUTH_REQUIRED_SETTINGS
        PLUGIN_SPOTON_NEW_SEARCH
        PLUGIN_SPOTON_CLEAR_SEARCH_HISTORY
        PLUGIN_SPOTON_PLAYER_AUTH_TITLE
        PLUGIN_SPOTON_PLAYER_AUTH_DESC
        PLUGIN_SPOTON_PLAYER_AUTH_BANNER
        PLUGIN_SPOTON_PLAYER_AUTH_STATUS_OK
        PLUGIN_SPOTON_PLAYER_AUTH_STATUS_REQUIRED
        PLUGIN_SPOTON_PLAYER_AUTH_INSTRUCTIONS
        PLUGIN_SPOTON_PLAYER_AUTH_START_BTN
        PLUGIN_SPOTON_PLAYER_AUTH_CANCEL_BTN
        PLUGIN_SPOTON_PLAYER_AUTH_WAITING
        PLUGIN_SPOTON_PLAYER_AUTH_SUCCESS
        PLUGIN_SPOTON_PLAYER_AUTH_FAILED
        PLUGIN_SPOTON_PLAYER_AUTH_TIMEOUT
        PLUGIN_SPOTON_PLAYER_AUTH_MISMATCH
        PLUGIN_SPOTON_PLAYBACK_AUTH_REQUIRED
        PLUGIN_SPOTON_PLAYER_AUTH_BROWSER_TITLE
        PLUGIN_SPOTON_PLAYER_AUTH_BROWSER_DESC
        PLUGIN_SPOTON_PLAYER_AUTH_BROWSER_START_BTN
        PLUGIN_SPOTON_PLAYER_AUTH_BROWSER_PASTE_HINT
        PLUGIN_SPOTON_PLAYER_AUTH_BROWSER_SUBMIT_BTN
        PLUGIN_SPOTON_PLAYER_AUTH_BROWSER_FAILED
        PLUGIN_SPOTON_CUSTOM_APP_TITLE
        PLUGIN_SPOTON_CUSTOM_APP_SETUP
        PLUGIN_SPOTON_BUNDLED_SHARED_QUOTA_HINT
        PLUGIN_SPOTON_CUSTOM_QUOTA_OK
        PLUGIN_SPOTON_DEFAULT_AUTH_INFO
        PLUGIN_SPOTON_SETTINGS_ACCOUNT_SECTION
        PLUGIN_SPOTON_SETUP_SPDC_TITLE
        PLUGIN_SPOTON_SETUP_SPDC_DESC
        PLUGIN_SPOTON_SETUP_PATHFINDER_TITLE
        PLUGIN_SPOTON_SETUP_PATHFINDER_DESC
        PLUGIN_SPOTON_PLAYER_AUTH_SOURCE_ZEROCONF
        PLUGIN_SPOTON_PLAYER_AUTH_SOURCE_BROWSER
    );

    # Obsolete keys that must NOT be present
    # Phase 02.1 cleanup (username/password flow removed):
    my @removed_keys = qw(
        PLUGIN_SPOTON_ACCOUNT_USERNAME
        PLUGIN_SPOTON_ACCOUNT_PASSWORD
        PLUGIN_SPOTON_ACCOUNT_ADD
        PLUGIN_SPOTON_ACCOUNT_ADD_BTN
    );

    # Plan 04.3-03 cleanup (PKCE/OAuth flow removed):
    my @pkce_removed_keys = qw(
        PLUGIN_SPOTON_SETUP_WIZARD
        PLUGIN_SPOTON_STEP1_BODY
        PLUGIN_SPOTON_DASHBOARD_LINK
        PLUGIN_SPOTON_CLIENT_ID_LABEL
        PLUGIN_SPOTON_CLIENT_ID_HINT
        PLUGIN_SPOTON_CONNECT_BTN
        PLUGIN_SPOTON_SETUP_HINT
        PLUGIN_SPOTON_AUTH_STATE_ERROR
        PLUGIN_SPOTON_AUTH_DENIED
        PLUGIN_SPOTON_AUTH_SUCCESS
        PLUGIN_SPOTON_AUTH_REDIRECT
        PLUGIN_SPOTON_AUTH_FAILED
        PLUGIN_SPOTON_BACK_TO_SETTINGS
        PLUGIN_SPOTON_CLIENT_ID_REQUIRED
        PLUGIN_SPOTON_OPEN_SPOTIFY
        PLUGIN_SPOTON_OPEN_SPOTIFY_HINT
        PLUGIN_SPOTON_CLOSE_TAB
    );

    # Keys that only require EN (format identifiers etc.)
    my @en_only_keys = qw(
    );

    # Build lookup of what exists
    # strings.txt format: KEY\n\tEN\tvalue\n\tDE\tvalue\n
    my %has_en;
    my %has_de;

    # Parse each line
    my $current_key = '';
    for my $line (split /\n/, $content) {
        if ($line =~ /^([A-Z][A-Z0-9_]+)\s*$/) {
            $current_key = $1;
        } elsif ($line =~ /^\t(EN|DE)\t(.+)$/) {
            my ($lang, $val) = ($1, $2);
            if ($lang eq 'EN') {
                $has_en{$current_key} = 1;
            } elsif ($lang eq 'DE') {
                $has_de{$current_key} = 1;
            }
        }
    }

    # Verify bilingual keys
    for my $key (@bilingual_keys) {
        ok($has_en{$key}, "$key has EN translation");
        ok($has_de{$key}, "$key has DE translation");
    }

    # Verify EN-only keys
    for my $key (@en_only_keys) {
        ok($has_en{$key}, "$key has EN translation");
    }

    # Verify obsolete Phase 02.1 keys are removed
    for my $key (@removed_keys) {
        ok(!$has_en{$key} && !$has_de{$key}, "$key is removed (obsolete in Phase 02.1)");
    }

    # Verify PKCE/OAuth keys removed in Plan 04.3-03
    for my $key (@pkce_removed_keys) {
        ok(!$has_en{$key} && !$has_de{$key}, "$key is removed (PKCE flow removed in Plan 04.3-03)");
    }

    # Plan 65-04: the bundled-mode info line is obsolete — the default PKCE
    # identity is no longer a shared community Client ID, and the template
    # now shows PLUGIN_SPOTON_DEFAULT_AUTH_INFO instead.
    ok(!$has_en{'PLUGIN_SPOTON_BUNDLED_MODE_INFO'} && !$has_de{'PLUGIN_SPOTON_BUNDLED_MODE_INFO'},
        'PLUGIN_SPOTON_BUNDLED_MODE_INFO is removed (Keymaster default, Plan 65-04)');

    # Plan 66-03: the 66-02 Settings reorg removed the standalone Browse-setup
    # and Made-For-You-setup guide steps and the custom-Developer-App title
    # (the reworded guide now covers account + playback + sp_dc + Pathfinder
    # in four steps; the Custom App section is header-less inside details).
    my @phase66_removed_keys = qw(
        PLUGIN_SPOTON_SETUP_BROWSE_TITLE
        PLUGIN_SPOTON_SETUP_BROWSE_DESC
        PLUGIN_SPOTON_SETUP_DEVAPP_TITLE
        PLUGIN_SPOTON_MADE_FOR_YOU_SECTION
        PLUGIN_SPOTON_CONNECT_DERIVE_FAILED
    );
    for my $key (@phase66_removed_keys) {
        ok(!$has_en{$key} && !$has_de{$key},
            "$key is removed (Settings reorg, Plan 66-03)");
    }

    # Verify correct indentation: lines must use Tab, not spaces
    my $bad_indent = 0;
    for my $line (split /\n/, $content) {
        # Translation lines should start with \t followed by language code
        if ($line =~ /^ +(?:EN|DE)\t/) {
            $bad_indent++;
        }
    }
    is($bad_indent, 0, "All translation lines use Tab indentation (not spaces)");

    # Permanent regression test (Phase 53 D-15/D-16): the Keymaster HTTP
    # service is fully removed from the auth architecture (PKCE-only). No
    # translation value may reintroduce a "keymaster" reference. This checks
    # translation VALUES only (lines matching \tLANG\ttext), not key names,
    # so a future Keymaster-named key would not itself trip this assertion --
    # it targets user-facing string content specifically.
    my @keymaster_hits;
    for my $line (split /\n/, $content) {
        if ($line =~ /^\t[A-Z]{2}\t(.+)$/ && $1 =~ /keymaster/i) {
            push @keymaster_hits, $line;
        }
    }
    is(scalar(@keymaster_hits), 0,
        "No translation value references 'keymaster' (Phase 53 permanent regression guard)")
        or diag("Found keymaster reference(s): " . join("; ", @keymaster_hits));
}

done_testing();
