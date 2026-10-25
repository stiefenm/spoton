#!/usr/bin/perl
use strict;
use warnings;
use Test::More;
use File::Basename qw(dirname);
use Cwd qw(abs_path);

# Resolve the project root (t/<group>/x.t sits two levels below it)
my $test_dir     = dirname(abs_path($0));
my $project_dir  = dirname(dirname($test_dir));   # t/<group>/x.t -> repo root
die "wrong project root: $project_dir" unless -f "$project_dir/Plugins/SpotOn/Plugin.pm";
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
        PLUGIN_SPOTON_MFY_FALLBACK
        PLUGIN_SPOTON_MFY_HASH_BROKEN
        PLUGIN_SPOTON_TOP_TRACKS_UNAVAILABLE
        PLUGIN_SPOTON_SEARCH_LIMITED
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
        PLUGIN_SPOTON_NEW_SEARCH
        PLUGIN_SPOTON_CLEAR_SEARCH_HISTORY
        PLUGIN_SPOTON_PLAYER_AUTH_INSTRUCTIONS
        PLUGIN_SPOTON_PLAYER_AUTH_CANCEL_BTN
        PLUGIN_SPOTON_PLAYER_AUTH_FAILED
        PLUGIN_SPOTON_SETTINGS_ACCOUNT_SECTION
        PLUGIN_SPOTON_SETTINGS_BACKEND_SECTION
        PLUGIN_SPOTON_SOLOIST_PAIRED
        PLUGIN_SPOTON_SOLOIST_NOT_PAIRED
        PLUGIN_SPOTON_SOLOIST_PAIR_HOWTO
        PLUGIN_SPOTON_STEP_ACCOUNT_TITLE
        PLUGIN_SPOTON_STEP_PLAYER_TITLE
        PLUGIN_SPOTON_STEP_WHY_TWO
        PLUGIN_SPOTON_STEP_PLAYER_NOT_NEEDED
        PLUGIN_SPOTON_ACCOUNT_PAIR_BUTTON
        PLUGIN_SPOTON_ACCOUNT_PAIR_WAITING
        PLUGIN_SPOTON_ACCOUNT_PAIR_SUCCESS
        PLUGIN_SPOTON_ACCOUNT_PAIR_TIMEOUT
        PLUGIN_SPOTON_ACCOUNT_PAIR_JUST_PAIRED
        PLUGIN_SPOTON_ACCOUNT_NEEDS_PAIRING
        PLUGIN_SPOTON_DISCOVER_IMPORTED
        PLUGIN_SPOTON_DISCOVER_INVALID
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
    my %key_seen;    # every KEY header line, whatever languages it carries

    # Parse each line
    my $current_key = '';
    for my $line (split /\n/, $content) {
        if ($line =~ /^([A-Z][A-Z0-9_]+)\s*$/) {
            $current_key = $1;
            $key_seen{$1} = 1;
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

    # 85-12 (decision-D17 pathfinder-login5-plus-rootlist, cookie-free; D-19): the sp_dc
    # field, its setup-guide step, the dashboard line, the secrets-down hint and the manual
    # Pathfinder hash field + setup-guide step are gone -- 18 keys, none referenced under
    # Plugins/SpotOn any more.
    my @phase85_removed_keys = map { "PLUGIN_SPOTON_$_" } qw(
        DASHBOARD_SPDC SETUP_SPDC_TITLE SETUP_SPDC_DESC SETUP_PATHFINDER_TITLE SETUP_PATHFINDER_DESC
        SP_DC SP_DC_DESC SP_DC_HOWTO_TITLE SP_DC_HOWTO SP_DC_STATUS_VALID SP_DC_STATUS_EXPIRED
        SP_DC_STATUS_EMPTY SP_DC_EXPIRED_HINT MFY_SECRETS_DOWN
        PATHFINDER_HASH PATHFINDER_HASH_DESC PATHFINDER_HASH_HOWTO_TITLE PATHFINDER_HASH_HOWTO
    );
    is(scalar(@phase85_removed_keys), 18, '85-12: the removed-keys list holds 18 keys');
    for my $key (@phase85_removed_keys) {
        ok(!$has_en{$key} && !$has_de{$key} && !$key_seen{$key},
            "$key is removed (cookie-free, 85-12)");
    }

    # 85-14 (D-01, D-02): the PKCE flow, the Client-ID field and wizard, the re-auth and v2.x
    # migration hints, the Keymaster browser fallback, the quota hints and the old playback-
    # authorization page are gone -- 61 keys, none referenced under Plugins/SpotOn any more
    # (checked per key with `command grep -rn <KEY> Plugins/SpotOn --include=*.pm --include=*.html`).
    # PLUGIN_SPOTON_ADD_ANOTHER stays: t/core/09 pins it and it is no PKCE string.
    my @phase85_pkce_removed_keys = map { "PLUGIN_SPOTON_$_" } qw(
        AUTH_REQUIRED BUNDLED_ID_REVOKED BUNDLED_SHARED_QUOTA_HINT CLIENT_ID_DESC CLIENT_ID_PLACEHOLDER
        CLIENT_ID_REAUTH_HINT CLIENT_ID_SETTINGS CLIENT_ID_WIZARD_TITLE CUSTOM_APP_REMOVE
        CUSTOM_APP_SETUP CUSTOM_APP_TITLE CUSTOM_QUOTA_OK DASHBOARD_MIGRATION DASHBOARD_MIGRATION_DONE
        DASHBOARD_MIGRATION_NEEDED DASHBOARD_PKCE DASHBOARD_PKCE_OK DASHBOARD_PKCE_REAUTH
        DEGRADED_MODE_WARNING MIGRATION_REQUIRED MIGRATION_SETTINGS_HINT PKCE_AUTH PKCE_AUTH_DESC
        PKCE_CONNECT_BTN PKCE_ERROR PKCE_MANUAL_BTN PKCE_MANUAL_DESC PKCE_MANUAL_TITLE
        PKCE_NEEDS_CLIENT_ID PKCE_OPENING PKCE_POPUP_NOTE PKCE_REAUTH_BANNER PKCE_SUCCESS
        PLAYBACK_AUTH_REQUIRED PLAYER_AUTH_BANNER PLAYER_AUTH_BROWSER_DESC PLAYER_AUTH_BROWSER_FAILED
        PLAYER_AUTH_BROWSER_PASTE_HINT PLAYER_AUTH_BROWSER_START_BTN PLAYER_AUTH_BROWSER_SUBMIT_BTN
        PLAYER_AUTH_BROWSER_TITLE PLAYER_AUTH_DESC PLAYER_AUTH_MISMATCH PLAYER_AUTH_SOURCE_BROWSER
        PLAYER_AUTH_SOURCE_ZEROCONF PLAYER_AUTH_START_BTN PLAYER_AUTH_STATUS_OK
        PLAYER_AUTH_STATUS_REQUIRED PLAYER_AUTH_SUCCESS PLAYER_AUTH_TIMEOUT PLAYER_AUTH_TITLE
        PLAYER_AUTH_WAITING REAUTH_REQUIRED REAUTH_REQUIRED_SETTINGS REGISTER_APP_LINK
        SETUP_DEVAPP_DESC SETUP_GUIDE_TITLE SETUP_PKCE_DESC SETUP_PKCE_TITLE SETUP_PLAYBACK_DESC
        SETUP_PLAYBACK_TITLE
    );
    is(scalar(@phase85_pkce_removed_keys), 61, '85-14: the PKCE removed-keys list holds 61 keys');
    for my $key (@phase85_pkce_removed_keys) {
        ok(!$has_en{$key}, "$key has no EN entry (PKCE flow removed, 85-14)");
        ok(!$has_de{$key}, "$key has no DE entry (PKCE flow removed, 85-14)");
        ok(!$key_seen{$key}, "$key has no key line at all (PKCE flow removed, 85-14)");
    }

    # 85-15 (D-01): PLUGIN_SPOTON_LIKE_ERROR_SCOPE is still read (Plugin.pm, a 403 on a library
    # write), but the OAuth scope / "re-authenticate via Settings" wording is gone -- there is no
    # such path any more; every language now points to the pairing button (ACCOUNT_PAIR_BUTTON).
    {
        my ($like) = $content =~ /^PLUGIN_SPOTON_LIKE_ERROR_SCOPE\n((?:\t[^\n]*\n)+)/m;
        my ($pair) = $content =~ /^PLUGIN_SPOTON_ACCOUNT_PAIR_BUTTON\n((?:\t[^\n]*\n)+)/m;
        ok(defined $like && defined $pair, '85-15: LIKE_ERROR_SCOPE and ACCOUNT_PAIR_BUTTON are both defined');
        my %like = map { /^\t([A-Z]{2})\t(.*)$/ ? ($1 => $2) : () } split /\n/, ($like // '');
        my %pair = map { /^\t([A-Z]{2})\t(.*)$/ ? ($1 => $2) : () } split /\n/, ($pair // '');
        is(scalar(keys %like), 11, '85-15: LIKE_ERROR_SCOPE has all 11 languages');
        my @stale = grep { $like{$_} =~ /user-library-modify|Re-authenticate|scope/i || $like{$_} =~ /Erneut anmelden/ } keys %like;
        is(scalar(@stale), 0, '85-15: LIKE_ERROR_SCOPE no longer names an OAuth scope or a re-authentication via Settings')
            or diag("stale: @stale");
        my @nopair = grep { index($like{$_}, $pair{$_} // "\0") < 0 } keys %like;
        is(scalar(@nopair), 0, '85-15: LIKE_ERROR_SCOPE names the pairing button in every language')
            or diag("no pairing button: @nopair");
    }

    # Phase 67: removed strings
    for my $key (qw(
        PLUGIN_SPOTON_DEFAULT_AUTH_INFO
        PLUGIN_SPOTON_DEVMODE_QUOTA_WARNING
        PLUGIN_SPOTON_PKCE_REDIRECT_NOTE
    )) {
        ok(!$has_en{$key} && !$has_de{$key},
            "$key is removed (Phase 67 Client ID UX cleanup)");
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

    # 85-08 (D-19): the visible Made-for-You / Top-Tracks / search lines exist in all eleven languages.
    my %langs_of;
    my $cur;
    for my $line (split /\n/, $content) {
        if ($line =~ /^(PLUGIN_SPOTON\w*)\s*$/) { $cur = $1; next; }
        $langs_of{$cur}{$1} = $2 if defined $cur && $line =~ /^\t([A-Z]{2})\t(.+)$/;
    }
    for my $key (qw(PLUGIN_SPOTON_MFY_FALLBACK PLUGIN_SPOTON_MFY_HASH_BROKEN PLUGIN_SPOTON_TOP_TRACKS_UNAVAILABLE PLUGIN_SPOTON_SEARCH_LIMITED)) {
        for my $lang (qw(CS DA DE EN ES FR IT NL NO PL SV)) {
            ok(defined $langs_of{$key}{$lang} && length $langs_of{$key}{$lang}, "$key has a $lang translation");
        }
    }

    # 85-11 (D-24, D-02, D-23): the two-step settings page and the __DISCOVER__ notices exist
    # in all eleven languages -- 12 keys, 132 lines. PLUGIN_SPOTON_STEP_ACCOUNT_TITLE and
    # PLUGIN_SPOTON_STEP_PLAYER_TITLE carry the numbered headings; the German wording of the
    # three user-facing anchors is pinned verbatim.
    my @phase85_keys = map { "PLUGIN_SPOTON_$_" } qw(
        STEP_ACCOUNT_TITLE STEP_PLAYER_TITLE STEP_WHY_TWO STEP_PLAYER_NOT_NEEDED
        ACCOUNT_PAIR_BUTTON ACCOUNT_PAIR_WAITING ACCOUNT_PAIR_SUCCESS ACCOUNT_PAIR_TIMEOUT
        ACCOUNT_PAIR_JUST_PAIRED ACCOUNT_NEEDS_PAIRING DISCOVER_IMPORTED DISCOVER_INVALID
    );
    is(scalar(@phase85_keys), 12, '85-11: twelve new keys are pinned');
    for my $key (@phase85_keys) {
        for my $lang (qw(CS DA DE EN ES FR IT NL NO PL SV)) {
            ok(defined $langs_of{$key}{$lang} && length $langs_of{$key}{$lang}, "$key has a $lang translation");
        }
        is(scalar(keys %{ $langs_of{$key} || {} }), 11, "$key has exactly the eleven shipped languages");
    }
    is($langs_of{PLUGIN_SPOTON_STEP_ACCOUNT_TITLE}{DE}, '1. Spotify-Konto koppeln (einmal pro Konto)',
        'D-24: the DE step-1 heading is pinned');
    is($langs_of{PLUGIN_SPOTON_STEP_PLAYER_TITLE}{DE}, '2. Player koppeln (nur Soloist, einmal pro Player)',
        'D-24: the DE step-2 heading is pinned');
    is($langs_of{PLUGIN_SPOTON_ACCOUNT_PAIR_BUTTON}{DE}, 'Konto koppeln', 'D-21: the DE pairing button label is pinned');
    is($langs_of{PLUGIN_SPOTON_ACCOUNT_NEEDS_PAIRING}{DE}, 'Bitte Konto einmal koppeln', 'D-02: the DE needsPairing hint is pinned');
    like($langs_of{PLUGIN_SPOTON_STEP_WHY_TWO}{DE}, qr/Soloist keine Zugangsdaten herausgibt/,
        'D-24: the DE why-two-steps line says Soloist exports no credentials');
    for my $key (qw(PLUGIN_SPOTON_DISCOVER_IMPORTED PLUGIN_SPOTON_DISCOVER_INVALID)) {
        for my $lang (qw(CS DA DE EN ES FR IT NL NO PL SV)) {
            like($langs_of{$key}{$lang} // '', qr/__DISCOVER__/, "$key ($lang) names the __DISCOVER__ folder");
        }
    }
}

# ============================================================
# 74b-02 Task 3 (D-13, D-21, D-01): the format help text promises no 24-bit FLAC,
# no PCM-delivered-as-FLAC note and no bit-exact claim; the FLAC option label
# reads FLAC 16. The eleven old note sentences are captured verbatim (they were
# the shipped help text before this plan) so the guard can fail against them.
# ============================================================
{
    use utf8;
    my $desc_file = "$project_dir/Plugins/SpotOn/strings.txt";
    open(my $dfh, '<:encoding(UTF-8)', $desc_file) or die "Cannot read strings.txt: $!";
    my $dcontent = do { local $/; <$dfh> };
    close($dfh);
    my %v74b;
    my $dcur;
    for my $dl (split /\n/, $dcontent) {
        if ($dl =~ /^(PLUGIN_SPOTON\w*)\s*$/) { $dcur = $1; next; }
        $v74b{$dcur}{$1} = $2 if defined $dcur && $dl =~ /^\t([A-Z]{2})\t(.+)$/;
    }
    my @L = qw(CS DA DE EN ES FR IT NL NO PL SV);

    my %OLD_NOTE = (
        CS => q{Poznámka: na přehrávačích s podporou FLAC je i explicitní volba PCM doručena jako bezeztrátový FLAC (LMS vybírá formáty podle pořadí preferencí přehrávače).},
        DA => q{Bemærk: på FLAC-kompatible afspillere leveres et eksplicit PCM-valg stadig som tabsfri FLAC (LMS vælger formater i afspillerens præferencerækkefølge).},
        DE => q{Hinweis: Auf FLAC-fähigen Playern wird eine explizite PCM-Auswahl dennoch als verlustfreies FLAC ausgeliefert (LMS wählt Formate in der Präferenz-Reihenfolge des Players).},
        EN => q{Note: on FLAC-capable players an explicit PCM selection is still delivered as lossless FLAC (LMS picks formats in the player's preference order).},
        ES => q{Nota: en reproductores compatibles con FLAC, una selección explícita de PCM se entrega igualmente como FLAC sin pérdidas (LMS elige los formatos según el orden de preferencia del reproductor).},
        FR => q{Remarque : sur les lecteurs compatibles FLAC, une sélection PCM explicite est tout de même délivrée en FLAC sans perte (LMS choisit les formats selon l'ordre de préférence du lecteur).},
        IT => q{Nota: sui lettori compatibili FLAC una selezione esplicita di PCM viene comunque consegnata come FLAC senza perdite (LMS sceglie i formati nell'ordine di preferenza del lettore).},
        NL => q{Let op: op FLAC-compatibele spelers wordt een expliciete PCM-keuze toch als verliesvrije FLAC geleverd (LMS kiest formaten in de voorkeursvolgorde van de speler).},
        NO => q{Merk: på FLAC-kompatible spillere leveres et eksplisitt PCM-valg likevel som tapsfri FLAC (LMS velger formater i spillerens preferanserekkefølge).},
        PL => q{Uwaga: na odtwarzaczach obsługujących FLAC jawny wybór PCM i tak jest dostarczany jako bezstratny FLAC (LMS wybiera formaty według kolejności preferencji odtwarzacza).},
        SV => q{Obs: på FLAC-kompatibla spelare levereras ett explicit PCM-val ändå som förlustfri FLAC (LMS väljer format i spelarens preferensordning).},
    );

    my $D = $v74b{PLUGIN_SPOTON_STREAM_FORMAT_DESC} || {};
    is(join(',', sort keys %$D), join(',', @L), '74b-02 D-13: PLUGIN_SPOTON_STREAM_FORMAT_DESC has exactly the eleven languages');
    for my $lang (@L) {
        my $t = $D->{$lang} // '';
        unlike($t, qr/24[- ]?bit/i, "74b-02 D-13: DESC ($lang) promises no 24-bit FLAC");
        ok(index($t, $OLD_NOTE{$lang}) < 0, "74b-02 D-13: DESC ($lang) no longer carries the PCM-delivered-as-FLAC note");
        unlike($t, qr/bit[- ]?(?:exact|perfect)|bitgenau|bitperfekt/i, "74b-02 D-21: DESC ($lang) makes no bit-exact claim");
        unlike($t, qr/[\x{2013}\x{2014}]/, "74b-02: DESC ($lang) uses only '-' as dash");
        like($v74b{PLUGIN_SPOTON_STREAM_FORMAT_FLAC}{$lang} // '', qr/FLAC 16/, "74b-02 D-01: the FLAC option label ($lang) reads FLAC 16");
    }
    is(scalar(keys %{ $v74b{PLUGIN_SPOTON_STREAM_FORMAT_FLAC} || {} }), 11, '74b-02 D-01: the FLAC option label has the eleven languages');

    for my $k (qw(LINE VIA_DIRECT VIA_PROXY REASON_NO_FLC REASON_NO_LAME REASON_RULE MP3_NOTE)) {
        my $key = "PLUGIN_SPOTON_STREAM_FORMAT_$k";
        is(join(',', sort keys %{ $v74b{$key} || {} }), join(',', @L), "74b-02: $key has exactly the eleven languages");
        my @dash = grep { ($v74b{$key}{$_} // '') =~ /[\x{2013}\x{2014}]/ } @L;
        is(scalar(@dash), 0, "74b-02: $key carries no em or en dash");
    }
    for my $k (qw(LINE REASON_RULE)) {
        my @nos = grep { ($v74b{"PLUGIN_SPOTON_STREAM_FORMAT_$k"}{$_} // '') !~ /%s/ } @L;
        is(scalar(@nos), 0, "74b-02: PLUGIN_SPOTON_STREAM_FORMAT_$k keeps its %s placeholder in every language");
    }
}

# ============================================================
# 79-24 (RF-74b-IN-04 and its MP3_NOTE sibling, D-08, D-02 promise discipline):
# the 16-bit FLAC conversion reduces a source with more than 16 bits, so
# neither the format help text nor the lossy-MP3 note may claim it is lossless
# or that FLAC 16 "keeps" a Lossless / Very high quality. Two separate cell
# groups; each starts with an exact-eleven parse guard so an empty parse can
# never pass.
# ============================================================
{
    use utf8;
    open(my $fh, '<:encoding(UTF-8)', "$project_dir/Plugins/SpotOn/strings.txt") or die "Cannot read strings.txt: $!";
    my $content = do { local $/; <$fh> };
    close($fh);
    my (%val, $cur);
    for my $l (split /\n/, $content) {
        if ($l =~ /^(PLUGIN_SPOTON\w*)\s*$/) { $cur = $1; next; }
        $val{$cur}{$1} = $2 if defined $cur && $l =~ /^\t([A-Z]{2})\t(.+)$/;
    }
    my @L = qw(CS DA DE EN ES FR IT NL NO PL SV);

    # the word each language uses for "lossless" in the FLAC 16 sentence
    my %DESC_CLAIM = (
        CS => qr/bezeztrát|bezztrát/i,
        DA => qr/tabsfri/i,
        DE => qr/verlustfrei/i,
        EN => qr/lossless/i,
        ES => qr/sin pérdida/i,
        FR => qr/sans perte/i,
        IT => qr/senza perdit/i,
        NL => qr/verliesvrij/i,
        NO => qr/tapsfri/i,
        PL => qr/bezstratn/i,
        SV => qr/förlustfri/i,
    );
    my $D = $val{PLUGIN_SPOTON_STREAM_FORMAT_DESC} || {};
    is(join(',', sort keys %$D), join(',', @L), '79-24 IN-04: PLUGIN_SPOTON_STREAM_FORMAT_DESC has exactly the eleven languages');
    my @desc_claims = grep { ($D->{$_} // '') =~ $DESC_CLAIM{$_} } @L;
    is(join(',', @desc_claims), '', '79-24 IN-04: no DESC language calls the FLAC 16 conversion lossless (languages still claiming are listed)');

    # "FLAC 16" followed by each language's "keeps it" clause
    my %KEEP_CLAIM = (
        CS => qr/FLAC 16 ji zachová/i,
        DA => qr/FLAC 16 bevarer/i,
        DE => qr/FLAC 16 erhält/i,
        EN => qr/FLAC 16 keeps/i,
        ES => qr/FLAC 16 la conserva/i,
        FR => qr/FLAC 16 la conserve/i,
        IT => qr/FLAC 16 la mantiene/i,
        NL => qr/FLAC 16 behoudt/i,
        NO => qr/FLAC 16 beholder/i,
        PL => qr/FLAC 16 ją zachowuje/i,
        SV => qr/FLAC 16 bevarar/i,
    );
    my $N = $val{PLUGIN_SPOTON_STREAM_FORMAT_MP3_NOTE} || {};
    is(join(',', sort keys %$N), join(',', @L), '79-24 MP3-NOTE: PLUGIN_SPOTON_STREAM_FORMAT_MP3_NOTE has exactly the eleven languages');
    my @keep_claims = grep { ($N->{$_} // '') =~ $KEEP_CLAIM{$_} } @L;
    is(join(',', @keep_claims), '', '79-24 MP3-NOTE: no note language says FLAC 16 keeps the Spotify quality (languages still claiming are listed)');
}

done_testing();
