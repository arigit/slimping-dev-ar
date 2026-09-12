package Plugins::SlimPing::Core::StarStore;

use strict;
use warnings;

use Plugins::SlimPing::Core::Logging;
use Plugins::SlimPing::Schema;
require Plugins::SlimPing::Core::UserStore;
require Plugins::SlimPing::Utils::StoreHelpers;

my $log   = Plugins::SlimPing::Core::Logging->getLogger();
my $prefs = Plugins::SlimPing::Core::Logging->getPrefs();

my $_instance;

sub getInstance {
    my $class = shift;
    $_instance //= bless {}, $class;
    return $_instance;
}

# Return 1 if the item is starred by user, undef otherwise.
sub isStarred {
    my ($self, $username, $sq_id) = @_;
    return undef unless $sq_id && $username;

    my $schema = Plugins::SlimPing::Schema->connect();
    my $user   = Plugins::SlimPing::Core::UserStore->getInstance->getByUsername($username)
        or return undef;

    my $star = $schema->resultset('Star')->find({
        user_id => $user->id(),
        sq_id   => $sq_id,
    });
    return $star ? 1 : undef;
}

# Return epoch timestamp the item was starred, or undef.
sub getStarredAt {
    my ($self, $username, $sq_id) = @_;
    return undef unless $sq_id && $username;

    my $schema = Plugins::SlimPing::Schema->connect();
    my $user   = Plugins::SlimPing::Core::UserStore->getInstance->getByUsername($username)
        or return undef;

    my $star = $schema->resultset('Star')->find({
        user_id => $user->id(),
        sq_id   => $sq_id,
    });
    return undef unless $star && $star->starred_at() > 0;

    require Plugins::SlimPing::Core::LibraryMapper;
    return Plugins::SlimPing::Core::LibraryMapper::_iso8601($star->starred_at());
}

# Return full star hashref for a user (tracks, albums, artists buckets).
# Used by Lists::_starredData and Menu::InfoMenu.
sub getStars {
    my ($self, $username) = @_;
    my $schema = Plugins::SlimPing::Schema->connect();
    my $user   = Plugins::SlimPing::Core::UserStore->getInstance->getByUsername($username)
        or return {};

    my $stars = { tracks => {}, albums => {}, artists => {} };
    my $rs = $schema->resultset('Star')->search(
        { user_id => $user->id() },
        { order_by => 'sq_id' }
    );
    while (my $row = $rs->next()) {
        my $type = $row->item_type() . 's';
        $stars->{$type}{ $row->sq_id() } = $row->starred_at();
    }
    return $stars;
}

# Add or remove stars.  $p is the parsed param hashref (may contain id,
# albumId, artistId).  $add is 1 for star, 0 for unstar.
sub modifyStars {
    my ($self, $username, $p, $add) = @_;

    my $schema = Plugins::SlimPing::Schema->connect();
    my $user   = Plugins::SlimPing::Core::UserStore->getInstance->getByUsername($username)
        or return;

    my %type_map = (
        id       => 'track',
        albumId  => 'album',
        artistId => 'artist',
    );

    my $now     = time();
    my $rs      = $schema->resultset('Star');
    my $cap     = $prefs->get('star_user_cap');
    my $global  = $prefs->get('star_global_cap');

    for my $param (keys %type_map) {
        my $type = $type_map{$param};
        my @ids = ref $p->{$param} eq 'ARRAY' ? @{ $p->{$param} }
                : defined $p->{$param}         ? ( $p->{$param} )
                : ();

        for my $id (@ids) {
            if ($add) {
                # Check caps before inserting
                my $count = $rs->count({ user_id => $user->id() });
                if ($count >= $cap) {
                    $log->warn("SlimPing: star user cap ($cap) reached for $username");
                    next;
                }
                my $global_count = $rs->count({});
                if ($global_count >= $global) {
                    $log->warn("SlimPing: star global cap ($global) reached");
                    next;
                }
                eval {
                    $rs->create({
                        user_id    => $user->id(),
                        sq_id      => $id,
                        item_type  => $type,
                        starred_at => $now,
                    });
                };
                if ($@) {
                    # Only ignore duplicate key violations; re-throw everything else.
                    die $@ unless $@ =~ /UNIQUE constraint failed/;
                }
            } else {
                $rs->search({ user_id => $user->id(), sq_id => $id })->delete();
            }
        }
    }
    return;
}

# Return a list of sq_ids for a user of a given type.
sub getStarredIds {
    my ($self, $username, $type) = @_;

    my $schema = Plugins::SlimPing::Schema->connect();
    my $user   = Plugins::SlimPing::Core::UserStore->getInstance->getByUsername($username)
        or return [];

    my $rs = $schema->resultset('Star')->search(
        { user_id => $user->id(), item_type => $type },
        { columns => ['sq_id'] }
    );
    return [ map { $_->sq_id() } $rs->all() ];
}

# Admin flush -- delete all stars, return count.
sub flushAll {
    my $self = shift;
    return Plugins::SlimPing::Utils::StoreHelpers->flushAll('Star');
}

# Return a hashref of sq_id => starred_at for a batch of items.
# Used to avoid N+1 per-item lookups during track/album/artist shaping.
sub getStarredIdsBatch {
    my ($self, $username, $sq_ids) = @_;
    return {} unless $username && $sq_ids && ref $sq_ids eq 'ARRAY' && @$sq_ids;

    my $schema = Plugins::SlimPing::Schema->connect();
    my $user   = Plugins::SlimPing::Core::UserStore->getInstance->getByUsername($username)
        or return {};

    my $rs = $schema->resultset('Star')->search(
        { user_id => $user->id(), sq_id => { -in => $sq_ids } },
        { columns => [qw(sq_id starred_at)] }
    );
    my %result;
    while (my $row = $rs->next()) {
        $result{ $row->sq_id() } = $row->starred_at();
    }
    return \%result;
}

# Admin flush for a single user.
sub flushForUser {
    my ($self, $username) = @_;
    return Plugins::SlimPing::Utils::StoreHelpers->flushForUser($username, 'Star');
}

1;
