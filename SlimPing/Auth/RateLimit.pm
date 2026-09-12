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
# Auth/RateLimit.pm - In-memory brute-force defence for /rest/ auth
#
# Tracks per-(ip, username) and per-ip auth failures.  After N failures
# within window W, the key enters cooldown for C seconds during which all
# auth attempts are rejected regardless of credential validity.
#
# Counters are in-memory only -- lost on plugin restart.  An attacker who can
# trigger the LMS process to restart can bypass cooldowns, but that already
# implies host-level access at which point the rate limiter is irrelevant.
#
# Default thresholds (public IPs only):
#   per-(ip, user): N = 10 failures, W = 5 min, C = 15 min
#   per-ip:         N = 50 failures, W = 5 min, C = 15 min
#
# The per-IP bucket has a much higher threshold than the per-user bucket so
# that NAT'd households or phones running multiple Subsonic apps don't get
# locked out by one user's typos.  When `lan_mode` is on (S9, separate change
# set) thresholds soften further.
#
# **Private-LAN sources are exempt entirely.**  The threat model for this
# limiter is internet credential brute force; loopback, RFC1918, link-local,
# IPv6 ULA, and Tailscale CGNAT clients are trusted-network devices doing
# normal client setup (which can include several "is the server up?" probes
# during onboarding).  Rate-limiting them is the wrong tradeoff.
#
# Memory hygiene: when a key is checked or recorded, expired sibling entries
# in the same bucket are pruned.  A full sweep also runs every 1000 events.
#

package Plugins::SlimPing::Auth::RateLimit;

use strict;
use warnings;

use Time::HiRes qw(time);

use Plugins::SlimPing::Core::Logging;
require Plugins::SlimPing::Core::IPTrust;

my $log   = Plugins::SlimPing::Core::Logging->getLogger();
my $prefs = Plugins::SlimPing::Core::Logging->getPrefs();

# Buckets:
#   $_per_user{ "$ip\t$username" } = { count, first, cooldown_until }
#   $_per_ip  { $ip                } = { count, first, cooldown_until }
my %_per_user;
my %_per_ip;
my $_event_counter = 0;

# Returns the (per_user_threshold, per_ip_threshold, window_secs,
# cooldown_secs) defaults for the active mode.  Per-IP threshold is much
# larger than per-user so NAT'd / multi-app sources aren't locked out by
# one user's typos.
sub _thresholds {
    # lan_mode defaults to ON (undef = treat as on) so upgrades don't tighten
    # rate limits behind operators' backs.  Operators opt INTO the strict
    # public-IP-posture thresholds by explicitly saving lan_mode=0.
    my $raw = $prefs->get('lan_mode');
    my $lan = defined $raw ? ( $raw ? 1 : 0 ) : 1;
    return $lan
      ? ( 30, 200, 5 * 60, 5 * 60 )      # lan_mode (default): very forgiving
      : ( 10, 50,  5 * 60, 15 * 60 );    # strict: public-internet posture
}

# Returns 1 if the (ip, username) pair (or the ip alone) is currently in
# cooldown.  Private-LAN sources always return 0 -- they are not rate-limited.
sub isLocked {
    my ( $class, $ip, $username ) = @_;
    return 0 unless defined $ip && length $ip;
    return 0 if Plugins::SlimPing::Core::IPTrust->isPrivateIp($ip);

    my $now = time();

    if ( my $rec = $_per_ip{$ip} ) {
        return 1 if $rec->{cooldown_until} && $rec->{cooldown_until} > $now;
    }
    if ( defined $username && length $username ) {
        my $key = "$ip\t$username";
        if ( my $rec = $_per_user{$key} ) {
            return 1 if $rec->{cooldown_until} && $rec->{cooldown_until} > $now;
        }
    }
    return 0;
}

# Record an auth failure.  Returns 1 if the resulting state is now locked.
# Private-LAN sources are never recorded (not rate-limited).
sub recordFailure {
    my ( $class, $ip, $username ) = @_;
    return 0 unless defined $ip && length $ip;
    return 0 if Plugins::SlimPing::Core::IPTrust->isPrivateIp($ip);

    my $now = time();
    my ( $user_threshold, $ip_threshold, $window, $cooldown ) = _thresholds();

    my $triggered = 0;

    $triggered ||=
      _bumpBucket( \%_per_ip, $ip, $now, $ip_threshold, $window, $cooldown,
        'per-ip' );

    if ( defined $username && length $username ) {
        my $key = "$ip\t$username";
        $triggered ||=
          _bumpBucket( \%_per_user, $key, $now, $user_threshold, $window,
            $cooldown, "per-user($username)" );
    }

    if ($triggered) {
        $log->warn(
            sprintf(
'SlimPing rate-limit: cooldown triggered for ip=%s user=%s (per-user N=%d, per-ip N=%d, window=%ds, cooldown=%ds)',
                $ip, $username // '-',
                $user_threshold, $ip_threshold, $window, $cooldown
            )
        );
    }

    _maybeSweep( $now, $window, $cooldown );
    return $triggered;
}

sub _bumpBucket {
    my ( $bucket, $key, $now, $threshold, $window, $cooldown, $tag ) = @_;
    my $rec = $bucket->{$key} ||= { count => 0, first => $now };

    # Reset window if the first recorded failure is older than W.
    if ( $now - $rec->{first} > $window ) {
        $rec->{count} = 0;
        $rec->{first} = $now;
        delete $rec->{cooldown_until};
    }
    $rec->{count}++;

    if ( $rec->{count} >= $threshold && !$rec->{cooldown_until} ) {
        $rec->{cooldown_until} = $now + $cooldown;
        $rec->{tag} = $tag;
        return 1;
    }
    return 0;
}

# Successful auth clears the (ip, username) and ip entries for this peer.
# This means a successful login resets the brute-force progress for that
# pair; an attacker who guesses correctly mid-burst gets a clean slate, but
# the slate they get is already "they have valid creds", so the rate limiter
# has done its job.
sub clearSuccess {
    my ( $class, $ip, $username ) = @_;
    return unless defined $ip && length $ip;
    delete $_per_ip{$ip};
    if ( defined $username && length $username ) {
        delete $_per_user{"$ip\t$username"};
    }
    return;
}

# Periodic sweep -- runs roughly every 1000 events to prune entries whose
# cooldown has elapsed and whose window has expired.  Keeps memory bounded
# under sustained attack from a large set of source IPs.
sub _maybeSweep {
    my ( $now, $window, $cooldown ) = @_;
    $_event_counter++;
    return unless $_event_counter % 1000 == 0;

    for my $bucket ( \%_per_ip, \%_per_user ) {
        for my $key ( keys %$bucket ) {
            my $rec = $bucket->{$key};
            my $stale =
                ( !$rec->{cooldown_until} || $rec->{cooldown_until} < $now )
              && ( $now - $rec->{first} > $window );
            delete $bucket->{$key} if $stale;
        }
    }
    return;
}

# Drop all in-memory rate-limit state.  Exposed as a settings UI action so
# operators can recover from a self-induced lockout (e.g. testing) without
# restarting LMS.  Returns the number of buckets cleared, for logging.
sub clearAll {
    my ($class) = @_;
    my $n = scalar( keys %_per_user ) + scalar( keys %_per_ip );
    %_per_user      = ();
    %_per_ip        = ();
    $_event_counter = 0;
    return $n;
}

# Backwards-compat alias used by older test code.
sub _reset { __PACKAGE__->clearAll(); return; }

1;
