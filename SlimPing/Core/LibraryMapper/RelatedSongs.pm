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

# INTERNAL MODULE -- do not use directly. All access through the
# Plugins::SlimPing::Core::LibraryMapper facade.
#
# Core/LibraryMapper/RelatedSongs.pm - Similar-song engine with tiered signals
#
# Given an artist, album, or song ID, returns a shuffled list of shaped tracks
# drawn from the seed artist and similar artists.  The richness of the similarity
# signal is controlled by the feature_similar_depth server pref:
#
#   basic    -- genre overlap only (same foundation as ArtistInfo.pm)
#   enhanced -- genre + artists who appear on the same albums (compilations,
#               collaborations, split releases)
#   full     -- enhanced + one-hop collaboration-graph walk + play-count
#               weighted shuffle
#
# If the input ID resolves to an album or song, the primary artist is used as
# the seed.  Unknown / unresolvable IDs return an empty list.

package Plugins::SlimPing::Core::LibraryMapper::RelatedSongs;

use strict;
use warnings;

use List::Util qw(shuffle);
use Time::HiRes qw(time);
use Slim::Schema;
use Plugins::SlimPing::Core::Logging;

my $log = Plugins::SlimPing::Core::Logging->getLogger();

# ---------------------------------------------------------------------------
# Public entry point
# ---------------------------------------------------------------------------

sub getSimilarSongs {
    my ($self, $sq_id, %args) = @_;

    my $count  = $args{count} // 50;
    my $depth  = _readDepth();
    my $artist = _resolveArtist($self, $sq_id);
    return [] unless $artist;

    my $t0 = time();

    my $pool = _similarArtistPool($self, $artist, $depth, $count);

    my $tracks = _pickWeightedTracks($self, $pool, $artist, $count, $depth);

    $log->debug(sprintf(
        'SlimPing: getSimilarSongs depth=%s artist=%s pool=%d tracks=%d (%.1fms)',
        $depth, $artist->name(), scalar keys %$pool, scalar @$tracks,
        (time() - $t0) * 1000
    ));

    return $tracks;
}

# ---------------------------------------------------------------------------
# ID resolution
# ---------------------------------------------------------------------------

# Decode the sq_ ID and resolve to a Contributor object.  Accepts artist,
# album, and song IDs; for albums and songs the primary artist is returned.
sub _resolveArtist {
    my ($self, $sq_id) = @_;
    return undef unless defined $sq_id;

    my ($type, $raw_id) = $self->decodeId($sq_id);
    return undef unless defined $type && defined $raw_id;

    if ($type eq 'artist') {
        return Slim::Schema->find('Contributor', $raw_id);
    }

    if ($type eq 'album') {
        my $album = Slim::Schema->find('Album', $raw_id);
        return undef unless $album;
        return $album->artist();
    }

    if ($type eq 'track') {
        my $track = Slim::Schema->find('Track', $raw_id);
        return undef unless $track;
        return $track->artist();
    }

    return undef;
}

# ---------------------------------------------------------------------------
# Pref read
# ---------------------------------------------------------------------------

sub _readDepth {
    my $prefs = Plugins::SlimPing::Core::Logging->getPrefs();
    my $val   = $prefs->get('feature_similar_depth');
    return $val if $val eq 'basic' || $val eq 'enhanced' || $val eq 'full';
    return 'basic';
}

# ---------------------------------------------------------------------------
# Artist pool builder
# ---------------------------------------------------------------------------

# Returns a hashref of { artist_id => weight } for artists similar to the seed.
# The seed artist is always included at weight 1.0.
sub _similarArtistPool {
    my ($self, $artist, $depth, $count) = @_;

    # Always include the seed artist
    my %pool = ( $artist->id() => 1.0 );

    # Basic: genre overlap only
    my @genre_ids = $self->_genreArtistIds($artist, $count);
    for my $gid (@genre_ids) {
        $pool{$gid} = ($pool{$gid} // 0) + 0.6;
    }

    return \%pool if $depth eq 'basic';

    # Enhanced: add shared-album artists
    my @shared_ids = _sharedAlbumArtistIds($self, $artist, $count);
    for my $sid (@shared_ids) {
        $pool{$sid} = ($pool{$sid} // 0) + 0.6;
    }

    return \%pool if $depth eq 'enhanced';

    # Full: one-hop graph walk from the current pool
    my @current_ids = keys %pool;
    my $hop_count = 0;
    for my $cid (@current_ids) {
        last if ++$hop_count > 20;    # cap graph-walk input size
        my $hop_artist = Slim::Schema->find('Contributor', $cid);
        next unless $hop_artist;
        my @hop_ids = _sharedAlbumArtistIds($self, $hop_artist, int($count / 3));
        for my $hid (@hop_ids) {
            $pool{$hid} = ($pool{$hid} // 0) + 0.3;   # decayed weight
        }
    }

    return \%pool;
}

# ---------------------------------------------------------------------------
# Signal: shared albums (compilations, collaborations, split releases)
# ---------------------------------------------------------------------------

sub _sharedAlbumArtistIds {
    my ($self, $artist, $count) = @_;

    my $dbh = Slim::Schema->dbh;
    my $sth = $dbh->prepare_cached(
        'SELECT DISTINCT ca2.contributor FROM contributor_album ca1'
      . ' JOIN contributor_album ca2 ON ca2.album = ca1.album'
      . ' WHERE ca1.contributor = ? AND ca2.contributor != ?'
    );
    $sth->execute($artist->id(), $artist->id());
    my @ids = map { $_->[0] } @{ $sth->fetchall_arrayref() };
    $sth->finish();
    return () unless @ids;

    my @picked = shuffle(@ids);
    splice(@picked, $count) if @picked > $count;
    return @picked;
}

# ---------------------------------------------------------------------------
# Track picker
# ---------------------------------------------------------------------------

# Pick tracks from the weighted artist pool.  At 'full' depth, play count
# from TrackPersistent is used as a secondary weight; at lower depths a
# simple shuffle is used.
sub _pickWeightedTracks {
    my ($self, $pool, $seed_artist, $count, $depth) = @_;

    my @artist_ids = keys %$pool;
    return [] unless @artist_ids;

    # Fetch candidate tracks: fetch all track IDs from pool artists, shuffle,
    # take the first N.
    my $placeholders = join(',', ('?') x scalar @artist_ids);
    my $dbh = Slim::Schema->dbh;
    my $sth = $dbh->prepare(
        "SELECT t.id FROM tracks t"
      . " JOIN contributor_track ct ON ct.track = t.id"
      . " WHERE ct.contributor IN ($placeholders) AND ct.role = 1"
      . " AND t.audio = 1"
    );
    $sth->execute(@artist_ids);
    my @track_ids = map { $_->[0] } @{ $sth->fetchall_arrayref() };
    $sth->finish();
    return [] unless @track_ids;

    @track_ids = shuffle(@track_ids);

    # At 'full' depth, apply play-count weighted shuffle.
    if ($depth eq 'full' && scalar(@track_ids) > $count) {
        @track_ids = _playCountWeightedSort($self, \@track_ids, $count);
    }

    # Take up to $count, resolve and shape
    splice(@track_ids, $count) if @track_ids > $count;

    my $rs = Slim::Schema->search('Track',
        { 'me.id' => { -in => \@track_ids } },
        { prefetch => ['album', 'primary_artist'] }
    );
    my %track_by_id = map { $_->id() => $_ } $rs->all();

    # Preserve the shuffled/weighted order
    my @result;
    for my $tid (@track_ids) {
        my $track = $track_by_id{$tid};
        next unless $track && $track->audio();
        push @result, $self->shapeTrack($track);
    }

    return \@result;
}

# Weighted shuffle: sort by TrackPersistent.playCount (higher = earlier),
# then take the top $scan_limit, then shuffle to preserve some randomness.
sub _playCountWeightedSort {
    my ($self, $track_ids, $count) = @_;

    my $scan_limit = $count * 3;
    my $placeholders = join(',', ('?') x scalar @$track_ids);
    my $dbh = Slim::Schema->dbh;
    # Plain prepare() -- not prepare_cached() -- because the variable-length IN
    # clause produces a different SQL string per batch size.
    my $sth = $dbh->prepare(
        "SELECT t.id, COALESCE(tp.playCount, 0) AS pc FROM tracks t"
      . " LEFT JOIN tracks_persistent tp ON tp.urlmd5 = t.urlmd5"
      . " WHERE t.id IN ($placeholders)"
      . " ORDER BY pc DESC LIMIT ?"
    );
    $sth->execute(@$track_ids, $scan_limit);
    my @weighted = map { $_->[0] } @{ $sth->fetchall_arrayref() };
    $sth->finish();

    @weighted = shuffle(@weighted);
    return @weighted;
}

1;
