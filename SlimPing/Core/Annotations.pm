package Plugins::SlimPing::Core::Annotations;

use strict;
use warnings;

use Plugins::SlimPing::Core::Logging;

my $log = Plugins::SlimPing::Core::Logging->getLogger();

# --- Read accessors (delegated to StarStore / RatingStore) ---------------------

sub _starStore {
    require Plugins::SlimPing::Core::StarStore;
    return Plugins::SlimPing::Core::StarStore->getInstance();
}

sub _ratingStore {
    require Plugins::SlimPing::Core::RatingStore;
    return Plugins::SlimPing::Core::RatingStore->getInstance();
}

sub getStars {
    my ( $class, $username ) = @_;
    return _starStore()->getStars($username);
}

sub isStarred {
    my ( $class, $username, $sq_id ) = @_;
    return _starStore()->isStarred( $username, $sq_id );
}

# Track ratings come from Ratings Light when it is installed, because it owns
# the rating column and also sees ratings set outside SlimPing.  RL has no
# value for an unrated track, and refuses writes silently during a scan or for
# a track with no persistent row, so fall back to SlimPing's per-user store
# rather than making a set rating disappear.
sub getRating {
    my ( $class, $username, $sq_id ) = @_;

    require Plugins::SlimPing::Core::RatingsLight;
    if ( Plugins::SlimPing::Core::RatingsLight->available ) {
        require Plugins::SlimPing::Core::LibraryMapper;
        my ($type) = eval { Plugins::SlimPing::Core::LibraryMapper->decodeId($sq_id) };
        if ( !$@ && ( $type // '' ) eq 'track' ) {
            my $rating = Plugins::SlimPing::Core::RatingsLight->fetchOne($sq_id);
            return $rating if defined $rating;
        }
    }

    return _ratingStore()->getRating( $username, $sq_id );
}

sub getStarredAt {
    my ( $class, $username, $sq_id ) = @_;
    return _starStore()->getStarredAt( $username, $sq_id );
}

# Merged single-item lookup: per-user SlimPing store first, then bridged
# LMS favourites (the server-global OPML file).  Returns the SlimPing star
# timestamp, else the favourites-file mtime timestamp for bridged items,
# else undef.  InfoMenu does NOT use this merged variant (its labels
# describe Subsonic-client stars only).
sub getStarredAtMerged {
    my ( $class, $username, $sq_id ) = @_;
    return undef unless $sq_id;

    my $mine = $class->getStarredAt( $username, $sq_id );
    return $mine if $mine;

    require Plugins::SlimPing::Core::LmsFavorites;
    my $lms = Plugins::SlimPing::Core::LmsFavorites->list();
    for my $bucket (qw(tracks albums artists)) {
        return Plugins::SlimPing::Core::LmsFavorites->timestamp()
          if exists $lms->{$bucket}{$sq_id};
    }
    return undef;
}

# Batch fetch starred timestamps for a list of sq_ids.
# Returns hashref of { sq_id => iso8601_string }.
sub getStarredBatch {
    my ( $class, $username, $sq_ids ) = @_;
    return {} unless $username && $sq_ids && ref $sq_ids eq 'ARRAY' && @$sq_ids;

    my $raw = _starStore()->getStarredIdsBatch( $username, $sq_ids );
    return {} unless keys %$raw;

    require Plugins::SlimPing::Core::LibraryMapper;
    my %iso;
    $iso{$_} = Plugins::SlimPing::Core::LibraryMapper::_iso8601( $raw->{$_} ) for keys %$raw;
    return \%iso;
}

# Batch fetch ratings for a list of sq_ids.
# Returns hashref of { sq_id => rating_int }.
#
# With Ratings Light present, its rating wins for tracks and SlimPing's own
# store fills the gaps (RL has no album or artist ratings, and no value for an
# unrated track).  One local batch plus one RL batch, regardless of list size.
sub getRatingBatch {
    my ( $class, $username, $sq_ids ) = @_;
    return {} unless $username && $sq_ids && ref $sq_ids eq 'ARRAY' && @$sq_ids;

    my $local = _ratingStore()->getRatingBatch( $username, $sq_ids );

    require Plugins::SlimPing::Core::RatingsLight;
    return $local unless Plugins::SlimPing::Core::RatingsLight->available;

    require Plugins::SlimPing::Core::LibraryMapper;
    my @track_ids;
    for my $sq_id (@$sq_ids) {
        my ($type) = eval { Plugins::SlimPing::Core::LibraryMapper->decodeId($sq_id) };
        push @track_ids, $sq_id if !$@ && ( $type // '' ) eq 'track';
    }

    my $rl     = Plugins::SlimPing::Core::RatingsLight->fetchBatch( \@track_ids );
    my %result = ( %$local, %$rl );
    return \%result;
}

sub modifyStars {
    my ( $class, $user, $p, $add ) = @_;
    return _starStore()->modifyStars( $user, $p, $add );
}

# Keep SlimPing's own copy of the rating (it is the fallback when RL has no
# value, and the only store for album and artist ratings) and push tracks to
# Ratings Light so its bookkeeping and notifications run.
sub setUserRating {
    my ( $class, $user, $id, $rating ) = @_;
    my $result = _ratingStore()->setRating( $user, $id, $rating );

    require Plugins::SlimPing::Core::RatingsLight;
    if ( Plugins::SlimPing::Core::RatingsLight->available ) {
        my $pushed = eval { Plugins::SlimPing::Core::RatingsLight->submit( $id, $rating ) };
        if ($@) {
            $log->warn("SlimPing: RatingsLight dispatch failed for $id: $@");
        }
        elsif ( !$pushed ) {
            $log->debug("SlimPing: RatingsLight not updated for $id (not a track, or refused)");
        }
    }

    return $result;
}

1;
