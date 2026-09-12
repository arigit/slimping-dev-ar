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

# Core/IPTrust.pm - Shared IP address classification utilities
#
# Stateless class methods for source-IP trust evaluation used by both
# AdminGate (admin UI access control) and RateLimit (per-IP throttling).
# The same rules must apply in both places to avoid inconsistent behaviour
# where an IP that is exempt from rate limiting could still be blocked.

package Plugins::SlimPing::Core::IPTrust;

use strict;
use warnings;

# True if $ip is a loopback address (127.0.0.0/8 or ::1).
sub isLoopback {
    my ( $class, $ip ) = @_;
    return 0 unless defined $ip && length $ip;
    return 1 if $ip =~ /^127\./;
    return 1 if $ip eq '::1' || $ip eq '0:0:0:0:0:0:0:1';
    return 0;
}

# True if $ip is "private" -- loopback, RFC1918, link-local, CGNAT
# (100.64/10, covers Tailscale by default), IPv6 ULA, or IPv6 link-local.
sub isPrivateIp {
    my ( $class, $ip ) = @_;
    return 0 unless defined $ip && length $ip;

    return 1 if isLoopback( $class, $ip );

    # IPv4 ranges
    if ( $ip =~ /^(\d{1,3})\.(\d{1,3})\.\d{1,3}\.\d{1,3}$/ ) {
        my ( $a, $b ) = ( $1, $2 );
        return 1 if $a == 10;
        return 1 if $a == 172 && $b >= 16 && $b <= 31;
        return 1 if $a == 192 && $b == 168;
        return 1 if $a == 169 && $b == 254;                # link-local
        return 1 if $a == 100 && $b >= 64 && $b <= 127;    # CGNAT/Tailscale
        return 0;
    }

    # IPv6: link-local fe80::/10, ULA fc00::/7 (covers fd00::/8).
    return 1 if $ip =~ /^fe[89ab][0-9a-f]:/i;
    return 1 if $ip =~ /^f[cd][0-9a-f]{2}:/i;

    return 0;
}

1;
