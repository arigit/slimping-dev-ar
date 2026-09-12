package Plugins::SlimPing::Core::SessionStore;

use strict;
use warnings;

use JSON::XS ();
use Plugins::SlimPing::Core::Logging;
use Plugins::SlimPing::Schema;
require Plugins::SlimPing::Core::UserStore;
require Plugins::SlimPing::Utils::StoreHelpers;

my $log   = Plugins::SlimPing::Core::Logging->getLogger();
my $prefs = Plugins::SlimPing::Core::Logging->getPrefs();

my $_instance;
my $json = JSON::XS->new->utf8;

sub getInstance {
    my $class = shift;
    $_instance //= bless {}, $class;
    return $_instance;
}

# --- State accessors (keyed by username + client_name) -----------------------

sub getState {
    my ($self, $username, $client_name) = @_;
    $client_name //= '';

    my $schema = Plugins::SlimPing::Schema->connect();
    my $user   = Plugins::SlimPing::Core::UserStore->getInstance->getByUsername($username)
        or return _defaultState();

    my $row = $schema->resultset('Session')->find({
        user_id     => $user->id(),
        client_name => $client_name,
    });

    if ($row) {
        return {
            play_queue  => $json->decode($row->play_queue() || '[]'),
            queue_index => $row->queue_index() // 0,
            now_playing => $row->now_playing_track() ? {
                track_id      => $row->now_playing_track(),
                position_secs => $row->position_secs() // 0,
                started_at    => $row->started_at(),
            } : undef,
            client_name => $row->client_name(),
            last_seen   => $row->last_seen_at(),
        };
    }
    return _defaultState();
}

sub _defaultState {
    return {
        play_queue  => [],
        queue_index => 0,
        now_playing => undef,
        client_name => '',
        last_seen   => 0,
    };
}

sub saveQueue {
    my $self        = shift;
    my %args        = @_;
    my $username    = $args{username}    or die 'saveQueue: username required';
    my $client_name = $args{client_name} // '';
    my $track_ids   = $args{track_ids}   or die 'saveQueue: track_ids required';
    my $current     = $args{current};
    my $position    = $args{position};

    my $schema = Plugins::SlimPing::Schema->connect();
    my $user   = Plugins::SlimPing::Core::UserStore->getInstance->getByUsername($username)
        or return;

    my $row = $schema->resultset('Session')->find_or_new({
        user_id     => $user->id(),
        client_name => $client_name,
    });

    my $data = {
        play_queue  => $json->encode($track_ids // []),
        queue_index => $current // 0,
        last_seen_at => time(),
    };
    if (defined $position) {
        $data->{position_secs} = $position;
    }
    $row->set_columns($data);
    $row->update_or_insert();
    return;
}

sub setNowPlaying {
    my ($self, $username, $track_id, $position_secs, $client_name) = @_;
    $client_name //= '';

    my $schema = Plugins::SlimPing::Schema->connect();
    my $user   = Plugins::SlimPing::Core::UserStore->getInstance->getByUsername($username)
        or return;

    my $now  = time();
    my $row  = $schema->resultset('Session')->find_or_new({
        user_id     => $user->id(),
        client_name => $client_name,
    });

    $row->set_columns({
        now_playing_track => $track_id,
        position_secs     => $position_secs // 0,
        started_at        => $now,
        last_seen_at      => $now,
    });
    $row->update_or_insert();
    return;
}

sub clearNowPlaying {
    my ($self, $username, $client_name) = @_;
    $client_name //= '';

    my $schema = Plugins::SlimPing::Schema->connect();
    my $user   = Plugins::SlimPing::Core::UserStore->getInstance->getByUsername($username)
        or return;

    my $row = $schema->resultset('Session')->find({
        user_id     => $user->id(),
        client_name => $client_name,
    });
    if ($row) {
        $row->update({
            now_playing_track => undef,
            position_secs     => undef,
            started_at        => undef,
        });
    }
    return;
}

sub getQueue {
    my ($self, $username, $client_name) = @_;
    $client_name //= '';

    my $state = $self->getState($username, $client_name);
    my $np    = $state->{now_playing} || {};
    return {
        entry     => $state->{play_queue},
        current   => $state->{queue_index},
        position  => $np->{position_secs} // 0,
        username  => $username,
        changed   => $np->{started_at},
        changedBy => $state->{client_name},
    };
}

sub getActiveSessions {
    my $self = shift;
    my $schema = Plugins::SlimPing::Schema->connect();

    my $rs = $schema->resultset('Session')->search(
        { 'now_playing_track' => { '!=' => undef } },
        { order_by => 'last_seen_at DESC' }
    );

    my @active;
    while (my $s = $rs->next()) {
        my $user = $s->user();
        push @active, {
            username     => $user->username(),
            client_name  => $s->client_name() || '',
            track_id     => $s->now_playing_track(),
            position     => $s->position_secs() // 0,
            started_at   => $s->started_at(),
            last_seen    => $s->last_seen_at(),
        };
    }
    return \@active;
}

# Return all sessions for a user as an arrayref of hashrefs, ordered by
# last_seen_at descending.  Includes both active (now_playing_track IS NOT NULL)
# and idle clients -- unlike getActiveSessions which filters globally to
# active-only.  Used by the LMS Clients menu to show per-client status.
sub getSessionsForUser {
    my ($self, $username) = @_;

    my $schema = Plugins::SlimPing::Schema->connect();
    my $user   = Plugins::SlimPing::Core::UserStore->getInstance->getByUsername($username)
        or return [];

    my $rs = $schema->resultset('Session')->search(
        { user_id => $user->id() },
        {
            columns  => [qw(client_name now_playing_track position_secs
                             started_at last_seen_at)],
            order_by => { -desc => 'last_seen_at' },
        }
    );

    my @sessions;
    while (my $s = $rs->next()) {
        push @sessions, {
            client_name       => $s->client_name(),
            now_playing_track => $s->now_playing_track(),
            position_secs     => $s->position_secs() // 0,
            started_at        => $s->started_at(),
            last_seen_at      => $s->last_seen_at(),
        };
    }
    return \@sessions;
}

# --- TTL cleanup ------------------------------------------------------------

sub cleanupExpiredSessions {
    my $self   = shift;
    my $ttl    = $prefs->get('session_ttl_days') // 90;
    my $cutoff = time() - ($ttl * 86400);

    my $rs    = Plugins::SlimPing::Schema->connect()->resultset('Session');
    my $count = $rs->search({ last_seen_at => { '<' => $cutoff } })->count();
    if ($count > 0) {
        $rs->search({ last_seen_at => { '<' => $cutoff } })->delete();
        $log->info("SlimPing: cleaned up $count expired sessions (TTL: $ttl days)");
    }
    return $count;
}

# --- Admin flush ------------------------------------------------------------

sub flushAll {
    my $self = shift;
    return Plugins::SlimPing::Utils::StoreHelpers->flushAll('Session');
}

sub flushForUser {
    my ($self, $username) = @_;
    return Plugins::SlimPing::Utils::StoreHelpers->flushForUser($username, 'Session');
}

1;
