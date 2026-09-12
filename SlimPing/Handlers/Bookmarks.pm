package Plugins::SlimPing::Handlers::Bookmarks;

use strict;
use warnings;

use Plugins::SlimPing::API::Router;
require Plugins::SlimPing::Core::Container;
require Plugins::SlimPing::Utils::Errors;

my $_store;

sub _store {
    require Plugins::SlimPing::Core::BookmarkStore;
    $_store ||= Plugins::SlimPing::Core::BookmarkStore->getInstance();
    return $_store;
}

sub registerHandlers {
    my $class = shift;
    Plugins::SlimPing::API::Router->registerHandler('getBookmarks',   \&getBookmarks);
    Plugins::SlimPing::API::Router->registerHandler('createBookmark', \&createBookmark);
    Plugins::SlimPing::API::Router->registerHandler('deleteBookmark', \&deleteBookmark);
}

sub getUserBookmarks {
    my ($class, $username) = @_;
    return _store()->getUserBookmarks($username);
}

sub getBookmarks {
    my ($args) = @_;
    my $username  = $args->{user}{username};
    my $bookmarks = _store()->getUserBookmarks($username);
    my $mapper    = Plugins::SlimPing::Core::Container->get('library_mapper');

    return { bookmarks => { bookmark => [] } } unless keys %$bookmarks;

    # Decode all bookmark IDs and map sq_id -> raw_id in one pass.
    my @sq_ids = keys %$bookmarks;
    my %raw_for;
    for my $sq_id (@sq_ids) {
        my (undef, $raw_id) = $mapper->decodeId($sq_id);
        $raw_for{$sq_id} = $raw_id if defined $raw_id;
    }

    # Batch-fetch all referenced tracks in one query with album + artist prefetch.
    my %track_for;
    my %raw_id_to_sq;
    if (%raw_for) {
        my @raw_ids = values %raw_for;
        my @tracks  = $mapper->getTracksByIds(\@raw_ids);
        %track_for  = map { $_->id() => $_ } @tracks;

        # Build reverse map: raw_id -> sq_id (for annotation hint lookups).
        %raw_id_to_sq = reverse %raw_for;
    }

    # Batch-fetch user annotations (starred-at, per-user rating) for all entries.
    require Plugins::SlimPing::Core::Annotations;
    my $starred_batch = Plugins::SlimPing::Core::Annotations->getStarredBatch($username, \@sq_ids);
    my $rating_batch  = Plugins::SlimPing::Core::Annotations->getRatingBatch($username, \@sq_ids);

    # Batch-fetch average ratings for all bookmark entries.
    require Plugins::SlimPing::Core::RatingStore;
    my $avg_ratings = Plugins::SlimPing::Core::RatingStore->getAverageRatingBatch(\@sq_ids);

    # Pre-compute per-track shapeTrack hints (genres, contributors, album artists)
    # so that shapeTrack never falls through to its per-item DBIx lazy-load paths.
    my %hints_for;
    my $album_data;
    if (%raw_for) {
        my @raw_ids = values %raw_for;

        my $genres_by_raw = $mapper->batchFetchAllTrackGenres(\@raw_ids);
        my ($contrib, $composer) = $mapper->batchFetchTrackContributors(\@raw_ids);

        # Collect unique album IDs for a single batch album-artist query.
        my %album_ids;
        for my $track (values %track_for) {
            my $aid = $track->get_column('album');
            $album_ids{$aid} = 1 if defined $aid;
        }
        my $album_artists = {};
        if (%album_ids) {
            $album_artists =
              $mapper->batchFetchAlbumArtists( Slim::Schema->dbh, [ keys %album_ids ] );
        }

        # Batch-resolve album metadata (id, title, contributor, compilation)
        # so shapeTrack uses the pre-resolved hashref instead of firing a
        # per-track DBIx contributor query.  Declared outside the if block
        # because it is referenced in the entry-building loop below.
        $album_data =
          $mapper->batchFetchAlbumDataForTracks( [ values %track_for ] );

        # Build per-raw_id hint hashes.
        for my $raw_id (@raw_ids) {
            my $track = $track_for{$raw_id};
            next unless $track;
            my $sq_id  = $raw_id_to_sq{$raw_id};
            my $aid    = $track->get_column('album');
            my $adata  = ( defined $aid ? $album_data->{$aid} : undef );
            $hints_for{$raw_id} = {
                starredAt        => $starred_batch->{$sq_id},
                rating           => $rating_batch->{$sq_id},
                averageRating    => $avg_ratings->{$sq_id},
                genres           => $genres_by_raw->{$raw_id} // [],
                contributors     => $contrib->{$raw_id} // [],
                composerNames    => $composer->{$raw_id} // [],
                isCompilation    => $adata ? ( $adata->{compilation} // 0 ) : 0,
                ( defined $aid
                    ? ( albumArtists => $album_artists->{$aid} // [] )
                    : () ),
            };
        }
    }

    my @entries;
    for my $sq_id (@sq_ids) {
        my $bm    = $bookmarks->{$sq_id};
        my $entry;

        if (exists $raw_for{$sq_id}) {
            my $raw_id = $raw_for{$sq_id};
            my $track  = $track_for{$raw_id};
            if ($track) {
                my $hints = $hints_for{$raw_id} // {};
                $entry = $mapper->shapeTrack($track, undef, $album_data, {
                    %$hints,
                    bookmarkPosition => $bm->{position} // 0,
                });
            }
        }

        if (!$entry) {
            $entry = { id => $sq_id, isDir => \0 };
        }

        push @entries, {
            entry    => $entry,
            position => $bm->{position} // 0,
            username => $username,
            comment  => $bm->{comment} // '',
            created  => $bm->{created},
            changed  => $bm->{changed},
        };
    }

    return { bookmarks => { bookmark => \@entries } };
}

sub createBookmark {
    my ($args) = @_;
    my $p = $args->{params};
    my $id = $p->{id}
        or return Plugins::SlimPing::Utils::Errors->missingParam('id');
    # Per OpenSubsonic spec, position is in milliseconds.
    my $position = $p->{position} // 0;
    my $comment  = $p->{comment}  // '';
    my $username = $args->{user}{username};

    _store()->createBookmark($username, $id, $position, $comment);

    return {};
}

sub deleteBookmark {
    my ($args) = @_;
    my $id = $args->{params}{id}
        or return Plugins::SlimPing::Utils::Errors->missingParam('id');

    my $username = $args->{user}{username};
    _store()->deleteBookmark($username, $id);

    return {};
}

1;
