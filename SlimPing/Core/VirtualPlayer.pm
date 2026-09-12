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
# Core/VirtualPlayer.pm - Unified LMS pipeline streaming for SlimPing
#
# Creates a lightweight Slim::Player::HTTP virtual player to stream audio
# through LMS's native transcoding and protocol-handler pipeline.  Used for
# any stream/download request that needs processing: local files requiring
# format conversion or bitrate capping, and ALL remote tracks (since LMS
# must fetch and decode them).
#
# The virtual player acts as an audio sink.  Chunks are relayed to the
# HTTP client via LMS's sendStreamingResponse event loop, the same
# mechanism used by LMS's own stream.mp3 endpoint.
#
# Delegates to five sub-modules:
#   StreamingClient.pm  - LMS player subclass + prime-buffer priming
#   RemoteGovernor.pm   - per-client rate limiting + global concurrency cap
#   StreamEnricher.pm   - ICY metadata, local metadata, CUE stop timers
#   PlayerCleanup.pm    - disconnected player lifecycle + orphan sweeps
#   ArtworkBridge.pm    - in-memory artwork cache + fallback resolution
#

package Plugins::SlimPing::Core::VirtualPlayer;

use strict;
use warnings;

use Slim::Player::HTTP;
use Slim::Web::HTTP;
use Plugins::SlimPing::Core::Logging;
require Plugins::SlimPing::Core::Container;
require Plugins::SlimPing::Core::PipelinePool;
require Plugins::SlimPing::Core::VirtualPlayer::StreamingClient;
require Plugins::SlimPing::Core::VirtualPlayer::RemoteGovernor;
require Plugins::SlimPing::Core::VirtualPlayer::StreamEnricher;
require Plugins::SlimPing::Core::VirtualPlayer::PlayerCleanup;
require Plugins::SlimPing::Core::VirtualPlayer::ArtworkBridge;

my $log          = Plugins::SlimPing::Core::Logging->getLogger();
my $prefs        = Plugins::SlimPing::Core::Logging->getPrefs();
my $server_prefs = Plugins::SlimPing::Core::Logging->getServerPrefs();

# Monotonic counter for unique virtual player addresses.  LMS's
# Slim::Player::Client::new asserts no duplicate IDs exist, so we append a
# per-request counter to guarantee uniqueness even for re-requests of the
# same track.  Old players are cleaned up by LMS's forgetClient on disconnect.
my $REQUEST_ID = 0;

# No persistent player registry -- see docs/transcoding.md for the rationale.
# Every HTTP request creates a fresh Slim::Player::HTTP that dies with its
# socket.  Sharing state between requests fails for real clients because they
# open parallel connections for probes, previews and audio simultaneously, and
# any rebind/destroy logic ends up interfering with playback on a sibling
# connection.

# Maximum MP3 output bitrate LMS produces.  Used as the default when no
# explicit bitrate cap is requested.  Referenced by Stream.pm:_getTranscodeDecision
# for the transcodeStream estimate.
use constant MAX_OUTPUT_BITRATE => 320;

# Public API -- orchestrators

sub _governRemoteStream {
    my ($args) = @_;
    return unless $args->{is_remote};
    unless ( Plugins::SlimPing::Core::VirtualPlayer::RemoteGovernor::_checkRemoteRateLimit( $args->{username}, $args->{client_name} ) ) {
        return -1;
    }
    unless ( Plugins::SlimPing::Core::VirtualPlayer::RemoteGovernor::_acquireRemoteSlot( $args->{_address} ) ) {
        return 0;
    }
    return;
}

# Register DSD->MP3 transcode rules for a specific virtual player in LMS's
# commandTable.  Called from _buildPlayer each time a StreamingClient is
# created.  Uses the same per-client registration pattern as DSDPlayer's
# setupTranscoder (dsf-flc-*-<MAC>).  The rule is keyed by player ID so
# LMS can find it via exact hash lookup when building transcode profiles.

sub _buildPlayer {
    my ($args) = @_;
    my $paddr = getpeername( $args->{httpClient} );
    unless ($paddr) {
        $log->warn("SlimPing: getpeername failed for $args->{sq_id} -- client disconnected, aborting stream");
        return;
    }
    my $address = $args->{_address};

    my $client = Plugins::SlimPing::Core::StreamingClient->new( $address, $paddr, $args->{httpClient} );
    $client->init();
    $client->name( "SlimPing: $args->{client_name} ($args->{sq_id})" );
    $client->_setModel( _clientModel( $args->{client_name} ) );
    $client->_setLiveStream( $args->{is_live_stream} );

    $Slim::Web::HTTP::peerclient{ $args->{httpClient} } = $address;
    return $client;
}

sub _commitBitratePref {
    my ( $client, $output_br_kbps ) = @_;
    return unless $output_br_kbps > 0;
    my $target_br = $output_br_kbps == MAX_OUTPUT_BITRATE
      ? MAX_OUTPUT_BITRATE - 1
      : $output_br_kbps;
    $server_prefs->client($client)->set( 'transcodeBitrate', $target_br );
}

sub _writeResponseHeaders {
    my ($args) = @_;
    my $response         = $args->{response};
    my $output_br_kbps   = $args->{output_br_kbps};
    my $size_bytes       = $args->{size_bytes};
    my $want_cl          = $args->{want_cl};
    my $range_byte_start = $args->{range_byte_start};
    my $is_download      = $args->{is_download};
    my $format           = $args->{format};
    my $is_live_stream   = $args->{is_live_stream};

    my $output_mime = Plugins::SlimPing::Core::Container->get('library_mapper')->outputMime();

    # NOTE: This 206 code path serves direct-play (non-transcoded) responses
    # where the caller has already determined the resource is seekable.
    # Transcode pipeline responses route through AudioDelivery.pm which sets
    # Accept-Ranges: none and never passes range_byte_start here.
    if ( defined $size_bytes && $size_bytes > 0 && $want_cl ) {
        if ( defined $range_byte_start && $range_byte_start < $size_bytes ) {
            $response->code(206);
            $response->header( 'Accept-Ranges'  => 'bytes' );
            $response->header( 'Content-Range'  => "bytes $range_byte_start-" . ( $size_bytes - 1 ) . "/$size_bytes" );
            $response->header( 'Content-Length' => $size_bytes - $range_byte_start );
        }
        else {
            $response->code(200);
            # Let the caller control Accept-Ranges -- AudioDelivery sets
            # 'none' for transcode, 'bytes' for direct serve.
            $response->header( 'Content-Length' => $size_bytes );
        }
    }
    elsif ( defined $range_byte_start && defined $size_bytes && $size_bytes > 0 ) {
        $response->code(206);
        $response->header( 'Content-Range'  => "bytes $range_byte_start-" . ( $size_bytes - 1 ) . "/$size_bytes" );
        $response->header( 'Content-Length' => $size_bytes - $range_byte_start );
    }
    else {
        $response->code(200);
    }

    $response->header( 'Content-Type' => $output_mime );
    $response->header( 'Connection'   => 'close' );

    if ($is_live_stream) {
        if ( $args->{stream_name} ) {
            my $safe_name = $args->{stream_name};
            $safe_name =~ s/[\x00-\x1f\x7f]//g;
            $response->header( 'icy-name' => $safe_name ) if length $safe_name;
        }
        $response->header( 'icy-br'          => $output_br_kbps )         if $output_br_kbps;
        $response->header( 'icy-genre'       => $args->{meta}{genre} )   if $args->{meta} && $args->{meta}{genre};
        $response->header( 'icy-url'         => $args->{icy_url} )       if $args->{icy_url};
        $response->header( 'icy-description' => $args->{icy_desc} )      if $args->{icy_desc};
        $response->header( 'icy-metaint'     => 32768 )                  if $args->{enable_icy};
        $response->header( 'icy-year'        => $args->{meta}{year} )    if $args->{meta} && $args->{meta}{year};
    }

    if ($is_download) {
        my $ext = $format || 'mp3';
        $response->header( 'Content-Disposition' => qq{attachment; filename="download.$ext"} );
    }
    else {
        $response->header( 'Content-Disposition' => 'inline' );
    }

    return $output_mime;
}

sub _startPlayback {
    my ( $client, $args ) = @_;
    my $httpClient     = $args->{httpClient};
    my $response       = $args->{response};
    my $source_url     = $args->{source_url};
    my $time_offset    = $args->{time_offset};
    my $enable_icy     = $args->{enable_icy};
    my $output_mime    = $args->{_output_mime};
    my $output_br_kbps = $args->{output_br_kbps};
    my $size_bytes     = $args->{size_bytes};
    my $is_remote      = $args->{is_remote};
    my $is_live_stream = $args->{is_live_stream};
    my $is_download    = $args->{is_download};
    my $sq_id          = $args->{sq_id};
    my $client_name    = $args->{client_name};

    # Initiate pre-buffer priming for transcode streams so the client
    # receives a healthy initial burst and the transcode pipeline has
    # time to warm up.  Skipped for downloads (file transfer, not playback)
    # and live streams (low-latency relay, no transcode startup).
    unless ( $is_download || $is_live_stream ) {
        Plugins::SlimPing::Core::VirtualPlayer::StreamingClient::_initPrimeBuffer( $client->id );
    }

    my $headers = Slim::Web::HTTP::_stringifyHeaders($response) . "\x0d\x0a";

    # LMS auto-sets sendMetaData from the Icy-MetaData request header
    # (Slim/Web/HTTP.pm:557-558).  Align injection with enable_icy so
    # the body matches what the response headers promise.
    if ($enable_icy) {
        $Slim::Web::HTTP::sendMetaData{$httpClient}  = 1;
        $Slim::Web::HTTP::metaDataBytes{$httpClient} = -length($headers);
    } else {
        $Slim::Web::HTTP::sendMetaData{$httpClient} = 0;
        # The pool-check block in radioStream may have leaked icy-metaint
        # onto the response object.  Strip it so the client does not
        # expect ICY blocks that will never arrive.
        $response->remove_header('icy-metaint');
    }

    delete $Slim::Web::HTTP::keepAlives{$httpClient};
    Slim::Utils::Timers::killTimers( $httpClient, \&Slim::Web::HTTP::closeHTTPSocket );

    # Populate the playlist and start playback BEFORE addStreamingResponse so
    # the player is in 'play' mode with a non-empty playlist when LMS's
    # sendStreamingResponse first fires.  If the playlist is empty on the
    # first poll, LMS enters its silence path and queues silence MP3 frames
    # instead of calling nextChunk -- the client hears silence and the
    # transcode pipeline never starts.
    # Suppress LMS's native playlist persistence for this ephemeral player.
    # modifyPlaylistCallback (Slim::Player::Playlist:1155) skips the
    # clientplaylist_*.m3u write when startupPlaylistLoading is true,
    # and resets the flag to 0 after the sync-group loop completes.
    # Without this, every streamViaPipeline call creates a unique
    # player ID (monotonic counter) and a corresponding M3U file that
    # nothing ever cleans up.
    $client->startupPlaylistLoading(1);

    $client->execute( [ 'playlist', 'add', $source_url ] );

    # Seek-aware playback: use playlist jump instead of playmode when
    # timeOffset is requested, because playmode('play', { timeOffset => N })
    # passes index => undef through the state machine.  With index undef,
    # _getNextTrack hits the playlist-cloning check (Song.pm:643) which can
    # silently drop seekdata if the streamingSong is a playlist.  The
    # canonical LMS pattern is execute(['playlist', 'jump', 0, 0, 0,
    # { timeOffset => N }]) which carries an explicit index and routes
    # seekdata through the standard playlistJumpCommand dispatch.
    if ( $time_offset > 0 ) {
        $log->info(
            sprintf(
                'SlimPing: seek via playlist jump: client=%s offset=%s source=%s',
                $client->id(), $time_offset, $source_url
            )
        );
        $client->execute(
            [ 'playlist', 'jump', 0, 0, 0, { timeOffset => $time_offset } ] );
    }
    else {
        $log->debug(
            sprintf(
                'SlimPing: play without seek: client=%s source=%s',
                $client->id(), $source_url
            )
        );
        $client->execute( [ 'play' ] );
    }

    # Pre-seed ICY stream title with "<Station> - Connecting..." so ICY-capable
    # clients see a meaningful status during the cold-start period rather than
    # an empty or stale title.  Overwritten by _enrichTick as soon as the real
    # stream title arrives from the station.
    if ( $is_live_stream && $enable_icy && $args->{stream_name} ) {
        require Slim::Music::Info;
        Slim::Music::Info::setCurrentTitle(
            $source_url, $args->{stream_name} . ' - Connecting...' );
    }

    Slim::Web::HTTP::addStreamingResponse( $httpClient, $headers );

    # addStreamingResponse sets the TCP send buffer to 65536 bytes
    # (MAXCHUNKSIZE * 2).  Some clients never drain buffer contents,
    # so audio is stuck in the kernel buffer until socket close.
    # Apply client-specific socket quirks to resize as needed.
    my $quirks = $args->{_client_quirks};
    if ( $quirks && $quirks->{sndbuf_bytes} ) {
        require Socket;
        setsockopt( $httpClient, Socket::SOL_SOCKET, Socket::SO_SNDBUF, $quirks->{sndbuf_bytes} );
    }

    $log->debug(
        sprintf(
            'SlimPing: pipeline headers id=%s client=%s icy_req=%d cl=%s ct=%s out_br=%d size=%s remote=%d live=%d',
            $sq_id, $client_name, $enable_icy, ( $response->header('Content-Length') // 'none' ),
            $output_mime, $output_br_kbps, ( defined $size_bytes ? $size_bytes : 'unknown' ),
            $is_remote, $is_live_stream
        )
    );
}

sub _registerPoolPrimary {
    my ( $client, $args ) = @_;
    my $is_live_stream = $args->{is_live_stream};
    my $is_remote      = $args->{is_remote};
    my $source_url     = $args->{source_url};
    my $output_br_kbps = $args->{output_br_kbps};
    my $sq_id          = $args->{sq_id};

    if ( $is_live_stream && $is_remote && $args->{artwork_cache_key} ) {
        Plugins::SlimPing::Core::PipelinePool->registerPrimary(
            pool_type  => 'radio',
            source_url => $source_url,
            br_kbps    => $output_br_kbps,
            player     => $client,
            httpClient => $args->{httpClient},
        );
        $log->debug("SlimPing: pool primary registered for $sq_id");
    }

    if ( !$is_live_stream && $is_remote ) {
        Plugins::SlimPing::Core::PipelinePool->registerPrimary(
            pool_type   => 'track',
            source_url  => $source_url,
            br_kbps     => $output_br_kbps,
            player      => $client,
            httpClient  => $args->{httpClient},
            time_offset => $args->{time_offset},
        );
        $log->debug("SlimPing: track pool primary registered for $sq_id");
    }
}

sub streamViaPipeline {
    my %args = @_;

    Plugins::SlimPing::Core::VirtualPlayer::PlayerCleanup::_registerCleanupHandler();

    $args{client_name}      ||= 'unknown';
    $args{format}           ||= '';
    $args{time_offset}      //= 0;
    $args{output_br_kbps}   //= 0;
    $args{duration_s}       //= 0;
    $args{is_live_stream}   //= 0;
    $args{username}         ||= '_anon';
    $args{cue_offset_bytes} //= 0;
    $args{cue_duration_s}   //= 0;

    my $request = $args{response}->request();
    $args{enable_icy} = $args{is_live_stream} && $request && $request->header('Icy-MetaData') ? 1 : 0;

    # Apply client-specific quirks for this stream.
    if ( $request ) {
        my $ua = $request->header('User-Agent') || '';
        my $quirks = Plugins::SlimPing::Core::ClientQuirks->quirks_for_client(
            $ua, $args{client_name}
        );
        if ( defined $quirks->{enable_icy} && !$quirks->{enable_icy} ) {
            $args{enable_icy} = 0;
            $log->info("SlimPing: ICY disabled for $args{client_name} client");
        }
        $args{_client_quirks} = $quirks;   # carry through to _startPlayback
    }
    $args{want_cl} = $args{want_cl} ? 1 : 0;

    $args{_address} = "slimping-" . $args{sq_id} . "-" . $REQUEST_ID++;

    my $governed = _governRemoteStream( \%args );
    return $governed if defined $governed;

    my $client = _buildPlayer( \%args )
      or return;

    _commitBitratePref( $client, $args{output_br_kbps} );
    $args{_output_mime} = _writeResponseHeaders( \%args );
    _startPlayback( $client, \%args );

    # Register this stream for cache population (downloads do not populate).
    require Plugins::SlimPing::Core::TranscodeCache;
    unless ( $args{is_download} ) {
        Plugins::SlimPing::Core::TranscodeCache->getInstance->registerStream(
            $client->id, $args{sq_id}, $args{output_br_kbps},
            $args{size_bytes} // 0
        );
    }

    _registerPoolPrimary( $client, \%args );
    Plugins::SlimPing::Core::VirtualPlayer::StreamEnricher::_scheduleEnrichment( $client, \%args );
    Plugins::SlimPing::Core::VirtualPlayer::StreamEnricher::_scheduleCueStop( $client, \%args );
    Plugins::SlimPing::Core::VirtualPlayer::StreamEnricher::_scheduleLocalMetaInjection( $client, \%args );

    $log->debug(
        sprintf(
            'SlimPing: virtual player stream %s fmt=%s out_br=%d remote=%d (client=%s)',
            $args{sq_id}, $args{format} || 'auto',
            $args{output_br_kbps}, $args{is_remote}, $args{client_name}
        )
    );

    return;
}

# Normalise a Subsonic client name into a safe convert.conf clienttype token.
# Strips non-alphanumeric characters, lowercases, and prefixes with 'slimping-'.
# Returns undef for generic/unknown clients so the default 'slimping' model is used.
#
# Clients with custom convert.conf rules need their own rules keyed to the
# token this function returns (e.g. slimping-symfonium for client 'Symfonium').
sub _clientModel {
    my ($client_name) = @_;
    return undef unless defined $client_name && length $client_name;
    $client_name = lc($client_name);

    # Share streams use the slimping-share model so the slimping-share
    # convert.conf rules apply (faster LAME preset -q 5 for concurrent
    # visitor throughput, otherwise identical to the generic slimping rules).
    return 'slimping-share' if index( $client_name, 'share:' ) == 0;

    # Internet-radio favourites use the slimping-radio model so the
    # slimping-radio convert.conf rules apply (live-stream quality preset
    # -q 2, no seek capabilities for the live-source case).
    return 'slimping-radio' if $client_name eq 'radio';

    # All other clients use the base 'slimping' model.
    #
    # We previously produced per-client model strings (e.g. slimping-symfonium,
    # slimping-substreamer8) with the intention of supporting per-client
    # convert.conf overrides if a client ever needed format-specific quirks.
    # In practice that capability was never used, and per-client model strings
    # actively broke the generic slimping rules because LMS's
    # TranscodingHelper does exact-string match on the convert.conf
    # clienttype field: 'slimping-substreamer8' does NOT match a rule
    # registered for 'slimping'.  Real clients never matched our CBR rules
    # and silently fell back to system ABR encoding.
    #
    # Returning undef here makes the model() override (line ~152) default
    # to 'slimping', so the generic '<format> mp3 slimping *' rules apply
    # uniformly across every client.  If we ever need a per-client quirk in
    # convert.conf, the right pattern is to special-case THAT client here
    # (like the share/radio carve-outs above) rather than reverting to the
    # per-client-model-by-default behaviour.
    return undef;
}

# Shared stream-handler helpers

# Extract remote IP for rate-limit and audit purposes.  Honours the trust_xff
# pref so operators behind a reverse proxy get accurate source-IP evaluation
# on unauth'd stream endpoints (shareStream, shareMetadata, radioMetadata).
sub remoteIp {
    my ( $class, $httpClient, $request ) = @_;

    my $prefs = Plugins::SlimPing::Core::Logging->getPrefs();
    if ( $prefs->get('trust_xff') && $request ) {
        if ( my $xff = $request->header('X-Forwarded-For') ) {
            my ($first) = split /\s*,\s*/, $xff;
            return $first if defined $first && length $first;
        }
    }

    return $httpClient && $httpClient->can('peerhost')
      ? ( $httpClient->peerhost() // '-' )
      : '-';
}

# Send a plain HTTP error for unauth'd stream endpoints (shareStream,
# shareMetadata, radioMetadata) and radio-ID errors on stream.view.
# These are NOT Subsonic API endpoints -- they carry their own credential
# or are publicly shareable URLs -- and must not leak server implementation
# details via the Subsonic XML/JSON error envelope.
#
# Subsonic code to HTTP status mapping:
#   0  -> 501 (not implemented / feature disabled)
#   10 -> 400 (missing required parameter)
#   40 -> 429 (rate limited)
#   70 -> 404 (not found / expired / out of range)
sub sendStreamError {
    my ( $class, $httpClient, $response, $subsonic_code, $msg ) = @_;

    my %code_to_http = (
        0  => 501,
        10 => 400,
        40 => 429,
        70 => 404,
    );
    my $http_code = $code_to_http{$subsonic_code} // 400;

    $response->code($http_code);
    $response->header( 'Content-Type'   => 'text/plain; charset=utf-8' );
    $response->header( 'Content-Length' => length($msg) );
    Slim::Web::HTTP::addHTTPResponse( $httpClient, $response, \$msg );
}

# --- Forwarders to sub-modules ------------------------------------------------

# RemoteGovernor forwarders
sub _checkRemoteRateLimit {
    return Plugins::SlimPing::Core::VirtualPlayer::RemoteGovernor::_checkRemoteRateLimit(@_);
}

sub _acquireRemoteSlot {
    return Plugins::SlimPing::Core::VirtualPlayer::RemoteGovernor::_acquireRemoteSlot(@_);
}

sub _releaseRemoteSlot {
    return Plugins::SlimPing::Core::VirtualPlayer::RemoteGovernor::_releaseRemoteSlot(@_);
}

sub _reconcileRemoteSlots {
    return Plugins::SlimPing::Core::VirtualPlayer::RemoteGovernor::_reconcileRemoteSlots();
}

sub remoteInFlight {
    return Plugins::SlimPing::Core::VirtualPlayer::RemoteGovernor::remoteInFlight();
}

sub remoteDroppedCount {
    return Plugins::SlimPing::Core::VirtualPlayer::RemoteGovernor::remoteDroppedCount();
}

# PlayerCleanup forwarders
sub cleanupDisconnectedPlayers {
    return Plugins::SlimPing::Core::VirtualPlayer::PlayerCleanup::cleanupDisconnectedPlayers();
}

sub cleanupAllPlayers {
    return Plugins::SlimPing::Core::VirtualPlayer::PlayerCleanup::cleanupAllPlayers();
}

sub _sweepOrphanedPlaylistFiles {
    return Plugins::SlimPing::Core::VirtualPlayer::PlayerCleanup::_sweepOrphanedPlaylistFiles();
}

# ArtworkBridge forwarders
sub getArtworkFromCache {
    return Plugins::SlimPing::Core::VirtualPlayer::ArtworkBridge::getArtworkFromCache(@_);
}

sub resolveCoverArtForTrack {
    return Plugins::SlimPing::Core::VirtualPlayer::ArtworkBridge::resolveCoverArtForTrack(@_);
}

sub getArtworkFromLivePlayer {
    return Plugins::SlimPing::Core::VirtualPlayer::ArtworkBridge::getArtworkFromLivePlayer(@_);
}

sub getArtworkFromTrackId {
    return Plugins::SlimPing::Core::VirtualPlayer::ArtworkBridge::getArtworkFromTrackId(@_);
}

sub readDefaultArtwork {
    return Plugins::SlimPing::Core::VirtualPlayer::ArtworkBridge::readDefaultArtwork(@_);
}

1;
