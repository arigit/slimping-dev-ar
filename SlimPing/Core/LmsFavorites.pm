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
# Core/LmsFavorites.pm - Read-only bridge to LMS-native favourites
#
# LMS stores favourites in an OPML file (prefs/favorites.opml), shared by
# all LMS users.  SlimPing's star store is per-user, so items starred in
# the LMS UI are invisible to getStarred/getStarred2 without this bridge.
#
# Gated by the lms_favourites_bridge preference (default on).  When the
# pref is disabled the bridge returns empty buckets and no timestamp, so
# Lyrion favourites become completely invisible to SlimPing.  The memoised
# state keys on the pref, so flips take effect on the next request without
# a restart.
#
# Stateless utility: class methods only, no constructor.  Results are
# memoised on the favourites OPML file's mtime.
#

package Plugins::SlimPing::Core::LmsFavorites;

use strict;
use warnings;

use Plugins::SlimPing::Core::Logging;

my $log = Plugins::SlimPing::Core::Logging->getLogger();

# Memoisation state: the favourites OPML file only changes when a user
# edits favourites in the LMS UI.  Cache the parsed buckets plus the
# file's mtime; re-resolve when the mtime moves.
my $_list_cache;     # [ mtime, buckets ] from the last resolution
my $_fav_enabled;    # enabled flag at cache time
my $_bridge_on;      # lms_favourites_bridge pref value at cache time
my $_fav_ts;         # ISO8601 string for the cached mtime (undef when absent)

# Resolve the favourites OPML path the way LMS does
# (Slim::Plugin::Favorites::OpmlFavorites::filename).
sub _favoritesPath {
    require Slim::Utils::OSDetect;
    my $dir = Slim::Utils::OSDetect::dirsFor('prefs');
    return undef unless $dir;
    require File::Spec;
    return File::Spec->catdir( $dir, 'favorites.opml' );
}

# Parse the OPML file into buckets when the cached copy is stale.
sub _refresh {
    my $prefs     = Plugins::SlimPing::Core::Logging->getPrefs();
    my $bridge_on = $prefs->get('lms_favourites_bridge') ? 1 : 0;

    # Bridge disabled: empty buckets and no timestamp, with no access to
    # the OPML file or the LMS Favorites singleton at all.  The memoised
    # state keys on $bridge_on so flips take effect on the next request.
    unless ($bridge_on) {
        return if defined $_list_cache && !$_bridge_on;
        $_list_cache  = [ 0, { tracks => {}, albums => {}, artists => {} } ];
        $_fav_enabled = 0;
        $_bridge_on   = 0;
        $_fav_ts      = undef;
        return;
    }

    require Slim::Utils::Favorites;
    my $enabled = Slim::Utils::Favorites->enabled() ? 1 : 0;

    my $path  = _favoritesPath();
    my $mtime = $path ? ( stat $path )[9] // 0 : 0;

    # Re-resolve when the file's mtime moves or a toggle flips.
    return
         if defined $_list_cache
      && $_list_cache->[0] == $mtime
      && $_fav_enabled == $enabled
      && $_bridge_on == $bridge_on;

    my $buckets = { tracks => {}, albums => {}, artists => {} };

    if ($enabled) {
        require Plugins::SlimPing::Core::LibraryMapper;
        require Plugins::SlimPing::Core::Container;
        my $mapper = Plugins::SlimPing::Core::Container->get('library_mapper');

        my $favs = Slim::Utils::Favorites->new();
        if ($favs) {
            for my $item ( @{ $favs->all() || [] } ) {
                my $url = $item->{url} or next;

                if ( $url =~ /^file:/i ) {

                    # Only real library rows match tracks.url; playlist and
                    # radio file URLs do not.
                    my $track = Slim::Schema->search( 'Track', { url => $url } )->first or next;
                    $buckets->{tracks}{ $mapper->encodeId( 'track', $track->id ) } = undef;
                }
                elsif ( $url =~ /^db:/ ) {
                    my $obj = eval { Slim::Schema->objectForUrl($url) };
                    if ($@) {
                        $log->warn("SlimPing: LMS favourite URL resolution failed for $url: $@");
                        next;
                    }
                    next unless $obj;
                    if ( $obj->isa('Slim::Schema::Track') ) {
                        $buckets->{tracks}{ $mapper->encodeId( 'track', $obj->id ) } = undef;
                    }
                    elsif ( $obj->isa('Slim::Schema::Album') ) {
                        $buckets->{albums}{ $mapper->encodeId( 'album', $obj->id ) } = undef;
                    }
                    elsif ( $obj->isa('Slim::Schema::Contributor') ) {
                        $buckets->{artists}{ $mapper->encodeId( 'artist', $obj->id ) } = undef;
                    }

                    # db:genre / db:year / db:work and all plugin schemes: skipped.
                }
            }
        }
    }

    $_list_cache  = [ $mtime, $buckets ];
    $_fav_enabled = $enabled;
    $_bridge_on   = $bridge_on;
    if ( $enabled && $mtime ) {
        $_fav_ts = Plugins::SlimPing::Core::LibraryMapper::_iso8601($mtime);
    }
    else {
        $_fav_ts = undef;
    }
}

# Return the same bucket shape as StarStore::getStars:
# { tracks => {sq_id => undef}, albums => {...}, artists => {...} }.
# Values are undef: LMS favourites carry no timestamps.
#
# Only local-library identities are bridged: file:// track URLs and
# db:album / db:contributor entries.  Radio, plugin and playlist schemes
# have no Subsonic identity and are skipped.
#
# Memoised on the OPML file's mtime.  The cached buckets are shared, so
# callers must treat the result as read-only.  Note: the LMS Favorites
# singleton parses the file once per process, so external edits outside
# the LMS UI are not visible until LMS restarts (mtime only tracks
# UI-driven edits, which update both).
sub list {
    my ($class) = @_;
    _refresh();
    return $_list_cache->[1];
}

# ISO8601 timestamp for the favourites OPML file's mtime -- the stand-in
# star timestamp for bridged items.  undef when favourites are disabled
# or the file is absent.
sub timestamp {
    my ($class) = @_;
    _refresh();
    return $_fav_ts;
}

1;
