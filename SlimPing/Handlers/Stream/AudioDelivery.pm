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
# Handlers/Stream/AudioDelivery.pm - Audio dispatch facade for SlimPing
#
# Owns the six audio delivery paths: direct file serve, LMS virtual-player
# pipeline (MP3 transcode), external transcode bypass (DSD, CUE lossless),
# FLAC re-encode-on-seek, and the transcode output cache.  Delegates
# file-delivery details to AudioDelivery::FileServe, DSD transcoding to
# AudioDelivery::DsdTranscode, and CUE lossless handling to
# AudioDelivery::CueLossless.
#
# Called from Handlers/Stream/Endpoints.pm's _serveStream / _serveDownload
# wrappers.
#

package Plugins::SlimPing::Handlers::Stream::AudioDelivery;

use strict;
use warnings;

use Slim::Utils::Misc;
use Slim::Web::HTTP;
use Time::HiRes qw(time);
require Plugins::SlimPing::API::Router;
require Plugins::SlimPing::Auth::Permissions;
require Plugins::SlimPing::Core::Container;
require Plugins::SlimPing::Core::LibraryMapper;
require Plugins::SlimPing::Core::Logging;
require Plugins::SlimPing::Core::PipelinePool;
require Plugins::SlimPing::Core::TranscodeCache;
require Plugins::SlimPing::Core::TranscodeEstimate;
require Plugins::SlimPing::Core::VirtualPlayer;
require Plugins::SlimPing::Core::ExternalProcess;
require Plugins::SlimPing::Handlers::Stream::AudioDelivery::FileServe;
require Plugins::SlimPing::Handlers::Stream::AudioDelivery::DsdTranscode;
require Plugins::SlimPing::Handlers::Stream::AudioDelivery::CueLossless;

my $log = Plugins::SlimPing::Core::Logging->getLogger();

# On-demand seeked FLAC cache for _deliverExoticFlac offset>0 path.
# Keyed by "$sq_id:$offset" — holds { path => $temp_path, size => $bytes }.
# LRU-evicted at MAX_SEEK_CACHE_ENTRIES.  Temp files cleaned on eviction
# and plugin shutdown.
my %_seek_cache;
use constant MAX_SEEK_CACHE_ENTRIES => 16;

# --- Track resolution ---------------------------------------------------------
#
# Public class method — resolves a track ID to stream-ready metadata.
# Returns a hashref with keys: sq_id, track, stream_info, estimate,
# format, max_bitrate, client_name, want_cl, time_offset, range_byte_start,
# cue_offset_bytes, cue_duration_s, cue_start_seconds, is_cue_track.
# Returns undef and sends an error response on failure.
# Callers: serve() (internal), Sharing::shareStream (external).
#
# The $params_override hashref (4th positional arg) lets callers inject
# pre-resolved parameters — Sharing::shareStream uses
#   { id => $sq_id, max_bitrate => $max_bitrate, format => '' }.

sub resolveTrack {
    my ( $httpClient, $response, $args, $params_override ) = @_;
    $params_override //= {};
    my $p = $args->{params};

    my $sq_id = $params_override->{id} || $p->{id}
      or do {
        Plugins::SlimPing::API::Router->sendError( $httpClient, $response, $p, 10, 'Required parameter id is missing' );
        return;
      };

    my $mapper      = Plugins::SlimPing::Core::Container->get('library_mapper');
    my $stream_info = $mapper->resolveStreamUrl($sq_id);
    unless ($stream_info) {
        $log->info("SlimPing: stream request for unknown id=$sq_id");
        Plugins::SlimPing::API::Router->sendError( $httpClient, $response, $p, 70, 'Track not found' );
        return;
    }

    my $track = $mapper->getTrackById($sq_id);
    unless ($track) {
        Plugins::SlimPing::API::Router->sendError( $httpClient, $response, $p, 70, 'Track not found' );
        return;
    }

    my $format             = $params_override->{format}      // $p->{format}      // '';
    my $max_bitrate        = $params_override->{max_bitrate}  // $p->{maxBitRate}  // 0;
    my $time_offset        = $params_override->{time_offset}  // $p->{timeOffset}  // 0;
    my $client_time_offset = $time_offset;  # original, before Range parsing mutates it
    my $client_name        = $p->{c} || 'unknown';

    my $ecl_raw = $p->{estimateContentLength};
    my $want_cl = ( defined $ecl_raw && ( lc($ecl_raw) eq 'true' || $ecl_raw eq '1' ) ) ? 1 : 0;

    my $estimate = Plugins::SlimPing::Core::TranscodeEstimate->estimate(
        {
            duration_s     => $track->{duration} // 0,
            source_br_kbps => $track->{bitRate}  // 0,
            is_remote      => $stream_info->{is_remote} ? 1 : 0,
            content_type   => $track->{suffix} || '',
            cap_kbps       => $max_bitrate,
        }
    );

    my $range_byte_start;
    my $req = $response->request();
    if ( $req && $req->header('Range') && $estimate ) {
        my $parsed = Plugins::SlimPing::Core::TranscodeEstimate->parseRange(
            $req->header('Range'),
            $estimate->{size_bytes},
            $estimate->{duration_s},
        );
        if ($parsed) {
            $range_byte_start = $parsed->{byte_start};
            # time_offset stays at the client's declared timeOffset value.
            # The parsed Range→time conversion assumes MP3 output (via
            # TranscodeEstimate) which does not match the actual file layout
            # when serving raw FLAC directly.  Overriding time_offset here
            # would cause serveFile to seek to a wildly incorrect byte
            # position — the Range→time→byte round-trip through different
            # file models (MP3 estimate vs real FLAC) introduces skew.
            $log->debug(
                sprintf(
                    'SlimPing: Range %s -> byte=%d (out_br=%dkbps size=%d)',
                    $req->header('Range'),       $range_byte_start,
                    $estimate->{output_br_kbps}, $estimate->{size_bytes}
                )
            );
        }
    }

    # CUE / split-track detection: LMS sets audio_offset to an explicit
    # value (including 0 for the first segment) on CUE-split tracks, while
    # standalone files leave it NULL.  The is_cue_source flag is set by
    # resolveStreamUrl based on defined-ness of audio_offset(), not its value.
    my $cue_offset_bytes = $stream_info->{audio_offset} // 0;
    my $cue_duration_s   = 0;
    my $cue_start_seconds = 0;
    # is_cue_source is determined by resolveStreamUrl via a sibling-count
    # query — the only reliable CUE detector.  audio_offset > 0 is normal
    # for standalone files (ID3 tags, encoder headers) and produces false
    # positives that route MP3s into the CUE lossless re-encode path.
    my $is_cue_track = $stream_info->{is_cue_source};

    if ($is_cue_track) {
        $cue_duration_s = $track->{duration} // 0;
        if ( $cue_duration_s > 0 ) {
            # Compute start time from preceding track durations within the
            # same container.  Byte-offset / bitrate is unreliable for VBR
            # formats (FLAC) and breaks entirely when bitrate is null.
            $cue_start_seconds = $mapper->getCueStartTime(
                $sq_id, $stream_info->{url}, $cue_offset_bytes
            ) // $cue_start_seconds;

            # Recompute the estimate with the CUE segment duration.
            $estimate = Plugins::SlimPing::Core::TranscodeEstimate->estimate(
                {
                    duration_s     => $cue_duration_s,
                    source_br_kbps => $track->{bitRate} // 0,
                    is_remote      => $stream_info->{is_remote} ? 1 : 0,
                    content_type   => $track->{suffix} || '',
                    cap_kbps       => $max_bitrate,
                    cue_duration   => $cue_duration_s,
                }
            );
        }
    }

    # Effective seek: CUE start + any client-requested timeOffset.
    my $effective_offset = $cue_start_seconds;
    if ( $time_offset > 0 ) {
        $effective_offset += $time_offset;
    }

    return {
        sq_id              => $sq_id,
        track              => $track,
        stream_info        => $stream_info,
        estimate           => $estimate,
        format             => $format,
        max_bitrate        => $max_bitrate,
        time_offset        => $effective_offset,
        client_time_offset => $client_time_offset,
        client_name        => $client_name,
        want_cl            => $want_cl,
        range_byte_start   => $range_byte_start,
        cue_offset_bytes   => $cue_offset_bytes,
        cue_duration_s     => $cue_duration_s,
        cue_start_seconds  => $cue_start_seconds,
        is_cue_track       => $is_cue_track,
        httpClient         => $httpClient,
        response           => $response,
        args               => $args,
    };
}

# --- Pipeline decision --------------------------------------------------------

# Determine whether a stream request needs the LMS virtual player pipeline.
#
# Remote tracks always need processing (LMS must fetch and decode them).
# Downloads of local files must NOT be transcoded per the Subsonic spec.
# format=raw explicitly disables all processing.
# A format change or any non-zero maxBitRate cap needs the pipeline.
sub _needsProcessing {
    my ( $stream_info, $track, $format, $max_bitrate, $is_download ) = @_;

    return 1 if $stream_info->{is_remote};

    # DSD formats (DSF, DFF) cannot be decoded by any mobile or desktop
    # Subsonic client.  Like remote tracks, the raw source is not usable
    # by clients -- DSD files are impractically large (hundreds of MB per
    # track) and no Subsonic app can play them natively.  Always route
    # through the pipeline for MP3 transcoding, including downloads.
    # Users who need native DSD should use LMS players with suitable DACs.
    return 1 if Plugins::SlimPing::Core::Container->get('library_mapper')->isDsdFormat( $track->{suffix} );

    return 0 if $is_download;
    return 0 if $format eq 'raw';

    my $source_exceeds_cap = 0;
    if ( $max_bitrate && $max_bitrate > 0 ) {
        my $source_br = $track->{bitRate} // 0;
        if ( $source_br && $source_br > $max_bitrate ) {
            $source_exceeds_cap = 1;
        }
        elsif ( !$source_br && Plugins::SlimPing::Core::Container->get('library_mapper')->isLosslessFormat( $track->{suffix} ) ) {
            $source_exceeds_cap = 1;
        }
    }

    if ( $format && lc($format) ne ( $track->{suffix} // '' ) ) {
        return 1 if lc($format) eq 'mp3';

        $log->debug(
            sprintf(
                'SlimPing: requested format=%s cannot be produced (pipeline emits MP3 only); '
                  . 'serving source or capped MP3 instead',
                lc($format)
            )
        );
    }

    return $source_exceeds_cap;
}

# --- Public API ---------------------------------------------------------------

sub serve {
    my ( $httpClient, $response, $args, $is_download, $cached_cap_kbps ) = @_;
    my $p = $args->{params};

    my $t0 = time();

    require Plugins::SlimPing::Auth::Permissions;
    if ( Plugins::SlimPing::Auth::Permissions->requireRole( $args->{user}, 'streamRole' ) ) {
        Plugins::SlimPing::API::Router->sendError( $httpClient, $response, $p, 50, 'User is not authorised for this operation' );
        return;
    }

    my $d = resolveTrack( $httpClient, $response, $args, {} )
      or return;

    # Honour a remembered client bitrate cap (from getTranscodeDecision)
    # when the stream request itself specified no limit.  Least-authoritative
    # fallback: explicit override > request param > remembered cap > no limit.
    $d->{max_bitrate} = $cached_cap_kbps
        if !$d->{max_bitrate} && $cached_cap_kbps;

    my $sq_id            = $d->{sq_id};
    my $track            = $d->{track};
    my $stream_info      = $d->{stream_info};
    my $estimate         = $d->{estimate};
    my $format           = $d->{format};
    my $max_bitrate      = $d->{max_bitrate};
    my $time_offset      = $d->{time_offset};
    my $client_name      = $d->{client_name};
    my $want_cl          = $d->{want_cl};
    my $range_byte_start = $d->{range_byte_start};
    my $cue_offset_bytes = $d->{cue_offset_bytes} // 0;
    my $cue_duration_s   = $d->{cue_duration_s}   // 0;
    my $cue_start_secs   = $d->{cue_start_seconds} // 0;
    my $is_cue_track     = $d->{is_cue_track}      // 0;

    my $t_resolve = time();

    if ( $range_byte_start
        && $stream_info->{is_remote}
        && $estimate
        && $estimate->{size_bytes}
        && ( $range_byte_start / $estimate->{size_bytes} ) > 0.95 )
    {
        $log->debug("SlimPing: ignoring near-end Range probe for $sq_id");
        $time_offset       = $p->{timeOffset} // 0;
        $range_byte_start  = undef;
    }
    # Cache lookup -- serve complete entries directly, skipping the pipeline.
    # Downloads may read from cache but never populate it.
    # CUE tracks with a client-requested seek must not return a cached MP3
    # transcode -- the entry holds the complete positioned segment and the
    # request's offset is container-absolute, so the HIT+SEEK slicing would
    # land in the wrong place.  Offset-0 CUE requests may hit the cache:
    # the entry IS the full segment and the HIT path serves it whole (the
    # slicing block is skipped for CUE tracks).  Cache errors fall through
    # to the normal pipeline path.
    my $cached;
    unless ( $is_download || ( Plugins::SlimPing::Core::ExternalProcess::haveFlac()
            && $is_cue_track
            && $d->{client_time_offset} > 0 ) ) {
        my $output_br = $estimate ? $estimate->{output_br_kbps} : 0;
        if ( $output_br > 0 ) {
            $cached = eval {
                require Plugins::SlimPing::Core::TranscodeCache;
                Plugins::SlimPing::Core::TranscodeCache->getInstance
                  ->lookup( $sq_id, $output_br );
            };
            if ($@) {
                $log->warn("SlimPing: cache lookup error: $@");
                $cached = undef;
            }
        }
    }

    if ( $cached && $cached->{status} eq 'complete' ) {
        my $body_ref = $cached->{data};
        my $size     = $cached->{populated};
        my $track_duration = $track->{duration} // 0;

        # The cache stores the full CBR MP3 transcode output.  When seeking,
        # compute a proportional byte offset and then scan forward to the
        # next MPEG frame sync word (0xFF 0xE0-0xFF) so the served stream
        # starts at a valid frame boundary.
        # CUE entries are positioned segments -- their time_offset is
        # container-absolute, so byte-slicing would land in the wrong
        # place.  Serve them whole instead (the entry IS the segment).
        if ( $time_offset > 0 && $track_duration > 0 && $size > 0
            && !$is_cue_track )
        {
            my $byte_offset = int( ( $time_offset / $track_duration ) * $size );
            if ( $byte_offset < $size ) {
                my $data      = $$body_ref;
                my $pos       = $byte_offset;
                my $scan_end  = $byte_offset + 65536;
                $scan_end     = $size - 2 if $scan_end >= $size;
                while ( $pos < $scan_end ) {
                    my $b0 = ord( substr( $data, $pos,     1 ) );
                    my $b1 = ord( substr( $data, $pos + 1, 1 ) );
                    last if $b0 == 0xFF && ( $b1 & 0xE0 ) == 0xE0;
                    $pos++;
                }
                if ( $pos < $scan_end ) {
                    $byte_offset = $pos;
                }
                else {
                    $log->warn(
                        sprintf(
                            'SlimPing: no MPEG sync word within 64KB of byte %d for %s',
                            $byte_offset, $sq_id
                        )
                    );
                }
                my $seeked = substr( $data, $byte_offset );
                $body_ref = \$seeked;
                $size     = length($seeked);
                $log->debug(
                    sprintf(
                        'SlimPing: stream cache HIT+SEEK %s br=%d offset=%ds byte=%d/%d '
                      . '(%.1fms resolve, %d bytes served)',
                        $sq_id, $estimate->{output_br_kbps}, $time_offset,
                        $byte_offset, $cached->{populated},
                        ( $t_resolve - $t0 ) * 1000, $size
                    )
                );
            }
        }
        else {
            $log->debug(
                sprintf(
                    'SlimPing: stream cache HIT %s br=%d (%.1fms resolve, %d bytes)',
                    $sq_id, $estimate->{output_br_kbps},
                    ( $t_resolve - $t0 ) * 1000, $size
                )
            );
        }

        $response->code(200);
        $response->header( 'Content-Type',
            Plugins::SlimPing::Core::Container->get('library_mapper')->outputMime() );
        $response->header( 'Content-Length' => $size );
        $response->header( 'Connection'     => 'close' );
        $response->header( 'Accept-Ranges'  => 'bytes' );

        Slim::Web::HTTP::addHTTPResponse( $httpClient, $response, $body_ref );

        return;
    }


    if ( $stream_info->{is_remote} ) {
        my $proxy_enabled = Plugins::SlimPing::Core::Logging->isFeatureEnabled('proxy_remote_streams');
        unless ($proxy_enabled) {
            $log->warn("SlimPing: proxy_remote_streams is disabled, rejecting remote stream");
            Plugins::SlimPing::API::Router->sendError( $httpClient, $response, $p, 70, 'Track not found' );
            return;
        }
    }

    if ( $stream_info->{is_remote} && !$is_download && $estimate ) {
        require Plugins::SlimPing::Core::PipelinePool;
        my $br = $estimate->{output_br_kbps};
        if ($br) {
            my $output_mime =
              Plugins::SlimPing::Core::Container->get('library_mapper')
              ->outputMime();

            $response->code(200);
            $response->header( 'Content-Type' => $output_mime );
            $response->header( 'Connection'   => 'close' );

            require Slim::Web::HTTP;
            my $headers =
              Slim::Web::HTTP::_stringifyHeaders($response) . "\x0d\x0a";

            my $attached =
              Plugins::SlimPing::Core::PipelinePool->registerListener(
                pool_type   => 'track',
                source_url  => $stream_info->{url},
                br_kbps     => $br,
                httpClient  => $httpClient,
                headers     => $headers,
                time_offset => $time_offset,
              );
            if ($attached) {
                $log->debug("SlimPing: attached pooled track listener for $sq_id");
                return;
            }
        }
    }

    # CUE / split-track files cannot be served directly -- the file contains
    # audio from multiple tracks.  Route through the pipeline regardless of
    # format, bitrate, or download flag.
    my $needs_pipeline = $is_cue_track
      || _needsProcessing( $stream_info, $track, $format, $max_bitrate, $is_download );

    $log->debug(
        sprintf(
            'SlimPing: dispatch %s -> %s (fmt=%s cap=%d src_br=%d suffix=%s remote=%d dl=%d%s%s)',
            $sq_id,
            $needs_pipeline ? 'pipeline' : 'direct',
            $format || 'auto',
            $max_bitrate,
            $track->{bitRate} // 0,
            $track->{suffix}  // '?',
            $stream_info->{is_remote},
            $is_download,
            ( $format eq 'raw' && $needs_pipeline ) ? ' RAW-OVERRIDE' : '',
            $is_cue_track ? ' CUE' : ''
        )
    );

    # DSD tracks (DSF, DFF) cannot be decoded by LMS's transcode framework —
    # the dsf/dff rules in convert.conf are dropped by the parser.  Always
    # transcode to FLAC first (disk cache), then serve the FLAC directly or
    # feed it through LMS's FLAC→MP3 pipeline depending on what the client
    # requested.  Once the FLAC is cached the MP3 path also benefits: LMS
    # reads the cached FLAC via file:// URL and the MP3 output enters the
    # standard transcode RAM+disk cache.
    if ( $needs_pipeline && Plugins::SlimPing::Core::Container->get('library_mapper')->isDsdFormat( $track->{suffix} ) ) {
        my $dsd_path = Slim::Utils::Misc::pathFromFileURL( $stream_info->{url} );
        unless ( defined $dsd_path && length $dsd_path ) {
            $log->error("SlimPing: DSD track with non-file URL: $stream_info->{url}");
            _send500( $httpClient, $response );
            return;
        }

        unless ( Plugins::SlimPing::Core::ExternalProcess::haveDsdplay() ) {
            $log->error("SlimPing: dsdplay not found — DSDPlayer plugin required");
            _send500( $httpClient, $response,
                'DSD decoder (dsdplay) not found — install the DSDPlayer plugin' );
            return;
        }

        my $target_rate  = Plugins::SlimPing::Handlers::Stream::AudioDelivery::DsdTranscode::selectOutputRate($track);
        my $cache_suffix = "flac";
        my $rate_key     = "$sq_id:$target_rate";
        my $cache        = Plugins::SlimPing::Core::TranscodeCache->getInstance;
        my $prepared     = eval { $cache->prepareFormatOutput( $rate_key, $cache_suffix ); };

        # Cache hit — FLAC already on disk.  Serve directly or pipeline to MP3.
        if ( $prepared && $prepared->{ready} ) {
            $log->debug(
                sprintf( 'SlimPing: stream DSD FLAC cache HIT %s rate=%d offset=%d (%d bytes)',
                    $sq_id, $target_rate, $time_offset, $prepared->{size} ) );
            _deliverExoticFlac(
                httpClient  => $httpClient,
                response    => $response,
                flac_path   => $prepared->{path},
                flac_size   => $prepared->{size},
                sq_id       => $sq_id,
                client_name => $client_name,
                format      => $format,
                max_bitrate => $max_bitrate,
                time_offset => $time_offset,
                duration    => $track->{duration} // 0,
                is_download => $is_download,
            );
            return;
        }

        my $output_path = $prepared ? $prepared->{path} : '';
        my $we_claimed  = $prepared && !$prepared->{ready};

        my $dsdplay_bin = Plugins::SlimPing::Core::ExternalProcess::dsdplayPath();
        my $flac_bin    = Plugins::SlimPing::Core::ExternalProcess::flacPath();

        my $bps = Plugins::SlimPing::Core::Logging->getPrefs()
                    ->get('dsd_output_bit_depth') // 24;

        my $cache_key = join( ':', $sq_id, 'dsd-flac', $target_rate );

        # When another request is already processing this track
        # (TranscodeCache inflight set), register as a waiter via
        # ExternalProcess inflight dedup rather than building a
        # doomed command with an empty output path.
        unless ($we_claimed) {
            my $waiter = Plugins::SlimPing::Core::ExternalProcess->spawnPipeline(
                cmd_decode       => [],
                cmd_encode       => [],
                tmp_path         => '',
                cache_key        => $cache_key,
                cache_sq_id      => $rate_key,
                cache_suffix     => $cache_suffix,
                timeout_s        => 120,
                on_complete      => sub {
                    my ($serve_path) = @_;
                    my $size = -s $serve_path;
                    unless ($size) {
                        $log->error("SlimPing: DSD serve path missing/empty: $serve_path");
                        Plugins::SlimPing::API::Router->sendError( $httpClient, $response, $p, 0,
                            'DSD transcode produced empty output — the source file may be corrupt' );
                        return;
                    }
                    $log->debug("SlimPing: DSD serving $size bytes (waiter)");
                    _deliverExoticFlac(
                        httpClient  => $httpClient,
                        response    => $response,
                        flac_path   => $serve_path,
                        flac_size   => $size,
                        sq_id       => $sq_id,
                        client_name => $client_name,
                        format      => $format,
                        max_bitrate => $max_bitrate,
                        time_offset => $time_offset,
                        duration    => $track->{duration} // 0,
                        is_download => $is_download,
                    );
                },
                on_error => sub {
                    my ($reason) = @_;
                    $log->warn("SlimPing: DSD->FLAC failed for $sq_id: $reason");
                    Plugins::SlimPing::API::Router->sendError( $httpClient, $response, $p, 0,
                        'DSD transcode failed — the source file may be corrupt' );
                },
                httpClient => $httpClient,
                response   => $response,
            );
            if ($waiter == 2) {
                return;   # registered as waiter
            }
            # TranscodeCache inflight was set but ExternalProcess entry
            # has gone (race: transcode just completed).  Retry the
            # cache lookup — the RAM/disk cache should now be populated.
            $log->debug("SlimPing: DSD inflight race for $cache_key, retrying cache");
            $prepared = eval { $cache->prepareFormatOutput( $rate_key, $cache_suffix ); };
            if ( $prepared && $prepared->{ready} ) {
                _deliverExoticFlac(
                    httpClient  => $httpClient,
                    response    => $response,
                    flac_path   => $prepared->{path},
                    flac_size   => $prepared->{size},
                    sq_id       => $sq_id,
                    client_name => $client_name,
                    format      => $format,
                    max_bitrate => $max_bitrate,
                    time_offset => $time_offset,
                    duration    => $track->{duration} // 0,
                    is_download => $is_download,
                );
                return;
            }
            $log->warn("SlimPing: DSD spawn failed for $cache_key (waiter miss)");
            Plugins::SlimPing::API::Router->sendError( $httpClient, $response, $p, 0,
                'DSD transcode could not start — retry later' );
            return;
        }

        # We claimed the transcode slot — build the pipeline commands.
        # DSDPlayer's dsdplay outputs FLAC to stdout.  The three-stage
        # pipeline decodes the FLAC to raw PCM (flac -dc), then re-encodes
        # with correct STREAMINFO at the target bit depth (flac -5).
        # The intermediate stage is required — dsdplay's FLAC output is not
        # raw PCM, so a direct dsdplay | flac -5 would fail.
        # --bps is encode-only and only on the final flac -5 stage.

        my $cmd_decode = [
            $dsdplay_bin, '-r', $target_rate, $dsd_path,
        ];
        my $cmd_intermediate = [
            $flac_bin, '-dc', '--silent', '--force-raw-format',
            '--endian=little', '--sign=signed', '-',
        ];
        my $cmd_encode = [
            $flac_bin, '-5', '--silent', '--force-raw-format',
            '--endian=little', '--sign=signed', '--channels=2',
            "--bps=$bps", '--sample-rate', $target_rate,
        ];

        # Inject metadata tags so LMS can resolve track identity when it
        # reads the cache FLAC file.  Without these, LMS creates a bare
        # database entry with "No Album" / "No Artist" for the cache URL.
        if ( $track && $track->{title} ) {
            push @{$cmd_encode}, '--tag=TITLE=' . $track->{title};
            push @{$cmd_encode}, '--tag=ARTIST=' . $track->{artist}
              if $track->{artist};
            push @{$cmd_encode}, '--tag=ALBUM=' . $track->{album}
              if $track->{album};
        }

        push @{$cmd_encode}, '-o', $output_path, '-';

        my $dsd_started = Plugins::SlimPing::Core::ExternalProcess->spawnPipeline(
            cmd_decode       => $cmd_decode,
            cmd_intermediate => $cmd_intermediate,
            cmd_encode       => $cmd_encode,
            tmp_path         => $output_path,
            cache_key    => $cache_key,
            cache_sq_id  => $rate_key,
            cache_suffix => $cache_suffix,
            timeout_s    => 120,
            on_complete  => sub {
                my ($serve_path) = @_;
                my $size = -s $serve_path;
                unless ($size) {
                    $log->error("SlimPing: DSD serve path missing/empty: $serve_path");
                    Plugins::SlimPing::API::Router->sendError( $httpClient, $response, $p, 0,
                        'DSD transcode produced empty output — the source file may be corrupt' );
                    return;
                }
                $log->debug("SlimPing: DSD serving $size bytes");
                _deliverExoticFlac(
                    httpClient  => $httpClient,
                    response    => $response,
                    flac_path   => $serve_path,
                    flac_size   => $size,
                    sq_id       => $sq_id,
                    client_name => $client_name,
                    format      => $format,
                    max_bitrate => $max_bitrate,
                    time_offset => $time_offset,
                    duration    => $track->{duration} // 0,
                    is_download => $is_download,
                );
            },
            on_error => sub {
                my ($reason) = @_;
                $log->warn("SlimPing: DSD->FLAC failed for $sq_id: $reason");
                Plugins::SlimPing::API::Router->sendError( $httpClient, $response, $p, 0,
                    'DSD transcode failed — the source file may be corrupt' );
            },
            httpClient => $httpClient,
            response   => $response,
        );

        if ($dsd_started == 2) {
            return;   # waiter — callback will fire when transcode completes
        }
        unless ($dsd_started) {
            if ($we_claimed) {
                $cache->discardFormatOutput( $rate_key, $output_path, $cache_suffix );
            }
            $log->warn("SlimPing: DSD spawn failed for $cache_key");
            Plugins::SlimPing::API::Router->sendError( $httpClient, $response, $p, 0,
                'DSD transcode could not start — retry later' );
            return;
        }

        $log->debug(
            sprintf( 'SlimPing: stream DSD %s rate=%d (%.1fms resolve, %s)',
                $sq_id, $target_rate, ( $t_resolve - $t0 ) * 1000, $client_name ) );
        return;
    }

    # CUE / split-track lossless path: re-encode the segment to FLAC
    # (flac -dc --skip --until | flac -5).  Always enters for CUE tracks.
    # on_complete callback uses _deliverExoticFlac to serve the FLAC
    # directly or pipe it through the LMS FLAC->MP3 pipeline depending on
    # client format/cap settings.
    if ( Plugins::SlimPing::Core::ExternalProcess::haveFlac()
        && $needs_pipeline
        && $is_cue_track )
    {
        my $client_to = $d->{client_time_offset} // 0;
        _serveCueLossless(
            httpClient         => $httpClient,
            response           => $response,
            file_url           => $stream_info->{url},
            track              => $track,
            cue_start_secs     => $cue_start_secs,
            cue_duration_s     => $cue_duration_s,
            client_time_offset => $client_to,
            is_download        => $is_download,
            client_name        => $client_name,
            max_bitrate        => $max_bitrate,
            format             => $format,
        );
        $log->debug(
            sprintf(
                'SlimPing: stream CUE lossless %s start=%s dur=%d client_off=%d (%.1fms resolve, %s)',
                $sq_id, $cue_start_secs, $cue_duration_s, $client_to,
                ( $t_resolve - $t0 ) * 1000, $client_name
            )
        );
        return;
    }

    if ( !$needs_pipeline ) {
        my $file_url = $stream_info->{url};
        my $req = $response->request();
        my $range_header = $req ? $req->header('Range') : undef;
        Plugins::SlimPing::Handlers::Stream::AudioDelivery::FileServe::serveFile(
            httpClient   => $httpClient,
            response     => $response,
            file_url     => $file_url,
            content_type => $track->{contentType},
            is_download  => $is_download,
            time_offset  => $time_offset,
            duration     => $track->{duration} // 0,
            http_range   => $range_header,
            sq_id        => $sq_id,
        );
        $log->debug(
            sprintf(
                'SlimPing: stream direct %s offset=%d (%.1fms resolve + %.1fms serve, %s)',
                $sq_id, $time_offset,
                ( $t_resolve - $t0 ) * 1000,
                ( time() - $t_resolve ) * 1000, $client_name
            )
        );
    }
    else {
        # Transcode pipeline output is not seekable (LMS pipe).
        # Explicitly signal this so clients fall back to timeOffset.
        $response->header( 'Accept-Ranges' => 'none' );

        my $meta = {};
        $meta->{artist} = $track->{artist} if $track->{artist};
        $meta->{title}  = $track->{title}  if $track->{title};
        $meta->{album}  = $track->{album}  if $track->{album};
        $meta->{genre}  = $track->{genre}  if $track->{genre};
        $meta->{year}   = $track->{year}   if $track->{year};

        # CUE / split-track URLs carry time-range fragments (e.g.
        # file:///path/album.flac#1869.36-2111.37) that LMS stores in
        # the tracks.url column.  LMS's internal playlist and transcode
        # pipeline does not strip these fragments before opening the file
        # -- unlike pathFromFileURL which uses URI->new() and discards
        # the fragment component.  Passing a URL with a fragment into
        # the pipeline produces an immediate STREAMOUT+EOS (the file
        # open fails because the fragment is treated as part of the
        # filename).  The time_offset parameter already encodes the
        # seek position, and cue_duration_s limits playback, so the
        # fragment is redundant for the pipeline path.
        my $pipeline_url = $stream_info->{url};
        $pipeline_url =~ s/#\d+(?:\.\d+)?-\d+(?:\.\d+)?$//
            if $is_cue_track;

        my $started = Plugins::SlimPing::Core::VirtualPlayer::streamViaPipeline(
            httpClient       => $httpClient,
            response         => $response,
            source_url       => "slimping://$sq_id/library",
            sq_id            => $sq_id,
            client_name      => $client_name,
            format           => $format,
            time_offset      => $time_offset,
            is_download      => $is_download,
            is_remote        => $stream_info->{is_remote},
            output_br_kbps   => $estimate ? $estimate->{output_br_kbps} : 0,
            size_bytes       => $estimate ? $estimate->{size_bytes}     : undef,
            duration_s       => $estimate ? $estimate->{duration_s}     : 0,
            meta             => $meta,
            range_byte_start => $range_byte_start,
            want_cl          => $want_cl,
            username         => $args->{user}{username},
            cue_offset_bytes => $cue_offset_bytes,
            cue_duration_s   => $cue_duration_s,
        );
        if ( defined $started && $started <= 0 ) {
            my $msg = $started == -1
              ? 'Too many remote stream requests - wait before retrying'
              : 'Too many concurrent remote streams - try again later';
            Plugins::SlimPing::API::Router->sendError( $httpClient, $response, $p, 0, $msg );
            return;
        }
        $log->debug(
            sprintf(
                'SlimPing: stream pipeline %s fmt=%s br=%d remote=%d offset=%d (%.1fms resolve, %s)',
                $sq_id, $format || 'auto', $max_bitrate, $stream_info->{is_remote},
                $time_offset, ( $t_resolve - $t0 ) * 1000, $client_name
            )
        );
    }
}


# --- Emergency error path ------------------------------------------------------
#
# _send500 sends a raw HTTP 500 response.  This violates the Subsonic spec
# (which requires HTTP 200 with an error in the JSON/XML envelope).  We
# accept this violation because _send500 is only called from ExternalProcess
# callbacks — by the time the callback fires, the Router's dispatch eval{}
# has already returned and the normal Subsonic envelope path is unavailable.
#
# The alternative (threading a response buffer through the async machinery)
# would add significant complexity.  In practice, all major Subsonic clients
# handle HTTP 5xx gracefully by displaying a generic error.  If a future
# client breaks, the fix is to buffer the error response through
# ResponseFormatter from within the callback — not to eliminate _send500.
sub _send500 {
    my ( $httpClient, $response, $msg ) = @_;
    $msg //= 'Internal server error';
    $response->code(500);
    $response->header( 'Content-Type'   => 'text/plain; charset=utf-8' );
    $response->header( 'Content-Length' => length($msg) );
    Slim::Web::HTTP::addHTTPResponse( $httpClient, $response, \$msg );
    return;
}


# Store a seeked FLAC temp file in the RAM cache, evicting the oldest entry
# if at capacity.  The temp file is cleaned up on eviction or plugin shutdown.
# Called from _deliverExoticFlac offset>0 on_complete callback.
sub _cacheSeekedFlac {
    my ( $key, $path, $size ) = @_;
    return unless $key && $path && $size;

    if ( scalar keys %_seek_cache >= MAX_SEEK_CACHE_ENTRIES ) {
        my ($oldest_key) = sort keys %_seek_cache;
        my $old = delete $_seek_cache{$oldest_key};
        unlink( $old->{path} ) if $old && $old->{path} && -f $old->{path};
    }

    $_seek_cache{$key} = { path => $path, size => $size };
    return;
}

# --- Exotic→FLAC delivery ------------------------------------------------------
#
# Single decision point for all exotic→FLAC transcode outputs.  Once an exotic
# format (DSD, CUE-split FLAC, or future APE/ALAC CUE) has been transcoded to a
# valid FLAC file, this method decides whether to serve the FLAC directly or
# feed it through LMS's virtual-player pipeline for MP3 transcoding.
#
# Rules (priority order):
#   1. Client explicitly asks for MP3 (format=mp3) → pipeline to MP3
#   2. Client sets a bitrate cap → pipeline to MP3
#   3. Operator configured exotic_target=mp3 → pipeline to MP3
#   4. Otherwise → serve FLAC directly via FileServe
#
# Called from DSD and CUE spawnPipeline completion callbacks, which fire after
# the Router dispatch eval{} has returned.  Uses _send500 for error delivery
# because the normal Subsonic envelope path is unavailable by that point.
sub _deliverExoticFlac {
    my %args = @_;
    my $format      = $args{format}      || '';
    my $max_bitrate = $args{max_bitrate} // 0;

    my $want_mp3 = ( $format && lc($format) eq 'mp3' )
                || ( !$format && $max_bitrate && $max_bitrate > 0 );

    unless ( $format || ( $max_bitrate && $max_bitrate > 0 ) ) {
        my $target = Plugins::SlimPing::Core::Logging->getPrefs()
                       ->get('exotic_target') || 'flac';
        $want_mp3 = ( $target eq 'mp3' );
    }

    $log->debug(
        sprintf(
            'SlimPing: _deliverExoticFlac %s fmt=%s cap=%d offset=%d dur=%d -> %s',
            $args{sq_id}, $format || 'auto', $max_bitrate,
            ( $args{time_offset} // 0 ), ( $args{duration} // 0 ),
            $want_mp3 ? 'MP3-via-pipeline' : 'FLAC-via-serveFile'
        )
    );

    # Resolve real-track metadata from sq_id for the MP3 pipeline path so
    # LMS can display proper Now Playing metadata.
    my $meta = {};

    if ( $args{sq_id} ) {
        require Plugins::SlimPing::Core::Container;
        my $mapper = eval { Plugins::SlimPing::Core::Container->get('library_mapper') };
        unless ($@) {
            # Shaped metadata for Now Playing injection (artist / title needed
            # for CUE segments where the container Track carries different values).
            my $track_data = eval { $mapper->getTrackById( $args{sq_id} ) };
            unless ( $@ || !$track_data ) {
                $meta->{artist} = $track_data->{artist} if $track_data->{artist};
                $meta->{title}  = $track_data->{title}  if $track_data->{title};
                $meta->{album}  = $track_data->{album}  if $track_data->{album};
                $meta->{genre}  = $track_data->{genre}  if $track_data->{genre};
                $meta->{year}   = $track_data->{year}   if $track_data->{year};
            }
        }
    }

    if ($want_mp3) {
        my $br = ( $max_bitrate && $max_bitrate > 0 ) ? $max_bitrate : 320;
        my $offset = $args{time_offset} // 0;
        my $dur    = $args{duration}    // 0;

        # Only full-segment outputs may populate the transcode cache.
        # Seeked outputs are partial (the offset is baked into the FLAC
        # segment) and would pollute the full-track cache key.  The CBR
        # size estimate lets registerStream track expected_bytes.
        my $size_bytes = ( $dur > 0 && $offset == 0 )
          ? int( $dur * $br * 1000 / 8 )
          : undef;

        Plugins::SlimPing::Core::VirtualPlayer::streamViaPipeline(
            httpClient        => $args{httpClient},
            response          => $args{response},
            source_url        => 'slimping://'
              . $args{sq_id} . '/cache/'
              . ( $args{flac_path} =~ m{/([^/]+)$} )[0],
            sq_id             => $args{sq_id},
            client_name       => $args{client_name} || 'exotic',
            format            => 'mp3',
            time_offset       => $offset,
            is_download       => $args{is_download},
            is_remote         => 0,
            output_br_kbps    => $br,
            size_bytes        => $size_bytes,
            duration_s        => $dur,
            meta              => $meta,
        );
    } else {
        my $offset = $args{time_offset} // 0;

        # offset=0: serve the complete cached FLAC directly — zero extra cost.
        if ( $offset == 0 ) {
            Plugins::SlimPing::Handlers::Stream::AudioDelivery::FileServe::serveFile(
                httpClient    => $args{httpClient},
                response      => $args{response},
                override_path => $args{flac_path},
                content_type  => 'audio/flac',
                is_download   => $args{is_download},
                time_offset   => $args{time_offset} // 0,
                duration      => $args{duration} // 0,
                file_size     => $args{flac_size},
                sq_id         => $args{sq_id},
            );
            return;
        }

        # offset>0: the client (Symfonium via getTranscodeStream) needs a
        # valid FLAC from this time position.  Mid-stream byte slices lack
        # STREAMINFO and ExoPlayer rejects them.  Re-encode from the offset
        # via flac -dc --skip=N | flac -5 — source is already FLAC, so
        # decode is fast.  Output is RAM-cached; repeat seeks are instant.

        my $cache_key = $args{sq_id} . ':' . $offset;

        if ( my $entry = $_seek_cache{$cache_key} ) {
            if ( -f $entry->{path} && -s $entry->{path} ) {
                $log->debug("SlimPing: seek cache HIT $cache_key ($entry->{size} bytes)");
                Plugins::SlimPing::Handlers::Stream::AudioDelivery::FileServe::serveFile(
                    httpClient    => $args{httpClient},
                    response      => $args{response},
                    override_path => $entry->{path},
                    content_type  => 'audio/flac',
                    file_size     => $entry->{size},
                    sq_id         => $args{sq_id},
                );
                return;
            }
            delete $_seek_cache{$cache_key};
        }

        my $seeked_path = Slim::Utils::Misc::getTempDir() . '/slimping_seek_'
          . time() . '_' . int( rand(999999) ) . '.flac';

        my $flac_bin = Plugins::SlimPing::Core::ExternalProcess::flacPath();
        my $skip_str =
          Plugins::SlimPing::Handlers::Stream::AudioDelivery::CueLossless::formatFlacTime($offset);

        # Match the sample rate of the initial DSD→FLAC transcode.
        my $target_rate =
          Plugins::SlimPing::Handlers::Stream::AudioDelivery::DsdTranscode::selectOutputRate(undef);

        my $cmd_decode = [
            $flac_bin, '-dc', '--silent',
            "--skip=$skip_str",
            '--force-raw-format', '--endian=little', '--sign=signed',
            '--', $args{flac_path},
        ];
        my $cmd_encode = [
            $flac_bin, '-5', '--silent', '--force-raw-format',
            '--endian=little', '--sign=signed',
            '--channels=2', '--bps=24',
            '--sample-rate', $target_rate,
            '-o', $seeked_path, '-',
        ];

        $log->debug("SlimPing: seek re-encode $cache_key offset=$offset rate=$target_rate");

        Plugins::SlimPing::Core::ExternalProcess->spawnPipeline(
            cmd_decode => $cmd_decode,
            cmd_encode => $cmd_encode,
            tmp_path   => $seeked_path,
            cache_key  => $cache_key,
            timeout_s  => 60,
            on_complete => sub {
                my ($result_path) = @_;
                my $size = -s $result_path;
                unless ( $size && $size > 0 ) {
                    $log->error("SlimPing: seek re-encode produced empty output for $cache_key");
                    Plugins::SlimPing::Handlers::Stream::AudioDelivery::_send500(
                        $args{httpClient}, $args{response} );
                    return;
                }
                _cacheSeekedFlac( $cache_key, $result_path, $size );
                $log->debug("SlimPing: seek cache stored $cache_key ($size bytes)");
                Plugins::SlimPing::Handlers::Stream::AudioDelivery::FileServe::serveFile(
                    httpClient    => $args{httpClient},
                    response      => $args{response},
                    override_path => $result_path,
                    content_type  => 'audio/flac',
                    file_size     => $size,
                    sq_id         => $args{sq_id},
                );
            },
            on_error => sub {
                my ($reason) = @_;
                $log->warn("SlimPing: seek re-encode failed for $cache_key: $reason");
                Plugins::SlimPing::Handlers::Stream::AudioDelivery::_send500(
                    $args{httpClient}, $args{response} );
            },
            httpClient => $args{httpClient},
            response   => $args{response},
        );
    }
}

# --- CUE lossless -------------------------------------------------------------

# Serve a CUE segment by re-encoding the source file.  Delegates to
# AudioDelivery::CueLossless::serveCueLossless.
sub _serveCueLossless {
    return Plugins::SlimPing::Handlers::Stream::AudioDelivery::CueLossless::serveCueLossless(@_);
}

1;
