# SlimPing - An LMS Plugin exposing an OpenSubsonic REST API
#
# Copyright (C) 2026 John Willis
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program.  If not, see <http://www.gnu.org/licenses/>.
#

#
# Menu/InfoMenu.pm - LMS menu system exposing SlimPing plugin data
#
# Modes (set via menu_mode):
#   usage        - Now playing, bookmarks, stars per user
#   user_details - Usage + user info and API key summary
#   admin        - All of the above, with an all-users overview
#   off          - Menu hidden via menuCondition
#

package Plugins::SlimPing::Menu::InfoMenu;

use strict;
use warnings;

use Plugins::SlimPing::Core::Logging;
require Plugins::SlimPing::Core::Container;
require Plugins::SlimPing::Core::LibraryMapper;
require Plugins::SlimPing::Utils::IconUtils;
require Plugins::SlimPing::Utils::Params;
require Plugins::SlimPing::Utils::Format;

my $log   = Plugins::SlimPing::Core::Logging->getLogger();
my $prefs = Plugins::SlimPing::Core::Logging->getPrefs();

my $MODE_USER_DETAILS = 'user_details';
my $MODE_ADMIN        = 'admin';

# --- Entry points called from Plugin.pm ---

sub menuCondition {
    my $mode = $prefs->get('menu_mode');
    return 0 if $mode eq 'off';
    my $mgr = Plugins::SlimPing::Core::Container->get('auth_manager');
    return scalar(@{ $mgr->getUsers() }) > 0;
}

sub topLevel {
    my ($client, $cb, $args) = @_;

    my $mode  = $prefs->get('menu_mode');
    my $mgr   = Plugins::SlimPing::Core::Container->get('auth_manager');
    my $users = $mgr->getUsers();

    unless (@$users) {
        $cb->({
            items => [
                {
                    name  => 'No Subsonic users configured',
                    type  => 'text',
                    icon  => Plugins::SlimPing::Utils::IconUtils->getIcon('icon'),
                    line2 => 'Add users via the SlimPing settings page',
                },
            ],
            title => 'SlimPing',
        });
        return;
    }

    my @items;

    # User picker: shown for admin mode always, or multi-user in other modes
    my $show_picker = ($mode eq $MODE_ADMIN) || (scalar(@$users) > 1);
    if ($show_picker) {
        for my $user (@$users) {
            my $display = $mgr->getDisplayName($user->{username});
            my $alias   = $mgr->getAlias($user->{username});
            push @items, {
                name        => $display,
                type        => 'link',
                icon        => Plugins::SlimPing::Utils::IconUtils->getIcon('author'),
                url         => sub { _userMenu($_[0], $_[1], $_[2], { username => $user->{username}, mode => $mode }) },
                passthrough => [ { username => $user->{username}, mode => $mode } ],
                line2       => ($alias ? $user->{username} . ' - ' : '')
                               . ($user->{enabled} ? 'Active' : 'Disabled'),
                nocache     => 1,
            };
        }
    }

    # Admin summary link
    if ($mode eq $MODE_ADMIN) {
        push @items, {
            name    => 'All Users Overview',
            type    => 'link',
            icon    => Plugins::SlimPing::Utils::IconUtils->getIcon('statistics'),
            url     => \&_adminSummaryMenu,
            line2   => 'Active sessions, user counts, key usage',
            nocache => 1,
        };
    }

    # Single user, non-admin: skip picker, go straight to user menu
    if (!$show_picker && scalar(@$users) == 1) {
        _userMenu($client, $cb, $args, { username => $users->[0]{username}, mode => $mode });
        return;
    }

    $cb->({
        items => \@items,
        title => 'SlimPing',
    });
}

# --- User menu (Level 1) ---

sub _userMenu {
    my ($client, $cb, $args, $params) = @_;
    my $username = $params->{username};
    my $mode     = $params->{mode} // $prefs->get('menu_mode');

    my @items;

    # Favourite Tracks -- tracks starred by the user, most recent first
    push @items, {
        name        => 'Favourite Tracks',
        type        => 'link',
        icon        => Plugins::SlimPing::Utils::IconUtils->getIcon('favorite'),
        url         => sub { _favouriteTracksSubMenu($_[0], $_[1], $_[2], { username => $username }) },
        passthrough => [ { username => $username } ],
        line2       => 'Tracks starred from Subsonic clients',
        nocache     => 1,
    };

    # Favourite Albums -- albums starred by the user, alpha sorted
    push @items, {
        name        => 'Favourite Albums',
        type        => 'link',
        icon        => Plugins::SlimPing::Utils::IconUtils->getIcon('album'),
        url         => sub { _favouriteAlbumsSubMenu($_[0], $_[1], $_[2], { username => $username }) },
        passthrough => [ { username => $username } ],
        line2       => 'Albums starred from Subsonic clients',
        nocache     => 1,
    };

    # Favourite Artists -- artists starred by the user, alpha sorted
    push @items, {
        name        => 'Favourite Artists',
        type        => 'link',
        icon        => Plugins::SlimPing::Utils::IconUtils->getIcon('author'),
        url         => sub { _favouriteArtistsSubMenu($_[0], $_[1], $_[2], { username => $username }) },
        passthrough => [ { username => $username } ],
        line2       => 'Artists starred from Subsonic clients',
        nocache     => 1,
    };

    # Rated Tracks -- tracks with explicit 1-5 star ratings
    push @items, {
        name        => 'Rated Tracks',
        type        => 'link',
        icon        => Plugins::SlimPing::Utils::IconUtils->getIcon('rating'),
        url         => sub { _ratedTracksSubMenu($_[0], $_[1], $_[2], { username => $username }) },
        passthrough => [ { username => $username } ],
        line2       => 'Tracks with ratings from Subsonic clients',
        nocache     => 1,
    };

    # Bookmarks -- audiobook and podcast position bookmarks
    push @items, {
        name        => 'Bookmarks',
        type        => 'link',
        icon        => Plugins::SlimPing::Utils::IconUtils->getIcon('bookmarks'),
        url         => sub { _bookmarksSubMenu($_[0], $_[1], $_[2], { username => $username }) },
        passthrough => [ { username => $username } ],
        line2       => 'Audiobook and podcast position bookmarks',
        nocache     => 1,
    };

    # Clients -- connected Subsonic clients and their status
    push @items, {
        name        => 'Clients',
        type        => 'link',
        icon        => Plugins::SlimPing::Utils::IconUtils->getIcon('nowplaying'),
        url         => sub { _clientsSubMenu($_[0], $_[1], $_[2], { username => $username }) },
        passthrough => [ { username => $username } ],
        line2       => 'Connected Subsonic clients and playback status',
        nocache     => 1,
    };

    # User details mode: add combined user info + API keys
    if ($mode eq $MODE_USER_DETAILS || $mode eq $MODE_ADMIN) {
        push @items, {
            name        => 'User Info',
            type        => 'link',
            icon        => Plugins::SlimPing::Utils::IconUtils->getIcon('info'),
            url         => sub { _userInfoDisplay($_[0], $_[1], $_[2], { username => $username }) },
            passthrough => [ { username => $username } ],
            line2       => 'Account status, roles, and API key summary',
            nocache     => 1,
        };
    }

    $cb->({
        items     => \@items,
        title     => 'User: ' . Plugins::SlimPing::Core::Container->get('auth_manager')->getDisplayName($username),
        menuStyle => 'list',
    });
}

# --- Sub-menu handlers ---

sub _bookmarksSubMenu {
    my ($client, $cb, $args, $params) = @_;
    my $username = $params->{username};
    my $mgr      = Plugins::SlimPing::Core::Container->get('auth_manager');
    my $display  = $mgr->getDisplayName($username);

    # Query BookmarkStore directly instead of routing through the REST handler.
    # The old path (Handlers::Bookmarks->getUserBookmarks) worked but was
    # architecturally impure -- menus should query stores, not handlers.
    require Plugins::SlimPing::Core::BookmarkStore;
    my $bookmarks = Plugins::SlimPing::Core::BookmarkStore->getInstance->getUserBookmarks($username);

    my @sorted = sort {
        ($bookmarks->{$b}{changed} // 0) <=> ($bookmarks->{$a}{changed} // 0)
    } keys %$bookmarks;

    my @items;
    for my $sq_id (@sorted) {
        my $bm       = $bookmarks->{$sq_id};
        my $resolved = _resolveTrackDisplay($sq_id);
        my $track    = $resolved ? $resolved->{track}     : undef;
        my $url      = $resolved ? $resolved->{url}       : undef;
        my $cover    = $resolved ? $resolved->{cover_url} : undef;

        if ($track && $url) {
            # position_ms from BookmarkStore is in milliseconds; formatDuration
            # expects seconds.  Divide by 1000 for display.
            my $position_secs = int(($bm->{position} // 0) / 1000);
            push @items, {
                name       => $track->{title} || 'Unknown',
                type       => 'audio',
                url        => $url,
                play       => $url,
                icon       => $cover || Plugins::SlimPing::Utils::IconUtils->getIcon('bookmarks'),
                image      => $cover || Plugins::SlimPing::Utils::IconUtils->getIcon('bookmarks'),
                on_select  => 'play',
                nextWindow => 'nowPlaying',
                line2      => sprintf('%s%s | %s',
                    $position_secs > 0 ? Plugins::SlimPing::Utils::Format->formatDuration($position_secs) . ' | ' : '',
                    $bm->{comment} || 'no comment',
                    scalar localtime($bm->{changed})),
            };
        } else {
            push @items, {
                name  => ($track ? $track->{title} : $sq_id) . ' [unavailable]',
                type  => 'text',
                icon  => Plugins::SlimPing::Utils::IconUtils->getIcon('bookmarks'),
                line2 => $bm->{comment} || '',
            };
        }
    }

    my $limit   = $prefs->get('menu_page_size') // 500;
    my @paged   = _paginateMenu(\@items, $limit, $params, \&_bookmarksSubMenu);

    unless (@paged) {
        $cb->({
            items => [{
                name  => 'No bookmarks yet',
                type  => 'text',
                icon  => Plugins::SlimPing::Utils::IconUtils->getIcon('bookmarks'),
                line2 => 'Bookmarked audiobook positions will appear here',
            }],
            title => "Bookmarks - $display",
        });
        return;
    }

    $cb->({
        items     => \@paged,
        title     => "Bookmarks - $display",
        menuStyle => 'list',
    });
}

# Clients sub-menu: all Subsonic clients that have connected for this user.
# Shows live status (Active with current track, or Idle), last-seen date, and
# now-playing track info.  Active clients show a "Play here" audio item to
# play the current track on the selected LMS player.
sub _clientsSubMenu {
    my ($client, $cb, $args, $params) = @_;
    my $username = $params->{username};
    my $mgr      = Plugins::SlimPing::Core::Container->get('auth_manager');
    my $display  = $mgr->getDisplayName($username);

    require Plugins::SlimPing::Core::SessionStore;
    my $sessions = Plugins::SlimPing::Core::SessionStore->getInstance->getSessionsForUser($username);

    unless (@$sessions) {
        $cb->({
            items => [{
                name  => 'No clients connected yet',
                type  => 'text',
                icon  => Plugins::SlimPing::Utils::IconUtils->getIcon('nowplaying'),
                line2 => 'Connect a Subsonic client and start playback',
            }],
            title => "Clients - $display",
        });
        return;
    }

    my @items;
    for my $sess (@$sessions) {
        my $client_name = $sess->{client_name} || 'Unknown';
        my $last_seen   = $sess->{last_seen_at}
            ? scalar localtime($sess->{last_seen_at})
            : 'never';
        my $track_id    = $sess->{now_playing_track};
        my $is_active   = $track_id ? 1 : 0;
        my $status      = $is_active ? 'Active' : 'Idle';

        my $line2 = "Status: $status  |  Last seen: $last_seen";

        if ($is_active) {
            my $resolved = _resolveTrackDisplay($track_id);
            if ($resolved && $resolved->{track} && $resolved->{url}) {
                my $pos = Plugins::SlimPing::Utils::Format->formatDuration(
                    $sess->{position_secs} // 0
                );
                $line2 = "Now: $resolved->{track}{title}"
                       . ($resolved->{track}{artist} ? " - $resolved->{track}{artist}" : '')
                       . "  |  Pos: $pos  |  Last seen: $last_seen";

                # Info item showing client and current track
                push @items, {
                    name  => "$client_name ($status)",
                    type  => 'text',
                    icon  => Plugins::SlimPing::Utils::IconUtils->getIcon('nowplaying'),
                    line2 => $line2,
                };

                # Playable item to play the current track on this LMS player
                push @items, {
                    name       => "Play current track on this player",
                    type       => 'audio',
                    url        => $resolved->{url},
                    play       => $resolved->{url},
                    icon       => $resolved->{cover_url} || Plugins::SlimPing::Utils::IconUtils->getIcon('play'),
                    on_select  => 'play',
                    nextWindow => 'nowPlaying',
                    line2      => $resolved->{track}{title} . ($resolved->{track}{artist} ? " - $resolved->{track}{artist}" : ''),
                };
                next;
            }
        }

        # Idle client or unresolvable track -- text item only.
        push @items, {
            name  => "$client_name ($status)",
            type  => 'text',
            icon  => $is_active
                ? Plugins::SlimPing::Utils::IconUtils->getIcon('nowplaying')
                : Plugins::SlimPing::Utils::IconUtils->getIcon('time'),
            line2 => $line2,
        };
    }

    $cb->({
        items     => \@items,
        title     => "Clients - $display",
        menuStyle => 'list',
    });
}

# Displays user account info and API key summary as a formatted text drilldown,
# following the same style Bookish uses for audiobook metadata in its InfoMenu.
# When mode is admin, extended API usage and session stats are included.
sub _userInfoDisplay {
    my ($client, $cb, $args, $params) = @_;
    my $username = $params->{username};
    my $mgr  = Plugins::SlimPing::Core::Container->get('auth_manager');
    my $user = $mgr->getUser($username);

    unless ($user) {
        $cb->({
            items => [{ name => 'User not found', type => 'text', icon => Plugins::SlimPing::Utils::IconUtils->getIcon('info') }],
            title => 'User Info',
        });
        return;
    }

    my $mode     = $params->{mode} // $prefs->get('menu_mode');
    my $is_admin = ($mode eq $MODE_ADMIN);
    my $text     = _buildUserInfoText($user, $is_admin);
    my $display  = $mgr->getDisplayName($username);

    $cb->({
        items => [{
            name => $text,
            type => 'text',
            icon => Plugins::SlimPing::Utils::IconUtils->getIcon('info'),
            wrap => 1,
        }],
        title => "User Info - $display",
    });
}

# Favourite Tracks sub-menu: tracks starred by the user, most recent first.
# Each item is type 'audio' -- selecting it plays the track on the active LMS player.
# Paginated via _paginateMenu with the menu_page_size preference.
sub _favouriteTracksSubMenu {
    my ($client, $cb, $args, $params) = @_;
    my $username = $params->{username};
    my $mgr      = Plugins::SlimPing::Core::Container->get('auth_manager');
    my $display  = $mgr->getDisplayName($username);

    require Plugins::SlimPing::Core::StarStore;
    my $stars  = Plugins::SlimPing::Core::StarStore->getInstance->getStars($username);
    my $tracks = $stars->{tracks} // {};
    unless (keys %$tracks) {
        $cb->({
            items => [{
                name  => 'No favourite tracks yet',
                type  => 'text',
                icon  => Plugins::SlimPing::Utils::IconUtils->getIcon('favorite'),
                line2 => 'Starred tracks from Subsonic clients will appear here',
            }],
            title => "Favourite Tracks - $display",
        });
        return;
    }

    # Sort by starred_at descending (most recent first).
    my @sorted = sort { ($tracks->{$b} // 0) <=> ($tracks->{$a} // 0) } keys %$tracks;

    my @items;
    for my $sq_id (@sorted) {
        my $resolved = _resolveTrackDisplay($sq_id);
        next unless $resolved && $resolved->{track} && $resolved->{url};
        push @items, {
            name       => $resolved->{track}{title} || 'Unknown',
            type       => 'audio',
            url        => $resolved->{url},
            play       => $resolved->{url},
            icon       => $resolved->{cover_url} || Plugins::SlimPing::Utils::IconUtils->getIcon('favorite'),
            image      => $resolved->{cover_url} || Plugins::SlimPing::Utils::IconUtils->getIcon('favorite'),
            on_select  => 'play',
            nextWindow => 'nowPlaying',
            line2      => ($resolved->{track}{artist} || '') . ($resolved->{track}{album} ? " - $resolved->{track}{album}" : ''),
        };
    }

    my $limit   = $prefs->get('menu_page_size') // 500;
    my @paged   = _paginateMenu(\@items, $limit, $params, \&_favouriteTracksSubMenu);

    unless (@paged) {
        $cb->({
            items => [{
                name  => 'No favourite tracks found',
                type  => 'text',
                icon  => Plugins::SlimPing::Utils::IconUtils->getIcon('favorite'),
                line2 => 'Starred tracks from Subsonic clients will appear here',
            }],
            title => "Favourite Tracks - $display",
        });
        return;
    }

    $cb->({
        items     => \@paged,
        title     => "Favourite Tracks - $display",
        menuStyle => 'list',
    });
}

# Favourite Albums sub-menu: albums starred by the user, alpha-sorted by title.
# Each item is type 'link' -- selecting it opens _albumTracksSubMenu which shows
# the album's tracks as playable audio items.
sub _favouriteAlbumsSubMenu {
    my ($client, $cb, $args, $params) = @_;
    my $username = $params->{username};
    my $mgr      = Plugins::SlimPing::Core::Container->get('auth_manager');
    my $display  = $mgr->getDisplayName($username);

    require Plugins::SlimPing::Core::StarStore;
    my $stars  = Plugins::SlimPing::Core::StarStore->getInstance->getStars($username);
    my $albums = $stars->{albums} // {};
    unless (keys %$albums) {
        $cb->({
            items => [{
                name  => 'No favourite albums yet',
                type  => 'text',
                icon  => Plugins::SlimPing::Utils::IconUtils->getIcon('favorite'),
                line2 => 'Starred albums from Subsonic clients will appear here',
            }],
            title => "Favourite Albums - $display",
        });
        return;
    }

    # Resolve and sort by album title (alpha).
    my @items;
    for my $sq_id (keys %$albums) {
        my $resolved = _resolveAlbumDisplay($sq_id);
        next unless $resolved;
        push @items, {
            name        => $resolved->{name},
            type        => 'link',
            url         => sub { _albumTracksSubMenu($_[0], $_[1], $_[2], {
                username => $username,
                album_sq_id => $sq_id,
                album_name => $resolved->{name},
            }) },
            passthrough => [ { username => $username, album_sq_id => $sq_id } ],
            icon        => $resolved->{cover} || Plugins::SlimPing::Utils::IconUtils->getIcon('album'),
            image       => $resolved->{cover} || Plugins::SlimPing::Utils::IconUtils->getIcon('album'),
            line2       => $resolved->{artist} || '',
            nocache     => 1,
        };
    }

    @items = sort { lc($a->{name}) cmp lc($b->{name}) } @items;

    my $limit   = $prefs->get('menu_page_size') // 500;
    my @paged   = _paginateMenu(\@items, $limit, $params, \&_favouriteAlbumsSubMenu);

    unless (@paged) {
        $cb->({
            items => [{
                name  => 'No favourite albums found',
                type  => 'text',
                icon  => Plugins::SlimPing::Utils::IconUtils->getIcon('favorite'),
            }],
            title => "Favourite Albums - $display",
        });
        return;
    }

    $cb->({
        items     => \@paged,
        title     => "Favourite Albums - $display",
        menuStyle => 'list',
    });
}

# Album Tracks sub-menu: shows all tracks for a given album as playable audio
# items.  Reached from Favourite Albums and Favourite Artists drill-downs.
sub _albumTracksSubMenu {
    my ($client, $cb, $args, $params) = @_;
    my $username   = $params->{username};
    my $album_sq_id = $params->{album_sq_id};
    my $album_name = $params->{album_name} || 'Unknown Album';

    my $mapper = Plugins::SlimPing::Core::Container->get('library_mapper');
    my (undef, $raw_id) = eval { $mapper->decodeId($album_sq_id) };
    if ($@ || !defined $raw_id) {
        $cb->({
            items => [{ name => 'Album not found', type => 'text',
                        icon => Plugins::SlimPing::Utils::IconUtils->getIcon('album') }],
            title => $album_name,
        });
        return;
    }

    my $album = Slim::Schema->find('Album', $raw_id);
    unless ($album) {
        $cb->({
            items => [{ name => 'Album not found', type => 'text',
                        icon => Plugins::SlimPing::Utils::IconUtils->getIcon('album') }],
            title => $album_name,
        });
        return;
    }

    # Fetch all tracks for this album, ordered by track number.
    my @tracks = $album->tracks->search(
        undef,
        { order_by => 'tracknum', prefetch => ['primary_artist'] }
    )->all();

    unless (@tracks) {
        $cb->({
            items => [{ name => 'No tracks found', type => 'text',
                        icon => Plugins::SlimPing::Utils::IconUtils->getIcon('album') }],
            title => $album_name,
        });
        return;
    }

    my $artwork_id = $album->artwork() || $raw_id;
    my $cover = "/music/$artwork_id/cover.jpg";

    my @items;
    for my $track (@tracks) {
        # Build a sq_id for each track so _resolveTrackDisplay can resolve it.
        my $track_sq_id = $mapper->encodeId('track', $track->id());
        my $resolved = _resolveTrackDisplay($track_sq_id);
        next unless $resolved && $resolved->{url};

        my $artist  = eval { $track->primary_artist->name() } || '';
        my $tn      = $track->tracknum() || '';
        my $title   = $track->title() || 'Unknown';
        my $name    = $tn ? "$tn. $title" : $title;

        push @items, {
            name       => $name,
            type       => 'audio',
            url        => $resolved->{url},
            play       => $resolved->{url},
            icon       => $cover || Plugins::SlimPing::Utils::IconUtils->getIcon('album'),
            image      => $cover || Plugins::SlimPing::Utils::IconUtils->getIcon('album'),
            on_select  => 'play',
            nextWindow => 'nowPlaying',
            line2      => $artist,
        };
    }

    unless (@items) {
        $cb->({
            items => [{ name => 'No playable tracks found', type => 'text',
                        icon => Plugins::SlimPing::Utils::IconUtils->getIcon('album') }],
            title => $album_name,
        });
        return;
    }

    $cb->({
        items     => \@items,
        title     => $album_name,
        menuStyle => 'list',
    });
}

# Favourite Artists sub-menu: artists starred by the user, alpha-sorted by name.
# Each item is type 'link' -- selecting it opens _artistAlbumsSubMenu which shows
# the artist's albums, each linking further to _albumTracksSubMenu.
sub _favouriteArtistsSubMenu {
    my ($client, $cb, $args, $params) = @_;
    my $username = $params->{username};
    my $mgr      = Plugins::SlimPing::Core::Container->get('auth_manager');
    my $display  = $mgr->getDisplayName($username);

    require Plugins::SlimPing::Core::StarStore;
    my $stars   = Plugins::SlimPing::Core::StarStore->getInstance->getStars($username);
    my $artists = $stars->{artists} // {};
    unless (keys %$artists) {
        $cb->({
            items => [{
                name  => 'No favourite artists yet',
                type  => 'text',
                icon  => Plugins::SlimPing::Utils::IconUtils->getIcon('favorite'),
                line2 => 'Starred artists from Subsonic clients will appear here',
            }],
            title => "Favourite Artists - $display",
        });
        return;
    }

    # Resolve and sort by artist name (alpha).
    my @items;
    for my $sq_id (keys %$artists) {
        my $resolved = _resolveArtistDisplay($sq_id);
        next unless $resolved;
        push @items, {
            name        => $resolved->{name},
            type        => 'link',
            url         => sub { _artistAlbumsSubMenu($_[0], $_[1], $_[2], {
                username      => $username,
                artist_sq_id  => $sq_id,
                artist_name   => $resolved->{name},
            }) },
            passthrough => [ { username => $username, artist_sq_id => $sq_id } ],
            icon        => Plugins::SlimPing::Utils::IconUtils->getIcon('author'),
            line2       => 'Browse albums',
            nocache     => 1,
        };
    }

    @items = sort { lc($a->{name}) cmp lc($b->{name}) } @items;

    my $limit   = $prefs->get('menu_page_size') // 500;
    my @paged   = _paginateMenu(\@items, $limit, $params, \&_favouriteArtistsSubMenu);

    unless (@paged) {
        $cb->({
            items => [{
                name  => 'No favourite artists found',
                type  => 'text',
                icon  => Plugins::SlimPing::Utils::IconUtils->getIcon('favorite'),
            }],
            title => "Favourite Artists - $display",
        });
        return;
    }

    $cb->({
        items     => \@paged,
        title     => "Favourite Artists - $display",
        menuStyle => 'list',
    });
}

# Artist Albums sub-menu: shows all albums by a given artist, alpha-sorted.
# Each album is a link that opens _albumTracksSubMenu.  Reached from
# Favourite Artists drill-down.
sub _artistAlbumsSubMenu {
    my ($client, $cb, $args, $params) = @_;
    my $username     = $params->{username};
    my $artist_sq_id = $params->{artist_sq_id};
    my $artist_name  = $params->{artist_name} || 'Unknown Artist';

    my $mapper = Plugins::SlimPing::Core::Container->get('library_mapper');
    my (undef, $raw_id) = eval { $mapper->decodeId($artist_sq_id) };
    if ($@ || !defined $raw_id) {
        $cb->({
            items => [{ name => 'Artist not found', type => 'text',
                        icon => Plugins::SlimPing::Utils::IconUtils->getIcon('author') }],
            title => $artist_name,
        });
        return;
    }

    my $contributor = Slim::Schema->find('Contributor', $raw_id);
    unless ($contributor) {
        $cb->({
            items => [{ name => 'Artist not found', type => 'text',
                        icon => Plugins::SlimPing::Utils::IconUtils->getIcon('author') }],
            title => $artist_name,
        });
        return;
    }

    # Query albums for this contributor, ordered by year then title.
    my @albums = Slim::Schema->rs('Album')->search(
        { 'contributor_album.contributor' => $raw_id },
        {
            join     => ['contributor_album'],
            order_by => ['year', 'title'],
            distinct => 1,
        }
    )->all();

    unless (@albums) {
        $cb->({
            items => [{ name => 'No albums found', type => 'text',
                        icon => Plugins::SlimPing::Utils::IconUtils->getIcon('author') }],
            title => $artist_name,
        });
        return;
    }

    my @items;
    for my $album (@albums) {
        my $album_sq_id = $mapper->encodeId('album', $album->id());
        my $title       = $album->title() || 'Unknown Album';
        my $year        = $album->year() || '';
        my $artwork_id  = $album->artwork() || $album->id();
        my $cover       = "/music/$artwork_id/cover.jpg";
        my $line2       = $year ? "Released: $year" : '';

        push @items, {
            name        => $title,
            type        => 'link',
            url         => sub { _albumTracksSubMenu($_[0], $_[1], $_[2], {
                username   => $username,
                album_sq_id => $album_sq_id,
                album_name => $title,
            }) },
            passthrough => [ { username => $username, album_sq_id => $album_sq_id } ],
            icon        => $cover || Plugins::SlimPing::Utils::IconUtils->getIcon('album'),
            image       => $cover || Plugins::SlimPing::Utils::IconUtils->getIcon('album'),
            line2       => $line2,
            nocache     => 1,
        };
    }

    $cb->({
        items     => \@items,
        title     => $artist_name,
        menuStyle => 'list',
    });
}

# Rated Tracks sub-menu: tracks with explicit 1-5 star ratings, sorted by rating
# descending then title alpha.  Each item is type 'audio' -- plays on the active
# LMS player.  The rating is displayed in line2 as visual stars (e.g. "★★★★☆").
sub _ratedTracksSubMenu {
    my ($client, $cb, $args, $params) = @_;
    my $username = $params->{username};
    my $mgr      = Plugins::SlimPing::Core::Container->get('auth_manager');
    my $display  = $mgr->getDisplayName($username);

    require Plugins::SlimPing::Core::RatingStore;
    my $ratings = Plugins::SlimPing::Core::RatingStore->getInstance->getRatedTracks($username);

    unless (@$ratings) {
        $cb->({
            items => [{
                name  => 'No rated tracks yet',
                type  => 'text',
                icon  => Plugins::SlimPing::Utils::IconUtils->getIcon('rating'),
                line2 => 'Tracks rated via Subsonic clients will appear here',
            }],
            title => "Rated Tracks - $display",
        });
        return;
    }

    # Resolve all rated tracks and build display items.
    my @items;
    for my $entry (@$ratings) {
        my $sq_id    = $entry->{sq_id};
        my $rating   = $entry->{rating};
        my $resolved = _resolveTrackDisplay($sq_id);
        next unless $resolved && $resolved->{track} && $resolved->{url};

        # Build visual star display: filled stars for the rating, empty for remainder.
        my $stars_str = ("\x{2605}" x $rating) . ("\x{2606}" x (5 - $rating));
        my $line2 = ($resolved->{track}{artist} || '')
                  . ($resolved->{track}{album} ? " - $resolved->{track}{album}" : '')
                  . " - $stars_str";

        push @items, {
            name       => $resolved->{track}{title} || 'Unknown',
            type       => 'audio',
            url        => $resolved->{url},
            play       => $resolved->{url},
            icon       => $resolved->{cover_url} || Plugins::SlimPing::Utils::IconUtils->getIcon('rating'),
            image      => $resolved->{cover_url} || Plugins::SlimPing::Utils::IconUtils->getIcon('rating'),
            on_select  => 'play',
            nextWindow => 'nowPlaying',
            line2      => $line2,
        };
    }

    # Alpha-sort within rating groups (store already returns rating-desc order).
    @items = sort { lc($a->{name}) cmp lc($b->{name}) } @items;

    my $limit   = $prefs->get('menu_page_size') // 500;
    my @paged   = _paginateMenu(\@items, $limit, $params, \&_ratedTracksSubMenu);

    unless (@paged) {
        $cb->({
            items => [{
                name  => 'No rated tracks found',
                type  => 'text',
                icon  => Plugins::SlimPing::Utils::IconUtils->getIcon('rating'),
            }],
            title => "Rated Tracks - $display",
        });
        return;
    }

    $cb->({
        items     => \@paged,
        title     => "Rated Tracks - $display",
        menuStyle => 'list',
    });
}

sub _adminSummaryMenu {
    my ($client, $cb) = @_;
    my $text = _buildAdminSummaryText();

    $cb->({
        items => [{
            name => $text,
            type => 'text',
            icon => Plugins::SlimPing::Utils::IconUtils->getIcon('statistics'),
            wrap => 1,
        }],
        title => 'All Users Overview',
    });
}

# Resolves track display data from a sq_id.  Returns a hashref with track, url,
# and cover_url, or undef if the track cannot be found.
# url uses db:track.id=<id> format so LMS resolves the track directly from the
# database, preserving library metadata in Now Playing and track info menus.
sub _resolveTrackDisplay {
    my ($sq_id) = @_;
    return undef unless $sq_id;
    my $mapper    = Plugins::SlimPing::Core::Container->get('library_mapper');
    my $track     = $mapper->getTrackById($sq_id);
    return undef unless $track;
    return {
        track     => $track,
        url       => $mapper->resolveTrackDbUrl($sq_id),
        cover_url => $mapper->resolveCoverArtUrl($sq_id),
    };
}

# Resolves album display data from a sq_id for menu rendering.
# Returns a hashref with name, artist, cover, and raw_id, or undef if the album
# cannot be found.  The raw_id is stashed so that _albumTracksSubMenu can
# resolve track listings without re-decoding the sq_id.
sub _resolveAlbumDisplay {
    my ($sq_id) = @_;
    return undef unless $sq_id;
    my $mapper = Plugins::SlimPing::Core::Container->get('library_mapper');

    # Decode to get the raw ID for metadata lookup.
    my (undef, $raw_id) = eval { $mapper->decodeId($sq_id) };
    return undef if $@ || !defined $raw_id;

    my $album = Slim::Schema->find('Album', $raw_id);
    return undef unless $album;

    my $artist_name = '';
    if (my $contributor = $album->contributor()) {
        $artist_name = $contributor->name() || '';
    }

    # Use $album->artwork() for the correct cover-art ID (not raw album ID).
    # Fall back to raw_id for albums without explicit artwork.
    my $artwork_id = $album->artwork() || $raw_id;

    return {
        name    => $album->title() || 'Unknown Album',
        artist  => $artist_name,
        cover   => "/music/$artwork_id/cover.jpg",
        raw_id  => $raw_id,
    };
}

# Resolves artist display data from a sq_id for menu rendering.
# Returns a hashref with name and raw_id, or undef if the artist cannot be found.
# The raw_id is stashed so that _artistAlbumsSubMenu can resolve album listings
# without re-decoding the sq_id.
sub _resolveArtistDisplay {
    my ($sq_id) = @_;
    return undef unless $sq_id;
    my $mapper = Plugins::SlimPing::Core::Container->get('library_mapper');

    my (undef, $raw_id) = eval { $mapper->decodeId($sq_id) };
    return undef if $@ || !defined $raw_id;

    my $contributor = Slim::Schema->find('Contributor', $raw_id);
    return undef unless $contributor;

    return {
        name   => $contributor->name() || 'Unknown Artist',
        raw_id => $raw_id,
    };
}

# Builds a multi-line text block for the User Info drilldown page, following the
# same style Bookish uses for audiobook metadata in its BookInfoRenderer.
# When $is_admin is true, extended API usage and session details are included.
sub _buildUserInfoText {
    my ($user, $is_admin) = @_;
    my @lines;

    my $mgr     = Plugins::SlimPing::Core::Container->get('auth_manager');
    my $state   = Plugins::SlimPing::Core::Container->get('session_state');
    my $session = $state->getState($user->{username});

    # Account section
    push @lines, 'Account';
    push @lines, '-------';
    push @lines, sprintf('Username:  %s', $user->{username});
    push @lines, sprintf('Status:    %s', $user->{enabled} ? 'Enabled' : 'Disabled');

    my $alias = $mgr->getAlias($user->{username});
    push @lines, sprintf('Alias:     %s', $alias || '(none)');

    push @lines, sprintf('Role:      %s', $user->{admin} ? 'Administrator' : 'Standard user');

    # API keys section
    push @lines, '';
    my $keys = $user->{api_keys} || [];
    push @lines, sprintf('API Keys:  %d', scalar @$keys);

    for my $key (@$keys) {
        my $label     = $key->{label} || 'Unlabelled';
        my $prefix    = $key->{prefix} || '--------';
        my $created   = scalar localtime($key->{created_at});
        my $last_used = $key->{last_used_at} ? scalar localtime($key->{last_used_at}) : 'never';
        push @lines, sprintf('  %s  (%s...)', $label, $prefix);
        push @lines, sprintf('    Created: %s', $created);
        push @lines, sprintf('    Last used: %s', $last_used);
    }

    # Session info section
    push @lines, '';
    push @lines, 'Session';
    push @lines, '-------';
    push @lines, sprintf('Last seen:   %s',
        $session->{last_seen} ? scalar localtime($session->{last_seen}) : 'never');
    push @lines, sprintf('Client:      %s', $session->{client_name} || 'unknown');

    # Admin-only extended stats
    if ($is_admin) {
        push @lines, '';
        push @lines, 'Admin: API Usage';
        push @lines, '----------------';
        my $active = $session->{now_playing} ? 'Active' : 'Idle';
        push @lines, sprintf('Playback:    %s', $active);

        if ($session->{now_playing} && $session->{now_playing}{track_id}) {
            my $np = $session->{now_playing};
            my $resolved = _resolveTrackDisplay($np->{track_id});
            if ($resolved && $resolved->{track}) {
                push @lines, sprintf('Now playing: %s - %s',
                    $resolved->{track}{title} || '?',
                    $resolved->{track}{artist} || '?');
                push @lines, sprintf('Position:    %s', Plugins::SlimPing::Utils::Format->formatDuration($np->{position_secs}));
            }
        }
    }

    return join("\n", @lines);
}

# Builds a multi-line admin summary report showing all users, session state,
# and API key counts in a single scrollable text panel.
sub _buildAdminSummaryText {
    my @lines;
    my $mgr   = Plugins::SlimPing::Core::Container->get('auth_manager');
    my $users = $mgr->getUsers();
    my $state = Plugins::SlimPing::Core::Container->get('session_state');
    my $active_sessions = $state->getActiveSessions();

    my $total_keys    = 0;
    my $enabled_count = 0;
    for my $u (@$users) {
        $enabled_count++ if $u->{enabled};
        $total_keys += scalar(@{ $u->{api_keys} || [] });
    }

    push @lines, 'SlimPing - All Users Overview';
    push @lines, '================================';
    push @lines, '';
    push @lines, sprintf('Total users:    %d (%d enabled)', scalar(@$users), $enabled_count);
    push @lines, sprintf('Active clients: %d', scalar(@$active_sessions));
    push @lines, sprintf('Total API keys: %d', $total_keys);
    push @lines, '';
    push @lines, 'Per-User Detail';
    push @lines, '---------------';

    for my $user (@$users) {
        my $display = $mgr->getDisplayName($user->{username});
        my $sess    = $state->getState($user->{username});
        my $np      = $sess->{now_playing};

        my $status = $user->{enabled} ? 'Enabled' : 'Disabled';
        push @lines, '';

        if ($mgr->getAlias($user->{username})) {
            push @lines, sprintf('%s  (%s)  [%s]', $display, $user->{username}, $status);
        } else {
            push @lines, sprintf('%s  [%s]', $display, $status);
        }

        push @lines, sprintf('  Keys: %d  |  Last seen: %s',
            scalar(@{ $user->{api_keys} || [] }),
            $sess->{last_seen} ? scalar localtime($sess->{last_seen}) : 'never');

        if ($np && $np->{track_id}) {
            my $resolved = _resolveTrackDisplay($np->{track_id});
            if ($resolved && $resolved->{track}) {
                push @lines, sprintf('  Playing: %s - %s  (%s)',
                    $resolved->{track}{title} || '?',
                    $resolved->{track}{artist} || '?',
                    Plugins::SlimPing::Utils::Format->formatDuration($np->{position_secs}));
            }
        }
    }

    return join("\n", @lines);
}

# --- Helpers ---

# Slices @$items from $params->{offset} up to $limit entries and appends a
# "More..." link item if items remain beyond the page.  The "More..." item
# captures the incremented offset in BOTH the url closure's constructed params
# hashref AND the passthrough arrayref, matching the existing InfoMenu pattern
# where sub-handlers read params from the closure, not from $args->{passthrough}.
sub _paginateMenu {
    my ($items, $limit, $params, $sub_handler_ref) = @_;

    my $total  = scalar @$items;
    my $offset = $params->{offset} // 0;

    my @page = splice(@$items, $offset, $limit);
    my $remaining = $total - ($offset + scalar @page);

    if ($remaining > 0) {
        my $next_offset = $offset + scalar @page;
        push @page, {
            name        => "More... ($remaining remaining)",
            type        => 'link',
            icon        => Plugins::SlimPing::Utils::IconUtils->getIcon('forward'),
            url         => sub {
                $sub_handler_ref->(
                    $_[0], $_[1], $_[2],
                    { %$params, offset => $next_offset }
                );
            },
            passthrough => [ { %$params, offset => $next_offset } ],
            nocache     => 1,
        };
    }

    return @page;
}

1;
