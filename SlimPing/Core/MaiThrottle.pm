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
# Core/MaiThrottle.pm - Concurrency and rate gate for external MAI requests
#
# Three-layer protection for the Music & Artist Info plugin's upstream API
# calls (Wikipedia, Last.fm, LRCLib, Genius, etc.):
#
#   1. Concurrency cap (mai_external_cap, default 20) — limits simultaneous
#      in-flight external requests so MAI cannot saturate LMS's event loop.
#
#   2. Rate limit (mai_request_rate, default 10/min) — sliding-window cap on
#      total requests per minute, bounding sustained upstream traffic
#      regardless of how fast individual requests complete.  Set
#      conservatively because each MAI executeRequest fans out to 2+
#      upstream HTTP calls (e.g. Wikipedia search + page fetch per bio).
#
#   3. Deferred request queue (mai_queue_max, default 500) — when a
#      request is rejected by the rate-limit or concurrency cap, it is
#      pushed onto a FIFO queue instead of being silently dropped.  A
#      timer drains the queue at the rate-limit cadence, ensuring caches
#      eventually get populated even under heavy burst load.
#
# Local MAI lookups (embedded tags, disk cache, .lrc/.txt files) complete
# inline and are never throttled — only the executeRequest call is gated.
#
# Dropped requests (queue full) increment the dropped counter.
# Deferred requests (successfully queued) increment the deferred counter.
# Both are exposed in the settings UI for observability.
#

package Plugins::SlimPing::Core::MaiThrottle;

use strict;
use warnings;

use Slim::Control::Request;

use Plugins::SlimPing::Core::Logging;

my $log   = Plugins::SlimPing::Core::Logging->getLogger();
my $prefs = Plugins::SlimPing::Core::Logging->getPrefs();

my $_in_flight   = 0;
my $_dropped     = 0;
my $_deferred    = 0;
my @_timestamps  = ();             # sliding window for rate limit (epoch seconds)
my $_last_grant  = 0;              # epoch seconds of last slot grant (inter-request spacing)
my $_last_log    = 0;              # last time we logged a drop warning

# Deferred request queue — entries are { params, on_result, timeout_secs, cache_key }
my $_deferred_queue = [];
my $_queue_coalesce = {};         # cache_key => 1 for dedup
my $_drain_active   = 0;

use constant RATE_WINDOW => 60;   # seconds
use constant LOG_COOLDOWN => 30;   # seconds between drop log messages

# Try to acquire a concurrency + rate-limit slot.  Returns 1 on success, 0 when
# at either cap or when the inter-request spacing check fails.  Callers must call
# releaseSlot() when an async fetch completes.
#
# The inter-request spacing check (gap >= 60/rate_limit seconds) prevents burst
# flooding: even when the sliding window has room, only one request passes
# through per spacing interval.  This is critical because each MAI executeRequest
# fans out to 2+ upstream HTTP calls (e.g. Wikipedia search + page fetch per
# biography), and those calls fire concurrently inside MAI's async path.
sub acquireSlot {
    my ($class) = @_;

    my $cap = $prefs->get('mai_external_cap');
    $cap = 20 if $cap < 5 || $cap > 50;

    my $rate_max = $prefs->get('mai_request_rate');
    $rate_max = 10 if $rate_max < 1;

    # --- inter-request spacing (burst prevention) ---
    # Enforce a minimum gap between slot grants so Wikipedia sees a smooth
    # trickle, not a concurrent flood.  Without this, the first N requests
    # in an empty rate window all pass through at once and MAI's async
    # SimpleAsyncHTTP fires every upstream call concurrently.
    my $now = time();
    if ( $_last_grant > 0 ) {
        my $min_gap = 60.0 / $rate_max;
        my $elapsed = $now - $_last_grant;
        if ( $elapsed < $min_gap ) {
            return 0;
        }
    }

    # --- rate limit: sliding window ---
    my $cutoff = $now - RATE_WINDOW;
    @_timestamps = grep { $_ > $cutoff } @_timestamps;

    if ( @_timestamps >= $rate_max ) {
        return 0;
    }

    # --- concurrency cap ---
    if ( $_in_flight >= $cap ) {
        return 0;
    }

    $_in_flight++;
    $_last_grant = $now;
    push @_timestamps, $now;
    return 1;
}

# Release a concurrency slot.  Safe to call when in_flight is already 0 (no-op).
# Does NOT remove the rate-limit timestamp — the rate window governs total
# requests, not in-flight duration.
sub releaseSlot {
    my ($class) = @_;
    $_in_flight-- if $_in_flight > 0;
    return;
}

# --- Deferred request queue ---

# Push a request onto the deferred queue for later processing.  Deduplicates
# by optional cache_key so repeated requests for the same entity only occupy
# one queue slot.  Silently drops when the queue is at capacity.
#
# Returns 1 when enqueued, 0 when dropped (full queue or coalesced).
sub _enqueueDeferred {
    my ($class, $params, $on_result_coderef, $timeout_secs, $cache_key) = @_;

    my $max = $prefs->get('mai_queue_max') // 500;
    $max = 500 if $max < 10;

    # Coalesce: skip if a request with the same cache_key is already queued.
    if ( defined $cache_key && length $cache_key && $_queue_coalesce->{$cache_key} ) {
        $log->debug("MaiThrottle coalesced duplicate queue entry for $cache_key")
            if $log->is_debug;
        return 0;
    }

    if ( scalar(@$_deferred_queue) >= $max ) {
        $_dropped++;
        _maybeLogDrop('queue-full', scalar(@$_deferred_queue), $max);
        return 0;
    }

    my $entry = {
        params       => $params,
        on_result    => $on_result_coderef,
        timeout_secs => $timeout_secs // 30,
        cache_key    => $cache_key,
    };
    push @$_deferred_queue, $entry;

    if ( defined $cache_key && length $cache_key ) {
        $_queue_coalesce->{$cache_key} = 1;
    }

    $_deferred++;

    $log->info(
        sprintf(
            'SlimPing: MaiThrottle queued request (depth=%d, total deferred=%d)',
            scalar(@$_deferred_queue), $_deferred
        )
    ) if $log->is_info;

    $class->_startDrainTimer() unless $_drain_active;

    return 1;
}

# Start the drain timer if not already running.
sub _startDrainTimer {
    my ($class) = @_;
    return if $_drain_active;

    $_drain_active = 1;
    my $interval = $class->_drainInterval();
    Slim::Utils::Timers::setTimer(
        undef, time() + $interval,
        sub { $class->_drainOne() }
    );

    $log->info(
        sprintf(
            'SlimPing: MaiThrottle drain started (interval=%.1fs, queue depth=%d)',
            $interval, scalar(@$_deferred_queue)
        )
    ) if $log->is_info;
}

# Calculate the drain interval in seconds: one slot per rate-limit cadence.
# At mai_request_rate=10, this is 6.0 seconds between queue pops.
sub _drainInterval {
    my ($class) = @_;
    my $rate = $prefs->get('mai_request_rate') || 10;
    $rate = 10 if $rate < 1;
    return 60.0 / $rate;
}

# Pop one entry from the queue and process it through the throttle gate.
# Reschedules itself if more entries remain.
sub _drainOne {
    my ($class) = @_;

    if ( !@$_deferred_queue ) {
        $_drain_active = 0;
        $log->info('SlimPing: MaiThrottle drain stopped (queue empty)')
            if $log->is_info;
        return;
    }

    # Try to acquire a slot.  If none available, back off and retry later.
    unless ( $class->acquireSlot() ) {
        my $interval = $class->_drainInterval();
        Slim::Utils::Timers::setTimer(
            undef, time() + $interval,
            sub { $class->_drainOne() }
        );
        return;
    }

    my $entry = shift @$_deferred_queue;

    # Clear the coalesce marker so the cache_key can be queued again.
    if ( defined $entry->{cache_key} && length $entry->{cache_key} ) {
        delete $_queue_coalesce->{ $entry->{cache_key} };
    }

    # Process the request — same logic as asyncRequest body.
    my $request = Slim::Control::Request::executeRequest(undef, $entry->{params});

    if ( !$request->isStatusProcessing() ) {
        # Sync completion.
        if ( $entry->{on_result} ) {
            eval { $entry->{on_result}->($request) };
            $log->warn("MaiThrottle drain sync coderef error: $@") if $@;
        }
        $class->releaseSlot();
    } else {
        # Async — wire callback + safety timer.
        my $state = { slot_released => 0 };

        $request->callbackFunction(
            sub {
                unless ( $state->{slot_released}++ ) {
                    $class->releaseSlot();
                }
                if ( $entry->{on_result} ) {
                    eval { $entry->{on_result}->($request) };
                    $log->warn("MaiThrottle drain callback coderef error: $@") if $@;
                }
            }
        );

        Slim::Utils::Timers::setTimer(
            undef, time() + $entry->{timeout_secs},
            sub {
                unless ( $state->{slot_released}++ ) {
                    $class->releaseSlot();
                }
            }
        );
    }

    # Schedule next drain if more entries remain.
    if ( @$_deferred_queue ) {
        my $interval = $class->_drainInterval();
        Slim::Utils::Timers::setTimer(
            undef, time() + $interval,
            sub { $class->_drainOne() }
        );
    } else {
        $_drain_active = 0;
        $log->info('SlimPing: MaiThrottle drain stopped (queue empty)')
            if $log->is_info;
    }

    return;
}

# --- Async request helper ---

# Dispatch an executeRequest through the throttle with timer-gated slot release.
#
# $params            — MAI request arrayref, e.g. ['musicartistinfo', 'biography', "artist_id:$id"]
# $on_result_coderef — called with the raw $request on sync completion AND async callback.
#                       Pass undef when no result processing is needed.
# $timeout_secs      — safety-timer duration (slot released if MAI never calls back)
# $cache_key         — optional dedup key for the deferred queue (e.g. "bio:123", "lyrics:456")
#                       When absent, the request is still queued but not coalesced.
#
# Returns { sync => 1, request => $request } on synchronous completion (coderef already called).
# Returns { sync => 0 } on async dispatch (coderef will fire in callback).
# Returns undef when the throttle rejects AND the deferred queue is full.
sub asyncRequest {
    my ($class, $params, $on_result_coderef, $timeout_secs, $cache_key) = @_;
    $timeout_secs //= 30;

    unless ( $class->acquireSlot() ) {
        # Rate-limited or at concurrency cap — queue for later processing.
        $class->_enqueueDeferred($params, $on_result_coderef, $timeout_secs, $cache_key);
        return undef;
    }

    my $request = Slim::Control::Request::executeRequest(undef, $params);

    # Sync completion — MAI had the result inline (local file, disk cache, memory).
    if ( !$request->isStatusProcessing() ) {
        if ($on_result_coderef) {
            eval { $on_result_coderef->($request) };
            $log->warn("MaiThrottle asyncRequest sync coderef error: $@") if $@;
        }
        $class->releaseSlot();
        return { sync => 1, request => $request };
    }

    # Async — MAI needs to go online.  Wire callback + safety timer.
    my $state = { slot_released => 0 };

    $request->callbackFunction(
        sub {
            unless ( $state->{slot_released}++ ) {
                $class->releaseSlot();
            }
            if ($on_result_coderef) {
                eval { $on_result_coderef->($request) };
                $log->warn("MaiThrottle async callback coderef error: $@") if $@;
            }
        }
    );

    Slim::Utils::Timers::setTimer(
        undef, time() + $timeout_secs,
        sub {
            unless ( $state->{slot_released}++ ) {
                $class->releaseSlot();
            }
        }
    );

    return { sync => 0 };
}

# Read-only observability accessors for the settings UI.
sub inFlight      { return $_in_flight; }
sub droppedCount  { return $_dropped; }
sub deferredCount { return $_deferred; }
sub queueDepth    { return scalar(@$_deferred_queue); }

# Log drop events, at most once per LOG_COOLDOWN seconds to avoid log spam.
sub _maybeLogDrop {
    my ($reason, $current, $limit) = @_;
    my $now = time();
    return if $now - $_last_log < LOG_COOLDOWN;
    $_last_log = $now;
    $log->warn(
        sprintf(
            'SlimPing: MaiThrottle dropped request (%s: %d >= %d, total dropped=%d)',
            $reason, $current, $limit, $_dropped
        )
    );
    return;
}

1;
