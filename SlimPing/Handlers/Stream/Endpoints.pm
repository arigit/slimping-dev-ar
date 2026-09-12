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
# Handlers/Stream/Endpoints.pm - Streaming and media-delivery endpoints
#
# Registers OpenSubsonic stream, download, and cover art endpoints with the
# Router.  Audio delivery uses a two-path dispatch: files requiring no
# processing are served directly from the filesystem; everything else (remote
# tracks, local tracks needing format conversion or bitrate capping) streams
# through a virtual LMS player pipeline that handles protocol resolution and
# transcoding.  Cover art is retrieved via LibraryMapper and optionally resized
# through Slim::Utils::ImageResizer before delivery.
#
# Lives under Handlers/Stream/ alongside AudioDelivery.pm.  Previously
# Stream.pm at the parent level — moved into the directory to eliminate the
# file/directory coexistence confusion.  Perl resolves
# Plugins::SlimPing::Handlers::Stream::Endpoints from
# Handlers/Stream/Endpoints.pm via @INC path search.
#

package Plugins::SlimPing::Handlers::Stream::Endpoints;

use strict;
use warnings;

use Slim::Utils::ImageResizer;
use Slim::Web::HTTP;
use Time::HiRes  qw(time);
require Plugins::SlimPing::API::Router;
require Plugins::SlimPing::Core::LibraryMapper;
require Plugins::SlimPing::Core::Logging;
require Plugins::SlimPing::Core::Container;
require Plugins::SlimPing::Handlers::Stream::AudioDelivery;

my $log = Plugins::SlimPing::Core::Logging->getLogger();

# Remembered client bitrate caps from getTranscodeDecision.
# Keyed by "username:client_name" -- stores { br => kbps, ts => epoch }.
# br is the last maxAudioBitrate or maxTranscodingAudioBitrate the client
# declared.  ts is the Unix epoch of the last stream request from that
# client, updated on every _serveAudio access so that the periodic sweep
# evicts the least-recently-used entries rather than the lowest-bitrate
# ones.  A client that streams regularly keeps its entry regardless of
# how low its cap is.
my %_client_max_audio_br;
my %_client_max_transcode_br;

# Sweep counter for periodic capping of the remembered-bitrate hashes.
# Every 100th getTranscodeDecision call, entries exceeding 500 are
# trimmed by LRU (oldest access-timestamp first).
my $_client_br_sweep_count = 0;

sub registerHandlers {
    my $class = shift;
    Plugins::SlimPing::API::Router->registerStreamHandler( 'stream',      \&_serveStream );
    Plugins::SlimPing::API::Router->registerStreamHandler( 'download',    \&_serveDownload );
    Plugins::SlimPing::API::Router->registerStreamHandler( 'getCoverArt', \&_coverArtRaw );

    # Transcode-decision endpoints live in TranscodeDecision.pm.
    require Plugins::SlimPing::Handlers::Stream::TranscodeDecision;
    Plugins::SlimPing::Handlers::Stream::TranscodeDecision->registerHandlers();
}

sub _serveAudio {
    my ( $httpClient, $response, $args, $is_download ) = @_;
    my $p = $args->{params};
    my $user       = $args->{user}{username} || '_anon';
    my $client     = $p->{c} || 'unknown';
    my $key        = "$user:$client";

    # Read remembered caps, bump the access timestamp so the sweep
    # evicts least-recently-used entries rather than low-bitrate ones.
    my $now        = time();
    my $audio_br   = $_client_max_audio_br{$key};
    my $transcode_br = $_client_max_transcode_br{$key};
    my $cached_cap_kbps = 0;
    if ($audio_br) {
        $_client_max_audio_br{$key}{ts} = $now;
        $cached_cap_kbps = $audio_br->{br};
    }
    if ($transcode_br) {
        $_client_max_transcode_br{$key}{ts} = $now;
        $cached_cap_kbps = $transcode_br->{br} if !$cached_cap_kbps;
    }

    Plugins::SlimPing::Handlers::Stream::AudioDelivery::serve(
        $httpClient, $response, $args, $is_download, $cached_cap_kbps
    );
}

sub _serveStream   { _serveAudio( $_[0], $_[1], $_[2], 0 ); }
sub _serveDownload { _serveAudio( $_[0], $_[1], $_[2], 1 ); }

# Remember or clear per-client bitrate caps declared via getTranscodeDecision.
# These serve as a fallback when a classic stream.view request omits maxBitRate.
#
# Named params (hashref):
#   user            => $user hashref (required)
#   client_name     => client string (required)
#   max_audio_br    => maxAudioBitrate in kbps, 0 = unlimited
#   max_transcode_br=> maxTranscodingAudioBitrate in kbps, 0 = unlimited
#   explicit_audio  => bool — true when maxAudioBitrate was present in the JSON body
#   explicit_transcode => bool — true when maxTranscodingAudioBitrate was present
#
# When a field was explicitly set to 0 the remembered cap is deleted (the client
# is signalling "no limit" and an earlier cap from a prior session must not
# persist).  When a field was absent from the body, the remembered cap is left
# untouched — the client simply didn't state a preference this time.
sub _rememberClientBitrateCap {
    my ($opts) = @_;
    my $user             = $opts->{user};
    my $client_name      = $opts->{client_name};
    my $max_audio_br     = $opts->{max_audio_br}     // 0;
    my $max_transcode_br = $opts->{max_transcode_br} // 0;
    my $explicit_audio   = $opts->{explicit_audio};
    my $explicit_transcode = $opts->{explicit_transcode};

    return unless $explicit_audio || $explicit_transcode;

    my $key = ( $user->{username} || '_anon' ) . ':' . ( $client_name || 'unknown' );
    my $now = time();

    if ($explicit_audio) {
        if ( $max_audio_br > 0 ) {
            $_client_max_audio_br{$key} = { br => $max_audio_br, ts => $now };
        }
        else {
            delete $_client_max_audio_br{$key};
        }
    }
    if ($explicit_transcode) {
        if ( $max_transcode_br > 0 ) {
            $_client_max_transcode_br{$key} = { br => $max_transcode_br, ts => $now };
        }
        else {
            delete $_client_max_transcode_br{$key};
        }
    }

    # Periodic sweep: every 100th getTranscodeDecision call, cap each hash
    # at 500 entries, evicting the least-recently-used (oldest ts).
    if ( ++$_client_br_sweep_count % 100 == 0 ) {
        my $max = 500;
        for my $hash ( \( %_client_max_audio_br, %_client_max_transcode_br ) ) {
            if ( keys(%$hash) > $max ) {
                my @sorted = sort { $hash->{$a}{ts} <=> $hash->{$b}{ts} } keys %$hash;
                my $cut = int( $max * 0.8 );
                delete @$hash{ @sorted[ $cut .. $#sorted ] };
            }
        }
    }
}

sub _coverArtRaw {
    my ( $httpClient, $response, $args ) = @_;
    my $p     = $args->{params};
    my $sq_id = $p->{id};
    my $size  = $p->{size} // 0;

    my $t0 = time();

    require Plugins::SlimPing::Auth::Permissions;
    if ( Plugins::SlimPing::Auth::Permissions->requireRole( $args->{user}, 'coverArtRole' ) ) {
        Plugins::SlimPing::API::Router->sendError( $httpClient, $response, $p, 50, 'User is not authorised for this operation' );
        return;
    }

    unless ($sq_id) {
        Plugins::SlimPing::API::Router->sendError( $httpClient, $response, $p, 10, 'Required parameter id is missing' );
        return;
    }

    my ( $type ) = Plugins::SlimPing::Core::LibraryMapper->decodeId($sq_id);
    unless ( defined $type ) {
        Plugins::SlimPing::API::Router->sendError( $httpClient, $response, $p, 70, 'Cover art not found' );
        return;
    }

    my ( $body, $content_type );

    if ( $type eq 'radio' ) {
        unless ( Plugins::SlimPing::Core::Logging->isFeatureEnabled('feature_internet_radio') ) {
            Plugins::SlimPing::API::Router->sendError( $httpClient, $response, $p, 0, 'Not implemented: internet radio cover art' );
            return;
        }
        my $mapper   = Plugins::SlimPing::Core::Container->get('library_mapper');
        my $icon_url = $mapper->getRadioIconUrl($sq_id);
        if ($icon_url) {
            if ( $icon_url =~ /^https?:\/\// ) {
                require LWP::UserAgent;
                my $ua = LWP::UserAgent->new(
                    timeout  => 10,
                    agent    => 'SlimPing/0.1',
                    max_size => 5_242_880,
                );
                my $res = $ua->get($icon_url);
                if ( $res->is_success ) {
                    $body         = $res->decoded_content();
                    $content_type = $res->header('Content-Type');
                }
            }
            elsif ( $icon_url =~ m{^/imageproxy/} ) {
                my ($encoded) = $icon_url =~ m{/imageproxy/(.*)/[^/]+$};
                if ($encoded) {
                    my $real_url = URI::Escape::uri_unescape($encoded);
                    if ( $real_url =~ /^https?:\/\// ) {
                        require LWP::UserAgent;
                        my $ua = LWP::UserAgent->new(
                            timeout  => 10,
                            agent    => 'SlimPing/0.1',
                            max_size => 5_242_880,
                        );
                        my $res = $ua->get($real_url);
                        if ( $res->is_success ) {
                            $body         = $res->decoded_content();
                            $content_type = $res->header('Content-Type');
                        }
                    }
                }
            }
            else {
                require Slim::Music::Artwork;
                ( $body, $content_type ) = Slim::Music::Artwork->getImageContentAndType($icon_url);
            }
        }

        # Fall back to shipped default radio icon when no OPML image exists
        # or the OPML image could not be fetched.  Consistent with the
        # three-path fallback in radioMetadata (InternetRadio.pm).
        unless ($body) {
            ( $body, $content_type ) = Plugins::SlimPing::Core::VirtualPlayer->readDefaultArtwork('radio');
        }
    }
    elsif ( $type eq 'dynamic_playlist' ) {
        # Serve the search icon for DPL playlists so they are visually distinct
        # from user-created SSP playlists in OpenSubsonic clients.
        ( $body, $content_type ) = Plugins::SlimPing::Core::VirtualPlayer->readDefaultArtwork('dpl');
        unless ($body) {
            ( $body, $content_type ) = Plugins::SlimPing::Core::VirtualPlayer->readDefaultArtwork('radio');
        }
    }
    else {
        require Plugins::SlimPing::Core::CoverArtResolver;
        ( $body, $content_type ) = Plugins::SlimPing::Core::CoverArtResolver->resolve($sq_id);
    }

    unless ($body) {
        Plugins::SlimPing::API::Router->sendError( $httpClient, $response, $p, 70, 'Cover art not found' );
        return;
    }

    $content_type ||= 'image/jpeg';

    my $t_locate = time();

    # Resize if client requested a specific size (synchronous, in-process).
    if ( $size && $size > 0 ) {
        Slim::Utils::ImageResizer::sync_resize(
            \$body,
            "slimping_cover_${sq_id}_${size}",
            "${size}x${size}_o",
            sub {
                my ( $resized_ref, $fmt ) = @_;
                if ( $resized_ref && length($$resized_ref) ) {
                    $body         = $$resized_ref;
                    $content_type = "image/$fmt" if $fmt;
                }
            }
        );
    }

    $response->code(200);
    $response->header( 'Content-Type'   => $content_type );
    $response->header( 'Content-Length' => length($body) );
    $response->header( 'Cache-Control'  => 'private, max-age=86400' );
    Slim::Web::HTTP::addHTTPResponse( $httpClient, $response, \$body );

    $log->debug(
        sprintf(
            'SlimPing: coverArt %s size=%s (%.1fms locate + %.1fms resize/send, %d bytes)',
            $sq_id,
            $size || 'orig',
            ( $t_locate - $t0 ) * 1000,
            ( time() - $t_locate ) * 1000,
            length($body)
        )
    );
}

1;
