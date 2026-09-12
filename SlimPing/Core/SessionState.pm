package Plugins::SlimPing::Core::SessionState;

use strict;
use warnings;

use Plugins::SlimPing::Core::Logging;

my $log = Plugins::SlimPing::Core::Logging->getLogger();
my $_instance;

sub getInstance {
    my $class = shift;
    $_instance //= bless {}, $class;
    return $_instance;
}

sub _store {
    require Plugins::SlimPing::Core::SessionStore;
    return Plugins::SlimPing::Core::SessionStore->getInstance();
}

sub getState {
    my ($self, $username, $client_name) = @_;
    return _store()->getState($username, $client_name);
}

sub saveQueue {
    my $self        = shift;
    my %args        = @_;
    my $username    = $args{username}    or die 'saveQueue: username required';
    my $client_name = $args{client_name} // '';
    my $track_ids   = $args{track_ids}   or die 'saveQueue: track_ids required';
    my $current     = $args{current};
    my $position    = $args{position};
    return _store()->saveQueue(
        username    => $username,
        client_name => $client_name,
        track_ids   => $track_ids,
        current     => $current,
        position    => $position,
    );
}

sub setNowPlaying {
    my ($self, $username, $track_id, $position_secs, $client_name) = @_;
    return _store()->setNowPlaying($username, $track_id, $position_secs, $client_name);
}

sub clearNowPlaying {
    my ($self, $username, $client_name) = @_;
    return _store()->clearNowPlaying($username, $client_name);
}

sub getQueue {
    my ($self, $username, $client_name) = @_;
    return _store()->getQueue($username, $client_name);
}

sub getActiveSessions {
    my $self = shift;
    return _store()->getActiveSessions();
}

# In-memory cache of playback timeline state keyed by "username:client_name".
# Populated by reportPlayback, read by getNowPlaying.  Ephemeral — does not
# survive plugin reload.  Avoids a DB migration for transient position data.
my %_timeline;

sub updatePlaybackState {
    my $self        = shift;
    my %args        = @_;
    my $username      = $args{username}      or die 'updatePlaybackState: username required';
    my $client_name   = $args{client_name}   or die 'updatePlaybackState: client_name required';
    my $state         = $args{state}         || 'playing';
    my $position_ms   = $args{position_ms}   // 0;
    my $playback_rate = $args{playback_rate} // 1.0;
    my $key = ($username // '') . ':' . ($client_name // '');
    $_timeline{$key} = {
        state         => $state         || 'playing',
        position_ms   => $position_ms   // 0,
        playback_rate => $playback_rate // 1.0,
    };
}

sub getPlaybackState {
    my ($self, $username, $client_name) = @_;
    my $key = ($username // '') . ':' . ($client_name // '');
    return $_timeline{$key};
}

1;
