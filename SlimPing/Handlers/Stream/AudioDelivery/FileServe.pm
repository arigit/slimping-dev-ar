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
# Handlers/Stream/AudioDelivery/FileServe.pm - Direct file serving for SlimPing
#
# Extracted from AudioDelivery.pm.  Handles direct file serve with HTTP Range
# support, Content-Disposition headers, FLAC re-encode-on-seek, and byte-offset
# file delivery.
#

package Plugins::SlimPing::Handlers::Stream::AudioDelivery::FileServe;

use strict;
use warnings;

use Slim::Utils::Misc;
use Slim::Web::HTTP;
use URI::Escape qw(uri_escape_utf8);
require Plugins::SlimPing::Core::Container;
require Plugins::SlimPing::Core::Logging;

my $log = Plugins::SlimPing::Core::Logging->getLogger();

# --- Content-Disposition -------------------------------------------------------

sub setContentDisposition {
    my ( $response, $raw ) = @_;
    my $name = defined $raw ? $raw : 'download';

    my $ascii = $name;
    $ascii =~ s/[\x00-\x1f\x7f]/_/g;
    $ascii =~ s/["\\]/_/g;
    $ascii = substr( $ascii, 0, 200 ) if length($ascii) > 200;
    $ascii = 'download'               if $ascii eq '';

    my $disp = qq{attachment; filename="$ascii"};
    if ( $ascii ne $name ) {
        my $encoded = uri_escape_utf8( $name, qq{^A-Za-z0-9._~-} );
        $disp .= qq{; filename*=UTF-8''$encoded};
    }
    $response->header( 'Content-Disposition' => $disp );
    return;
}

# --- File delivery -------------------------------------------------------------

# Serve a file to an OpenSubsonic client.
#
# $file_url / $override_path: one must be provided.  Normal library files
# pass a file:// URL; exotic-format transcode outputs (DSD->FLAC, CUE->FLAC)
# pass $override_path (the cached or temp file path) and leave $file_url
# as undef.  When $override_path is set, $content_type is used verbatim
# (the caller knows the exact MIME).
#
# Direct file serve: the filehandle is seekable, so genuine HTTP Range
# requests (Range: bytes=start-) are honoured with 206 Partial Content
# and Content-Range.  timeOffset-only requests (no Range header) return
# 200 -- timeOffset is a semantic reposition, not an HTTP Range request.
# Transcode pipeline responses route through a separate path that sets
# Accept-Ranges: none (pipe output is not seekable).
sub serveFile {
    my %args = @_;

    my $httpClient    = $args{httpClient};
    my $response      = $args{response};
    my $file_url      = $args{file_url};
    my $override_path = $args{override_path};
    my $content_type  = $args{content_type};
    my $is_download   = $args{is_download} // 0;
    my $time_offset   = $args{time_offset} // 0;
    my $duration      = $args{duration}    // 0;
    my $file_size     = $args{file_size};
    my $http_range    = $args{http_range};
    my $sq_id         = $args{sq_id};

    my $path = $override_path // Slim::Utils::Misc::pathFromFileURL($file_url);

    unless ( defined $path && length $path ) {
        my $id = $override_path || $file_url || '(none)';
        $log->error("SlimPing: _serveFile called with unresolvable path: $id");
        return Plugins::SlimPing::Handlers::Stream::AudioDelivery::_send500( $httpClient, $response );
    }

    $file_size //= ( -s $path ) // 0;

    # Determine the effective byte offset: for FLAC files with a time
    # offset, use LMS's findFrameBoundaries to map time→byte precisely
    # via the FLAC seek table.  For all other formats, and for bare
    # Range headers, use the header value or a proportional estimate.
    my $effective_byte_start;
    if ( $time_offset && $time_offset > 0 && $duration && $duration > 0 ) {

        # FLAC: use the format-class frame-boundary finder so the byte
        # offset lands on a valid frame start.  Falls back to proportional
        # estimate if the format class or seek table is unavailable.
        if ( $content_type && $content_type eq 'audio/flac' ) {
            $effective_byte_start = _flacFrameBoundary( $path, $time_offset );
        }

        # For all other formats (or when the FLAC seek table is absent),
        # use a proportional estimate.  VBR skew is tolerable — decoders
        # resync at the next frame boundary.
        $effective_byte_start //= int( ( $time_offset / $duration ) * $file_size );
    }
    elsif ( $http_range && $http_range =~ /^bytes=(\d+)-/ ) {
        $effective_byte_start = $1;
    }

    # For byte-range requests, duration is not required — the client
    # supplied a byte offset directly.  Keep the duration gate for
    # time-offset seeks (which need duration to compute the proportional
    # byte offset) but allow bare Range headers through regardless.
    my $is_byte_range = $http_range && $http_range =~ /^bytes=(\d+)-/;
    if ( defined $effective_byte_start && $effective_byte_start > 0
         && ( $is_byte_range || ( $duration && $duration > 0 ) )
         && $file_size > 0 ) {

        # Inject a synthetic Range header and delegate to LMS's
        # sendStreamingFile, which handles regular-file seeking
        # correctly.  This returns 206 with Content-Range, which is
        # the HTTP-correct response for a byte-range request.
        # KNOWN ISSUE: getTranscodeStream clients (Symfonium) may not
        # handle 206 responses correctly for this endpoint — they
        # expect 200.  See working-docs/exotic-format-seeking-
        # investigation-2026-06-18.md for full analysis.
        my $byte_offset = $effective_byte_start;
        $byte_offset = $file_size - 1 if $byte_offset >= $file_size;

        my $req = $response->request();
        if ($req) {
            $req->header( 'Range' => "bytes=$byte_offset-" );
        }

        if ($is_download) {
            my $fname = ( split /\//, $path )[-1];
            setContentDisposition( $response, $fname );
        } else {
            $response->header( 'Content-Disposition' => 'inline' );
        }

        Slim::Web::HTTP::sendStreamingFile( $httpClient, $response,
            $content_type
              || Plugins::SlimPing::Core::Container->get('library_mapper')->outputMime(),
            $path, undef, !$is_download );
        return;
    }

    # Range bytes=0- (or time_offset=0): the client requested from the
    # start of the file.  Respond 206 with full Content-Range but don't
    # seek — serve the complete file.
    if ( defined $effective_byte_start && $effective_byte_start == 0
         && $http_range && $http_range =~ /^bytes=(\d+)-/ )
    {
        $response->code(206);
        $response->header( 'Accept-Ranges'  => 'bytes' );
        $response->header( 'Content-Range'  => "bytes 0-" . ( $file_size - 1 ) . "/$file_size" );
        $response->header( 'Content-Length' => $file_size );
        $response->header( 'Content-Type'   => $content_type
              || Plugins::SlimPing::Core::Container->get('library_mapper')->outputMime() );
        if ($is_download) {
            my $fname = ( split /\//, $path )[-1];
            setContentDisposition( $response, $fname );
        } else {
            $response->header( 'Content-Disposition' => 'inline' );
        }

        Slim::Web::HTTP::sendStreamingFile( $httpClient, $response, $content_type, $path, undef, !$is_download );
        return;
    }

    # Byte-range fallback: the client sent a Range header but we could not
    # compute the byte offset ourselves (no duration for time→byte mapping,
    # and no file_size for Content-Range validation).  Inject the raw Range
    # header into the request and delegate to LMS's sendStreamingFile, which
    # has its own Range/206 handling for regular files.
    if ($is_byte_range) {
        my $req = $response->request();
        if ($req) {
            $req->header( 'Range' => $http_range );
        }
        $response->code(200);
        $response->header( 'Accept-Ranges' => 'bytes' );
        $response->header( 'Content-Type' => $content_type
              || Plugins::SlimPing::Core::Container->get('library_mapper')->outputMime() );
        if ($is_download) {
            my $fname = ( split /\//, $path )[-1];
            setContentDisposition( $response, $fname );
        } else {
            $response->header( 'Content-Disposition' => 'inline' );
        }
        Slim::Web::HTTP::sendStreamingFile( $httpClient, $response, $content_type, $path, undef, !$is_download );
        return;
    }

    # Non-seek path -- delegate to LMS's sendStreamingFile for proper
    # Content-Length, Content-Type, and If-Range handling.
    $response->code(200);
    $response->header( 'Accept-Ranges' => 'bytes' );
    $response->header( 'Content-Type' => $content_type
          || Plugins::SlimPing::Core::Container->get('library_mapper')->outputMime() );
    if ($is_download) {
        my $fname = ( split /\//, $path )[-1];
        setContentDisposition( $response, $fname );
    } else {
        $response->header( 'Content-Disposition' => 'inline' );
    }

    Slim::Web::HTTP::sendStreamingFile( $httpClient, $response, $content_type, $path, undef, !$is_download );
    return;
}

# Map a time offset (seconds) to a byte offset within a FLAC file using
# LMS's format-aware frame-boundary finder.  Uses the FLAC SEEKTABLE when
# available; falls back to linear scan for files without one.  Returns the
# byte offset on success, or undef when the format class or seek table is
# unavailable (caller falls back to proportional estimate).
sub _flacFrameBoundary {
    my ( $path, $time_offset ) = @_;

    require FileHandle;
    my $fh = FileHandle->new($path);
    return undef unless $fh;

    require Slim::Formats;
    my $flac_class = Slim::Formats->classForFormat('flc');
    unless ( $flac_class && $flac_class->can('findFrameBoundaries') ) {
        close($fh);
        return undef;
    }

    my $byte_offset = $flac_class->findFrameBoundaries( $fh, undef, $time_offset );
    close($fh);

    return undef unless defined $byte_offset && $byte_offset >= 0;
    return $byte_offset;
}

1;
