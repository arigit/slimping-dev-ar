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
# Tests/PlaybackSubmissionTest.pm - one APC report per play
#
# Regression cover for the wiring between Handlers::Playback::_recordPlayback
# and PlaybackReporter::report.
#
# APC's external reportplayback API is stateless: every call at or above its
# threshold records a play.  Clients that use the playbackReport extension hand
# the APC pass tracker a whole pass to report (Core/ApcTracker), so the
# completed-play path must not report the same play again.  The handler knows
# this and passes skip_apc down; if that flag is dropped on the way, a single
# play reaches APC twice -- which is exactly what a tester saw, with Symfonium
# sending both reportPlayback and a completion scrobble.  The OpenSubsonic spec
# does not forbid a client using both endpoints, so the server has to be
# idempotent on its own.
#
# The handler is driven with the container, the APC dispatcher and the LMS stats
# writer faked out, so nothing here touches a session, a database, or another
# plugin.
#

package Plugins::SlimPing::Tests::PlaybackSubmissionTest;

use strict;
use warnings;

sub runChecks {
    my ($class) = @_;

    require Plugins::SlimPing::Handlers::Playback;
    require Plugins::SlimPing::Core::Container;
    require Plugins::SlimPing::Core::AlternatePlayCount;
    require Plugins::SlimPing::Core::PlaybackReporter;

    my @dispatches;
    my @stats;

    my $session = bless {}, 'Plugins::SlimPing::Tests::PlaybackSubmissionTest::Session';
    my $auth    = bless {}, 'Plugins::SlimPing::Tests::PlaybackSubmissionTest::Auth';

    # Fake the container rather than re-registering services: registering would
    # warn and would replace the live services for the duration of the run.
    my $real_get = \&Plugins::SlimPing::Core::Container::get;
    my %fake = (
        session_state  => $session,
        auth_manager   => $auth,
        library_mapper => undef,
    );

    local *Plugins::SlimPing::Core::Container::get = sub {
        my ( $class, $name ) = @_;
        return $fake{$name} if exists $fake{$name};
        return $real_get->( $class, $name );
    };

    local *Plugins::SlimPing::Core::AlternatePlayCount::apcAvailable = sub { return 1 };
    local *Plugins::SlimPing::Core::AlternatePlayCount::submit       = sub {
        my ( $class, $sq_id, $percent ) = @_;
        push @dispatches, { sq_id => $sq_id, percent => $percent };
        return 1;
    };

    local *Plugins::SlimPing::Core::PlaybackReporter::_updateLmsStats = sub {
        push @stats, $_[0];
        return 1;
    };

    local *Plugins::SlimPing::Core::Scrobbler::submit = sub { return 1 };

    my @checks;

    my $check = sub {
        my ( $label, $expected, $code ) = @_;

        @dispatches = ();
        @stats      = ();

        my $survived = eval { $code->(); 1 };
        unless ($survived) {
            my $error = $@ || 'unknown error';
            chomp $error;
            push @checks, { label => $label, ok => 0, detail => "died: $error" };
            return;
        }

        my $apc   = scalar @dispatches;
        my $stats = scalar @stats;
        my @problems;

        push @problems, "expected $expected->{apc} APC dispatches, got $apc"
          if $apc != $expected->{apc};
        push @problems, "expected $expected->{stats} LMS stats updates, got $stats"
          if $stats != $expected->{stats};

        if ( defined $expected->{percent} && $apc ) {
            my $percent = $dispatches[0]{percent};
            $percent = -1 unless defined $percent;
            push @problems, "expected a $expected->{percent}% dispatch, got $percent%"
              if $percent != $expected->{percent};
        }

        # AlternatePlayCount::submit applies the 100% default, so a caller with
        # no percentage of its own must leave it undefined rather than guess.
        if ( $expected->{no_percent} && $apc && defined $dispatches[0]{percent} ) {
            push @problems, 'expected the percent to be left to APC, got ' . $dispatches[0]{percent} . '%';
        }

        push @checks, {
            label  => $label,
            ok     => @problems ? 0 : 1,
            detail => @problems ? join( '; ', @problems ) : $expected->{detail},
        };
    };

    my $record = sub {
        my (%args) = @_;
        return Plugins::SlimPing::Handlers::Playback::_recordPlayback(
            $args{user},
            $args{id},
            $args{position},
            $args{client},
            $args{submission},
            %{ $args{opts} || {} },
        );
    };

    $check->(
        'a play the pass tracker already reported is not sent to APC again',
        { apc => 0, stats => 1, detail => 'the tracker owns APC reporting for a tracked client' },
        sub {
            $record->(
                user       => 'subtest',
                id         => 'sq_tr_9001',
                position   => 200,
                client     => 'TestClient',
                submission => 1,
                opts       => { skip_apc => 1 },
            );
        },
    );

    $check->(
        'a play from a client that never reports playback still reaches APC once',
        {
            apc        => 1,
            stats      => 1,
            no_percent => 1,
            detail     => 'no percentage of our own, so APC applies its 100% default',
        },
        sub {
            $record->(
                user       => 'subtest',
                id         => 'sq_tr_9002',
                position   => 200,
                client     => 'OtherClient',
                submission => 1,
            );
        },
    );

    $check->(
        'a stopped report below the scrobble threshold records nothing',
        { apc => 0, stats => 0, detail => 'nothing recorded, nothing dispatched' },
        sub {
            $record->(
                user       => 'subtest',
                id         => 'sq_tr_9003',
                position   => 20,
                client     => 'TestClient',
                submission => 0,
                opts       => { stopped => 1, skip_apc => 1 },
            );
        },
    );

    $check->(
        'two completion signals for one play cause no extra APC dispatch',
        { apc => 0, stats => 1, detail => 'the reportPlayback and scrobble halves are deduped' },
        sub {
            my %args = (
                user       => 'subtest',
                id         => 'sq_tr_9004',
                position   => 200,
                client     => 'TestClient',
                submission => 1,
                opts       => { skip_apc => 1 },
            );

            $record->(%args);    # the reportPlayback stop
            $record->(%args);    # the completion scrobble
        },
    );

    return \@checks;
}

package Plugins::SlimPing::Tests::PlaybackSubmissionTest::Session;

sub updatePlaybackState { return }
sub clearNowPlaying     { return }
sub setNowPlaying       { return }

package Plugins::SlimPing::Tests::PlaybackSubmissionTest::Auth;

sub isPlaybackLoggingEnabled  { return 1 }
sub isPlaybackReportAccepted  { return 1 }

1;
