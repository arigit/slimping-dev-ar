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
# Handlers/Lists.pm - List handlers for album, song and artist lists with various sorting options
#

package Plugins::SlimPing::Handlers::Lists;

use strict;
use warnings;

use Plugins::SlimPing::API::Router;
use Plugins::SlimPing::Core::LibraryMapper;
require Plugins::SlimPing::Core::Container;
require Plugins::SlimPing::Utils::Errors;
require Plugins::SlimPing::Utils::Params;

sub registerHandlers {
    my $class = shift;
    Plugins::SlimPing::API::Router->registerHandler('getAlbumList',   \&getAlbumList);
    Plugins::SlimPing::API::Router->registerHandler('getAlbumList2',  \&getAlbumList2);
    Plugins::SlimPing::API::Router->registerHandler('getRandomSongs', \&getRandomSongs);
    Plugins::SlimPing::API::Router->registerHandler('getStarred',       \&getStarred);
    Plugins::SlimPing::API::Router->registerHandler('getStarred2',      \&getStarred2);
    Plugins::SlimPing::API::Router->registerHandler('getSongsByGenre',  \&getSongsByGenre);
}

my $mapper = sub { Plugins::SlimPing::Core::Container->get('library_mapper') };
my $libId  = sub { Plugins::SlimPing::Core::LibraryMapper->decodeLibraryParam($_[0]) };

sub getAlbumList {
    my ($args) = @_;
    my $p      = $args->{params};
    my $type   = $p->{type} || 'newest';
    my $err    = Plugins::SlimPing::Utils::Errors->requireEnum($type, 'type',
        qw(random newest highest frequent recent starred
           alphabeticalByName alphabeticalByArtist byYear byGenre));
    return $err if $err;
    my $size   = Plugins::SlimPing::Utils::Params->clamp(
        val => $p->{size}, min => 1, max => 500, default => 10);
    my $offset = Plugins::SlimPing::Utils::Params->clamp(
        val => $p->{offset}, min => 0, max => 5000, default => 0);
    my $lib    = $libId->($p);

    my $albums = $mapper->()->getAlbumList(
        type       => $type,
        size       => $size,
        offset     => $offset,
        library_id => $lib,
        genre      => $p->{genre},
    );

    return { albumList => { album => $albums } };
}

sub getAlbumList2 {
    my ($args) = @_;
    my $result = getAlbumList($args);
    # Rekey albumList -> albumList2 for the v2 endpoint
    $result->{albumList2} = delete $result->{albumList};
    return $result;
}

sub getRandomSongs {
    my ($args) = @_;
    my $p    = $args->{params};
    my $size     = Plugins::SlimPing::Utils::Params->clamp(
        val => $p->{size}, min => 1, max => 500, default => 10);
    my $lib      = $libId->($p);
    my $genre    = $p->{genre};
    my $fromYear = $p->{fromYear};
    my $toYear   = $p->{toYear};

    my @picked = $mapper->()->getRandomSongIds(
        size       => $size,
        genre      => $genre,
        fromYear   => $fromYear,
        toYear     => $toYear,
        library_id => $lib,
    );

    my @songs;
    if (@picked) {
        my @track_objs = $mapper->()->getTracksByIds(\@picked, $lib);
        my $track_genre = $mapper->()->batchFetchTrackGenres(\@track_objs);

        # Batch-fetch annotations so shapeTrack does zero per-track lookups.
        my @track_rows = map { [ $_->id() ] } @track_objs;
        my ($starred, $ratings) = $mapper->()->_batchFetchAnnotations('track', \@track_rows);

        @songs = map {
            my $encoded = $mapper->()->encodeId('track', $_->id());
            $mapper->()->shapeTrack($_, $track_genre->{$_->id()}, undef, {
                starredAt        => $starred->{$encoded},
                rating           => $ratings->{$encoded},
                bookmarkPosition => undef,
            })
        } @track_objs;
    }

    return { randomSongs => { song => \@songs } };
}

sub getStarred  { return _getStarred(shift, 1); }
sub getStarred2 { return _getStarred(shift, 2); }

sub _getStarred {
    my ($args, $version) = @_;
    my $lib = $libId->($args->{params});
    my $data = _starredData($args, $lib);
    my $result_key = $version == 2 ? 'starred2' : 'starred';
    return { $result_key => $data };
}

sub getSongsByGenre {
    my ($args) = @_;
    my $p     = $args->{params};
    my $genre = $p->{genre};
    return Plugins::SlimPing::Utils::Errors->missingParam('genre')
        unless defined $genre && length $genre;

    my $count  = Plugins::SlimPing::Utils::Params->clamp(
        val => $p->{count}, min => 1, max => 500, default => 10);
    my $offset = Plugins::SlimPing::Utils::Params->clamp(
        val => $p->{offset}, min => 0, max => 5000, default => 0);
    my $lib    = $libId->($p);

    my $songs = $mapper->()->getTracksByGenre(
        genre      => $genre,
        count      => $count,
        offset     => $offset,
        library_id => $lib,
    );
    return { songsByGenre => { song => $songs } };
}

sub _starredData {
    my ($args, $lib) = @_;
    my $user  = $args->{user};
    require Plugins::SlimPing::Core::Annotations;
    my $stars = Plugins::SlimPing::Core::Annotations->getStars($user->{username});

    # StarStore returns integer epochs; the OpenSubsonic starred field is
    # date-time, so normalise store timestamps to ISO8601 before merging.
    require Plugins::SlimPing::Core::LibraryMapper;
    for my $bucket (qw(tracks albums artists)) {
        for my $id ( keys %{ $stars->{$bucket} } ) {
            my $ts = $stars->{$bucket}{$id};
            $stars->{$bucket}{$id} =
                ( defined $ts && $ts > 0 )
                ? Plugins::SlimPing::Core::LibraryMapper::_iso8601($ts)
                : undef;
        }
    }

    # Union in LMS-native favourites (server-global OPML).  SlimPing stars
    # take precedence: they carry per-user timestamps, bridged entries use
    # the favourites file's mtime so clients see a non-null starred field.
    require Plugins::SlimPing::Core::LmsFavorites;
    my $lms = Plugins::SlimPing::Core::LmsFavorites->list();
    my $lms_ts = Plugins::SlimPing::Core::LmsFavorites->timestamp();
    for my $bucket (qw(tracks albums artists)) {
        $stars->{$bucket}{$_} = $lms_ts
            for grep { !exists $stars->{$bucket}{$_} } keys %{ $lms->{$bucket} };
    }

    my $mapper_obj = $mapper->();

    # Batch-fetch tracks with prefetch instead of calling getTrackById() N times.
    # Star timestamps come from the already-fetched stars data (everything here
    # is starred by definition).  Ratings are batch-fetched.  Bookmarks skipped.
    my @songs;
    {
        my @raw_ids = map { ($mapper_obj->decodeId($_))[1] }
            grep { defined }
            keys %{ $stars->{tracks} || {} };
        if (@raw_ids) {
            my @track_objs = $mapper_obj->getTracksByIds(\@raw_ids, $lib);
            my $track_genre = $mapper_obj->batchFetchTrackGenres(\@track_objs);

            my @track_rows = map { [ $_->id() ] } @track_objs;
            my (undef, $ratings) = $mapper_obj->_batchFetchAnnotations('track', \@track_rows);

            @songs = map {
                my $encoded = $mapper_obj->encodeId('track', $_->id());
                $mapper_obj->shapeTrack($_, $track_genre->{$_->id()}, undef, {
                    starredAt        => $stars->{tracks}{$encoded},
                    rating           => $ratings->{$encoded},
                    bookmarkPosition => undef,
                })
            } @track_objs;
        }
    }

    # Batch-fetch albums with hints instead of calling getAlbumById() N times.
    my @albums;
    {
        my @raw_ids = map { ($mapper_obj->decodeId($_))[1] }
            grep { defined }
            keys %{ $stars->{albums} || {} };
        if ($lib && @raw_ids) {
            my $in_lib = $mapper_obj->idsInLibrary('library_album', 'album', \@raw_ids, $lib);
            @raw_ids = grep { $in_lib->{$_} } @raw_ids;
        }
        if (@raw_ids) {
            my @album_objs = $mapper_obj->getAlbumsByIds(\@raw_ids);
            if (@album_objs) {
                my $agg = $mapper_obj->enrichAlbumAggregates(\@album_objs);
                @albums = map {
                    my $encoded = $mapper_obj->encodeId('album', $_->id());
                    $mapper_obj->shapeAlbum($_, {
                        %{ $agg->{ $_->id() } // {} },
                        starredAt => $stars->{albums}{$encoded},
                    })
                } @album_objs;
            }
        }
    }

    # Batch-fetch artists with album counts instead of calling getArtistById() N times.
    my @artists;
    {
        my @raw_ids = map { ($mapper_obj->decodeId($_))[1] }
            grep { defined }
            keys %{ $stars->{artists} || {} };
        if ($lib && @raw_ids) {
            my $in_lib = $mapper_obj->idsInLibrary('library_contributor', 'contributor', \@raw_ids, $lib);
            @raw_ids = grep { $in_lib->{$_} } @raw_ids;
        }
        if (@raw_ids) {
            my @artist_objs = $mapper_obj->getArtistsByIds(\@raw_ids);
            if (@artist_objs) {
                my $counts = $mapper_obj->enrichArtistAlbumCounts(\@artist_objs);
                @artists = map {
                    my $encoded = $mapper_obj->encodeId('artist', $_->id());
                    $mapper_obj->shapeArtist($_, {
                        albumCount => $counts->{ $_->id() } // 0,
                        starredAt  => $stars->{artists}{$encoded},
                    })
                } @artist_objs;
            }
        }
    }

    return { song => \@songs, album => \@albums, artist => \@artists };
}
1;
