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
# Plugin.pm - Main entry point for the SlimPing LMS plugin
#
# SlimPing exposes an OpenSubsonic REST API so that Subsonic-compatible
# clients can browse and stream a Lyrion Music Server (LMS) music library.
#
# Key responsibilities:
#   - Plugin initialisation and service loading
#   - Registration of the /rest/ catch-all route for all Subsonic API calls
#   - Top-level menu handler (informational placeholder)
#   - LMS event subscription for library-change notifications
#

package Plugins::SlimPing::Plugin;

use strict;
use warnings;

use base qw(Slim::Plugin::OPMLBased);

use Slim::Utils::Log;
use Plugins::SlimPing::Core::Logging;

# Register the log category with LMS settings UI
my $log = Slim::Utils::Log->addLogCategory({
    category     => 'plugin.slimping',
    defaultLevel => 'WARN',
    description  => 'SlimPing OpenSubsonic Server',
});

# Cache format version.  Increment this to force a transcode cache flush
# on every installation's next startup.  The hidden pref cache_format_version
# records the last version that was flushed; if it is less than this constant,
# the flush fires and the pref is updated.
use constant CACHE_FORMAT_VERSION => 4;

my $prefs = Plugins::SlimPing::Core::Logging->getPrefs();

sub initPlugin {
    my $class = shift;

    # Initialise plugin preferences with defaults (won't overwrite existing)
    $prefs->init( _getDefaultPreferences() );

    # Migrate legacy 'jit' warming mode: JIT warming was removed (2026-05-20)
    # after it caused an accidental DoS against upstream MAI services.  Users
    # who had it enabled are migrated to 'on_demand' so the plugin doesn't
    # break on upgrade.
    if ( $prefs->get('feature_mai_text') eq 'jit' ) {
        $prefs->set( 'feature_mai_text', 'on_demand' );
        $log->info('SlimPing: migrated feature_mai_text from jit to on_demand');
    }

    $class->SUPER::initPlugin(
        feed   => \&topLevelMenuHandler,
        tag    => 'slimping',
        menu   => undef,
        is_app => 1,
        weight => 10,
    );

    # Register settings page (protected by LMS web auth).
    # Only initialise in web UI context -- avoids unnecessary work in CLI/scanner.
    if (main::WEBUI) {
        require Plugins::SlimPing::Core::Settings;
        Plugins::SlimPing::Core::Settings->new();
    }

    # Register the single /rest/ catch-all route for all Subsonic API calls.
    # /rest/ is NOT under plugins/ -- it is the path mandated by the Subsonic
    # protocol spec. All Subsonic clients hardcode this prefix. Auth is handled
    # inside the router before any LMS data is touched.
    require Plugins::SlimPing::API::Router;
    Slim::Web::Pages->addRawFunction(
        'rest/',
        \&Plugins::SlimPing::API::Router::dispatch
    );

    # Initialise the response formatter with the server version string.
    # This is "pluginVersion-LMSVersion" so clients can identify the server stack.
    require Plugins::SlimPing::API::ResponseFormatter;
    my $pd = Slim::Utils::PluginManager->dataForPlugin('Plugins::SlimPing::Plugin');
    Plugins::SlimPing::API::ResponseFormatter->init(
        ( $pd && $pd->{version} ) ? $pd->{version} : undef
    );

    # Initialise the client quirks registry.  Quirks are client-specific
    # workarounds gated by a master pref (client_quirks_enabled, default on)
    # and per-quirk prefs.  When the master is off, all hook methods bail
    # immediately -- no overhead on the hot path.
    require Plugins::SlimPing::Core::ClientQuirks;
    Plugins::SlimPing::Core::ClientQuirks->init();

    # Register the slimping:// protocol handler so transcode cache files are
    # served through a remote URL scheme.  isRemote => 1 prevents LMS from
    # creating permanent tracks rows for transient cache files.
    require Plugins::SlimPing::ProtocolHandler;

    # Register all Phase A handlers
    require Plugins::SlimPing::Handlers::System;
    Plugins::SlimPing::Handlers::System->registerHandlers();

    require Plugins::SlimPing::Handlers::Browse;
    Plugins::SlimPing::Handlers::Browse->registerHandlers();

    require Plugins::SlimPing::Handlers::Search;
    Plugins::SlimPing::Handlers::Search->registerHandlers();

    require Plugins::SlimPing::Handlers::Lists;
    Plugins::SlimPing::Handlers::Lists->registerHandlers();

    require Plugins::SlimPing::Handlers::Stream::Endpoints;
    Plugins::SlimPing::Handlers::Stream::Endpoints->registerHandlers();

    require Plugins::SlimPing::Handlers::Playlists;
    Plugins::SlimPing::Handlers::Playlists->registerHandlers();

    require Plugins::SlimPing::Core::Annotations;
    require Plugins::SlimPing::Core::LmsFavorites;
    require Plugins::SlimPing::Handlers::Annotation;
    Plugins::SlimPing::Handlers::Annotation->registerHandlers();

    require Plugins::SlimPing::Handlers::Jukebox;
    Plugins::SlimPing::Handlers::Jukebox->registerHandlers();

    require Plugins::SlimPing::Handlers::NowPlaying;
    Plugins::SlimPing::Handlers::NowPlaying->registerHandlers();

    require Plugins::SlimPing::Handlers::Users;
    Plugins::SlimPing::Handlers::Users->registerHandlers();

    require Plugins::SlimPing::Handlers::Scanning;
    Plugins::SlimPing::Handlers::Scanning->registerHandlers();

    require Plugins::SlimPing::Handlers::Bookmarks;
    Plugins::SlimPing::Handlers::Bookmarks->registerHandlers();

    require Plugins::SlimPing::Handlers::Lyrics;
    Plugins::SlimPing::Handlers::Lyrics->registerHandlers();

    require Plugins::SlimPing::Handlers::Playback;
    Plugins::SlimPing::Handlers::Playback->registerHandlers();

    require Plugins::SlimPing::Handlers::InternetRadio;
    Plugins::SlimPing::Handlers::InternetRadio->registerHandlers();

    require Plugins::SlimPing::Core::ShareStore;
    require Plugins::SlimPing::Handlers::Sharing;
    Plugins::SlimPing::Handlers::Sharing->registerHandlers();

    require Plugins::SlimPing::Handlers::Stubs;
    Plugins::SlimPing::Handlers::Stubs->registerHandlers();

    # Probe whether the Music & Artist Info plugin is installed so
    # LibraryMapper can enrich artist images from MAI's local store.
    # Plugins cannot be installed or removed mid-session, so a single
    # startup check is sufficient.
    if (eval { require Plugins::MusicArtistInfo::LocalArtwork; 1 }) {
        Plugins::SlimPing::Core::LibraryMapper->setMaiAvailable(1);
        $log->info('SlimPing: Music & Artist Info plugin detected -- artist image enrichment available');
    } else {
        $log->info('SlimPing: Music & Artist Info plugin not present (continuing without it)');
    }

    # Probe whether the AudioScrobbler plugin is installed so Scrobbler can
    # feed completed plays into LMS's existing Last.fm / ListenBrainz pipeline.
    # Plugins cannot be installed or removed mid-session, so a single startup
    # check is sufficient.
    if (eval { require Slim::Plugin::AudioScrobbler::Plugin; 1 }) {
        require Plugins::SlimPing::Core::Scrobbler;
        Plugins::SlimPing::Core::Scrobbler->setScrobblerAvailable(1);
        $log->info('SlimPing: AudioScrobbler plugin detected -- scrobbling available');
    } else {
        $log->info('SlimPing: AudioScrobbler plugin not present (continuing without scrobbling)');
    }

    # Probe whether the Alternative Play Count plugin is installed so
    # completed plays can be reported through its external reportplayback
    # dispatch (APC cannot otherwise see plays SlimPing serves to
    # OpenSubsonic clients, since they never pass through a real player).
    # Plugins cannot be installed or removed mid-session, so a single
    # startup check is sufficient.
    if (eval { require Plugins::AlternativePlayCount::Plugin; 1 }) {
        require Plugins::SlimPing::Core::AlternatePlayCount;
        Plugins::SlimPing::Core::AlternatePlayCount->setApcAvailable(1);
        $log->info('SlimPing: Alternative Play Count plugin detected -- external play reporting available');
    } else {
        $log->info('SlimPing: Alternative Play Count plugin not present (continuing without it)');
    }

    # Probe whether the DynamicPlaylists4 plugin is installed so the
    # DynamicPlaylistBridge can expose favourited DPL playlists as read-only
    # OpenSubsonic playlists.  Plugins cannot be installed or removed
    # mid-session, so a single startup check is sufficient.
    if ( eval { require Plugins::DynamicPlaylists4::Plugin; 1 } ) {
        require Plugins::SlimPing::Core::DynamicPlaylistBridge;
        my $bridge = Plugins::SlimPing::Core::DynamicPlaylistBridge->getInstance();
        $bridge->init('Plugins::DynamicPlaylists4::Plugin');
        $log->info('SlimPing: DynamicPlaylists4 plugin detected -- dynamic playlist exposure available');
    } else {
        $log->info('SlimPing: DynamicPlaylists4 plugin not present (continuing without it)');
    }

    # Initialise the SQLite persistence layer and run any pending migrations.
    require Plugins::SlimPing::Schema;
    Plugins::SlimPing::Schema->connect();
    Plugins::SlimPing::Schema->deploySchema();

    # Remove unused index from earlier schema versions (MED-9).
    # All queries include user_id in WHERE, so the PK prefix already covers them.
    Plugins::SlimPing::Schema->dbh()->do('DROP INDEX IF EXISTS idx_star_sq_id');

    require Plugins::SlimPing::Core::Migration;
    Plugins::SlimPing::Core::Migration::run();

    $log->info('SlimPing: plugin initialised');
}

sub postinitPlugin {
    my $class = shift;

    require Plugins::SlimPing::Core::Container;
    Plugins::SlimPing::Core::Container->registerDefaultServices();

    # Slim::Utils::Cache is backed by a persistent SQLite DbCache whose
    # entries survive full process restarts.  Purge the folder cache on
    # every startup so a stale empty array cached by a prior code version
    # is never served to a client.  The fresh first request will recompute
    # the list from current prefs without any conditional gap.
    eval {
        Plugins::SlimPing::Core::Container->get('library_mapper')
          ->invalidateFolderCache();
    };
    if ($@) {
        $log->warn("SlimPing: startup folder cache invalidation failed: $@");
    }

    # Audit external binaries (flac, dsdplay) at startup so the
    # audio dispatch never enters a doomed path.  Missing binaries
    # disable CUE lossless and DSD direct paths via simple boolean gates.
    require Plugins::SlimPing::Core::ExternalProcess;
    Plugins::SlimPing::Core::ExternalProcess::auditCapabilities();

    require Plugins::SlimPing::Core::LibraryMapper;

    # --- Cache format version flush --------------------------------------------
    # When CACHE_FORMAT_VERSION is incremented, all persistent transcode caches
    # are flushed on the next startup via the unified forceFlushAll path.
    # The hidden pref cache_format_version records the last-flushed version so
    # the flush is a one-shot per version bump.
    my $cached_format_ver = $prefs->get('cache_format_version') // 0;
    if ( $cached_format_ver < CACHE_FORMAT_VERSION ) {
        eval {
            require Plugins::SlimPing::Core::TranscodeCache;
            Plugins::SlimPing::Core::TranscodeCache->forceFlushAll();
        };
        if ($@) {
            $log->warn(
"SlimPing: cache flush for format version bump failed: $@"
            );
        }

        # Invalidate the LibraryMapper CHI metadata cache so shaped responses
        # do not reference stale cache keys.  Eval-wrapped so a Container or
        # LibraryMapper failure never prevents plugin loading.
        eval {
            Plugins::SlimPing::Core::Container->get('library_mapper')
              ->invalidateCache();
        };
        if ($@) {
            $log->warn(
"SlimPing: LibraryMapper cache invalidation during format flush failed: $@"
            );
        }

        # Update the pref AFTER all flush attempts complete — prevents
        # infinite retry on startup.  Slim::Utils::Prefs::set does not
        # throw, so an eval is unnecessary here.
        $prefs->set( 'cache_format_version', CACHE_FORMAT_VERSION );
        $log->info(
            'SlimPing: cache flushed for format version '
              . CACHE_FORMAT_VERSION
        );
    }

    # Invalidate LibraryMapper cache when LMS completes a library rescan.
    # The event fired by Slim::Utils::Scanner::Local and Slim::Music::Import
    # is ['rescan', 'done'] -- confirmed from LMS source.
    Slim::Control::Request::subscribe(
        sub {
            Plugins::SlimPing::Core::Container->get('library_mapper')->invalidateCache();
            $prefs->set('lastScanTimestampMs', int(time() * 1000));
        },
        [['rescan'], ['done']]
    );

    # Schedule periodic session TTL cleanup (idle sessions age out after
    # session_ttl_days, default 7) and share expiry pruning.  Both run once
    # on startup and every 15 minutes thereafter.
    require Plugins::SlimPing::Core::SessionStore;
    eval { Plugins::SlimPing::Core::SessionStore->getInstance()->cleanupExpiredSessions(); };
    if ($@) {
        $log->warn("SlimPing: cleanup task 'cleanupExpiredSessions' failed: $@");
    }
    eval { Plugins::SlimPing::Core::ShareStore->getInstance()->pruneExpired(); };
    if ($@) {
        $log->warn("SlimPing: cleanup task 'pruneExpired' failed: $@");
    }

    # Load VirtualPlayer once — its methods are called from multiple eval
    # blocks below (startup cleanup, periodic timer, and shutdown).
    require Plugins::SlimPing::Core::VirtualPlayer;

    # Delete orphaned clientplaylist M3U files left by previous plugin
    # instances.  At startup no slimping-* players exist in memory, so
    # every matching file is a zombie.  New files are suppressed at the
    # source (startupPlaylistLoading flag in _startPlayback), making this
    # a one-off historical cleanup.
    eval {
        my $n = Plugins::SlimPing::Core::VirtualPlayer::_sweepOrphanedPlaylistFiles();
        if ($n) {
            $log->info("SlimPing: cleaned up $n orphaned clientplaylist files on startup");
        }
    };
    if ($@) {
        $log->warn("SlimPing: orphaned playlist file sweep failed: $@");
    }

    # Sweep stale virtual players left over from a previous plugin instance
    # (crash, unclean reload).  LMS does not clean up HTTP players
    # automatically — they accumulate in the clients list forever.
    eval {
        my $n = Plugins::SlimPing::Core::VirtualPlayer::cleanupDisconnectedPlayers();
        if ($n) {
            $log->info("SlimPing: cleaned up $n stale virtual players on startup");
        }
    };
    if ($@) {
        $log->warn("SlimPing: startup virtual player cleanup failed: $@");
    }

    Slim::Utils::Timers::setTimer(
        undef,
        time() + 900,    # first run in 15 minutes
        sub {
            eval { Plugins::SlimPing::Core::SessionStore->getInstance()->cleanupExpiredSessions(); };
            if ($@) {
                $log->warn("SlimPing: scheduled cleanup task 'cleanupExpiredSessions' failed: $@");
            }
            eval { Plugins::SlimPing::Core::ShareStore->getInstance()->pruneExpired(); };
            if ($@) {
                $log->warn("SlimPing: scheduled cleanup task 'pruneExpired' failed: $@");
            }
            eval {
                Plugins::SlimPing::Core::VirtualPlayer::cleanupDisconnectedPlayers();
            };
            if ($@) {
                $log->warn("SlimPing: scheduled cleanup task 'cleanupDisconnectedPlayers' failed: $@");
            }
            Slim::Utils::Timers::setTimer(undef, time() + 900, shift);
        },
    );

    $log->info('SlimPing: services registered');
}

sub topLevelMenuHandler {
    my ($client, $cb, $args) = @_;
    require Plugins::SlimPing::Menu::InfoMenu;
    Plugins::SlimPing::Menu::InfoMenu::topLevel($client, $cb, $args);
}

sub getDisplayName { 'PLUGIN_SLIMPING' }
sub optionsPage    { 'plugins/SlimPing/settings/slimping_settings.html' }

# Canonical preference defaults.  Consumed by initPlugin (for $prefs->init)
# Single source of truth -- do not duplicate defaults elsewhere.
sub _getDefaultPreferences {
    return {
        server_name              => 'SlimPing',
        exposed_libraries_mode   => 'all',
        radioFolder              => '',
        radioFolderRecurse       => 0,
        menu_mode                => 'usage',
        admin_access             => 'lan_open',
        trust_xff                => 0,
        lan_mode                 => 1,
        allow_plain_password     => 0,
        proxy_remote_streams     => 1,
        remote_stream_cap        => 10,
        remote_stream_rate_limit => 3,
        remote_stream_rate_window => 10,
        feature_internet_radio   => 1,
        feature_podcasts         => 1,
        lms_favourites_bridge    => 1,
        feature_mai_integration  => 'auto',
        feature_mai_text         => 'on_demand',
        feature_similar_depth    => 'basic',
        mai_external_cap         => 20,
        mai_request_rate         => 10,
        mai_queue_max            => 500,
        mai_bio_positive_ttl     => 7776000,
        mai_bio_negative_ttl     => 2592000,
        maxAlbumCount            => 0,
        maxArtistCount           => 0,
        maxSongCount             => 0,
        genre_count_per_entity   => 3,
        exposed_contributor_roles => 'ARTIST,ALBUMARTIST,COMPOSER,CONDUCTOR,BAND',
        cache_ttl_seconds        => 300,
        lastScanTimestampMs      => 0,
        minimalClients           => '',
        legacyClients            => 'DSub, Subsonic',
        star_user_cap            => 5000,
        star_global_cap          => 500_000,
        bookmark_user_cap        => 1000,
        bookmark_global_cap      => 20_000,
        share_user_cap           => 50,
        share_global_cap         => 5000,

        # Dynamic Playlist exposure (DPL4 bridge).  Enabled by default --
        # the feature self-gates at runtime on DPL4 presence (isAvailable),
        # so with DPL4 absent it is a no-op.  An explicit disable in
        # settings turns it off regardless of DPL4 state.
        dpl_feature_enabled      => 1,
        dpl_cache_ttl_seconds    => 300,
        dpl_seed_size            => 50,

        # Transcode cache
        cache_ram_max_mb         => 100,
        cache_ram_max_tracks     => 50,
        cache_disk_enabled       => 0,
        cache_disk_max_mb        => 2048,
        cache_disk_path          => '',
        share_min_ttl            => 3600,
        share_default_ttl        => 86400,
        share_max_ttl            => 604800,
        share_max_bitrate        => 192,
        radio_max_bitrate        => 192,
        share_max_listeners      => 5,
        share_max_unique_ips     => 20,
        max_share_entries        => 500,
        radio_token_ttl   => 7776000,
        feature_sharing          => 1,
        session_ttl_days         => 7,
        scrobble_gateway_player  => '',
        scrobble_source_type     => 'P',
        scrobble_dedup_window    => 240,
        client_quirks_enabled    => 1,
        quirk_substreamer_artwork => 1,

        # Cache format version — bump CACHE_FORMAT_VERSION to force a
        # transcode cache flush on next startup (hidden, do NOT add to
        # Settings::prefs() — it is an internal mechanism)
        cache_format_version     => 0,

        # Maximum items per page in LMS menus.  500 items renders comfortably on
        # all LMS clients (Material Skin, Squeezebox, iPeng).  Reduce on
        # low-memory devices; operators with very large libraries can tune it up.
        menu_page_size           => 500,

        exotic_target            => 'flac',
        exotic_target_rate       => 44100,
        dsd_output_bit_depth     => 24,
    };
}

sub menuCondition {
    require Plugins::SlimPing::Menu::InfoMenu;
    return Plugins::SlimPing::Menu::InfoMenu::menuCondition();
}

sub shutdownPlugin {
    my $class = shift;
    $log->info('SlimPing: shutting down');

    # Remove ALL virtual players before teardown.  Without this, players
    # persist in LMS's client list as permanent zombies after plugin
    # disable/reload — HTTP players have no Slimproto heartbeat and LMS
    # never calls forgetClient for them on its own.
    eval {
        my $n = Plugins::SlimPing::Core::VirtualPlayer::cleanupAllPlayers();
        if ($n) {
            $log->info("SlimPing: shutdown cleaned up $n virtual players");
        }
    };
    if ($@) {
        $log->warn("SlimPing: shutdown virtual player cleanup failed: $@");
    }

    Plugins::SlimPing::Schema->disconnect();

    # Release the transcode cache singleton cleanly before Perl global
    # destruction to avoid "Can't call method on undef" warnings.
    eval {
        require Plugins::SlimPing::Core::TranscodeCache;
        if ( my $cache = Plugins::SlimPing::Core::TranscodeCache->getInstance ) {
            $cache->shutdown();
        }
    };

    # Write a clean-shutdown marker so the next startup can skip the orphan
    # sweep.  The marker lives in LMS's temp directory as a 0-byte sentinel.
    # Don't log failures -- we're shutting down and the log may already be
    # closed.  An eval prevents a Perl warning from aborting the shutdown.
    eval {
        my $marker = Slim::Utils::Misc::getTempDir() . '/slimping_clean_shutdown';
        if ( open my $fh, '>', $marker ) {
            close $fh;
        }
    };
}

1;
