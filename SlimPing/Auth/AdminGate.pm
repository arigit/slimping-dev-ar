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

# Auth/AdminGate.pm - HTTP admin-gate enforcement for the settings UI
#
# Settings endpoints (HTML page + four JSON sub-endpoints) are gated by a
# graduated source-IP trust model controlled by the `admin_access` pref.
# Three modes:
#
#   lan_open       (default) Loopback and private-LAN sources are admitted
#                  anonymously.  Public IPs must authenticate.  Matches the
#                  typical home LMS deployment: settings "just work" from the
#                  LAN browser, and a port-scanner from the internet is denied.
#
#   loopback_open  Only loopback (127/8, ::1) is admitted anonymously.
#                  Useful when the operator does not trust their LAN.
#
#   auth_required  Every request must authenticate, regardless of source IP.
#                  Recommended for deployments that put LMS on the public
#                  internet (port-forward, reverse proxy, etc).
#
# When authentication is required, two credentials are accepted:
#   1. LMS Basic Auth -- only honoured when LMS's `authorize` pref is on
#      (otherwise checkAuthorization returns 1 unconditionally).
#   2. SlimPing API key (?k=<key> or 'Authorization: Bearer <key>') belonging
#      to a user with admin => 1 and enabled => 1.
#
# Mutating requests (anything other than GET/HEAD) additionally require:
#   - Content-Type: application/json (form-encoded posts are the easy
#     cross-origin CSRF surface).
#   - Origin (or Referer) matching the request Host.
# These CSRF checks apply REGARDLESS of mode -- source-IP trust does not
# protect against a malicious page visited by an admin on the LAN.
#
# Reverse-proxy note: when LMS only hears requests from a proxy on loopback,
# every peer looks like 127.0.0.1 and `lan_open` would admit everyone.  The
# trust_xff pref (S14) makes the gate honour X-Forwarded-For for source-IP
# evaluation.  We log a one-time WARN when XFF is seen but trust_xff is off.

package Plugins::SlimPing::Auth::AdminGate;

use strict;
use warnings;

use Slim::Web::HTTP;
use JSON::XS ();
use URI      ();

use Plugins::SlimPing::Core::Logging;
require Plugins::SlimPing::Core::Container;
require Plugins::SlimPing::Core::IPTrust;
require URI::Escape;

my $log          = Plugins::SlimPing::Core::Logging->getLogger();
my $prefs        = Plugins::SlimPing::Core::Logging->getPrefs();
my $server_prefs = Plugins::SlimPing::Core::Logging->getServerPrefs();
my $json         = JSON::XS->new->utf8->allow_nonref;

# Set once we've warned about the trust_xff misconfiguration, to avoid spam.
my $_xff_warned;

sub requireAdmin {
    my ( $httpClient, $request, %opts ) = @_;

    my $method      = $request->method() || 'GET';
    my $is_mutating = $method ne 'GET' && $method ne 'HEAD';

    if ($is_mutating) {

        # Origin/Referer check -- the actual CSRF defence -- applies to every
        # mutating request (HTML page legacy form submit OR JSON sub-endpoint).
        unless ( _originAllowed($request) ) {
            return ( 0, 403, 'Cross-origin request rejected', undef );
        }

        # The JSON-only Content-Type check is belt-and-braces for the JSON
        # sub-endpoints (where the body is parsed as JSON anyway).  The HTML
        # page handler must accept form-encoded POSTs because that's how the
        # legacy non-AJAX submit buttons reach it; LMS has already parsed the
        # form into $params by the time we get here.
        if ( $opts{json_endpoint} ) {
            my $ct = $request->header('Content-Type') || '';
            unless ( $ct =~ m{^\s*application/json\b}i ) {
                return ( 0, 415, 'Content-Type must be application/json',
                    undef );
            }
        }
    }

    my $ip   = remoteIp( $httpClient, $request );
    my $mode = $prefs->get('admin_access');

    # Source-IP trust shortcut -- admits anonymously when the IP falls inside
    # the configured trust tier.
    if ( $mode eq 'lan_open' && Plugins::SlimPing::Core::IPTrust->isPrivateIp($ip) ) {
        return ( 1, undef, undef, "lan:$ip" );
    }
    if ( $mode eq 'loopback_open' && Plugins::SlimPing::Core::IPTrust->isLoopback($ip) ) {
        return ( 1, undef, undef, "loopback:$ip" );
    }

    # Credential paths -- always available regardless of mode, so an operator
    # accessing remotely can authenticate even when their IP isn't trusted.
    if ( $server_prefs->get('authorize') ) {
        if ( my ( $u, $p ) = $request->authorization_basic() ) {
            if ( Slim::Web::HTTP::checkAuthorization( $u, $p, $request ) ) {
                return ( 1, undef, undef, "lms:$u" );
            }
        }
    }

    if ( my $key = extractApiKey($request) ) {
        my $user = Plugins::SlimPing::Core::Container->get('auth_manager')
          ->getUserByApiKey($key);
        if ( $user && $user->{admin} && $user->{enabled} ) {
            return ( 1, undef, undef, $user->{username} );
        }
    }

    # Loopback bootstrap -- only relevant in `auth_required` mode.  Without
    # this, an operator who sets auth_required before creating any admin
    # user would be locked out.  In lan_open / loopback_open the IP-trust
    # path already covers the bootstrap case.
    if ( $mode eq 'auth_required' && Plugins::SlimPing::Core::IPTrust->isLoopback($ip) && _hasNoAdmin() ) {
        $log->warn(
'SlimPing: settings bootstrap -- allowing loopback access (no admin user exists yet)'
        );
        return ( 1, undef, undef, 'bootstrap' );
    }

    return ( 0, 401, 'Authentication required', undef );
}

# Returns the remote IP for trust evaluation.  Honours the `trust_xff` pref
# (S14) -- when on, the leftmost X-Forwarded-For entry wins, so operators
# behind a reverse proxy keep accurate source-IP trust decisions.  When off,
# only the direct peer is considered, and a one-time WARN is emitted if XFF
# is seen -- likely a reverse-proxy operator who hasn't enabled trust_xff.
#
# Public because Settings::AdminApi handlers also use it for audit-log IP
# fields -- the same XFF semantics must apply there as in the gate itself.
sub remoteIp {
    my ( $httpClient, $request ) = @_;

    if ( $request && $prefs->get('trust_xff') ) {
        if ( my $xff = $request->header('X-Forwarded-For') ) {
            my ($first) = split /\s*,\s*/, $xff;
            return $first if defined $first && length $first;
        }
    }
    elsif ( $request && !$_xff_warned && $request->header('X-Forwarded-For') ) {
        $_xff_warned = 1;
        $log->warn(
            'SlimPing: X-Forwarded-For header present but trust_xff is off -- '
              . 'reverse-proxy deployments should enable the trust_xff pref so '
              . 'admin_access source-IP checks see the real client address' );
    }

    return '-' unless $httpClient && $httpClient->can('peerhost');
    return $httpClient->peerhost() // '-';
}

# Extract an API key from either ?k=<key> in the query string or an
# 'Authorization: Bearer <key>' header.  Returns undef if neither is present.
#
# Public because Core::Settings::handler renders the key into the page so
# AJAX calls back to the JSON endpoints can re-present it.
sub extractApiKey {
    my ($request) = @_;
    if ( my $auth = $request->header('Authorization') ) {
        if ( $auth =~ /^\s*Bearer\s+(\S+)/i ) {
            return $1;
        }
    }
    my $query = $request->uri->query() || '';
    for my $pair ( split /&/, $query ) {
        my ( $k, $v ) = split /=/, $pair, 2;
        next unless defined $k && $k eq 'k' && defined $v;
        return URI::Escape::uri_unescape($v);
    }
    return;
}

# Returns true if the request's Origin (or Referer fallback) host matches the
# host on the request itself.  A missing Origin/Referer is allowed for
# non-browser clients (curl/scripts) -- those still need a valid credential, so
# the CSRF risk is borne by the auth check, not by header presence.
sub _originAllowed {
    my ($request) = @_;
    my $origin = $request->header('Origin') || $request->header('Referer');
    return 1 unless defined $origin && length $origin;
    my $origin_host = eval { URI->new($origin)->host };
    if ($@) {
        $log->warn("SlimPing: AdminGate origin parse failure: $@");
        return 0;
    }
    $origin_host ||= '';
    my $req_host    = $request->header('Host')         || '';
    $req_host =~ s/:\d+$//;
    $origin_host = lc $origin_host;
    $req_host    = lc $req_host;
    return $origin_host eq $req_host;
}

sub _hasNoAdmin {
    my $users = Plugins::SlimPing::Core::Container->get('auth_manager')->getUsers();
    for my $user (@$users) {
        return 0 if $user->{admin} && $user->{enabled};
    }
    return 1;
}

sub denyAdmin {
    my ( $httpClient, $response, $code, $message ) = @_;
    my $body = $json->encode( { error => $message } );
    $response->code($code);
    $response->header( 'Content-Type'   => 'application/json; charset=utf-8' );
    $response->header( 'Content-Length' => length($body) );
    if ( $code == 401 ) {
        $response->header( 'WWW-Authenticate' => 'Bearer realm="SlimPing"' );
    }
    Slim::Web::HTTP::addHTTPResponse( $httpClient, $response, \$body );
    return;
}

# Returns a minimal scalar-ref of HTML for the settings page when admin auth
# fails.  filltemplatefile-style return so LMS treats this as a normal page
# render.  We deliberately avoid a 401 here -- the page already loaded under
# LMS's own dispatcher and a status change at this point would be lost; the
# textual message is what reaches the operator.
sub renderAdminRequired {
    my ( $code, $message ) = @_;
    my $html = <<"HTML";
<!doctype html>
<html><head><meta charset="utf-8"><title>SlimPing -- Admin Required</title>
<style>body{font:14px sans-serif;max-width:640px;margin:3em auto;padding:0 1em;color:#333}
h1{font-size:1.4em}code{background:#eee;padding:2px 6px;border-radius:3px}</style>
</head><body>
<h1>SlimPing settings -- admin access required</h1>
<p>The plugin's admin gate denied your request. ($code: @{[ $message // 'no detail' ]})</p>
<p>The current access mode is configured to require an authenticated admin  --
either because you reached the page from a public IP or because the operator
has set <code>admin_access</code> to <code>auth_required</code>. To proceed,
do one of the following:</p>
<ul>
<li>Reach this page from a private LAN address (default mode admits LAN
clients without credentials), or from the LMS host itself (loopback).</li>
<li>Enable LMS web authentication (<em>Settings &raquo; Advanced &raquo; Security</em>)
and sign in with the LMS Basic Auth credentials.</li>
<li>Append <code>?k=&lt;your-admin-api-key&gt;</code> to this URL.</li>
<li>For first-run setup with <code>auth_required</code> mode, access the
page from the LMS host itself (<code>localhost</code>) -- a loopback
bootstrap window lets the first admin user be created.</li>
</ul>
</body></html>
HTML
    return \$html;
}

1;
