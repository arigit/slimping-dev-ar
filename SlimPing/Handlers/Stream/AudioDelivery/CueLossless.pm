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
# Handlers/Stream/AudioDelivery/CueLossless.pm - CUE-sheet lossless re-encode and delivery
#
# Extracted from AudioDelivery.pm.  Handles FLAC time formatting, ffmpeg format
# mapping, and CUE-segment lossless re-encode/streaming for LMS-split CUE tracks.
#

package Plugins::SlimPing::Handlers::Stream::AudioDelivery::CueLossless;

use strict;
use warnings;

use Slim::Utils::Misc;
require Plugins::SlimPing::Core::Container;
require Plugins::SlimPing::Core::ExternalProcess;
require Plugins::SlimPing::Core::Logging;
require Plugins::SlimPing::Core::TranscodeCache;

my $log = Plugins::SlimPing::Core::Logging->getLogger();

# --- Time and format helpers ---------------------------------------------------

# Format a number of seconds for flac --skip / --until.
# Uses MM:SS.SS for tracks under 60 minutes, H:MM:SS.SS for longer
# tracks (classical works, live recordings, audiobooks).
sub formatFlacTime {
    my ($secs) = @_;
    my $h      = int( $secs / 3600 );
    my $m      = int( ( $secs % 3600 ) / 60 );
    my $s      = $secs - $h * 3600 - $m * 60;
    if ( $h > 0 ) {
        return sprintf( '%d:%02d:%05.2f', $h, $m, $s );
    }
    return sprintf( '%d:%05.2f', $m, $s );
}

# Maps LMS file suffixes to human-readable format labels for debug logging.
sub _formatLabel {
    my ($suffix) = @_;
    my %map = (
        flac => 'flac',
        flc  => 'flac',
        wav  => 'wav',
        aif  => 'aiff',
        aiff => 'aiff',
        ape  => 'ape',
        wv   => 'wv',
        mp3  => 'mp3',
    );
    return $map{ lc( $suffix || '' ) };
}

# --- CUE lossless delivery -----------------------------------------------------

# Serve a CUE segment by re-encoding the source file using the flac
# binary (shipped with LMS Docker, used internally by convert.conf).
# Always re-encodes because FLAC frames carry no timestamps -- stream
# copy from a non-zero offset preserves the original sample positions,
# which contradicts STREAMINFO and causes decoder errors.
#
# Output goes to a temp file (seekable) so the encoder can write correct
# STREAMINFO, then is moved into the disk cache if enabled.  Repeat
# plays skip the transcode entirely.
sub serveCueLossless {
    my %args = @_;

    my $httpClient         = $args{httpClient} or die 'serveCueLossless: httpClient required';
    my $response           = $args{response}   or die 'serveCueLossless: response required';
    my $file_url           = $args{file_url}   or die 'serveCueLossless: file_url required';
    my $track              = $args{track}      or die 'serveCueLossless: track required';
    my $cue_start_secs     = $args{cue_start_secs}     // 0;
    my $cue_duration_s     = $args{cue_duration_s}     // 0;
    my $client_name        = $args{client_name}        // 'unknown';
    my $client_time_offset = $args{client_time_offset} // 0;
    my $is_download        = $args{is_download}        // 0;
    my $max_bitrate        = $args{max_bitrate};
    my $format             = $args{format};

    my $path = Slim::Utils::Misc::pathFromFileURL($file_url);
    unless ( defined $path && length $path ) {
        $log->error("SlimPing: _serveCueLossless called with non-file URL: $file_url");
        return Plugins::SlimPing::Handlers::Stream::AudioDelivery::_send500( $httpClient, $response );
    }

    my $suffix = $track->{suffix} || '';
    my $ffmt   = _formatLabel($suffix);

    # The pipeline always produces FLAC regardless of source format
    # (flac -dc ... | flac -5 ...).  Content-Type must match the actual
    # output, not the original source.  _deliverExoticFlac hardcodes
    # audio/flac for the direct-serve path.
    my $mime = 'audio/flac';

    my $start_secs    = $cue_start_secs + ( $client_time_offset // 0 );
    my $effective_dur = $cue_duration_s - ( $client_time_offset // 0 );
    if ( $effective_dur <= 0 ) {
        $log->warn("SlimPing: CUE lossless effective duration <= 0, falling back to original");
        $effective_dur = $cue_duration_s;
        $start_secs    = $cue_start_secs;
    }

    # flac -dc can only decode FLAC.  Non-FLAC source files (MP3, APE,
    # WavPack, ALAC, WAV) route through the VirtualPlayer which delegates
    # to LMS's native transcode framework.  We preserve the #start-end URL
    # fragment so LMS's TranscodingHelper can extract the CUE time range
    # and handle seeking natively (findFrameBoundaries, MP3::Cut::Gapless,
    # byte-rate estimation, or decoder flags like --skip/--until).
    # Output is always MP3 (VirtualPlayer outputMime is audio/mpeg).
    # LMS transcode cache handles repeat plays — no separate format cache.
    #
    # FUTURE: Lossless exotic formats (APE/CUE, WavPack/CUE, ALAC/CUE)
    # currently lose quality through this path (always MP3 output).  When a
    # client requests raw/FLAC from one of these sources, we should extract
    # a lossless segment (via ffmpeg or format-specific tools) into the
    # format cache, then flow through _deliverExoticFlac — the same pattern
    # FLAC/CUE uses today.  That preserves lossless passthrough when the
    # client asks for it, while the VP→MP3 path handles the transcode case.
    my %flac_suffixes = map { $_ => 1 } qw(flac flc);
    unless ( $flac_suffixes{ lc($suffix) } ) {
        $log->debug("SlimPing: CUE non-FLAC source (suffix=$suffix), routing via LMS native seeking");
        require Plugins::SlimPing::Core::VirtualPlayer;
        Plugins::SlimPing::Core::VirtualPlayer::streamViaPipeline(
            httpClient     => $httpClient,
            response       => $response,
            source_url     => "slimping://" . $track->{id} . "/library",
            sq_id          => $track->{id},
            client_name    => $client_name,
            format         => 'mp3',                                       # VP output is always MP3
            time_offset    => $client_time_offset,                         # extra client seek only
            is_download    => $is_download,
            is_remote      => 0,
            output_br_kbps => $max_bitrate || 320,
            duration_s     => $effective_dur,
        );
        return;
    }

    $log->debug(
        sprintf(
            'SlimPing: CUE lossless %s ss=%s t=%s fmt=%s',
            $track->{id}, $start_secs, $effective_dur, $ffmt // 'unknown'
        )
    );

    # Build cache key encoding time range so concurrent requests for
    # different segments of the same CUE track do not falsely collide.
    # Use floating-point seconds formatted with sprintf rather than int()
    # on sample counts — the product (seconds × sample_rate) exceeds the
    # 32-bit signed integer range for audiobooks and long classical works
    # (8+ hours at 44.1 kHz = ~1.4e9 samples), triggering "fixed-point
    # overflow" warnings from Perl's int() on 32-bit-constrained systems.
    my $samplerate    = $track->{samplingRate} || 44100;
    my $start_samples = sprintf( '%.0f', $start_secs * $samplerate );
    my $end_samples   = sprintf( '%.0f', ( $start_secs + $effective_dur ) * $samplerate );
    my $cache_key     = join( ':', $track->{id}, $suffix, "${start_samples}-${end_samples}" );
    my $range_key     = join( ':', $track->{id}, "${start_samples}-${end_samples}" );

    # Reserve the output path.  prepareFormatOutput returns a cache hit
    # (ready=>1), a reserved temp path (ready=>0), or undef (inflight).
    my $cache    = Plugins::SlimPing::Core::TranscodeCache->getInstance;
    my $prepared = eval { $cache->prepareFormatOutput( $range_key, $suffix ); };

    if ( $prepared && $prepared->{ready} ) {
        $log->debug( sprintf( 'SlimPing: CUE cache HIT %s (%d bytes)', $track->{id}, $prepared->{size} ) );

        # Seeking is baked into the transcode command via --skip; at serve
        # time we hand the already-positioned FLAC file to
        # _deliverExoticFlac, which decides between direct FLAC delivery
        # and the FLAC->MP3 pipeline (slimping:// cache variant) — the same
        # decision the transcode-completion path makes, so cache hits
        # honour the client's requested format and bitrate cap.  The source
        # is still converted to FLAC exactly once; MP3 output is produced
        # by Lyrion's pipeline from the cached FLAC pointer.
        Plugins::SlimPing::Handlers::Stream::AudioDelivery::_deliverExoticFlac(
            httpClient  => $httpClient,
            response    => $response,
            flac_path   => $prepared->{path},
            flac_size   => $prepared->{size},
            sq_id       => $track->{id},
            client_name => $client_name,
            format      => $format,
            max_bitrate => $max_bitrate,
            time_offset => 0,                   # seeking baked into transcode
                                                # Only full segments may populate the transcode cache --
                                                # client-seeked segments would pollute the full-track key.
            duration    => $client_time_offset ? 0 : $effective_dur,
            is_download => $is_download,
        );
        return;
    }

    my $output_path = $prepared ? $prepared->{path} : '';
    my $we_claimed  = $prepared && !$prepared->{ready};

    my $flac_bin = Plugins::SlimPing::Core::ExternalProcess::flacPath();

    # Two-stage pipeline: flac -dc produces WAV (with correct header
    # carrying bit depth, sample rate, and channels from the source),
    # then flac -5 reads WAV from stdin and re-encodes a FLAC segment
    # with correct STREAMINFO.  No format flags needed — the WAV header
    # communicates everything, so bit depth, sample rate, and channel
    # count are preserved exactly (a true side-grade, no quality loss).
    my $skip_str  = formatFlacTime($start_secs);
    my $until_str = formatFlacTime($effective_dur);

    my $cmd_decode = [ $flac_bin, '-dc', '--silent', "--skip=$skip_str", "--until=+$until_str", '--', $path, ];
    my $cmd_encode = [ $flac_bin, '-5',  '--silent', ];

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

    my $started = Plugins::SlimPing::Core::ExternalProcess->spawnPipeline(
        cmd_decode   => $cmd_decode,
        cmd_encode   => $cmd_encode,
        tmp_path     => $output_path,
        cache_key    => $cache_key,
        cache_sq_id  => $range_key,
        cache_suffix => $suffix,
        timeout_s    => 120,
        on_complete  => sub {
            my ($serve_path) = @_;
            my $size = -s $serve_path;
            unless ($size) {
                $log->error("SlimPing: CUE lossless serve path missing/empty: $serve_path");
                Plugins::SlimPing::Handlers::Stream::AudioDelivery::_send500( $httpClient, $response );
                return;
            }
            $log->debug( sprintf( 'SlimPing: CUE lossless serving %d bytes', $size ) );

            # Seeking is baked into the transcode command via --skip, so
            # time_offset and duration are passed as zero — serve from byte 0.
            Plugins::SlimPing::Handlers::Stream::AudioDelivery::_deliverExoticFlac(
                httpClient  => $httpClient,
                response    => $response,
                flac_path   => $serve_path,
                flac_size   => $size,
                sq_id       => $track->{id},
                client_name => $client_name,
                format      => $format,
                max_bitrate => $max_bitrate,
                time_offset => 0,              # seeking baked into transcode
                                               # Only full segments may populate the transcode cache --
                                               # client-seeked segments would pollute the full-track key.
                duration    => $client_time_offset ? 0 : $effective_dur,
                is_download => $is_download,
            );
        },
        on_error => sub {
            my ($reason) = @_;
            $log->warn("SlimPing: CUE lossless failed for $track->{id}: $reason");
            if ($we_claimed) {
                eval { $cache->discardFormatOutput( $range_key, $output_path, $suffix ); };
                if ($@) {
                    $log->warn("SlimPing: CUE lossless discard failed: $@");
                }
            }
            require Plugins::SlimPing::API::Router;
            Plugins::SlimPing::API::Router->sendError( $httpClient, $response, {}, 0,
                'CUE segment transcode failed — the source file may be corrupt' );
        },
        httpClient => $httpClient,
        response   => $response,
    );

    if ( $started == 2 ) {
        return;    # waiter -- callback will fire when transcode completes
    }
    unless ($started) {
        if ($we_claimed) {
            eval { $cache->discardFormatOutput( $range_key, $output_path, $suffix ); };
            if ($@) {
                $log->warn("SlimPing: CUE lossless discard on spawn-fail error: $@");
            }
        }
        $log->warn("SlimPing: CUE lossless spawn failed for $cache_key");
        require Plugins::SlimPing::API::Router;
        Plugins::SlimPing::API::Router->sendError( $httpClient, $response, {}, 0,
            'CUE segment transcode could not start — retry later' );
        return;
    }
}

1;
