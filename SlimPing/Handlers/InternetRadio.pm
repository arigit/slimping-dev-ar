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
# Handlers/InternetRadio.pm - Internet radio station handlers
#

package Plugins::SlimPing::Handlers::InternetRadio;

use strict;
use warnings;

use Plugins::SlimPing::API::Router;
use Plugins::SlimPing::Core::Logging;
require Plugins::SlimPing::Core::Container;
require Plugins::SlimPing::Core::StreamGate;
require Plugins::SlimPing::Auth::RateLimit;
require Plugins::SlimPing::Core::DebugThrottle;

my $log   = Plugins::SlimPing::Core::Logging->getLogger();
my $prefs = Plugins::SlimPing::Core::Logging->getPrefs();

sub registerHandlers {
    my $class = shift;
    Plugins::SlimPing::API::Router->registerHandler(
        'getInternetRadioStations', \&getInternetRadioStations);
    Plugins::SlimPing::API::Router->registerStreamHandler(
        'radioMetadata', \&radioMetadata );
    Plugins::SlimPing::API::Router->registerStreamHandler(
        'radioStream', \&radioStream );
}

sub getInternetRadioStations {
    my ($args) = @_;

    return { internetRadioStations => { internetRadioStation => [] } }
        unless Plugins::SlimPing::Core::Logging->isFeatureEnabled('feature_internet_radio');

    my $stations = Plugins::SlimPing::Core::Container->get('library_mapper')
        ->getInternetRadioStations($args->{user}{username});

    return {
        internetRadioStations => {
            internetRadioStation => $stations,
        },
    };
}

# --- Stream handler (no auth gate -- stream token is the credential) ---

sub radioMetadata {
    my ( $httpClient, $response, $args ) = @_;
    my $p = $args->{params};

    # Gate 1: Feature toggle
    return
      if Plugins::SlimPing::Core::StreamGate->requireFeature(
        $httpClient, $response, 'feature_internet_radio', 'radioMetadata' );

    # Gate 2: Rate-limit gate
    my ($ip) =
      Plugins::SlimPing::Core::StreamGate->gateIp( $httpClient, $response,
        $response->request() )
      or return;

    # Gate 3: Required parameters
    my ($sq_id) =
      Plugins::SlimPing::Core::StreamGate->requireParam(
        httpClient => $httpClient, response => $response,
        ip => $ip, value => $p->{sq_id}, param_name => 'sq_id' )
      or return;
    my ($token) =
      Plugins::SlimPing::Core::StreamGate->requireParam(
        httpClient => $httpClient, response => $response,
        ip => $ip, value => $p->{t_stream}, param_name => 't_stream' )
      or return;
    my ($expiry) =
      Plugins::SlimPing::Core::StreamGate->requireParam(
        httpClient => $httpClient, response => $response,
        ip => $ip, value => $p->{token_expires}, param_name => 'token_expires' )
      or return;

    # Gate 4: Validate HMAC stream token
    return unless _validateStreamToken( $sq_id, $expiry, $token, 'radioMetadata', $httpClient, $response, $ip );

    # Success -- clear rate-limit cooldown
    Plugins::SlimPing::Auth::RateLimit->clearSuccess( $ip, '_anon' );

    # Artwork: read whatever LMS resolved for the player -- $song->coverArt()
    # from the live virtual player is the canonical answer.  Only when no
    # player is active do we fall back to the timer-populated cache or the
    # shipped default icon.  Valid tokens must never 404 here.
    require Plugins::SlimPing::Core::VirtualPlayer;

    my ( $body, $content_type );

    # Path A: On-demand live player lookup -- reads artwork from the currently
    # streaming virtual player, including plugin-injected artwork (BBC Sounds,
    # etc.) that LMS resolved through its native chain.
    ( $body, $content_type ) =
      Plugins::SlimPing::Core::VirtualPlayer->getArtworkFromLivePlayer(
        "slimping-$sq_id", "irs:$sq_id:0" );

    # Path B: Timer-populated cache -- same $song->coverArt() data from the
    # streaming timer callback (pre-stream or post-disconnect).
    unless ($body) {
        ( $body, $content_type ) =
          Plugins::SlimPing::Core::VirtualPlayer->getArtworkFromCache(
            "irs:$sq_id:0" );
    }

    # Path C: Shipped default radio icon -- absolute last resort.
    unless ($body) {
        ( $body, $content_type ) =
          Plugins::SlimPing::Core::VirtualPlayer->readDefaultArtwork('radio');
    }

    unless ($body) {
        Plugins::SlimPing::Core::VirtualPlayer->sendStreamError(
            $httpClient, $response, 70, 'Cover art not found' );
        return;
    }

    $content_type ||= 'image/jpeg';

    $response->code(200);
    $response->header( 'Content-Type'   => $content_type );
    $response->header( 'Content-Length' => length($body) );
    $response->header( 'Cache-Control'  => 'private, max-age=60' );
    Slim::Web::HTTP::addHTTPResponse( $httpClient, $response, \$body );

    Plugins::SlimPing::Core::DebugThrottle->debugRateLimited(
        "radio_meta_$sq_id",
        sprintf( "SlimPing: radio metadata served for %s ip=%s", $sq_id, $ip ),
        60
    );
}

# --- Stream handler (no auth gate -- stream token is the credential) ---

sub radioStream {
    my ( $httpClient, $response, $args ) = @_;
    my $p = $args->{params};

    # Gate 1: Feature toggle
    return
      if Plugins::SlimPing::Core::StreamGate->requireFeature(
        $httpClient, $response, 'feature_internet_radio', 'radioStream' );

    # Gate 2: Rate-limit gate
    my ($ip) =
      Plugins::SlimPing::Core::StreamGate->gateIp( $httpClient, $response,
        $response->request() )
      or return;

    # Gate 3: Required parameters
    my ($sq_id) =
      Plugins::SlimPing::Core::StreamGate->requireParam(
        httpClient => $httpClient, response => $response,
        ip => $ip, value => $p->{sq_id}, param_name => 'sq_id' )
      or return;
    my ($token) =
      Plugins::SlimPing::Core::StreamGate->requireParam(
        httpClient => $httpClient, response => $response,
        ip => $ip, value => $p->{t_stream}, param_name => 't_stream' )
      or return;
    my ($expiry) =
      Plugins::SlimPing::Core::StreamGate->requireParam(
        httpClient => $httpClient, response => $response,
        ip => $ip, value => $p->{token_expires}, param_name => 'token_expires' )
      or return;

    # Gate 4: Validate HMAC stream token
    return unless _validateStreamToken( $sq_id, $expiry, $token, 'radioStream', $httpClient, $response, $ip );

    # Gate 5: proxy_remote_streams must be enabled for radio
    unless (
        Plugins::SlimPing::Core::Logging->isFeatureEnabled('proxy_remote_streams')
      )
    {
        require Plugins::SlimPing::Core::VirtualPlayer;
        Plugins::SlimPing::Core::VirtualPlayer->sendStreamError(
            $httpClient, $response, 0, 'Not implemented: radio streaming' );
        return;
    }

    # Success -- clear rate-limit cooldown
    Plugins::SlimPing::Core::StreamGate->clearGate($ip);

    # Resolve stream URL
    my $mapper = Plugins::SlimPing::Core::Container->get('library_mapper');
    my $stream_info = $mapper->resolveStreamUrl($sq_id);
    unless ($stream_info) {
        require Plugins::SlimPing::Core::VirtualPlayer;
        Plugins::SlimPing::Core::VirtualPlayer->sendStreamError(
            $httpClient, $response, 70, 'Station not found' );
        return;
    }

    # Build station metadata and an unauth'd radioMetadata URL for the
    # icy-url ICY header so clients (VLC, mpv) can fetch cover art.
    my $name = $mapper->getRadioName($sq_id);
    my $meta        = {};
    my $stream_name = 'Unknown Radio Station';
    my $icy_url;
    if ($name) {
        $stream_name = $name;
        # Strip control characters from station names to prevent
        # CRLF injection in HTTP response headers (icy-*).
        $stream_name =~ s/[\x00-\x1f\x7f]//g;
        $stream_name = 'Unknown Radio Station' unless length $stream_name;
        $meta        = { artist => $name, title => $name };
    }

    {
        require URI::Escape;
        my $base =
          Plugins::SlimPing::Core::LibraryMapper::_requestBaseUrl() || '';
        $icy_url = "$base/rest/radioMetadata.view?sq_id="
          . URI::Escape::uri_escape_utf8($sq_id)
          . '&t_stream='
          . URI::Escape::uri_escape_utf8($token);
        $icy_url .= '&token_expires='
          . URI::Escape::uri_escape_utf8($expiry);
    }

    # Pool check: if another listener is already streaming this underlying
    # URL at the same bitrate, attach as a pooled listener instead of
    # creating a duplicate virtual player and transcode pipeline.
    require Plugins::SlimPing::Core::PipelinePool;
    require Plugins::SlimPing::Core::Container;
    {
        my $br   = $prefs->get('radio_max_bitrate');
        my $mime = Plugins::SlimPing::Core::Container->get('library_mapper')
          ->outputMime();

        my $request  = $response->request();
        my $want_icy = $request && $request->header('Icy-MetaData') ? 1 : 0;

        $response->code(200);
        $response->header( 'Content-Type'        => $mime );
        $response->header( 'Connection'          => 'close' );
        $response->header( 'icy-name'            => $stream_name );
        $response->header( 'icy-br'              => $br );
        $response->header( 'icy-url'             => $icy_url ) if $want_icy;
        $response->header( 'icy-metaint'         => 32768 )   if $want_icy;
        $response->header( 'Content-Disposition' => 'inline' );

        require Slim::Web::HTTP;
        my $headers =
          Slim::Web::HTTP::_stringifyHeaders($response) . "\x0d\x0a";

        my $attached = Plugins::SlimPing::Core::PipelinePool->registerListener(
            pool_type   => 'radio',
            source_url  => $stream_info->{url},
            br_kbps     => $br,
            httpClient  => $httpClient,
            headers     => $headers,
            time_offset => undef,
            enable_icy  => $want_icy,
        );
        if ($attached) {
            return;
        }
    }

    require Plugins::SlimPing::Core::VirtualPlayer;
    my $started = Plugins::SlimPing::Core::VirtualPlayer::streamViaPipeline(
        httpClient        => $httpClient,
        response          => $response,
        source_url        => $stream_info->{url},
        sq_id             => $sq_id,
        client_name       => 'radio',
        output_br_kbps    => $prefs->get('radio_max_bitrate'),
        format            => '',
        time_offset       => 0,
        is_download       => 0,
        is_remote         => 1,
        want_cl           => 0,
        is_live_stream    => 1,
        meta              => $meta,
        stream_name       => $stream_name,
        icy_url           => $icy_url,
        artwork_cache_key => "irs:$sq_id:0",
    );
    if ( defined $started && $started <= 0 ) {
        my $msg = $started == -1
          ? 'Too many remote stream requests - wait before retrying'
          : 'Too many concurrent remote streams - try again later';
        Plugins::SlimPing::Core::VirtualPlayer->sendStreamError(
            $httpClient, $response, 40, $msg );
        return;
    }
}

# --- Private helpers ---

# Validate a streaming HMAC token and send a stream error + record a rate-limit
# failure when invalid.  Returns 1 on success, 0 on failure (caller should return).
sub _validateStreamToken {
    my ( $sq_id, $expiry, $token, $context, $httpClient, $response, $ip ) = @_;
    require Plugins::SlimPing::Core::Container;
    my $mgr = Plugins::SlimPing::Core::Container->get('auth_manager');
    my ( $valid_id ) = $mgr->validateStreamToken( $sq_id, $expiry, $token );
    unless ($valid_id) {
        $log->warn("SlimPing: $context invalid token for $sq_id ip=$ip");
        require Plugins::SlimPing::Auth::RateLimit;
        Plugins::SlimPing::Auth::RateLimit->recordFailure( $ip, '_anon' );
        require Plugins::SlimPing::Core::VirtualPlayer;
        Plugins::SlimPing::Core::VirtualPlayer->sendStreamError(
            $httpClient, $response, 40, 'Invalid or expired stream token' );
        return 0;
    }
    return 1;
}

1;
