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
# Core/VirtualPlayer/RemoteGovernor.pm - Remote-stream rate limiting and concurrency control
#
# Extracted from VirtualPlayer.pm.  Two complementary layers protect upstream
# services (Spotify, TIDAL, etc.) from unbounded concurrent load when clients
# pre-buffer or download multiple remote tracks simultaneously.
#
# Layer 1 -- Per-client rate limiting (sliding window).
# Keyed by "username:client_name".  Catches rapid-fire requests from a single
# client before they consume slots.
#
# Layer 2 -- Global concurrency cap.
# The backstop: total concurrent remote pipeline players regardless of which
# clients contribute.  Slots are released in PlayerCleanup.
#

package Plugins::SlimPing::Core::VirtualPlayer::RemoteGovernor;

use strict;
use warnings;

use Slim::Player::Client;
require Plugins::SlimPing::Core::Logging;

my $log   = Plugins::SlimPing::Core::Logging->getLogger();
my $prefs = Plugins::SlimPing::Core::Logging->getPrefs();

# Layer 1 -- Per-client rate limiting (sliding window).
# Keyed by "username:client_name".  Catches rapid-fire requests from a single
# client before they consume slots.
my %_remote_rate_state;               # "$user:$client" => [@timestamps]
my $_remote_rate_sweep_count = 0;

# Layer 2 -- Global concurrency cap.
# The backstop: total concurrent remote pipeline players regardless of which
# clients contribute.  Slots are released in PlayerCleanup.
my $_remote_in_flight       = 0;
my $_remote_dropped         = 0;      # total rejections (observability)
my %_remote_slots;                    # address => 1
my $_remote_last_drop_log   = 0;
use constant REMOTE_LOG_COOLDOWN => 30;

# Layer 1 -- Per-client sliding-window rate limiter.
# Returns 1 (pass) or 0 (rate limited).  Prunes stale state every 100th call.
sub _checkRemoteRateLimit {
    my ( $username, $client_name ) = @_;
    my $key = ( $username || '_anon' ) . ':' . ( $client_name || 'unknown' );

    my $limit  = $prefs->get('remote_stream_rate_limit') // 3;
    my $window = $prefs->get('remote_stream_rate_window') // 10;

    my $timestamps = $_remote_rate_state{$key} ||= [];
    my $cutoff     = time() - $window;

    # Expire entries older than the window
    shift @$timestamps while @$timestamps && $timestamps->[0] < $cutoff;

    if ( @$timestamps >= $limit ) {
        $log->warn(
            "SlimPing: remote stream rate limit reached for $key "
              . '('
              . scalar(@$timestamps)
              . " requests in ${window}s limit=$limit)"
        );
        return 0;
    }

    push @$timestamps, time();

    # Periodic sweep: every 100th call, prune stale keys from the hash
    if ( ++$_remote_rate_sweep_count % 100 == 0 ) {
        for my $k ( keys %_remote_rate_state ) {
            my $ts = $_remote_rate_state{$k};
            delete $_remote_rate_state{$k}
              unless $ts && @$ts && $ts->[-1] > $cutoff;
        }
    }

    return 1;
}

# Layer 2 -- Acquire a concurrency slot for a remote stream player address.
# Returns 1 (slot acquired) or 0 (cap reached).  Logging is rate-limited.
sub _acquireRemoteSlot {
    my ($address) = @_;
    my $cap = $prefs->get('remote_stream_cap') // 10;
    return 0 unless defined $address && length $address;

    if ( $_remote_in_flight >= $cap ) {
        $_remote_dropped++;
        my $now = time();
        if ( $now - $_remote_last_drop_log > REMOTE_LOG_COOLDOWN ) {
            $log->warn(
                "SlimPing: remote stream concurrency cap reached "
                  . "($_remote_in_flight/$cap in-flight, total_dropped=$_remote_dropped)"
            );
            $_remote_last_drop_log = $now;
        }
        return 0;
    }

    $_remote_in_flight++;
    $_remote_slots{$address} = 1;
    return 1;
}

# Release a concurrency slot previously acquired by _acquireRemoteSlot.
sub _releaseRemoteSlot {
    my ($address) = @_;
    return unless defined $address && length $address;
    return unless delete $_remote_slots{$address};
    $_remote_in_flight--;
}

# Safety net: cross-reference %_remote_slots against the live LMS player
# list and prune any entries whose player has been removed outside our
# close-handler (enrichment timer, LMS-internal cleanup).
sub _reconcileRemoteSlots {
    return unless %_remote_slots;
    my %alive = map { $_->id() => 1 } Slim::Player::Client::clients();
    for my $addr ( keys %_remote_slots ) {
        unless ( $alive{$addr} ) {
            delete $_remote_slots{$addr};
            $_remote_in_flight--;
        }
    }
}

# Observability accessors for external monitoring and AdminApi status endpoints.
sub remoteInFlight     { return $_remote_in_flight; }
sub remoteDroppedCount { return $_remote_dropped; }

1;
