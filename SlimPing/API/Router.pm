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
# API/Router.pm - HTTP request router for the SlimPing OpenSubsonic API
#
# This module is the single addRawFunction handler registered by Plugin.pm
# for all /rest/*.view requests.  It is responsible for:
#
#   1. Parsing URL query-string and POST body parameters (formPost
#      OpenSubsonic extension)
#   2. Authenticating the request via Auth::Middleware
#   3. Resolving (or creating) the virtual player for the (user, client) pair
#   4. Dispatching to a registered handler coderef
#   5. Sending the formatted response via ResponseFormatter
#
# Handler modules register themselves at initPlugin time by calling
# registerHandler() or registerStreamHandler().  Stream handlers bypass
# ResponseFormatter and write binary data directly to the HTTP client.
#

package Plugins::SlimPing::API::Router;

use strict;
use warnings;

use Encode qw(encode_utf8 is_utf8);
use POSIX qw(strftime);
use URI::Escape qw(uri_unescape);
use Time::HiRes qw(time);

use Plugins::SlimPing::Core::Logging;
require Plugins::SlimPing::Core::DebugThrottle;

my $log = Plugins::SlimPing::Core::Logging->getLogger();
my $prefs = Plugins::SlimPing::Core::Logging->getPrefs();

# Hard cap on accepted POST body size for /rest/ endpoints.  Generous enough
# for the largest legitimate Subsonic operation (a full updatePlaylist with
# thousands of song IDs is comfortably under 1 MB) but small enough that an
# unauthenticated attacker cannot exhaust memory by streaming a huge body.
use constant MAX_POST_BODY_BYTES => 1 * 1024 * 1024;

# Endpoints that skip the Subsonic auth gate.  Discovery endpoints must be
# reachable before authentication; share-stream endpoints carry their own
# credential in the URL.
my %_unauth_endpoints = map { $_ => 1 } qw(
    ping
    getOpenSubsonicExtensions
    shareStream
    shareMetadata
    radioStream
    radioMetadata
);

# Endpoints whose responses carry Cache-Control and Last-Modified headers.
# Library data (changes only on rescan) gets the full cache TTL; user-specific
# collections (stars, playlists) get a shorter TTL because they can change
# between rescans.  Real-time endpoints (nowPlaying, scanStatus) and mutations
# are deliberately excluded -- caching a "now playing" snapshot is misleading.
#
# The cache TTL is controlled by the cache_ttl_seconds preference (default 300).
# See docs/testing.md for the rationale behind this list and the decision not
# to extend ifModifiedSince beyond getIndexes.
my %_cacheable_endpoints = (
    # Library listings -- invalidate on rescan
    getMusicFolders => 'library',
    getIndexes      => 'library',
    getArtists      => 'library',
    getGenres       => 'library',
    getAlbumList    => 'library',
    getAlbumList2   => 'library',
    getTopSongs     => 'library',
    # Static metadata -- practically never changes
    ping                       => 'static',
    getLicense                 => 'static',
    getOpenSubsonicExtensions  => 'static',
    # User collections -- can change between rescans
    getStarred  => 'user',
    getStarred2 => 'user',
    getPlaylists  => 'user',
);

# Each Handlers:: module calls registerHandler() at initPlugin time.
my %_handlers;

# Stream handler registry: endpoint_name => coderef
# Stream handlers bypass ResponseFormatter -- they write binary data directly.
my %_stream_handlers;

# Register a standard JSON/XML handler for the given endpoint name.
# Duplicate registrations are a programmer error -- the second registration
# would silently overwrite the first, masking dispatch-table bugs.  Fail fast
# at plugin init time per the project's fail-fast-on-init convention.
sub registerHandler {
    my ($class, $endpoint, $coderef) = @_;
    die "SlimPing: duplicate handler registration for endpoint '$endpoint'"
        if exists $_handlers{$endpoint};
    $_handlers{$endpoint} = $coderef;
}

# Register a stream handler for the given endpoint name.
# Stream handlers receive ($httpClient, $response, $args) and are responsible
# for writing binary content directly without going through ResponseFormatter.
sub registerStreamHandler {
    my ($class, $endpoint, $coderef) = @_;
    die "SlimPing: duplicate stream handler registration for endpoint '$endpoint'"
        if exists $_stream_handlers{$endpoint};
    $_stream_handlers{$endpoint} = $coderef;
}

# Main dispatch entry point -- called by LMS for every /rest/*.view request.
sub dispatch {
    my ($httpClient, $response) = @_;

    my $t_start = time();

    my $request = $response->request();
    my $params  = _parseParams($request);
    my $format  = $params->{f} || 'xml';

    require Plugins::SlimPing::Utils::Errors;

    # Extract endpoint from path: /rest/getAlbum.view or /rest/getAlbum -> getAlbum
    my $path = $request->uri->path();
    my ($endpoint) = ($path =~ m{/rest/(\w+)(?:\.view)?$});

    unless ($endpoint) {
        $log->warn("SlimPing: unrecognised path: $path");
        return _sendResponse($httpClient, $response, $format,
            Plugins::SlimPing::Utils::Errors->error(0, 'Invalid request path'), 'invalid');
    }

    my $t_parse = time();

    my $user;
    unless ($_unauth_endpoints{$endpoint}) {
        # Standard auth gate for all other endpoints
        require Plugins::SlimPing::Auth::Middleware;
        my $auth_error;
        ($user, $auth_error) =
            Plugins::SlimPing::Auth::Middleware->authenticate($params, $httpClient, $request);
        unless ($user) {
            $log->warn("SlimPing: auth failure for endpoint $endpoint");
            return _sendResponse($httpClient, $response, $format, $auth_error, $endpoint);
        }
    } else {
        # Unauthenticated endpoints get a sentinel user with basic permissions
        # so that LibraryMapper->setRequestUser() and permission checks work
        # without special-casing.
        $user = { username => '_anon', admin => 0, enabled => 1 };
    }

    my $t_auth = time();

    # Let LibraryMapper shape methods look up the current user's star/rating
    # annotations without every handler having to pass username explicitly.
    Plugins::SlimPing::Core::LibraryMapper->setRequestUser($user->{username});

    # Extract the request base URL so handlers can construct FQDN URLs that
    # account for proxies, forwarding, and non-standard ports.
    {
        my $scheme = $request->header('X-Forwarded-Proto') || 'http';
        my $host   = $request->header('Host');
        if ( $host && $host =~ /\A[A-Za-z0-9\-\.:\[\]]+\z/ ) {
            Plugins::SlimPing::Core::LibraryMapper->setRequestBaseUrl("$scheme://$host");
        }
    }

    my $client_name = $params->{c} // '';
    require Plugins::SlimPing::Core::ClientQuirks;
    Plugins::SlimPing::Core::ClientQuirks->setRequestClient($client_name);

    my $args = { params => $params, user => $user, client_name => $client_name,
                 _httpClient => $httpClient, _response => $response };

    # Apply client-specific request-phase workarounds before dispatch.
    # Returns immediately when client_quirks_enabled is off (the default).
    Plugins::SlimPing::Core::ClientQuirks->applyRequestHooks($args);

    # Stream handlers bypass ResponseFormatter -- they write binary directly
    if (my $stream_handler = $_stream_handlers{$endpoint}) {
        return $stream_handler->($httpClient, $response, $args);
    }

    # Standard JSON/XML handlers
    my $handler = $_handlers{$endpoint};
    unless ($handler) {
        $log->info("SlimPing: no handler registered for '$endpoint'");
        return _sendResponse($httpClient, $response, $format,
            Plugins::SlimPing::Utils::Errors->error(0, "Not implemented: $endpoint"), $endpoint);
    }

    my $result = eval {
        $handler->($args);
    };

    if ($@) {
        require Carp;
        my $err = $@;
        $log->error(sub { "SlimPing: handler '$endpoint' threw: $err" . Carp::longmess() });
        $result = Plugins::SlimPing::Utils::Errors->error(0, 'Internal server error');
    }

    my $t_handler = time();

    Plugins::SlimPing::Core::ClientQuirks->applyResponseHooks($result);

    require Plugins::SlimPing::Utils::ResponseTrimmer;
    Plugins::SlimPing::Utils::ResponseTrimmer->trim($result, $params->{c});

    _sendResponse($httpClient, $response, $format, $result, $endpoint);

    my $t_send = time();

    if ($log->is_debug) {
        Plugins::SlimPing::Core::DebugThrottle->debugRateLimited(
            "timing_$endpoint",
            sprintf(
                'SlimPing timing: %s parse=%.1fms auth=%.1fms handler=%.1fms send=%.1fms total=%.1fms',
                $endpoint,
                ($t_parse  - $t_start)  * 1000,
                ($t_auth   - $t_parse)  * 1000,
                ($t_handler - $t_auth)   * 1000,
                ($t_send   - $t_handler) * 1000,
                ($t_send   - $t_start)  * 1000,
            ),
            30
        );
    }
}

# Parse request parameters from the URL query string and (for POST requests)
# the request body.  Query-string values take precedence over body values.
# A key that appears more than once in the query string is stored as an
# arrayref -- required for multi-value params like id= in star/updatePlaylist.
#
# POST bodies are accepted only when the Content-Type indicates form-encoded
# data (formPost OpenSubsonic extension) and the body is within MAX_POST_BODY_BYTES.
# Bodies that violate either rule are silently dropped -- the auth check that
# runs next will fail since the credentials live in the dropped payload.
sub _parseParams {
    my ($request) = @_;
    my %params;

    _accumulate(\%params, $request->uri->query() || '');

    if ($request->method() eq 'POST') {
        my $ct = $request->header('Content-Type') // '';
        if ($ct =~ m{^\s*application/x-www-form-urlencoded\b}i
            || $ct =~ m{^\s*multipart/form-data\b}i) {

            my $body = $request->content() // '';
            if (length($body) > MAX_POST_BODY_BYTES) {
                $log->warn(sprintf(
                    'SlimPing: POST body too large (%d bytes) -- ignoring body',
                    length($body)
                ));
            } else {
                # Only populate a key from the body if not already set by the
                # query string.
                for my $pair (split /&/, $body) {
                    my ($k, $v) = split /=/, $pair, 2;
                    next unless defined $k && length $k;
                    $params{ _formDecodeValue($k) } //= _formDecodeValue($v // '');
                }
            }
        } elsif (length($ct)) {
            $log->debug("SlimPing: POST body Content-Type not consumed by form parser: '$ct'");
        }
    }

    # Flatten known scalar parameters to prevent duplicate query-string keys
    # from producing unexpected arrayrefs in the auth chain and handlers.
    for my $k (qw(k apiKey u p t s f c v share track token_expires t_stream sq_id playlist)) {
        $params{$k} = $params{$k}->[-1]
            if ref $params{$k} eq 'ARRAY';
    }

    return \%params;
}

# Accumulate key=value pairs into %$dest, collecting duplicate keys as arrayrefs.
sub _accumulate {
    my ($dest, $str) = @_;
    for my $pair (split /&/, $str) {
        my ($k, $v) = split /=/, $pair, 2;
        next unless defined $k && length $k;
        $k = _formDecodeValue($k);
        $v = _formDecodeValue($v // '');
        if (exists $dest->{$k}) {
            $dest->{$k} = [$dest->{$k}] unless ref $dest->{$k} eq 'ARRAY';
            push @{ $dest->{$k} }, $v;
        } else {
            $dest->{$k} = $v;
        }
    }
}

# Form-decode one raw parameter value: translate '+' to a space first (the
# form-encoding convention -- aiohttp and other clients encode spaces as '+'
# in query strings and formPost bodies), then percent-decode the result.
#
# Order matters.  A percent-encoded literal plus ('%2B') has no raw '+' to
# translate, so it decodes to '+' afterwards -- values that legitimately
# contain a plus survive intact.  Base64 auth tokens (t=) may contain '+',
# and clients send it percent-encoded ('%2B'); those tokens arrive here
# unchanged.  A raw '+' in a token would decode to a space, which is correct
# per form encoding: a raw '+' on the wire is by convention a space, and
# clients must percent-encode token values.
sub _formDecodeValue {
    my ($value) = @_;
    my $form = $value =~ tr/+/ /r;
    return uri_unescape($form);
}

# Render $data via ResponseFormatter and write the HTTP response.
# $endpoint is optional -- when provided, cacheable endpoints get
# Cache-Control and Last-Modified headers.
sub _sendResponse {
    my ($httpClient, $response, $format, $data, $endpoint) = @_;

    require Plugins::SlimPing::API::ResponseFormatter;
    my $body = Plugins::SlimPing::API::ResponseFormatter->render($data, $format);
    $body = encode_utf8($body) if is_utf8($body);

    my $ct = ($format eq 'json') ? 'application/json' : 'text/xml';
    $response->header('Content-Type'   => "$ct; charset=utf-8");
    $response->header('Content-Length' => length($body));
    $response->code(200);

    _maybeAddCachingHeaders($response, $endpoint) if $endpoint && !$data->{error};

    require Slim::Web::HTTP;
    Slim::Web::HTTP::addHTTPResponse($httpClient, $response, \$body);
}

# Send a Subsonic error response through the standard envelope.
# Public so stream sub-modules can call it directly without routing
# through AudioDelivery.pm or Endpoints.pm private copies.
# Delegates error-hashref construction to Utils::Errors for consistency —
# all error envelopes in the plugin now flow through a single module.
sub sendError {
    my ($class, $httpClient, $response, $params, $code, $msg) = @_;
    require Plugins::SlimPing::Utils::Errors;
    _sendResponse($httpClient, $response,
        (ref $params eq 'HASH' ? $params->{f} : undef) || 'xml',
        Plugins::SlimPing::Utils::Errors->error($code, $msg)
    );
}

# Add Cache-Control and Last-Modified headers for cacheable endpoints.
# Library data gets the full cache TTL (default 300 s), user collections get
# a shorter TTL (60 s), and static metadata gets a longer TTL (3600 s).
# Last-Modified is derived from lastScanTimestampMs for library endpoints;
# user-collection and static endpoints omit it because their change cadence
# is independent of library rescans.
sub _maybeAddCachingHeaders {
    my ($response, $endpoint) = @_;
    my $category = $_cacheable_endpoints{$endpoint} or return;

    my $ttl = $prefs->get('cache_ttl_seconds');
    my $max_age;

    if ($category eq 'static') {
        $max_age = 3600;
    } elsif ($category eq 'user') {
        $max_age = 60;
    } else {
        $max_age = $ttl;
    }

    $response->header('Cache-Control' => "max-age=$max_age, private");

    # Last-Modified only makes sense for library data that changes on rescan.
    if ($category eq 'library') {
        my $last_scan = $prefs->get('lastScanTimestampMs');
        if ($last_scan) {
            my $http_date = _epochToHttpDate(int($last_scan / 1000));
            $response->header('Last-Modified' => $http_date) if $http_date;
        }
    }
}

# Convert a Unix epoch to an RFC 1123 HTTP-date string (GMT).
sub _epochToHttpDate {
    my ($epoch) = @_;
    return strftime('%a, %d %b %Y %H:%M:%S GMT', gmtime($epoch));
}

1;
