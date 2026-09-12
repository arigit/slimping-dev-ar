package Plugins::SlimPing::Core::RatingStore;

use strict;
use warnings;

use Plugins::SlimPing::Core::Logging;
use Plugins::SlimPing::Schema;
require Plugins::SlimPing::Core::UserStore;
require Plugins::SlimPing::Utils::StoreHelpers;

my $log = Plugins::SlimPing::Core::Logging->getLogger();

my $_instance;

sub getInstance {
    my $class = shift;
    $_instance //= bless {}, $class;
    return $_instance;
}

sub getRating {
    my ($self, $username, $sq_id) = @_;
    return undef unless $sq_id && $username;

    my $schema = Plugins::SlimPing::Schema->connect();
    my $user   = Plugins::SlimPing::Core::UserStore->getInstance->getByUsername($username)
        or return undef;

    my $rating = $schema->resultset('Rating')->find({
        user_id => $user->id(),
        sq_id   => $sq_id,
    });
    return $rating ? $rating->rating() : undef;
}

sub setRating {
    my ($self, $username, $sq_id, $rating) = @_;

    my $schema = Plugins::SlimPing::Schema->connect();
    my $user   = Plugins::SlimPing::Core::UserStore->getInstance->getByUsername($username)
        or return;

    if ($rating == 0) {
        $schema->resultset('Rating')->search({
            user_id => $user->id(),
            sq_id   => $sq_id,
        })->delete();
    } else {
        my $row = $schema->resultset('Rating')->find_or_new({
            user_id => $user->id(),
            sq_id   => $sq_id,
        });
        $row->rating($rating);
        $row->rated_at(time());
        $row->update_or_insert();
    }
    return;
}

# Return a hashref of sq_id => rating for a batch of items.
sub getRatingBatch {
    my ($self, $username, $sq_ids) = @_;
    return {} unless $username && $sq_ids && ref $sq_ids eq 'ARRAY' && @$sq_ids;

    my $schema = Plugins::SlimPing::Schema->connect();
    my $user   = Plugins::SlimPing::Core::UserStore->getInstance->getByUsername($username)
        or return {};

    my $rs = $schema->resultset('Rating')->search(
        { user_id => $user->id(), sq_id => { -in => $sq_ids } },
        { columns => [qw(sq_id rating)] }
    );
    my %result;
    while (my $row = $rs->next()) {
        $result{ $row->sq_id() } = $row->rating();
    }
    return \%result;
}

# Return all rated tracks for a user as an arrayref of {sq_id, rating} hashes,
# sorted by rating descending.  The Rating table has no item_type column, so
# track-only filtering uses sq_id prefix matching (sq_tr_%).  Title-alpha
# tie-breaking is done by the caller after resolving track names.
sub getRatedTracks {
    my ($self, $username) = @_;

    my $schema = Plugins::SlimPing::Schema->connect();
    my $user   = Plugins::SlimPing::Core::UserStore->getInstance->getByUsername($username)
        or return [];

    my $rs = $schema->resultset('Rating')->search(
        {
            user_id => $user->id(),
            sq_id   => { -like => 'sq_tr\_%' },
        },
        {
            columns  => [qw(sq_id rating)],
            order_by => { -desc => 'rating' },
        }
    );
    return [ map { { sq_id => $_->sq_id(), rating => $_->rating() } } $rs->all() ];
}

sub flushAll {
    my $self = shift;
    return Plugins::SlimPing::Utils::StoreHelpers->flushAll('Rating');
}

sub flushForUser {
    my ($self, $username) = @_;
    return Plugins::SlimPing::Utils::StoreHelpers->flushForUser($username, 'Rating');
}

# Return the average rating for a single sq_id across all users, or undef.
sub getAverageRating {
    my ($self, $sq_id) = @_;
    return undef unless $sq_id;

    my $rs = Plugins::SlimPing::Schema->connect()->resultset('Rating')->search(
        { sq_id => $sq_id },
        { select => [ { AVG => 'rating' } ], as => ['avg_rating'] }
    );
    my $row = $rs->first;
    return undef unless $row;
    my $avg = $row->get_column('avg_rating');
    return defined $avg ? $avg + 0 : undef;
}

# Batch variant of getAverageRating.  Accepts an arrayref of sq_ids and returns
# a hashref mapping sq_id => average rating (or undef).  Single GROUP BY query
# avoids N+1 calls when shaping large result sets.
sub getAverageRatingBatch {
    my ($self, $sq_ids) = @_;
    return {} unless $sq_ids && @$sq_ids;

    my $rs = Plugins::SlimPing::Schema->connect()->resultset('Rating')->search(
        { sq_id => { -in => $sq_ids } },
        {
            select   => [ 'sq_id', { AVG => 'rating' } ],
            as       => [ 'sq_id', 'avg_rating' ],
            group_by => 'sq_id',
        }
    );

    my %avgs;
    while ( my $row = $rs->next() ) {
        my $sq_id = $row->get_column('sq_id');
        my $avg   = $row->get_column('avg_rating');
        $avgs{$sq_id} = defined $avg ? $avg + 0 : undef;
    }
    return \%avgs;
}

1;
