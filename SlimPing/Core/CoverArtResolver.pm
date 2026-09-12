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
# Core/CoverArtResolver.pm - Cover art extraction from DBIx objects
#
# Stateless helper that resolves an sq_id to raw image bytes and content
# type by navigating the Slim::Schema ORM object graph.  Exists so that
# handlers do not need to import Slim::Schema directly for cover art.
#
# This module is in the data-access tier (same as LibraryMapper sub-modules)
# and is granted an architecture-check exception.
#

package Plugins::SlimPing::Core::CoverArtResolver;

use strict;
use warnings;

use Slim::Schema;
require Plugins::SlimPing::Core::LibraryMapper;
require Plugins::SlimPing::Core::Logging;

my $log = Plugins::SlimPing::Core::Logging->getLogger();

sub resolve {
    my ( $class, $sq_id ) = @_;

    my ( $type, $raw_id ) = Plugins::SlimPing::Core::LibraryMapper->decodeId($sq_id);
    unless ( defined $type ) {
        return ( undef, undef );
    }

    if ( $type eq 'track' ) {
        return _resolveTrackCover( $raw_id, $sq_id );
    }
    elsif ( $type eq 'album' ) {
        return _resolveAlbumCover( $raw_id, $sq_id );
    }
    elsif ( $type eq 'artist' ) {
        return _resolveArtistCover( $raw_id, $sq_id );
    }
    elsif ( $type eq 'playlist' ) {
        return _resolvePlaylistCover( $raw_id, $sq_id );
    }

    return ( undef, undef );
}

sub _resolveTrackCover {
    my ( $raw_id, $sq_id ) = @_;

    my $track = Slim::Schema->find( 'Track', $raw_id );
    return ( undef, undef ) unless $track;

    my ( $body, $content_type ) = $track->coverArt();

    # Fall back to sibling album tracks.  The first track in album
    # order may have cover=0 (e.g. a CUE-sheet entry whose artwork
    # scan failed), so try all tracks until one yields artwork.
    if ( !$body ) {
        my $album = $track->album();
        if ($album) {
            my $rs = $album->tracks;
            while ( my $c = $rs->next() ) {
                next if $c->id() == $track->id();
                ( $body, $content_type ) = $c->coverArt();
                last if $body;
            }
        }
    }

    # Remote tracks (streaming services): coverArt() only checks a KV
    # cache and returns early without falling through to the filesystem
    # read or URL fetch.  Resolve the cover column directly -- it may
    # contain a local cached file path or an HTTPS URL.
    if ( !$body ) {
        ( $body, $content_type ) = _resolveCoverFromColumn( $track, $sq_id );
    }

    return ( $body, $content_type );
}

sub _resolveAlbumCover {
    my ( $raw_id, $sq_id ) = @_;

    my $album = Slim::Schema->find( 'Album', $raw_id );
    return ( undef, undef ) unless $album;

    # Find any track in the album that has valid cover art.  Some tracks
    # (e.g. CUE-sheet entries) may have cover=0 even when sibling tracks
    # carry the album artwork.
    my ( $body, $content_type );
    my $rs = $album->tracks;
    while ( my $candidate = $rs->next() ) {
        ( $body, $content_type ) = $candidate->coverArt();
        if ( !$body ) {
            ( $body, $content_type ) = _resolveCoverFromColumn( $candidate, $sq_id );
        }
        last if $body;
    }

    return ( $body, $content_type );
}

sub _resolveArtistCover {
    my ( $raw_id, $sq_id ) = @_;

    require Plugins::SlimPing::Core::Container;
    my $mapper       = Plugins::SlimPing::Core::Container->get('library_mapper');
    my $artwork_path = $mapper->getArtistArtworkPath($sq_id);
    if ($artwork_path) {
        my ( $body, $content_type ) = Slim::Music::Artwork->getImageContentAndType($artwork_path);
        return ( $body, $content_type ) if $body;
    }

    my $artist = Slim::Schema->find( 'Contributor', $raw_id );
    if ($artist) {
        my $first_track = Slim::Schema->search(
            'Track',
            {
                'contributorTracks.contributor' => $raw_id,
                'contributorTracks.role'        => [ 1, 5 ],
            },
            { join => 'contributorTracks', rows => 1 }
        )->single;
        if ($first_track) {
            my ( $body, $content_type ) = $first_track->coverArt();
            if ( !$body ) {
                ( $body, $content_type ) = _resolveCoverFromColumn( $first_track, $sq_id );
            }
            return ( $body, $content_type ) if $body;
        }
    }

    return ( undef, undef );
}

sub _resolvePlaylistCover {
    my ( $raw_id, $sq_id ) = @_;

    my $pl = Slim::Schema->find( 'Playlist', $raw_id );
    return ( undef, undef ) unless $pl;

    my ( $body, $content_type );
    my @ptracks = $pl->tracks->all();
    for my $ptrack (@ptracks) {
        ( $body, $content_type ) = $ptrack->coverArt();
        if ( !$body ) {
            ( $body, $content_type ) = _resolveCoverFromColumn( $ptrack, $sq_id );
        }
        last if $body;
    }

    # Fall back to the shipped default artwork when no playlist track
    # has cover art available.
    unless ($body) {
        require Plugins::SlimPing::Core::VirtualPlayer;
        ( $body, $content_type ) = Plugins::SlimPing::Core::VirtualPlayer->readDefaultArtwork('playlist');
    }

    return ( $body, $content_type );
}

# Resolve cover art from the track's cover column directly.
#
# For remote tracks (streaming services), Track::coverArt() only checks a KV
# cache and returns early on miss -- it never falls through to the filesystem
# read or URL fetch that non-remote tracks use.  The cover column may contain:
#   - A local file path (cached by LMS's precache artwork scanner)
#   - An HTTPS URL (as originally provided by the streaming plugin)
#
# Returns (body, content_type) or (undef, undef) on failure.
sub _resolveCoverFromColumn {
    my ( $track, $sq_id ) = @_;

    my $cover = eval { $track->cover() };
    return ( undef, undef ) unless $cover && $cover ne '0';

    # Local cached file -- read it directly, bypassing the KV cache entirely.
    if ( $cover !~ /^\d+$/ && $cover !~ /^https?:/ ) {
        my ( $body, $content_type ) = Slim::Music::Artwork->getImageContentAndType($cover);
        return ( $body, $content_type ) if $body;
    }

    # Remote HTTPS URL -- fetch it and populate the KV cache for future requests.
    if ( $cover =~ /^https?:\/\// ) {
        return _fetchCoverFromUrl( $track, $sq_id, $cover );
    }

    return ( undef, undef );
}

# Fetch cover art from an HTTPS URL and cache it for subsequent coverArt() calls.
# Returns (body, content_type) or (undef, undef) on failure.
sub _fetchCoverFromUrl {
    my ( $track, $sq_id, $cover_url ) = @_;

    # Defence in depth: only fetch HTTPS URLs
    return ( undef, undef ) unless $cover_url =~ /^https:\/\//;

    $log->info("SlimPing: fetching remote cover art for $sq_id");

    require LWP::UserAgent;
    my $ua = LWP::UserAgent->new(
        timeout  => 10,
        agent    => 'SlimPing/0.1',
        max_size => 5_242_880,        # 5 MB limit
    );

    my $res = $ua->get($cover_url);
    unless ( $res->is_success ) {
        $log->warn( "SlimPing: failed to fetch cover art from $cover_url: " . $res->status_line );
        return ( undef, undef );
    }

    my $body         = $res->decoded_content();
    my $content_type = $res->header('Content-Type') || 'image/jpeg';

    # Populate the LMS KV cache so subsequent coverArt() calls hit
    eval {
        my $cache = Slim::Utils::Cache->new();
        $cache->set( 'cover_' . $track->url(), { image => $body, type => $content_type }, 86_400 * 7 );
    };
    if ($@) {
        $log->warn("SlimPing: KV cache populate error for cover art: $@");
    }

    return ( $body, $content_type );
}

1;
