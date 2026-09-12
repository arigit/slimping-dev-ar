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

# Core/DebugThrottle.pm - Debug message throttling utilities
#
# Reduces log spam by suppressing repeated debug messages within time windows.
# Uses three separate internal hashes to prevent key-prefix collisions between
# throttling strategies.

package Plugins::SlimPing::Core::DebugThrottle;

use strict;
use warnings;

use Plugins::SlimPing::Core::Logging;

my $log   = Plugins::SlimPing::Core::Logging->getLogger();
my $prefs = Plugins::SlimPing::Core::Logging->getPrefs();

my $_default_window = 60;

# Per-method state hashes (separate to eliminate prefix-collision risk).
my %_throttled;
my %_rate_limited;
my %_once;

# Throttled debug logging -- suppresses repeated identical messages within a
# time window.  After the window expires, logs a summary of how many times
# the message was suppressed.
sub debugThrottled {
    my ( $class, $key, $message, $window ) = @_;
    return unless $log->is_debug;

    $window //= $_default_window;
    my $now = time();

    my $state = $_throttled{$key} //=
      { count => 0, last_time => 0, logged_summary => 0 };

    if ( $now - $state->{last_time} > $window ) {
        if ( $state->{count} > 1 && !$state->{logged_summary} ) {
            my $suppressed = $state->{count} - 1;
            $log->debug(
"[$key] (suppressed $suppressed similar messages in last ${window}s)"
            );
        }

        $state->{count}          = 1;
        $state->{last_time}      = $now;
        $state->{logged_summary} = 0;
        $log->debug($message);
    }
    else {
        $state->{count}++;
    }
}

# Rate-limited debug logging -- logs at most once per window.
sub debugRateLimited {
    my ( $class, $key, $message, $window ) = @_;
    return unless $log->is_debug;

    $window //= $_default_window;
    my $now = time();

    my $last_time = $_rate_limited{$key} // 0;

    if ( $now - $last_time >= $window ) {
        $_rate_limited{$key} = $now;
        $log->debug($message);
    }
}

# Log once per key -- logs a message only once per session.
sub debugOnce {
    my ( $class, $key, $message ) = @_;
    return unless $log->is_debug;
    return if $_once{$key};
    $_once{$key} = 1;
    $log->debug($message);
}

# Clear throttle state, optionally for a specific key.
sub clearState {
    my ( $class, $key ) = @_;

    if ( defined $key ) {
        delete $_throttled{$key};
        delete $_rate_limited{$key};
        delete $_once{$key};
    }
    else {
        %_throttled    = ();
        %_rate_limited = ();
        %_once         = ();
    }
}

# Get throttle statistics for diagnostics.
sub stats {
    my ($class) = @_;
    my %stats;
    for my $key ( keys %_throttled ) {
        $stats{$key} = $_throttled{$key}->{count};
    }
    return \%stats;
}

1;
