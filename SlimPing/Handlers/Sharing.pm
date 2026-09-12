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
# Handlers/Sharing.pm - Share CRUD and streaming handlers for SlimPing
#
# Registers OpenSubsonic share endpoints (createShare, getShares, updateShare,
# deleteShare) and the unauthenticated shareStream endpoint.  All persistence
# is delegated to Core::ShareStore.
#

package Plugins::SlimPing::Handlers::Sharing;

use strict;
use warnings;

use Slim::Player::Client;
use Slim::Player::HTTP;
use Time::HiRes qw(time);
use Plugins::SlimPing::API::Router;
use Plugins::SlimPing::Core::Logging;
require Plugins::SlimPing::Core::Container;
require Plugins::SlimPing::Core::StreamGate;
require Plugins::SlimPing::Core::TranscodeEstimate;
require Plugins::SlimPing::Core::VirtualPlayer;
require Plugins::SlimPing::Core::DebugThrottle;
require Plugins::SlimPing::Handlers::SharePage;
require Plugins::SlimPing::Utils::Errors;
require Plugins::SlimPing::Utils::Params;

my $log   = Plugins::SlimPing::Core::Logging->getLogger();
my $prefs = Plugins::SlimPing::Core::Logging->getPrefs();

sub registerHandlers {
    my $class = shift;
    Plugins::SlimPing::API::Router->registerHandler( 'createShare',
        \&createShare );
    Plugins::SlimPing::API::Router->registerHandler( 'getShares',
        \&getShares );
    Plugins::SlimPing::API::Router->registerHandler( 'updateShare',
        \&updateShare );
    Plugins::SlimPing::API::Router->registerHandler( 'deleteShare',
        \&deleteShare );
    Plugins::SlimPing::API::Router->registerStreamHandler( 'shareStream',
        \&shareStream );
    Plugins::SlimPing::API::Router->registerStreamHandler( 'shareMetadata',
        \&shareMetadata );
}

# --- Standard handlers (Subsonic-envelope, auth'd) ---

sub createShare {
    my ($args) = @_;
    my $p    = $args->{params};
    my $user = $args->{user};

    require Plugins::SlimPing::Auth::Permissions;
    if ( my $err =
        Plugins::SlimPing::Auth::Permissions->requireRole( $user, 'shareRole' ) )
    {
        return $err;
    }
    return Plugins::SlimPing::Utils::Errors->error(50, 'Not authorised')
        if $user->{username} eq '_anon';

    my @ids = Plugins::SlimPing::Utils::Params->multiParam($p->{id});
    unless (@ids) {
        return Plugins::SlimPing::Utils::Errors->missingParam('id');
    }

    my $description = $p->{description} // '';
    $description =~ tr/+/ /;    # decode form-encoding at input boundary

    # expires is a Unix timestamp (seconds or milliseconds since epoch).
    # Convert to a relative TTL so ShareStore can clamp it against server bounds.
    # A value of 0 or "never" from the client means "use the server default."
    my $ttl = _expiresToTtl($p->{expires});

    # Validate all IDs and expand album/playlist entries to constituent tracks.
    # Expansion happens before cap checks so the entry count reflects the real
    # number of stored entries.
    my $mapper = Plugins::SlimPing::Core::Container->get('library_mapper');
    my @entry_ids;
    for my $sq_id (@ids) {
        my ( $type ) = $mapper->decodeId($sq_id);
        unless ($type) {
            return Plugins::SlimPing::Utils::Errors->error(70, "Unknown ID: $sq_id");
        }
        if ( $type eq 'album' ) {
            my $tracks = $mapper->getTracksByAlbum($sq_id);
            unless ( $tracks && @$tracks ) {
                return Plugins::SlimPing::Utils::Errors->error(70, "Album is empty: $sq_id");
            }
            push @entry_ids, map { $_->{id} } @$tracks;
        }
        else {
            push @entry_ids, $sq_id;
        }
    }
    @ids = @entry_ids;

    my $share_row = _shareStore()->createShare(
        $user->{username}, \@ids, $description, $ttl
    );
    return $share_row if $share_row->{error};

    my $shaped = _shareStore()->shapeShare($share_row);
    _addShareUrl($shaped);
    return { shares => { share => [$shaped] } };
}

sub getShares {
    my ($args) = @_;
    my $shares = _shareStore()->getShares( $args->{user}{username} );
    _addShareUrl($_) for @$shares;
    return { shares => { share => $shares } };
}

sub updateShare {
    my ($args) = @_;
    my $p    = $args->{params};
    my $user = $args->{user};

    my $token = $p->{id}
      or return Plugins::SlimPing::Utils::Errors->missingParam('id');

    my $share = _shareStore()->getShareByToken($token)
      or return Plugins::SlimPing::Utils::Errors->notFound('Share');

    # Creator or admin only
    unless ( $user->{admin} || $share->{username} eq $user->{username} ) {
        return Plugins::SlimPing::Utils::Errors->notAuthorised();
    }

    my $description = $p->{description};
    $description =~ tr/+/ / if defined $description;
    my $new_ttl = _expiresToTtl($p->{expires});

    _shareStore()->updateShare( $token, $description, $new_ttl );
    return {};
}

sub deleteShare {
    my ($args) = @_;
    my $p    = $args->{params};
    my $user = $args->{user};

    my $token = $p->{id}
      or return Plugins::SlimPing::Utils::Errors->missingParam('id');

    my $share = _shareStore()->getShareByToken($token)
      or return Plugins::SlimPing::Utils::Errors->notFound('Share');

    unless ( $user->{admin} || $share->{username} eq $user->{username} ) {
        return Plugins::SlimPing::Utils::Errors->notAuthorised();
    }

    _shareStore()->deleteShare($token);
    return {};
}

# --- Stream handler (no auth gate -- share token is the credential) ---

sub shareStream {
    my ( $httpClient, $response, $args ) = @_;
    my $p = $args->{params};

    # Gate 1: Feature toggle
    return
      if Plugins::SlimPing::Core::StreamGate->requireFeature(
        $httpClient, $response, 'feature_sharing', 'shareStream' );

    # Gate 2: Rate-limit gate
    my ($ip) =
      Plugins::SlimPing::Core::StreamGate->gateIp( $httpClient, $response,
        $response->request() )
      or return;

    # Gate 3: Extract share token
    my ($token) =
      Plugins::SlimPing::Core::StreamGate->requireParam(
        httpClient => $httpClient, response => $response,
        ip => $ip, value => $p->{share}, param_name => 'share' )
      or return;

    # Gate 4: Validate share token (DB lookup -- not HMAC, unlike radio)
    my $share = _shareStore()->getShareByToken($token);
    unless ( $share && ref $share->{entry} eq 'ARRAY' && @{ $share->{entry} } ) {
        require Plugins::SlimPing::Auth::RateLimit;
        Plugins::SlimPing::Auth::RateLimit->recordFailure( $ip, '_anon' );
        Plugins::SlimPing::Auth::RateLimit->recordFailure( $ip, "share:$token" );
        Plugins::SlimPing::Core::VirtualPlayer->sendStreamError( $httpClient, $response, 70,
            'Share not found or expired' );
        return;
    }

    # Success -- clear rate-limit cooldown
    Plugins::SlimPing::Core::StreamGate->clearGate($ip);

    # Concurrent listener cap -- count active LMS virtual players with the
    # share prefix.  Zombies from aborted streams are excluded by checking
    # connected() in _countPlayersByPrefix.  A close-handler registered in
    # VirtualPlayer.pm eventually calls forgetClient on disconnected players.
    my $player_prefix = "slimping-share-$token";
    my $max_listeners = $prefs->get('share_max_listeners');
    my $current       = _countPlayersByPrefix($player_prefix);
    if ( $current >= $max_listeners ) {
        Plugins::SlimPing::Core::VirtualPlayer->sendStreamError( $httpClient, $response, 70,
            'Share has reached its listener limit' );
        return;
    }

    # Record visit (immediate SQLite durability)
    _shareStore()->recordVisit($token);

    # IP diversity tracking (auto-revoke on threshold)
    my $unique_ips = _shareStore()->recordIp( $token, $ip );

    # Audit log (rate-limited: once per 60s per share).  Token is truncated
    # in log messages -- the full token is a bearer credential.
    my $token_short = substr($token, 0, 4) . '...';
    Plugins::SlimPing::Core::DebugThrottle->debugRateLimited(
        "share_access_$token",
        sprintf( "SlimPing: share access token=%s ip=%s (%d unique IPs)",
            $token_short, $ip, $unique_ips ),
        60
    );

    # Three-way dispatch when no specific track is requested:
    #   ?playlist=1  -> M3U playlist (even for single-entry shares)
    #   (no params)  -> HTML share page
    #   ?track=N     -> falls through to direct audio stream below
    $log->info(
        sprintf(
            'SlimPing: share access diagnostics token=%s track_defined=%d entry_ref=%s entry_count=%d',
            substr( $token, 0, 4 ),
            defined( $p->{track} ) ? 1 : 0,
            ref( $share->{entry} ) || 'scalar',
            ref( $share->{entry} ) eq 'ARRAY' ? scalar( @{ $share->{entry} } ) : -1
        )
    );
    if ( !defined $p->{track} ) {
        if ( $p->{playlist} ) {
            _serveM3uPlaylist( $httpClient, $response, $share );
            return;
        }
        Plugins::SlimPing::Handlers::SharePage::serveSharePage( $httpClient, $response, $share );
        return;
    }

    my $track_idx  = int( $p->{track} // 0 );
    my $max_idx    = $#{ $share->{entry} };
    if ( $track_idx < 0 || $track_idx > $max_idx ) {
        Plugins::SlimPing::Core::VirtualPlayer->sendStreamError( $httpClient, $response, 70,
            'Track index out of range' );
        return;
    }
    my $entry        = $share->{entry}[$track_idx];
    my $sq_id        = $entry->{id};
    my $max_bitrate  = $prefs->get('share_max_bitrate');

    require Plugins::SlimPing::Handlers::Stream::AudioDelivery;
    my $d = Plugins::SlimPing::Handlers::Stream::AudioDelivery::resolveTrack(
        $httpClient, $response, $args,
        { id => $sq_id, max_bitrate => $max_bitrate, format => '' }
    ) or return;

    my $track        = $d->{track};
    my $stream_info  = $d->{stream_info};
    my $estimate     = $d->{estimate};
    my $time_offset  = $d->{time_offset};
    my $range_byte_start = $d->{range_byte_start};

    my $req = $response->request();
    if ( $req && $req->header('Range') ) {
        $req->remove_header('Range');
    }

    my $meta;
    if ($entry->{artist} || $entry->{title}) {
        $meta = {};
        $meta->{artist} = $entry->{artist} if $entry->{artist};
        $meta->{title}  = $entry->{title}  if $entry->{title};
        $meta->{album}  = $entry->{album}  if $entry->{album};
        $meta->{genre}  = $entry->{genre}  if $entry->{genre};
        $meta->{year}   = $entry->{year}   if $entry->{year};
    }

    (my $safe_username = $share->{username}) =~ s/[\x00-\x1f\x7f]//g;
    my $desc = $share->{description} || $safe_username;
    my $stream_name = "SlimPing Share by $safe_username";

    my $base = Plugins::SlimPing::Core::LibraryMapper->_requestBaseUrl() || '';
    $base =~ s/[\x0d\x0a]//g;
    my $icy_url = "$base/rest/shareMetadata.view?share=$token&track=$track_idx";

    my $started = Plugins::SlimPing::Core::VirtualPlayer::streamViaPipeline(
        httpClient        => $httpClient,
        response          => $response,
        source_url        => $stream_info->{url},
        sq_id             => "share-$token",
        client_name       => "share: $desc",
        format            => '',
        time_offset       => $time_offset,
        is_download       => 0,
        is_remote         => $stream_info->{is_remote},
        output_br_kbps    => $estimate ? $estimate->{output_br_kbps} : 0,
        size_bytes        => $estimate ? $estimate->{size_bytes}     : undef,
        duration_s        => $estimate ? $estimate->{duration_s}     : 0,
        range_byte_start  => $range_byte_start,
        want_cl           => 1,
        meta              => $meta,
        stream_name       => $stream_name,
        icy_url           => $icy_url,
        icy_description   => $stream_name,
        artwork_cache_key => "$token:$track_idx",
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

# --- Metadata handler (no auth gate -- share token is the credential) ---

sub shareMetadata {
    my ( $httpClient, $response, $args ) = @_;
    my $p = $args->{params};

    # Gate 1: Feature toggle
    return
      if Plugins::SlimPing::Core::StreamGate->requireFeature(
        $httpClient, $response, 'feature_sharing', 'shareMetadata' );

    # Gate 2: Rate-limit gate
    my ($ip) =
      Plugins::SlimPing::Core::StreamGate->gateIp( $httpClient, $response,
        $response->request() )
      or return;

    # Gate 3: Extract share token
    my ($token) =
      Plugins::SlimPing::Core::StreamGate->requireParam(
        httpClient => $httpClient, response => $response,
        ip => $ip, value => $p->{share}, param_name => 'share' )
      or return;

    # Gate 4: Validate share token
    my $share = _shareStore()->getShareByToken($token);
    unless ( $share && ref $share->{entry} eq 'ARRAY' && @{ $share->{entry} } ) {
        require Plugins::SlimPing::Auth::RateLimit;
        Plugins::SlimPing::Auth::RateLimit->recordFailure( $ip, '_anon' );
        Plugins::SlimPing::Auth::RateLimit->recordFailure( $ip, "share_meta:$token" );
        Plugins::SlimPing::Core::VirtualPlayer->sendStreamError( $httpClient, $response, 70, 'Share not found or expired' );
        return;
    }
    Plugins::SlimPing::Core::StreamGate->clearGate($ip);

    # Select entry by index
    my $track_idx = int( $p->{track} // 0 );
    my $max_idx   = $#{ $share->{entry} };
    if ( $track_idx < 0 || $track_idx > $max_idx ) {
        Plugins::SlimPing::Core::VirtualPlayer->sendStreamError( $httpClient, $response, 70, 'Track index out of range' );
        return;
    }

    # Record visit and IP diversity (metadata reads count as visits)
    _shareStore()->recordVisit($token);
    my $unique_ips = _shareStore()->recordIp( $token, $ip );

    my $token_short = substr($token, 0, 4) . '...';
    Plugins::SlimPing::Core::DebugThrottle->debugRateLimited(
        "share_meta_$token",
        sprintf( "SlimPing: share metadata token=%s ip=%s track=%d (%d unique IPs)",
            $token_short, $ip, $track_idx, $unique_ips ),
        60
    );

    # Artwork: read whatever LMS resolved for the player -- $song->coverArt()
    # from the live virtual player is the canonical answer.  Only when no
    # player is active do we fall back to the timer-populated cache or the
    # shipped default icon.  Valid tokens must never 404 here.
    my ( $body, $content_type );

    # Path A: On-demand live player lookup -- reads artwork from the currently
    # streaming virtual player, including plugin-injected artwork (BBC Sounds,
    # etc.) that LMS resolved through its native chain.
    ( $body, $content_type ) =
      Plugins::SlimPing::Core::VirtualPlayer->getArtworkFromLivePlayer(
        "slimping-share-$token", "$token:$track_idx" );

    # Path B: Timer-populated cache -- same $song->coverArt() data from the
    # streaming timer callback (pre-stream or post-disconnect).
    unless ($body) {
        ( $body, $content_type ) =
          Plugins::SlimPing::Core::VirtualPlayer->getArtworkFromCache(
            "$token:$track_idx" );
    }

    # Path B2: Resolve artwork from the share entry when no player is streaming
    # (covers the HTML share page where the <img> tag requests artwork before
    # any track has been played).  Delegates to VirtualPlayer which owns all
    # artwork resolution paths.
    unless ($body) {
        my $entry = $share->{entry}[$track_idx];
        if ( $entry && $entry->{id} ) {
            my $mapper = Plugins::SlimPing::Core::Container->get('library_mapper');
            my ( undef, $track_raw ) = $mapper->decodeId( $entry->{id} );
            if ($track_raw) {
                ( $body, $content_type ) =
                  Plugins::SlimPing::Core::VirtualPlayer->getArtworkFromTrackId($track_raw);
            }
        }
    }

    # Path C: Shipped default music icon -- absolute last resort.
    unless ($body) {
        ( $body, $content_type ) =
          Plugins::SlimPing::Core::VirtualPlayer->readDefaultArtwork('share');
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
}

# --- Admin delegation (called by AdminApi.pm, not registered as endpoints) ---

sub getAllShares {
    my $shares = _shareStore()->getAllShares();
    _addShareUrl($_) for @$shares;
    return $shares;
}

sub revokeShare {
    my ( $class, $token ) = @_;
    return _shareStore()->revokeShare($token);
}

sub revokeAllShares {
    return _shareStore()->revokeAllShares();
}

# --- Private helpers ---

sub _shareStore {
    require Plugins::SlimPing::Core::ShareStore;
    return Plugins::SlimPing::Core::ShareStore->getInstance();
}

# Convert an expires value (Unix timestamp, seconds or milliseconds since epoch)
# to a relative TTL in seconds.  Returns undef when no expiry or zero/negative,
# meaning "use the server default."
sub _expiresToTtl {
    my ($expires) = @_;
    return undef unless defined $expires && $expires ne '';
    my $raw = int($expires);
    return undef unless $raw > 0;
    my $expires_epoch = $raw > 10_000_000_000 ? int( $raw / 1000 ) : $raw;
    my $ttl = $expires_epoch - time();
    return $ttl < 0 ? 0 : $ttl;
}

# Augment a share hashref with the share URL (baseUrl + token).
# The base URL is set by the Router on every request context.
sub _addShareUrl {
    my ($share) = @_;
    return unless $share && ref $share eq 'HASH' && $share->{id};
    my $base = Plugins::SlimPing::Core::LibraryMapper->_requestBaseUrl();
    $share->{url} = ($base || '') . '/rest/shareStream.view?share=' . $share->{id};

    # Per-entry stream URLs let clients navigate between tracks within a
    # shared album/playlist.  Each URL is clamped to the share's expiry.
    if ( $share->{entry} && ref $share->{entry} eq 'ARRAY' ) {
        for my $i ( 0 .. $#{ $share->{entry} } ) {
            $share->{entry}[$i]{streamUrl} =
              ($base || '') . '/rest/shareStream.view?share=' . $share->{id}
            . '&track=' . $i;
        }
    }
}

# Count active LMS virtual players whose ID starts with the given prefix.
# Only counts players that are actually connected -- LMS calls closeStreamingSocket
# on client disconnect but does NOT call forgetClient for HTTP players, leaving
# zombie entries in clients().  Excluding disconnected players prevents the
# listener cap from filling with stale entries after aborted streams.
sub _countPlayersByPrefix {
    my ($prefix) = @_;
    my $count = 0;
    for my $client ( Slim::Player::Client::clients() ) {
        next unless index( $client->id(), $prefix ) == 0;
        next
          if $client->isa('Slim::Player::HTTP')
          && !$client->connected();
        $count++;
    }
    return $count;
}

# Serve an M3U playlist for multi-track shares when no specific track is
# requested.  Each entry points to a per-track shareStream URL so clients
# (VLC, mpv, etc.) play all tracks sequentially without a separate request
# for each track transition.
sub _serveM3uPlaylist {
    my ( $httpClient, $response, $share ) = @_;

    my $base = Plugins::SlimPing::Core::LibraryMapper->_requestBaseUrl() || '';

    my @lines = ("#EXTM3U");

    for my $i ( 0 .. $#{ $share->{entry} } ) {
        my $entry = $share->{entry}[$i];
        my $title = $entry->{title} || 'Untitled';
        my $artist = $entry->{artist} || '';
        my $display = $artist ? "$artist - $title" : $title;
        my $duration = $entry->{duration} // 0;

        push @lines, "#EXTINF:$duration,$display";
        push @lines, "$base/rest/shareStream.view?share=$share->{id}&track=$i";
    }

    my $body = join("\n", @lines) . "\n";

    $response->code(200);
    $response->header( 'Content-Type'        => 'audio/x-mpegurl; charset=utf-8' );
    $response->header( 'Content-Length'      => length($body) );
    $response->header( 'Content-Disposition' => 'attachment; filename="playlist.m3u"' );
    Slim::Web::HTTP::addHTTPResponse( $httpClient, $response, \$body );
}

1;
