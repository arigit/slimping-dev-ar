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
# Core/LibraryMapper/Queries.pm - Slim::Schema query layer
#
# Read-only query methods that virtualise LMS database access into Subsonic
# response shapes.  All methods here pair a database fetch with a call to the
# Shapes sub-module to produce response hashes.
#

package Plugins::SlimPing::Core::LibraryMapper::Queries;

use strict;
use warnings;

use List::Util qw(shuffle);
use Slim::Schema;
use Time::HiRes qw(time);
use Plugins::SlimPing::Core::Logging;

my $log   = Plugins::SlimPing::Core::Logging->getLogger();
my $prefs = Plugins::SlimPing::Core::Logging->getPrefs();

# --- Music folders (LMS virtual libraries) ------------------------------------

sub getMusicFolders {
    my $self = ref $_[0] ? $_[0] : $_[0]->getInstance();

    my $t0     = time();
    my $cached = $self->{_cache}->get('slimping.folders');
    if ($cached) {
        $log->debug(sprintf('SlimPing: getMusicFolders cache hit (%.1fms)', (time() - $t0) * 1000));
        return $cached;
    }

    my $mode = $prefs->get('exposed_libraries_mode');

    my @folders;
    # MusicFolder.id is integer per the OpenSubsonic spec — "All Music" is
    # always folder 0 and is present in every exposure mode.  Virtual libraries
    # get a stable integer derived from their canonical string ID so the value
    # survives cache expiry and restart.
    push @folders, { id => 0, name => 'All Music' };

    if ($mode ne 'default_only') {
        require Slim::Music::VirtualLibraries;
        my $libs = Slim::Music::VirtualLibraries->getLibraries() || {};

        # %$libs is keyed by LMS's internal hashed library key; each value's
        # {id} field is the canonical ID stored in prefs and used for filtering.
        # Always use $lib->{id} (not the hash key) for consistency with what
        # Settings.pm stores in exposed_library_ids.
        my $raw = $prefs->get('exposed_library_ids');
        my $exposed_ids = $mode eq 'selected'
            ? ( ref $raw eq 'ARRAY' ? $raw : [] )
            : undef;
        my %allowed = $exposed_ids ? map { $_ => 1 } @$exposed_ids : ();

        for my $lib_key (keys %$libs) {
            my $lib = $libs->{$lib_key};
            next if $exposed_ids && !$allowed{ $lib->{id} };
            push @folders, {
                id   => $self->folderCanonicalToInt( $lib->{id} ),
                name => $lib->{name},
            };
        }
    }

    $self->{_cache}->set('slimping.folders', \@folders,
        Plugins::SlimPing::Core::LibraryMapper::FOLDERS_CACHE_TTL());

    $log->debug(sprintf('SlimPing: getMusicFolders took %.1fms (%d folders)', (time() - $t0) * 1000, scalar @folders));
    return \@folders;
}

# --- Artists ------------------------------------------------------------------

sub getArtistById {
    my ($self, $sq_id) = @_;
    $self = $self->getInstance() unless ref $self;
    my (undef, $raw_id) = $self->decodeId($sq_id);
    return undef unless defined $raw_id;
    my $artist = Slim::Schema->find('Contributor', $raw_id);
    return undef unless $artist;
    return $self->shapeArtist($artist);
}

# Batch-fetch artists by raw IDs with optional library filtering.  Returns
# a list of DBIx Contributor objects.  Combine with enrichArtistAlbumCounts()
# to get per-artist album count data for shapeArtist().
sub getArtistsByIds {
    my ($self, $raw_ids, $lib) = @_;
    $self = $self->getInstance() unless ref $self;
    return () unless $raw_ids && @$raw_ids;

    my @ids = @$raw_ids;
    if ($lib) {
        my $dbh = Slim::Schema->dbh;
        my $placeholders = join(',', ('?') x scalar @ids);
        my $sth = $dbh->prepare(
            "SELECT contributor FROM library_contributor WHERE library = ? AND contributor IN ($placeholders)"
        );
        $sth->execute($lib, @ids);
        my %in_lib = map { $_->[0] => 1 } @{ $sth->fetchall_arrayref() };
        $sth->finish();
        @ids = grep { $in_lib{$_} } @ids;
        return () unless @ids;
    }

    return Slim::Schema->search('Contributor',
        { 'me.id' => { -in => \@ids } },
        { order_by => 'me.namesort' }
    )->all();
}

# Build a hashref keyed by artist raw ID with albumCount from the
# contributor_album join table.
sub enrichArtistAlbumCounts {
    my ($self, $artist_objs) = @_;
    return {} unless $artist_objs && @$artist_objs;

    my @aids = map { $_->id() } @$artist_objs;
    my $dbh = Slim::Schema->dbh;
    my $placeholders = join(',', ('?') x scalar @aids);
    my $sth = $dbh->prepare(
        "SELECT contributor, COUNT(DISTINCT album) FROM contributor_album"
      . " WHERE contributor IN ($placeholders) GROUP BY contributor"
    );
    $sth->execute(@aids);
    my %counts;
    while (my ($cid, $n) = $sth->fetchrow_array()) {
        $counts{$cid} = $n;
    }
    $sth->finish();
    return \%counts;
}

sub getAlbumsByArtist {
    my ($self, $sq_artist_id, %args) = @_;
    $self = $self->getInstance() unless ref $self;

    my $t0     = time();
    my (undef, $raw_id) = $self->decodeId($sq_artist_id);
    return [] unless defined $raw_id;

    my $lib = $args{library_id};

    my %criteria = ( 'contributorAlbums.contributor' => $raw_id );
    my @joins = ('contributorAlbums');

    if ($lib) {
        my $in_lib = _inLibrary($self, 'library_album', 'album', $lib);
        my @ids = keys %$in_lib;
        return [] unless @ids;
        $criteria{'me.id'} = { -in => \@ids };
    }

    my $rs = Slim::Schema->search('Album',
        \%criteria,
        { join => \@joins, distinct => 1, prefetch => ['contributor'], order_by => 'me.titlesort' }
    );

    my @album_objs = $rs->all();

    # Batch-fetch songCount, duration, created timestamp, and genre for all
    # albums to avoid N+1 queries inside shapeAlbum.
    my %album_hints;
    if (@album_objs) {
        my @album_ids = map { $_->id() } @album_objs;
        my $placeholders = join(',', ('?') x scalar @album_ids);
        my $dbh = Slim::Schema->dbh;

        # Plain prepare() -- not prepare_cached() -- because the variable-length
        # IN clause produces a different SQL string per batch size.
        my $sth = $dbh->prepare(
            "SELECT album, COUNT(*), COALESCE(SUM(secs), 0), MIN(added_time) FROM tracks"
          . " WHERE album IN ($placeholders) AND audio = 1"
          . " GROUP BY album"
        );
        $sth->execute(@album_ids);
        while (my ($aid, $n, $s, $ts) = $sth->fetchrow_array()) {
            $album_hints{$aid}{songCount}    = $n;
            $album_hints{$aid}{durationSecs} = int($s // 0);
            $album_hints{$aid}{created}      = Plugins::SlimPing::Core::LibraryMapper::_iso8601($ts);
        }
        $sth->finish();

        my $genre_hint = _batchGenreHint($self, $dbh, \@album_ids);
        $album_hints{$_}{genre} = $genre_hint->{$_} for @album_ids;

        # Batch-fetch starred and rating annotations
        my @album_rows = map { [$_] } @album_ids;
        my ($starred, $ratings) = $self->_batchFetchAnnotations('album', \@album_rows);
        for my $i (0 .. $#album_ids) {
            my $encoded = $self->encodeId('album', $album_ids[$i]);
            $album_hints{ $album_ids[$i] }{starredAt} = $starred->{$encoded};
            $album_hints{ $album_ids[$i] }{rating}    = $ratings->{$encoded};
        }
    }

    my @albums = map {
        $self->shapeAlbum($_, $album_hints{ $_->id() } // {})
    } @album_objs;

    $log->debug(sprintf('SlimPing: getAlbumsByArtist took %.1fms (%d albums)', (time() - $t0) * 1000, scalar @albums));
    return \@albums;
}

# --- Albums -------------------------------------------------------------------

sub getAlbumById {
    my ($self, $sq_id) = @_;
    $self = $self->getInstance() unless ref $self;
    my (undef, $raw_id) = $self->decodeId($sq_id);
    return undef unless defined $raw_id;
    my $album = Slim::Schema->find('Album', $raw_id);
    return undef unless $album;
    return $self->shapeAlbum($album);
}

# Batch-fetch albums by raw IDs with contributor prefetch and optional
# library filtering.  Returns a list of DBIx Album objects.  Combine with
# enrichAlbumAggregates() to get songCount/duration/created/genre data.
sub getAlbumsByIds {
    my ($self, $raw_ids, $lib) = @_;
    $self = $self->getInstance() unless ref $self;
    return () unless $raw_ids && @$raw_ids;

    my @ids = @$raw_ids;
    if ($lib) {
        my $dbh = Slim::Schema->dbh;
        my $placeholders = join(',', ('?') x scalar @ids);
        my $sth = $dbh->prepare(
            "SELECT album FROM library_album WHERE library = ? AND album IN ($placeholders)"
        );
        $sth->execute($lib, @ids);
        my %in_lib = map { $_->[0] => 1 } @{ $sth->fetchall_arrayref() };
        $sth->finish();
        @ids = grep { $in_lib{$_} } @ids;
        return () unless @ids;
    }

    return Slim::Schema->search('Album',
        { 'me.id' => { -in => \@ids } },
        { order_by => 'me.titlesort', prefetch => ['contributor'] }
    )->all();
}

# Build an aggregation hashref keyed by album raw ID with songCount,
# durationSecs, created, and genre hint.  Consumed by shapeAlbum callers.
sub enrichAlbumAggregates {
    my ($self, $album_objs) = @_;
    return {} unless $album_objs && @$album_objs;

    my @aids = map { $_->id() } @$album_objs;
    my %agg;

    my $agg_rs = Slim::Schema->search('Track',
        { album => { -in => \@aids }, audio => 1 },
        { select   => ['album',
                       { COUNT => 'me.id', -as => 'n' },
                       { SUM   => 'secs',  -as => 's' },
                       { MIN   => 'me.added_time', -as => 'ts' }],
          as       => ['album', 'n', 's', 'ts'],
          group_by => 'album' }
    );
    while (my $row = $agg_rs->next()) {
        $agg{ $row->get_column('album') } = {
            songCount    => $row->get_column('n')  // 0,
            durationSecs => int($row->get_column('s') // 0),
            created      => Plugins::SlimPing::Core::LibraryMapper::_iso8601(
                                $row->get_column('ts')
                            ),
        };
    }

    my $dbh = Slim::Schema->dbh;
    my $genre_hint = $self->_batchGenreHint($dbh, \@aids);
    $agg{$_}{genre} = $genre_hint->{$_} for @aids;

    return \%agg;
}

sub getTracksByAlbum {
    my ($self, $sq_album_id) = @_;
    $self = $self->getInstance() unless ref $self;

    my $t0     = time();
    my (undef, $raw_id) = $self->decodeId($sq_album_id);
    return [] unless defined $raw_id;

    my $rs = Slim::Schema->search('Track',
        { album => $raw_id },
        { prefetch => ['album', 'primary_artist'],
          order_by => ['me.disc', 'me.tracknum', 'me.titlesort'] }
    );

    my @track_objs = $rs->all();

    my @track_ids  = map { $_->id() } @track_objs;
    my $track_genres = batchFetchAllTrackGenres($self, \@track_ids);

    my $exposed = $prefs->get('exposed_contributor_roles');
    my %role_filter;
    if ($exposed) {
        %role_filter = map { lc($_) => 1 } split(/\s*,\s*/, $exposed);
    }
    else {
        %role_filter = map { lc($_) => 1 } qw(ARTIST COMPOSER CONDUCTOR BAND ALBUMARTIST TRACKARTIST);
    }
    my ($track_contributors, $track_composers) =
        batchFetchTrackContributors($self, \@track_ids, \%role_filter);

    # Batch-fetch starred and rating annotations
    my @track_rows = map { [$_->id()] } @track_objs;
    my ($starred_batch, $rating_batch) = $self->_batchFetchAnnotations('track', \@track_rows);

    # Resolve album artists and compilation status once for the album
    # (all tracks share the same album).
    my $dbh = Slim::Schema->dbh;
    my $album_artists_for = $self->batchFetchAlbumArtists($dbh, [$raw_id]);
    my $is_comp = ( @track_objs && $track_objs[0]->album )
        ? ( $track_objs[0]->album->compilation // 0 )
        : 0;

    my @tracks = map {
        my $tid = $_->id();
        my $encoded = $self->encodeId('track', $tid);
        $self->shapeTrack(
            $_,
            undef,
            undef,
            {
                starredAt      => $starred_batch->{$encoded},
                rating         => $rating_batch->{$encoded},
                genres         => $track_genres->{$tid} // [],
                contributors   => $track_contributors->{$tid} // [],
                composerNames  => $track_composers->{$tid} // [],
                albumArtists   => $album_artists_for->{$raw_id} // [],
                isCompilation  => $is_comp,
            },
        );
    } @track_objs;

    $log->debug(sprintf('SlimPing: getTracksByAlbum took %.1fms (%d tracks)', (time() - $t0) * 1000, scalar @tracks));
    return \@tracks;
}

# --- Tracks -------------------------------------------------------------------

sub getTrackById {
    my ($self, $sq_id) = @_;
    $self = $self->getInstance() unless ref $self;
    my (undef, $raw_id) = $self->decodeId($sq_id);
    return undef unless defined $raw_id;
    my $track = Slim::Schema->find('Track', $raw_id);
    return undef unless $track;

    my %hints;
    eval {
        require Plugins::SlimPing::Core::RatingStore;
        $hints{averageRating} = Plugins::SlimPing::Core::RatingStore->getAverageRating($sq_id);
    };
    if ($@) {
        $log->warn("SlimPing: averageRating lookup failed for $sq_id: $@") if $log;
    }

    if ( $track->can('lastplayed') ) {
        my $lp = eval { $track->lastplayed() };
        if ( defined $lp && $lp > 0 ) {
            require POSIX;
            $hints{played} = Plugins::SlimPing::Core::LibraryMapper::_iso8601($lp);
        }
    }

    # Propagate compilation flag.  (The isCompilation hint remains available
    # for future use such as releaseType selection.)
    my $album = eval { $track->album() };
    if ( $album && !$@ ) {
        $hints{isCompilation} = $album->compilation // 0;
    }

    return $self->shapeTrack($track, undef, undef, \%hints);
}

# Batch-fetch tracks by raw IDs with album + artist prefetch.  Returns a
# list of DBIx Track objects (not shaped hashes) so callers can apply their
# own shaping with optional genre hint or library filtering.
sub getTracksByIds {
    my ($self, $raw_ids, $lib) = @_;
    $self = $self->getInstance() unless ref $self;
    return () unless $raw_ids && @$raw_ids;

    my %criteria = ( 'me.id' => { -in => $raw_ids }, audio => 1 );
    my @joins;
    if ($lib) {
        $criteria{'libraryTracks.library'} = $lib;
        push @joins, 'libraryTracks';
    }

    return Slim::Schema->search('Track',
        \%criteria,
        { join => \@joins, prefetch => ['album', 'primary_artist'] }
    )->all();
}

# Batch-fetch tracks by URL with album + artist prefetch.
# Returns a hashref keyed by URL to DBIx Track objects.
sub getTracksByUrls {
    my ($self, $urls) = @_;
    $self = $self->getInstance() unless ref $self;
    return {} unless $urls && @$urls;

    my $rs = Slim::Schema->search('Track',
        { url => { -in => $urls } },
        { prefetch => ['album', 'primary_artist'] }
    );
    return { map { $_->url() => $_ } $rs->all() };
}

# Batch membership check: returns a hashref of { raw_id => 1 } for every
# item ID that belongs to $lib in the given $table/$id_col.
sub idsInLibrary {
    my ($self, $table, $id_col, $raw_ids, $lib) = @_;
    return {} unless $lib && $raw_ids && @$raw_ids;

    return {} unless $table =~ /^library_[a-z]+$/ && $id_col =~ /^[a-z]+$/;

    my $dbh          = Slim::Schema->dbh;
    my $placeholders = join(',', ('?') x scalar(@$raw_ids));
    my $sth          = $dbh->prepare(
        "SELECT $id_col FROM $table WHERE library = ? AND $id_col IN ($placeholders)"
    );
    $sth->execute($lib, @$raw_ids);
    my %in_lib = map { $_->[0] => 1 } @{ $sth->fetchall_arrayref() };
    $sth->finish();
    return \%in_lib;
}

# Return a DBIx Album row object (or undef).  For callers that need to
# navigate the ORM object graph (contributor, musicbrainz_id, etc.).
sub getAlbumObject {
    my ($self, $raw_id) = @_;
    $self = $self->getInstance() unless ref $self;
    return undef unless defined $raw_id;
    return Slim::Schema->find('Album', $raw_id);
}

# --- Genres -------------------------------------------------------------------

# --- Tracks by genre ----------------------------------------------------------

sub getTracksByGenre {
    my ($self, %args) = @_;
    $self = $self->getInstance() unless ref $self;

    my $genre_name = $args{genre} // '';
    return [] unless length $genre_name;

    my $genre = Slim::Schema->search('Genre', { name => $genre_name })->first();
    return [] unless $genre;

    my $count  = $args{count}  // 20;
    my $offset = $args{offset} // 0;
    my $lib    = $args{library_id};

    my %criteria = ( audio => 1 );
    my @joins = ('genreTracks');
    $criteria{'genreTracks.genre'} = $genre->id();

    if ($lib) {
        $criteria{'libraryTracks.library'} = $lib;
        push @joins, 'libraryTracks';
    }

    my $rs = Slim::Schema->search('Track',
        \%criteria,
        { join => \@joins, distinct => 1,
          prefetch => ['album', 'primary_artist'],
          order_by => 'me.titlesort',
          rows => $count, offset => $offset }
    );

    my @track_objs = $rs->all();

    my @track_ids  = map { $_->id() } @track_objs;
    my $track_genres = batchFetchAllTrackGenres($self, \@track_ids);

    my $exposed = $prefs->get('exposed_contributor_roles');
    my %role_filter;
    if ($exposed) {
        %role_filter = map { lc($_) => 1 } split(/\s*,\s*/, $exposed);
    }
    else {
        %role_filter = map { lc($_) => 1 } qw(ARTIST COMPOSER CONDUCTOR BAND ALBUMARTIST TRACKARTIST);
    }
    my ($track_contributors, $track_composers) =
        batchFetchTrackContributors($self, \@track_ids, \%role_filter);

    return [ map {
        my $tid = $_->id();
        $self->shapeTrack($_, undef, undef, {
            genres         => $track_genres->{$tid} // [],
            contributors   => $track_contributors->{$tid} // [],
            composerNames  => $track_composers->{$tid} // [],
        });
    } @track_objs ];
}

# --- Top songs ----------------------------------------------------------------

sub getTopSongs {
    my ($self, %args) = @_;
    $self = $self->getInstance() unless ref $self;

    my $t0     = time();
    my $count  = $args{count}  // 50;
    my $artist = $args{artist};
    my $genre  = $args{genre};

    # Scan TrackPersistent (play-count table) in descending order.  We need to
    # walk enough rows to satisfy the $count target after genre/audio filtering,
    # so overscan by a factor of 3.  A single batch resolve of Track objects
    # replaces N individual Slim::Schema->find calls that the old loop used.
    my @persistent;
    my $scan_limit = $count * 3;
    my $rs = Slim::Schema->search('TrackPersistent',
        { 'me.playCount' => { '>' => 0 } },
        { order_by => 'me.playCount DESC' }
    );
    while (my $tp = $rs->next()) {
        push @persistent, $tp;
        last if scalar(@persistent) >= $scan_limit;
    }

    return [] unless @persistent;

    # Batch-find all candidate tracks by urlmd5
    my @md5s = map { $_->urlmd5 } @persistent;
    my @track_objs = Slim::Schema->search('Track',
        { urlmd5 => { -in => \@md5s } },
        { prefetch => ['album', 'primary_artist'] }
    )->all();
    my %track_by_md5 = map { $_->urlmd5 => $_ } @track_objs;

    my @track_ids  = map { $_->id() } @track_objs;
    my $track_genres = batchFetchAllTrackGenres($self, \@track_ids);

    my $exposed = $prefs->get('exposed_contributor_roles');
    my %role_filter;
    if ($exposed) {
        %role_filter = map { lc($_) => 1 } split(/\s*,\s*/, $exposed);
    }
    else {
        %role_filter = map { lc($_) => 1 } qw(ARTIST COMPOSER CONDUCTOR BAND ALBUMARTIST TRACKARTIST);
    }
    my ($track_contributors, $track_composers) =
        batchFetchTrackContributors($self, \@track_ids, \%role_filter);

    my @top;
    for my $tp (@persistent) {
        my $track = $track_by_md5{ $tp->urlmd5 };
        next unless $track && $track->audio();
        if ($genre) {
            my $t_g = $track_genres->{ $track->id() } // [];
            next unless grep { $_ eq $genre } @$t_g;
        }
        if ($artist) {
            my $track_artist = $track->artist();
            next unless $track_artist && $track_artist->name() =~ /\Q$artist\E/i;
        }
        push @top, $self->shapeTrack($track, undef, undef, {
            genres         => $track_genres->{ $track->id() } // [],
            contributors   => $track_contributors->{ $track->id() } // [],
            composerNames  => $track_composers->{ $track->id() } // [],
        });
        last if scalar(@top) >= $count;
    }

    $log->debug(sprintf('SlimPing: getTopSongs took %.1fms (%d songs)', (time() - $t0) * 1000, scalar @top));
    return \@top;
}

# --- Library membership helpers -----------------------------------------------

# Returns a hashref of { raw_id => 1 } for all IDs in the given library table.
# Uses raw DBI because library_album, library_contributor, and library_genre
# have no DBIx::Class schema classes or relationships defined in LMS core.

sub _inLibrary {
    my ($self, $table, $id_col, $lib) = @_;
    return {} unless $lib;

    # Defence in depth: only known-good table/column names from the LMS schema,
    # all callers pass hardcoded literals but validation prevents accidental injection.
    return {} unless $table =~ /^library_[a-z]+$/ && $id_col =~ /^[a-z]+$/;

    my $dbh = Slim::Schema->dbh;
    my $sth = $dbh->prepare_cached("SELECT $id_col FROM $table WHERE library = ?");
    $sth->execute($lib);
    my %in = map { $_->[0] => 1 } @{ $sth->fetchall_arrayref() };
    $sth->finish();
    return \%in;
}

# _batchGenreHint($self, $dbh, \@album_ids) -> \%hints
#
# Returns a hashref of { album_id => genre_name } for the given album IDs using
# a subquery that picks one track per album first, then joins genre data only
# for those single tracks.  This avoids the 3-table JOIN across all tracks that
# the naive GROUP BY approach would incur -- a major win when the album list is
# large (Symfonium requests 500 albums at a time).
sub _batchGenreHint {
    my ($self, $dbh, $album_ids) = @_;
    my %genre_for;
    return \%genre_for unless @$album_ids;

    my $placeholders = join(',', ('?') x scalar @$album_ids);
    # Plain prepare() -- not prepare_cached() -- because the variable-length IN
    # clause produces a different SQL string per batch size.
    my $sth = $dbh->prepare(
        "SELECT sq.album, g.name FROM ("
      . "  SELECT album, MIN(id) AS tid FROM tracks"
      . "  WHERE album IN ($placeholders) AND audio = 1"
      . "  GROUP BY album"
      . ") sq"
      . " JOIN genre_track gt ON gt.track = sq.tid"
      . " JOIN genres g ON g.id = gt.genre"
    );
    $sth->execute(@$album_ids);
    while (my ($aid, $gname) = $sth->fetchrow_array()) {
        $genre_for{$aid} = $gname;
    }
    $sth->finish();
    return \%genre_for;
}

# batchFetchTrackGenres($self, \@track_objs) -> \%hints
#
# Returns a hashref of { track_id => first_genre_name_or_empty_string } for
# the given Track objects.  Single-genre-per-track resolution via genre_track
# JOIN.  Tracks with no tagged genre map to an empty string, so callers can
# distinguish "didn't check" -- undef -- from "no genre" -- ''.
#
# Replaces the SQL idiom that was duplicated nine times across handlers and
# Queries.pm itself.  All callers should use this method instead of inlining
# the genre_track JOIN.
sub batchFetchTrackGenres {
    my ($self, $track_objs) = @_;
    return {} unless $track_objs && @$track_objs;

    my @tids = map { $_->id() } @$track_objs;
    my $dbh = Slim::Schema->dbh;
    my $placeholders = join(',', ('?') x scalar @tids);
    # Plain prepare() -- not prepare_cached() -- because the variable-length IN
    # clause produces a different SQL string per batch size.
    my $sth = $dbh->prepare(
        "SELECT gt.track, g.name FROM genre_track gt"
      . " JOIN genres g ON g.id = gt.genre"
      . " WHERE gt.track IN ($placeholders)"
      . " ORDER BY gt.genre"
    );
    $sth->execute(@tids);
    my %out;
    while (my ($tid, $gname) = $sth->fetchrow_array()) {
        $out{$tid} //= $gname;
    }
    $sth->finish();
    $out{ $_->id() } //= '' for @$track_objs;
    return \%out;
}

# batchFetchAllTrackGenres($self, \@track_ids) -> \%hints
#
# Returns a hashref of { track_id => [genre_name, ...] } for the given track
# IDs.  All genres are returned, capped by the genre_count_per_entity pref
# (default 3).  Tracks with no genre map to an empty arrayref.
#
# Unlike batchFetchTrackGenres which takes Track objects and returns a single
# genre per track, this method takes raw track IDs (integers) so callers from
# RawQueries can use it without instantiating DBIx objects.
sub batchFetchAllTrackGenres {
    my ($self, $track_ids) = @_;
    return {} unless $track_ids && @$track_ids;

    my $prefs = Plugins::SlimPing::Core::Logging->getPrefs();
    my $cap   = $prefs->get('genre_count_per_entity') // 3;
    $cap = 1 if $cap < 1;

    my $dbh = Slim::Schema->dbh;
    my $placeholders = join(',', ('?') x scalar @$track_ids);
    # Plain prepare() -- not prepare_cached() -- because the variable-length IN
    # clause produces a different SQL string per batch size.
    my $sth = $dbh->prepare(
        "SELECT gt.track, g.name FROM genre_track gt"
      . " JOIN genres g ON g.id = gt.genre"
      . " WHERE gt.track IN ($placeholders)"
      . " ORDER BY gt.genre"
    );
    $sth->execute(@$track_ids);
    my %out;
    while (my ($tid, $gname) = $sth->fetchrow_array()) {
        push @{ $out{$tid} }, $gname
            if @{ $out{$tid} // [] } < $cap;
    }
    $sth->finish();
    $out{ $_ } //= [] for @$track_ids;
    return \%out;
}

# batchFetchTrackContributors($self, \@track_ids, \%role_filter) -> (\%contributors, \%composer_names)
#
# Returns two hashrefs keyed by raw track ID:
#   \%contributors:    { track_id => [{role, artist => {id, name}}, ...] }
#   \%composer_names:  { track_id => ['Name', ...] }
# \%role_filter is a hashref of {lowercase_role_name => 1} -- only roles
# in this set are included.  An empty/undef filter includes all roles.
sub batchFetchTrackContributors {
    my ($self, $track_ids, $role_filter) = @_;
    return ({}, {}) unless $track_ids && @$track_ids;

    $role_filter //= {};

    # Translate role-name filter to role IDs once, so the filter can be pushed
    # into the SQL WHERE clause.  Roles with no known ID mapping are left for
    # the Perl-side guard (they should never match, but this is defensive).
    my @role_ids;
    if (%$role_filter) {
        for my $rn (keys %$role_filter) {
            my $rid = Slim::Schema::Contributor->typeToRole(uc($rn));
            push @role_ids, $rid if defined $rid;
        }
    }

    my $dbh = Slim::Schema->dbh;
    my $placeholders = join(',', ('?') x scalar @$track_ids);
    my $sql = "SELECT ct.track, ct.role, c.id, c.name"
            . " FROM contributor_track ct"
            . " JOIN contributors c ON c.id = ct.contributor"
            . " WHERE ct.track IN ($placeholders)";

    my @params = @$track_ids;
    if (@role_ids) {
        my $rp = join(',', ('?') x scalar @role_ids);
        $sql .= " AND ct.role IN ($rp)";
        push @params, @role_ids;
    }

    # Plain prepare() -- not prepare_cached() -- because the variable-length IN
    # clause and optional role filter produce a different SQL string per call.
    my $sth = $dbh->prepare($sql);
    $sth->execute(@params);

    # Capture the role map hashref once to avoid per-row class method dispatch.
    my $role_map = Slim::Schema::Contributor->roleToContributorMap();

    my %contributors;
    my %composer_names;
    my %artist_obj;     # memoized {id, name} hashrefs per unique contributor
    my %encoded_id;     # memoized encoded artist IDs

    while (my ($tid, $role_id, $cid, $cname) = $sth->fetchrow_array()) {
        my $role_name = lc($role_map->{$role_id} // $role_id);
        next if %$role_filter && !$role_filter->{$role_name};

        my $artist = $artist_obj{$cid} //= do {
            my $enc = $encoded_id{$cid} //= $self->encodeId('artist', $cid);
            { id => $enc, name => $cname };
        };

        push @{ $contributors{$tid} }, { role => $role_name, artist => $artist };

        if ($role_name eq 'composer') {
            push @{ $composer_names{$tid} }, $cname;
        }
    }
    $sth->finish();

    for my $tid (@$track_ids) {
        $contributors{$tid}   //= [];
        $composer_names{$tid} //= [];
    }

    return (\%contributors, \%composer_names);
}

# batchFetchArtistRoles($self, \@artist_ids) -> \%roles
#
# Returns { artist_id => [lowercase_role_name, ...] } for the given raw
# contributor IDs.  Mirrors the DBIx role union in shapeArtist
# (Shapes.pm:157-176) but batched for the search3 / getArtists hashref
# paths, which cannot lazy-load contributor roles.
#
# Uses the same roleToContributorMap() mapping as
# batchFetchTrackContributors, so custom (user-defined) roles come
# through lowercased too.  UNION dedupes (contributor, role) pairs.
sub batchFetchArtistRoles {
    my ($self, $artist_ids) = @_;
    my %roles_for;
    return \%roles_for unless $artist_ids && @$artist_ids;

    my $dbh = Slim::Schema->dbh;
    my $placeholders = join(',', ('?') x scalar @$artist_ids);
    my $sql = "SELECT ct.contributor, ct.role FROM contributor_track ct"
            . " WHERE ct.contributor IN ($placeholders)"
            . " UNION"
            . " SELECT ca.contributor, ca.role FROM contributor_album ca"
            . " WHERE ca.contributor IN ($placeholders)";

    # Plain prepare() -- variable-length IN clause produces a different
    # SQL string per call (same rationale as batchFetchTrackContributors).
    my $sth = $dbh->prepare($sql);
    $sth->execute(@$artist_ids, @$artist_ids);

    # Capture the role map hashref once to avoid per-row class method dispatch.
    my $role_map = Slim::Schema::Contributor->roleToContributorMap();
    while (my ($cid, $role_id) = $sth->fetchrow_array()) {
        my $role_name = lc($role_map->{$role_id} // $role_id);
        $role_name = 'artist' if $role_name eq 'trackartist';
        push @{ $roles_for{$cid} }, $role_name;
    }
    $sth->finish();

    # TRACKARTIST maps to ARTIST (see shapeArtist), so roles 1 and 6 can
    # both produce 'artist' -- dedupe each artist's list.
    for my $cid ( keys %roles_for ) {
        my %seen;
        $roles_for{$cid} = [ grep { !$seen{$_}++ } @{ $roles_for{$cid} } ];
    }

    $roles_for{$_} //= [] for @$artist_ids;
    return \%roles_for;
}

# batchFetchAlbumGenres($self, $dbh, \@album_ids) -> \%hints
#
# Returns { album_id => [genre_name, ...] } for the given album IDs.
# All genres from all tracks on each album are collected, deduplicated
# via DISTINCT, and capped by genre_count_per_entity pref.
sub batchFetchAlbumGenres {
    my ($self, $dbh, $album_ids) = @_;
    my %genre_for;
    return \%genre_for unless @$album_ids;

    my $prefs = Plugins::SlimPing::Core::Logging->getPrefs();
    my $cap   = $prefs->get('genre_count_per_entity') // 3;
    $cap = 1 if $cap < 1;

    my $placeholders = join(',', ('?') x scalar @$album_ids);
    my $sth = $dbh->prepare(
        "SELECT DISTINCT t.album, g.name FROM tracks t"
      . " JOIN genre_track gt ON gt.track = t.id"
      . " JOIN genres g ON g.id = gt.genre"
      . " WHERE t.album IN ($placeholders) AND t.audio = 1"
      . " ORDER BY t.album, gt.genre"
    );
    $sth->execute(@$album_ids);
    while (my ($aid, $gname) = $sth->fetchrow_array()) {
        push @{ $genre_for{$aid} }, $gname
            if @{ $genre_for{$aid} // [] } < $cap;
    }
    $sth->finish();
    $genre_for{$_} //= [] for @$album_ids;
    return \%genre_for;
}

# batchFetchAlbumArtists($self, $dbh, \@album_ids) -> \%hints
#
# Returns { album_id => [{id, name}, ...] } for the given album IDs.
# Queries contributor_album for the ALBUMARTIST (role 5) only.  Role 1
# (ARTIST) rows are populated per track contributor, so including them
# would contaminate the AlbumID3 'artists'/'displayArtist' fields with
# every guest artist on the album (spec: "The list of all album artists
# of the album").  Albums with no role-5 rows fall back to the single
# album contributor in shapeAlbum (Shapes.pm:491-494).
sub batchFetchAlbumArtists {
    my ($self, $dbh, $album_ids) = @_;
    my %artists_for;
    return \%artists_for unless @$album_ids;

    my $placeholders = join(',', ('?') x scalar @$album_ids);
    my $sth = $dbh->prepare(
        "SELECT DISTINCT ca.album, c.id, c.name FROM contributor_album ca"
      . " JOIN contributors c ON c.id = ca.contributor"
      . " WHERE ca.album IN ($placeholders)"
      . " AND ca.role = 5"
      . " ORDER BY ca.album, c.name"
    );
    $sth->execute(@$album_ids);
    while (my ($aid, $cid, $cname) = $sth->fetchrow_array()) {
        push @{ $artists_for{$aid} }, {
            id   => $self->encodeId('artist', $cid),
            name => $cname,
        };
    }
    $sth->finish();
    $artists_for{$_} //= [] for @$album_ids;
    return \%artists_for;
}

# batchFetchAlbumDataForTracks($self, \@track_objs) -> \%album_data
#
# Batch-resolves album metadata (id, title, contributor_id, contributor_name)
# for the given Track objects via a single raw SQL query.  Returns a hashref of
# { album_id => { id, title, contributor_id, contributor_name } } lightweight
# hashrefs.  No DBIx Album or Contributor objects are created, so nothing enters
# the global identity map -- this is the key difference from the old
# batchFetchTrackAlbums which created full DBIx objects that lived forever.
#
# Used by shapePlaylist where tracks come through the PlaylistTrack resultset
# (which cannot carry Track-level album/contributor prefetch).
sub batchFetchAlbumDataForTracks {
    my ($self, $track_objs) = @_;
    return {} unless $track_objs && @$track_objs;

    my %album_ids;
    for my $t (@$track_objs) {
        my $aid = $t->get_column('album');
        $album_ids{$aid} = 1 if defined $aid;
    }
    return {} unless keys %album_ids;

    my @ids = keys %album_ids;
    my $dbh = Slim::Schema->dbh;
    my $placeholders = join(',', ('?') x scalar @ids);

    # Plain prepare() -- not prepare_cached() -- because the variable-length IN
    # clause produces a different SQL string for every distinct batch size.
    # prepare_cached would create a new cached handle per size and never evict it.
    my $sth = $dbh->prepare(
        "SELECT a.id, a.title, c.id, c.name, a.compilation"
      . " FROM albums a"
      . " LEFT JOIN contributors c ON a.contributor = c.id"
      . " WHERE a.id IN ($placeholders)"
    );
    $sth->execute(@ids);

    my %data;
    while (my ($aid, $atitle, $cid, $cname, $acomp) = $sth->fetchrow_array()) {
        $data{$aid} = {
            id               => $aid,
            title            => $atitle // '',
            contributor_id   => $cid,
            contributor_name => $cname // '',
            compilation      => $acomp ? 1 : 0,
        };
    }
    $sth->finish();

    # Ensure every requested album ID gets an entry, even if the LEFT JOIN
    # didn't match (NULL contributor FK or missing album row).
    for my $aid (@ids) {
        $data{$aid} //= {
            id               => $aid,
            title            => '',
            contributor_id   => undef,
            contributor_name => '',
            compilation      => 0,
        };
    }

    return \%data;
}

1;
