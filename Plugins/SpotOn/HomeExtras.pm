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
    $args{feed} = sub {
        my ($client, $cb, $feedArgs) = @_;

        my $cacheKey = join('_', $tag, ($client ? $client->id : ''), ($feedArgs->{index} // ''), ($feedArgs->{quantity} // ''));
        my $cached = $_feedCache{$cacheKey};

        if ($cached && time() - $cached->{ts} < 60) {
            $cb->(copyMenu($cached->{result}));
            return;
        }

        delete $_feedCache{$cacheKey} if $cached;

        $origFeed->($client, sub {
            my $result = shift;
            my @items = grep { ($_->{type} || '') ne 'textarea' }
                        @{ $result->{items} || [] };
            my $filtered = { %$result, items => \@items };
            $_feedCache{$cacheKey} = { ts => time(), result => copyMenu($filtered) };
            $cb->($filtered);
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
