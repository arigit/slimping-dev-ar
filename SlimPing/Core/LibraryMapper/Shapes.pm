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
# Core/LibraryMapper/Shapes.pm - Subsonic data shape constructors
#
# Pure data-shaping functions: take Slim::Schema row objects and produce
# response hashrefs.  No queries, no caching, no streaming.
#

package Plugins::SlimPing::Core::LibraryMapper::Shapes;

use strict;
use warnings;

use Slim::Schema;
use Plugins::SlimPing::Core::Logging;
use Scalar::Util qw(looks_like_number);
require Plugins::SlimPing::API::ResponseFormatter;

my $log = Plugins::SlimPing::Core::Logging->getLogger();

# LMS stores audio format as short codes ('mp3', 'flc', 'aac', etc.).
# Subsonic clients expect standard MIME types.
# Format => [MIME type, is_lossless]
# Single source of truth for format classification -- used by _mimeType,
# isLosslessFormat, and outputMime.  Lossless formats are those where a
# client bitrate cap virtually always requires transcoding.
my %_mime = (
    mp3  => [ 'audio/mpeg',      0 ],
    flc  => [ 'audio/flac',      1 ],
    flac => [ 'audio/flac',      1 ],
    ogg  => [ 'audio/ogg',       0 ],
    oga  => [ 'audio/ogg',       0 ],
    aac  => [ 'audio/aac',       0 ],
    m4a  => [ 'audio/mp4',       0 ],
    alac => [ 'audio/mp4',       1 ],
    opus => [ 'audio/ogg',       0 ],
    wma  => [ 'audio/x-ms-wma',  0 ],
    wav  => [ 'audio/wav',       1 ],
    aif  => [ 'audio/aiff',      1 ],
    aiff => [ 'audio/aiff',      1 ],
    mp4  => [ 'audio/mp4',       0 ],
    ape  => [ 'audio/ape',       1 ],
    wv   => [ 'audio/wavpack',   1 ],
    dsf  => [ 'audio/dsf',       1 ],
    dff  => [ 'audio/dff',       1 ],
);

sub _mimeType {
    my ( $class_or_self, $format ) = @_;
    return 'audio/mpeg' unless defined $format && length $format;
    my $entry = $_mime{ lc($format) };
    return $entry->[0] if $entry;
    return "audio/$format";
}

# Returns true when $format is a lossless codec whose bitrate virtually
# always exceeds any client cap (FLAC, ALAC, WAV, AIFF, APE, WavPack, DSD).
# Pure function -- no instance state needed.
sub isLosslessFormat {
    my ( $class_or_self, $format ) = @_;
    return 0 unless defined $format;
    my $entry = $_mime{ lc($format) };
    return $entry && $entry->[1] ? 1 : 0;
}

# Returns true when $format is a DSD format (DSF/DFF) that no mobile or
# desktop Subsonic client can decode natively.  These formats must always
# be transcoded through the virtual player pipeline rather than served
# directly.  Users who need native DSD playback should use LMS players
# connected to suitable DACs instead of OpenSubsonic clients.
# Pure function -- no instance state needed.
sub isDsdFormat {
    my ( $class_or_self, $format ) = @_;
    return 0 unless defined $format;
    my $lc = lc($format);
    return $lc eq 'dsf' || $lc eq 'dff';
}

# Canonical output MIME type for the LMS virtual player pipeline.
# LMS's Slim::Player::HTTP only produces MP3; referencing this constant
# avoids hardcoding 'audio/mpeg' across the codebase.
sub outputMime {
    return 'audio/mpeg';
}

sub shapeArtist {
    my ( $self, $artist, $hints ) = @_;
    $hints //= {};

    # $artist may be a DBIx::Class Contributor object or a plain hashref with
    # keys id, name, namesort, musicbrainz_id (RawQueries batch SQL).  The
    # hashref path requires albumCount to be in $hints -- it has no lazy-load
    # fallback for album counts.
    my ( $artist_raw_id, $artist_name, $artist_sort, $artist_mbid );

    if ( ref $artist eq 'HASH' ) {
        $artist_raw_id = $artist->{id};
        $artist_name   = $artist->{name} // '';
        $artist_sort   = $artist->{namesort};
        $artist_mbid   = $artist->{musicbrainz_id};
    }
    else {
        $artist_raw_id = $artist->id();
        $artist_name   = $artist->name();
        $artist_sort   = $artist->namesort();
        $artist_mbid   = $artist->musicbrainz_id();
    }

    $artist_name //= '';

    my $album_count =
      exists $hints->{albumCount}
      ? $hints->{albumCount}
      : $artist->albums()->count();
    my $artist_id = $self->encodeId( 'artist', $artist_raw_id );

    my $starred_at;
    my $rating;
    if ( exists $hints->{starredAt} ) {
        $starred_at = $hints->{starredAt};
        $rating     = $hints->{rating};
    }
    else {
        my $username = Plugins::SlimPing::Core::LibraryMapper::_requestUsername();
        if ($username) {
            require Plugins::SlimPing::Core::Annotations;
            $starred_at =
              Plugins::SlimPing::Core::Annotations->getStarredAtMerged( $username,
                $artist_id );
            $rating = Plugins::SlimPing::Core::Annotations->getRating( $username,
                $artist_id );
        }
    }

    my @artist_roles;
    if ( exists $hints->{roles} ) {
        @artist_roles = @{ $hints->{roles} };
    } elsif ( ref $artist ne 'HASH' ) {
        # DBIx path: query distinct roles from contributor_track and contributor_album.
        my $dbh   = Slim::Schema->dbh;
        my $roles = {};
        for my $sql (
            'SELECT DISTINCT ct.role FROM contributor_track ct WHERE ct.contributor = ?',
            'SELECT DISTINCT ca.role FROM contributor_album ca WHERE ca.contributor = ?',
          )
        {
            my $sth = $dbh->prepare_cached($sql);
            $sth->execute($artist_raw_id);
            $roles->{ $_->[0] } = 1 for @{ $sth->fetchall_arrayref() };
            $sth->finish();
        }
        require Slim::Schema::Contributor;
        @artist_roles = map {
            my $name = Slim::Schema::Contributor->roleToType($_);
            lc( defined $name ? $name : $_ );
        } keys %$roles;
    }

    # Normalise roles: TRACKARTIST is non-conventional and not mapped by
    # clients (Symfonium) -- map it to ARTIST, and dedupe since roles 1
    # and 6 can now both produce 'artist'.
    my %seen_roles;
    @artist_roles = grep { !$seen_roles{$_}++ }
        map { $_ eq 'trackartist' ? 'artist' : $_ } @artist_roles;

    return {
        id             => $artist_id,
        name           => $artist_name,
        mediaType      => 'artist',
        albumCount     => $album_count,
        coverArt       => $self->encodeId( 'artist', $artist_raw_id ),
        artistImageUrl => Plugins::SlimPing::API::ResponseFormatter->coverArtUrl($artist_id, size => 600),
        ( defined $starred_at ? ( starred    => $starred_at )  : () ),
        ( defined $rating     ? ( userRating => int($rating) ) : () ),
        musicBrainzId => $artist_mbid // undef,
        sortName      => $artist_sort // undef,
        roles         => \@artist_roles,
    };
}

# Legacy Artist model for search2 / getArtists (pre-1.8.0).
sub shapeArtistLegacy {
    my ( $self, $artist, $hints ) = @_;
    $hints //= {};

    # $artist may be a DBIx::Class Contributor object or a plain hashref with
    # keys id, name, namesort, musicbrainz_id (RawQueries batch SQL).  The
    # hashref path requires albumCount to be in $hints -- it has no lazy-load
    # fallback for album counts.
    my ( $artist_raw_id, $artist_name, $artist_sort, $artist_mbid );

    if ( ref $artist eq 'HASH' ) {
        $artist_raw_id = $artist->{id};
        $artist_name   = $artist->{name} // '';
        $artist_sort   = $artist->{namesort};
        $artist_mbid   = $artist->{musicbrainz_id};
    }
    else {
        $artist_raw_id = $artist->id();
        $artist_name   = $artist->name();
        $artist_sort   = $artist->namesort();
        $artist_mbid   = $artist->musicbrainz_id();
    }

    $artist_name //= '';

    my $album_count =
      exists $hints->{albumCount}
      ? $hints->{albumCount}
      : $artist->albums()->count();
    my $artist_id = $self->encodeId( 'artist', $artist_raw_id );

    return {
        id             => $artist_id,
        name           => $artist_name,
        albumCount     => $album_count,
        coverArt       => $self->encodeId( 'artist', $artist_raw_id ),
        artistImageUrl => Plugins::SlimPing::API::ResponseFormatter->coverArtUrl($artist_id, size => 600),
    };
}

sub shapeAlbum {
    my ( $self, $album, $hints ) = @_;
    $hints //= {};

    # $album may be a DBIx::Class Album object (most callers) or a plain hashref
    # with keys id, title, year, musicbrainz_id, titlesort (RawQueries batch SQL).
    # The hashref path requires all optional fields to be in $hints -- it has no
    # lazy-load fallback.
    my ( $album_raw_id, $album_title, $album_year, $album_mbid, $album_sort );
    if ( ref $album eq 'HASH' ) {
        $album_raw_id = $album->{id};
        $album_title  = $album->{title};
        $album_year   = $album->{year};
        $album_mbid   = $album->{musicbrainz_id};
        $album_sort   = $album->{titlesort};
    }
    else {
        $album_raw_id = $album->id();
        $album_title  = $album->title();
        $album_year   = $album->year();
        $album_mbid   = $album->musicbrainz_id();
        $album_sort   = $album->titlesort();
    }

    my $song_count =
      exists $hints->{songCount}
      ? $hints->{songCount}
      : $album->tracks()->count();

 # $album->duration() returns a MM:SS string -- compute integer seconds instead.
    my $duration_secs;
    if ( exists $hints->{durationSecs} ) {
        $duration_secs = $hints->{durationSecs};
    }
    else {
        my $sum_rs = Slim::Schema->search(
            'Track',
            { album => $album->id(), audio => 1 },
            {
                select => [ { SUM => 'secs', -as => 'total_secs' } ],
                as     => ['total_secs']
            }
        );
        my $row = $sum_rs->first;
        $duration_secs = $row ? int( $row->get_column('total_secs') // 0 ) : 0;
    }

    my $genre;
    my $genres;
    if ( exists $hints->{allGenres} ) {
        my @gn = @{ $hints->{allGenres} };
        $genre  = @gn ? $gn[0] : undef;
        $genres = [ map { { name => $_ } } @gn ];
    }
    elsif ( exists $hints->{genre} ) {
        $genre  = $hints->{genre};
        $genres = $genre ? [ { name => $genre } ] : [];
    }
    else {
        my $t = $album->tracks->first;
        my $g = $t ? $t->genre() : undef;
        $genre  = $g ? $g->name() : undef;
        $genres = $genre ? [ { name => $genre } ] : [];
    }

    # Artist may be supplied as a hint (name + encoded ID) to avoid the
    # $album->contributor() lazy load in batch album lists.
    my $artist_name;
    my $artist_id;
    if ( exists $hints->{artistName} ) {
        $artist_name = $hints->{artistName};
        $artist_id   = $hints->{artistId};
    }
    else {
        my $artist = $album->contributor();
        $artist_name = $artist ? $artist->name() : '';
        $artist_id =
          $artist ? $self->encodeId( 'artist', $artist->id() ) : undef;
    }

    my $album_id = $self->encodeId( 'album', $album_raw_id );

    my $starred_at;
    my $rating;
    if ( exists $hints->{starredAt} ) {
        $starred_at = $hints->{starredAt};
        $rating     = $hints->{rating};
    }
    else {
        my $username = Plugins::SlimPing::Core::LibraryMapper::_requestUsername();
        if ($username) {
            require Plugins::SlimPing::Core::Annotations;
            $starred_at =
              Plugins::SlimPing::Core::Annotations->getStarredAtMerged( $username,
                $album_id );
            $rating = Plugins::SlimPing::Core::Annotations->getRating( $username,
                $album_id );
        }
    }

    my $compilation;
    my $release_type;
    if ( exists $hints->{isCompilation} ) {
        $compilation = $hints->{isCompilation};
        $release_type = $hints->{releaseType};
    } else {
        $compilation = ref $album eq 'HASH'
            ? $album->{compilation}
            : $album->compilation();
        $release_type = ref $album eq 'HASH'
            ? $album->{release_type}
            : $album->release_type();
    }

    my $created;
    if ( exists $hints->{created} ) {
        $created = $hints->{created};
    }
    else {
        my $cr_rs = Slim::Schema->search(
            'Track',
            { album => $album->id(), audio => 1 },
            {
                select => [ { MIN => 'added_time', -as => 'min_added' } ],
                as     => ['min_added']
            }
        );
        my $cr_row = $cr_rs->first;
        # created is required by the OpenSubsonic AlbumID3 spec.
        # Fall back to epoch-zero (1970-01-01T00:00:00Z) for empty albums
        # (no tracks yet) — a stable sentinel, unlike time().
        $created = Plugins::SlimPing::Core::LibraryMapper::_iso8601(
            $cr_row ? $cr_row->get_column('min_added') : 0
        );
    }

    # Album artist list from hints (pre-computed in batch queries), with a
    # DBIx fallback for single-album callers (getAlbum, getAlbumInfo).
    my @album_artists;
    if ( exists $hints->{albumArtists} ) {
        @album_artists = @{ $hints->{albumArtists} };
    }
    elsif ( defined $album_raw_id && $album_raw_id ) {
        my $dbh    = Slim::Schema->dbh;
        my $result = $self->batchFetchAlbumArtists( $dbh, [$album_raw_id] );
        @album_artists = @{ $result->{$album_raw_id} // [] };
    }

    # Compilation-aware display artist -- uses the localised "Various Artists"
    # string when the album is a compilation, joins multiple album artists when
    # available, or falls back to the single artist name.
    my $display_artist;
    if ( $compilation ) {
        require Slim::Music::Info;
        $display_artist = Slim::Music::Info::variousArtistString();
    }
    elsif ( @album_artists ) {
        $display_artist = join(', ', map { $_->{name} } @album_artists);
    }
    else {
        $display_artist = $artist_name;
    }

    # Album play count -- aggregate from track persistent data (STATISTICS gated).
    my $al_play_count;
    if ( exists $hints->{playCount} ) {
        $al_play_count = $hints->{playCount};
    } else {
        if ( main::STATISTICS ) {
            my $dbh = Slim::Schema->dbh;
            my $sth = $dbh->prepare_cached(
                'SELECT COALESCE(SUM(tp.playCount), 0) FROM tracks t '
              . 'LEFT JOIN tracks_persistent tp ON tp.urlmd5 = t.urlmd5 '
              . 'WHERE t.album = ? AND t.audio = 1'
            );
            $sth->execute($album_raw_id);
            ($al_play_count) = $sth->fetchrow_array();
            $sth->finish();
        }
        $al_play_count //= 0;
    }

    # Album replay gain from the albums table.
    my ( $al_rg, $al_rp );
    if ( exists $hints->{albumGain} ) {
        $al_rg = $hints->{albumGain};
        $al_rp = $hints->{albumPeak};
    } else {
        $al_rg = ref $album eq 'HASH'
            ? $album->{replay_gain}
            : $album->get_column('replay_gain');
        $al_rp = ref $album eq 'HASH'
            ? $album->{replay_peak}
            : $album->get_column('replay_peak');
    }

    # Album last-played -- MAX of track lastplayed timestamps (STATISTICS gated).
    my $al_played;
    if ( exists $hints->{played} ) {
        $al_played = $hints->{played};
    } elsif ( main::STATISTICS ) {
        my $dbh = Slim::Schema->dbh;
        my $sth = $dbh->prepare_cached(
            'SELECT MAX(tp.lastplayed) FROM tracks t '
          . 'LEFT JOIN tracks_persistent tp ON tp.urlmd5 = t.urlmd5 '
          . 'WHERE t.album = ? AND t.audio = 1'
        );
        $sth->execute($album_raw_id);
        my ($max_played) = $sth->fetchrow_array();
        $sth->finish();
        $al_played = $max_played
            ? Plugins::SlimPing::Core::LibraryMapper::_iso8601($max_played) : undef;
    } else {
        $al_played = undef;
    }

    # Disc titles from tracks with discsubtitle.
    my @disc_titles;
    if ( exists $hints->{discTitles} ) {
        @disc_titles = @{ $hints->{discTitles} };
    } else {
        my $dbh = Slim::Schema->dbh;
        my $sth = $dbh->prepare_cached(
            'SELECT DISTINCT disc, discsubtitle FROM tracks '
          . 'WHERE album = ? AND audio = 1 AND disc IS NOT NULL AND discsubtitle IS NOT NULL '
          . 'ORDER BY disc'
        );
        $sth->execute($album_raw_id);
        while ( my ( $d, $title ) = $sth->fetchrow_array() ) {
            push @disc_titles, { disc => int($d), title => $title };
        }
        $sth->finish();
    }

    # shapeAlbum produces both AlbumID3 (getAlbum) and Child (getAlbumList)
    # shapes.  isDir and title are required on Child but extraneous on
    # AlbumID3.  Keeping both is simpler than maintaining separate shapes.
    return {
        id        => $album_id,
        name      => $album_title,
        title     => $album_title,
        artist    => $artist_name,
        artistId  => $artist_id,
        coverArt  => $self->encodeId( 'album', $album_raw_id ),
        songCount => $song_count,
        duration  => $duration_secs,
        created   => $created,
        year      => $album_year // undef,
        genre     => $genre,
        genres    => $genres,
        playCount => $al_play_count,
        isDir     => \1,
        ( defined $starred_at ? ( starred    => $starred_at )  : () ),
        ( defined $rating     ? ( userRating => int($rating) ) : () ),
        musicBrainzId => $album_mbid // undef,
        sortName      => $album_sort // undef,
        displayArtist => $display_artist,
        artists       => @album_artists
        ? \@album_artists
        : $artist_id
            ? [ { id => $artist_id, name => $artist_name } ]
            : [],
        ( defined $compilation ? ( isCompilation => $compilation ? \1 : \0 ) : () ),
        ( defined $release_type && length $release_type
            ? ( releaseTypes => [$release_type] ) : () ),
        ( defined $al_rg || defined $al_rp
            ? ( replayGain => {
                ( defined $al_rg ? ( albumGain => $al_rg + 0.0 ) : () ),
                ( defined $al_rp ? ( albumPeak => $al_rp + 0.0 ) : () ),
              } )
            : () ),
        ( defined $al_played ? ( played => $al_played ) : () ),
        ( @disc_titles ? ( discTitles => \@disc_titles ) : () ),
    };
}

sub shapePlaylist {
    my ( $self, $pl, $include_tracks, $hints ) = @_;
    $hints //= {};

    my $song_count;
    my $duration_secs;

    if ( exists $hints->{songCount} ) {
        $song_count    = $hints->{songCount};
        $duration_secs = $hints->{duration};
    }
    else {
        my $dbh = Slim::Schema->dbh;
        my $sth = $dbh->prepare_cached(
            'SELECT COUNT(*), COALESCE(SUM(t.secs), 0) FROM playlist_track pt '
              . 'LEFT JOIN tracks t ON t.url = pt.track WHERE pt.playlist = ?' );
        $sth->execute( $pl->id() );
        ( $song_count, $duration_secs ) = $sth->fetchrow_array();
        $sth->finish();
    }

    my $username = Plugins::SlimPing::Core::LibraryMapper::_requestUsername();
    my $owner    = $username || 'admin';

    # SSP (smart playlist) evaluation expiry.  LMS does not expose the
    # per-playlist refresh interval, so we default to a conservative
    # 1-hour window from the last change time.  Static playlists have
    # no expiry and omit the field entirely.
    my $valid_until;
    if ( ( $pl->content_type() // '' ) eq 'ssp' ) {
        my $changed = $pl->updated_time() // time();
        $valid_until = Plugins::SlimPing::Core::LibraryMapper::_iso8601(
            $changed + 3600
        );
    }

    my $shaped = {
        id        => $self->encodeId( 'playlist', $pl->id() ),
        name      => $pl->title() // '',
        owner     => $owner,
        public    => \1,
        songCount => $song_count // 0,
        duration  => int( $duration_secs // 0 ),
        coverArt  => $self->encodeId( 'playlist', $pl->id() ),
        # Slim::Schema::Playlist inherits from Track; added_time / updated_time
        # are DBIx column accessors on the tracks table.
        created   => Plugins::SlimPing::Core::LibraryMapper::_iso8601( $pl->added_time() // time() ),
        changed   => Plugins::SlimPing::Core::LibraryMapper::_iso8601( $pl->updated_time() // time() ),
        comment   => _playlistComment($pl),
        readonly  => ( ( $pl->content_type() // '' ) eq 'ssp' ) ? \0 : \1,
        ( defined $valid_until ? ( validUntil => $valid_until ) : () ),
    };

    if ($include_tracks) {

        # Delegate to LMS's own track resolution (objectForUrl pipeline).
        # Tracks whose files have been deleted still produce a stub Track
        # object -- we flag those as missing rather than dropping them.
        # Remote URLs (spotify:, tidal:, etc.) may resolve as stubs when
        # LMS's objectForUrl does not populate the RemoteTrack cache; the
        # stub still carries the correct URL and round-trips through the
        # normal sq_tr_ ID scheme for playlist update/stream operations.
        my @track_objs = $pl->tracks->all();

        my $album_lookup = $self->batchFetchAlbumDataForTracks( \@track_objs );
        my $track_genre  = $self->batchFetchTrackGenres( \@track_objs );

        # Batch-resolve album artists so shapeTrack does not repeat the
        # contributor_album query for every track.
        my $dbh = Slim::Schema->dbh;
        my $album_artists_for = $self->batchFetchAlbumArtists(
            $dbh, [ keys %$album_lookup ]
        );

        $shaped->{entry} = [
            map {
                my $t          = $_;
                my $album_id   = $t->get_column('album');
                my $album_data = defined $album_id
                    ? ( $album_lookup->{$album_id} // {} )
                    : {};
                my $shaped_track = $self->shapeTrack(
                    $t, $track_genre->{ $t->id() }, $album_lookup,
                    {
                        albumArtists => defined $album_id
                            ? ( $album_artists_for->{$album_id} // [] )
                            : [],
                        isCompilation => $album_data->{compilation} // 0,
                    }
                );

                # Flag missing tracks: LMS creates a stub Track for dead
                # URLs which has no title.  Remote tracks keep their URL
                # as the title so clients can identify them.
                if ( !defined $shaped_track->{title}
                    || $shaped_track->{title} eq '' )
                {
                    $shaped_track->{title} = '[missing]';
                }

                $shaped_track;
            } @track_objs
        ];
    }

    return $shaped;
}

sub shapeTrack {
    my ( $self, $track, $genre_name, $album_lookup, $hints ) = @_;
    $album_lookup //= {};
    $hints        //= {};

    # Extract all fields into scalars.  The hashref path (RawQueries batch SQL)
    # provides album and artist fields pre-joined; the DBIx path resolves them
    # from related objects.  After this block the rest of the method builds the
    # return hashref from scalars only -- same code path regardless of input.
    my ( $track_raw_id, $track_title, $track_sort, $album_raw_id,
         $album_title, $album_contrib_id, $album_contrib_name,
         $secs, $bitrate, $fmt, $suffix, $tracknum, $disc,
         $filesize, $added_time, $playcount, $year, $bpm,
         $channels, $samplerate, $samplesize, $track_mbid,
         $artist_raw_id, $artist_name, $comment, $played_iso,
         $track_rg, $track_rp, $is_stub, $track_url,
         $grouping_val, $work_title );

    if ( ref $track eq 'HASH' ) {
        $track_raw_id       = $track->{id};
        $track_title        = $track->{title};
        $track_sort         = $track->{titlesort};
        $album_raw_id       = $track->{album_id};
        $album_title        = $track->{album_title};
        $album_contrib_id   = $track->{album_contrib_id};
        $album_contrib_name = $track->{album_contrib_name};
        $secs               = $track->{secs};
        $bitrate            = $track->{bitrate};
        $fmt                = $track->{content_type} // '';
        my $url_no_fragment = $track->{url} // '';
        $url_no_fragment =~ s/#.*$//;
        ($suffix) = ( $url_no_fragment =~ /\.([^.]+)$/ );
        $tracknum           = $track->{tracknum};
        $disc               = $track->{disc};
        $filesize           = $track->{filesize};
        $added_time         = $track->{added_time};
        $playcount          = $track->{playcount};
        $year               = $track->{year};
        $bpm                = $track->{bpm};
        $channels           = $track->{channels};
        $samplerate         = $track->{samplerate};
        $samplesize         = $track->{samplesize};
        $track_mbid         = $track->{musicbrainz_id};
        $artist_raw_id      = $track->{artist_id};
        $artist_name        = $track->{artist_name};
        $comment            = undef;  # not available in batch SQL
        $played_iso         = $track->{lastplayed}
            ? Plugins::SlimPing::Core::LibraryMapper::_iso8601( $track->{lastplayed} )
            : undef;
        $track_rg           = $track->{replay_gain};
        $track_rp           = $track->{replay_peak};
        $grouping_val       = $track->{grouping};
        $work_title         = $track->{work_title};
    }
    else {
        $track_raw_id = $track->id();
        $track_title  = $track->title();
        $track_sort   = $track->titlesort();
        $secs         = $track->secs();
        $bitrate      = $track->bitrate();
        $fmt          = $track->content_type() // '';
        my $url_no_fragment = $track->url() // '';
        $url_no_fragment =~ s/#.*$//;
        ($suffix) = ( $url_no_fragment =~ /\.([^.]+)$/ );
        $tracknum     = $track->tracknum();
        $disc         = $track->disc();
        $filesize     = $track->filesize();
        $added_time   = $track->added_time();
        $playcount    = $track->playcount();
        $year         = $track->year();
        $bpm          = $track->bpm();
        $channels     = $track->channels();
        $samplerate   = $track->samplerate();
        $samplesize   = $track->samplesize();
        $track_mbid   = $track->musicbrainz_id();
        $track_rg     = $track->get_column('replay_gain');
        $track_rp     = $track->get_column('replay_peak');
        $grouping_val = eval { $track->get_column('grouping') };
        $work_title   = eval { $track->work() && $track->work()->title() };
        $comment      = $track->comment();
        my $lastplayed = eval { $track->lastplayed() };
        if ($@) {
            $log->warn("SlimPing: lastplayed error for track " . $track->id() . ": $@");
            $played_iso = undef;
        } elsif ( defined $lastplayed && $lastplayed > 0 ) {
            $played_iso = Plugins::SlimPing::Core::LibraryMapper::_iso8601($lastplayed);
        } else {
            $played_iso = undef;
        }

        # Resolve album to a uniform hashref (from album_lookup cache or DBIx)
        my $album;
        if ( keys %$album_lookup ) {
            my $aid = $track->get_column('album');
            $album = $album_lookup->{$aid} if defined $aid;
        }
        if ( !$album ) {
            my $a = $track->album();
            if ($a) {
                my $c = $a->contributor();
                $album = {
                    id               => $a->id(),
                    title            => $a->title() // '',
                    contributor_id   => $c ? $c->id()   : undef,
                    contributor_name => $c ? $c->name() : '',
                };
            }
            else {
                $album = { id => undef, title => '', contributor_id => undef, contributor_name => '' };
            }
        }
        $album_raw_id       = $album->{id};
        $album_title        = $album->{title};
        $album_contrib_id   = $album->{contributor_id};
        $album_contrib_name = $album->{contributor_name};

        # Resolve artist
        my $artist     = $track->artist();
        $artist_raw_id = $artist ? $artist->id()   : undef;
        $artist_name   = $artist ? $artist->name() : undef;
    }

    # Stub Track objects (from dead playlist URLs via objectForUrl) have
    # audio=0 and no relationships.  Skip expensive DBIx lookups that
    # will always return empty for stubs.
    # Remote tracks (Spotify, Tidal, etc.) may also resolve as stubs when
    # the protocol handler is not registered -- their URLs still work for
    # streaming, so do not treat them as stubs.
    $track_url = ref $track ne 'HASH' ? ( $track->url() // '' ) : ( $track->{url} // '' );
    $is_stub   = 0;
    if ( ref $track ne 'HASH' ) {
        $is_stub = !( eval { $track->audio() } // 1 )
            && ( !$track_url || $track_url !~ /^[a-zA-Z][a-zA-Z0-9+\-.]*:/ || $track_url =~ /^file:/ );
    }

    $artist_name //= '';
    $album_title //= '';

    # Sanitise fields that map to Java int in client JSON adapters.
    # A single corrupted database value (e.g. bpm=1.84e19) causes Moshi-based
    # clients like Symfonium to reject the entire search page.
    $bpm        = undef if defined $bpm && ( $bpm <= 0 || $bpm > 1000 );
    $year       = undef if defined $year && ( $year < 1000 || $year > 2100 );
    $tracknum   = undef if defined $tracknum && ( $tracknum <= 0 || $tracknum > 9999 );
    $disc       = undef if defined $disc && ( $disc <= 0 || $disc > 999 );
    $channels   = undef if defined $channels && ( $channels <= 0 || $channels > 128 );
    $samplerate = undef if defined $samplerate && ( $samplerate < 8000 || $samplerate > 768000 );
    $samplesize = undef if defined $samplesize && ( !looks_like_number($samplesize) || $samplesize <= 0 || $samplesize > 64 );

    my $album_id = $album_raw_id ? $self->encodeId( 'album', $album_raw_id ) : undef;
    my $track_id = $self->encodeId( 'track', $track_raw_id );

    # Annotation lookups for the current request's user
    my $starred_at;
    my $rating;
    if ( exists $hints->{starredAt} ) {
        $starred_at = $hints->{starredAt};
        $rating     = $hints->{rating};
    }
    elsif ( !$is_stub ) {
        my $username = Plugins::SlimPing::Core::LibraryMapper::_requestUsername();
        if ($username) {
            require Plugins::SlimPing::Core::Annotations;
            $starred_at =
              Plugins::SlimPing::Core::Annotations->getStarredAtMerged( $username,
                $track_id );
            $rating = Plugins::SlimPing::Core::Annotations->getRating( $username,
                $track_id );
        }
    }

    # Bookmark position.  Batch callers (RawQueries search) pass the sentinel
    # via hints to avoid N+1 getUserBookmarks calls across thousands of tracks.
    # Single-track callers (getSong, playlist entries) omit the hint and get
    # the individual lookup -- cheap for 1-20 tracks, correct for resume UI.
    my $bookmark_position;
    if ( exists $hints->{bookmarkPosition} ) {
        $bookmark_position = $hints->{bookmarkPosition};
    }
    elsif ( !$is_stub ) {
        my $username = Plugins::SlimPing::Core::LibraryMapper::_requestUsername();
        if ($username) {
            require Plugins::SlimPing::Core::BookmarkStore;
            my $store   = Plugins::SlimPing::Core::BookmarkStore->getInstance();
            my $bm      = $store->getUserBookmarks($username);
            $bookmark_position = $bm->{$track_id}{position}
                if $bm && $bm->{$track_id};
        }
    }

    # Contributor list and display composer -- hint-first, DBIx fallback.
    # Skip for stub Track objects (from dead playlist URLs) that lack the
    # full relationship graph.
    my @contributors;
    my @composer_names;
    if ( !$is_stub && exists $hints->{contributors} ) {
        @contributors   = @{ $hints->{contributors} };
        @composer_names = @{ $hints->{composerNames} // [] };
    }
    elsif ( !$is_stub && ref $track ne 'HASH' ) {
        my $prefs = Plugins::SlimPing::Core::Logging->getPrefs();
        my $exposed = $prefs->get('exposed_contributor_roles');
        my @role_types = $exposed
            ? split(/\s*,\s*/, $exposed)
            : qw(ARTIST COMPOSER CONDUCTOR BAND ALBUMARTIST TRACKARTIST);

        for my $role_type (@role_types) {
            $role_type = uc($role_type);
            my $rs = eval { $track->contributorsOfType($role_type) };
            next unless $rs;
            for my $c ( $rs->all ) {
                push @contributors, {
                    role   => lc($role_type),
                    artist => {
                        id   => $self->encodeId( 'artist', $c->id ),
                        name => $c->name,
                    },
                };
            }
        }
        push @composer_names, map { $_->name } eval { $track->composer() };
    }

    # Album artists -- hint-first (batch query paths pass pre-resolved data),
    # DBIx fallback for single-track/album callers via contributor_album.
    my @album_artists;
    if ( exists $hints->{albumArtists} ) {
        @album_artists = @{ $hints->{albumArtists} };
    }
    elsif ( !$is_stub && defined $album_raw_id ) {
        my $dbh    = Slim::Schema->dbh;
        my $result = $self->batchFetchAlbumArtists( $dbh, [$album_raw_id] );
        @album_artists = @{ $result->{$album_raw_id} // [] };
    }

    # Multi-genre hint-aware logic.  Hints take priority (batch query paths),
    # then the single genre_name parameter (legacy callers), then DBIx lookup
    # as a fallback.  Do NOT call methods on hashrefs.
    my @genre_names;
    if ( exists $hints->{genres} ) {
        @genre_names = @{ $hints->{genres} };
    }
    elsif ( defined $genre_name && length $genre_name ) {
        @genre_names = ($genre_name);
    }
    elsif ( ref $track ne 'HASH' && !$is_stub ) {
        my $g  = $track->genre();
        my $gn = $g ? $g->name() : undef;
        @genre_names = ( defined $gn && length $gn ) ? ($gn) : ();
    }
    my $genre_val = @genre_names ? $genre_names[0] : undef;
    my $genres    = [ map { { name => $_ } } @genre_names ];

    my $display_artist = $artist_name // '';

    # Contributors must contain only non-artist roles -- artist,
    # albumartist and trackartist belong in artists/albumArtists.
    my @os_contributors = grep {
        $_->{role} ne 'artist' && $_->{role} ne 'albumartist' && $_->{role} ne 'trackartist'
    } @contributors;

    return {
        id       => $track_id,
        parent   => $album_id,
        title    => $track_title,
        name     => $track_title,
        album    => $album_title,
        albumId  => $album_id,
        artist   => $artist_name,
        artistId => $artist_raw_id
        ? $self->encodeId( 'artist', $artist_raw_id )
        : undef,
        coverArt => $album_id,
        duration => int( $secs // 0 ),
        bitRate  => ( $bitrate && $bitrate =~ /^\d+$/ ) ? 0 + int( $bitrate / 1000 ) : undef,
        contentType => _mimeType( $self, $fmt ),
        suffix      => $suffix || $fmt || '',
        ( ( $suffix || $fmt ) && lc( $suffix || $fmt ) ne 'mp3'
            ? ( transcodedContentType => 'audio/mpeg',
                transcodedSuffix      => 'mp3' )
            : () ),
        path        => _fakePath( $track_title, $artist_name, $album_title, $disc, $tracknum, $suffix ),
        year        => $year // undef,
        genre       => $genre_val,
        genres      => $genres,
        track       => $tracknum // undef,
        discNumber  => $disc     // 1,
        size        => $filesize // 0,
        created     => Plugins::SlimPing::Core::LibraryMapper::_iso8601(
            $added_time
        ),
        isDir     => \0,
        isVideo   => \0,
        type      => 'music',
        mediaType => 'song',
        playCount => int( $playcount // 0 ),
        ( defined $played_iso
            ? ( played => $played_iso )
            : exists $hints->{played}
                ? ( played => $hints->{played} )
                : () ),
        ( exists $hints->{averageRating}
            ? ( averageRating => $hints->{averageRating} )
            : () ),
        ( defined $starred_at ? ( starred    => $starred_at )  : () ),
        ( defined $rating     ? ( userRating => int($rating) ) : () ),
        bpm           => $bpm            // undef,
        comment       => $comment        // undef,
        sortName      => $track_sort     // undef,
        musicBrainzId => $track_mbid     // undef,
        channelCount  => $channels       // undef,
        samplingRate  => $samplerate     // undef,
        bitDepth      => $samplesize     // undef,
        ( defined $track_rg || defined $track_rp
            ? ( replayGain => {
                ( defined $track_rg ? ( trackGain => $track_rg + 0.0 ) : () ),
                ( defined $track_rp ? ( trackPeak => $track_rp + 0.0 ) : () ),
              } )
            : () ),
        ( defined $bookmark_position
            ? ( bookmarkPosition => int($bookmark_position) )
            : () ),
        ( @os_contributors
            ? ( contributors => \@os_contributors )
            : () ),
        ( @composer_names
            ? ( displayComposer => join( ', ', @composer_names ) )
            : () ),
        displayArtist => $display_artist,
        # Build track artists from the contributor list (ARTIST + TRACKARTIST),
        # deduplicating by ID.  Fall back to the single FK when contributors
        # are unavailable (stub tracks or hashref callers without contributor
        # hints).
        artists       => do {
            my %seen;
            my @from_contrib = grep { ( $_->{role} eq 'artist' || $_->{role} eq 'trackartist' )
                                      && !$seen{ $_->{artist}{id} }++ } @contributors;
            @from_contrib
            ? [ map { $_->{artist} } @from_contrib ]
            : $artist_raw_id
                ? [ { id => $self->encodeId( 'artist', $artist_raw_id ),
                      name => $artist_name } ]
                : [];
        },
        displayAlbumArtist => $album_contrib_name // '',
        # Album artists: prefer resolved list (from hints or DBIx fallback).
        # If empty, fall back to the single album contributor FK.
        albumArtists => @album_artists
            ? \@album_artists
            : $album_contrib_id
                ? [ { id   => $self->encodeId( 'artist', $album_contrib_id ),
                      name => $album_contrib_name // '' } ]
                : [],
        # OpenSubsonic groupings — the GROUPING tag, split on semicolon or null.
        ( defined $grouping_val && length $grouping_val
            ? ( groupings => [
                grep { defined && length } map { s/^\s+|\s+$//gr }
                  split( /[;\x00]/, $grouping_val )
              ] )
            : () ),
        # OpenSubsonic works — the WORK tag from the works table.
        # The works table has no musicbrainz_id column; emit name only.
        ( defined $work_title && length $work_title
            ? ( works => [ { name => $work_title } ] )
            : () ),
    };
}

# Construct a synthetic relative path from metadata, matching Navidrome's fakePath()
# approach.  No real filesystem paths are ever exposed in API responses.
sub _fakePath {
    my ( $title, $artist_name, $album_name, $disc, $tracknum, $suffix ) = @_;
    $artist_name ||= 'Unknown Artist';
    $album_name  ||= 'Unknown Album';
    $title       ||= 'Unknown Title';
    $suffix      //= 'mp3';

# Slashes in any component would break the path illusion -- replace with underscores.
    my $sanitise = sub {
        my ($s) = @_;
        $s =~ s{/}{_}g;
        return $s;
    };

    my @parts;
    push @parts, $sanitise->($artist_name);
    push @parts, $sanitise->($album_name);

    my $file = '';
    if ( $disc && $disc != 1 ) {
        $file .= sprintf( '%02d-', $disc );
    }
    if ($tracknum) {
        $file .= sprintf( '%02d - ', $tracknum );
    }
    $file .= $sanitise->($title) . '.' . ( $suffix || 'mp3' );

    push @parts, $file;
    return join( '/', @parts );
}

# Extract a playlist-level comment from the LMS playlist object.
# LMS stores comments via the 'comment' accessor on the DBIx class.
# Falls back to undef (absent from the response) when unavailable.
sub _playlistComment {
    my ($pl) = @_;
    return undef unless $pl && $pl->can('comment');
    my $comment = eval { $pl->comment() };
    return undef unless defined $comment && length $comment;
    return $comment;
}

1;
