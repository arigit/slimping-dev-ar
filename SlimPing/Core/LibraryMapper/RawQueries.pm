# INTERNAL MODULE -- do not use directly. All access through the
# Plugins::SlimPing::Core::LibraryMapper facade.
#
# Core/LibraryMapper/RawQueries.pm - Flattened raw DBI queries for hot paths
#
# Replaces multi-query DBIx::Class chains with single raw DBI queries that
# return every column needed for the Subsonic response in one resultset.
# Response hashrefs use the exact same keys as Shapes.pm -- ResponseFormatter
# is unchanged.  No DBIx objects are created, so nothing enters the global
# identity map.

package Plugins::SlimPing::Core::LibraryMapper::RawQueries;

use strict;
use warnings;

use Slim::Schema;
use Time::HiRes qw(time);
use Plugins::SlimPing::Core::Logging;

my $log   = Plugins::SlimPing::Core::Logging->getLogger();
my $prefs = Plugins::SlimPing::Core::Logging->getPrefs();

# _sortedArtistPool($self, $lib) -> \[[id, namesort], ...]
#
# Returns a cached arrayref of [id, namesort] pairs for every artist,
# sorted by namesort.  Drives from contributor_track (indexed by role)
# rather than scanning all contributors, so it scales to large libraries.
# Cached per generation until the next library rescan invalidates it.
sub _sortedArtistPool {
    my ($self, $lib) = @_;
    $self = $self->getInstance() unless ref $self;

    my $cache_key = $lib ? "slimping.sorted_artists.$lib" : 'slimping.sorted_artists';

    return $self->_cached($cache_key, sub {
        my $dbh = Slim::Schema->dbh;
        my $sql = 'SELECT DISTINCT c.id'
                . ' FROM contributor_track ct'
                . ' JOIN contributors c ON c.id = ct.contributor'
                . ' WHERE ct.role IN (1, 5, 6)';

        my @params;
        if ($lib) {
            $sql .= ' AND EXISTS (SELECT 1 FROM library_contributor lc'
                  . ' WHERE lc.contributor = ct.contributor AND lc.library = ?)';
            push @params, $lib;
        }

        $sql .= ' ORDER BY c.namesort';

        my $sth = $dbh->prepare($sql);
        $sth->execute(@params);
        my @sorted = map { [$_->[0]] } @{ $sth->fetchall_arrayref() };
        $sth->finish();
        return \@sorted;
    });
}

# _sortedAlbumPool($self, $lib) -> \@ids
#
# Cached arrayref of all album IDs, sorted by id DESC.  Rebuilt once per
# rescan generation; paginated calls slice it in Perl.
sub _sortedAlbumPool {
    my ($self, $lib) = @_;
    $self = $self->getInstance() unless ref $self;
    my $cache_key = $lib ? "slimping.sorted_albums.$lib" : 'slimping.sorted_albums';
    return $self->_cached($cache_key, sub {
        my $dbh = Slim::Schema->dbh;
        my $sql = 'SELECT a.id FROM albums a';
        my @params;
        if ($lib) {
            $sql .= ' WHERE EXISTS (SELECT 1 FROM library_album la'
                  . ' WHERE la.album = a.id AND la.library = ?)';
            push @params, $lib;
        }
        $sql .= ' ORDER BY a.id DESC';
        my $sth = $dbh->prepare($sql);
        $sth->execute(@params);
        my @ids = map { $_->[0] } @{ $sth->fetchall_arrayref() };
        $sth->finish();
        return \@ids;
    });
}

# _sortedSongPool($self, $lib) -> \@ids
#
# Cached arrayref of all audio-track IDs, sorted by id DESC.  Rebuilt once
# per rescan generation; paginated calls slice it in Perl.
sub _sortedSongPool {
    my ($self, $lib) = @_;
    $self = $self->getInstance() unless ref $self;
    my $cache_key = $lib ? "slimping.sorted_songs.$lib" : 'slimping.sorted_songs';
    return $self->_cached($cache_key, sub {
        my $dbh = Slim::Schema->dbh;
        my $sql = 'SELECT t.id FROM tracks t WHERE t.audio = 1';
        my @params;
        if ($lib) {
            $sql .= ' AND EXISTS (SELECT 1 FROM library_track lt'
                  . ' WHERE lt.track = t.id AND lt.library = ?)';
            push @params, $lib;
        }
        $sql .= ' ORDER BY t.id DESC';
        my $sth = $dbh->prepare($sql);
        $sth->execute(@params);
        my @ids = map { $_->[0] } @{ $sth->fetchall_arrayref() };
        $sth->finish();
        return \@ids;
    });
}

sub getArtists {
    my ($self, %args) = @_;
    $self = $self->getInstance() unless ref $self;

    my $t0  = time();
    my $lib = $args{library_id};

    my $dbh = Slim::Schema->dbh;

    # Contributors that are ARTIST (role=1), ALBUMARTIST (role=5), or
    # TRACKARTIST (role=6) on any track.  contributor_track's composite PK
    # (role, contributor, track) allows an indexed lookup, not a full table scan.
    # Album count via LEFT JOIN subquery on contributor_album.
    # Library filtering uses EXISTS on library_contributor when needed.
    my $sql = 'SELECT c.id, c.name, c.namesort, c.musicbrainz_id,'
            . ' COALESCE(ac.album_count, 0) AS album_count'
            . ' FROM contributors c'
            . ' LEFT JOIN ('
            . '  SELECT contributor, COUNT(DISTINCT album) AS album_count'
            . '  FROM contributor_album GROUP BY contributor'
            . ' ) ac ON ac.contributor = c.id'
            . ' WHERE EXISTS ('
            . '  SELECT 1 FROM contributor_track ct'
            . '  WHERE ct.contributor = c.id AND ct.role IN (1, 5, 6)'
            . ' )';

    my @params;
    if ($lib) {
        $sql .= ' AND EXISTS (SELECT 1 FROM library_contributor lc'
              . ' WHERE lc.contributor = c.id AND lc.library = ?)';
        push @params, $lib;
    }

    $sql .= ' ORDER BY c.namesort';

    my $sth = $dbh->prepare($sql);
    $sth->execute(@params);

    my @rows;
    while (my ($id, $name, $namesort, $mbid, $album_count) = $sth->fetchrow_array()) {
        push @rows, [$id, $name, $namesort, $mbid, $album_count];
    }
    $sth->finish();

    my ($starred_batch, $rating_batch) = $self->_batchFetchAnnotations('artist', \@rows);

    # Roles for the page's artists in one batch.  getArtists always
    # shapes via shapeArtist (no legacy variant), so no guard needed.
    my $artist_roles = $self->batchFetchArtistRoles([map { $_->[0] } @rows]);

    my @artists;
    for my $row (@rows) {
        my ($id, $name, $namesort, $mbid, $album_count) = @$row;
        my $encoded = $self->encodeId('artist', $id);
        push @artists, $self->shapeArtist(
            { id => $id, name => $name, namesort => $namesort, musicbrainz_id => $mbid },
            {
                albumCount => int($album_count // 0),
                starredAt  => $starred_batch->{$encoded},
                rating     => $rating_batch->{$encoded},
                roles      => $artist_roles->{$id} // [],
            },
        );
    }

    $log->debug(sprintf('SlimPing: RawQueries::getArtists took %.1fms (%d artists)',
        (time() - $t0) * 1000, scalar @artists));
    return \@artists;
}

sub getGenres {
    my ($self, %args) = @_;
    $self = $self->getInstance() unless ref $self;

    my $t0  = time();
    my $lib = $args{library_id};

    my $dbh = Slim::Schema->dbh;

    my $sql = 'SELECT g.id, g.name, COUNT(DISTINCT gt.track) AS song_count,'
            . ' COUNT(DISTINCT t.album) AS album_count'
            . ' FROM genres g'
            . ' JOIN genre_track gt ON gt.genre = g.id'
            . ' JOIN tracks t ON t.id = gt.track';

    my @params;
    if ($lib) {
        $sql .= ' JOIN library_track lt ON lt.track = gt.track AND lt.library = ?';
        push @params, $lib;
    }

    $sql .= ' GROUP BY g.id, g.name ORDER BY g.name';

    my $sth = $dbh->prepare($sql);
    $sth->execute(@params);

    my @genres;
    while (my ($id, $name, $songs, $albums) = $sth->fetchrow_array()) {
        push @genres, {
            songCount  => int($songs  // 0),
            albumCount => int($albums // 0),
            value      => $name,
        };
    }
    $sth->finish();

    $log->debug(sprintf('SlimPing: RawQueries::getGenres took %.1fms (%d genres)',
        (time() - $t0) * 1000, scalar @genres));
    return \@genres;
}

sub getAlbumList {
    my ($self, %args) = @_;
    $self = $self->getInstance() unless ref $self;

    my $t0     = time();
    my $type   = $args{type}   || 'newest';
    my $size   = $args{size}   // 10;
    my $offset = $args{offset} // 0;
    my $lib   = $args{library_id};
    my $genre = $args{genre};

    my $dbh = Slim::Schema->dbh;

    my %type_order = (
        newest               => 'ta.max_ts DESC',
        highest              => 'ta.min_ts DESC',
        frequent             => 'total_playcount DESC',
        recent               => 'last_played DESC',
        alphabeticalByName   => 'a.titlesort',
        alphabeticalByArtist => 'c.namesort, a.year, a.titlesort',
        byGenre              => 'a.titlesort',
        byYear               => 'a.year DESC, a.titlesort',
    );
    my $order_by = $type_order{$type} || 'a.id DESC';

    # frequent and recent ordering needs playcount / lastplayed from the
    # persistent stats table.  When STATISTICS is off, fall back to a.id DESC.
    my $needs_persistent =
      ( $type eq 'frequent' || $type eq 'recent' ) && main::STATISTICS;
    if ( !$needs_persistent && ( $type eq 'frequent' || $type eq 'recent' ) ) {
        $order_by = 'a.id DESC';
    }

    # Base query with aggregated track data (genre fetched via batch helpers)
    my $sql = 'SELECT a.id, a.title, a.titlesort, a.year, a.musicbrainz_id,'
            . ' c.id AS contributor_id, c.name AS contributor_name,'
            . ' COALESCE(ta.song_count, 0) AS song_count,'
            . ' COALESCE(ta.duration_secs, 0) AS duration_secs,'
            . ' ta.min_ts AS created_ts,'
            . ' a.compilation, a.release_type';
    if ($needs_persistent) {
        $sql .= ', COALESCE(tpa.total_playcount, 0) AS total_playcount,'
              . ' tpa.last_played AS last_played';
    }
    $sql .= ' FROM albums a'
          . ' LEFT JOIN contributors c ON a.contributor = c.id'
          . ' LEFT JOIN ('
          . '  SELECT album, COUNT(*) AS song_count,'
          . '   COALESCE(SUM(secs), 0) AS duration_secs,'
          . '   MAX(added_time) AS max_ts,'
          . '   MIN(added_time) AS min_ts'
          . '  FROM tracks WHERE audio = 1 GROUP BY album'
          . ' ) ta ON ta.album = a.id';
    if ($needs_persistent) {
        $sql .= ' LEFT JOIN ('
              . '  SELECT t2.album,'
              . '   COALESCE(SUM(tp2.playCount), 0) AS total_playcount,'
              . '   MAX(tp2.lastplayed) AS last_played'
              . '  FROM tracks t2'
              . '  LEFT JOIN tracks_persistent tp2 ON tp2.urlmd5 = t2.urlmd5'
              . '  WHERE t2.audio = 1 GROUP BY t2.album'
              . ' ) tpa ON tpa.album = a.id';
    }

    my @params;
    my $where_added = 0;
    if ($lib) {
        $sql .= ' WHERE EXISTS (SELECT 1 FROM library_album la'
              . ' WHERE la.album = a.id AND la.library = ?)';
        push @params, $lib;
        $where_added = 1;
    }
    if ($genre) {
        $sql .= ( $where_added ? ' AND' : ' WHERE' )
              . ' a.id IN (SELECT DISTINCT t3.album FROM tracks t3 '
              . 'JOIN genre_track gt3 ON gt3.track = t3.id '
              . 'JOIN genres g3 ON g3.id = gt3.genre WHERE g3.name = ?)';
        push @params, $genre;
        $where_added = 1;
    }

    # type=starred has no %type_order entry and previously fell through to
    # an unfiltered a.id DESC listing (every album in the library).  Restrict
    # to the merged starred set: per-user SlimPing stars plus bridged LMS
    # favourites.  An empty merged set means an empty list, not every album.
    if ( $type eq 'starred' ) {
        my %sq_ids;
        my $username = Plugins::SlimPing::Core::LibraryMapper::_requestUsername();
        if ($username) {
            require Plugins::SlimPing::Core::Annotations;
            my $stars = Plugins::SlimPing::Core::Annotations->getStars($username) || {};
            $sq_ids{$_} = 1 for keys %{ $stars->{albums} || {} };
        }
        require Plugins::SlimPing::Core::LmsFavorites;
        my $lms = Plugins::SlimPing::Core::LmsFavorites->list();
        $sq_ids{$_} = 1 for keys %{ $lms->{albums} || {} };

        my @merged = grep { defined } map { ( $self->decodeId($_) )[1] } keys %sq_ids;
        return [] unless @merged;

        # Chunk the IN list at 50 placeholders (same DBD::SQLite workaround
        # as the batch-fetch helpers elsewhere in this file).
        my @in_clauses;
        for ( my $i = 0; $i < @merged; $i += 50 ) {
            my $end   = $i + 49;
            $end      = $#merged if $end > $#merged;
            my @chunk = @merged[$i .. $end];
            push @in_clauses, '(' . join(',', ('?') x scalar @chunk) . ')';
            push @params, @chunk;
        }
        $sql .= ( $where_added ? ' AND' : ' WHERE' )
              . ' (' . join(' OR ', map { "a.id IN $_" } @in_clauses) . ')';
        $where_added = 1;
    }

    if ($type eq 'random') {
        # Lightweight ID fetch -- SELECT id only, no genre/track aggregation JOINs.
        my $id_sql = 'SELECT a.id FROM albums a';
        my @id_params;
        if ($lib) {
            $id_sql .= ' WHERE EXISTS (SELECT 1 FROM library_album la'
                     . ' WHERE la.album = a.id AND la.library = ?)';
            push @id_params, $lib;
        }
        my $id_sth = $dbh->prepare($id_sql);
        $id_sth->execute(@id_params);
        my @all_ids = map { $_->[0] } @{ $id_sth->fetchall_arrayref() };
        $id_sth->finish();

        return [] unless @all_ids;
        use List::Util qw(shuffle);
        my @shuffled = shuffle(@all_ids);
        my @slice    = @shuffled[$offset .. $offset + $size - 1];
        return [] unless @slice;
        my $placeholders = join(',', ('?') x scalar @slice);
        $sql .= ($where_added ? ' AND' : ' WHERE') . ' a.id IN (' . $placeholders . ')';
        $where_added = 1;
        push @params, @slice;
    } elsif ($type eq 'highest') {
        # Oversample by (offset + size) * 5 (capped at 2500) and post-sort by
        # averageRating.  Ratings live in SlimPing's own SQLite DB so we cannot
        # push the sort into the LMS SQL query.  ta.min_ts DESC provides a
        # plausible candidate pool (recently-added albums are the most likely
        # candidates for highly-rated content).  Post-sort handles the final
        # ranking; offset is honoured after the sort.
        my $oversample = ($offset + $size) * 5;
        $oversample = 2500 if $oversample > 2500;
        $sql .= " ORDER BY $order_by LIMIT ? OFFSET 0";
        push @params, $oversample;
    } else {
        $sql .= " ORDER BY $order_by LIMIT ? OFFSET ?";
        push @params, $size, $offset;
    }

    my $sth = $dbh->prepare($sql);
    $sth->execute(@params);

    my @rows;
    if ($needs_persistent) {
        while (my ($id, $title, $titlesort, $year, $mbid,
                   $contrib_id, $contrib_name,
                   $song_count, $duration_secs, $created_ts,
                   $comp, $rel_type,
                   $total_playcount, $last_played) = $sth->fetchrow_array())
        {
            push @rows, [$id, $title, $titlesort, $year, $mbid,
                         $contrib_id, $contrib_name,
                         $song_count, $duration_secs, $created_ts,
                         $comp, $rel_type,
                         $total_playcount, $last_played];
        }
    } else {
        while (my ($id, $title, $titlesort, $year, $mbid,
                   $contrib_id, $contrib_name,
                   $song_count, $duration_secs, $created_ts,
                   $comp, $rel_type) = $sth->fetchrow_array())
        {
            push @rows, [$id, $title, $titlesort, $year, $mbid,
                         $contrib_id, $contrib_name,
                         $song_count, $duration_secs, $created_ts,
                         $comp, $rel_type];
        }
    }
    $sth->finish();

    my @aid_list       = map { $_->[0] } @rows;
    my $album_genres   = $self->batchFetchAlbumGenres($dbh, \@aid_list);
    my $album_artists  = $self->batchFetchAlbumArtists($dbh, \@aid_list);

    my ($starred_batch, $rating_batch) = $self->_batchFetchAnnotations('album', \@rows);

    my $album_avg_ratings = {};
    if (@rows) {
        require Plugins::SlimPing::Core::RatingStore;
        my @encoded_ids = map { $self->encodeId('album', $_->[0]) } @rows;
        $album_avg_ratings = Plugins::SlimPing::Core::RatingStore->getAverageRatingBatch(\@encoded_ids);
    }

    # Post-sort for highest: oversampled rows are sorted by averageRating DESC,
    # then sliced from offset to offset+size.  Unrated albums (undef) sort last.
    if ($type eq 'highest' && @rows) {
        # Pre-compute ratings lookup keyed by raw album ID to avoid
        # encodeId in the sort comparator (O(n) vs O(n log n) calls).
        my %avg_by_raw = map {
            $_->[0] => $album_avg_ratings->{ $self->encodeId('album', $_->[0]) } // -1
        } @rows;
        @rows = sort { $avg_by_raw{ $b->[0] } <=> $avg_by_raw{ $a->[0] } } @rows;
        # Slice: honour the offset parameter for pagination.
        # splice handles out-of-range offsets correctly (empties the
        # array when offset >= @rows), so no guard is needed.
        splice(@rows, 0, $offset) if $offset > 0;
        splice(@rows, $size) if @rows > $size;
    }

    my @albums;
    for my $row (@rows) {
        my ($id, $title, $titlesort, $year, $mbid,
            $contrib_id, $contrib_name,
            $song_count, $duration_secs, $created_ts,
            $comp, $rel_type) = @$row;
        my $encoded = $self->encodeId('album', $id);
        my %hints = (
            songCount     => int($song_count   // 0),
            durationSecs  => int($duration_secs // 0),
            allGenres     => $album_genres->{$id} // [],
            albumArtists  => $album_artists->{$id} // [],
            artistName    => $contrib_name // '',
            artistId      => defined $contrib_id ? $self->encodeId('artist', $contrib_id) : undef,
            created       => Plugins::SlimPing::Core::LibraryMapper::_iso8601($created_ts // 0),
            starredAt     => $starred_batch->{$encoded},
            rating        => $rating_batch->{$encoded},
            averageRating => $album_avg_ratings->{$encoded},
            isCompilation => $comp ? 1 : 0,
            releaseType   => $rel_type,
        );
        if ($needs_persistent) {
            my $tpc  = $row->[12] // 0;  # total_playcount
            my $lp   = $row->[13];        # last_played
            $hints{playCount} = int($tpc) // 0;
            if ($lp) {
                $hints{played} = Plugins::SlimPing::Core::LibraryMapper::_iso8601($lp);
            }
        }
        push @albums, $self->shapeAlbum(
            {
                id             => $id,
                title          => $title,
                year           => $year,
                musicbrainz_id => $mbid,
                titlesort      => $titlesort,
                compilation    => $comp,
                release_type   => $rel_type,
            },
            \%hints
        );
    }

    $log->debug(sprintf('SlimPing: RawQueries::getAlbumList type=%s took %.1fms (%d albums)',
        $type, (time() - $t0) * 1000, scalar @albums));
    return \@albums;
}

# Return a shuffled pool of track IDs matching optional genre, year-range,
# and library filters.  The caller splices to the desired size.
sub getRandomSongIds {
    my ($self, %args) = @_;
    $self = $self->getInstance() unless ref $self;

    my $size     = $args{size}     // 10;
    my $genre    = $args{genre};
    my $fromYear = $args{fromYear};
    my $toYear   = $args{toYear};
    my $lib      = $args{library_id};

    my $dbh  = Slim::Schema->dbh;
    my $sql  = 'SELECT id FROM tracks WHERE audio = 1';
    my @params;
    if ($genre) {
        $sql .= ' AND id IN (SELECT gt.track FROM genre_track gt '
              . 'JOIN genres g ON g.id = gt.genre WHERE g.name = ?)';
        push @params, $genre;
    }
    if ($fromYear) {
        $sql .= ' AND year >= ?';
        push @params, $fromYear;
    }
    if ($toYear) {
        $sql .= ' AND year <= ?';
        push @params, $toYear;
    }
    if ($lib) {
        $sql .= ' AND id IN (SELECT track FROM library_track WHERE library = ?)';
        push @params, $lib;
    }

    my $sth = $dbh->prepare_cached($sql);
    $sth->execute(@params);
    my @all_ids = map { $_->[0] } @{ $sth->fetchall_arrayref() };
    $sth->finish();

    require List::Util;
    my @picked = List::Util::shuffle(@all_ids);
    splice(@picked, $size) if @picked > $size;

    return @picked;
}

sub search {
    my ($self, %args) = @_;
    $self = $self->getInstance() unless ref $self;

    my $t0     = time();
    my $query  = Plugins::SlimPing::Core::LibraryMapper->cleanSearchQuery($args{query} // '');

    # Spec (open-subsonic-api/openapi/endpoints/search3.json): counts and
    # offsets are integers, default 20 (counts) / 0 (offsets), minimum 0.
    # A value of 0 is meaningful (return none of that type) and must be preserved.
    my $artist_count  = defined $args{artistCount}  ? int($args{artistCount})  : 20;
    my $artist_offset = defined $args{artistOffset} ? int($args{artistOffset}) : 0;
    my $album_count   = defined $args{albumCount}   ? int($args{albumCount})   : 20;
    my $album_offset  = defined $args{albumOffset}  ? int($args{albumOffset})  : 0;
    my $song_count    = defined $args{songCount}    ? int($args{songCount})    : 20;
    my $song_offset   = defined $args{songOffset}   ? int($args{songOffset})   : 0;

    # Spec minimum is 0 -- clamp negatives (SQLite LIMIT -1 means "unlimited").
    $artist_count  = 0 if $artist_count  < 0;
    $album_count   = 0 if $album_count   < 0;
    $song_count    = 0 if $song_count    < 0;
    $artist_offset = 0 if $artist_offset < 0;
    $album_offset  = 0 if $album_offset  < 0;
    $song_offset   = 0 if $song_offset   < 0;
    my $lib           = $args{library_id};
    my $legacy        = $args{legacy};

    # Server-side caps on result counts
    my $max_album_count  = $prefs->get('maxAlbumCount');
    my $max_artist_count = $prefs->get('maxArtistCount');
    my $max_song_count   = $prefs->get('maxSongCount');
    $album_count  = $max_album_count  if $max_album_count  && $album_count  > $max_album_count;
    $artist_count = $max_artist_count if $max_artist_count && $artist_count > $max_artist_count;
    $song_count   = $max_song_count   if $max_song_count   && $song_count   > $max_song_count;

    my $is_empty = length($query) == 0;
    my $like     = '%' . $query . '%';

    my $dbh = Slim::Schema->dbh;

    my $username = Plugins::SlimPing::Core::LibraryMapper::_requestUsername();
    require Plugins::SlimPing::Core::Annotations if $username;

    # --- Artist search -----------------------------------------------------------

    my $t_artist = time();
    my @artists;

    my $shape_method = $legacy ? 'shapeArtistLegacy' : 'shapeArtist';

    my @artist_rows;
    if ($is_empty) {
        # Use a cached, pre-sorted pool of [id, namesort] pairs driven
        # from contributor_track (indexed by role) rather than scanning
        # the full contributors table.  The pool is built once per rescan
        # generation; subsequent paginated calls are Perl array slices
        # plus one small query for full data.
        my $sorted = _sortedArtistPool($self, $lib);

        if ($sorted && @$sorted) {
            my $end_idx = $artist_offset + $artist_count - 1;
            $end_idx = $#$sorted if $end_idx > $#$sorted;
            my @page = ($artist_offset <= $#$sorted)
                ? @$sorted[$artist_offset .. $end_idx]
                : ();

            if (@page) {
                # Fetch in chunks of 50 to work around a DBD::SQLite issue
                # where large IN clauses (>~100 placeholders) silently
                # return truncated results.
                my @page_ids  = map { $_->[0] } @page;
                my %pos       = map { $page_ids[$_] => $_ } 0 .. $#page_ids;
                my $BASE      = 'SELECT c.id, c.name, c.namesort, c.musicbrainz_id,'
                              . ' COALESCE(ca.album_count, 0) AS album_count'
                              . ' FROM contributors c'
                              . ' LEFT JOIN ('
                              . '  SELECT contributor, COUNT(DISTINCT album) AS album_count'
                              . '  FROM contributor_album GROUP BY contributor'
                              . ' ) ca ON ca.contributor = c.id'
                              . ' WHERE c.id IN (';
                my @results;
                for (my $i = 0; $i < @page_ids; $i += 50) {
                    my $end = $i + 49;
                    $end = $#page_ids if $end > $#page_ids;
                    my @chunk = @page_ids[$i .. $end];
                    my $ph    = join(',', ('?') x scalar @chunk);
                    my $sth   = $dbh->prepare($BASE . $ph . ') ORDER BY c.namesort');
                    $sth->execute(@chunk);
                    while (my $row = $sth->fetchrow_arrayref()) {
                        push @results, [$row->[0], $row->[1], $row->[2], $row->[3], $row->[4]];
                    }
                    $sth->finish();
                }
                @artist_rows = sort {
                    ($pos{$a->[0]} // 0) <=> ($pos{$b->[0]} // 0)
                } @results;
            }
        }
    } else {
        my $sql = 'SELECT c.id, c.name, c.namesort, c.musicbrainz_id,'
                . ' COALESCE(ca.album_count, 0) AS album_count'
                . ' FROM contributors c'
                . ' LEFT JOIN ('
                . '  SELECT contributor, COUNT(DISTINCT album) AS album_count'
                . '  FROM contributor_album GROUP BY contributor'
                . ' ) ca ON ca.contributor = c.id'
                . ' WHERE c.name LIKE ?'
                . ' AND EXISTS ('
                . '  SELECT 1 FROM contributor_track ct'
                . '  WHERE ct.contributor = c.id AND ct.role IN (1, 5, 6)'
                . ' )';

        my @params = ($like);
        if ($lib) {
            $sql .= ' AND EXISTS (SELECT 1 FROM library_contributor lc'
                  . ' WHERE lc.contributor = c.id AND lc.library = ?)';
            push @params, $lib;
        }

        $sql .= ' ORDER BY c.namesort LIMIT ? OFFSET ?';
        push @params, $artist_count, $artist_offset;

        my $sth = $dbh->prepare_cached($sql);
        $sth->execute(@params);
        while (my ($id, $name, $namesort, $mbid, $album_count) = $sth->fetchrow_array()) {
            push @artist_rows, [$id, $name, $namesort, $mbid, $album_count];
        }
        $sth->finish();
    }

    my $artist_starred = {};
    my $artist_ratings = {};
    if ($shape_method eq 'shapeArtist') {
        ($artist_starred, $artist_ratings) = $self->_batchFetchAnnotations('artist', \@artist_rows);
    }

    # Roles for the page's artists in one batch; the hashref path in
    # shapeArtist cannot lazy-load contributor roles (no DBIx objects).
    my $artist_roles = $shape_method eq 'shapeArtist'
        ? $self->batchFetchArtistRoles([map { $_->[0] } @artist_rows])
        : {};

    for my $row (@artist_rows) {
        my ($id, $name, $namesort, $mbid, $album_count) = @$row;
        my %hints = ( albumCount => int($album_count // 0) );
        if ($username && $shape_method eq 'shapeArtist') {
            my $encoded = $self->encodeId('artist', $id);
            $hints{starredAt} = $artist_starred->{$encoded};
            $hints{rating}    = $artist_ratings->{$encoded};
        }
        $hints{roles} = $artist_roles->{$id} // [] if $shape_method eq 'shapeArtist';
        push @artists, $self->$shape_method(
            { id => $id, name => $name, namesort => $namesort, musicbrainz_id => $mbid },
            \%hints,
        );
    }
    my $t_artist_ms = (time() - $t_artist) * 1000;

    # --- Album search ------------------------------------------------------------

    my $t_album = time();
    # Genre is supplied per album from the batchFetchAlbumGenres call below;
    # a genre subquery here would return one row per genre of the album's
    # minimum-ID track and duplicate albums with multi-genre tracks.
    my $album_sql = 'SELECT a.id, a.title, a.titlesort, a.year, a.musicbrainz_id,'
                  . ' ac.id AS contrib_id, ac.name AS contrib_name,'
                  . ' COALESCE(ta.song_count, 0) AS song_count,'
                  . ' COALESCE(ta.duration_secs, 0) AS duration_secs,'
                  . ' ta.min_ts AS created_ts,'
                  . ' a.compilation, a.release_type'
                  . ' FROM albums a'
                  . ' LEFT JOIN contributors ac ON a.contributor = ac.id'
                  . ' LEFT JOIN ('
                  . '  SELECT album, COUNT(*) AS song_count,'
                  . '   COALESCE(SUM(secs), 0) AS duration_secs,'
                  . '   MIN(added_time) AS min_ts'
                  . '  FROM tracks WHERE audio = 1 GROUP BY album'
                  . ' ) ta ON ta.album = a.id';

    my @album_params;
    my @album_rows;
    my $album_pool_attempted;
    my $album_sth;
    if ($is_empty) {
        # Use cached sorted pool to avoid full table scan + ORDER BY
        # on every paginated call.  Paginate in Perl, then fetch full
        # data only for the current page.
        my $sorted = _sortedAlbumPool($self, $lib);
        if ($sorted && @$sorted) {
            my $end_idx = $album_offset + $album_count - 1;
            $end_idx = $#$sorted if $end_idx > $#$sorted;
            my @page_ids = ($album_offset <= $#$sorted)
                ? @$sorted[$album_offset .. $end_idx]
                : ();
            if (@page_ids) {
                # Chunked fetch to avoid DBD::SQLite large-IN-clause
                # truncation (same pattern as artist path).
                my %pos       = map { $page_ids[$_] => $_ } 0 .. $#page_ids;
                my $BASE      = $album_sql . ' WHERE a.id IN (';
                my @results;
                for (my $i = 0; $i < @page_ids; $i += 50) {
                    my $end = $i + 49;
                    $end = $#page_ids if $end > $#page_ids;
                    my @chunk = @page_ids[$i .. $end];
                    my $ph    = join(',', ('?') x scalar @chunk);
                    my $sth   = $dbh->prepare($BASE . $ph . ') ORDER BY a.id DESC');
                    $sth->execute(@chunk);
                    while (my $row_ref = $sth->fetchrow_arrayref()) {
                        push @results, [@$row_ref];
                    }
                    $sth->finish();
                }
                @album_rows = sort {
                    ($pos{$a->[0]} // 0) <=> ($pos{$b->[0]} // 0)
                } @results;
            }
        }
        $album_pool_attempted = 1;
    } else {
        $album_sql .= ' WHERE (a.title LIKE ? OR ac.name LIKE ?)';
        push @album_params, $like, $like;
        if ($lib) {
            $album_sql .= ' AND EXISTS (SELECT 1 FROM library_album la'
                        . ' WHERE la.album = a.id AND la.library = ?)';
            push @album_params, $lib;
        }
    }

    # Only fall through to the non-cached path when the pool path was
    # not entered (typed query).  If the pool path ran but the offset
    # was beyond the pool bounds, return an empty result -- do NOT
    # fall through and return unfiltered albums.
    if (!$album_pool_attempted) {
        $album_sql .= ' ORDER BY a.id DESC LIMIT ? OFFSET ?';
        push @album_params, $album_count, $album_offset;
        $album_sth = $dbh->prepare_cached($album_sql);
        $album_sth->execute(@album_params);

        while (my ($id, $title, $titlesort, $year, $mbid,
                   $contrib_id, $contrib_name,
                   $song_count, $duration_secs, $created_ts,
                   $comp, $rel_type) = $album_sth->fetchrow_array()) {
            push @album_rows, [$id, $title, $titlesort, $year, $mbid,
                               $contrib_id, $contrib_name,
                               $song_count, $duration_secs, $created_ts,
                               $comp, $rel_type];
        }
        $album_sth->finish();
    }

    my @search_album_ids = map { $_->[0] } @album_rows;
    my $search_album_genres  = $self->batchFetchAlbumGenres($dbh, \@search_album_ids);
    my $search_album_artists = $self->batchFetchAlbumArtists($dbh, \@search_album_ids);

    my ($album_starred, $album_ratings) = $self->_batchFetchAnnotations('album', \@album_rows);

    my @albums;
    for my $row (@album_rows) {
        my ($id, $title, $titlesort, $year, $mbid,
            $contrib_id, $contrib_name,
            $song_count, $duration_secs, $created_ts,
            $comp, $rel_type) = @$row;
        my $encoded = $self->encodeId('album', $id);
        push @albums, $self->shapeAlbum(
            {
                id             => $id,
                title          => $title,
                year           => $year,
                musicbrainz_id => $mbid,
                titlesort      => $titlesort,
                compilation    => $comp,
                release_type   => $rel_type,
            },
            {
                songCount     => int($song_count   // 0),
                durationSecs  => int($duration_secs // 0),
                genre         => $search_album_genres->{$id}->[0],
                artistName    => $contrib_name // '',
                artistId      => defined $contrib_id ? $self->encodeId('artist', $contrib_id) : undef,
                created       => Plugins::SlimPing::Core::LibraryMapper::_iso8601($created_ts // 0),
                starredAt     => $album_starred->{$encoded},
                rating        => $album_ratings->{$encoded},
                isCompilation => $comp ? 1 : 0,
                releaseType   => $rel_type,
                allGenres     => $search_album_genres->{$id} // [],
                albumArtists  => $search_album_artists->{$id} // [],
            }
        );
    }
    my $t_album_ms = (time() - $t_album) * 1000;

    # --- Song search -------------------------------------------------------------

    my $t_song = time();
    my $song_sql = 'SELECT t.id, t.title, t.titlesort, t.album, a.compilation, t.secs, t.bitrate,'
                 . ' t.content_type, t.url, t.tracknum, t.disc, t.filesize,'
                 . " t.added_time, COALESCE(tp.playcount, 0) AS playcount, t.year, t.bpm,"
                 . ' t.channels, t.samplerate, t.samplesize, t.musicbrainz_id,'
                 . ' a.title AS album_title,'
                 . ' ac.id AS album_contrib_id, ac.name AS album_contrib_name,'
                 . ' art.id AS artist_id, art.name AS artist_name,'
                 . ' t.grouping, w.title AS work_title'
                 . ' FROM tracks t'
                 . ' LEFT JOIN albums a ON t.album = a.id'
                 . ' LEFT JOIN contributors ac ON a.contributor = ac.id'
                 . ' LEFT JOIN contributors art ON art.id = t.primary_artist'
                 . ' LEFT JOIN tracks_persistent tp ON tp.urlmd5 = t.urlmd5'
                 . ' LEFT JOIN works w ON t.work = w.id'
                 . ' WHERE t.audio = 1';

    my @song_params;
    my @song_rows;
    my $song_pool_attempted;
    if (!$is_empty) {
        $song_sql .= ' AND t.title LIKE ?';
        push @song_params, $like;
    }

    my $song_sth;
    if ($is_empty) {
        # Use cached sorted pool to avoid full table scan + ORDER BY
        # on every paginated call.
        my $sorted = _sortedSongPool($self, $lib);
        if ($sorted && @$sorted) {
            my $end_idx = $song_offset + $song_count - 1;
            $end_idx = $#$sorted if $end_idx > $#$sorted;
            my @page_ids = ($song_offset <= $#$sorted)
                ? @$sorted[$song_offset .. $end_idx]
                : ();
            if (@page_ids) {
                # Chunked fetch to avoid DBD::SQLite large-IN-clause
                # truncation (same pattern as artist/album paths).
                my %pos  = map { $page_ids[$_] => $_ } 0 .. $#page_ids;
                my $BASE = $song_sql;
                if ($lib) {
                    $BASE .= ' AND EXISTS (SELECT 1 FROM library_track lt'
                          . ' WHERE lt.track = t.id AND lt.library = ?)';
                }
                $BASE .= ' AND t.id IN (';
                my @results;
                for (my $i = 0; $i < @page_ids; $i += 50) {
                    my $end = $i + 49;
                    $end = $#page_ids if $end > $#page_ids;
                    my @chunk = @page_ids[$i .. $end];
                    my $ph    = join(',', ('?') x scalar @chunk);
                    my $sth   = $dbh->prepare($BASE . $ph . ') ORDER BY t.id DESC');
                    $sth->execute(($lib ? $lib : ()), @chunk);
                    while (my $row_ref = $sth->fetchrow_arrayref()) {
                        push @results, [@$row_ref];
                    }
                    $sth->finish();
                }
                @song_rows = sort {
                    ($pos{$a->[0]} // 0) <=> ($pos{$b->[0]} // 0)
                } @results;
            }
        }
        $song_pool_attempted = 1;
    }

    if (!$song_pool_attempted) {
        if ($lib) {
            $song_sql .= ' AND EXISTS (SELECT 1 FROM library_track lt'
                       . ' WHERE lt.track = t.id AND lt.library = ?)';
            push @song_params, $lib;
        }
        $song_sql .= ' ORDER BY t.id DESC LIMIT ? OFFSET ?';
        push @song_params, $song_count, $song_offset;
        $song_sth = $dbh->prepare_cached($song_sql);
        $song_sth->execute(@song_params);

        while (my ($id, $title, $titlesort, $album_raw_id, $comp, $secs, $bitrate,
                   $content_type, $url, $tracknum, $disc, $filesize,
                   $added_time, $playcount, $year, $bpm,
                   $channels, $samplerate, $samplesize, $mbid,
                   $album_title, $album_contrib_id, $album_contrib_name,
                   $artist_id_raw, $artist_name,
                   $grouping, $work_title) = $song_sth->fetchrow_array()) {
            push @song_rows, [$id, $title, $titlesort, $album_raw_id, $comp, $secs, $bitrate,
                              $content_type, $url, $tracknum, $disc, $filesize,
                              $added_time, $playcount, $year, $bpm,
                              $channels, $samplerate, $samplesize, $mbid,
                              $album_title, $album_contrib_id, $album_contrib_name,
                              $artist_id_raw, $artist_name,
                              $grouping, $work_title];
        }
        $song_sth->finish();
    }

    my ($song_starred, $song_ratings) = $self->_batchFetchAnnotations('track', \@song_rows);

    my $avg_ratings = {};
    if (@song_rows) {
        require Plugins::SlimPing::Core::RatingStore;
        my @encoded = map { $self->encodeId('track', $_->[0]) } @song_rows;
        $avg_ratings = Plugins::SlimPing::Core::RatingStore->getAverageRatingBatch(\@encoded);
    }

    # Batch-fetch genres and contributors for search-result tracks
    my @search_track_ids = map { $_->[0] } @song_rows;
    my $search_genres = $self->batchFetchAllTrackGenres(\@search_track_ids);

    my $exposed = $prefs->get('exposed_contributor_roles');
    my %role_filter;
    if ($exposed) {
        %role_filter = map { lc($_) => 1 } split(/\s*,\s*/, $exposed);
    }
    else {
        %role_filter = map { lc($_) => 1 } qw(ARTIST COMPOSER CONDUCTOR BAND ALBUMARTIST TRACKARTIST);
    }
    my ($search_contributors, $search_composers) =
        $self->batchFetchTrackContributors(\@search_track_ids, \%role_filter);

    my @songs;
    for my $row (@song_rows) {
        my ($id, $title, $titlesort, $album_raw_id, $comp, $secs, $bitrate,
            $content_type, $url, $tracknum, $disc, $filesize,
            $added_time, $playcount, $year, $bpm,
            $channels, $samplerate, $samplesize, $mbid,
            $album_title, $album_contrib_id, $album_contrib_name,
            $artist_id_raw, $artist_name,
            $grouping, $work_title) = @$row;

        my $encoded = $self->encodeId('track', $id);
        push @songs, $self->shapeTrack(
            {
                id                 => $id,
                title              => $title,
                titlesort          => $titlesort,
                album_id           => $album_raw_id,
                album_title        => $album_title,
                album_contrib_id   => $album_contrib_id,
                album_contrib_name => $album_contrib_name,
                secs               => $secs,
                bitrate            => $bitrate,
                content_type       => $content_type,
                url                => $url,
                tracknum           => $tracknum,
                disc               => $disc,
                filesize           => $filesize,
                added_time         => $added_time,
                playcount          => $playcount,
                year               => $year,
                bpm                => $bpm,
                channels           => $channels,
                samplerate         => $samplerate,
                samplesize         => $samplesize,
                musicbrainz_id     => $mbid,
                artist_id          => $artist_id_raw,
                artist_name        => $artist_name,
                grouping           => $grouping,
                work_title         => $work_title,
            },
            undef,
            undef,
            {
                starredAt        => $song_starred->{$encoded},
                rating           => $song_ratings->{$encoded},
                averageRating    => $avg_ratings->{$encoded},
                genres           => $search_genres->{$id} // [],
                contributors     => $search_contributors->{$id} // [],
                composerNames    => $search_composers->{$id} // [],
                bookmarkPosition => undef,
                isCompilation    => $comp ? 1 : 0,
            },
        );
    }
    my $t_song_ms = (time() - $t_song) * 1000;

    $log->debug(sprintf(
        'SlimPing: RawQueries::search q="%s" took %.1fms (a=%d al=%d s=%d) [artist=%.0f album=%.0f song=%.0f]',
        $query, (time() - $t0) * 1000, scalar @artists, scalar @albums, scalar @songs,
        $t_artist_ms, $t_album_ms, $t_song_ms
    ));
    return { artists => \@artists, albums => \@albums, songs => \@songs };
}

1;
