package Plugins::SpotOn::HomeExtras;

use strict;
use warnings;

Plugins::SpotOn::HomeExtraRecentlyPlayed->initPlugin();
Plugins::SpotOn::HomeExtraTopTracks->initPlugin();
Plugins::SpotOn::HomeExtraMadeForYou->initPlugin();
Plugins::SpotOn::HomeExtraMainMenu->initPlugin();
Plugins::SpotOn::HomeExtraPlaylists->initPlugin();

1;

package Plugins::SpotOn::HomeExtraBase;

use strict;
use warnings;

use base qw(Plugins::MaterialSkin::HomeExtraBase);

use Plugins::SpotOn::MenuCopy qw(copyMenu);

my %_feedCache;

sub initPlugin {
    my ($class, %args) = @_;

    my $tag = $args{tag};
    my $origFeed = $args{feed};

    # Wrap feed: filter textarea items that render as junk cards in MS
    # scrolled rows (WR-01), and memoize for 60s to avoid hitting the
    # uncached recently-played endpoint on every home-screen refresh (WR-02).
    # Cache key includes index/quantity because Material Skin pages rows via
    # CLI _index/_quantity and XMLBrowser forwards them in the feed args
    # (GH #133 — page-2 requests within the 60s TTL previously got page 1's
    # cached result).
    # The memo and XMLBrowser never share a tree: XMLBrowser writes items/
    # fetched/offset into what it is handed, so both the miss and the hit path
    # hand out a copy (GH #210, a second playlist within 60s read an empty slice).
    # The add-method relay (92-14, GH #238) is NOT part of the memo: XMLBrowser hands the `query` hash of the
    # root reply to every deeper feed of the request, and for a levelled item_id it calls the root with the
    # same index/quantity for an add, a play, a touch-to-play and a browse, so they all share one memo slot.
    # A memoized relay would turn the next play into a capped one (WR-03) or a browse into an add. So the
    # wrapper strips `query` from what it memoizes and derives the relay again for every request from the
    # row's root args (_controlAddRelay), on a hit and on a miss alike, for every row (Playlists and Made
    # For You roots never relay by themselves).
    my $withRelay = sub {
        my ($menu, $feedArgs) = @_;
        delete $menu->{query};
        if (my $relay = Plugins::SpotOn::Plugin::_controlAddRelay($feedArgs)) {
            $menu->{query} = $relay;
        }
        return $menu;
    };

    $args{feed} = sub {
        my ($client, $cb, $feedArgs) = @_;

        my $cacheKey = join('_', $tag, ($client ? $client->id : ''), ($feedArgs->{index} // ''), ($feedArgs->{quantity} // ''));
        my $cached = $_feedCache{$cacheKey};

        if ($cached && time() - $cached->{ts} < 60) {
            $cb->($withRelay->(copyMenu($cached->{result}), $feedArgs));
            return;
        }

        delete $_feedCache{$cacheKey} if $cached;

        $origFeed->($client, sub {
            my $result = shift;
            my @items = grep { ($_->{type} || '') ne 'textarea' }
                        @{ $result->{items} || [] };
            my %shared = %$result;
            delete $shared{query};   # per request, never memoized
            my $filtered = { %shared, items => \@items };
            $_feedCache{$cacheKey} = { ts => time(), result => copyMenu($filtered) };
            $cb->($withRelay->($filtered, $feedArgs));
        }, $feedArgs);
    };

    $class->SUPER::initPlugin(
        feed => $args{feed},
        tag  => "SpotOnExtras${tag}",
        extra => {
            title       => $args{title},
            subtitle    => $args{subtitle},
            icon        => Plugins::SpotOn::Plugin->_pluginDataFor('icon'),
            needsPlayer => 1,
        },
    );
}

# Clears the 60s memoization cache; called by Plugins::SpotOn::HomeExtras::refresh().
# Relies on %_feedCache being a file-scoped lexical visible to all subs in this file.
sub clearFeedCache { %_feedCache = (); }

1;

package Plugins::SpotOn::HomeExtraRecentlyPlayed;

use strict;
use warnings;

use base qw(Plugins::SpotOn::HomeExtraBase);

sub initPlugin {
    my $class = shift;

    $class->SUPER::initPlugin(
        title    => 'PLUGIN_SPOTON_RECENTLY_PLAYED',
        subtitle => 'PLUGIN_SPOTON',
        feed     => \&Plugins::SpotOn::Plugin::_recentlyPlayedFeed,
        tag      => 'RecentlyPlayed',
    );
}

1;

package Plugins::SpotOn::HomeExtraTopTracks;

use strict;
use warnings;

use base qw(Plugins::SpotOn::HomeExtraBase);

sub initPlugin {
    my $class = shift;

    $class->SUPER::initPlugin(
        title    => 'PLUGIN_SPOTON_TOP_TRACKS',
        subtitle => 'PLUGIN_SPOTON',
        feed     => \&Plugins::SpotOn::Plugin::_topTracksFeed,
        tag      => 'TopTracks',
    );
}

1;

package Plugins::SpotOn::HomeExtraMadeForYou;

use strict;
use warnings;

use base qw(Plugins::SpotOn::HomeExtraBase);

sub initPlugin {
    my $class = shift;

    $class->SUPER::initPlugin(
        title    => 'PLUGIN_SPOTON_MADE_FOR_YOU',
        subtitle => 'PLUGIN_SPOTON',
        feed     => \&Plugins::SpotOn::Plugin::_madeForYouFeed,
        tag      => 'MadeForYou',
    );
}

1;

package Plugins::SpotOn::HomeExtraMainMenu;

use strict;
use warnings;

use base qw(Plugins::SpotOn::HomeExtraBase);

sub initPlugin {
    my $class = shift;

    $class->SUPER::initPlugin(
        title    => 'PLUGIN_SPOTON_MAIN_MENU',
        subtitle => 'PLUGIN_SPOTON',
        feed     => \&Plugins::SpotOn::Plugin::handleFeed,
        tag      => 'MainMenu',
    );
}

1;

package Plugins::SpotOn::HomeExtraPlaylists;

use strict;
use warnings;

use base qw(Plugins::SpotOn::HomeExtraBase);

sub initPlugin {
    my $class = shift;

    $class->SUPER::initPlugin(
        title    => 'PLUGIN_SPOTON_PLAYLISTS',
        subtitle => 'PLUGIN_SPOTON',
        feed     => \&Plugins::SpotOn::Plugin::_userPlaylistsFeed,
        tag      => 'Playlists',
    );
}

1;

# Re-open Plugins::SpotOn::HomeExtras to define refresh() after the
# %_feedCache lexical and clearFeedCache sub are compiled in
# HomeExtraBase above.

package Plugins::SpotOn::HomeExtras;

# refresh()
# Call after account/auth state changes (GH #139).  Clears the 60s
# WR-02 memoization FIRST (otherwise the refresh re-serves stale rows),
# then asks Material Skin to re-fetch home rows via its
# signalHomeExtraUpdate notification.  eval + can() guard handles MS
# versions predating signalHomeExtraUpdate.
# Daemon lifecycle is intentionally NOT signaled here — HomeExtra rows
# carry no daemon-derived content and clearing the memoization on every
# daemon restart would trigger redundant Spotify API refetch bursts.
sub refresh {
    Plugins::SpotOn::HomeExtraBase::clearFeedCache();

    eval {
        Plugins::MaterialSkin::Plugin::signalHomeExtraUpdate()
            if Plugins::MaterialSkin::Plugin->can('signalHomeExtraUpdate');
    };
}

1;
