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
# ProtocolHandler.pm - LMS protocol handler for slimping:// URLs
#
# Registered as the handler for the 'slimping' URL scheme.  Extends
# Slim::Player::Protocols::File so LMS's TranscodingHelper can resolve
# cache and library files to real filesystem paths for transcode command
# construction.  Overrides isRemote => 1 to prevent LMS from creating
# permanent tracks rows for transient slimping:// tracks.
#
# URL format: slimping://<identity>/<source>[/<hint>]
#
#   identity  - SlimPing virtual track ID (e.g. sq_tr_42461)
#   source    - source variant: 'cache' or 'library'
#   hint      - optional: MD5-hex filename for cache variant
#
# Source variants:
#   cache    - open from the transcode cache directory (File handler)
#   library  - resolve via resolveStreamUrl(), then delegate to the
#              protocol handler registered for the resolved scheme:
#              File for file:// sources, the service's own handler for
#              remote schemes (qobuz://, tidal://, deezer://...)
#
# isRemote => 1 causes LMS to route the URL through Slim::Schema::RemoteTrack
# (in-memory LRU cache, no database row) instead of creating a permanent
# tracks row.  getMetadataFor resolves the real track metadata from sq_id
# so Now Playing and plugins display correct title/artist/album.

package Plugins::SlimPing::ProtocolHandler;

use strict;
use warnings;
use base qw(Slim::Player::Protocols::File);

require Plugins::SlimPing::Core::Logging;
my $log = Plugins::SlimPing::Core::Logging->getLogger();

# Register with LMS at file-scope — the require in Plugin.pm triggers
# this top-level code.
Slim::Player::ProtocolHandlers->registerHandler( 'slimping', __PACKAGE__ );

# --- LMS Protocol Handler API (class methods) -------------------------------

# Parse a slimping:// URL into its three components:
#   slimping://<identity>/<source>[/<hint>]
# Returns an empty list when the URL is not a valid slimping:// URL.
sub _parseSlimpingUrl {
    my ($url) = @_;
    return () unless defined $url;
    return $url =~ m{^slimping://([^/]+)/([^/]+)(?:/(.+))?$} ? ( $1, $2, $3 ) : ();
}

# isRemote => 1 prevents LMS from creating a permanent tracks row for
# the cache file URL.  The track is stored as a RemoteTrack with
# attributes populated in getNextTrack() (before open() builds the
# transcode command).
sub isRemote { 1 }

# isAudio => 1 tells LMS this handler produces audio data.
sub isAudio { 1 }

# canDirectStream => 0 forces LMS to run the source through its own
# transcode pipeline (convert.conf).  The VirtualPlayer's convert.conf
# rules handle FLAC->MP3 for the slimping client model.
sub canDirectStream { 0 }

# Provide metadata for Now Playing and plugin display.  Called by LMS
# when building the current-song information for the player.
sub getMetadataFor {
    my ( $class, $client, $url ) = @_;

    my ($sq_id) = _parseSlimpingUrl($url);
    return {} unless $sq_id;

    my $meta = _resolveTrackMeta($sq_id);
    return {} unless $meta;

    return $meta;
}

# Report the format so LMS knows which convert.conf rules apply.
# Delegate to _formatForUrl so the cache and library variants resolve
# differently — see that method for the rationale.
sub getFormatForURL {
    my ( $class, $url ) = @_;
    return $class->_formatForUrl($url);
}

# slimping:// URLs are single tracks, never playlists.
sub isPlaylistURL { 0 }

# Same variant-aware format resolution as getFormatForURL, applied at
# transcode time (Slim::Player::Song::open).  LMS caches content-type
# data from getFormatForURL on the track object; this override must
# agree with it so the cached and the authoritative format resolve
# identically.
sub formatOverride {
    my ( $class, $song ) = @_;
    my $track = eval { $song->currentTrack() };
    if ($@) {
        $log->warn("SlimPing: formatOverride currentTrack error: $@");
        return 'unk';
    }
    unless ($track) {
        $log->warn('SlimPing: formatOverride has no current track - cannot resolve format');
        return 'unk';
    }
    return $class->_formatForUrl( $track->url );
}

# Resolve the format for a slimping:// URL.
#
# The cache variant always serves FLAC (DSD->FLAC transcode output), so
# it reports LMS's canonical FLAC identifier 'flc' — not 'flac'.  Every
# FLAC transcode rule in convert.conf keys on 'flc'; returning 'flac'
# matches no rule and falls through to raw passthrough.
#
# The library variant must report the REAL source format.  Hardcoding
# 'flc' for it made LMS build the flc->mp3 chain (flac | sox | lame) for
# MP3 sources, which dies on the first bytes of MP3 data — a regression
# introduced when the normal pipeline migrated to slimping:// URLs.
#
# The format resolves from the source URL after resolveStreamUrl() —
# never through pathFromFileURL(), which is file-specific and would pass
# remote service URLs (qobuz://, tidal://...) into file-path machinery.
# contentType() resolves both file:// and remote URLs: file paths by
# suffix, remote schemes via the types.conf suffix map and, failing that,
# the registered protocol handler's own getFormatForURL().
#
# A non-slimping URL may be received here after getNextTrack() hands the
# track to a remote service handler (the track URL becomes the service's
# URL, or the signed stream URL).  contentType() resolves those directly.
#
# When the real format cannot be resolved the result is 'unk' (LMS's
# unknown type), which matches no transcode rule and fails visibly.
# Falling back to a guessed format would silently build the wrong chain
# — the original bug in a different guise.
sub _formatForUrl {
    my ( $class, $url ) = @_;

    my ( $sq_id, $source ) = _parseSlimpingUrl($url);
    if ( $sq_id && $source ) {
        return 'flc' if $source eq 'cache';

        require Plugins::SlimPing::Core::Container;
        my $mapper = eval { Plugins::SlimPing::Core::Container->get('library_mapper') };
        return 'unk' if $@;

        my $stream_info = eval { $mapper->resolveStreamUrl($sq_id) };
        return 'unk' if $@ || !$stream_info || !$stream_info->{url};

        # Resolve the source URL before contentType() — it must never be
        # called on a slimping:// URL, or the handler registry would
        # re-enter our own getFormatForURL().
        $url = $stream_info->{url};
    }

    require Slim::Music::Info;
    my $type = eval { Slim::Music::Info::contentType($url) };
    if ($@) {
        $log->warn("SlimPing: content-type resolution failed for $url: $@");
    }
    unless ($type) {
        $log->warn("SlimPing: no content type for $url - refusing to guess");
    }
    return $type || 'unk';
}

# Transcode-seek is not supported for cache files.  Explicit declaration
# rather than relying on can() guard semantics.
sub canTranscodeSeek { 0 }

# Validate the URL structure and pass the track to the callback.
# LMS calls scanUrl when adding a URL to the playlist; a missing
# scanUrl causes LMS to treat the URL as unscannable.
sub scanUrl {
    my ( $class, $url, $args ) = @_;
    return $args->{cb}->( $args->{song}->currentTrack() )
      if $url =~ m{^slimping://};
    return undef;
}

# Resolve the slimping:// URL before LMS opens the stream.  Following the
# Qobuz/TIDAL pattern: populate track metadata and set streamUrl in
# getNextTrack(), then open() reads streamUrl and TranscodingHelper
# uses the track's audio properties for convert.conf token substitution.
sub getNextTrack {
    my ( $class, $song, $successCb, $errorCb ) = @_;

    my $url   = $song->currentTrack()->url;
    my $track = $song->currentTrack();

    # Three-component URL: slimping://<id>/<source>[/<hint>]
    my ( $sq_id, $source, $hint ) = _parseSlimpingUrl($url);
    unless ( $sq_id && $source ) {
        $log->warn("SlimPing: getNextTrack cannot parse URL: $url");
        $errorCb->() if $errorCb;
        return;
    }

    # Resolve full track metadata from the LMS database.  Populated on the
    # RemoteTrack so File::open() has secs (duration), TranscodingHelper has
    # audio properties for convert.conf token substitution, and Now Playing
    # displays correct title/artist/album.
    my $meta = _resolveTrackMeta($sq_id);

    if ( $source eq 'library' ) {
        if ($meta) {
            $track->setAttributes($meta);
        }

        require Plugins::SlimPing::Core::Container;
        my $mapper = eval { Plugins::SlimPing::Core::Container->get('library_mapper') };
        unless ($@) {
            my $stream_info = eval { $mapper->resolveStreamUrl($sq_id) };
            unless ( $@ || !$stream_info || !$stream_info->{url} ) {
                $song->streamUrl( $stream_info->{url} );
                $log->debug( "SlimPing: getNextTrack $sq_id library -> " . $stream_info->{url} );

                # Remote service schemes (qobuz://, tidal://, deezer://...)
                # are handled by their own protocol handlers, which resolve
                # the signed stream URL in their getNextTrack() and open it
                # in their new().  Hand them the track with the service URL
                # set so they can crack the track ID from
                # $song->currentTrack()->url.  File sources are handled
                # directly below.
                my $scheme = $stream_info->{scheme} // '';
                if ( length $scheme && $scheme ne 'file' ) {
                    require Slim::Player::ProtocolHandlers;
                    my $delegate = Slim::Player::ProtocolHandlers->handlerForURL( $stream_info->{url} );
                    if ( $delegate && $delegate ne __PACKAGE__ && $delegate->can('getNextTrack') ) {
                        $track->url( $stream_info->{url} );
                        $log->debug("SlimPing: delegating getNextTrack $sq_id to $delegate");
                        return $delegate->getNextTrack( $song, $successCb, $errorCb );
                    }

                    $log->warn("SlimPing: no protocol handler registered for scheme '$scheme' ($sq_id)");
                    $errorCb->() if $errorCb;
                    return;
                }
            }
        }

        return $successCb->();
    }

    if ( $source eq 'cache' && $hint ) {
        if ($meta) {

            # Override audio properties for DSD-sourced cache files: the
            # shaped hash reflects the ORIGINAL 1-bit / 2.8 MHz DSD file,
            # but the FLAC cache file is 24-bit / 44.1 kHz (as encoded by
            # the dsdplay | flac pipeline in AudioDelivery.pm).
            my $suffix = lc( $meta->{suffix} || '' );
            if ( $suffix eq 'dsf' || $suffix eq 'dff' ) {
                require Plugins::SlimPing::Handlers::Stream::AudioDelivery::DsdTranscode;
                $meta->{samplesize} = 24;
                $meta->{samplerate} =
                  Plugins::SlimPing::Handlers::Stream::AudioDelivery::DsdTranscode::selectOutputRate($meta);
                $meta->{channels} = 2;
            }
            $track->setAttributes($meta);
        }

        # Set the actual source URL for the File protocol handler.
        require Plugins::SlimPing::Core::TranscodeCache;
        my $cache    = Plugins::SlimPing::Core::TranscodeCache->getInstance;
        my $base_dir = $cache->getDiskCacheDir();

        if ($base_dir) {
            my $file_path = "$base_dir/$hint";
            $song->streamUrl("file://$file_path");
        }
    }

    $log->debug("SlimPing: getNextTrack $sq_id $source");
    $successCb->();
}

# Resolve all track metadata from the LMS database for a given sq_id.
# Returns a hashref suitable for RemoteTrack->setAttributes(), or undef
# on failure (logged).  Shared between getNextTrack() and getMetadataFor().
sub _resolveTrackMeta {
    my ($sq_id) = @_;

    require Plugins::SlimPing::Core::Container;
    my $mapper = eval { Plugins::SlimPing::Core::Container->get('library_mapper') };
    return undef if $@;

    my $t = eval { $mapper->getTrackById($sq_id) };
    return undef if $@ || !$t;

    return {
        title      => $t->{title}  || '',
        artist     => $t->{artist} || '',
        album      => $t->{album}  || '',
        genre      => $t->{genre}  || '',
        duration   => $t->{duration} // 0,
        secs       => $t->{duration} // 0,
        bitrate    => ( $t->{bitRate} // 0 ) * 1000,    # shaped kbps -> LMS bps
        samplesize => $t->{bitDepth}     // 0,
        samplerate => $t->{samplingRate} // 0,
        channels   => $t->{channelCount} // 0,
        cover      => $t->{coverArt} || '',
        suffix     => $t->{suffix}   || '',
        remote     => 1,
    };
}

# --- Instance methods -------------------------------------------------------

# Intercept pathFromFileURL so the File handler's new() and open() methods
# get a real filesystem path instead of the slimping:// URL.  File::new()
# calls $class->pathFromFileURL($url) at File.pm line 63 to resolve the
# source file path for the transcode command ($FILE$ substitution).
sub pathFromFileURL {
    my ( $class, $url ) = @_;

    # Three-component URL: slimping://<id>/<source>[/<hint>]
    my ( $sq_id, $source, $hint ) = _parseSlimpingUrl($url);
    return $class->SUPER::pathFromFileURL($url) unless $sq_id && $source;

    if ( $source eq 'library' ) {
        require Plugins::SlimPing::Core::Container;
        my $mapper = eval { Plugins::SlimPing::Core::Container->get('library_mapper') };
        return undef if $@;

        my $stream_info = eval { $mapper->resolveStreamUrl($sq_id) };
        return undef if $@ || !$stream_info || !$stream_info->{url};

        # Remote service URLs are opened by their own protocol handlers,
        # never by the File handler.  Returning undef makes any accidental
        # File-handler reach fail cleanly instead of attempting to open a
        # qobuz:// (or similar) URL as a local file path.
        my $scheme = $stream_info->{scheme} // '';
        if ( length $scheme && $scheme ne 'file' ) {
            $log->debug("SlimPing: pathFromFileURL $sq_id library: remote scheme '$scheme' - not a file path");
            return undef;
        }

        # Use LMS's pathFromFileURL for proper URL decoding (%20 -> space).
        require Slim::Utils::Misc;
        my $path = Slim::Utils::Misc::pathFromFileURL( $stream_info->{url} );
        $log->debug("SlimPing: pathFromFileURL $sq_id library -> $path")
          if defined $path;
        return $path;
    }

    if ( $source eq 'cache' && $hint ) {
        require Plugins::SlimPing::Core::TranscodeCache;
        my $cache    = Plugins::SlimPing::Core::TranscodeCache->getInstance;
        my $base_dir = $cache->getDiskCacheDir();

        if ($base_dir) {
            my $file_path = "$base_dir/$hint";
            $log->debug("SlimPing: pathFromFileURL $sq_id cache -> $file_path");
            return $file_path;
        }
    }

    return undef;
}

# Parse the slimping:// URL, validate the source, then delegate to the
# protocol handler registered for the resolved URL scheme.  Local files
# go to the File handler (pathFromFileURL() above handles URL→path
# translation); remote service URLs (qobuz://, tidal://, ...) go to the
# service's own handler, which opens the signed stream URL set by its
# getNextTrack().
#
# A non-slimping URL is received here after getNextTrack() handed the
# track to a remote service handler — the track URL has become the
# service's URL (or its signed stream URL).  Delegate by scheme.
sub new {
    my ( $class, $args ) = @_;
    my $url = $args->{url};

    # Three-component URL: slimping://<id>/<source>[/<hint>]
    my ( $sq_id, $source, $hint ) = _parseSlimpingUrl($url);
    unless ( $sq_id && $source ) {

        # Post-delegation: the track URL is now the service URL or its
        # signed stream URL.  Dispatch on the scheme registered in LMS.
        require Slim::Player::ProtocolHandlers;
        my $delegate = Slim::Player::ProtocolHandlers->handlerForURL($url);
        if ( $delegate && $delegate ne __PACKAGE__ ) {
            $log->debug("SlimPing: protocol handler delegating open of $url to $delegate");
            return $delegate->new($args);
        }

        $log->warn("SlimPing: protocol handler cannot resolve URL: $url");
        return undef;
    }

    if ( $source eq 'library' ) {

        # Resolve via LibraryMapper, then delegate to the handler
        # registered for the resolved scheme: File for file:// sources,
        # the service handler for remote schemes.
        require Plugins::SlimPing::Core::Container;
        my $mapper = eval { Plugins::SlimPing::Core::Container->get('library_mapper') };
        return undef if $@;

        my $stream_info = eval { $mapper->resolveStreamUrl($sq_id) };
        return undef if $@ || !$stream_info || !$stream_info->{url};

        my $resolved_url = $stream_info->{url};
        my $scheme       = $stream_info->{scheme} // '';

        if ( length $scheme && $scheme ne 'file' ) {
            require Slim::Player::ProtocolHandlers;
            my $delegate = Slim::Player::ProtocolHandlers->handlerForURL($resolved_url);
            if ( $delegate && $delegate ne __PACKAGE__ ) {
                $log->debug("SlimPing: protocol handler $sq_id library -> $delegate ($resolved_url)");
                return $delegate->new($args);
            }

            $log->warn("SlimPing: no protocol handler registered for scheme '$scheme' ($sq_id)");
            return undef;
        }

        $log->debug("SlimPing: protocol handler $sq_id library -> $resolved_url");
        return $class->SUPER::new( { %$args, url => $resolved_url } );
    }

    if ( $source eq 'cache' && $hint ) {

        # Validate the cache file exists before delegating.
        require Plugins::SlimPing::Core::TranscodeCache;
        my $cache    = Plugins::SlimPing::Core::TranscodeCache->getInstance;
        my $base_dir = $cache->getDiskCacheDir();
        unless ($base_dir) {
            $log->warn("SlimPing: protocol handler has no disk cache directory");
            return undef;
        }

        my $file_path = "$base_dir/$hint";
        unless ( -f $file_path ) {
            $log->warn("SlimPing: protocol handler cache file not found: $file_path");
            return undef;
        }

        # Delegate to the File protocol handler.  File::new() calls
        # pathFromFileURL($url) to resolve the source path — our override
        # above intercepts the slimping:// URL and returns the real path.
        $log->debug("SlimPing: protocol handler $sq_id cache -> $file_path");
        return $class->SUPER::new($args);
    }

    $log->warn("SlimPing: protocol handler unknown source '$source' for $sq_id");
    return undef;
}

1;
