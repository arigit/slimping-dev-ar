package Plugins::SlimPing::Core::BookmarkStore;

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

sub getUserBookmarks {
    my ($self, $username) = @_;

    my $schema = Plugins::SlimPing::Schema->connect();
    my $user   = Plugins::SlimPing::Core::UserStore->getInstance->getByUsername($username)
        or return {};

    my $bookmarks = {};
    my $rs = $schema->resultset('Bookmark')->search(
        { user_id => $user->id() },
        { order_by => 'changed_at DESC' }
    );
    while (my $row = $rs->next()) {
        $bookmarks->{ $row->sq_id() } = {
            id           => $row->sq_id(),
            position     => $row->position_ms(),
            comment      => $row->comment(),
            created      => $row->created_at(),
            changed      => $row->changed_at(),
        };
    }
    return $bookmarks;
}

sub createBookmark {
    my ($self, $username, $sq_id, $position_ms, $comment) = @_;

    my $schema = Plugins::SlimPing::Schema->connect();
    my $user   = Plugins::SlimPing::Core::UserStore->getInstance->getByUsername($username)
        or return;

    my $now  = time();
    my $rs   = $schema->resultset('Bookmark');
    my $cap  = $prefs->get('bookmark_user_cap');

    # Guard against undef position_ms -- treat as 0 rather than corrupting data.
    my $pos = defined $position_ms ? int($position_ms) : 0;

    # Count existing bookmarks for this user.
    my $count = $rs->count({ user_id => $user->id() });

    # If at cap, evict the oldest by changed_at (silent LRU).
    if ($count >= $cap) {
        my $oldest = $rs->search(
            { user_id => $user->id() },
            { order_by => 'changed_at ASC', rows => 1 }
        )->single();
        if ($oldest) {
            $oldest->delete();
        }
    }

    # Global cap as circuit-breaker.
    my $global_cap = $prefs->get('bookmark_global_cap');
    if ($rs->count({}) >= $global_cap) {
        $log->warn("SlimPing: bookmark global cap ($global_cap) reached");
        return;
    }

    # Upsert on (user_id, sq_id) atomically -- delete then insert wrapped in a
    # transaction so a crash between the two operations cannot lose the bookmark.
    $schema->txn_do(sub {
        $rs->search({ user_id => $user->id(), sq_id => $sq_id })->delete();

        $rs->create({
            user_id      => $user->id(),
            sq_id        => $sq_id,
            position_ms  => $pos,
            comment      => $comment // '',
            created_at   => $now,
            changed_at   => $now,
        });
    });
    return;
}

sub deleteBookmark {
    my ($self, $username, $sq_id) = @_;

    my $schema = Plugins::SlimPing::Schema->connect();
    my $user   = Plugins::SlimPing::Core::UserStore->getInstance->getByUsername($username)
        or return;

    $schema->resultset('Bookmark')->search({
        user_id => $user->id(),
        sq_id   => $sq_id,
    })->delete();
    return;
}

sub flushAll {
    my $self = shift;
    return Plugins::SlimPing::Utils::StoreHelpers->flushAll('Bookmark');
}

sub flushForUser {
    my ($self, $username) = @_;
    return Plugins::SlimPing::Utils::StoreHelpers->flushForUser($username, 'Bookmark');
}

1;
