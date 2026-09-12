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

# INTERNAL MODULE -- do not use directly. All access through the
# Plugins::SlimPing::Core::LibraryMapper facade.
#
# Core/LibraryMapper/Streaming.pm - Stream URL resolution and internet radio
#
# resolveStreamUrl/resolveFilePath return real URLs (filesystem paths or
# remote stream URLs) and must NEVER appear in API responses.  Internet radio
# methods populate the in-memory radio URL cache used by resolveStreamUrl.
#

package Plugins::SlimPing::Core::LibraryMapper::Streaming;

use strict;
use warnings;

use Digest::MD5 qw(md5_hex);
use Slim::Schema;
use Time::HiRes qw(time);
use Plugins::SlimPing::Core::Logging;
require Plugins::SlimPing::API::ResponseFormatter;

my $log   = Plugins::SlimPing::Core::Logging->getLogger();
my $prefs = Plugins::SlimPing::Core::Logging->getPrefs();

# Internal cache: sq_rd_id => raw external URL.
# Populated by getInternetRadioStations, consumed by resolveStreamUrl.
# Never exposed in API responses (stored separately from station objects).
my %_radio_urls;

# Internal cache: sq_rd_id => icon URL from OPML image attribute.
# Populated by getInternetRadioStations, consumed by Stream::_coverArtRaw.
# Never exposed in API responses.
my %_radio_icons;

# Internal cache: sq_rd_id => station name from OPML text attribute.
my %_radio_names;

# Returns the icon URL for a radio station, or undef.
# Warms the cache from the favourites OPML on miss so that radioMetadata.view
# and getCoverArt.view survive plugin restarts when a client reuses an old ID.
sub getRadioIconUrl {
    my ($self, $sq_id) = @_;
    unless (exists $_radio_icons{$sq_id}) {
        $self->_warmRadioCache();
    }
    return $_radio_icons{$sq_id};
}

# Lightweight cache warm for a single radio icon lookup.  Unlike
# getInternetRadioStations (which resets all caches before loading), this
# loads the favourites OPML and merges any newly discovered stations into
# the existing caches without wiping entries concurrently populated by
# other requests.
sub _warmRadioCache {
    my ($self) = @_;

    require Slim::Plugin::Favorites::OpmlFavorites;
    my $favs   = Slim::Plugin::Favorites::OpmlFavorites->new();
    my $level  = $favs->toplevel();
    return unless $level && ref $level eq 'ARRAY';

    my $radioFolder = _resolveRadioFolder($self, '');
    if ( length $radioFolder ) {
        my $found;
        for my $entry (@$level) {
            if ( ( $entry->{text} // '' ) eq $radioFolder && $entry->{outline} ) {
                $level = $entry->{outline};
                $found = 1;
                last;
            }
        }
        return unless $found;
    }

    my $base_url  = Plugins::SlimPing::Core::LibraryMapper::_requestBaseUrl() // '';
    my $radio_ttl = $prefs->get('radio_token_ttl');

    for my $entry (@$level) {
        next if $entry->{outline};
        next unless ( $entry->{text} // '' ) && ( $entry->{URL} || $entry->{url} );
        next if ( $entry->{type} // '' ) eq 'link';

        my $url   = $entry->{URL} || $entry->{url};
        my $name  = $entry->{text};
        my $image = $entry->{icon} || $entry->{image};

        my $sq_id = $self->encodeId( 'radio', substr( md5_hex($url), 0, 16 ) );
        $_radio_urls{$sq_id}  = $url;
        $_radio_names{$sq_id} = $name;
        $_radio_icons{$sq_id} = $image if $image;
    }
}

# Returns the station name for a radio station, or undef.
sub getRadioName {
    my ($self, $sq_id) = @_;
    return $_radio_names{$sq_id};
}

# Returns the LMS track URL (file:// or http://) for Stream handler internal use ONLY.
# This must never be included in any API response.
sub resolveFilePath {
    my ($self, $sq_id) = @_;
    my ($type, $raw_id) = $self->decodeId($sq_id);
    return undef unless $type && $type eq 'track';
    my $track = Slim::Schema->find('Track', $raw_id);
    return $track ? $track->url() : undef;
}

# Returns a db:track.id=<id> URL suitable for LMS menu item 'url'/'play' fields.
# Unlike resolveFilePath (which returns file:// URLs), this format lets LMS resolve
# the track directly from the database via Slim::Schema::_objForDbUrl, preserving
# library metadata (artist, album, cover art) in Now Playing and track info menus.
sub resolveTrackDbUrl {
    my ($self, $sq_id) = @_;
    my ($type, $raw_id) = $self->decodeId($sq_id);
    return undef unless $type && $type eq 'track';
    return undef unless defined $raw_id && length $raw_id;
    return 'db:track.id=' . $raw_id;
}

# Returns an LMS XML Browser URL for album drill-down navigation.
# Uses Slim::Schema::Album::url() which returns the native format:
#   db:album.title=<escaped>&contributor.name=<escaped>
# The db:album.id=X format does NOT work for LMS menu navigation -- LMS's
# XMLBrowser only understands the title+contributor form.
sub resolveAlbumDbUrl {
    my ($self, $sq_id) = @_;
    my ($type, $raw_id) = $self->decodeId($sq_id);
    return undef unless $type && $type eq 'album';
    return undef unless defined $raw_id && length $raw_id;
    my $album = Slim::Schema->find('Album', $raw_id);
    return undef unless $album;
    return eval { $album->url() };
}

# Returns an LMS XML Browser URL for artist drill-down navigation.
# Uses Slim::Schema::Contributor::url() which returns the native format:
#   db:contributor.name=<escaped>
sub resolveArtistDbUrl {
    my ($self, $sq_id) = @_;
    my ($type, $raw_id) = $self->decodeId($sq_id);
    return undef unless $type && $type eq 'artist';
    return undef unless defined $raw_id && length $raw_id;
    my $contributor = Slim::Schema->find('Contributor', $raw_id);
    return undef unless $contributor;
    return eval { $contributor->url() };
}

# Returns a hashref describing the stream source for any virtual ID, or undef
# if the ID cannot be resolved.  Replaces resolveFilePath for all new callers.
#
# Return shape: { url => $url, is_remote => $bool, scheme => $scheme }
#
# resolveFilePath remains as a backward-compat wrapper that delegates here when
# the type is 'track' -- it is still used by the LMS menu system (InfoMenu.pm).
sub resolveStreamUrl {
    my ($self, $sq_id) = @_;

    my ($type, $raw_id) = $self->decodeId($sq_id);
    return undef unless $type;

    if ($type eq 'track') {
        my $track = Slim::Schema->find('Track', $raw_id);
        return undef unless $track;
        my $url = $track->url();
        return undef unless defined $url && length $url;
        my $audio_offset = $track->audio_offset();

        # A defined audio_offset does not guarantee a CUE / split-track
        # container.  Many standalone files have audio_offset=0 (not NULL) in
        # the LMS database.  Count tracks that genuinely share this container
        # URL -- a CUE split has >=2 tracks at the same base file, a standalone
        # file has exactly 1.
        #
        # LMS stores CUE-split tracks with time-range fragments on the URL:
        #   file:///path/album.flac#0-184.85
        #   file:///path/album.flac#184.85-281.63
        # Each track gets a UNIQUE URL, so an exact match returns count=1.
        # We must strip the fragment and count all tracks sharing the base URL.
        my $is_cue = 0;
        if ( defined $audio_offset ) {
            my $base_url = $url;
            my $has_fragment = ( $base_url =~ s/#\d+(?:\.\d+)?-\d+(?:\.\d+)?$// );

            # Time-based CUE (fragment-bearing) sibling counts are cached per
            # base URL because the count is stable between rescans and the
            # query runs on every stream request.  Generation suffix ensures
            # automatic invalidation when invalidateCache bumps the counter.
            # Byte-offset CUE tracks (no fragment) always query directly --
            # they share identical container URLs and are far less common.
            if ($has_fragment) {
                my $cache_key = "slimping.cue_sibling_count.$base_url.g$self->{_cache_gen}";
                my $cached = $self->{_cache}->get($cache_key);
                if ( defined $cached ) {
                    $is_cue = $cached;
                    $log->debug("SlimPing: CUE is_cue=$is_cue (cache hit, base=$base_url)")
                        if $log->is_debug;
                }
                else {
                    $is_cue = _countCueSiblings( $self, $base_url, $url, $cache_key );
                }
            }
            elsif ( $audio_offset > 0 ) {
                # Byte-offset CUE: tracks share an identical container URL
                # differentiated only by audio_offset.  Far less common than
                # time-based CUE.  audio_offset=0 is NOT a CUE indicator --
                # many standalone files have it set to 0 (not NULL) by LMS.
                $is_cue = _countCueSiblings( $self, $base_url, $url, undef );
            }
            # else: audio_offset=0 with no fragment -- standalone file, not CUE.
        }

        return {
            url           => $url,
            is_remote     => _isRemoteUrl($url),
            scheme        => _urlScheme($url),
            audio_offset  => defined $audio_offset ? $audio_offset : 0,
            is_cue_source => $is_cue,
        };
    }
    elsif ($type eq 'radio') {
        # Refuse to resolve radio stream IDs when the feature is disabled.
        # The feature flag is the single gate -- the handler skips populating
        # the cache, and this branch refuses to lazy-warm it.  A stored
        # sq_rd_id from an earlier session can no longer reach a real URL.
        return undef
            unless Plugins::SlimPing::Core::Logging->isFeatureEnabled('feature_internet_radio');

        # Look up from the cache populated by getInternetRadioStations.
        # If the cache is cold (plugin restart before first radio station query),
        # warm it by calling getInternetRadioStations with an empty username
        # (falls back to the admin-level default folder).
        unless (exists $_radio_urls{$sq_id}) {
            $self->getInternetRadioStations('');
        }
        my $url = $_radio_urls{$sq_id};
        return undef unless $url;
        return {
            url       => $url,
            is_remote => 1,
            scheme    => _urlScheme($url),
        };
    }

    return undef;
}

# Returns an LMS-native cover art URL (/music/<id>/cover.jpg) for use in menu item
# icon/image fields.  Material skin renders these as album art thumbnails.
sub resolveCoverArtUrl {
    my ($self, $sq_id) = @_;
    my ($type, $raw_id) = $self->decodeId($sq_id);
    return undef unless $type && $type eq 'track';
    my $track = Slim::Schema->find('Track', $raw_id);
    return undef unless $track;
    my $album = $track->album();
    return undef unless $album;
    my $artwork = $album->artwork() || $raw_id;
    return "/music/$artwork/cover.jpg";
}

# --- Internet Radio ------------------------------------------------------------

# Returns a Subsonic internetRadioStations list shaped from LMS favourites.
# Loads the favourites OPML, navigates to the configured folder (if set),
# and flattens playable entries into station objects.
sub getInternetRadioStations {
    my ($self, $username) = @_;

    my $t0 = time();

    %_radio_urls  = ();
    %_radio_names = ();
    %_radio_icons = ();

    require Slim::Plugin::Favorites::OpmlFavorites;
    my $favs = Slim::Plugin::Favorites::OpmlFavorites->new();

    # Find the level to expose.  Check per-user override first, then admin
    # default, then fall back to the root.
    my $radioFolder = _resolveRadioFolder($self, $username);

    my $level = $favs->toplevel();
    if (length $radioFolder) {
        # Search for a folder entry with matching text at the root level
        my $found;
        for my $entry (@$level) {
            if (($entry->{text} // '') eq $radioFolder && $entry->{outline}) {
                $level = $entry->{outline};
                $found = 1;
                last;
            }
        }
        # Folder not found -- return empty list
        return [] unless $found;
    }

    my $base_url = Plugins::SlimPing::Core::LibraryMapper::_requestBaseUrl() // '';

    # Embed self-authenticating HMAC tokens in radio stream URLs so that
    # clients can follow the streamUrl without adding Subsonic auth headers.
    # radioStream.view is an overlay endpoint that validates t_stream directly.
    my $radio_ttl = $prefs->get('radio_token_ttl');

    # Flatten playable entries from this level, optionally recursing into
    # subfolders when the admin has enabled the radioFolderRecurse toggle.
    my $recurse = $prefs->get('radioFolderRecurse') ? 1 : 0;
    my @stations = _flattenRadioEntries( $self, $level, $base_url, $radio_ttl, $recurse );

    my $elapsed = sprintf('%.1f', (time() - $t0) * 1000);
    $log->debug("SlimPing: getInternetRadioStations took ${elapsed}ms ("
        . scalar(@stations) . " stations, folder=\"$radioFolder\")")
        if $log->is_debug;

    return \@stations;
}

# Recursively walk an OPML outline level, collecting playable entries into
# station objects.  When $recurse is true, subfolders (entries with an
# outline child) are descended into; otherwise only the current level is
# examined.
sub _flattenRadioEntries {
    my ( $self, $entries, $base_url, $radio_ttl, $recurse ) = @_;

    my @stations;
    for my $entry (@$entries) {
        if ( $entry->{outline} && $recurse ) {
            push @stations,
              _flattenRadioEntries( $self, $entry->{outline}, $base_url,
                $radio_ttl, $recurse );
            next;
        }
        next if $entry->{outline};    # folder, but recursion is off
        next unless ( $entry->{text} // '' ) && ( $entry->{URL} || $entry->{url} );
        next if ( $entry->{type} // '' ) eq 'link';

        my $url   = $entry->{URL} || $entry->{url};
        my $name  = $entry->{text};
        my $image = $entry->{icon} || $entry->{image};

        my $sq_id = $self->encodeId( 'radio', substr( md5_hex($url), 0, 16 ) );
        $_radio_urls{$sq_id}  = $url;
        $_radio_names{$sq_id} = $name;
        $_radio_icons{$sq_id} = $image // '';

        require Plugins::SlimPing::Core::Container;
        my $mgr = Plugins::SlimPing::Core::Container->get('auth_manager');
        my ( $token, $expiry ) = $mgr->generateStreamToken( $sq_id, $radio_ttl );
        my $stream_url = Plugins::SlimPing::API::ResponseFormatter->radioStreamUrl(
            $sq_id,
            base_url      => $base_url,
            token         => $token,
            token_expires => $expiry,
        );

        push @stations, {
            id          => $sq_id,
            name        => $name,
            streamUrl   => $stream_url,
            homePageUrl => '',
            coverArt    => $sq_id,
        };
    }
    return @stations;
}

# Resolve which favourites folder to expose for a given username.
# Order: per-user setting (from Auth::Manager user record) -> admin default pref -> empty string (root).
# Per-user radioFolder on user records is reserved for a future settings UI; currently only
# the admin-level pref is exposed in the web settings page.
sub _resolveRadioFolder {
    my ($self, $username) = @_;

    if (defined $username && length $username) {
        require Plugins::SlimPing::Core::Container;
        my $user = Plugins::SlimPing::Core::Container->get('auth_manager')->getUser($username);
        if ($user && defined $user->{radioFolder} && length $user->{radioFolder}) {
            return $user->{radioFolder};
        }
    }

    return $prefs->get('radioFolder');
}

# Compute the start time (seconds) for a CUE / split-track segment.
#
# Two strategies serve the two CUE representations LMS uses:
#
# 1. Time-based CUE: the track URL carries a #<start>-<end> fragment
#    (e.g. album.flac#184.853-281.627).  The start time is extracted
#    directly from the fragment -- no sibling query needed.
#
# 2. Byte-offset CUE: tracks share an identical container URL and are
#    differentiated by the audio_offset column (byte offset within the
#    file).  The start time is the sum of preceding sibling durations.
#
# Returns 0 for non-CUE tracks or when no preceding siblings exist.
sub getCueStartTime {
    my ( $self, $sq_id, $url, $cue_offset_bytes ) = @_;

    # Time-based CUE: extract start time from the URL fragment.
    # Format: <base_url>#<start_seconds>-<end_seconds>
    # ffmpeg -ss accepts fractional seconds, so pass the value verbatim
    # rather than rounding -- streamcopy seeks to the nearest FLAC frame
    # boundary, which is fine-grained enough for CUE split points.
    if ( $url && $url =~ /#(\d+(?:\.\d+)?)-(\d+(?:\.\d+)?)$/ ) {
        my $start_secs = $1;
        $log->debug("SlimPing: CUE start ${start_secs}s (from URL fragment)");
        return $start_secs;
    }

    # Byte-offset CUE: sum preceding sibling durations.
    return 0 unless $cue_offset_bytes > 0;

    my ( $type, $raw_id ) = $self->decodeId($sq_id);
    return 0 unless $type && $type eq 'track' && defined $raw_id;

    my $track = Slim::Schema->find( 'Track', $raw_id )
      or return 0;

    my $db_url = $track->url || $url;
    return 0 unless defined $db_url && length $db_url;

    # Strip any time-range fragment so the exact URL match finds all
    # siblings sharing the same container file.
    my $base_url = $db_url;
    $base_url =~ s/#\d+(?:\.\d+)?-\d+(?:\.\d+)?$//;

    my $rs = eval {
        Slim::Schema->rs('Track')->search(
            {
                url          => $base_url,
                audio_offset => { '<', $cue_offset_bytes },
            },
            { order_by => 'audio_offset ASC' }
        );
    };
    return 0 if $@ || !$rs;

    my $start_secs = 0;
    while ( my $sibling = $rs->next ) {
        $start_secs += $sibling->secs || 0;
    }

    if ( $start_secs > 0 ) {
        $log->debug(
            sprintf(
                'SlimPing: CUE start %ds (cumulative sibling durations, offset=%d bytes)',
                $start_secs, $cue_offset_bytes
            )
        );
    }

    return $start_secs;
}

# --- CUE sibling-count query ---------------------------------------------------

# Run the sibling-count query for a CUE container base URL and optionally cache
# the result.  Used by resolveStreamUrl to determine is_cue_source.
#
# $cache_key is set (with generation suffix) for time-based CUE (fragment-bearing
# URLs) where the count is stable between rescans.  It is undef for byte-offset
# CUE where caching is not applied.
sub _countCueSiblings {
    my ( $self, $base_url, $original_url, $cache_key ) = @_;

    # Count tracks sharing this base URL.  Two conditions are OR'd:
    #   1. Exact match — catches the hidden LMS container track
    #      (content_type='cur', audio=0, URL with no fragment).
    #   2. LIKE match — catches all CUE-split virtual tracks whose
    #      URL is the base URL followed by "#seconds-seconds".
    #
    # The base URL is used unescaped in the LIKE pattern.  URL-encoded
    # characters (%20, %3B, etc.) contain SQL LIKE metacharacters but
    # this is harmless: the % wildcard matches the literal % in the
    # stored URL (a single character), and the digits that follow
    # (%20 in the pattern matches %20 in the stored URL).  The _ in
    # LIKE patterns matches exactly one character — a practical non-
    # issue because any mismatched character would need the rest of
    # the path AND the #fragment suffix to still align, which is
    # pathologically unlikely for real file system paths.
    my $count = eval {
        Slim::Schema->rs('Track')->search(
            {
                -or => [
                    { url => $base_url },
                    { url => { -like => "$base_url\#%" } },
                ]
            }
        )->count();
    };
    if ($@) {
        $log->warn("SlimPing: sibling count failed for URL $original_url: $@");
        return 0;
    }

    my $is_cue = ( $count && $count > 1 ) ? 1 : 0;

    if ($cache_key) {
        $self->{_cache}->set( $cache_key, $is_cue, 300 );
    }

    $log->debug(
        "SlimPing: CUE sibling count=$count base=$base_url -> is_cue=$is_cue"
    ) if $count && $count > 0;

    return $is_cue;
}

# --- URL classification helpers -----------------------------------------------

# Returns true when $url uses a non-local scheme (http, https, or plugin protocol).
# file:// URLs return false so the existing direct-serve path handles them.
# Plugin-protocol schemes are detected by probing LMS's protocol-handler
# registry rather than hard-coding a list, so newly installed streaming
# plugins are picked up automatically.
sub _isRemoteUrl {
    my ($url) = @_;
    return 0 unless defined $url && length $url;

    my ($scheme) = $url =~ m{^([^:/?#]+):};
    return 0 unless defined $scheme && length $scheme;
    $scheme = lc $scheme;

    # Fast path: well-known schemes whose classification never changes.
    return 1 if $scheme eq 'http' || $scheme eq 'https' || $scheme eq 'icy';
    return 0 if $scheme eq 'file';

    # Delegate everything else to LMS's protocol-handler registry.
    require Slim::Player::ProtocolHandlers;
    return Slim::Player::ProtocolHandlers->isValidHandler($scheme) ? 1 : 0;
}

# Extract the lowercased URL scheme from a URL string.  Returns '' for file://
# paths that don't parse as URLs, 'file' for LMS file-url strings, or the
# protocol scheme for everything else.
sub _urlScheme {
    my ($url) = @_;
    return '' unless defined $url && length $url;
    my ($scheme) = ($url =~ m{^(\w+):}i);
    return lc($scheme // '');
}

1;
