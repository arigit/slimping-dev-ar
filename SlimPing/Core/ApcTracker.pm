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

#
# Core/ApcTracker.pm - Alternative Play Count pass tracking
#
# APC's external reportplayback API is stateless: every call is final -- at or
# above APC's played threshold it records a play, below it a skip.  Translating
# a client's reportPlayback/scrobble stream into those calls needs a small
# state machine per user+client, mirroring how APC itself tracks a real LMS
# player:
#
#   - Moving on to a different track ends the previous pass and reports it with
#     its furthest position -- a play or a skip, as APC decides.  This covers
#     skip-to-next and natural ends alike, whether or not the client sent
#     stopped first (APC's "newsong").
#   - A stop that has already cleared APC's played threshold is a completed play
#     whatever happens next, so a grace timer reports it once the window passes
#     (end of queue, client closing the app).
#   - A stop below the threshold is held, not sent.  APC decides a skip from the
#     percentage played, and it decides it when the client moves on rather than
#     at the moment it stops: the next report for a different track reports the
#     held pass as a skip, and a report for the same track is a resume that
#     reports nothing and simply continues the pass.  If nothing ever follows,
#     nothing is sent -- which is what APC's own player tracking does too, since
#     its stop handler clears its state without recording anything.
#   - A pause alone reports nothing; resuming and finishing gives one event.
#     A pause within APC_END_SLACK_SECS of the end is the end of the client's
#     queue and settles at once.
#   - Returning to the start of the same track (APC_RESTART_SECS) after
#     reaching the threshold completes that pass -- reported at once -- and
#     begins a new one.  Other jumps back just continue the pass.
#   - A pass that never got past position 0 was never listened to and is not
#     reported.
#   - A completed-play scrobble for the current track settles it once it
#     reached the threshold: clients may end a queue with no further
#     reportPlayback at all, only the scrobble.
#
# A repeated stopped, or a late stopped for a track already reported as
# skipped, is ignored so APC never sees the same play twice.
#
# Collaborators are injected so the tracker can be driven by the in-server
# runtime tests without a client, a database or real timers:
#   durationSecs     => sub { my ($sq_id) = @_; return $seconds_or_0 }
#   thresholdPercent => sub { return $apc_played_threshold_percent }
#   reportEnded      => sub { my ($username, $sq_id, $percent) = @_; }
#   armTimer         => sub { my ($delay_secs, $cb) = @_; }   # cb() calls fireTimer
#   now              => sub { return epoch_float }            # optional
#
# One entry per user+client, so state cannot grow without bound.
#

package Plugins::SlimPing::Core::ApcTracker;

use strict;
use warnings;

use Time::HiRes ();

use Plugins::SlimPing::Core::Logging;

my $log = Plugins::SlimPing::Core::Logging->getLogger();

# A stopped followed by a different track within this window was a skip (or a
# natural end moving to the next track); with nothing following, a plain stop.
use constant APC_STOP_GRACE_SECS => 10;

# A stopped for a track that was already reported within this window is the
# client's late arrival for a pass that is over; ignore it.
use constant APC_LATE_STOP_SECS => 30;

# A pause with no further report for this long is taken as abandoned playback
# (the client app was closed) and settled like a plain stop.
use constant APC_PAUSE_TIMEOUT_SECS => 900;

# Back within this many seconds of the start of the same track, after getting
# further than this beyond it, is a new pass: the client resetting its last
# track at the end of the queue, or the listener restarting it.
use constant APC_RESTART_SECS => 10;

# A pause this close to the track's end is the client stopping at the end of
# its queue, so it is a natural finish.
use constant APC_END_SLACK_SECS => 2;

sub new {
    my ( $class, %args ) = @_;

    for my $required (qw(durationSecs thresholdPercent reportEnded)) {
        die "ApcTracker: $required is required" unless $args{$required};
    }

    my $self = {
        duration_secs     => $args{durationSecs},
        threshold_percent => $args{thresholdPercent},
        report_ended      => $args{reportEnded},
        arm_timer         => $args{armTimer} || sub { },
        now               => $args{now}      || sub { Time::HiRes::time() },
        tracks            => {},
        skipped           => {},
        gen               => 0,
    };

    return bless $self, $class;
}

# Percent of a track played, clamped to 0-100, or undef when the duration is
# unknown.  Class method so it can be exercised on its own.
sub percentPlayed {
    my ( $class, $duration_secs, $position_secs ) = @_;

    return undef unless $duration_secs && $duration_secs > 0;

    my $percent = 100 * ( $position_secs || 0 ) / $duration_secs;
    $percent = 0   if $percent < 0;
    $percent = 100 if $percent > 100;

    return $percent;
}

# Has this client ever reported reportPlayback playback?  Used by the scrobble
# endpoint to decide whether a completed scrobble still needs to settle or
# report the current pass.
sub isTrackedClient {
    my ( $self, $username, $client ) = @_;
    return exists $self->{tracks}{ _key( $username, $client ) } ? 1 : 0;
}

# A reportPlayback event.  $position_secs may be undef when the client omitted
# positionMs; the last known position is used instead.
sub onReport {
    my ( $self, $username, $client, $sq_id, $state, $position_secs ) = @_;

    return 0 unless defined $sq_id && length $sq_id;
    $state ||= 'playing';

    my $key  = _key( $username, $client );
    my $now  = $self->{now}->();
    my $prev = $self->{tracks}{$key};

    $log->debug( sprintf 'SlimPing: APC track %s: %s %s pos=%s',
        $key, $state, $sq_id, defined $position_secs ? sprintf( '%.1fs', $position_secs ) : 'none' );

    if ( $state eq 'stopped' && ( !$prev || $prev->{sq_id} ne $sq_id ) ) {
        my $skipped = $self->{skipped}{$key};
        if ( $skipped && $skipped->{sq_id} eq $sq_id && $now - $skipped->{at} < APC_LATE_STOP_SECS ) {
            $log->debug("SlimPing: APC ignoring late stopped for already-reported $sq_id");
            return 0;
        }
    }

    if ( $prev && $prev->{sq_id} ne $sq_id ) {
        $self->_endOnNext( $key, $prev, $now );
        $prev = undef;
    }

    # Reports without positionMs fall back to the last known position.
    $position_secs //= $prev ? $prev->{position_secs} : 0;

    if ( $state eq 'stopped' ) {
        return 0 if $prev && ( $prev->{stopping} || $prev->{done} );

        my $track = $prev || $self->_newTrack( $username, $sq_id );
        $self->_setPosition( $track, $position_secs );
        $track->{stopping} = 1;
        $self->{tracks}{$key} = $track;

        # Only a pass that has already cleared APC's played threshold needs a
        # deadline: it is a completed play whatever happens next.  Below the
        # threshold the pass is held for a later report to classify, so no
        # timer is armed -- see _endOnNext and _settle.
        $self->_armTimer( $key, $track, APC_STOP_GRACE_SECS )
          if $self->_reachedThreshold($track);

        return 1;
    }

    # Any other report cancels a pending stop/pause timer.
    my $track = $prev;

    if ( $track && $track->{stopping} ) {

        # Same track reported again after a stop: that was a plain stop, and
        # this is a new pass through the track.
        $self->_settle($track);
        $track = undef;
    }
    elsif ( $track && $self->_isRestart( $track, $position_secs ) ) {
        if ( $track->{done} ) {
            $track = undef;
        }
        elsif ( $self->_reachedThreshold($track) ) {

            # Back at the start: a pass that reached the threshold is complete.
            $self->_settle($track);
            $track = undef;
        }
    }

    $track ||= $self->_newTrack( $username, $sq_id );

    $self->_setPosition( $track, $position_secs );
    $track->{gen} = ++$self->{gen};

    if ( $state eq 'paused' && !$track->{done} ) {
        my $duration = $self->_durationFor($track);
        if ( $duration > 0 && $position_secs >= $duration - APC_END_SLACK_SECS ) {

            # Paused at the very end: the client has finished its queue.
            $self->_settle($track);
        }
        else {
            $self->_armTimer( $key, $track, APC_PAUSE_TIMEOUT_SECS );
        }
    }

    $self->{tracks}{$key} = $track;
    return 1;
}

# The client scrobbled a completed play of the track it is still on.  Clients
# may end a queue with no further reportPlayback at all -- the last track just
# finishes and gets scrobbled -- so this is the only sign the pass is over.
# Settle it if it reached APC's threshold.  A scrobble for a track already
# moved on from or settled, or for a fresh pass still at the start, changes
# nothing.
sub onScrobbled {
    my ( $self, $username, $client, $sq_id ) = @_;

    my $key   = _key( $username, $client );
    my $track = $self->{tracks}{$key};

    return 0 unless $track && $track->{sq_id} eq $sq_id && !$track->{done};
    return 0 unless $self->_reachedThreshold($track);

    $track->{gen} = ++$self->{gen};
    $self->_settle($track);

    # Mid-queue, the client's stopped for this track can still arrive after it
    # already reported the next one -- ignore it like any late stopped for a
    # pass that is already over.
    $self->{skipped}{$key} = { sq_id => $sq_id, at => $self->{now}->() };
    return 1;
}

# Entry point for an injected timer.  Stale timers (a newer report or timer
# bumped the generation) do nothing.
sub fireTimer {
    my ( $self, $key, $gen ) = @_;

    my $track = $self->{tracks}{$key};
    return 0 unless $track && $track->{gen} == $gen;

    $self->_settle( $track, paused => !$track->{stopping} );
    return 1;
}

# Number of user+client passes currently tracked (diagnostics and tests).
sub activePassCount {
    my ($self) = @_;
    return scalar keys %{ $self->{tracks} };
}

# --- Internal helpers --------------------------------------------------------

sub _key {
    my ( $username, $client ) = @_;
    return ( $username // '' ) . ':' . ( $client // '' );
}

# The client moved on to a different track: report the previous pass with how
# far it got -- a play or a skip, as APC decides -- unless it was already
# reported or never started.
sub _endOnNext {
    my ( $self, $key, $track, $now ) = @_;

    return 0 if $track->{done};

    if ( $track->{max_pos} <= 0 ) {
        $log->debug("SlimPing: APC not reporting $track->{sq_id} -- never played past 0s");
        return 0;
    }

    my $percent = $self->_percentFor($track);
    if ( defined $percent ) {
        $self->_reportEnded( $track, $percent );
    }
    else {
        $log->debug("SlimPing: APC not reporting $track->{sq_id} -- track duration unknown");
    }

    $self->{skipped}{$key} = { sq_id => $track->{sq_id}, at => $now };
    return 1;
}

sub _newTrack {
    my ( $self, $username, $sq_id ) = @_;
    return {
        username      => $username,
        sq_id         => $sq_id,
        position_secs => 0,
        max_pos       => 0,
        stopping      => 0,
        done          => 0,
        gen           => 0,
    };
}

sub _setPosition {
    my ( $self, $track, $position_secs ) = @_;
    $track->{position_secs} = $position_secs;
    $track->{max_pos}       = $position_secs if $position_secs > $track->{max_pos};
    return;
}

sub _isRestart {
    my ( $self, $track, $position_secs ) = @_;
    return $position_secs <= APC_RESTART_SECS
      && $track->{max_pos} > $position_secs + APC_RESTART_SECS;
}

# One pending timer per pass: arming a new one (or any later report) bumps the
# generation, so an older timer finds itself stale and does nothing.
sub _armTimer {
    my ( $self, $key, $track, $secs ) = @_;
    $track->{gen} = ++$self->{gen};
    my $gen = $track->{gen};
    $self->{arm_timer}->( $secs, sub { $self->fireTimer( $key, $gen ) } );
    return;
}

# Settle a pass that ended without a next track following: a stop past the
# threshold, an abandoned pause, or a pause at the end of the queue.  Reported
# only when it reached APC's played threshold.
#
# Below the threshold the pass is deliberately left open.  A stop there is a
# pending skip rather than a settled pass: APC classifies it from the
# percentage played when the client moves on, so _endOnNext reports it then and
# a report for the same track is a resume that continues the pass.  Closing it
# here is what used to lose a mid-song stop entirely -- APC never saw it.
sub _settle {
    my ( $self, $track, %opts ) = @_;

    return 0 if $track->{done};
    $track->{stopping} = 0;

    my $percent   = $self->_percentFor($track);
    my $threshold = $self->{threshold_percent}->();

    if ( defined $percent && $percent >= $threshold ) {
        $track->{done} = 1;
        $self->_reportEnded( $track, $percent );
        return 1;
    }

    $log->debug(
        sprintf 'SlimPing: APC holding %s for the next report -- %s at %s, below APC threshold %d%%',
        $track->{sq_id},
        $opts{paused} ? 'paused' : 'stopped',
        defined $percent ? sprintf( '%d%%', $percent ) : 'unknown duration', $threshold
    );
    return 0;
}

sub _reachedThreshold {
    my ( $self, $track ) = @_;

    my $percent = $self->_percentFor($track);
    return 0 unless defined $percent;
    return $percent >= $self->{threshold_percent}->() ? 1 : 0;
}

sub _percentFor {
    my ( $self, $track ) = @_;
    return $self->percentPlayed( $self->_durationFor($track), $track->{max_pos} );
}

# Duration is looked up once per pass and cached: the tracked path calls this
# on every threshold check.
sub _durationFor {
    my ( $self, $track ) = @_;
    $track->{duration} = $self->{duration_secs}->( $track->{sq_id} ) || 0
      unless defined $track->{duration};
    return $track->{duration};
}

sub _reportEnded {
    my ( $self, $track, $percent ) = @_;

    $log->debug( sprintf 'SlimPing: APC ended %s at %.1fs (%d%%)', $track->{sq_id}, $track->{max_pos}, $percent + 0.5 );

    my $ok = eval { $self->{report_ended}->( $track->{username}, $track->{sq_id}, $percent ); 1 };
    unless ($ok) {
        my $error = $@ || 'unknown error';
        chomp $error;
        $log->warn("SlimPing: APC report dispatch failed for $track->{sq_id}: $error");
    }

    return;
}

1;
