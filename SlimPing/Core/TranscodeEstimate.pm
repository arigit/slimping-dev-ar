package Plugins::SlimPing::Core::TranscodeEstimate;

use strict;
use warnings;

# Pure policy module — single source of truth for output bitrate and SIZE.
# No dependencies on Slim::* or other plugin singletons.  Inputs are plain
# scalars and hashrefs.  Outputs are plain hashrefs or undef.
#
# See docs/superpowers/specs/2026-05-24-streaming-seeking-architecture-design.md

my @BITRATE_LADDER = ( 320, 256, 224, 192, 160, 128, 112, 96, 80, 64, 56, 48, 40, 32 );
use constant MAX_OUTPUT_BITRATE => 320;

# Default bitrate (kbps) for remote-track content types whose database bitrate
# column is NULL.  Streaming services like Spotty never persist bitrate so we
# need a format-based fallback for cap decisions and Content-Length estimation.
my %_CT_DEFAULT_BITRATE = (
    spt => 320,
    ogg => 320,
    ops => 320,
    aac => 256,
    alc => 900,
    flc => 900,
    mp3 => 320,
);

# Snap a requested cap to the LAME bitrate ladder.
#   0      -> 0    (no limit)
#   500    -> 320  (above ladder, caps at top)
#   320    -> 320  (exact)
#   200    -> 192  (snapped down)
#   31     -> 32   (floor)
sub snapBitrate {
    my ( undef, $cap_kbps ) = @_;
    return 0 unless $cap_kbps && $cap_kbps > 0;
    foreach my $rate (@BITRATE_LADDER) {
        return $rate if $rate <= $cap_kbps;
    }
    return 32;
}

# Resolve a source bitrate for cap decisions.  Returns the DB value if known,
# else the real plugin quality setting for remote tracks (via StreamingServiceAudit),
# else the hardcoded content-type default, else 0.
sub resolveSourceBitrate {
    my ( undef, $track_bitrate, $is_remote, $content_type ) = @_;
    return $track_bitrate if $track_bitrate && $track_bitrate > 0;
    return 0 unless $is_remote;
    return 0 unless defined $content_type && length $content_type;

    # Try the actual plugin quality/bitrate setting first.  StreamingServiceAudit
    # reads the plugin's own pref (e.g. plugin.spotty::bitrate) so our estimate
    # reflects what the upstream service will actually deliver — no upscaling,
    # accurate Content-Length for CBR output.
    my $plugin_br = eval {
        require Plugins::SlimPing::Core::StreamingServiceAudit;
        Plugins::SlimPing::Core::StreamingServiceAudit
          ->effectiveBitrateForScheme( lc($content_type) );
    };
    return $plugin_br if $plugin_br && $plugin_br > 0;

    # Fall back to hardcoded defaults (plugin not installed, pref read failed).
    return $_CT_DEFAULT_BITRATE{ lc($content_type) } // 0;
}

# Compute the canonical SIZE estimate for a transcoded stream.
#
# Inputs (hashref):
#   duration_s     => track duration in seconds (required)
#   source_br_kbps => source bitrate, if known (0 = unknown)
#   is_remote      => 1 for remote tracks (e.g. Spotty), 0 for local
#   content_type   => suffix string for remote-bitrate fallback (e.g. 'spt')
#   cap_kbps       => requested cap, 0 for none
#
# Returns hashref:
#   { output_br_kbps => N, duration_s => D, size_bytes => S }
# or undef if SIZE cannot be known (no duration, or no resolvable bitrate).
sub estimate {
    my ( undef, $args ) = @_;
    my $cue_duration = $args->{cue_duration} // 0;
    my $duration = $cue_duration > 0 ? $cue_duration : ( $args->{duration_s} // 0 );
    return undef unless $duration > 0;

    my $source_br = __PACKAGE__->resolveSourceBitrate( $args->{source_br_kbps} // 0, $args->{is_remote} // 0,
        $args->{content_type}, );
    my $snapped_cap = __PACKAGE__->snapBitrate( $args->{cap_kbps} // 0 );

    my $output_br;
    if ( $source_br > 0 && $snapped_cap > 0 ) {

        # No upscale — never produce more bits than the source has.
        $output_br = $source_br < $snapped_cap ? $source_br : $snapped_cap;
    }
    elsif ( $source_br > 0 ) {

        # No cap.  Local tracks get the source rate (LMS will not upscale).
        # For local tracks we still cap at MAX_OUTPUT_BITRATE because the
        # pipeline always outputs MP3 — that is the only knob we hold.
        $output_br = $source_br < MAX_OUTPUT_BITRATE ? $source_br : MAX_OUTPUT_BITRATE;
    }
    elsif ( $snapped_cap > 0 ) {

        # No source bitrate known but a cap was set — trust the cap.
        $output_br = $snapped_cap;
    }
    else {
        # Nothing resolvable.  No SIZE.
        return undef;
    }

    # Snap the final output bitrate to the LAME CBR ladder.  When no cap is
    # requested, the resolved source bitrate may be a non-standard value
    # (e.g. a future streaming service quality setting) that LAME cannot
    # encode in --cbr mode.  A non-ladder bitrate causes LAME to silently
    # produce ABR/VBR output, which breaks the SIZE estimate (CBR math).
    # Snapping guarantees the transcodeBitrate set on the virtual player
    # matches a convert.conf rule capability, keeping output deterministic.
    $output_br = __PACKAGE__->snapBitrate($output_br);

    my $size_bytes = int( ( $output_br * 1000 / 8 ) * $duration );
    return {
        output_br_kbps => $output_br,
        duration_s     => $duration,
        size_bytes     => $size_bytes,
    };
}

# Parse an HTTP Range header against a known SIZE and duration.
# Returns { byte_start => N, time_offset_s => T } or undef on parse failure
# or when size_bytes is not positive.
#
# Only "bytes=N-" and "bytes=N-M" are supported; suffix ranges ("bytes=-N")
# and multi-range requests are not.  N is clamped to [0, size_bytes-1].
sub parseRange {
    my ( undef, $range_header, $size_bytes, $duration_s ) = @_;
    return undef unless defined $range_header;
    return undef unless $size_bytes && $size_bytes > 0;
    return undef unless $duration_s && $duration_s > 0;
    return undef unless $range_header =~ /^bytes=(\d+)-/;

    my $byte_start = int($1);
    $byte_start = $size_bytes - 1 if $byte_start >= $size_bytes;

    my $time_offset_s = int( ( $byte_start / $size_bytes ) * $duration_s );
    return {
        byte_start    => $byte_start,
        time_offset_s => $time_offset_s,
    };
}

1;
