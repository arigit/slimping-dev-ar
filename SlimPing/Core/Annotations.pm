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
    my ($class, $username) = @_;
    return _starStore()->getStars($username);
}

sub isStarred {
    my ($class, $username, $sq_id) = @_;
    return _starStore()->isStarred($username, $sq_id);
}

sub getRating {
    my ($class, $username, $sq_id) = @_;
    return _ratingStore()->getRating($username, $sq_id);
}

sub getStarredAt {
    my ($class, $username, $sq_id) = @_;
    return _starStore()->getStarredAt($username, $sq_id);
}

# Merged single-item lookup: per-user SlimPing store first, then bridged
# LMS favourites (the server-global OPML file).  Returns the SlimPing star
# timestamp, else the favourites-file mtime timestamp for bridged items,
# else undef.  InfoMenu does NOT use this merged variant (its labels
# describe Subsonic-client stars only).
sub getStarredAtMerged {
    my ($class, $username, $sq_id) = @_;
    return undef unless $sq_id;

    my $mine = $class->getStarredAt($username, $sq_id);
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
    my ($class, $username, $sq_ids) = @_;
    return {} unless $username && $sq_ids && ref $sq_ids eq 'ARRAY' && @$sq_ids;

    my $raw = _starStore()->getStarredIdsBatch($username, $sq_ids);
    return {} unless keys %$raw;

    require Plugins::SlimPing::Core::LibraryMapper;
    my %iso;
    $iso{$_} = Plugins::SlimPing::Core::LibraryMapper::_iso8601($raw->{$_})
        for keys %$raw;
    return \%iso;
}

# Batch fetch ratings for a list of sq_ids.
# Returns hashref of { sq_id => rating_int }.
sub getRatingBatch {
    my ($class, $username, $sq_ids) = @_;
    return {} unless $username && $sq_ids && ref $sq_ids eq 'ARRAY' && @$sq_ids;
    return _ratingStore()->getRatingBatch($username, $sq_ids);
}

sub modifyStars {
    my ($class, $user, $p, $add) = @_;
    return _starStore()->modifyStars($user, $p, $add);
}

sub setUserRating {
    my ($class, $user, $id, $rating) = @_;
    return _ratingStore()->setRating($user, $id, $rating);
}

1;
