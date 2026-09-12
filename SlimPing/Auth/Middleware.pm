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
# Auth/Middleware.pm - Authentication middleware for SlimPing
#
# Called by the Router before every handler.  Validates one of three auth
# schemes and returns ($user_hashref, undef) on success, or
# (undef, $error_hashref) on failure.  The error hashref is a valid Subsonic
# error payload that goes straight to ResponseFormatter -- no die() calls here.
#
# Auth priority order:
#   1. API key       -- k=<key> (OpenSubsonic extension; preferred for external use)
#   2. Token+salt    -- u=<user> + t=MD5(pass+salt) + s=<salt>  (Subsonic standard)
#   3. Plain password -- u=<user> + p=<password> (or p=enc:<hex>)  (legacy clients)
#
# Both unknown users and disabled users return error code 40 to avoid leaking
# information about which usernames exist (no user enumeration).
# A missing or invalid API key returns code 41 per the OpenSubsonic spec.
# A valid API key belonging to a disabled account returns code 40 (not 41),
# so that an attacker cannot distinguish "bad key" from "disabled account".
#
# Error hashrefs are pre-built as package-level templates but are always
# returned as shallow copies to prevent caller mutation corrupting future
# responses.
#

package Plugins::SlimPing::Auth::Middleware;

use strict;
use warnings;

use Plugins::SlimPing::Core::Logging;
use Plugins::SlimPing::Auth::RateLimit;
require Plugins::SlimPing::Core::Container;
require Plugins::SlimPing::Core::DebugThrottle;
use Time::HiRes qw(time);

my $log   = Plugins::SlimPing::Core::Logging->getLogger();
my $prefs = Plugins::SlimPing::Core::Logging->getPrefs();

# Pre-built error payload templates -- always return a shallow copy so that
# callers cannot mutate the singleton and corrupt subsequent requests.
my $_err_auth     = { error => { code => 40, message => 'Wrong username or password' } };
my $_err_disabled = { error => { code => 40, message => 'Wrong username or password' } };
my $_err_locked   = { error => { code => 40, message => 'Too many failed attempts - try again later' } };

# OpenSubsonic-spec code 44 = Invalid API key.  Code 41 is reserved for the
# LDAP-specific error and is hardcoded in many client UIs as "Authentication
# by token is not supported for LDAP" -- using it here is misleading.
my $_err_bad_key  = { error => { code => 44, message => 'Invalid or revoked API key' } };

# OpenSubsonic-spec code 41 = Token authentication not supported.  Per the
# spec this is the correct code when token+salt auth is disabled for any
# reason (previously returned code 42).
my $_err_no_token = {
    error => {
        code    => 41,
        message =>
'Token+salt auth is disabled on this server. Use an API key '
          . '(k= or Authorization: Bearer). '
          . 'Operators: enable LAN Mode in SlimPing settings to re-allow token+salt.'
    }
};
my $_err_no_plain = {
    error => {
        code    => 42,
        message =>
'Plain-password auth is disabled on this server. Use token+salt '
          . '(t= and s=) or an API key (k= / Authorization: Bearer). '
          . 'Operators: enable Plain Password in SlimPing settings if a '
          . 'legacy client truly cannot do better.'
    }
};

sub authenticate {
    my ($class, $params, $httpClient, $request) = @_;

    my $t0  = time();
    my $mgr = Plugins::SlimPing::Core::Container->get('auth_manager');
    my $ip  = Plugins::SlimPing::Auth::AdminGate::remoteIp($httpClient, $request);

    # Rate-limit gate: if this peer (with or without a username) is in
    # cooldown, reject before doing any credential work.  We check on the
    # username from the request params -- at this point it's untrusted user
    # input, but pairing the cooldown with username scopes the lockout to
    # the specific account being probed rather than the whole IP.
    my $rl_user = $params->{u} // '';
    if ( Plugins::SlimPing::Auth::RateLimit->isLocked($ip, $rl_user) ) {
        $log->warn("SlimPing auth: rejected (rate-limit cooldown) ip=$ip user=$rl_user");
        return (undef, { %$_err_locked });
    }

    # Priority 1: API key (OpenSubsonic extension -- preferred for external exposure)
    # Accept both the OpenSubsonic 'apiKey' parameter and the legacy Subsonic 'k' subset.
    if (my $api_key = $params->{apiKey} // $params->{k}) {
        # OpenSubsonic spec: if apiKey is present, no other auth params
        # (u, p, t, s) may be specified.  Return code 43 per api-reference.md.
        if ($params->{u} || $params->{p} || $params->{t} || $params->{s}) {
            $log->warn("SlimPing auth: conflicting auth params with API key ip=$ip");
            return (undef, { error => { code => 43, message => 'Multiple conflicting authentication mechanisms' } });
        }
        my $user = $mgr->getUserByApiKey($api_key);
        unless ($user) {
            $log->warn("SlimPing auth: failure (invalid API key) ip=$ip");
            Plugins::SlimPing::Auth::RateLimit->recordFailure($ip);
            return (undef, { %$_err_bad_key });
        }
        unless ($user->{enabled}) {
            # Return code 40 (not 41) -- no enumeration of account status via key probing
            $log->warn("SlimPing auth: failure for '${\$user->{username}}' ip=$ip");
            Plugins::SlimPing::Auth::RateLimit->recordFailure($ip, $user->{username});
            return (undef, { %$_err_disabled });
        }
        Plugins::SlimPing::Auth::RateLimit->clearSuccess($ip, $user->{username});
        $mgr->recordLogin($user->{username});
        Plugins::SlimPing::Core::DebugThrottle->debugRateLimited(
            "auth_ok_apikey_$user->{username}",
            sprintf("SlimPing auth: API key OK for '%s' (%.1fms)", $user->{username}, (time() - $t0) * 1000),
            60
        );
        return ($user, undef);
    }

    # Priority 2 & 3: username-based auth
    my $username = $params->{u};
    unless ($username) {
        Plugins::SlimPing::Auth::RateLimit->recordFailure($ip);
        return (undef, { %$_err_auth });
    }

    my $user = $mgr->getUser($username);
    unless ($user) {
        $log->warn("SlimPing auth: failure for '$username' ip=$ip");
        Plugins::SlimPing::Auth::RateLimit->recordFailure($ip, $username);
        return (undef, { %$_err_auth });
    }
    unless ($user->{enabled}) {
        $log->warn("SlimPing auth: failure for '$username' ip=$ip");
        Plugins::SlimPing::Auth::RateLimit->recordFailure($ip, $username);
        return (undef, { %$_err_disabled });
    }

    # S9a -- per-scheme wire-protocol gate.  Each Subsonic auth scheme has
    # its own pref so operators can dial in exactly what they accept:
    #
    #   k=<key>  : API key -- always accepted (no pref).  Best option, but
    #              ecosystem support is patchy.
    #   t= + s=  : Token+salt -- gated by `lan_mode`.  Default ON (undef =
    #              on) so upgrades don't break existing clients.  This is
    #              the Subsonic-standard scheme; what most popular clients
    #              actually do.
    #   p=       : Plain password -- gated by `allow_plain_password`.
    #              Default OFF (undef = off).  Operator opts in for legacy
    #              clients that cannot do better; the UI shows a red
    #              warning while it's enabled.
    #
    # Failed scheme attempts are NOT counted toward the rate-limit
    # cooldown -- they're configuration errors, not brute-force attempts.
    my $lan_raw = $prefs->get('lan_mode');
    my $lan_on  = defined $lan_raw ? ( $lan_raw ? 1 : 0 ) : 1;

    my $plain_raw = $prefs->get('allow_plain_password');
    my $plain_on  = defined $plain_raw ? ( $plain_raw ? 1 : 0 ) : 0;

    if ( $params->{t} && !$lan_on ) {
        $log->warn(
            "SlimPing auth: failure (token+salt disabled) "
              . "user='$username' ip=$ip"
        );
        return ( undef, { %$_err_no_token } );
    }
    if ( $params->{p} && !$plain_on ) {
        $log->warn(
            "SlimPing auth: failure (plain-password disabled) "
              . "user='$username' ip=$ip"
        );
        return ( undef, { %$_err_no_plain } );
    }

    # Priority 2: Token+salt (Subsonic standard -- no plaintext on wire)
    if (my $token = $params->{t}) {
        my $salt = $params->{s} // '';
        unless ($mgr->verifyTokenForUser($username, $token, $salt)) {
            $log->warn("SlimPing auth: failure for '$username' ip=$ip");
            Plugins::SlimPing::Auth::RateLimit->recordFailure($ip, $username);
            return (undef, { %$_err_auth });
        }
        Plugins::SlimPing::Auth::RateLimit->clearSuccess($ip, $username);
        $mgr->recordLogin($username);
        Plugins::SlimPing::Core::DebugThrottle->debugRateLimited(
            "auth_ok_token_$username",
            sprintf("SlimPing auth: token+salt OK for '%s' (%.1fms)", $username, (time() - $t0) * 1000),
            60
        );
        return ($user, undef);
    }

    # Priority 3: Plain password (legacy -- supported for older clients)
    if (my $password = $params->{p}) {
        # Handle hex-encoded passwords (enc: prefix from some legacy clients)
        if ($password =~ s/^enc://) {
            if (length($password) % 2 != 0) {
                $log->warn("SlimPing auth: failure for '$username' ip=$ip");
                Plugins::SlimPing::Auth::RateLimit->recordFailure($ip, $username);
                return (undef, { %$_err_auth });
            }
            $password = pack('H*', $password);
        }
        unless ($mgr->verifyPasswordForUser($username, $password)) {
            $log->warn("SlimPing auth: failure for '$username' ip=$ip");
            Plugins::SlimPing::Auth::RateLimit->recordFailure($ip, $username);
            return (undef, { %$_err_auth });
        }
        Plugins::SlimPing::Auth::RateLimit->clearSuccess($ip, $username);
        $mgr->recordLogin($username);
        Plugins::SlimPing::Core::DebugThrottle->debugRateLimited(
            "auth_ok_password_$username",
            sprintf("SlimPing auth: plain password OK for '%s' (%.1fms)", $username, (time() - $t0) * 1000),
            60
        );
        return ($user, undef);
    }

    # No credentials provided
    Plugins::SlimPing::Auth::RateLimit->recordFailure($ip, $username);
    return (undef, { %$_err_auth });
}

1;
