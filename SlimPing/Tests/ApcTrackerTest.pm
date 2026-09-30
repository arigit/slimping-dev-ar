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
# Tests/ApcTrackerTest.pm - runtime coverage for the APC pass tracker
#
# ApcTracker is a timer-driven state machine, so it cannot be exercised outside
# a running LMS -- and inside one it is very hard to drive deterministically
# from a real client. These tests build it with fake collaborators (fixed
# clock, captured timers, in-memory report sink) and step it through the
# event orderings a client produces.
#
# Each scenario returns ( passed, detail ); detail is only read on failure.
# The scenarios are named after the invariant they protect, so a failure in the
# log names the broken behaviour rather than an assertion number.
#

package Plugins::SlimPing::Tests::ApcTrackerTest;

use strict;
use warnings;

sub runChecks {
    my ($class) = @_;

    require Plugins::SlimPing::Core::ApcTracker;

    my @scenarios = (
        [ 'plain stop reports at the furthest position',       \&_plainStopAtFurthestPosition ],
        [ 'plain stop below the threshold reports nothing',    \&_plainStopBelowThreshold ],
        [ 'resumed pass after a below-threshold stop reports', \&_resumedPassReportsOnCompletion ],
        [ 'scrobble settles the current pass once',            \&_scrobbleSettlesOnce ],
        [ 'late stopped after a scrobble is ignored',          \&_lateStopAfterScrobble ],
        [ 'scrobble below the threshold settles nothing',      \&_scrobbleBelowThreshold ],
        [ 'moving on reports the previous pass',               \&_endOnNextReports ],
        [ 'a pass that never left zero is not reported',       \&_neverPlayedNotReported ],
        [ 'repeated stopped does not report twice',            \&_repeatStopReportedOnce ],
        [ 'pause mid-track waits for the pass to finish',      \&_pauseMidTrack ],
        [ 'pause at the end of the track settles at once',     \&_pauseAtEndSettles ],
        [ 'restarting from the start begins a new pass',       \&_restartBeginsNewPass ],
        [ 'unknown duration is never reported',                \&_unknownDurationNotReported ],
        [ 'mid-song stop is reported when the next track starts', \&_midSongStopReportedOnNextTrack ],
        [ 'mid-song stop with nothing following reports nothing', \&_midSongStopWithNothingFollowing ],
        [ 'resuming the same track clears the held mid-song stop', \&_midSongStopResumeClears ],
        [ 'resuming then moving on reports the pass once',     \&_midSongStopResumeThenNextTrack ],
        [ 'a late stopped after the skipped track is ignored',  \&_midSongStopLateStop ],
        [ 'passes are tracked per user and client',            \&_trackedPerUserAndClient ],
        [ 'tracked passes do not accumulate',                  \&_passesDoNotAccumulate ],
        [ 'percent played clamps to 0-100',                    \&_percentPlayedClamps ],
    );

    my @checks;
    for my $scenario (@scenarios) {
        my ( $label,  $code )   = @$scenario;
        my ( $passed, $detail ) = eval { $code->() };
        if ($@) {
            my $error = $@;
            chomp $error;
            push @checks, { label => $label, ok => 0, detail => "died: $error" };
            next;
        }
        push @checks,
          {
            label  => $label,
            ok     => $passed         ? 1       : 0,
            detail => defined $detail ? $detail : 'scenario returned no result',
          };
    }

    return \@checks;
}

# --- Scenarios ---------------------------------------------------------------

sub _plainStopAtFurthestPosition {
    my $h = _harness( duration => 300, threshold => 20 );
    $h->{tracker}->onReport( 'u', 'c', 'sq_tr_1', 'playing', 30 );
    $h->{tracker}->onReport( 'u', 'c', 'sq_tr_1', 'playing', 200 );
    $h->{tracker}->onReport( 'u', 'c', 'sq_tr_1', 'stopped', 120 );
    _fireLatest($h);

    return _expect( @{ $h->{reports} } == 1, 'expected exactly 1 report, got ' . @{ $h->{reports} } )
      unless @{ $h->{reports} } == 1;
    return _expect( $h->{reports}[0][1] eq 'sq_tr_1', 'reported the wrong track' )
      unless $h->{reports}[0][1] eq 'sq_tr_1';
    return _expect( _approx( $h->{reports}[0][2], 200 / 3 ), 'expected about 66.7%, got ' . $h->{reports}[0][2] );
}

sub _plainStopBelowThreshold {
    my $h = _harness( duration => 300, threshold => 20 );
    $h->{tracker}->onReport( 'u', 'c', 'sq_tr_1', 'playing', 30 );
    $h->{tracker}->onReport( 'u', 'c', 'sq_tr_1', 'stopped', 30 );
    _fireLatest($h);

    return _expect( @{ $h->{reports} } == 0, 'a 10% stop must not be reported' );
}

sub _resumedPassReportsOnCompletion {
    my $h = _harness( duration => 300, threshold => 20 );
    $h->{tracker}->onReport( 'u', 'c', 'sq_tr_1', 'playing', 30 );
    $h->{tracker}->onReport( 'u', 'c', 'sq_tr_1', 'stopped', 30 );
    _fireLatest($h);

    return _expect( @{ $h->{reports} } == 0, 'the below-threshold stop should not report' )
      unless @{ $h->{reports} } == 0;

    # Resume outside the stop grace window and play the track to the end. The
    # pass must re-open, otherwise the completion is never reported to APC.
    $h->{clock} += 20;
    $h->{tracker}->onReport( 'u', 'c', 'sq_tr_1', 'playing', 35 );
    $h->{tracker}->onReport( 'u', 'c', 'sq_tr_1', 'stopped', 300 );
    _fireLatest($h);

    return _expect( @{ $h->{reports} } == 1, 'the resumed pass must be reported once, got ' . @{ $h->{reports} } )
      unless @{ $h->{reports} } == 1;
    return _expect( _approx( $h->{reports}[0][2], 100 ), 'expected 100%, got ' . $h->{reports}[0][2] );
}

sub _midSongStopReportedOnNextTrack {
    my $h = _harness( duration => 300, threshold => 20 );
    $h->{tracker}->onReport( 'u', 'c', 'sq_tr_1', 'playing', 30 );
    $h->{tracker}->onReport( 'u', 'c', 'sq_tr_1', 'stopped', 30 );

    # The client stays stopped past the grace window before playing anything
    # else.  This is the sequence that used to lose the skip: the stop timer
    # closed the pass, so the next track had nothing left to report.
    $h->{clock} += 10;
    _fireLatest($h);

    return _expect( @{ $h->{reports} } == 0, 'a held mid-song stop must not report on its own' )
      unless @{ $h->{reports} } == 0;

    # Whenever the client plays something else -- minutes or days later -- the
    # held stop becomes a skip.  No timer is involved.
    $h->{clock} += 600;
    $h->{tracker}->onReport( 'u', 'c', 'sq_tr_2', 'playing', 0 );

    return _expect( @{ $h->{reports} } == 1, 'the held stop must be reported once, got ' . @{ $h->{reports} } )
      unless @{ $h->{reports} } == 1;
    return _expect( $h->{reports}[0][1] eq 'sq_tr_1', 'reported the wrong track' )
      unless $h->{reports}[0][1] eq 'sq_tr_1';
    return _expect( _approx( $h->{reports}[0][2], 10 ), 'expected 10% (a skip), got ' . $h->{reports}[0][2] );
}

sub _midSongStopWithNothingFollowing {
    my $h = _harness( duration => 300, threshold => 20 );
    $h->{tracker}->onReport( 'u', 'c', 'sq_tr_1', 'playing', 45 );
    $h->{tracker}->onReport( 'u', 'c', 'sq_tr_1', 'stopped', 45 );
    _fireLatest($h);

    # Nothing follows, so there is no evidence the listener skipped rather than
    # simply stopped; APC's own tracking records nothing in that case either.
    return _expect( @{ $h->{reports} } == 0, 'expected no report, got ' . @{ $h->{reports} } );
}

sub _midSongStopResumeClears {
    my $h = _harness( duration => 300, threshold => 20 );
    $h->{tracker}->onReport( 'u', 'c', 'sq_tr_1', 'playing', 30 );
    $h->{tracker}->onReport( 'u', 'c', 'sq_tr_1', 'stopped', 30 );

    $h->{clock} += 300;
    $h->{tracker}->onReport( 'u', 'c', 'sq_tr_1', 'playing', 35 );

    return _expect( @{ $h->{reports} } == 0, 'resuming the same track must clear the held stop' )
      unless @{ $h->{reports} } == 0;

    $h->{tracker}->onReport( 'u', 'c', 'sq_tr_1', 'stopped', 300 );
    _fireLatest($h);

    return _expect( @{ $h->{reports} } == 1, 'the completed pass reports once, got ' . @{ $h->{reports} } )
      unless @{ $h->{reports} } == 1;
    return _expect( _approx( $h->{reports}[0][2], 100 ), 'expected 100%, got ' . $h->{reports}[0][2] );
}

sub _midSongStopResumeThenNextTrack {
    my $h = _harness( duration => 300, threshold => 20 );
    $h->{tracker}->onReport( 'u', 'c', 'sq_tr_1', 'playing', 30 );
    $h->{tracker}->onReport( 'u', 'c', 'sq_tr_1', 'stopped', 30 );
    $h->{tracker}->onReport( 'u', 'c', 'sq_tr_1', 'playing', 45 );
    $h->{tracker}->onReport( 'u', 'c', 'sq_tr_2', 'playing', 0 );

    return _expect( @{ $h->{reports} } == 1, 'expected exactly 1 report, got ' . @{ $h->{reports} } )
      unless @{ $h->{reports} } == 1;
    return _expect( $h->{reports}[0][1] eq 'sq_tr_1', 'reported the wrong track' )
      unless $h->{reports}[0][1] eq 'sq_tr_1';
    return _expect( _approx( $h->{reports}[0][2], 15 ),
        'expected 15% (the resumed furthest position), got ' . $h->{reports}[0][2] );
}

sub _midSongStopLateStop {
    my $h = _harness( duration => 300, threshold => 20 );
    $h->{tracker}->onReport( 'u', 'c', 'sq_tr_1', 'playing', 30 );
    $h->{tracker}->onReport( 'u', 'c', 'sq_tr_1', 'stopped', 30 );
    $h->{tracker}->onReport( 'u', 'c', 'sq_tr_2', 'playing', 0 );

    # The client's stopped for the skipped track can still arrive afterwards.
    $h->{tracker}->onReport( 'u', 'c', 'sq_tr_1', 'stopped', 30 );
    _fireLatest($h);

    return _expect( @{ $h->{reports} } == 1,
        'the skip must not be reported twice, got ' . @{ $h->{reports} } );
}

sub _scrobbleSettlesOnce {
    my $h = _harness( duration => 300, threshold => 20 );
    $h->{tracker}->onReport( 'u', 'c', 'sq_tr_1', 'playing', 100 );
    my $settled = $h->{tracker}->onScrobbled( 'u', 'c', 'sq_tr_1' );

    return _expect( $settled,                'onScrobbled should settle a pass past the threshold' ) unless $settled;
    return _expect( @{ $h->{reports} } == 1, 'expected exactly 1 report, got ' . @{ $h->{reports} } )
      unless @{ $h->{reports} } == 1;
    return _expect( _approx( $h->{reports}[0][2], 100 / 3 ), 'expected about 33.3%, got ' . $h->{reports}[0][2] );
}

sub _lateStopAfterScrobble {
    my $h = _harness( duration => 300, threshold => 20 );
    $h->{tracker}->onReport( 'u', 'c', 'sq_tr_1', 'playing', 100 );
    $h->{tracker}->onScrobbled( 'u', 'c', 'sq_tr_1' );
    $h->{tracker}->onReport( 'u', 'c', 'sq_tr_1', 'stopped', 300 );
    _fireLatest($h);

    return _expect( @{ $h->{reports} } == 1,
        'a late stopped must not produce a second report, got ' . @{ $h->{reports} } );
}

sub _scrobbleBelowThreshold {
    my $h = _harness( duration => 300, threshold => 20 );
    $h->{tracker}->onReport( 'u', 'c', 'sq_tr_1', 'playing', 30 );
    my $settled = $h->{tracker}->onScrobbled( 'u', 'c', 'sq_tr_1' );

    return _expect( !$settled,               'a 10% scrobble must not settle the pass' ) if $settled;
    return _expect( @{ $h->{reports} } == 0, 'a 10% scrobble must not report' )
      unless @{ $h->{reports} } == 0;
    return _expect( $h->{tracker}->isTrackedClient( 'u', 'c' ), 'the client should stay tracked' );
}

sub _endOnNextReports {
    my $h = _harness( duration => 300, threshold => 20 );
    $h->{tracker}->onReport( 'u', 'c', 'sq_tr_1', 'playing', 40 );
    $h->{tracker}->onReport( 'u', 'c', 'sq_tr_2', 'playing', 10 );

    return _expect( @{ $h->{reports} } == 1,
        'expected the previous pass to be reported once, got ' . @{ $h->{reports} } )
      unless @{ $h->{reports} } == 1;
    return _expect( $h->{reports}[0][1] eq 'sq_tr_1', 'reported the wrong track' )
      unless $h->{reports}[0][1] eq 'sq_tr_1';
    return _expect( _approx( $h->{reports}[0][2], 40 / 3 ), 'expected about 13.3%, got ' . $h->{reports}[0][2] );
}

sub _neverPlayedNotReported {
    my $h = _harness( duration => 300, threshold => 20 );
    $h->{tracker}->onReport( 'u', 'c', 'sq_tr_1', 'playing', 0 );
    $h->{tracker}->onReport( 'u', 'c', 'sq_tr_2', 'playing', 5 );

    return _expect( @{ $h->{reports} } == 0, 'a pass at position 0 must not be reported' );
}

sub _repeatStopReportedOnce {
    my $h = _harness( duration => 300, threshold => 20 );
    $h->{tracker}->onReport( 'u', 'c', 'sq_tr_1', 'playing', 100 );
    $h->{tracker}->onReport( 'u', 'c', 'sq_tr_1', 'stopped', 100 );
    _fireLatest($h);
    $h->{tracker}->onReport( 'u', 'c', 'sq_tr_1', 'stopped', 100 );
    _fireLatest($h);

    return _expect( @{ $h->{reports} } == 1, 'a repeated stopped must not report twice, got ' . @{ $h->{reports} } );
}

sub _pauseMidTrack {
    my $h = _harness( duration => 300, threshold => 20 );
    $h->{tracker}->onReport( 'u', 'c', 'sq_tr_1', 'playing', 45 );
    $h->{tracker}->onReport( 'u', 'c', 'sq_tr_1', 'paused',  45 );

    return _expect( @{ $h->{reports} } == 0, 'a pause alone must not report' )
      unless @{ $h->{reports} } == 0;

    _fireLatest($h);    # abandoned-pause timer: below the threshold, stays open
    return _expect( @{ $h->{reports} } == 0, 'an abandoned pause below the threshold must not report' )
      unless @{ $h->{reports} } == 0;

    $h->{tracker}->onReport( 'u', 'c', 'sq_tr_1', 'playing', 60 );
    $h->{tracker}->onReport( 'u', 'c', 'sq_tr_1', 'stopped', 300 );
    _fireLatest($h);

    return _expect( @{ $h->{reports} } == 1, 'the finished pass must be reported once, got ' . @{ $h->{reports} } )
      unless @{ $h->{reports} } == 1;
    return _expect( _approx( $h->{reports}[0][2], 100 ), 'expected 100%, got ' . $h->{reports}[0][2] );
}

sub _pauseAtEndSettles {
    my $h = _harness( duration => 300, threshold => 20 );
    $h->{tracker}->onReport( 'u', 'c', 'sq_tr_1', 'playing', 100 );
    $h->{tracker}->onReport( 'u', 'c', 'sq_tr_1', 'paused',  299 );

    return _expect( @{ $h->{reports} } == 1,
        'a pause within the end slack must settle at once, got ' . @{ $h->{reports} } );
}

sub _restartBeginsNewPass {
    my $h = _harness( duration => 300, threshold => 20 );
    $h->{tracker}->onReport( 'u', 'c', 'sq_tr_1', 'playing', 100 );
    $h->{tracker}->onReport( 'u', 'c', 'sq_tr_1', 'playing', 0 );     # restart from the start
    $h->{tracker}->onReport( 'u', 'c', 'sq_tr_1', 'stopped', 300 );
    _fireLatest($h);

    return _expect( @{ $h->{reports} } == 2, 'a restarted pass must report twice in total, got ' . @{ $h->{reports} } )
      unless @{ $h->{reports} } == 2;

    # The first report is the abandoned pass, the second the restarted one.
    my @percents = map { $_->[2] } @{ $h->{reports} };
    return _expect( _approx( $percents[0], 100 / 3 ) && _approx( $percents[1], 100 ),
        'unexpected percents: ' . join( ', ', @percents ) );
}

sub _unknownDurationNotReported {
    my $h = _harness( duration => 0, threshold => 20 );
    $h->{tracker}->onReport( 'u', 'c', 'sq_tr_1', 'playing', 60 );
    $h->{tracker}->onReport( 'u', 'c', 'sq_tr_1', 'stopped', 300 );
    _fireLatest($h);

    return _expect( @{ $h->{reports} } == 0, 'an unknown duration must never be reported' );
}

sub _trackedPerUserAndClient {
    my $h = _harness( duration => 300, threshold => 20 );
    $h->{tracker}->onReport( 'user_a', 'client_1', 'sq_tr_1', 'playing', 60 );

    return _expect( $h->{tracker}->isTrackedClient( 'user_a', 'client_1' ), 'the reporting client should be tracked' )
      unless $h->{tracker}->isTrackedClient( 'user_a', 'client_1' );
    return _expect( !$h->{tracker}->isTrackedClient( 'user_b', 'client_1' ), 'another user must not be tracked' )
      if $h->{tracker}->isTrackedClient( 'user_b', 'client_1' );
    return _expect( !$h->{tracker}->isTrackedClient( 'user_a', 'client_2' ), 'another client must not be tracked' )
      if $h->{tracker}->isTrackedClient( 'user_a', 'client_2' );
    return ( 1, '' );
}

sub _passesDoNotAccumulate {
    my $h = _harness( duration => 300, threshold => 20 );
    $h->{tracker}->onReport( 'u', 'c', 'sq_tr_1', 'playing', 100 );
    $h->{tracker}->onReport( 'u', 'c', 'sq_tr_2', 'playing', 100 );
    $h->{tracker}->onReport( 'u', 'c', 'sq_tr_2', 'stopped', 300 );
    _fireLatest($h);

    return _expect( $h->{tracker}->activePassCount() == 1,
        'expected 1 tracked pass, got ' . $h->{tracker}->activePassCount() );
}

sub _percentPlayedClamps {
    my $tracker_class = 'Plugins::SlimPing::Core::ApcTracker';

    my $over = $tracker_class->percentPlayed( 300, 450 );
    return _expect( defined $over && _approx( $over, 100 ), 'past the end should clamp to 100' )
      unless defined $over && _approx( $over, 100 );

    my $under = $tracker_class->percentPlayed( 300, -5 );
    return _expect( defined $under && _approx( $under, 0 ), 'before the start should clamp to 0' )
      unless defined $under && _approx( $under, 0 );

    my $unknown = $tracker_class->percentPlayed( 0, 10 );
    return _expect( !defined $unknown, 'an unknown duration should return undef' ) if defined $unknown;

    return ( 1, '' );
}

# --- Test harness ------------------------------------------------------------

# Build an ApcTracker with fake collaborators: a fixed clock, captured timers
# and an in-memory report sink.
sub _harness {
    my (%args) = @_;

    my $h = {
        reports   => [],
        timers    => [],
        clock     => 1000,
        duration  => $args{duration}  // 300,
        threshold => $args{threshold} // 20,
    };

    $h->{tracker} = Plugins::SlimPing::Core::ApcTracker->new(
        durationSecs     => sub { $h->{duration} },
        thresholdPercent => sub { $h->{threshold} },
        reportEnded      => sub { push @{ $h->{reports} },                        [@_] },
        armTimer         => sub { my ( $secs, $cb ) = @_; push @{ $h->{timers} }, { secs => $secs, cb => $cb }; },
        now              => sub { $h->{clock} },
    );

    return $h;
}

# Fire the most recently armed timer.  Older timers are stale by generation and
# would do nothing, so this is the timer that actually runs next in production.
sub _fireLatest {
    my ($h) = @_;
    my $timer = $h->{timers}[-1] or return 0;
    $timer->{cb}->();
    return 1;
}

sub _approx {
    my ( $got, $want, $tolerance ) = @_;
    $tolerance //= 0.01;
    return abs( $got - $want ) <= $tolerance;
}

sub _expect {
    my ( $condition, $detail ) = @_;
    return $condition ? ( 1, '' ) : ( 0, $detail );
}

1;
