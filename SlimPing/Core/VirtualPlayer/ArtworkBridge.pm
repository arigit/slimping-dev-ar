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
# Core/VirtualPlayer/ArtworkBridge.pm - Artwork cache and share-artwork helpers
#
# Extracted from VirtualPlayer.pm.  Manages an in-memory artwork cache
# keyed by "$token:$track_idx", populated when the streaming Song object
# resolves so that shareMetadata.view and InternetRadio endpoints can
# serve plugin-injected artwork (BBC Sounds, etc.) that lives on the
# in-flight Song, not in the database.  Also provides fallback artwork
# resolution and default icon reading.
#

package Plugins::SlimPing::Core::VirtualPlayer::ArtworkBridge;

use strict;
use warnings;

require Plugins::SlimPing::Core::Container;
require Plugins::SlimPing::Core::Logging;

my $log = Plugins::SlimPing::Core::Logging->getLogger();

# In-memory artwork cache keyed by "$token:$track_idx".  Populated when the
# streaming Song object resolves (200ms after execute) so that shareMetadata.view
# can serve plugin-injected artwork (BBC Sounds, etc.) that lives on the in-flight
# Song, not in the database.  Cleaned up lazily on cache miss when the player
# that owns the entry has disconnected.
my %_artwork_cache;

# Cross-module accessor: called by StreamEnricher to cache artwork data
# from enrichment timers (both remote async fetch and local coverArt).
sub _setArtworkCache {
    my ( $key, $data, $type ) = @_;
    return unless defined $key && defined $data && length $data;
    $_artwork_cache{$key} = {
        data => $data,
        type => $type || 'image/jpeg',
    };
}

# Retrieve artwork previously cached by the streaming timer callback.
# Returns ($data, $content_type) or () on miss.  On miss, prunes the entry
# so stale data doesn't accumulate.
sub getArtworkFromCache {
    my ( $class, $key ) = @_;
    return () unless defined $key && exists $_artwork_cache{$key};

    my $entry = $_artwork_cache{$key};
    return () unless $entry && $entry->{data};

    return ( $entry->{data}, $entry->{type} );
}

# Fallback: resolve cover art for a track via Slim::Schema when no live
# streaming song object exists (pre-stream or post-disconnect).
sub resolveCoverArtForTrack {
    my ( $class, $sq_id ) = @_;
    return () unless defined $sq_id;

    my $mapper = Plugins::SlimPing::Core::Container->get('library_mapper');
    my ( undef, $raw_id ) = $mapper->decodeId($sq_id);
    return () unless defined $raw_id;

    my $track = Slim::Schema->find( 'Track', $raw_id );
    return () unless $track;

    my ( $body, $type ) = eval { $track->coverArt() };
    if ($@) {
        $log->debug("SlimPing: coverArt unavailable for $sq_id: $@");
        return ();
    }
    return () unless $body;
    return ( $body, $type || 'image/jpeg' );
}

# On-demand artwork lookup from a live virtual player.  Iterates LMS player
# clients matching $player_address_prefix, reads the underlying schema track
# from $client->playingSong() and calls coverArt() on it, caching the result
# in %_artwork_cache under $cache_key.  Returns ($data, $type) or ().
#
# playingSong() returns a Slim::Player::Song (which has no coverArt method),
# so we must call ->track() to get the underlying Slim::Schema::Track.
sub getArtworkFromLivePlayer {
    my ( $class, $player_address_prefix, $cache_key ) = @_;
    return () unless defined $player_address_prefix && length $player_address_prefix;
    return () unless defined $cache_key             && length $cache_key;

    for my $client ( Slim::Player::Client::clients() ) {
        next unless index( $client->id(), $player_address_prefix ) == 0;
        my $song = eval { $client->playingSong() };
        next unless $song;
        my $track = eval { $song->track() };
        next unless $track;
        my ( $data, $type ) = eval { $track->coverArt() };
        if ($@) {
            $log->debug( "SlimPing: coverArt error for live player " . $client->id . ": $@" );
        }
        next unless $data;

        $_artwork_cache{$cache_key} = {
            data => $data,
            type => $type || 'image/jpeg',
        };
        $log->debug("SlimPing: artwork cached live for $cache_key");
        return ( $data, $type || 'image/jpeg' );
    }

    return ();
}

# Resolve cover art directly from an LMS raw track ID -- no live player or
# cache needed.  Used as a fallback by shareMetadata so the HTML share page
# can show artwork before any track is streamed.
# Returns ($data, $content_type) or ().
sub getArtworkFromTrackId {
    my ( $class, $track_raw_id ) = @_;

    my $track = Slim::Schema->find( 'Track', $track_raw_id )
      or return ();
    my ( $data, $type ) = eval { $track->coverArt() };
    if ($@) {
        $log->warn("SlimPing: coverArt failed for track $track_raw_id: $@");
        return ();
    }
    return () unless $data;
    return ( $data, $type || 'image/jpeg' );
}

# Read a shipped default icon from the plugin's images directory.
# $kind is 'radio' (radio_default.png), 'dpl' (search_svg.png), or 'share' (music_default.png).
# Returns ($data, $content_type) or () if the file cannot be read.
# This is the absolute last resort -- valid tokens must never 404 on the
# artwork metadata endpoints.
sub readDefaultArtwork {
    my ( $class, $kind ) = @_;
    $kind ||= 'radio';

    require Slim::Music::Artwork;

    my $filename = $kind eq 'radio'  ? 'radio_default.png'
                 : $kind eq 'dpl'    ? 'search_svg.png'
                 :                     'music_default.png';

    # Primary: resolve from this module's own filesystem location via %INC.
    # VirtualPlayer.pm lives at .../SlimPing/Core/VirtualPlayer.pm and the
    # images are at .../SlimPing/HTML/EN/plugins/SlimPing/html/images/ --
    # so we navigate from the module path.  Works regardless of install type
    # (PluginManager, git checkout, symlink farm).
    my $vp_path = $INC{'Plugins/SlimPing/Core/VirtualPlayer.pm'};
    if ($vp_path) {
        require File::Basename;
        my $base_dir = File::Basename::dirname( File::Basename::dirname($vp_path) );
        my $path     = "$base_dir/HTML/EN/plugins/SlimPing/html/images/$filename";
        if ( -f $path ) {
            my ( $data, $type ) = Slim::Music::Artwork->getImageContentAndType($path);
            if ($data) {
                $log->debug("SlimPing: default artwork read from $path");
                return ( $data, $type || 'image/png' );
            }
        }
    }

    # Fallback: check the main LMS HTML tree -- works in development installs
    # where the plugin tree is symlinked into the LMS HTML directory.
    require Slim::Utils::OSDetect;
    for my $html_dir ( Slim::Utils::OSDetect::dirsFor('HTML') ) {
        my $path = "$html_dir/EN/plugins/SlimPing/html/images/$filename";
        next unless -f $path;
        my ( $data, $type ) = Slim::Music::Artwork->getImageContentAndType($path);
        if ($data) {
            $log->debug("SlimPing: default artwork read from $path");
            return ( $data, $type || 'image/png' );
        }
    }

    $log->warn("SlimPing: default $kind artwork not found ($filename)");
    return ();
}

1;
