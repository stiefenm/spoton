package Plugins::SpotOn::API::Pathfinder;

# Pathfinder (api-partner.spotify.com/pathfinder/v2/query) -- the one module
# that names the host. Made for You (decision-D17 pathfinder-login5-plus-
# rootlist), Top Tracks (decision-D07 pathfinder) and search (decision-SEARCH
# pathfinder-search) run through it with SpotOn's OWN login5 bearer:
#
#   - cookie-free (no sp_dc, no client token); LMS' shared cookie jar is
#     emptied of Spotify cookies before every request (the page scrape would
#     otherwise leave sp_t & co. in it)
#   - the User-Agent is set explicitly: the endpoint answers 403 "Client/request
#     not allowed" to LMS' legacy iTunes-form agent, curl and python (85-04
#     MFY spike, measured). It is the browser-form Mozilla/5.0 agent together
#     with App-Platform / Origin / Referer / spotify-app-version -- the one
#     header set measured on homeSection, userTopContent and searchDesktop
#   - persisted-query hashes are scraped from the web player bundles (and,
#     for userTopContent / search*, from the route chunks named in the
#     webpack chunk map) and cached under spoton_pf_hash_<op>; nothing from
#     the bundles is ever executed, a hash is only an id
#   - P-01 / NFL-03: at most PF_MAX_CONCURRENT queries are in flight, the rest
#     wait in a FIFO queue; concurrent cold-cache queries share one scrape
#   - an isolated 429 pool (PF_RATE_LIMIT_KEY), never the Browse rate key
#
# No dependency on the Web API client (Client.pm): Pathfinder is reached
# through SpClient (getMadeForYou / getTopTracks / search) only.

use strict;
use warnings;

use JSON::XS::VersionOneAndTwo;
use Slim::Networking::SimpleAsyncHTTP;
use Slim::Utils::Cache;
use Slim::Utils::Log;
use Time::HiRes;

# ------------------------------------------------------------
# Constants
# ------------------------------------------------------------
use constant PATHFINDER_URL => 'https://api-partner.spotify.com/pathfinder/v2/query';
use constant PF_OPEN_URL    => 'https://open.spotify.com/';
use constant PF_CDN_PREFIX  => 'https://open.spotifycdn.com/';

# The browser form of decision-D17's pinned Mozilla/5.0 agent: the only one
# measured together with the extra headers (runs/probes2.json, top.pl:113-120).
# LMS' own default would be the 403-gated iTunes form on LMS 8.x.
use constant PF_USER_AGENT  => 'Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/149.0.0.0 Safari/537.36';
use constant PF_APP_VERSION => '1.2.94.583.g60394bd5';

# The cache key Client.pm's reset and statusSnapshot already read, so they keep
# working until 85-09 / 85-15 replace them. Never 'spoton_rate_limit'.
use constant PF_RATE_LIMIT_KEY   => 'spoton_wp_rate_limit';
use constant PF_HASH_CACHE_PREFIX => 'spoton_pf_hash_';
use constant PF_HASH_TTL         => 30 * 86400;
use constant PF_MAX_BUNDLES      => 8;
use constant PF_MAX_CONCURRENT   => 2;      # SpClient's MAX_CONCURRENT_REQUESTS value
# D-19 / T-85-32: a scrape costs 4.8-6.8 MB, so re-scrapes are rate-limited --
# one per PF_RESCRAPE_COOLDOWN_S after a scrape, and one per PF_BROKEN_RETRY_S
# while the last scrape did not heal (the hash is still rejected, or the
# operation is absent from the bundles).
use constant PF_RESCRAPE_COOLDOWN_S => 600;
use constant PF_BROKEN_RETRY_S      => 3600;
use constant REQUEST_TIMEOUT     => 30;
use constant SCRAPE_TIMEOUT      => 60;

# The lazily loaded web-player route chunks that declare userTopContent and
# the search operations (85-04-TOP-SEARCH-SPIKE.md): their hashes live in the
# chunks, not in the page bundles. Chunk NAMES are stable, chunk hashes rotate
# with every release, so they are looked up in the webpack chunk map.
use constant PF_CHUNKS      => [ 'xpui-routes-profile', 'xpui-routes-search' ];

use constant SECTION_MFY    => 'spotify:section:0JQ5DAUnp4wcj0bCb3wh3S';
use constant SECTION_TOPMIX => 'spotify:section:0JQ5DAnM3wGh0gz1MXnu89';
use constant DJ_URI         => 'spotify:playlist:37i9dQZF1EYkqdzj48dyYq';

my $log   = logger('plugin.spoton');
# M5: cache version lives in Plugin.pm (single source of truth).
my $cache = Slim::Utils::Cache->new('spoton', Plugins::SpotOn::Plugin::SPOTON_CACHE_VERSION());

# ------------------------------------------------------------
# Module state (cleared by reset)
# ------------------------------------------------------------
my @_queue;                # jobs waiting for a slot
my $_inflight      = 0;    # jobs holding a slot
my $_scrapeRunning = 0;    # refreshHashes coalescing
my @_scrapeWaiters;

# Health (D-19), exposed through healthSnapshot for the status page (85-09):
# per-operation sets drive hashState, the *At stamps are epoch seconds.
my %_h = _freshHealth();
sub _freshHealth {
    return (
        opsMissing   => {},      # ops absent from the scraped bundles
        brokenOps    => {},      # ops whose scraped hash is still rejected (412)
        everOk       => 0,
        last412At    => undef,
        last401At    => undef,
        last403At    => undef,
        lastScrapeAt => undef,
        scrapeHealed => 1,       # false after a scrape that did not heal
    );
}
sub _now { return int(Time::HiRes::time()); }

# ============================================================
# Lifecycle
# ============================================================

# reset($class)
# Called by Plugin.pm::initPlugin. Clears the queue, the in-flight count, the
# scrape coalescing state and PF_RATE_LIMIT_KEY, so a stale Retry-After never
# outlives a restart (after 85-15 deletes Client.pm nothing else clears it).
sub reset {
    my ($class) = @_;
    @_queue         = ();
    $_inflight      = 0;
    $_scrapeRunning = 0;
    @_scrapeWaiters = ();
    %_h             = _freshHealth();
    $cache->remove(PF_RATE_LIMIT_KEY);
    main::INFOLOG && $log->info('Pathfinder: reset');
    return;
}

# healthSnapshot($class)
# D-19 contract for the status page: hashState is broken (a scraped hash is
# still rejected), op_missing (an operation is absent from the bundles), ok
# (a query has been answered) or unknown (nothing asked yet).
sub healthSnapshot {
    my ($class) = @_;
    my $state = %{ $_h{brokenOps} }  ? 'broken'
              : %{ $_h{opsMissing} } ? 'op_missing'
              : $_h{everOk}          ? 'ok'
              :                        'unknown';
    return {
        hashState    => $state,
        opsMissing   => [ sort keys %{ $_h{opsMissing} } ],
        last412At    => $_h{last412At},
        last401At    => $_h{last401At},
        last403At    => $_h{last403At},
        lastScrapeAt => $_h{lastScrapeAt},
        rateLimited  => $cache->get(PF_RATE_LIMIT_KEY) ? 1 : 0,
    };
}

# ============================================================
# query
# ============================================================

# query($class, $accountId, $op, $vars, $cb)
# One persisted query. $cb->($decodedResponse) on success,
# $cb->(undef, { error => ..., code => ... }) on failure. The request waits in
# a FIFO queue while PF_MAX_CONCURRENT queries are outstanding (P-01/NFL-03).
sub query {
    my ($class, $accountId, $op, $vars, $cb) = @_;

    unless (defined $op && !ref($op) && $op =~ /\A[A-Za-z][A-Za-z0-9_]*\z/) {
        $cb->(undef, { error => 'invalid_op' });
        return;
    }

    push @_queue, {
        accountId => $accountId,
        op        => $op,
        vars      => $vars || {},
        cb        => $cb,
    };
    $class->_pump();
    return;
}

# _pump($class)
# Starts queued jobs while slots are free. The slot is released exactly once
# through the guarded $finish callback; the dispatch is eval-guarded so a die
# cannot leak a slot (SpClient._request pattern).
sub _pump {
    my ($class) = @_;

    while (@_queue && $_inflight < PF_MAX_CONCURRENT) {
        my $job = shift @_queue;
        $_inflight++;

        my $done   = 0;
        my $finish = sub {
            return if $done++;
            $_inflight-- if $_inflight > 0;
            my @args = @_;
            eval { $job->{cb}->(@args); 1 }
                or $log->error("Pathfinder: callback for $job->{op} died: $@");
            $class->_pump();
        };

        eval { $class->_attempt($job, $finish); 1 } or do {
            $log->error("Pathfinder: dispatch of $job->{op} failed: $@");
            $finish->(undef, { error => 'internal_error' });
        };
    }
    return;
}

# _attempt($class, $job, $finish)
# One send: rate gate -> login5 bearer -> hash (scraping when missing) -> POST.
sub _attempt {
    my ($class, $job, $finish) = @_;

    if ($cache->get(PF_RATE_LIMIT_KEY)) {
        main::INFOLOG && $log->info("Pathfinder: $job->{op} short-circuited (cached rate limit)");
        $finish->(undef, { error => 'rate_limited', code => 429, local => 1 });
        return;
    }

    require Plugins::SpotOn::API::Login5;
    Plugins::SpotOn::API::Login5->getToken($job->{accountId}, sub {
        my ($token, $reason, $detail) = @_;

        unless ($token) {
            main::INFOLOG && $log->info("Pathfinder: no login5 token for $job->{op} (reason=" . ($reason // '?') . ')');
            # WR-16/WR-18: a login5 throttle (HTTP 429 or a protobuf
            # TIMEOUT/TOO_MANY_ATTEMPTS/TRY_AGAIN_LATER) is a rate limit, not
            # "no token".
            my $err = ($detail && ref $detail eq 'HASH' && ($detail->{throttled} || ($detail->{code} // 0) == 429))
                ? { error => 'rate_limited', code => 429, source => 'login5' }
                : { error => $reason || 'no_token' };
            $finish->(undef, $err);
            return;
        }

        $class->_withHash($job->{op}, sub {
            my ($hash, $err) = @_;
            unless ($hash) {
                $finish->(undef, $err || { error => 'hash_broken' });
                return;
            }
            $class->_post($job, $token, $hash, $finish);
        });
    });
    return;
}

# _withHash($class, $op, $cb)
# The cached persisted-query hash of $op, scraping the bundles first when it
# is missing -- unless a scrape is not allowed yet (D-19 cooldown), then the
# answer is hash_broken / op_missing without a request. $cb->($hash) or
# $cb->(undef, \%err).
sub _withHash {
    my ($class, $op, $cb) = @_;

    my $hash = $cache->get(PF_HASH_CACHE_PREFIX . $op);
    if (_validHash($hash)) {
        $cb->($hash);
        return;
    }

    unless ($class->_scrapeAllowed()) {
        if ($_h{opsMissing}{$op}) {
            $cb->(undef, { error => 'op_missing' });
        } else {
            $_h{brokenOps}{$op} = 1;
            $cb->(undef, { error => 'hash_broken' });
        }
        return;
    }

    $class->refreshHashes(sub {
        my ($ok) = @_;
        my $h = $cache->get(PF_HASH_CACHE_PREFIX . $op);
        if (_validHash($h)) {
            delete $_h{opsMissing}{$op};
            $cb->($h);
            return;
        }
        if ($ok) {
            # the bundles were read but do not declare this operation
            $_h{opsMissing}{$op} = 1;
            $_h{scrapeHealed}    = 0;
            $log->warn("Pathfinder: operation $op is not declared in the web player bundles");
            $cb->(undef, { error => 'op_missing' });
        } else {
            $_h{brokenOps}{$op} = 1;
            $cb->(undef, { error => 'hash_broken' });
        }
    });
    return;
}

sub _validHash {
    my ($h) = @_;
    return (defined $h && !ref($h) && $h =~ /\A[0-9a-f]{64}\z/) ? 1 : 0;
}

# _scrapeAllowed($class)
# D-19 / T-85-32: a scrape that is already running can always be joined;
# otherwise one per PF_RESCRAPE_COOLDOWN_S, or per PF_BROKEN_RETRY_S while the
# last scrape did not heal.
sub _scrapeAllowed {
    my ($class) = @_;
    return 1 if $_scrapeRunning;
    return 1 unless defined $_h{lastScrapeAt};
    my $window = $_h{scrapeHealed} ? PF_RESCRAPE_COOLDOWN_S : PF_BROKEN_RETRY_S;
    return (_now() - $_h{lastScrapeAt}) >= $window ? 1 : 0;
}

# _onHashRejected($class, $job, $finish)
# 412 "Invalid query hash": the web player rotated its hashes. Drop the op's
# cached hash, rescrape ONCE (rate-limited) and retry ONCE; a second 412 means
# the scraped hash is rejected too -> hash_broken.
sub _onHashRejected {
    my ($class, $job, $finish) = @_;
    my $op = $job->{op};

    $_h{last412At} = _now();
    $cache->remove(PF_HASH_CACHE_PREFIX . $op);
    $log->warn("Pathfinder: 412 for $op -- persisted-query hash rotated");

    if ($job->{rescraped}) {
        $_h{brokenOps}{$op} = 1;
        $_h{scrapeHealed}   = 0;
        $finish->(undef, { error => 'hash_broken', code => 412 });
        return;
    }
    $job->{rescraped} = 1;

    unless ($class->_scrapeAllowed()) {
        $_h{brokenOps}{$op} = 1;
        $finish->(undef, { error => 'hash_broken', code => 412 });
        return;
    }

    $class->refreshHashes(sub {
        my ($ok) = @_;
        my $h = $cache->get(PF_HASH_CACHE_PREFIX . $op);
        unless (_validHash($h)) {
            if ($ok) {
                $_h{opsMissing}{$op} = 1;
                $_h{scrapeHealed}    = 0;
                $finish->(undef, { error => 'op_missing', code => 412 });
            } else {
                $_h{brokenOps}{$op} = 1;
                $finish->(undef, { error => 'hash_broken', code => 412 });
            }
            return;
        }
        eval { $class->_attempt($job, $finish); 1 } or do {
            $log->error("Pathfinder: retry of $op failed: $@");
            $finish->(undef, { error => 'internal_error' });
        };
    });
    return;
}

# _post($class, $job, $token, $hash, $finish)
sub _post {
    my ($class, $job, $token, $hash, $finish) = @_;
    my $op = $job->{op};

    my $body = eval { to_json({
        operationName => $op,
        variables     => $job->{vars},
        extensions    => { persistedQuery => { version => 1, sha256Hash => $hash } },
    }) };
    unless (defined $body) {
        $log->error("Pathfinder: request body for $op could not be built: $@");
        $finish->(undef, { error => 'internal_error' });
        return;
    }

    # LMS' cookie jar is shared with the page scrape; keep Spotify cookies out.
    $class->_dropCookies();

    my $http = Slim::Networking::SimpleAsyncHTTP->new(
        sub {
            my $http    = shift;
            my $content = $http->content // '';
            my $result  = eval { from_json($content) };
            if ($@ || ref($result) ne 'HASH') {
                $log->error("Pathfinder: $op JSON parse error");
                $finish->(undef, { error => 'parse_error' });
                return;
            }
            if (ref($result->{errors}) eq 'ARRAY' && @{ $result->{errors} }) {
                $log->warn("Pathfinder: $op answered with errors[]");
                $finish->(undef, { error => 'graphql_error' });
                return;
            }
            $_h{everOk}       = 1;
            $_h{scrapeHealed} = 1;
            delete $_h{brokenOps}{$op};
            delete $_h{opsMissing}{$op};
            $finish->($result);
        },
        sub {
            my ($http, $error, $response) = @_;

            my $code = ($response && ref $response && $response->can('code'))
                ? ($response->code || 0) : 0;
            if (!$code && $error && $error =~ /^(\d{3})\b/) {
                $code = $1;
            }

            if ($code == 429) {
                my $retryAfter = 5;
                if ($response && ref $response && $response->can('header')) {
                    my $headerVal = $response->header('Retry-After');
                    $retryAfter = $headerVal if defined $headerVal && $headerVal =~ /^\d+$/;
                }
                $retryAfter = 1   if $retryAfter < 1;
                $retryAfter = 300 if $retryAfter > 300;

                # Isolated pool -- MUST NOT be 'spoton_rate_limit' (T-52-04).
                $cache->set(PF_RATE_LIMIT_KEY, 1, $retryAfter);
                $log->warn("Pathfinder: 429 on $op, rate limited for ${retryAfter}s (isolated pool)");
                if ($INC{'Plugins/SpotOn/Status.pm'}) {
                    Plugins::SpotOn::Status->recordError('warn', 'API', '429 on pathfinder/v2/query');
                }
                $finish->(undef, { error => 'rate_limited', code => 429 });
                return;
            }

            if ($code == 412) {
                $class->_onHashRejected($job, $finish);
                return;
            }

            if ($code == 401) {
                $_h{last401At} = _now();
                if (my $acct = $job->{accountId}) {
                    $cache->remove("spoton_login5_token_${acct}");
                }
                # exactly one login5 re-mint and one retry (D-19, SpClient D-07a)
                if (!$job->{retried401}) {
                    $job->{retried401} = 1;
                    $log->warn("Pathfinder: 401 for $op, retrying once with a fresh login5 token");
                    eval { $class->_attempt($job, $finish); 1 } or do {
                        $log->error("Pathfinder: re-mint retry of $op failed: $@");
                        $finish->(undef, { error => 'internal_error' });
                    };
                    return;
                }
                $finish->(undef, { error => 'unauthorized', code => 401 });
                return;
            }

            if ($code == 403) {
                # "Client/request not allowed": the User-Agent gate (85-04 spike)
                $_h{last403At} = _now();
                $log->warn("Pathfinder: 403 for $op -- User-Agent gate, no retry");
                $finish->(undef, { error => 'ua_gate', code => 403 });
                return;
            }

            # T-85-50: never log the Authorization value.
            $log->error("Pathfinder: HTTP $code for $op: " . ($error // ''));
            if ($INC{'Plugins/SpotOn/Status.pm'}) {
                Plugins::SpotOn::Status->recordError('error', 'API', "HTTP $code for pathfinder/v2/query");
            }
            $finish->(undef, { error => ($error || 'http_error'), code => $code });
        },
        { timeout => REQUEST_TIMEOUT, cache => 0 },
    );

    # Every header is passed explicitly: Async/HTTP.pm fills the User-Agent
    # only when it is absent (init_header), so an explicit one wins.
    $http->post(
        PATHFINDER_URL,
        'Authorization'       => "Bearer $token",
        'Content-Type'        => 'application/json;charset=UTF-8',
        'Accept'              => 'application/json',
        'User-Agent'          => PF_USER_AGENT,
        'App-Platform'        => 'WebPlayer',
        'Origin'              => 'https://open.spotify.com',
        'Referer'             => 'https://open.spotify.com/',
        'spotify-app-version' => PF_APP_VERSION,
        $body,
    );
    return;
}

# _dropCookies($class)
# Removes Spotify cookies from LMS' shared Async::HTTP cookie jar. The jar
# extracts Set-Cookie from every response (the web player page sets sp_t) and
# adds matching cookies to later requests; the Pathfinder path is cookie-free
# (decision-D17), so nothing of that may ride along. Skipped when the jar
# class is not loaded (unit tests).
sub _dropCookies {
    my ($class) = @_;
    return unless $INC{'Slim/Networking/Async/HTTP.pm'};

    eval {
        my $jar = Slim::Networking::Async::HTTP->cookie_jar;
        if ($jar) {
            my @drop;
            $jar->scan(sub {
                my ($version, $key, $val, $path, $domain) = @_;
                push @drop, [ $domain, $path, $key ]
                    if defined $domain && $domain =~ /(?:\A|\.)spotify(?:cdn)?\.com\z/i;
            });
            $jar->clear(@$_) for @drop;
        }
        1;
    } or $log->warn("Pathfinder: cookie jar cleanup failed: $@");
    return;
}

# ============================================================
# Hash scrape (T-85-31)
# ============================================================

# refreshHashes($class, $cb)
# Fetches the web player page (cookie-free, pinned User-Agent), then the
# listed https://open.spotifycdn.com/ bundles sequentially (at most
# PF_MAX_BUNDLES), and caches every ("<op>","query|mutation","<hash>") triple
# whose hash is 64 lowercase hex under spoton_pf_hash_<op>. A scrape costs
# ~7 requests / 6.8 MB (85-04-MFY-SPIKE.md budget). Concurrent callers are
# coalesced: while a scrape runs, later callers only append their callback and
# every waiter is answered when the one scrape ends. $cb->($ok), $ok true when
# at least one operation was found.
sub refreshHashes {
    my ($class, $cb) = @_;

    push @_scrapeWaiters, $cb;
    return if $_scrapeRunning;
    $_scrapeRunning = 1;

    # The cooldown anchor is the admission time; a transport failure of the
    # page request itself did not cost a scrape and gives it back.
    my $priorScrapeAt = $_h{lastScrapeAt};
    $_h{lastScrapeAt} = _now();

    my $finish = sub {
        my ($ok, $transportFailed) = @_;
        $_h{lastScrapeAt} = $priorScrapeAt if $transportFailed;
        $_scrapeRunning = 0;
        $class->_dropCookies();
        my @waiters = @_scrapeWaiters;
        @_scrapeWaiters = ();
        for my $w (@waiters) {
            eval { $w->($ok); 1 } or $log->error("Pathfinder: scrape waiter died: $@");
        }
    };

    eval { $class->_scrape($finish); 1 } or do {
        $log->error("Pathfinder: scrape failed to start: $@");
        $finish->(0);
    };
    return;
}

# _scrape($class, $finish)
sub _scrape {
    my ($class, $finish) = @_;

    my $headers = { 'User-Agent' => PF_USER_AGENT };

    my %ops;
    my $fetch;
    $fetch = sub {
        my ($url, $accept, $onBody, $onFail) = @_;
        my $http = Slim::Networking::SimpleAsyncHTTP->new(
            sub { my $h = shift; $onBody->($h->content // '') },
            sub { my ($h, $err) = @_; $onFail->($err // 'error') },
            { timeout => SCRAPE_TIMEOUT, cache => 0 },
        );
        $http->get($url, %$headers, ($accept ? (Accept => $accept) : ()));
    };

    my $store = sub {
        my $n = 0;
        for my $op (sort keys %ops) {
            $cache->set(PF_HASH_CACHE_PREFIX . $op, $ops{$op}, PF_HASH_TTL);
            $n++;
        }
        main::INFOLOG && $log->info("Pathfinder: scrape cached $n operation hashes");
        return $n;
    };

    $fetch->(PF_OPEN_URL, 'text/html', sub {
        my ($html) = @_;

        my (@urls, %seen);
        while ($html =~ m{<script[^>]+src="(https://open\.spotifycdn\.com/[^"]+\.js)"}g) {
            my $u = $1;
            next if $seen{$u}++;
            push @urls, $u;
            last if @urls >= PF_MAX_BUNDLES;
        }

        my $map;
        my $next;
        $next = sub {
            my $url = shift @urls;
            unless (defined $url) {
                undef $next;
                # userTopContent and the search ops live in route chunks named
                # in the main bundle's chunk map (T-85-31: CDN prefix only)
                my @chunkUrls = $map ? $class->_chunkUrls($map) : ();
                $log->warn('Pathfinder: no webpack chunk map found in the bundles -- route chunks are not scraped')
                    unless $map;
                my $nextChunk;
                $nextChunk = sub {
                    my $cu = shift @chunkUrls;
                    unless (defined $cu) {
                        undef $nextChunk;
                        $finish->($store->() ? 1 : 0);
                        return;
                    }
                    $fetch->($cu, undef, sub {
                        $class->_harvestOps($_[0], \%ops);
                        $nextChunk->();
                    }, sub {
                        $log->warn("Pathfinder: scrape chunk failed: $_[0]");
                        $nextChunk->();
                    });
                };
                $nextChunk->();
                return;
            }
            $fetch->($url, undef, sub {
                my ($js) = @_;
                $class->_harvestOps($js, \%ops);
                $map ||= $class->_parseChunkMap($js);
                $next->();
            }, sub {
                my ($err) = @_;
                $log->warn("Pathfinder: scrape bundle failed: $err");
                $next->();
            });
        };
        $next->();
    }, sub {
        my ($err) = @_;
        $log->warn("Pathfinder: scrape of the web player page failed: $err");
        $finish->(0, 1);
    });
    return;
}

# _harvestOps($class, $js, \%ops)
# ("<op>","query|mutation","<hash>") triples; the first one seen per op wins.
sub _harvestOps {
    my ($class, $js, $ops) = @_;
    while ($js =~ /\("([A-Za-z][A-Za-z0-9_]*)","(?:query|mutation)","([0-9a-f]{64})"/g) {
        my ($name, $hash) = ($1, $2);
        $ops->{$name} //= $hash;
    }
    return;
}

# _parseChunkMap($class, $js)
# The webpack chunk map of the main bundle, WITHOUT relying on the minified
# variable names:
#   <r>.u=<e>=>""+(({<id>:"<name>",...})[<e>]||<e>)+"."+({<id>:"<hash>",...})[<e>]+".js"
#   <r>.p="https://open.spotifycdn.com/..."
# -> { prefix, names => {id => name}, hashes => {id => hash} } or undef. The
# prefix must lie under https://open.spotifycdn.com/ (T-85-31).
sub _parseChunkMap {
    my ($class, $js) = @_;
    return undef unless defined $js && !ref($js);

    my $id = qr/[A-Za-z_\$][\w\$]*/;
    $js =~ /$id\.u=(?<fn>$id)=>""\+\(\(\{(?<names>[^}]*)\}\)\[\k<fn>\]\|\|\k<fn>\)\+"\."\+\(\{(?<hashes>[^}]*)\}\)\[\k<fn>\]\+"\.js"/
        or return undef;
    my ($namesTxt, $hashesTxt) = ($+{names}, $+{hashes});

    $js =~ /$id\.p="(?<prefix>\Q@{[PF_CDN_PREFIX]}\E[^"]*)"/ or return undef;
    my $prefix = $+{prefix};

    my %names  = $namesTxt  =~ /(\d+):"([^"]*)"/g;
    my %hashes = $hashesTxt =~ /(\d+):"([^"]*)"/g;
    return undef unless %hashes;
    return { prefix => $prefix, names => \%names, hashes => \%hashes };
}

# _chunkUrls($class, $map)
# The URLs of the PF_CHUNKS route chunks, built from the chunk map; only names
# and hashes of the strict shape are used and every URL must start with
# https://open.spotifycdn.com/.
sub _chunkUrls {
    my ($class, $map) = @_;
    my @urls;
    for my $want (@{ +PF_CHUNKS }) {
        for my $cid (sort { $a <=> $b } keys %{ $map->{names} }) {
            next unless $map->{names}{$cid} eq $want;
            my $hash = $map->{hashes}{$cid};
            next unless defined $hash && $hash =~ /\A[0-9a-f]{6,64}\z/ && $want =~ /\A[A-Za-z0-9_\-]+\z/;
            my $url = $map->{prefix} . $want . '.' . $hash . '.js';
            next unless index($url, PF_CDN_PREFIX) == 0;
            push @urls, $url;
        }
    }
    return @urls;
}

# ============================================================
# homeSection (Made for You)
# ============================================================

# homeSection($class, $accountId, $sectionUri, $cb)
# One homeSection query. The scraped hash dictates the variable set
# (85-04-MFY-SPIKE.md): the home variables plus uri, no country.
# $cb->(\@items) on success, $cb->(undef, \%err) on failure.
sub homeSection {
    my ($class, $accountId, $sectionUri, $cb) = @_;

    unless (defined $sectionUri && $sectionUri =~ /\Aspotify:section:[A-Za-z0-9]{1,40}\z/) {
        $cb->(undef, { error => 'invalid_id' });
        return;
    }

    $class->query($accountId, 'homeSection', {
        homeEndUserIntegration         => 'INTEGRATION_WEB_PLAYER',
        timeZone                       => _timeZone(),
        sp_t                           => '',
        facet                          => '',
        sectionItemsLimit              => 10,
        includeEpisodeContentRatingsV2 => \1,
        uri                            => $sectionUri,
    }, sub {
        my ($result, $err) = @_;
        if ($err) {
            $cb->(undef, $err);
            return;
        }
        $cb->($class->_extractSectionItems($result));
    });
    return;
}

# The time zone the web player sends; TZ when it is an Area/City name,
# otherwise Europe/Berlin (the value Client.pm always sent).
sub _timeZone {
    my $tz = $ENV{TZ};
    return $tz if defined $tz && $tz =~ m{\A[A-Za-z_]+/[A-Za-z_+\-/]+\z};
    return 'Europe/Berlin';
}

# _extractSectionItems($class, $result)
# data.homeSections.sections[0].sectionItems.items[] -> arrayref of
# { uri, typename, name, images, format, madeFor }. Type-checked at every level; an unknown
# shape yields an empty list and a WARN, never a die (T-85-44). Filtering by
# typename / DJ happens in SpClient->getMadeForYou.
sub _extractSectionItems {
    my ($class, $result) = @_;

    my $sections = (ref($result) eq 'HASH' && ref($result->{data}) eq 'HASH'
                    && ref($result->{data}{homeSections}) eq 'HASH')
        ? $result->{data}{homeSections}{sections} : undef;
    my $section  = (ref($sections) eq 'ARRAY') ? $sections->[0] : undef;
    my $items    = (ref($section) eq 'HASH' && ref($section->{sectionItems}) eq 'HASH')
        ? $section->{sectionItems}{items} : undef;

    unless (ref($items) eq 'ARRAY') {
        $log->warn('Pathfinder: homeSection response has no sectionItems.items -- unknown shape');
        return [];
    }

    return [ grep { defined } map { _sectionItem($_) } @$items ];
}

# _sectionItem($item)
# One sectionItems.items[] entry (homeSection and home share the shape) ->
# { uri, typename, name, images, format, madeFor } or undef. format is the
# playlist's Spotify format string ('' when absent), madeFor is 1 when the
# attributes carry madeFor.username (79-59: the value -- a user name -- is
# never kept).
sub _sectionItem {
    my ($item) = @_;
    return undef unless ref($item) eq 'HASH';
    my $content = ref($item->{content}) eq 'HASH' ? $item->{content} : {};
    my $data    = ref($content->{data}) eq 'HASH'  ? $content->{data}  : {};

    my $uri = $data->{uri};
    $uri = $item->{uri} unless defined $uri && !ref($uri);
    return undef unless defined $uri && !ref($uri) && length $uri;

    my $typename = $data->{__typename};
    $typename = $content->{__typename} unless defined $typename && !ref($typename);
    my $name   = $data->{name};
    my $format = $data->{format};
    my $madeFor = (ref($data->{attributes}) eq 'ARRAY'
        && grep { ref($_) eq 'HASH' && defined $_->{key} && !ref($_->{key}) && $_->{key} eq 'madeFor.username' }
           @{ $data->{attributes} }) ? 1 : 0;

    return {
        uri      => $uri,
        typename => (defined $typename && !ref($typename)) ? $typename : '',
        name     => (defined $name && !ref($name)) ? $name : '',
        images   => _imageItemsToRest($data->{images}),
        format   => (defined $format && !ref($format)) ? $format : '',
        madeFor  => $madeFor,
    };
}

# ============================================================
# home (79-59, GH #180: the whole Spotify home for Made For You)
# ============================================================

# home($class, $accountId, $cb)
# One `home` query with the variables of the 79-59 measurement (the web
# player's home variables, sectionItemsLimit 50, no uri). The hash is scraped
# like every other op. $cb->(\@sections) with
# { uri, title, items => [ _sectionItem ... ] } per row in Spotify's order
# (title '' for an untitled row), or $cb->(undef, \%err).
sub home {
    my ($class, $accountId, $cb) = @_;

    $class->query($accountId, 'home', {
        homeEndUserIntegration         => 'INTEGRATION_WEB_PLAYER',
        timeZone                       => _timeZone(),
        sp_t                           => '',
        facet                          => '',
        sectionItemsLimit              => 50,
        includeEpisodeContentRatingsV2 => \1,
    }, sub {
        my ($result, $err) = @_;
        if ($err) {
            $cb->(undef, $err);
            return;
        }
        $cb->($class->_extractHomeSections($result));
    });
    return;
}

# _extractHomeSections($class, $result)
# data.home.sectionContainer.sections.items[] -> arrayref of
# { uri, title, items }. Type-checked at every level; an unknown shape yields
# an empty list and a WARN, never a die (T-79-249).
sub _extractHomeSections {
    my ($class, $result) = @_;

    my $home = (ref($result) eq 'HASH' && ref($result->{data}) eq 'HASH'
                && ref($result->{data}{home}) eq 'HASH') ? $result->{data}{home} : undef;
    my $sc   = ($home && ref($home->{sectionContainer}) eq 'HASH') ? $home->{sectionContainer} : undef;
    my $ss   = ($sc && ref($sc->{sections}) eq 'HASH') ? $sc->{sections}{items} : undef;

    unless (ref($ss) eq 'ARRAY') {
        $log->warn('Pathfinder: home response has no sectionContainer.sections.items -- unknown shape');
        return [];
    }

    my @out;
    for my $sec (@$ss) {
        next unless ref($sec) eq 'HASH';
        my $uri = $sec->{uri};
        next unless defined $uri && !ref($uri) && $uri =~ /\Aspotify:section:[A-Za-z0-9]{1,40}\z/;
        my $sd    = ref($sec->{data}) eq 'HASH' ? $sec->{data} : {};
        my $title = '';
        if (ref($sd->{title}) eq 'HASH') {
            for my $k (qw(transformedLabel text)) {
                my $v = $sd->{title}{$k};
                if (defined $v && !ref($v) && length $v) { $title = $v; last; }
            }
        }
        my $items = (ref($sec->{sectionItems}) eq 'HASH' && ref($sec->{sectionItems}{items}) eq 'ARRAY')
            ? $sec->{sectionItems}{items} : [];
        push @out, { uri => $uri, title => $title, items => [ grep { defined } map { _sectionItem($_) } @$items ] };
    }
    return \@out;
}

# images.items[].sources[] -> [{url,width,height}] (Web-API image shape)
sub _imageItemsToRest {
    my ($images) = @_;
    return [] unless ref($images) eq 'HASH' && ref($images->{items}) eq 'ARRAY';
    my @out;
    for my $entry (@{ $images->{items} }) {
        next unless ref($entry) eq 'HASH' && ref($entry->{sources}) eq 'ARRAY';
        push @out, _sourcesToRest($entry->{sources});
    }
    return \@out;
}

sub _sourcesToRest {
    my ($sources) = @_;
    my @out;
    for my $s (@{ $sources || [] }) {
        next unless ref($s) eq 'HASH' && defined $s->{url} && !ref($s->{url}) && length $s->{url};
        push @out, { url => $s->{url}, width => $s->{width}, height => $s->{height} };
    }
    return @out;
}

# ============================================================
# userTopContent (Top Tracks, decision-D07 pathfinder)
# ============================================================

my %TIME_RANGE = (short_term => 'SHORT_TERM', medium_term => 'MID_TERM', long_term => 'LONG_TERM');

# topTracks($class, $accountId, $params, $cb)
# $params: time_range (short_term | medium_term | long_term), limit (capped at
# 50, D07-page-cap), offset. $cb->({ items => [track...], total, offset, limit })
# with every track in the Web-API shape SpotOn's callers consume, or
# $cb->(undef, \%err). Spotify's own ranking (sortBy AFFINITY).
sub topTracks {
    my ($class, $accountId, $params, $cb) = @_;
    $params ||= {};

    my $range  = $TIME_RANGE{ $params->{time_range} // '' } // 'MID_TERM';
    my $limit  = _clamp($params->{limit}, 1, 50, 50);
    my $offset = _clamp($params->{offset}, 0, 100000, 0);

    $class->query($accountId, 'userTopContent', {
        includeTopArtists => \0,
        topArtistsInput   => { offset => 0, limit => 1, sortBy => 'AFFINITY', timeRange => 'SHORT_TERM' },
        includeTopTracks  => \1,
        topTracksInput    => { offset => $offset + 0, limit => $limit + 0, sortBy => 'AFFINITY', timeRange => $range },
    }, sub {
        my ($result, $err) = @_;
        if ($err) {
            $cb->(undef, $err);
            return;
        }
        my $page = (ref($result->{data}) eq 'HASH' && ref($result->{data}{me}) eq 'HASH'
                    && ref($result->{data}{me}{profile}) eq 'HASH')
            ? $result->{data}{me}{profile}{topTracks} : undef;
        unless (ref($page) eq 'HASH' && ref($page->{items}) eq 'ARRAY') {
            $log->warn('Pathfinder: userTopContent response has no topTracks.items -- unknown shape');
            $cb->(undef, { error => 'unknown_shape' });
            return;
        }
        my @tracks = grep { defined } map { _mapTrack($_) } @{ $page->{items} };
        my $total  = (defined $page->{totalCount} && $page->{totalCount} =~ /\A\d+\z/) ? $page->{totalCount} + 0 : scalar(@tracks);
        $cb->({ items => \@tracks, total => $total, offset => $offset, limit => $limit });
    });
    return;
}

sub _clamp {
    my ($v, $min, $max, $default) = @_;
    return $default unless defined $v && !ref($v) && $v =~ /\A\d+\z/;
    return $min if $v < $min;
    return $max if $v > $max;
    return $v + 0;
}

# ============================================================
# search (decision-SEARCH pathfinder-search)
# ============================================================

my %TYPE_KEY     = (track => 'tracks', album => 'albums', artist => 'artists', playlist => 'playlists', show => 'shows', episode => 'episodes');
my %DESKTOP_SECT = (track => 'tracksV2', album => 'albumsV2', artist => 'artists', playlist => 'playlists', show => 'podcasts', episode => 'episodes');
my %TYPE_OP      = (track => 'searchTracks', album => 'searchAlbums', artist => 'searchArtists', playlist => 'searchPlaylists', show => 'searchPodcasts');

# search($class, $accountId, $params, $cb)
# $params: q, type (one of track album artist playlist show episode, or a
# comma-separated list), limit (<= 50; 10 is the measured value), offset.
#   - one type with a per-type op -> that op (searchTracks, searchAlbums,
#     searchArtists, searchPlaylists, searchPodcasts)
#   - several types, or episode -> ONE searchDesktop request whose sections fill
#     every requested type (episode deeper offsets are INFERRED)
# $cb->({ <types>s => { items, total, offset, limit }, ... }) in the Web-API
# shape, or $cb->(undef, \%err). q = artist:"<name>" (DontStopTheMusic) searches
# <name> and keeps only track items by an artist of that name, case-insensitively
# (the field filter itself is not measured on searchTracks); every other track and
# every unmappable entry stays in the list as a nameless slot {} (79-58, GH #168).
sub search {
    my ($class, $accountId, $params, $cb) = @_;
    $params ||= {};

    my (@types, %seen);
    for my $t (split /,/, ($params->{type} // '')) {
        $t =~ s/\A\s+|\s+\z//g;
        next unless exists $TYPE_KEY{$t} && !$seen{$t}++;
        push @types, $t;
    }
    unless (@types) {
        $cb->(undef, { error => 'invalid_type' });
        return;
    }

    my $term = $params->{q};
    unless (defined $term && !ref($term) && $term =~ /\S/) {
        $cb->(undef, { error => 'invalid_query' });
        return;
    }
    my $artistFilter;
    if ($term =~ /\Aartist:"([^"]*)"\z/) {
        $artistFilter = $1;
        $term = $1;
    }

    my $limit  = _clamp($params->{limit}, 1, 50, 10);
    my $offset = _clamp($params->{offset}, 0, 100000, 0);

    my ($op, $vars);
    if (@types == 1 && $TYPE_OP{ $types[0] }) {
        $op   = $TYPE_OP{ $types[0] };
        $vars = {
            searchTerm                     => $term,
            offset                         => $offset + 0,
            limit                          => $limit + 0,
            includeAudiobooks              => \1,
            includePreReleases             => \1,
            includeAlbumPreReleases        => \0,
            includeAuthors                 => \0,
            includeEpisodeContentRatingsV2 => \0,
        };
    } else {
        $op   = 'searchDesktop';
        $vars = {
            searchTerm                     => $term,
            offset                         => $offset + 0,
            limit                          => $limit + 0,
            numberOfTopResults             => 5,
            includeAudiobooks              => \1,
            includeArtistHasConcertsField  => \0,
            includePreReleases             => \1,
            includeAlbumPreReleases        => \0,
            includeAuthors                 => \0,
            includeEpisodeContentRatingsV2 => \0,
            isPrefix                       => undef,
        };
    }

    $class->query($accountId, $op, $vars, sub {
        my ($result, $err) = @_;
        if ($err) {
            $cb->(undef, $err);
            return;
        }
        my $v2 = (ref($result->{data}) eq 'HASH') ? $result->{data}{searchV2} : undef;
        unless (ref($v2) eq 'HASH') {
            $log->warn("Pathfinder: $op response has no data.searchV2 -- unknown shape");
            $cb->(undef, { error => 'unknown_shape' });
            return;
        }

        my %out;
        for my $type (@types) {
            my $section = $v2->{ $DESKTOP_SECT{$type} };
            my @items;
            my $total = 0;
            if (ref($section) eq 'HASH' && ref($section->{items}) eq 'ARRAY') {
                # 79-58 (GH #168): an unmappable entry keeps its slot as a nameless {} so list
                # positions stay equal to Spotify's offsets; callers map it to an ignore row (R-4)
                # or skip it (Top Result, DontStopTheMusic).
                @items = map { _mapSearchItem($type, $_) // {} } @{ $section->{items} };
                $total = (defined $section->{totalCount} && $section->{totalCount} =~ /\A\d+\z/)
                    ? $section->{totalCount} + 0 : scalar(@items);
            } else {
                $log->warn("Pathfinder: $op has no $DESKTOP_SECT{$type} section -- empty");
            }
            if (defined $artistFilter && $type eq 'track') {
                my $want = lc $artistFilter;
                # 79-58: a non-matching track becomes a slot, the row is not removed
                @items = map {
                    my $t = $_;
                    (scalar grep { lc($_->{name} // '') eq $want } @{ $t->{artists} || [] }) ? $t : {}
                } @items;
            }
            $out{ $TYPE_KEY{$type} } = { items => \@items, total => $total, offset => $offset, limit => $limit };
        }
        $cb->(\%out);
    });
    return;
}

# ============================================================
# Episodes, chapters, shows and their lists (79-71, GH #167 Browse half, D-38; spikes 013/014)
# ============================================================
#
# getEpisodeOrChapter (vars { uri }), queryShowMetadataV2 (vars { uri }), queryPodcastEpisodes and queryBookChapters
# (vars { uri, offset, limit }) run on query() like every other op: the FIFO queue, PF_MAX_CONCURRENT, the isolated
# 429 key and the hash cache with one re-scrape on a rotated hash. A Spotify "this id does not exist" is HTTP 200 with
# __typename NotFound and calls back { error => 'not_found' } (no code) -- the ONLY definitive answer; every transport,
# hash or GraphQL failure keeps its own error from query(), and the SpClient facades keep the two apart.

# episodeOrChapter($class, $accountId, $episodeId, $cb)
# $cb->(\%episode) in the Web-API episode shape (_mapEpisode: id, uri, name, duration_ms, images, show, ...) or
# $cb->(undef, \%err). Serves an Episode (podcast) and a Chapter (audiobook) alike.
sub episodeOrChapter {
    my ($class, $accountId, $episodeId, $cb) = @_;

    unless (defined $episodeId && !ref($episodeId) && $episodeId =~ /\A[A-Za-z0-9]{1,40}\z/) {
        $cb->(undef, { error => 'invalid_id' });
        return;
    }

    $class->query($accountId, 'getEpisodeOrChapter', { uri => "spotify:episode:$episodeId" }, sub {
        my ($result, $err) = @_;
        if ($err) {
            $cb->(undef, $err);
            return;
        }
        my $u = (ref($result->{data}) eq 'HASH') ? $result->{data}{episodeUnionV2} : undef;
        unless (ref($u) eq 'HASH') {
            $log->warn('Pathfinder: getEpisodeOrChapter response has no data.episodeUnionV2 -- unknown shape');
            $cb->(undef, { error => 'unknown_shape' });
            return;
        }
        my $type = _str($u->{__typename});
        if ($type eq 'NotFound') {
            $cb->(undef, { error => 'not_found' });
            return;
        }
        my $ep = ($type eq 'Episode' || $type eq 'Chapter') ? _mapEpisode({ data => $u }) : undef;
        unless ($ep) {
            $log->warn("Pathfinder: getEpisodeOrChapter answered __typename '$type' without a mappable item -- unknown shape");
            $cb->(undef, { error => 'unknown_shape' });
            return;
        }
        $cb->($ep);
    });
    return;
}

# showMetadata($class, $accountId, $showId, $cb)
# $cb->({ id, uri, name, publisher, images, description, kind => 'podcast'|'audiobook' }) or $cb->(undef, \%err).
sub showMetadata {
    my ($class, $accountId, $showId, $cb) = @_;

    unless (defined $showId && !ref($showId) && $showId =~ /\A[A-Za-z0-9]{1,40}\z/) {
        $cb->(undef, { error => 'invalid_id' });
        return;
    }

    $class->query($accountId, 'queryShowMetadataV2', { uri => "spotify:show:$showId" }, sub {
        my ($result, $err) = @_;
        if ($err) {
            $cb->(undef, $err);
            return;
        }
        my $u = (ref($result->{data}) eq 'HASH') ? $result->{data}{podcastUnionV2} : undef;
        unless (ref($u) eq 'HASH') {
            $log->warn('Pathfinder: queryShowMetadataV2 response has no data.podcastUnionV2 -- unknown shape');
            $cb->(undef, { error => 'unknown_shape' });
            return;
        }
        my $type = _str($u->{__typename});
        if ($type eq 'NotFound') {
            $cb->(undef, { error => 'not_found' });
            return;
        }
        my $kind = ($type eq 'Podcast') ? 'podcast' : ($type eq 'Audiobook') ? 'audiobook' : undef;
        my $show = $kind ? _mapShow({ data => $u }) : undef;
        unless ($show) {
            $log->warn("Pathfinder: queryShowMetadataV2 answered __typename '$type' without a mappable show -- unknown shape");
            $cb->(undef, { error => 'unknown_shape' });
            return;
        }
        $show->{description} = _str($u->{description});
        $show->{kind}        = $kind;
        $cb->($show);
    });
    return;
}

# showEpisodes($class, $accountId, $showId, $kind, $params, $cb)
# One page of a show's episodes (kind 'podcast': queryPodcastEpisodes, episodesV2) or an audiobook's chapters
# (kind 'audiobook': queryBookChapters, chaptersV2). $params: offset, limit (capped at 50).
# $cb->({ items => [episode...], total, offset, limit }) or $cb->(undef, \%err). Every list entry keeps its slot: one
# that cannot be mapped becomes { id, uri, name => undef }, so the returned count is the page's count and a caller
# that advances by it reaches total (SpClient._enrichMeta slot discipline).
sub showEpisodes {
    my ($class, $accountId, $showId, $kind, $params, $cb) = @_;
    $params ||= {};

    unless (defined $showId && !ref($showId) && $showId =~ /\A[A-Za-z0-9]{1,40}\z/) {
        $cb->(undef, { error => 'invalid_id' });
        return;
    }

    my $book   = (defined $kind && $kind eq 'audiobook') ? 1 : 0;
    my $op     = $book ? 'queryBookChapters' : 'queryPodcastEpisodes';
    my $listK  = $book ? 'chaptersV2'        : 'episodesV2';
    my $limit  = _clamp($params->{limit}, 1, 50, 50);
    my $offset = _clamp($params->{offset}, 0, 100000, 0);

    $class->query($accountId, $op, { uri => "spotify:show:$showId", offset => $offset + 0, limit => $limit + 0 }, sub {
        my ($result, $err) = @_;
        if ($err) {
            $cb->(undef, $err);
            return;
        }
        my $u = (ref($result->{data}) eq 'HASH') ? $result->{data}{podcastUnionV2} : undef;
        if (ref($u) eq 'HASH' && _str($u->{__typename}) eq 'NotFound') {
            $cb->(undef, { error => 'not_found' });
            return;
        }
        my $page = (ref($u) eq 'HASH') ? $u->{$listK} : undef;
        unless (ref($page) eq 'HASH' && ref($page->{items}) eq 'ARRAY') {
            $log->warn("Pathfinder: $op response has no podcastUnionV2.$listK.items -- unknown shape");
            $cb->(undef, { error => 'unknown_shape' });
            return;
        }
        my @items;
        for my $it (@{ $page->{items} }) {
            my $ent  = (ref($it) eq 'HASH' && ref($it->{entity}) eq 'HASH') ? $it->{entity} : {};
            my $uri  = _str($ent->{_uri});
            my $ep   = (ref($ent->{data}) eq 'HASH') ? _mapEpisode({ data => $ent->{data} }) : undef;
            my $id   = _idOf($uri, 'episode');
            push @items, $ep || { id => $id, uri => (defined $id ? $uri : ''), name => undef };
        }
        my $total = (defined $page->{totalCount} && $page->{totalCount} =~ /\A\d+\z/) ? $page->{totalCount} + 0 : $offset + scalar(@items);
        $cb->({ items => \@items, total => $total, offset => $offset, limit => $limit });
    });
    return;
}

# ------------------------------------------------------------
# Item mappers (85-04-TOP-SEARCH-SPIKE.md:138-151): Pathfinder -> Web-API shape.
# Type-checked at every level; GenericError items and anything without a
# valid uri are skipped, never a die (T-85-44).
# ------------------------------------------------------------

sub _unwrap {
    my ($item) = @_;
    return undef unless ref($item) eq 'HASH';
    my $d = (ref($item->{item}) eq 'HASH' && ref($item->{item}{data}) eq 'HASH') ? $item->{item}{data}
          : (ref($item->{data}) eq 'HASH') ? $item->{data}
          : undef;
    return undef unless $d;
    return undef if ($d->{__typename} // '') eq 'GenericError';
    return $d;
}

sub _idOf {
    my ($uri, $kind) = @_;
    return (defined $uri && !ref($uri) && $uri =~ /\Aspotify:\Q$kind\E:([A-Za-z0-9]{1,40})\z/) ? $1 : undef;
}

sub _str { return (defined $_[0] && !ref($_[0])) ? $_[0] : ''; }

sub _mapArtists {
    my ($artists) = @_;
    my @out;
    if (ref($artists) eq 'HASH' && ref($artists->{items}) eq 'ARRAY') {
        for my $a (@{ $artists->{items} }) {
            next unless ref($a) eq 'HASH';
            my $name = (ref($a->{profile}) eq 'HASH') ? _str($a->{profile}{name}) : '';
            my $uri  = _str($a->{uri});
            push @out, { name => $name, uri => $uri, id => (_idOf($uri, 'artist') // '') };
        }
    }
    return \@out;
}

sub _coverImages {
    my ($cover) = @_;
    return [] unless ref($cover) eq 'HASH' && ref($cover->{sources}) eq 'ARRAY';
    return [ _sourcesToRest($cover->{sources}) ];
}

# track: uri -> id, name, artists.items[].profile.name/uri, albumOfTrack
# name/uri/coverArt.sources -> album.images, duration.totalMilliseconds -> duration_ms
sub _mapTrack {
    my ($item) = @_;
    my $d = _unwrap($item) or return undef;
    my $uri = _str($d->{uri});
    my $id  = _idOf($uri, 'track') or return undef;

    my $alb = ref($d->{albumOfTrack}) eq 'HASH' ? $d->{albumOfTrack} : {};
    my $auri = _str($alb->{uri});
    my $dur  = (ref($d->{duration}) eq 'HASH' && defined $d->{duration}{totalMilliseconds}
                && $d->{duration}{totalMilliseconds} =~ /\A\d+\z/) ? $d->{duration}{totalMilliseconds} + 0 : 0;

    return {
        id          => $id,
        uri         => $uri,
        name        => _str($d->{name}),
        duration_ms => $dur,
        artists     => _mapArtists($d->{artists}),
        album       => {
            id     => (_idOf($auri, 'album') // ''),
            uri    => $auri,
            name   => _str($alb->{name}),
            images => _coverImages($alb->{coverArt}),
        },
    };
}

# album: name, uri, artists.items[].profile.name, coverArt.sources, date.year
sub _mapAlbum {
    my ($item) = @_;
    my $d = _unwrap($item) or return undef;
    my $uri = _str($d->{uri});
    my $id  = _idOf($uri, 'album') or return undef;
    my $year = (ref($d->{date}) eq 'HASH' && defined $d->{date}{year} && $d->{date}{year} =~ /\A\d{4}\z/) ? $d->{date}{year} : '';
    return {
        id           => $id,
        uri          => $uri,
        name         => _str($d->{name}),
        artists      => _mapArtists($d->{artists}),
        images       => _coverImages($d->{coverArt}),
        release_date => $year,
        album_type   => lc(_str($d->{type})),
    };
}

# artist: profile.name, uri, visuals.avatarImage.sources
sub _mapArtist {
    my ($item) = @_;
    my $d = _unwrap($item) or return undef;
    my $uri = _str($d->{uri});
    my $id  = _idOf($uri, 'artist') or return undef;
    my $avatar = (ref($d->{visuals}) eq 'HASH') ? $d->{visuals}{avatarImage} : undef;
    return {
        id     => $id,
        uri    => $uri,
        name   => (ref($d->{profile}) eq 'HASH') ? _str($d->{profile}{name}) : '',
        images => _coverImages($avatar),
    };
}

# playlist: name, uri, ownerV2.data.name, images.items[].sources
sub _mapPlaylist {
    my ($item) = @_;
    my $d = _unwrap($item) or return undef;
    my $uri = _str($d->{uri});
    my $id  = _idOf($uri, 'playlist') or return undef;
    my $owner = (ref($d->{ownerV2}) eq 'HASH' && ref($d->{ownerV2}{data}) eq 'HASH') ? _str($d->{ownerV2}{data}{name}) : '';
    return {
        id     => $id,
        uri    => $uri,
        name   => _str($d->{name}),
        owner  => (length $owner ? { display_name => $owner } : undef),
        images => _imageItemsToRest($d->{images}),
    };
}

# show (the podcasts section): name, uri, publisher.name, coverArt.sources
sub _mapShow {
    my ($item) = @_;
    my $d = _unwrap($item) or return undef;
    my $uri = _str($d->{uri});
    my $id  = _idOf($uri, 'show') or return undef;
    return {
        id        => $id,
        uri       => $uri,
        name      => _str($d->{name}),
        publisher => (ref($d->{publisher}) eq 'HASH') ? _str($d->{publisher}{name}) : '',
        images    => _coverImages($d->{coverArt}),
    };
}

# episode / chapter: name, uri, duration, releaseDate.isoString, coverArt and the show it belongs to:
# podcastV2.data for an Episode, audiobookV2.data for a Chapter (79-71, spike 013). The images are the item's
# own coverArt, else the show's (the chapter's own cover is empty on some books).
sub _mapEpisode {
    my ($item) = @_;
    my $d = _unwrap($item) or return undef;
    my $uri = _str($d->{uri});
    my $id  = _idOf($uri, 'episode') or return undef;
    my $dur = (ref($d->{duration}) eq 'HASH' && defined $d->{duration}{totalMilliseconds}
               && $d->{duration}{totalMilliseconds} =~ /\A\d+\z/) ? $d->{duration}{totalMilliseconds} + 0 : 0;
    my ($date) = (ref($d->{releaseDate}) eq 'HASH' ? _str($d->{releaseDate}{isoString}) : '') =~ /\A(\d{4}-\d{2}-\d{2})/;
    my $show = (ref($d->{podcastV2}) eq 'HASH')   ? _mapShow($d->{podcastV2})
             : (ref($d->{audiobookV2}) eq 'HASH') ? _mapShow($d->{audiobookV2})
             :                                      undef;
    my $images = _coverImages($d->{coverArt});
    $images = $show->{images} if !@$images && $show && ref($show->{images}) eq 'ARRAY';
    my $explicit = (ref($d->{contentRating}) eq 'HASH' && uc(_str($d->{contentRating}{label})) eq 'EXPLICIT') ? 1 : 0;
    return {
        id           => $id,
        uri          => $uri,
        name         => _str($d->{name}),
        description  => _str($d->{description}),
        duration_ms  => $dur,
        explicit     => $explicit,
        release_date => ($date // ''),
        images       => $images,
        ($show ? (show => $show) : ()),
    };
}

sub _mapSearchItem {
    my ($type, $item) = @_;
    my %map = (track => \&_mapTrack, album => \&_mapAlbum, artist => \&_mapArtist,
               playlist => \&_mapPlaylist, show => \&_mapShow, episode => \&_mapEpisode);
    my $fn = $map{$type} or return undef;
    return $fn->($item);
}

1;
