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
# Handlers/Stream/TranscodeDecision.pm - OpenSubsonic transcode-decision engine
#
# Extracted from Endpoints.pm.  Owns getTranscodeDecision, getTranscodeStream,
# direct-play profile matching, and the HMAC-signed transcodeParams token
# lifecycle.  Called from Endpoints::registerHandlers for endpoint registration
# and from Auth::Manager for HMAC key rotation.
#

package Plugins::SlimPing::Handlers::Stream::TranscodeDecision;

use strict;
use warnings;

use Time::HiRes  qw(time);
use Digest::SHA  qw(hmac_sha256_hex);
use MIME::Base64 qw(encode_base64url decode_base64url);
use JSON::XS     ();
require Plugins::SlimPing::API::Router;
require Plugins::SlimPing::Core::LibraryMapper;
require Plugins::SlimPing::Core::Logging;
require Plugins::SlimPing::Core::Container;
require Plugins::SlimPing::Core::TranscodeEstimate;
require Plugins::SlimPing::Utils::Errors;

my $log = Plugins::SlimPing::Core::Logging->getLogger();

sub registerHandlers {
    my $class = shift;
    Plugins::SlimPing::API::Router->registerHandler( 'getTranscodeDecision', \&_getTranscodeDecision, );
    Plugins::SlimPing::API::Router->registerStreamHandler( 'getTranscodeStream', \&_getTranscodeStream, );
}

# getTranscodeDecision -- OpenSubsonic extension endpoint that tells clients
# what the server can produce for a specific track before they request a stream.
# Clients POST their DirectPlayProfile list as a JSON body; we return whether
# the source can be served directly, what a transcode would look like (always
# MP3), and the real source format details.
sub _getTranscodeDecision {
    my ($args) = @_;
    my $p = $args->{params};

    my $sq_id = $p->{mediaId}
      or return Plugins::SlimPing::Utils::Errors->missingParam('mediaId');
    my $media_type = $p->{mediaType} || 'song';

    unless ( $media_type eq 'song' ) {
        return Plugins::SlimPing::Utils::Errors->error(0, "Unsupported mediaType: $media_type");
    }

    # Read JSON POST body (Router doesn't consume application/json bodies)
    my $request  = $args->{_response}->request();
    my $raw_body = $request->content() // '{}';
    use constant MAX_TRANSCODE_DECISION_BYTES => 65536;  # 64 KB
    if ( length($raw_body) > MAX_TRANSCODE_DECISION_BYTES ) {
        $log->warn(sprintf(
            'SlimPing: getTranscodeDecision body too large (%d bytes)',
            length($raw_body)
        ));
        return Plugins::SlimPing::Utils::Errors->error(0, 'Request body too large');
    }
    my $body = $raw_body;
    my $client_info;
    eval { $client_info = JSON::XS::decode_json($body); };
    if ($@) {
        $log->warn("SlimPing: getTranscodeDecision JSON parse error: $@");
        return Plugins::SlimPing::Utils::Errors->error(0, 'Invalid JSON body');
    }

    my $direct_play_profiles = $client_info->{directPlayProfiles}         // [];
    my $transcoding_profiles = $client_info->{transcodingProfiles}        // [];
    my $codec_profiles       = $client_info->{codecProfiles}              // [];
    my $max_audio_br         = $client_info->{maxAudioBitrate}            // 0;
    my $max_transcode_br     = $client_info->{maxTranscodingAudioBitrate} // 0;

    # Spec says these are in bps -- convert to kbps for internal use.
    $max_audio_br     = int( $max_audio_br / 1000 );
    $max_transcode_br = int( $max_transcode_br / 1000 );

    # Remember this client's declared caps so stream requests that omit
    # maxBitRate still get capped.  The hashes live in Endpoints.pm where
    # _serveAudio consumes them.
    #
    # Pass whether each field was explicitly present in the JSON body so
    # _rememberClientBitrateCap can distinguish "client set 0 = unlimited"
    # (clear the remembered cap) from "client omitted the field = no
    # preference stated" (leave the remembered cap untouched).
    Plugins::SlimPing::Handlers::Stream::Endpoints::_rememberClientBitrateCap({
        user               => $args->{user},
        client_name        => $args->{client_name},
        max_audio_br       => $max_audio_br,
        max_transcode_br   => $max_transcode_br,
        explicit_audio     => exists $client_info->{maxAudioBitrate},
        explicit_transcode => exists $client_info->{maxTranscodingAudioBitrate},
    });

    $log->debug(
        sprintf(
            'SlimPing: transcodeDecision client=%s profiles: dp=%d tp=%d cp=%d max_audio=%d max_transcode=%d',
            $sq_id,
            ( ref $direct_play_profiles eq 'ARRAY' ? scalar @$direct_play_profiles : 0 ),
            ( ref $transcoding_profiles eq 'ARRAY' ? scalar @$transcoding_profiles : 0 ),
            ( ref $codec_profiles eq 'ARRAY'       ? scalar @$codec_profiles       : 0 ),
            $max_audio_br,
            $max_transcode_br
        )
    );

    # Validate the sq_id can be decoded before attempting a track lookup.
    my $mapper = Plugins::SlimPing::Core::Container->get('library_mapper');
    my ( undef, $raw_id ) = $mapper->decodeId($sq_id);
    unless ( defined $raw_id ) {
        $log->info("SlimPing: getTranscodeDecision for unknown id=$sq_id");
        return Plugins::SlimPing::Utils::Errors->notFound('Track');
    }

    my $track = $mapper->getTrackById($sq_id)
      or return Plugins::SlimPing::Utils::Errors->notFound('Track');

    # --- sourceStream: real source file details ---
    # All fields are in the shaped track hashref from getTrackById/shapeTrack.
    my $suffix      = $track->{suffix} || '';
    my $src_br_kbps = $track->{bitRate}      // 0;
    my $channels    = $track->{channelCount} // 0;
    my $samplerate  = $track->{samplingRate} // 0;
    my $bitdepth    = $track->{bitDepth}     // 0;

    # Remote tracks (Spotify, TIDAL, etc.) often have NULL bitrate in the DB.
    # Resolve using the same content-type fallback as streamViaPipeline so the
    # transcode decision matches what the stream endpoint will actually deliver.
    unless ( $src_br_kbps && $src_br_kbps > 0 ) {
        $src_br_kbps = Plugins::SlimPing::Core::TranscodeEstimate->resolveSourceBitrate( 0, 1, $suffix );
    }

    my @transcode_reasons;

    # Map LMS short codes to canonical names (flc->flac).
    my $canonical     = $suffix eq 'flc' ? 'flac' : $suffix;
    my $source_stream = {
        protocol        => 'http',
        container       => $canonical,
        codec           => $canonical,
        audioBitrate    => $src_br_kbps ? 0 + int( $src_br_kbps * 1000 ) : undef,
        audioChannels   => $channels    ? int($channels)             : undef,
        audioSamplerate => $samplerate  ? int($samplerate)           : undef,
        audioBitdepth   => $bitdepth    ? int($bitdepth)             : undef,
    };

    # Strip undef keys -- JSON::XS encodes undef as null, but the spec says
    # absent keys are preferred over null values in StreamDetails.
    for my $k ( keys %$source_stream ) {
        delete $source_stream->{$k} unless defined $source_stream->{$k};
    }

    # --- directPlayProfile matching ---

    # --- Global maxAudioBitrate gate ---
    # The top-level maxAudioBitrate is a hard ceiling: if the source exceeds it,
    # canDirectPlay is false regardless of format/profile matches.
    #
    # When the DB has no bitrate for the track (src_br_kbps=0), lossless
    # formats are assumed to exceed any client cap -- a 900+ kbps FLAC will
    # always exceed a 128-320 kbps cap.  Lossy formats with unknown bitrate
    # get the benefit of the doubt (they might be low-bitrate spoken word).
    my $global_cap_blocks = 0;
    $log->debug("SlimPing: transcodeDecision gate src_br=$src_br_kbps max_audio=$max_audio_br suffix=$suffix");
    if ( $max_audio_br > 0 ) {
        if ( $src_br_kbps && $src_br_kbps > $max_audio_br ) {
            $global_cap_blocks = 1;
            push @transcode_reasons,
              "Source bitrate $src_br_kbps kbps exceeds client maximum $max_audio_br kbps for direct play";
        }
        elsif ( !$src_br_kbps && Plugins::SlimPing::Core::Container->get('library_mapper')->isLosslessFormat($suffix) ) {

            # Lossless format without a DB bitrate -- virtually always
            # exceeds any plausible client cap (e.g. FLAC at 900+ kbps).
            $global_cap_blocks = 1;
            push @transcode_reasons,
              "Lossless source ($suffix) exceeds client maximum $max_audio_br kbps for direct play";
        }
    }

    my ( $can_direct_play, $profile_reasons ) =
      _matchDirectPlay( $direct_play_profiles, $suffix, $src_br_kbps, $channels, $samplerate );

    # Global cap overrides any profile match
    $can_direct_play = \0 if $global_cap_blocks;

    # DSD formats cannot be decoded by any mobile or desktop Subsonic
    # client.  Override any DirectPlayProfile match -- server policy is
    # to always transcode DSD to MP3 for OpenSubsonic clients.  Users
    # who need native DSD should use LMS players with suitable DACs.
    if ( $$can_direct_play && Plugins::SlimPing::Core::Container->get('library_mapper')->isDsdFormat($suffix) ) {
        $can_direct_play = \0;
        push @transcode_reasons,
          'DSD format requires server-side decoding -- not available for direct play';
    }

    if ( $profile_reasons && @$profile_reasons ) {
        push @transcode_reasons, @$profile_reasons;
    }

    # --- transcodeStream: what we'll produce ---
    # When an exotic-format track (DSD) is requested and the operator has
    # configured exotic_target=flac, we offer FLAC output at the configured
    # sample rate.  Otherwise we offer MP3 CBR (existing behaviour).
    my $is_exotic = Plugins::SlimPing::Core::Container->get('library_mapper')->isDsdFormat($suffix);
    my $exotic_target = Plugins::SlimPing::Core::Logging->getPrefs()->get('exotic_target') || 'flac';
    my $offer_flac = $is_exotic
      && $exotic_target eq 'flac'
      && !( $max_transcode_br > 0 );

    my $target_br_kbps = 0;
    my $transcode_stream;
    if ($offer_flac) {
        my $rate_pref = Plugins::SlimPing::Core::Logging->getPrefs()->get('exotic_target_rate');
        $transcode_stream = {
            container       => 'flac',
            codec           => 'flac',
            audioCodec      => 'flac',
            audioBitrate    => undef,                          # VBR lossless
            audioSamplerate => int($rate_pref),
            audioBitdepth   => 24,
            audioChannels   => 2,
            protocol        => 'http',
        };
    }
    else {
        # --- MP3 transcode (existing logic) ---
        my $ceiling =
            $max_transcode_br > 0
          ? $max_transcode_br
          : Plugins::SlimPing::Core::TranscodeEstimate::MAX_OUTPUT_BITRATE();
        if ( $src_br_kbps > 0 ) {
            $target_br_kbps = $src_br_kbps < $ceiling ? $src_br_kbps : $ceiling;
        }
        elsif ( Plugins::SlimPing::Core::Container->get('library_mapper')->isLosslessFormat($suffix) ) {
            $target_br_kbps = $ceiling;
        }
        else {
            $target_br_kbps = 0;
        }
        my $target_rate = $samplerate ? ( $samplerate > 48000 ? 48000 : $samplerate ) : 44100;

        $transcode_stream = {
            container       => 'mp3',
            codec           => 'mp3',
            audioCodec      => 'mp3',
            audioProfile    => 'CBR',
            audioBitrate    => 0 + int( $target_br_kbps * 1000 ),
            audioSamplerate => int($target_rate),
            audioBitdepth   => 16,
            audioChannels   => 2,
            protocol        => 'http',
        };
    }

    # Strip undef keys
    for my $k ( keys %$transcode_stream ) {
        delete $transcode_stream->{$k} unless defined $transcode_stream->{$k};
    }

    # --- transcodingProfiles check ---
    # Check whether the client has a profile that accepts our transcode output.
    if ( $transcoding_profiles && ref $transcoding_profiles eq 'ARRAY' && @$transcoding_profiles ) {
        my $fmt     = $transcode_stream->{container} || 'mp3';
        my $fmt_ok  = 0;
        for my $tp (@$transcoding_profiles) {
            next unless ref $tp eq 'HASH';
            my $cont  = lc( $tp->{container}  // '' );
            my $codec = lc( $tp->{audioCodec} // '' );
            if (   ( $cont eq $fmt || $cont eq '*' )
                && ( $codec eq $fmt || $codec eq '*' ) )
            {
                $fmt_ok = 1;
                last;
            }
        }
        unless ($fmt_ok) {
            push @transcode_reasons, "Server produces $fmt; no matching transcoding profile found";
        }
    }

    # --- codecProfiles MP3 check ---
    # Informational only -- note if the client has an MP3 codec profile with
    # constraints we violate.  Our LAME ABR output decodes on every real-world
    # decoder, but the client should know.
    #
    # Spec structure: { type: "AudioCodec", name: "mp3", limitations: [...] }
    # Each limitation: { name, comparison, values, required }
    if ( $codec_profiles && ref $codec_profiles eq 'ARRAY' && @$codec_profiles ) {
        for my $cp (@$codec_profiles) {
            next unless ref $cp eq 'HASH';
            next unless lc( $cp->{type} // '' ) eq 'audiocodec';
            next unless lc( $cp->{name} // '' ) eq 'mp3';
            my $lims = $cp->{limitations};
            next unless $lims && ref $lims eq 'ARRAY';
            for my $lim (@$lims) {
                next unless ref $lim eq 'HASH';
                next unless lc( $lim->{name} // '' ) eq 'audiobitrate';
                my $comp  = lc( $lim->{comparison} // '' );
                my $value = lc( $lim->{values}     // '' );

                # "Equals" + "cbr" -> client requires CBR; we produce VBR
                if ( $comp eq 'equals' && $value eq 'cbr' ) {
                    push @transcode_reasons, "Server produces VBR; client MP3 codec profile requires CBR";
                    last;
                }
            }
        }
    }

    # Build an opaque transcodeParams token so the client can call
    # getTranscodeStream.view without re-sending format/bitrate params.
    # Encodes (sq_id, format, bitrate, offset, expiry) signed with HMAC.
    my $token_fmt = $offer_flac ? 'flac' : 'mp3';
    my $token_br  = $offer_flac ? 0 : ( $target_br_kbps || 320 );
    my $ttl       = Plugins::SlimPing::Core::Logging->getPrefs()->get('transcode_token_ttl') || 300;
    my $transcode_params = _buildTranscodeToken( $sq_id, $token_fmt, $token_br, 0, $ttl );

    # errorReason (OpenSubsonic optional): populated when both
    # canDirectPlay and canTranscode are false.  Not currently
    # reachable since the server always produces MP3 output.
    # canDirectPlay flows through as the JSON-boolean reference we already
    # have (\0 or \1 from _matchDirectPlay / the cap-blocks override above).
    # An earlier ternary form here read $can_direct_play in boolean context,
    # which is ALWAYS truthy for a scalar reference regardless of what it
    # points to -- meaning canDirectPlay was effectively stuck at true even
    # after we'd explicitly assigned \0.  Cross-referenced with Symfonium
    # debug logs (2026-05-27) where every getTranscodeDecision response
    # came back with canDirectPlay=true despite a populated transcodeReason
    # saying direct-play wasn't possible.  Tolriq specifically called out
    # "you are probably returning invalid answers".
    return {
        transcodeDecision => {
            canDirectPlay   => $can_direct_play,
            canTranscode    => \1,
            sourceStream    => $source_stream,
            transcodeStream => $transcode_stream,
            transcodeParams => $transcode_params,
            (
                @transcode_reasons
                ? ( transcodeReason => \@transcode_reasons )
                : ()
            ),
        },
    };
}

# getTranscodeStream -- OpenSubsonic endpoint that streams a transcoded track
# using an opaque transcodeParams token returned by getTranscodeDecision.
# The client must pass the token verbatim; we decode it, validate the HMAC,
# and delegate to the standard _serveAudio path.
sub _getTranscodeStream {
    my ( $httpClient, $response, $args ) = @_;
    my $p = $args->{params};

    my $sq_id = $p->{mediaId}
      or return Plugins::SlimPing::API::Router->sendError( $httpClient, $response, $p, 10, 'Required parameter mediaId is missing' );
    my $media_type = $p->{mediaType} || 'song';
    return Plugins::SlimPing::API::Router->sendError( $httpClient, $response, $p, 0, "Unsupported mediaType: $media_type" )
      unless $media_type eq 'song';

    my $token = $p->{transcodeParams}
      or return Plugins::SlimPing::API::Router->sendError( $httpClient, $response, $p, 10, 'Required parameter transcodeParams is missing' );

    my $decoded = _validateTranscodeToken($token);
    return Plugins::SlimPing::API::Router->sendError( $httpClient, $response, $p, 40, 'Invalid or expired transcode token' )
      unless $decoded;

    # Token must reference the same media the client is requesting
    return Plugins::SlimPing::API::Router->sendError( $httpClient, $response, $p, 40, 'Transcode token media mismatch' )
      unless $decoded->{sq_id} eq $sq_id;

    # Apply offset from the request, defaulting to the token value
    my $time_offset = $p->{offset} // $decoded->{offset} // 0;

    # Reconstruct the args the normal stream path expects
    $args->{params}{id}         = $decoded->{sq_id};
    $args->{params}{format}     = $decoded->{format};
    $args->{params}{maxBitRate} = $decoded->{bitrate};
    $args->{params}{timeOffset} = $time_offset;

    Plugins::SlimPing::Handlers::Stream::Endpoints::_serveStream( $httpClient, $response, $args );
}

# Match a client's directPlayProfiles against source file parameters.
# Returns (canDirectPlay, transcodeReasons).
# A profile matches when ALL its constraints are satisfied by the source.
# If ANY profile matches, canDirectPlay is true.
#
# Field names per the OpenSubsonic ClientInfo spec -- plural arrays, no
# per-profile bitrate or sample-rate fields (those are top-level ClientInfo).
sub _matchDirectPlay {
    my ( $profiles, $suffix, $src_br_kbps, $channels, $samplerate ) = @_;
    return ( \0, ['AudioCodecNotSupported'] )
      unless $profiles && ref $profiles eq 'ARRAY' && @$profiles;

    my %seen_reasons;
    for my $profile (@$profiles) {
        next unless ref $profile eq 'HASH';

        # OpenSubsonic spec: containers, audioCodecs, protocols are all
        # plural arrays.  An empty or absent array means "any."
        my $containers = $profile->{containers};
        my $codecs     = $profile->{audioCodecs};
        my $protos     = $profile->{protocols};
        my $max_ch     = $profile->{maxAudioChannels};

        # Container constraint -- empty array or absent means any
        if ( $containers && ref $containers eq 'ARRAY' && @$containers ) {
            my $hit = 0;
            for my $c (@$containers) {
                $hit = 1 if lc($c) eq lc($suffix);
            }
            unless ($hit) {
                $seen_reasons{AudioContainerNotSupported} = 1;
                next;
            }
        }

        # Codec constraint -- empty array or absent means any
        if ( $codecs && ref $codecs eq 'ARRAY' && @$codecs ) {
            my $hit = 0;
            for my $c (@$codecs) {
                $hit = 1 if lc($c) eq lc($suffix);
            }
            unless ($hit) {
                $seen_reasons{AudioCodecNotSupported} = 1;
                next;
            }
        }

        # Protocol constraint -- empty array or absent means any.
        # We only support HTTP, so if the client doesn't list "http",
        # this profile cannot match.
        if ( $protos && ref $protos eq 'ARRAY' && @$protos ) {
            my $hit = 0;
            for my $p (@$protos) {
                $hit = 1 if lc($p) eq 'http';
            }
            unless ($hit) {
                $seen_reasons{ProtocolNotSupported} = 1;
                next;
            }
        }

        # Channel constraint
        if ( defined $max_ch && $max_ch > 0 && $channels && $channels > $max_ch ) {
            $seen_reasons{AudioChannelsNotSupported} = 1;
            next;
        }

        # All constraints passed -- this profile matches
        return ( \1, undef );
    }

    # No profile matched -- collect reasons
    my @reasons = keys %seen_reasons;
    return ( \0, \@reasons );
}
# --- Transcode token helpers --------------------------------------------------

# HMAC signing key for transcodeParams tokens.  Lazily initialised from the
# Auth::Manager HMAC key.  The module-level cache is cleared on key rotation
# via clearTranscodeSigningKey (called directly by Auth::Manager::rotateHmacSigningKey).
my $_transcode_signing_key;

sub _transcodeSigningKey {
    return $_transcode_signing_key if $_transcode_signing_key;
    my $mgr = Plugins::SlimPing::Core::Container->get('auth_manager');
    $_transcode_signing_key = $mgr->getHmacSigningKey();
    return $_transcode_signing_key;
}

# Called by Auth::Manager::rotateHmacSigningKey after a key rotation so that
# transcode tokens use the new key immediately rather than the stale cached one.
sub clearTranscodeSigningKey {
    undef $_transcode_signing_key;
    return;
}

# Build an opaque transcodeParams token encoding (sq_id, format, bitrate,
# offset, expiry).  The payload is base64url-encoded JSON, signed with HMAC-
# SHA256.  The client must pass the full token back verbatim.
sub _buildTranscodeToken {
    my ( $sq_id, $format, $bitrate, $offset, $ttl_seconds ) = @_;
    $ttl_seconds //= 300;
    my $expiry  = time() + $ttl_seconds;
    my $payload = encode_base64url(
        JSON::XS::encode_json(
            {
                id  => $sq_id,
                fmt => $format || 'mp3',
                br  => int( ( $bitrate // 320 ) ),
                off => int( $offset // 0 ),
                exp => $expiry,
            }
        )
    );
    my $sig = hmac_sha256_hex( $payload, _transcodeSigningKey() );
    return "$payload.$sig";
}

# Validate a transcodeParams token.  Returns a hashref of decoded fields on
# success, or undef on any failure (expired, bad signature, invalid payload).
sub _validateTranscodeToken {
    my ($token) = @_;
    return undef unless defined $token && length $token;
    my ( $payload, $sig ) = split /\./, $token, 2;
    return undef unless defined $payload && length $payload;
    return undef unless defined $sig     && length $sig;

    my $candidate = hmac_sha256_hex( $payload, _transcodeSigningKey() );
    return undef
      unless Plugins::SlimPing::Auth::Manager::_constantTimeEq( $candidate, $sig );

    my $decoded = eval { JSON::XS::decode_json( decode_base64url($payload) ) };
    return undef unless $decoded && ref $decoded eq 'HASH';

    return undef if time() > ( $decoded->{exp} // 0 );

    return {
        sq_id   => $decoded->{id},
        format  => $decoded->{fmt} || 'mp3',
        bitrate => int( $decoded->{br} // 320 ),
        offset  => int( $decoded->{off} // 0 ),
        expiry  => $decoded->{exp},
    };
}

1;
