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
# Core/StreamingServiceAudit.pm - Plugin audit helper for SlimPing dependencies
#
# Stateless class that enumerates Lyrion plugins SlimPing directly depends on or
# interoperates with, reading their installed state, version, and (for streaming
# services) quality/bitrate preferences.  Streaming-service entries additionally
# probe the LMS protocol-handler registry: whether a handler is registered for
# the service's URL scheme and how SlimPing's protocol handler will delegate to
# it (two-phase signed-URL resolution vs self-contained convert.conf command).
# Consumers:
#
#   TranscodeEstimate::resolveSourceBitrate  — accurate source_br_kbps for
#       remote tracks, replacing hardcoded per-scheme defaults
#
#   Core/Settings handler  — populates the "Additional Lyrion Plugins" read-only
#       table in the settings UI
#
# Every plugin-pref read is eval-wrapped.  If a plugin is not installed or has
# changed its pref names, the call returns 0 / installed=0 rather than crashing.
#

package Plugins::SlimPing::Core::StreamingServiceAudit;

use strict;
use warnings;

# Internal specification table.  Each entry describes one Lyrion plugin that
# SlimPing uses.  Streaming-service entries additionally carry the quality/bitrate
# pref details needed by TranscodeEstimate::resolveSourceBitrate.
#
# role values:
#   'streaming'  — remote audio source (Spotify, TIDAL, etc.)
#   'metadata'   — artist/album metadata enrichment
#   'scrobbling' — playback reporting to external services
#
# quality_type values (streaming only):
#   'int'        — pref value is already kbps (Spotty bitrate)
#   'quality'    — pref value is a string label mapped via quality_map
#   'format_id'  — pref value is an integer format ID mapped via quality_map
#
my @_PLUGIN_SPECS = (

    # --- Streaming services ---
    #
    # url_scheme   - the URL scheme registered with LMS (probed via
    #                Slim::Player::ProtocolHandlers->handlerForURL)
    # content_types- source-format codes reported by the service's
    #                formatOverride that unambiguously identify it; used
    #                for bitrate lookups.  Shared codes (flac/flc/mp3/aac)
    #                are deliberately not claimed - the generic defaults
    #                apply.
    {
        name            => 'Spotty',
        url_scheme      => 'spotify',
        content_types   => [qw(spt)],
        label           => 'Spotify (Spotty)',
        role            => 'streaming',
        role_label      => 'Streaming Service',
        module_class    => 'Plugins::Spotty::Plugin',
        prefs_ns        => 'plugin.spotty',
        pref_key        => 'bitrate',
        quality_type    => 'int',
        quality_default => 320,
        quality_map     => undef,
    },
    {
        name            => 'SpotOn',
        url_scheme      => 'spoton',
        content_types   => [qw(son soc)],
        label           => 'Spotify (SpotOn)',
        role            => 'streaming',
        role_label      => 'Streaming Service',
        module_class    => 'Plugins::SpotOn::Plugin',
        prefs_ns        => 'plugin.spoton',
        pref_key        => 'bitrate',
        quality_type    => 'int',
        quality_default => 320,
        quality_map     => undef,
    },
    {
        name            => 'TIDAL',
        url_scheme      => 'tidal',
        content_types   => [],
        label           => 'TIDAL',
        role            => 'streaming',
        role_label      => 'Streaming Service',
        module_class    => 'Plugins::TIDAL::Plugin',
        prefs_ns        => 'plugin.tidal',
        pref_key        => 'quality',
        quality_type    => 'quality',
        quality_default => 'HIGH',
        quality_map     => {
            LOW      => { label => '96 kbps AAC',     br => 96 },
            HIGH     => { label => '320 kbps AAC',    br => 320 },
            LOSSLESS => { label => 'FLAC (lossless)', br => 900 },
            HI_RES   => { label => 'FLAC (hi-res)',   br => 3000 },
        },
    },
    {
        name            => 'Deezer',
        url_scheme      => 'deezer',
        content_types   => [],
        label           => 'Deezer',
        role            => 'streaming',
        role_label      => 'Streaming Service',
        module_class    => 'Plugins::Deezer::Plugin',
        prefs_ns        => 'plugin.deezer',
        pref_key        => 'quality',
        quality_type    => 'quality',
        quality_default => 'HIGH',
        quality_map     => {
            LOW      => { label => '128 kbps MP3',    br => 128 },
            HIGH     => { label => '320 kbps MP3',    br => 320 },
            LOSSLESS => { label => 'FLAC (lossless)', br => 900 },
        },
    },
    {
        name            => 'Qobuz',
        url_scheme      => 'qobuz',
        content_types   => [],
        label           => 'Qobuz',
        role            => 'streaming',
        role_label      => 'Streaming Service',
        module_class    => 'Plugins::Qobuz::Plugin',
        prefs_ns        => 'plugin.qobuz',
        pref_key        => 'preferredFormat',
        quality_type    => 'format_id',
        quality_default => 6,
        quality_map     => {
            5  => { label => 'MP3 320 kbps',         br => 320 },
            6  => { label => 'FLAC (CD quality)',    br => 900 },
            7  => { label => 'FLAC (hi-res 24/96)',  br => 1500 },
            27 => { label => 'FLAC (hi-res 24/192)', br => 3000 },
        },
    },

    # --- Metadata services ---
    {
        name         => 'MusicArtistInfo',
        scheme       => '',
        label        => 'Music & Artist Info',
        role         => 'metadata',
        role_label   => 'Metadata Service',
        module_class => 'Plugins::MusicArtistInfo::Plugin',
    },

    # --- Scrobbling services ---
    {
        name         => 'AudioScrobbler',
        scheme       => '',
        label        => 'Last.fm Scrobbler',
        role         => 'scrobbling',
        role_label   => 'Scrobbler Service',
        module_class => 'Slim::Plugin::AudioScrobbler::Plugin',
    },

    # --- Playlist services ---
    {
        name         => 'DynamicPlaylists4',
        scheme       => '',
        label        => 'Dynamic Playlists',
        role         => 'playlist',
        role_label   => 'Playlist Generation',
        module_class => 'Plugins::DynamicPlaylists4::Plugin',
    },
);

# --- Public API -------------------------------------------------------------

# Return the effective source bitrate (kbps) for a given URL scheme.
# Returns 0 if the plugin is not installed, the pref cannot be read, or
# the scheme is not recognised.  Callers fall back to hardcoded defaults.
sub effectiveBitrateForScheme {
    my ( $class, $scheme ) = @_;
    return 0 unless defined $scheme && length $scheme;
    $scheme = lc($scheme);

    my $spec = _specForScheme($scheme) or return 0;
    return 0 unless $spec->{role} eq 'streaming';
    return _readEffectiveBitrate($spec);
}

# Return a list of hashrefs describing each known plugin.  Each hashref:
# { name, label, role, role_label, installed, version, quality_label,
#   effective_br, url_scheme, handler_class, handler_registered,
#   delegation_mode }
#
# For streaming services the LMS protocol-handler registration is probed:
# handler_registered marks whether a handler for the URL scheme is present,
# and delegation_mode describes how the SlimPing protocol handler will
# delegate to it ('two-phase' handlers resolve the signed stream URL in
# getNextTrack, 'self-contained' handlers let their convert.conf rule pull
# the audio via the $URL$ token, 'none' means playback will fail).
# Used by Core/Settings to populate the settings UI table.
sub audit {
    my ($class) = @_;
    my @results;

    for my $spec (@_PLUGIN_SPECS) {
        my $installed = _probeInstalled($spec);

        my $label           = $spec->{label};
        my $version         = '';
        my $quality_label   = '';
        my $effective_br    = 0;
        my $url_scheme      = $spec->{url_scheme} || '';
        my $handler_class   = '';
        my $delegation_mode = '';

        if ($installed) {
            $version = _readPluginVersion($spec);
            $label   = _readPluginDisplayName($spec) || $spec->{label};

            if ( $spec->{role} eq 'streaming' ) {
                $effective_br  = _readEffectiveBitrate($spec);
                $quality_label = _readQualityLabel($spec);

                # Probe only installed services: handlerForURL can load the
                # handler class (with file-scope registration side effects),
                # so probing uninstalled services wastes a module load per
                # settings render and can register URL regexes for plugins
                # whose init never ran.
                if ($url_scheme) {
                    $handler_class   = _probeHandlerClass($url_scheme);
                    $delegation_mode = _delegationModeFor( $handler_class, $url_scheme );
                }
            }
        }

        push @results,
          {
            name               => $spec->{name},
            label              => $label,
            role               => $spec->{role},
            role_label         => $spec->{role_label},
            installed          => $installed,
            version            => $version,
            quality_label      => $quality_label || '',
            effective_br       => $effective_br,
            url_scheme         => $url_scheme,
            handler_class      => $handler_class || '',
            handler_registered => $handler_class ? 1 : 0,
            delegation_mode    => $delegation_mode,
          };
    }

    return @results;
}

# --- Private helpers --------------------------------------------------------

# Look up a plugin spec by URL scheme or by a source-format code the
# service's formatOverride reports (streaming only).  Callers pass either
# the LMS URL scheme (e.g. 'spotify') or the content-type code (e.g. 'spt').
sub _specForScheme {
    my ($code) = @_;
    return undef unless defined $code && length $code;
    $code = lc($code);

    for my $spec (@_PLUGIN_SPECS) {
        next unless $spec->{role} eq 'streaming';

        if ( $spec->{url_scheme} && $spec->{url_scheme} eq $code ) {
            return $spec;
        }

        if ( $spec->{content_types} ) {
            for my $ct ( @{ $spec->{content_types} } ) {
                return $spec if $ct eq $code;
            }
        }
    }

    return undef;
}

# Resolve the registered protocol-handler class for a URL scheme via LMS's
# own registry.  handlerForURL loads the class (covers both protocol-table
# and regex registrations), so callers can then inspect its capabilities.
# Memoised per scheme: registrations only change at plugin load time, which
# is a server restart away from any settings render.
my %_handler_probe;

sub _probeHandlerClass {
    my ($url_scheme) = @_;
    return '' unless $url_scheme;
    return $_handler_probe{$url_scheme} if exists $_handler_probe{$url_scheme};

    require Slim::Player::ProtocolHandlers;
    my $handler_class = eval { Slim::Player::ProtocolHandlers->handlerForURL("$url_scheme://x"); };
    my $result        = ( $@ || !$handler_class || $handler_class !~ /::/ ) ? '' : $handler_class;
    $_handler_probe{$url_scheme} = $result;
    return $result;
}

# Classify how the SlimPing protocol handler will delegate to a service's
# handler, based on the service handler's capabilities:
#   two-phase      - has getNextTrack: resolves the signed stream URL there,
#                    then opens it in new() (Qobuz, TIDAL, Deezer, SpotOn)
#   self-contained - no getNextTrack: its convert.conf rule pulls the audio
#                    itself via the $URL$ token (Spotty); formatOverride
#                    reports the source format
#   passthrough    - registered, but no known hooks; playback may still work
#                    through contentType/convert.conf defaults
#   none           - no handler registered for the scheme
sub _delegationModeFor {
    my ( $handler_class, $url_scheme ) = @_;
    return 'none' unless $handler_class;

    return 'two-phase'      if $handler_class->can('getNextTrack');
    return 'self-contained' if $handler_class->can('formatOverride');
    return 'passthrough';
}

# Check whether a plugin is installed.  Tries PluginManager first (covers
# third-party plugins under Plugins::), then falls back to %INC (covers core
# LMS plugins under Slim::Plugin:: and Slim::Plugin::).
sub _probeInstalled {
    my ($spec) = @_;
    return 0 unless $spec->{module_class};

    # Third-party plugins: PluginManager has metadata from install.xml
    my $data = eval { Slim::Utils::PluginManager->dataForPlugin( $spec->{module_class} ); };
    return 1 if $data;

    # Core LMS plugins: no PluginManager entry, but the module is in %INC
    my $module_path = $spec->{module_class};
    $module_path =~ s{::}{/}g;
    $module_path .= '.pm';
    return 1 if exists $INC{$module_path};

    return 0;
}

# Read the effective kbps bitrate for a streaming service spec.
# Returns 0 if the pref cannot be read or the value is unrecognised.
sub _readEffectiveBitrate {
    my ($spec) = @_;
    return 0 unless $spec->{prefs_ns} && $spec->{pref_key};

    my $prefs = eval { Slim::Utils::Prefs::preferences( $spec->{prefs_ns} ); };
    return 0 if $@ || !$prefs;

    my $raw = eval { $prefs->get( $spec->{pref_key} ); };
    return 0 if $@;

    my $type = $spec->{quality_type} || '';

    if ( $type eq 'int' ) {
        my $br = int( $raw // $spec->{quality_default} );
        return $br > 0 ? $br : 0;
    }

    if ( $type eq 'quality' || $type eq 'format_id' ) {
        $raw //= $spec->{quality_default};
        my $map   = $spec->{quality_map} || {};
        my $entry = $map->{$raw};
        return $entry ? ( $entry->{br} || 0 ) : 0;
    }

    return 0;
}

# Read the human-readable quality label for a streaming service spec.
# Returns '' if the pref cannot be read.
sub _readQualityLabel {
    my ($spec) = @_;
    return '' unless $spec->{prefs_ns} && $spec->{pref_key};

    my $prefs = eval { Slim::Utils::Prefs::preferences( $spec->{prefs_ns} ); };
    return '' if $@ || !$prefs;

    my $raw = eval { $prefs->get( $spec->{pref_key} ); };
    return '' if $@;

    my $type = $spec->{quality_type} || '';

    if ( $type eq 'int' ) {
        my $br = int( $raw // $spec->{quality_default} );
        return "$br kbps" if $br > 0;
        return '';
    }

    if ( $type eq 'quality' || $type eq 'format_id' ) {
        $raw //= $spec->{quality_default};
        my $map   = $spec->{quality_map} || {};
        my $entry = $map->{$raw};
        return $entry ? ( $entry->{label} || '' ) : "Unknown ($raw)";
    }

    return '';
}

# Read the human-readable display name from the plugin's own metadata.
# Uses the localisation key from install.xml (<name>PLUGIN_SPOTTY_NAME</name>)
# and passes it through LMS's string translation.  Falls back to '' on failure.
sub _readPluginDisplayName {
    my ($spec) = @_;
    return '' unless $spec->{module_class};

    # Third-party plugins: PluginManager has the raw name key
    my $data = eval { Slim::Utils::PluginManager->dataForPlugin( $spec->{module_class} ); };
    if ( $data && $data->{name} ) {
        my $label = eval { Slim::Utils::Strings::string( $data->{name} ); };
        return $label || $data->{name};
    }

    # Core LMS plugins: try install.xml from the module directory via %INC
    my $xml = _readInstallXmlValue( $spec, 'name' );
    if ($xml) {
        my $label = eval { Slim::Utils::Strings::string($xml); };
        return $label || $xml;
    }

    return '';
}

# Read the plugin version.  Tries PluginManager (third-party plugins), then
# install.xml next to the module for core LMS plugins.  Returns '' on failure.
sub _readPluginVersion {
    my ($spec) = @_;
    return '' unless $spec->{module_class};

    # Third-party plugins
    my $data = eval { Slim::Utils::PluginManager->dataForPlugin( $spec->{module_class} ); };
    return $data->{version} if $data && $data->{version};

    # Core LMS plugins: read install.xml from the module directory
    return _readInstallXmlValue( $spec, 'version' ) || '';
}

# Locate a plugin's install.xml via %INC and extract a single element value.
# Returns '' if the file cannot be found or the element is absent.
sub _readInstallXmlValue {
    my ( $spec, $element ) = @_;

    my $module_path = $spec->{module_class};
    $module_path =~ s{::}{/}g;
    $module_path .= '.pm';

    my $pm_path = $INC{$module_path} or return '';
    require File::Basename;
    my $dir      = File::Basename::dirname($pm_path);
    my $xml_path = "$dir/install.xml";
    return '' unless -f $xml_path;

    my $xml = eval {
        local $/;
        open my $fh, '<', $xml_path or return '';
        <$fh>;
    };
    return '' unless $xml;

    my ($value) = ( $xml =~ m{<$element>\s*([^<]+?)\s*</$element>}s );
    return $value || '';
}

1;
