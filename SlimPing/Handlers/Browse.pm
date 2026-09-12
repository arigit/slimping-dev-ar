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
# Handlers/Browse.pm - Browse API handlers for library exploration
#
# Implements Subsonic API endpoints for browsing music library: artists,
# albums, tracks, genres, and folder hierarchy. Provides both indexed
# (getArtists/getIndexes) and directory (getMusicDirectory) browsing patterns.
#
# When this module exceeds ~400 lines, split by concern into:
#   Handlers/Browse/Artists.pm    -- getArtists, getArtist, getIndexes,
#                                    getMusicDirectory, getArtistInfo, getArtistInfo2
#   Handlers/Browse/Albums.pm     -- getAlbum, getAlbumInfo, getAlbumInfo2
#   Handlers/Browse/NowPlaying.pm -- getNowPlaying, getTopSongs, getGenres,
#                                    getMusicFolders
#   Handlers/Browse/Related.pm    -- getSimilarSongs, getSimilarSongs2
#

package Plugins::SlimPing::Handlers::Browse;

use strict;
use warnings;

use Scalar::Util qw(blessed);

use Slim::Player::Client;

use Plugins::SlimPing::API::Router;
use Plugins::SlimPing::Core::LibraryMapper;
use Plugins::SlimPing::Core::Logging;
require Plugins::SlimPing::Core::Container;
require Plugins::SlimPing::Utils::Errors;
require Plugins::SlimPing::Utils::Params;


sub registerHandlers {
    my $class = shift;
    Plugins::SlimPing::API::Router->registerHandler( 'getMusicFolders',
        \&getMusicFolders );
    Plugins::SlimPing::API::Router->registerHandler( 'getArtists',
        \&getArtists );
    Plugins::SlimPing::API::Router->registerHandler( 'getArtist', \&getArtist );
    Plugins::SlimPing::API::Router->registerHandler( 'getAlbum',  \&getAlbum );
    Plugins::SlimPing::API::Router->registerHandler( 'getSong',   \&getSong );
    Plugins::SlimPing::API::Router->registerHandler( 'getIndexes',
        \&getIndexes );
    Plugins::SlimPing::API::Router->registerHandler( 'getMusicDirectory',
        \&getMusicDirectory );
    Plugins::SlimPing::API::Router->registerHandler( 'getGenres', \&getGenres );
    Plugins::SlimPing::API::Router->registerHandler( 'getArtistInfo',
        \&getArtistInfo );
    Plugins::SlimPing::API::Router->registerHandler( 'getArtistInfo2',
        \&getArtistInfo2 );
    Plugins::SlimPing::API::Router->registerHandler( 'getAlbumInfo',
        \&getAlbumInfo );
    Plugins::SlimPing::API::Router->registerHandler( 'getAlbumInfo2',
        \&getAlbumInfo );
    Plugins::SlimPing::API::Router->registerHandler( 'getNowPlaying',
        \&getNowPlaying );
    Plugins::SlimPing::API::Router->registerHandler( 'getTopSongs',
        \&getTopSongs );
    Plugins::SlimPing::API::Router->registerHandler( 'getSimilarSongs',
        \&getSimilarSongs );
    Plugins::SlimPing::API::Router->registerHandler( 'getSimilarSongs2',
        \&getSimilarSongs2 );
}

my $mapper = sub { Plugins::SlimPing::Core::Container->get('library_mapper') };
my $libId =
  sub { Plugins::SlimPing::Core::LibraryMapper->decodeLibraryParam( $_[0] ) };

sub getMusicFolders {
    my ($args) = @_;
    return {
        musicFolders => { musicFolder => $mapper->()->getMusicFolders() } };
}

sub getArtists {
    my ($args)  = @_;
    my $lib     = $libId->( $args->{params} );
    my $artists = $mapper->()->getArtists( library_id => $lib ) // [];

    # Build alphabetical index structure expected by the Subsonic spec
    my %index;
    for my $artist (@$artists) {
        my $letter = uc( substr( $artist->{name}, 0, 1 ) );
        $letter = '#' if $letter !~ /[A-Z]/;
        push @{ $index{$letter} }, $artist;
    }

    my @indexes = map { { name => $_, artist => $index{$_} } } sort keys %index;

    my $ignored_articles = Plugins::SlimPing::Core::Logging->getServerPrefs()
        ->get('ignoredarticles') // '';

    return {
        artists => {
            ignoredArticles => $ignored_articles,
            index           => \@indexes,
        }
    };
}

sub getArtist {
    my ($args) = @_;
    my $id = $args->{params}{id}
      or return Plugins::SlimPing::Utils::Errors->missingParam('id');
    my $lib = $libId->( $args->{params} );

    my $artist = $mapper->()->getArtistById($id);
    return Plugins::SlimPing::Utils::Errors->notFound('Artist')
      unless $artist;

    $artist->{album} =
      $mapper->()->getAlbumsByArtist( $id, library_id => $lib );

    return { artist => $artist };
}

sub getAlbum {
    my ($args) = @_;
    my $id = $args->{params}{id}
      or return Plugins::SlimPing::Utils::Errors->missingParam('id');

    my $album = $mapper->()->getAlbumById($id);
    return Plugins::SlimPing::Utils::Errors->notFound('Album')
      unless $album;

    $album->{song} = $mapper->()->getTracksByAlbum($id);

    return { album => $album };
}

sub getSong {
    my ($args) = @_;
    my $id = $args->{params}{id}
      or return Plugins::SlimPing::Utils::Errors->missingParam('id');

    my $track = $mapper->()->getTrackById($id);
    return Plugins::SlimPing::Utils::Errors->notFound('Song')
      unless $track;

    return { song => $track };
}

sub getIndexes {
    my ($args) = @_;
    my $p = $args->{params};

    my $last_scan = Plugins::SlimPing::Core::Logging->getPrefs()->get('lastScanTimestampMs');
    my $if_modified = $p->{ifModifiedSince} // 0;

    if ($last_scan && $last_scan <= $if_modified) {
        return {
            indexes => {
                lastModified    => $last_scan,
                ignoredArticles => Plugins::SlimPing::Core::Logging->getServerPrefs()
                    ->get('ignoredarticles') // '',
                index           => [],
            },
        };
    }

  # getIndexes is the legacy filesystem-style variant -- built from the same tag
  # data as getArtists so no real paths are ever exposed.
    my $artists_response = getArtists($args);
    return {
        indexes => {
            lastModified    => $last_scan || int(time() * 1000),
            ignoredArticles => Plugins::SlimPing::Core::Logging->getServerPrefs()
                ->get('ignoredarticles') // '',
            index           => $artists_response->{artists}{index},
        }
    };
}

sub getMusicDirectory {
    my ($args) = @_;
    my $id = $args->{params}{id}
      or return Plugins::SlimPing::Utils::Errors->missingParam('id');
    my $lib = $libId->( $args->{params} );

    my ( $type, $raw_id ) =
      Plugins::SlimPing::Core::LibraryMapper->decodeId($id);
    return Plugins::SlimPing::Utils::Errors->notFound('Music directory') unless $type;

    if ( $type eq 'artist' ) {
        my $artist = $mapper->()->getArtistById($id);
        return Plugins::SlimPing::Utils::Errors->notFound('Artist')
          unless $artist;
        return {
            directory => {
                id         => $id,
                name       => $artist->{name},
                parent     => 0,   # "All Music" folder (integer per spec)
                starred    => $artist->{starred},
                userRating => $artist->{userRating},
                child      =>
                  $mapper->()->getAlbumsByArtist( $id, library_id => $lib ),
            }
        };
    }

    if ( $type eq 'album' ) {
        my $album = $mapper->()->getAlbumById($id);
        return Plugins::SlimPing::Utils::Errors->notFound('Album')
          unless $album;
        return {
            directory => {
                id         => $id,
                name       => $album->{name},
                parent     => $album->{artistId},
                starred    => $album->{starred},
                userRating => $album->{userRating},
                child      => $mapper->()->getTracksByAlbum($id),
            }
        };
    }

    return Plugins::SlimPing::Utils::Errors->error(70, 'Unsupported directory type');
}

sub getGenres {
    my ($args) = @_;
    my $lib = $libId->( $args->{params} );
    return {
        genres => { genre => $mapper->()->getGenres( library_id => $lib ) } };
}

sub getArtistInfo {
    my ($args) = @_;
    my $p      = $args->{params};
    my $id     = $p->{id}
      or return Plugins::SlimPing::Utils::Errors->missingParam('id');

    my $info = $mapper->()->shapeArtistInfoLegacy(
        $id,
        count             => $p->{count} // 20,
        includeNotPresent => $p->{includeNotPresent} ? 1 : 0,
    );

    return Plugins::SlimPing::Utils::Errors->notFound('Artist')
      unless $info;

    return { artistInfo => $info };
}

sub getArtistInfo2 {
    my ($args) = @_;
    my $p      = $args->{params};
    my $id     = $p->{id}
      or return Plugins::SlimPing::Utils::Errors->missingParam('id');

    my $info = $mapper->()->shapeArtistInfo(
        $id,
        count             => $p->{count} // 20,
        includeNotPresent => $p->{includeNotPresent} ? 1 : 0,
    );

    return Plugins::SlimPing::Utils::Errors->notFound('Artist')
      unless $info;

    return { artistInfo2 => $info };
}

sub getAlbumInfo {
    my ($args) = @_;
    my $id = $args->{params}{id}
      or return Plugins::SlimPing::Utils::Errors->missingParam('id');

    my ( undef, $raw_id ) =
      Plugins::SlimPing::Core::LibraryMapper->decodeId($id);
    return Plugins::SlimPing::Utils::Errors->notFound('Album')
      unless defined $raw_id;

    my $album = Plugins::SlimPing::Core::Container->get('library_mapper')->getAlbumObject($raw_id);
    return Plugins::SlimPing::Utils::Errors->notFound('Album')
      unless $album;

    require Plugins::SlimPing::API::ResponseFormatter;
    require URI::Escape;

    my $sq_id    = Plugins::SlimPing::Core::LibraryMapper->encodeId( 'album', $raw_id );
    my $artist   = $album->contributor();
    my $artist_name = $artist ? $artist->name() : '';
    my $album_name  = $album->title() // '';
    my $last_fm  = '';
    if ( length $artist_name && length $album_name ) {
        $last_fm = 'https://www.last.fm/music/'
          . URI::Escape::uri_escape_utf8($artist_name)
          . '/'
          . URI::Escape::uri_escape_utf8($album_name);
    }

    return {
        albumInfo => {
            notes          => '',
            musicBrainzId  => $album->musicbrainz_id() || '',
            lastFmUrl      => $last_fm,
            smallImageUrl  => Plugins::SlimPing::API::ResponseFormatter->coverArtUrl( $sq_id, size => 300 ),
            mediumImageUrl => Plugins::SlimPing::API::ResponseFormatter->coverArtUrl( $sq_id, size => 600 ),
            largeImageUrl  => Plugins::SlimPing::API::ResponseFormatter->coverArtUrl( $sq_id, size => 1200 ),
        }
    };
}

sub getNowPlaying {
    my ($args) = @_;
    my @entries;

    # LMS hardware players currently playing
    my @player_tracks;
    my @player_clients;
    for my $client ( Slim::Player::Client::clients() ) {
        next unless $client->isPlaying();

        # Skip SlimPing share-stream virtual players -- they are internal
        # unauthenticated sinks, not real user players.  Their IDs start
        # with slimping-share- and libopensonic expects integer playerId
        # values.
        next if index( $client->id(), 'slimping-share-' ) >= 0;

        my $song  = $client->playingSong() or next;
        my $track = $song->currentTrack()  or next;
        next unless blessed($track) && $track->can('audio') && $track->audio();
        push @player_tracks,  $track;
        push @player_clients, $client;
    }

    my $track_genre = $mapper->()->batchFetchTrackGenres(\@player_tracks);

    for my $i ( 0 .. $#player_tracks ) {
        my $track  = $player_tracks[$i];
        my $client = $player_clients[$i];

        my $entry =
          $mapper->()->shapeTrack( $track, $track_genre->{ $track->id() } );
        $entry->{username}   = 'admin';
        $entry->{minutesAgo} = 0;
        $entry->{playerId}   = 0;  # integer per spec; no endpoint consumes distinct playerId values
        $entry->{playerName} = $client->name() || $client->id();
        push @entries, $entry;
    }

    # Subsonic client sessions with active now-playing state
    my $ss = Plugins::SlimPing::Core::Container->get('session_state');
    for my $session ( @{ $ss->getActiveSessions() } ) {
        my $track = $mapper->()->getTrackById( $session->{track_id} );
        next unless $track;

        my $seconds_ago =
          $session->{started_at} ? time() - $session->{started_at} : 0;
        $track->{username}   = $session->{username};
        $track->{minutesAgo} = $seconds_ago > 0 ? int( $seconds_ago / 60 ) : 0;
        $track->{playerId}   = 0;
        $track->{playerName} = $session->{client_name} || $session->{username};

        # playbackReport extension: expose timeline state from reportPlayback.
        my $tl = $ss->getPlaybackState( $session->{username},
            $session->{client_name} );
        if ($tl) {
            $track->{state}        = $tl->{state};
            $track->{positionMs}   = $tl->{position_ms};
            $track->{playbackRate} = $tl->{playback_rate};
        }

        push @entries, $track;
    }

    return { nowPlaying => { entry => \@entries } };
}

sub getTopSongs {
    my ($args) = @_;
    my $p      = $args->{params};
    my $artist_name = $p->{artist};
    return Plugins::SlimPing::Utils::Errors->missingParam('artist')
        unless defined $artist_name;
    my $songs  = $mapper->()->getTopSongs(
        count  => $p->{count}  // 50,
        artist => $artist_name,
        genre  => $p->{genre},
    );
    return { topSongs => { song => $songs } };
}

sub getSimilarSongs {
    my ($args) = @_;
    my $p  = $args->{params};
    my $id = $p->{id}
      or return Plugins::SlimPing::Utils::Errors->missingParam('id');

    my $count = Plugins::SlimPing::Utils::Params->clamp(
        val => $p->{count}, min => 1, max => 500, default => 50);
    my $songs = $mapper->()->getSimilarSongs(
        $id,
        count => $count,
    );

    return { similarSongs => { song => $songs } };
}

sub getSimilarSongs2 {
    my ($args) = @_;
    my $p  = $args->{params};
    my $id = $p->{id}
      or return Plugins::SlimPing::Utils::Errors->missingParam('id');

    my $count = Plugins::SlimPing::Utils::Params->clamp(
        val => $p->{count}, min => 1, max => 500, default => 50);
    my $songs = $mapper->()->getSimilarSongs2(
        $id,
        count => $count,
    );

    return { similarSongs2 => { song => $songs } };
}

1;
