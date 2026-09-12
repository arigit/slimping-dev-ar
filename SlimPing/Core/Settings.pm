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
# Core/Settings.pm - Settings UI handler for SlimPing
#
# Implements the Slim::Web::Settings interface to provide the SlimPing
# configuration page in the LMS web UI.  Provides management of server
# settings, users, and virtual players through a partials-based Template
# Toolkit UI.  The raw users JSON API endpoint checks that the caller has
# an active LMS session before processing any reads or writes.
#

package Plugins::SlimPing::Core::Settings;

use strict;
use warnings;

use base qw(Slim::Web::Settings);

use Slim::Web::HTTP;
use Slim::Web::Pages;
use JSON::XS ();
use URI      ();

use Plugins::SlimPing::Core::Logging;
use Plugins::SlimPing::API::ResponseFormatter;
require Plugins::SlimPing::Core::Container;

# Load all dependencies at compile time so handler methods (called on every
# HTTP request) never trigger a require that could hit LMS's reload guards.
require Plugins::SlimPing::Core::LibraryMapper;
require Plugins::SlimPing::Auth::AdminGate;
require Plugins::SlimPing::Settings::AdminApi::Users;
require Plugins::SlimPing::Settings::AdminApi::Players;
require Plugins::SlimPing::Settings::AdminApi::Server;
require Plugins::SlimPing::Settings::AdminApi::NowPlaying;
require Plugins::SlimPing::Settings::AdminApi::Shares;
require Plugins::SlimPing::Settings::AdminApi::Data;
require Plugins::SlimPing::Settings::AdminApi::DynamicPlaylists;
require Slim::Music::VirtualLibraries;
require Slim::Utils::Misc;

my $log   = Plugins::SlimPing::Core::Logging->getLogger();
my $prefs = Plugins::SlimPing::Core::Logging->getPrefs();
my $json  = JSON::XS->new->utf8->allow_nonref;

# --- Slim::Web::Settings interface ---

sub name {
    return Slim::Web::HTTP::CSRF->protectName('PLUGIN_SLIMPING');
}

sub page {
    return 'plugins/SlimPing/settings/slimping_settings.html';
}

sub prefs {
    return (
        $prefs,
        qw(
          server_name exposed_libraries_mode radioFolder radioFolderRecurse
          menu_mode admin_access trust_xff lan_mode allow_plain_password
          proxy_remote_streams feature_internet_radio feature_podcasts
          lms_favourites_bridge
          client_quirks_enabled quirk_substreamer_artwork
          remote_stream_cap remote_stream_rate_limit remote_stream_rate_window
          feature_mai_integration feature_mai_text mai_external_cap mai_request_rate
          mai_queue_max mai_bio_positive_ttl mai_bio_negative_ttl
          feature_similar_depth maxAlbumCount maxArtistCount maxSongCount
          genre_count_per_entity exposed_contributor_roles
          minimalClients legacyClients
          star_user_cap star_global_cap bookmark_user_cap bookmark_global_cap
          share_user_cap share_global_cap session_ttl_days
          menu_page_size
          feature_sharing share_min_ttl share_default_ttl share_max_ttl
          dpl_feature_enabled dpl_cache_ttl_seconds dpl_seed_size
          share_max_bitrate max_share_entries radio_max_bitrate radio_token_ttl
          share_max_listeners share_max_unique_ips
          scrobble_gateway_player scrobble_source_type
          cache_ram_max_mb cache_ram_max_tracks
          cache_disk_enabled cache_disk_max_mb cache_disk_path
          exotic_target exotic_target_rate
        )
    );
}

# --- Constructor ---

sub new {
    my $class = shift;

    # Triggers addPageFunction + addPageLinks('setup', ...) registration
    # so the settings page appears in the LMS navigation dropdown menus.
    $class->SUPER::new();

    # Register JSON sub-endpoints for the settings SPA.  Each handler lives
    # in its own sub-module under Settings/AdminApi/ and requires admin
    # authentication independently.  No facade — Core::Settings wires directly
    # to the sub-module handle() entry points.
    Slim::Web::Pages->addRawFunction( 'plugins/SlimPing/settings/users',
        \&Plugins::SlimPing::Settings::AdminApi::Users::handle );

    Slim::Web::Pages->addRawFunction( 'plugins/SlimPing/settings/players',
        \&Plugins::SlimPing::Settings::AdminApi::Players::handle );

    Slim::Web::Pages->addRawFunction( 'plugins/SlimPing/settings/server',
        \&Plugins::SlimPing::Settings::AdminApi::Server::handle );

    Slim::Web::Pages->addRawFunction( 'plugins/SlimPing/settings/nowplaying',
        \&Plugins::SlimPing::Settings::AdminApi::NowPlaying::handle );

    Slim::Web::Pages->addRawFunction( 'plugins/SlimPing/settings/data',
        \&Plugins::SlimPing::Settings::AdminApi::Data::handle );

    Slim::Web::Pages->addRawFunction( 'plugins/SlimPing/settings/shares',
        \&Plugins::SlimPing::Settings::AdminApi::Shares::handle );

    Slim::Web::Pages->addRawFunction( 'plugins/SlimPing/settings/dynamic_playlists',
        \&Plugins::SlimPing::Settings::AdminApi::DynamicPlaylists::handle );
}

# --- Handler ---

sub handler {
    my ( $class, $client, $params, $callback, $httpClient, $response ) = @_;

    # Gate the HTML settings page itself with the same admin check used by the
    # JSON endpoints.  Without this, an LMS with `authorize` off would render
    # the user list (usernames, jukebox bindings, exposure settings) to anyone
    # who can reach the LMS port.
    my $request = $response->request();
    my ( $auth_ok, $err_code, $err_msg ) =
      Plugins::SlimPing::Auth::AdminGate::requireAdmin( $httpClient, $request );
    unless ($auth_ok) {
        return Plugins::SlimPing::Auth::AdminGate::renderAdminRequired( $err_code, $err_msg );
    }

    # If the admin authenticated via an API key in the URL, surface it to the
    # rendered page so AJAX calls back to the JSON endpoints can re-present it
    # via Authorization: Bearer.  When LMS authorize is on, the browser carries
    # Basic Auth automatically and no embedded key is needed.  We JSON-encode
    # the value here so the template can embed it directly in a JS string
    # literal -- HTML-escaping is not sufficient for a JS context.
    $params->{slimping_admin_apikey_js} =
      $json->encode( Plugins::SlimPing::Auth::AdminGate::extractApiKey($request) // '' );

    # Legacy non-AJAX form submit fallback for server_name (kept for users
    # who have JavaScript disabled; AJAX is preferred).
    if ( $params->{server_name} ) {
        $prefs->set( 'server_name', $params->{server_name} );
        $log->info( 'SlimPing: server_name updated to \''
              . $params->{server_name}
              . '\'' );
    }

    if ( defined $params->{radio_folder} ) {
        $prefs->set( 'radioFolder', $params->{radio_folder} // '' );
        $log->info( 'SlimPing: radioFolder updated to \''
              . ( $params->{radio_folder} // '' )
              . '\'' );
    }

    if ( defined $params->{exposed_libraries_mode} ) {
        my $mode = $params->{exposed_libraries_mode};
        $prefs->set( 'exposed_libraries_mode', $mode );
        if ( $mode eq 'selected' ) {
            my @ids =
              ref $params->{exposed_library_ids} eq 'ARRAY'
              ? @{ $params->{exposed_library_ids} }
              : ();
            $prefs->set( 'exposed_library_ids', \@ids );
        }
        else {
            $prefs->remove('exposed_library_ids');
        }
        Plugins::SlimPing::Core::Container->get('library_mapper')
          ->invalidateFolderCache();
        $log->info("SlimPing: exposure mode updated to '$mode'");
    }

    # Cache flush handler
    if ( $params->{flush_cache} ) {
        eval {
            require Plugins::SlimPing::Core::TranscodeCache;
            Plugins::SlimPing::Core::TranscodeCache->forceFlushAll();
        };
        if ($@) {
            $log->warn("SlimPing: cache flush error: $@");
        }
    }

    # Populate template parameters
    my $pluginData =
      Slim::Utils::PluginManager->dataForPlugin('Plugins::SlimPing::Plugin');

    # Virtual library list for the exposure settings UI
    my $vlibraries  = Slim::Music::VirtualLibraries->getLibraries() || {};
    my $raw         = $prefs->get('exposed_library_ids');
    my $exposed_ids = ref $raw eq 'ARRAY' ? $raw : [];
    my %exposed     = map { $_ => 1 } @$exposed_ids;

    my @vlibrary_list = map {
        {
            id      => $vlibraries->{$_}->{id},
            name    => $vlibraries->{$_}->{name},
            exposed => $exposed{ $vlibraries->{$_}->{id} } ? \1 : \0,
        }
    } keys %$vlibraries;

    my $sessions =
      Plugins::SlimPing::Core::Container->get('session_state')->getActiveSessions();
    my @sessions_fmt = map {
        {
            %$_,
              last_seen_fmt => scalar localtime( $_->{last_seen} ),
        }
    } @$sessions;

    my $mgr       = Plugins::SlimPing::Core::Container->get('auth_manager');
    my $raw_users = $mgr->getUsers();
    my @safe_users = map {
        my %u = %$_;
        $u{alias} = $mgr->getAlias( $u{username} );
        # dpl_access lives in plugin prefs, not the DB
        my $dpl_val = $prefs->get("sq_dpl_access_$u{username}");
        $u{dpl_access} = defined $dpl_val ? $dpl_val : 1;    # default: enabled
        \%u;
    } @$raw_users;

    $params->{slimping_users}          = \@safe_users;
    $params->{slimping_sessions}       = \@sessions_fmt;

    my $as_available = eval { require Slim::Plugin::AudioScrobbler::Plugin; 1 };

    my @players;
    my @scrobble_players;
    for my $client ( Slim::Player::Client::clients() ) {
        my $entry = {
            id    => $client->id(),
            name  => $client->name(),
            model => $client->modelName() // '',
        };
        push @players, $entry;

        if ( $as_available && Slim::Plugin::AudioScrobbler::Plugin::getAccount($client) ) {
            push @scrobble_players, $entry;
        }
    }

    @players         = sort { $a->{name} cmp $b->{name} } @players;
    @scrobble_players = sort { $a->{name} cmp $b->{name} } @scrobble_players;

    $params->{slimping_players}          = \@players;
    $params->{slimping_scrobble_players} = \@scrobble_players;
    $params->{scrobble_gateway_player}   = $prefs->get('scrobble_gateway_player');
    $params->{scrobble_source_type}      = $prefs->get('scrobble_source_type');

    # Detect stale gateway player (saved but no longer AudioScrobbler-enabled).
    # The pref value is preserved so it resumes working if the player is fixed.
    my $gateway_id = $params->{scrobble_gateway_player};
    if ( $gateway_id && length $gateway_id ) {
        my %scrobble_ids = map { $_->{id} => 1 } @scrobble_players;
        unless ( $scrobble_ids{$gateway_id} ) {
            $params->{scrobble_gateway_stale} = 1;
            my $client = Slim::Player::Client::getClient($gateway_id);
            $params->{scrobble_gateway_player_name} =
              $client ? $client->name() : $gateway_id;
        }
    }

    $params->{slimping_server_name}    = $prefs->get('server_name') || 'SlimPing';
    $params->{slimping_exposure_mode}  = $prefs->get('exposed_libraries_mode');
    $params->{slimping_radio_folder}   = $prefs->get('radioFolder');
    $params->{radio_folder_recurse}    = $prefs->get('radioFolderRecurse') ? 1 : 0;
    $params->{slimping_vlibraries}     = \@vlibrary_list;
    $params->{plugin_version} =
      ( $pluginData && $pluginData->{version} )
      ? $pluginData->{version}
      : 'unknown';
    $params->{lms_version} = $::VERSION;
    $params->{subsonic_api_version} =
      Plugins::SlimPing::API::ResponseFormatter::SUBSONIC_VERSION;
    $params->{slimping_admin_access} = $prefs->get('admin_access');
    $params->{slimping_trust_xff}    = $prefs->get('trust_xff') ? 1 : 0;
    # lan_mode defaults to ON (undef = on) so upgrades don't break
    # token+salt clients.  allow_plain_password defaults to OFF (undef =
    # off) -- operator must explicitly opt in to plain-password support.
    {
        my $raw = $prefs->get('lan_mode');
        $params->{slimping_lan_mode} = defined $raw ? ( $raw ? 1 : 0 ) : 1;
    }
    {
        my $raw = $prefs->get('allow_plain_password');
        $params->{slimping_allow_plain_password} =
          defined $raw ? ( $raw ? 1 : 0 ) : 0;
    }
    $params->{proxy_remote_streams}    = $prefs->get('proxy_remote_streams');
    $params->{remote_stream_cap}       = $prefs->get('remote_stream_cap');
    $params->{remote_stream_rate_limit} = $prefs->get('remote_stream_rate_limit');
    $params->{remote_stream_rate_window} = $prefs->get('remote_stream_rate_window');
    $params->{feature_internet_radio}  = $prefs->get('feature_internet_radio');
    $params->{feature_podcasts}       = $prefs->get('feature_podcasts');
    $params->{lms_favourites_bridge}  = $prefs->get('lms_favourites_bridge');

    # Dynamic Playlist Exposure
    {
        require Plugins::SlimPing::Core::DynamicPlaylistBridge;
        my $bridge = Plugins::SlimPing::Core::DynamicPlaylistBridge->getInstance();
        $params->{dpl4_available}          = $bridge->isAvailable();
        $params->{dpl_feature_enabled}     = $prefs->get('dpl_feature_enabled') ? 1 : 0;
        $params->{dpl_eligible_count}      = $bridge->getExposureCount();
        $params->{dpl_eligible_names}      = $bridge->getExposureNames();
        $params->{dpl_source_counts}       = $bridge->getExposureCountBySource();
        $params->{dpl_discovery_stats}     = $bridge->getDiscoveryStats();
        $params->{dpl_cache_ttl}           = $prefs->get('dpl_cache_ttl_seconds') // 300;
        $params->{dpl_seed_size}          = $prefs->get('dpl_seed_size') // 100;
    }
    $params->{feature_mai_integration} = $prefs->get('feature_mai_integration');
    $params->{feature_mai_text}        = $prefs->get('feature_mai_text');
    $params->{mai_external_cap} = $prefs->get('mai_external_cap');
    $params->{mai_request_rate}   = $prefs->get('mai_request_rate');
    $params->{mai_queue_max}    = $prefs->get('mai_queue_max');
    $params->{mai_bio_positive_ttl} = $prefs->get('mai_bio_positive_ttl');
    $params->{mai_bio_negative_ttl} = $prefs->get('mai_bio_negative_ttl');
    $params->{slimping_max_album_count}  = $prefs->get('maxAlbumCount');
    $params->{slimping_max_artist_count} = $prefs->get('maxArtistCount');
    $params->{slimping_max_song_count}   = $prefs->get('maxSongCount');
    $params->{slimping_genre_count}     = $prefs->get('genre_count_per_entity') // 3;
    $params->{slimping_exposed_roles}   = $prefs->get('exposed_contributor_roles')
        // 'ARTIST,COMPOSER,CONDUCTOR,BAND,ALBUMARTIST,TRACKARTIST';
    $params->{slimping_minimal_clients}  = $prefs->get('minimalClients');
    $params->{slimping_legacy_clients}   = $prefs->get('legacyClients');
    $params->{client_quirks_enabled}     = $prefs->get('client_quirks_enabled');
    $params->{quirk_substreamer_artwork} = $prefs->get('quirk_substreamer_artwork');

    # Store caps
    $params->{star_user_cap}            = $prefs->get('star_user_cap');
    $params->{star_global_cap}          = $prefs->get('star_global_cap');
    $params->{bookmark_user_cap}        = $prefs->get('bookmark_user_cap');
    $params->{bookmark_global_cap}      = $prefs->get('bookmark_global_cap');

    # Sharing settings — TTL values are stored in seconds and divided here
    # for display in hours.  The // fallback protects against a missing or
    # corrupt preference (e.g. undef, zero, or a tiny float left behind by a
    # double-division cycle).  sprintf formatting avoids scientific notation
    # in the HTML input, which would defeat parseInt on the JS save path.
    $params->{feature_sharing}       = $prefs->get('feature_sharing') // 1;
    $params->{share_min_ttl}         = sprintf('%.0f', ( $prefs->get('share_min_ttl')     // 3600 ) / 3600 );
    $params->{share_default_ttl}     = sprintf('%.0f', ( $prefs->get('share_default_ttl') // 86400 ) / 3600 );
    $params->{share_max_ttl}         = sprintf('%.0f', ( $prefs->get('share_max_ttl')     // 604800 ) / 3600 );
    $params->{share_max_bitrate}     = $prefs->get('share_max_bitrate');
    $params->{share_user_cap}        = $prefs->get('share_user_cap');
    $params->{share_global_cap}      = $prefs->get('share_global_cap');
    $params->{share_max_listeners}   = $prefs->get('share_max_listeners');
    $params->{share_max_unique_ips}  = $prefs->get('share_max_unique_ips');
    $params->{session_ttl_days}      = $prefs->get('session_ttl_days') // 7;
    $params->{radio_token_ttl}       = $prefs->get('radio_token_ttl') // 7776000;

    # Transcode cache configuration
    $params->{cache_ram_max_mb}      = $prefs->get('cache_ram_max_mb');
    $params->{cache_ram_max_tracks}  = $prefs->get('cache_ram_max_tracks');
    $params->{cache_disk_enabled}    = $prefs->get('cache_disk_enabled');
    $params->{cache_disk_max_mb}     = $prefs->get('cache_disk_max_mb');
    $params->{cache_disk_path}       = $prefs->get('cache_disk_path');
    $params->{exotic_target}         = $prefs->get('exotic_target');
    $params->{exotic_target_rate}    = $prefs->get('exotic_target_rate');

    # Check for external transcoding binaries so the settings panel can warn
    # the operator when a required helper (e.g. LAME, FLAC) is missing.
    my @prereqs;
    for my $spec (
        { name => 'lame',   label => 'LAME MP3 Encoder' },
        { name => 'flac',   label => 'FLAC' },
        { name => 'sox',    label => 'SoX' },
    )
    {
        my $path = Slim::Utils::Misc::findbin( $spec->{name} );
        push @prereqs, {
            name     => $spec->{name},
            label    => $spec->{label},
            critical => 1,
            found    => $path ? 1 : 0,
            path     => $path || '',
            status   => $path ? 'ok' : 'error',
        };
    }
    for my $spec (
        { name => 'faad',     label => 'FAAD2 (AAC Decoder)' },
        { name => 'ffmpeg',   label => 'FFmpeg (WMA Decoder)' },
        { name => 'mppdec',   label => 'Musepack Decoder' },
        { name => 'mac',      label => "Monkey's Audio" },
        { name => 'wvunpack', label => 'WavPack' },
        { name => 'dsdplay',  label => 'DSDPlayer (DSD Decoder)' },
    )
    {
        my $path = Slim::Utils::Misc::findbin( $spec->{name} );
        push @prereqs, {
            name     => $spec->{name},
            label    => $spec->{label},
            critical => 0,
            found    => $path ? 1 : 0,
            path     => $path || '',
            status   => $path ? 'ok' : 'warning',
        };
    }
    $params->{slimping_prereqs} = \@prereqs;

    # Streaming service plugin audit — installed, quality/bitrate for display
    # in the settings UI and for TranscodeEstimate source-bitrate resolution.
    {
        require Plugins::SlimPing::Core::StreamingServiceAudit;
        my @services = Plugins::SlimPing::Core::StreamingServiceAudit->audit();
        $params->{slimping_streaming_services} = \@services;
    }

    # Transcode cache statistics for settings UI
    {
        eval {
            require Plugins::SlimPing::Core::TranscodeCache;
            my $stats = Plugins::SlimPing::Core::TranscodeCache->getInstance->stats();
            my $ram = $stats->{ram};
            $params->{cache_ram_track_count} = $ram->{track_count} // 0;
            $params->{cache_ram_hits}        = $ram->{hits}        // 0;
            $params->{cache_ram_misses}      = $ram->{misses}      // 0;
            $params->{cache_ram_evictions}   = $ram->{evictions}   // 0;
            $params->{cache_ram_max_tracks}  = $ram->{max_tracks}  // 0;
            $params->{cache_ram_bytes_fmt}   = $class->_formatBytes( $ram->{bytes_used} // 0 );
            $params->{cache_ram_max_fmt}     = $class->_formatBytes( $ram->{max_bytes}   // 0 );

            if ( $stats->{disk} ) {
                my $disk = $stats->{disk};
                $params->{cache_disk_track_count} = $disk->{track_count} // 0;
                $params->{cache_disk_bytes_fmt}   = $class->_formatBytes( $disk->{bytes_used} // 0 );
                $params->{cache_disk_max_fmt}     = $class->_formatBytes( $disk->{max_bytes}  // 0 );
            }

            $params->{cache_disk_active} = Plugins::SlimPing::Core::TranscodeCache->getInstance->isDiskActive();
        };
    }

    # Delegate rendering to the base class, which provides the settings
    # navigation context (additionalLinks, orderedLinks, topLevelItems) and
    # renders the template via filltemplatefile.
    return $class->SUPER::handler( $client, $params, $callback, $httpClient,
        $response );
}

sub _formatBytes {
    my ( $class, $bytes ) = @_;
    return '0 B' unless $bytes && $bytes > 0;
    my @units = qw(B KB MB GB);
    my $i = 0;
    while ( $bytes >= 1024 && $i < 3 ) {
        $bytes /= 1024;
        $i++;
    }
    return sprintf( '%.1f %s', $bytes, $units[$i] );
}

1;
