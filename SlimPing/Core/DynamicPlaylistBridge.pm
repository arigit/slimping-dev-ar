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
# Core/DynamicPlaylistBridge.pm - Expose DPL4 playlists as read-only OpenSubsonic playlists
#
# Acts as a second playlist provider alongside PlaylistStore.  Discovers
# eligible DPLs from DPL4 prefs (_enabled + _favourite), materialises
# track lists via DPL4's own getNextDynamicPlaylistTracks() API, caches
# results in CHI, and deduplicates across regenerations via the
# sq_dynamic_playlist_history table.
#
# Singleton - getInstance() returns the shared instance initialised
# by Plugin.pm at startup.
#

package Plugins::SlimPing::Core::DynamicPlaylistBridge;

use strict;
use warnings;

use Time::HiRes ();
use Slim::Utils::Cache;
use Slim::Utils::Prefs;
use Plugins::SlimPing::Core::Logging;

my $log   = Plugins::SlimPing::Core::Logging->getLogger();
my $prefs = Plugins::SlimPing::Core::Logging->getPrefs();

# Re-read from DPL4 prefs at most every 60 seconds to avoid hammering
# the prefs file on every getPlaylists call.
use constant DISCOVERY_TTL => 60;

my $_instance;

sub getInstance {
    my $class = shift;
    return $_instance if $_instance;

    $_instance = bless {
        _available     => 0,
        _initialised   => 0,
        _exposures     => {},       # exposure_id => { name, sql, params, source, category }
        _cache         => Slim::Utils::Cache->new(),
        _last_discover => 0,
    }, $class;

    return $_instance;
}

# --- Initialisation ---

# Called by Plugin.pm at startup after DPL4 detection.
# Takes a reference to the DPL4 plugin package name (string).
sub init {
    my ($self, $dpl4_package) = @_;

    $self->{_available}   = 1;
    $self->{_dpl4_package} = $dpl4_package;
    $self->{_initialised}  = 1;

    $self->_discover();

    $log->info(sprintf(
        "SlimPing: DynamicPlaylistBridge initialised - %d playlists eligible for exposure",
        scalar keys %{ $self->{_exposures} }
    ));

    return 1;
}

# --- Public API ---

sub isAvailable { return $_instance ? $_instance->{_available} : 0; }

sub isEnabled {
    return 0 unless $_instance && $_instance->{_available};
    return $prefs->get('dpl_feature_enabled') ? 1 : 0;
}

sub getExposureCount {
    return 0 unless $_instance && $_instance->{_available};
    $_instance->_discoverIfStale();
    return scalar keys %{ $_instance->{_exposures} };
}

sub getExposureNames {
    return [] unless $_instance && $_instance->{_available};
    $_instance->_discoverIfStale();
    my @names = sort { $a->{name} cmp $b->{name} }
                map  { {
                    id       => $_,
                    name     => $_instance->{_exposures}{$_}{name},
                    source   => $_instance->{_exposures}{$_}{source}   // 'unknown',
                    category => $_instance->{_exposures}{$_}{category} // '',
                } }
                keys %{ $_instance->{_exposures} };
    return \@names;
}

sub getExposureCountBySource {
    my %counts;
    return \%counts unless $_instance && $_instance->{_available};
    $_instance->_discoverIfStale();
    for my $eid (keys %{ $_instance->{_exposures} }) {
        my $src = $_instance->{_exposures}{$eid}{source} // 'unknown';
        $counts{$src}++;
    }
    return \%counts;
}

# Discovery statistics from the last _discover run, for the settings UI
# diagnostic display.  Returns a hashref of counters (raw, not_enabled,
# not_favourited, contextmenu, has_params, opml, eligible) or an empty
# hashref if discovery has not run.
sub getDiscoveryStats {
    return {} unless $_instance && $_instance->{_available};
    $_instance->_discoverIfStale();
    return $_instance->{_last_stats} // {};
}

# Refresh the exposure registry (called on settings page load and manual refresh).
sub refreshRegistry {
    my $self = $_instance or return;
    $self->_discover();
}

# Clear all caches and dedup history.
sub clearCaches {
    my $self = $_instance or return;

    # Clear materialised track caches
    for my $eid (keys %{ $self->{_exposures} }) {
        $self->{_cache}->remove('sq_dpl_materialised_' . $eid);
    }

    # Clear dedup history
    $self->_clearHistory();

    $log->info('SlimPing: DynamicPlaylistBridge caches cleared');
    return 1;
}

# --- Playlist Serving ---

# Returns shaped playlist hashes (without tracks) for getPlaylists.
sub getExposedPlaylists {
    my ($self, $username) = @_;

    return () unless $self->isEnabled();
    return () unless $self->_userHasAccess($username);

    $self->_discoverIfStale();

    require Plugins::SlimPing::Core::LibraryMapper;

    # Compute once outside the loop — _allowedUserList iterates all users
    my $allowed = $self->_allowedUserList();

    my @playlists;
    for my $eid (sort keys %{ $self->{_exposures} }) {
        my $exp   = $self->{_exposures}{$eid};
        my $sq_id = Plugins::SlimPing::Core::LibraryMapper->encodeId('dynamic_playlist', $eid);

        # Get cached materialised data for songCount/duration/changed/validUntil
        my $cached = $self->{_cache}->get('sq_dpl_materialised_' . $eid);
        my $ttl    = $prefs->get('dpl_cache_ttl_seconds') // 300;

        my $song_count = $cached ? $cached->{song_count} : 0;
        my $duration   = $cached ? $cached->{duration}   : 0;
        my $generated  = $cached ? $cached->{generated_at} : time();
        my $valid_until = $generated + $ttl;
        my $created     = $self->_exposureCreatedAt($eid);

        push @playlists, {
            id         => $sq_id,
            name       => $exp->{name},
            owner      => 'Lyrion Music Server',
            public     => \0,
            songCount  => $song_count,
            duration   => $duration,
            coverArt   => $sq_id,
            created    => _iso8601($created),
            changed    => _iso8601($generated),
            comment    => 'Dynamic playlist (DynamicPlaylists v4)',
            readonly   => \1,
            validUntil => _iso8601($valid_until),
            allowedUser => $allowed,
        };
    }

    return @playlists;
}

# Returns a shaped playlist hash with entry array for getPlaylist.
# Regenerates the materialised track list if stale.
sub getPlaylistWithTracks {
    my ($self, $exposure_id, $username) = @_;

    return Plugins::SlimPing::Utils::Errors->error(50, 'Dynamic playlist feature is not enabled')
        unless $self->isEnabled();

    return Plugins::SlimPing::Utils::Errors->error(50, 'User does not have access to dynamic playlists')
        unless $self->_userHasAccess($username);

    # Discovery may have failed during plugin init (DPL4 not yet loaded);
    # ensure the registry is up to date before looking up this exposure.
    $self->_discoverIfStale();

    my $exp = $self->{_exposures}{$exposure_id};
    return Plugins::SlimPing::Utils::Errors->notFound('Playlist')
        unless $exp;

    # Staleness handling uses a stale-while-revalidate model: an expired
    # cache entry is served to the client IMMEDIATELY and regeneration is
    # deferred to a zero-delay timer that runs after the response is sent.
    # Materialisation can take seconds (DPL4 SQL over a large library), and
    # blocking mobile/Android Auto clients on it makes the feature feel
    # broken.  Only a completely cold cache (first ever request for this
    # exposure) materialises synchronously.
    my $ttl    = $prefs->get('dpl_cache_ttl_seconds') // 300;
    my $cached = $self->{_cache}->get('sq_dpl_materialised_' . $exposure_id);

    my $track_data;
    if ($cached && (time() - $cached->{generated_at}) < $ttl) {
        $track_data = $cached;
    }
    elsif ($cached) {
        # Stale: serve it now, refresh in the background.
        $track_data = $cached;
        $self->_scheduleBackgroundRefresh($exposure_id, $exp);
    }
    else {
        # Cold cache: no choice but to materialise synchronously.
        $track_data = $self->_materialise($exposure_id, $exp);
        return Plugins::SlimPing::Utils::Errors->error(0, 'Failed to generate dynamic playlist tracks')
            unless $track_data;
    }

    # Resolve track URLs to Slim::Schema::Track objects and shape
    my @entries = $self->_resolveAndShape($track_data->{tracks});

    require Plugins::SlimPing::Core::LibraryMapper;
    my $sq_id = Plugins::SlimPing::Core::LibraryMapper->encodeId('dynamic_playlist', $exposure_id);
    my $created = $self->_exposureCreatedAt($exposure_id);

    return {
        id         => $sq_id,
        name       => $exp->{name},
        owner      => 'Lyrion Music Server',
        public     => \0,
        songCount  => $track_data->{song_count},
        duration   => $track_data->{duration},
        coverArt   => $sq_id,
        created    => _iso8601($created),
        changed    => _iso8601($track_data->{generated_at}),
        comment    => 'Dynamic playlist (DynamicPlaylists v4)',
        readonly   => \1,
        validUntil => _iso8601($track_data->{generated_at} + $ttl),
        allowedUser => $self->_allowedUserList(),
        entry      => \@entries,
    };
}

# --- Internal: Discovery ---

sub _discover {
    my $self = shift;

    return unless $self->{_available};

    my $dpl4_package = $self->{_dpl4_package};
    return unless $dpl4_package;

    my $dpl4_prefs = preferences('plugin.dynamicplaylists4');
    return unless $dpl4_prefs;

    # Build stub client for the DPL4 API call.
    # getDynamicPlaylists is DPL4's public plugin extension API and does not
    # require any internal initialisation — it reads from DPL4's own prefs and
    # internal state, which are fully populated by the time any HTTP request
    # handler runs.
    my $stub_client = bless {
        id => 'ssp_dpl_bridge',
    }, 'Plugins::SlimPing::Core::DynamicPlaylistBridge::StubClient';

    # Step 1: Get all playlist definitions via DPL4's public API.
    # Use function-call syntax because getDynamicPlaylists expects a client
    # as the first positional argument, not as an OO invocant.
    my $all_dpls = {};
    eval {
        no strict 'refs';
        $all_dpls = &{ $dpl4_package . '::getDynamicPlaylists' }($stub_client);
    };
    if ($@) {
        $log->warn("SlimPing: DynamicPlaylistBridge discovery error: $@");
    }

    # Resilience: DPL4 rebuilds its internal playlist registry on rescans and
    # some UI flows, leaving brief windows where getDynamicPlaylists returns
    # nothing.  If we previously had a populated registry, keep it and let the
    # next request retry rather than clobbering good data with an empty scan.
    my $had_dpl_exposures = grep { ($_->{source} // '') ne 'favourite' }
                            values %{ $self->{_exposures} };
    if ((!$all_dpls || !keys %$all_dpls) && $had_dpl_exposures) {
        $log->info('SlimPing: getDynamicPlaylists returned no data -- keeping previous registry, will retry');
        # Deliberately do NOT update _last_discover so the retry happens on
        # the next request instead of after the full discovery TTL.
        return;
    }

    # Step 2: Filter to enabled + favourited playlists.
    # Diagnostic counters logged at the end so support requests can identify
    # exactly where playlists were filtered out.
    my %eligible;
    my $raw_count           = 0;
    my $not_enabled_count   = 0;
    my $not_favourite_count = 0;
    my $unsatisfied_count   = 0;
    my $contextmenu_count   = 0;

    if ($all_dpls && ref $all_dpls eq 'HASH' && keys %$all_dpls) {
        $raw_count = scalar keys %$all_dpls;
        for my $pl_id (keys %$all_dpls) {
            my $pl_def = $all_dpls->{$pl_id};
            next unless $pl_def && $pl_def->{name};

            # DPL4 semantics: an ABSENT _enabled pref means enabled.  Prefs
            # only record explicit changes, so fresh installs have no
            # playlist_*_enabled keys at all.  Mirror DPL4's own check
            # (Plugin.pm: '(!defined $enabled || $enabled) ? 1 : 0').
            my $enabled   = $dpl4_prefs->get("playlist_${pl_id}_enabled");
            my $favourite = $dpl4_prefs->get("playlist_${pl_id}_favourite");
            if (defined $enabled && !$enabled) { $not_enabled_count++;   next; }
            if (!$favourite)                   { $not_favourite_count++; next; }

            # Context-menu playlists need a browse context (artist/album/etc.)
            # and cannot run standalone.
            if (($pl_def->{menulisttype} // '') eq 'contextmenu') {
                $contextmenu_count++;
                next;
            }

            # Skip DPLs whose parameters require the user to pick a value
            # (artist, album, genre, year selectors, etc.).  Playlists with
            # only list-type parameters that have a default (0 = All) work
            # headless -- the SQL will use the default value.
            if ($self->_hasUnsatisfiedParameters($pl_def)) {
                $unsatisfied_count++;
                next;
            }

            # getDynamicPlaylists does not expose the 'sql' key — that is an
            # internal detail of DPL4's playlist definitions.  We store the
            # internal filename-based ID from DPL4 (pl_def->{id}), which is
            # the key that getNextDynamicPlaylistTracks expects.
            $eligible{$pl_id} = {
                name        => $pl_def->{name},
                internal_id => $pl_def->{id} // $pl_id,
                sql         => '',
                category    => $pl_def->{playlistcategory} // '',
                source      => $pl_def->{defaultplaylist} ? 'default'
                             : $pl_def->{customplaylist}   ? 'usercustom'
                             : $pl_def->{dplcplaylist}     ? 'dplc'
                             :                                'unknown',
            };
        }
    }
    else {
        $log->info('SlimPing: getDynamicPlaylists returned no data — no DPL playlists exposed');
    }

    # Step 3: Also discover DPL4 favourites saved in LMS Favourites.
    # These are parameterised DPLs with pre-configured input values stored
    # as dynamicplaylist:// URLs in the LMS favourites OPML.  Playlists
    # already exposed via the direct DPL-favourite path are skipped so the
    # same playlist never appears twice.
    my %fav_eligible = $self->_discoverFavourites($all_dpls, $dpl4_prefs, \%eligible);
    %eligible = ( %eligible, %fav_eligible );

    $self->{_exposures}     = \%eligible;
    $self->{_last_discover} = time();

    # Full diagnostic breakdown at INFO level so support requests can
    # identify exactly where playlists were filtered out without needing
    # debug logging enabled.  Also stored on the instance so the settings
    # UI can render the same breakdown for the user.
    $self->{_last_stats} = {
        raw            => $raw_count,
        not_enabled    => $not_enabled_count,
        not_favourited => $not_favourite_count,
        contextmenu    => $contextmenu_count,
        has_params     => $unsatisfied_count,
        opml           => scalar keys %fav_eligible,
        eligible       => scalar keys %eligible,
    };

    $log->info(sprintf(
        'SlimPing: DPL discovery -- %d raw from DPL4, %d skipped (not enabled), '
      . '%d skipped (not favourited), %d skipped (context menu), '
      . '%d skipped (has params), %d from LMS Favourites OPML => %d eligible total',
        $raw_count,
        $not_enabled_count,
        $not_favourite_count,
        $contextmenu_count,
        $unsatisfied_count,
        scalar keys %fav_eligible,
        scalar keys %eligible
    ));
}

# Scan LMS Favourites OPML for dynamicplaylist:// URLs and return exposure
# entries for any DPL4 favourites that have pre-configured parameter values.
# $direct_eligible is the set already exposed via the DPL-favourite path;
# favourites pointing at those playlists are skipped (dedupe).
sub _discoverFavourites {
    my ($self, $all_dpls, $dpl4_prefs, $direct_eligible) = @_;

    my %eligible;

    # Internal IDs already exposed directly -- used to skip duplicate
    # Lyrion Favourites of the same playlist.
    my %seen_internal_ids =
        map  { $_->{internal_id} => 1 }
        grep { $_->{internal_id} }
        values %{ $direct_eligible // {} };

    # Walk the LMS Favourites OPML tree looking for dynamicplaylist:// URLs.
    # Each favourite has a URL with embedded parameter values, e.g.:
    #   dynamicplaylist://dpldefault_albums_061_mostplayed_avg?p1=1&p2=0
    eval {
        require Slim::Plugin::Favorites::OpmlFavorites;
        my $favs  = Slim::Plugin::Favorites::OpmlFavorites->new();
        my $level = $favs->toplevel();
        $self->_walkFavourites($level, \%eligible, $all_dpls, $dpl4_prefs, \%seen_internal_ids);
    };
    if ($@) {
        $log->warn("SlimPing: DynamicPlaylistBridge favourite discovery error: $@");
    }

    return %eligible;
}

# Recursively walk an OPML level and collect dynamicplaylist:// favourites.
sub _walkFavourites {
    my ($self, $items, $eligible, $all_dpls, $dpl4_prefs, $seen_internal_ids) = @_;

    return unless $items && ref $items eq 'ARRAY';

    for my $item (@$items) {
        my $url = $item->{URL} // $item->{url} // '';

        if ($url =~ m{^dynamicplaylist://}) {
            # Parse: dynamicplaylist://<playlist_id>?<query_string>
            my ($pl_id, $query) = ($url =~ m{^dynamicplaylist://([^?]+)(?:\?(.+))?$});
            next unless $pl_id;

            # Verify the referenced DPL playlist is enabled in DPL4.
            # $pl_id from the URL already includes the DPL4 prefix.
            # DPL4's own check: '(!defined $enabled || $enabled)' -- absent = enabled.
            my $enabled = $dpl4_prefs->get("playlist_${pl_id}_enabled");
            next if defined $enabled && !$enabled;

            # Parse query parameters into the format DPL4 expects
            my %params;
            if ($query) {
                for my $pair (split(/&/, $query)) {
                    my ($k, $v) = split(/=/, $pair, 2);
                    next unless defined $k;
                    $v //= '';
                    # Convert p1=1 to PlaylistParameter1 => { id => 1, value => 1 }
                    if ($k =~ /^p(\d+)$/) {
                        $params{"PlaylistParameter${1}"} = { id => int($1), value => $v };
                    }
                }
            }

            # The URL's playlist ID has a DPL4 prefix (dpldefault_ / dplusercustom_ /
            # dplccustom_).  DPL4's \$localDynamicPlaylists is keyed by raw filenames
            # (without prefix), so strip the prefix to get the internal ID.
            # Keep the original prefixed form as dpl_playlist_id — DPL4's
            # getNextDynamicPlaylistTracks uses it to identify the playlist type.
            # Non-capturing group (?:...) is essential here — a capturing group
            # would steal the second list element, assigning the literal string
            # "default"/"usercustom"/"dplc" to $raw_filename instead of the
            # actual filename.
            my ($dpl_prefix, $raw_filename) = ($pl_id =~ /^(dpl(?:default|usercustom|dplc)_)?(.+)$/);
            my $dpl_playlist_id = $pl_id;           # e.g. dpldefault_albums_061_mostplayed_avg
            my $internal_id     = $raw_filename // $pl_id;  # e.g. albums_061_mostplayed_avg

            # If the raw filename exists in DPL4's registry, use its canonical id
            for my $dpl_key (keys %$all_dpls) {
                my $def = $all_dpls->{$dpl_key};
                if (($def->{id} // '') eq $internal_id) {
                    $internal_id = $def->{id};
                    last;
                }
            }

            # Build a unique exposure key from the playlist ID and parameters
            require Digest::SHA;
            my $key = 'fav_' . $internal_id . '_' . substr(Digest::SHA::sha1_hex($url), 0, 8);

            # Get the display name from the favourite's text attribute
            my $name = $item->{text} || $item->{name} || $pl_id;

            # Dedupe: skip if this playlist is already exposed via the direct
            # DPL-favourite path (same internal_id).
            next if $seen_internal_ids->{$internal_id};

            $eligible->{$key} = {
                name             => $name,
                internal_id      => $internal_id,
                dpl_playlist_id  => $dpl_playlist_id,
                sql              => '',
                category         => 'Favourites',
                source           => 'favourite',
                params           => \%params,
            };
        }

        # Recurse into subfolders
        my $children = $item->{items} || $item->{children} || [];
        $self->_walkFavourites($children, $eligible, $all_dpls, $dpl4_prefs, $seen_internal_ids);
    }
}

sub _discoverIfStale {
    my $self = shift;
    if ((time() - $self->{_last_discover}) > DISCOVERY_TTL) {
        $self->_discover();
    }
}

# Decide whether a playlist's declared parameters prevent headless use.
# getDynamicPlaylists exposes parameters as { id => { id, type, name,
# definition } }.  'list' parameters enumerate fixed values with the first
# entry as the effective default, so they work without user input (the SQL
# when-clauses fall through to the default branch).  Every other type
# (artist, album, genre, year, multiple*, custom*, *contains, ...) needs a
# user selection and cannot run headless.
sub _hasUnsatisfiedParameters {
    my ($self, $pl_def) = @_;

    my $params = $pl_def->{parameters};
    return 0 unless $params && ref $params eq 'HASH' && keys %$params;

    for my $pk (keys %$params) {
        my $type = $params->{$pk}{type} // '';
        return 1 unless $type eq 'list';
    }

    return 0;
}

# --- Internal: Materialisation ---

# Schedule a one-shot zero-delay timer to re-materialise an exposure after
# the current request completes.  The in-flight guard prevents a burst of
# stale hits (e.g. a client syncing all playlists at once) from queuing
# duplicate regenerations of the same exposure.
sub _scheduleBackgroundRefresh {
    my ($self, $exposure_id, $exp) = @_;

    return if $self->{_refreshing}{$exposure_id};
    $self->{_refreshing}{$exposure_id} = 1;

    require Slim::Utils::Timers;
    Slim::Utils::Timers::setTimer( undef, Time::HiRes::time(), sub {
        my $t0 = Time::HiRes::time();
        my $ok = eval { $self->_materialise($exposure_id, $exp) };
        if ($@) {
            $log->warn("SlimPing: background DPL refresh failed for '$exposure_id': $@");
        }
        elsif ($ok) {
            $log->info(sprintf(
                "SlimPing: background DPL refresh for '%s' complete (%.1fs)",
                $exposure_id, Time::HiRes::time() - $t0
            ));
        }
        delete $self->{_refreshing}{$exposure_id};
    } );
}

sub _materialise {
    my ($self, $exposure_id, $exp) = @_;

    my $dpl4_package = $self->{_dpl4_package};
    return undef unless $dpl4_package;

    # Build stub client
    my $stub_client = bless {
        id => 'ssp_dpl_bridge',
    }, 'Plugins::SlimPing::Core::DynamicPlaylistBridge::StubClient';

    my $dpl4_prefs = preferences('plugin.dynamicplaylists4');
    # Use SlimPing's own seed size pref rather than DPL4's playback-oriented
    # max_number_of_unplayed_tracks.  DPL4's default of 20 is designed for
    # continuous refill during playback; OpenSubsonic clients see a static
    # list and benefit from a larger initial seed.
    my $max_tracks = $prefs->get('dpl_seed_size') // 100;
    my $min_tracks = $dpl4_prefs->get('min_number_of_unplayed_tracks') // 5;

    # Collect saved parameter values in the format DPL4 expects — each value
    # must be a hashref { id => N, value => val } because DPL4's
    # replaceParametersInSQL treats every value as a hashref.
    # Internal parameters (PlaylistLimit, PlaylistOffset, PlaylistPlayer, etc.)
    # are handled by DPL4's own getInternalParameters — we must NOT set them.
    my %parameters;

    # Path A: favourites have pre-configured parameters stored in the exposure
    # entry (parsed from the dynamicplaylist:// URL in LMS Favourites OPML).
    if ($exp->{params} && ref $exp->{params} eq 'HASH') {
        %parameters = %{ $exp->{params} };
    }

    # Path B: overlay any additional saved parameter values from DPL4 prefs.
    # Pref-stored params take precedence over favourite URL params when both
    # exist, since the user may have edited the favourite since saving it.
    for my $num (1 .. 20) {
        my $val = $dpl4_prefs->get("playlist_${exposure_id}_parameter_${num}");
        if (defined $val && length $val) {
            $parameters{"PlaylistParameter${num}"} = { id => $num, value => $val };
        }
    }

    # Build the playlist definition hashref that DPL4's getNextDynamicPlaylistTracks
    # expects as its second argument.
    #   dynamicplaylistid — the DPL4-prefixed ID (dpldefault_/dplusercustom_/dplccustom_).
    #     This is used by DPL4 to identify the playlist type; if it lacks the prefix
    #     DPL4 falls through to static playlist handling and fails.
    #   id — the raw filename (without prefix), used as the key into
    #     \$localDynamicPlaylists for SQL lookup.
    #   name — display name (cosmetic, used in log messages).
    my $dpl_playlist_def = {
        dynamicplaylistid => $exp->{dpl_playlist_id} // $exposure_id,
        id                => $exp->{internal_id} // $exposure_id,
        name              => $exp->{name},
    };

    # Call DPL4's API — function-call syntax because getNextDynamicPlaylistTracks
    # expects positional args, not OO method invocation.
    my ($track_ids, $track_info);
    eval {
        no strict 'refs';
        ($track_ids, $track_info) = &{ $dpl4_package . '::getNextDynamicPlaylistTracks' }(
            $stub_client,
            $dpl_playlist_def,
            $max_tracks,
            0,
            \%parameters,
        );
    };

    if ($@) {
        $log->error("SlimPing: DynamicPlaylistBridge materialisation error for '$exposure_id': $@");
        return undef;
    }

    return undef unless $track_ids && ref $track_ids eq 'ARRAY' && @$track_ids;

    # Single batch query: resolve track URLs and collect secs for duration
    # calculation.  A single -in search replaces per-ID find() calls which
    # were an N+1 hotspot at seed sizes of 100+.
    my $schema = Slim::Schema->connect();
    my @track_urls;
    my %url_to_tid;
    my %tid_to_secs;
    my %by_id;
    my @all_tracks = $schema->search('Track', { 'me.id' => { -in => $track_ids } })->all;
    $by_id{ $_->id } = $_ for @all_tracks;
    # Preserve DPL4's ordering by iterating the original ID list
    for my $tid (@$track_ids) {
        my $track = $by_id{$tid} or next;
        push @track_urls, $track->url;
        $url_to_tid{ $track->url } = $tid;
        $tid_to_secs{$tid} = int($track->secs // 0);
    }

    # Filter against dedup history
    my $fresh_urls = $self->_filterHistory($exposure_id, \@track_urls);

    # If insufficient tracks after filtering, clear history and retry
    if (@$fresh_urls < $min_tracks) {
        $self->_clearHistory($exposure_id);
        $fresh_urls = \@track_urls;
    }

    # Build filtered track ID list — only tracks whose URLs survived dedup
    my @filtered_ids = map { $url_to_tid{$_} } @$fresh_urls;
    return undef unless @filtered_ids;

    my $filtered_duration = 0;
    $filtered_duration += $tid_to_secs{$_} for @filtered_ids;

    # Record in history
    $self->_recordHistory($exposure_id, $fresh_urls);

    my $result = {
        tracks       => \@filtered_ids,
        song_count   => scalar @filtered_ids,
        duration     => $filtered_duration,
        generated_at => time(),
    };

    # Cache
    $self->{_cache}->set('sq_dpl_materialised_' . $exposure_id, $result, $prefs->get('dpl_cache_ttl_seconds') // 300);

    return $result;
}

# --- Internal: Track Resolution & Shaping ---

sub _resolveAndShape {
    my ($self, $track_ids) = @_;

    require Plugins::SlimPing::Core::LibraryMapper;
    require Plugins::SlimPing::Core::Container;

    my $mapper  = Plugins::SlimPing::Core::Container->get('library_mapper');
    my $schema  = Slim::Schema->connect();

    # Collect track objects with a single batch query, preserving the
    # materialised ordering.  Per-ID find() calls were an N+1 hotspot at
    # seed sizes of 100+.
    my %by_id;
    $by_id{ $_->id } = $_
        for $schema->search('Track', { 'me.id' => { -in => $track_ids } })->all;
    my @tracks = grep { defined } map { $by_id{$_} } @$track_ids;

    return () unless @tracks;

    # Batch fetch album/artist/genre data via the facade (same pattern as PlaylistStore)
    my $album_data  = $mapper->batchFetchAlbumDataForTracks(\@tracks);
    my $genre_data  = $mapper->batchFetchTrackGenres(\@tracks);

    # batchFetchAlbumArtists expects album IDs, not track objects
    my %album_ids;
    for my $t (@tracks) {
        my $aid = $t->get_column('album');
        $album_ids{$aid} = 1 if defined $aid;
    }
    my $artist_data = $mapper->batchFetchAlbumArtists(
        $schema->dbh,
        [ keys %album_ids ]
    );

    # Shape each track.  shapeTrack expects positional args:
    #   ($self, $track, $genre_name, $album_lookup, $hints)
    # where $hints is a hashref with album_hints/genre_hints/artist_hints keys.
    my @entries;
    for my $track (@tracks) {
        push @entries, $mapper->shapeTrack(
            $track,
            undef,          # $genre_name — not needed; batch-fetched
            undef,          # $album_lookup — not needed; batch-fetched
            {               # $hints
                album_hints  => $album_data,
                genre_hints  => $genre_data,
                artist_hints => $artist_data,
            },
        );
    }

    return @entries;
}

# --- Internal: Dedup History ---

sub _filterHistory {
    my ($self, $exposure_id, $track_urls) = @_;

    my $schema = Plugins::SlimPing::Schema->connect();
    my $dbh    = $schema->storage->dbh;

    my $existing = {};
    my $sth = $dbh->prepare('SELECT track_url FROM sq_dynamic_playlist_history WHERE exposure_id = ?');
    $sth->execute($exposure_id);
    while (my ($url) = $sth->fetchrow_array) {
        $existing->{$url} = 1;
    }

    my @fresh = grep { !$existing->{$_} } @$track_urls;
    return \@fresh;
}

sub _recordHistory {
    my ($self, $exposure_id, $track_urls) = @_;

    my $schema = Plugins::SlimPing::Schema->connect();
    my $dbh    = $schema->storage->dbh;
    my $now    = time();

    my $sth = $dbh->prepare(
        'INSERT OR IGNORE INTO sq_dynamic_playlist_history (exposure_id, track_url, added) VALUES (?, ?, ?)'
    );

    for my $url (@$track_urls) {
        $sth->execute($exposure_id, $url, $now);
    }
}

sub _clearHistory {
    my ($self, $exposure_id) = @_;

    my $schema = Plugins::SlimPing::Schema->connect();
    my $dbh    = $schema->storage->dbh;

    if ($exposure_id) {
        $dbh->do('DELETE FROM sq_dynamic_playlist_history WHERE exposure_id = ?', undef, $exposure_id);
    } else {
        $dbh->do('DELETE FROM sq_dynamic_playlist_history');
    }
}

# --- Internal: Permissions ---

sub _userHasAccess {
    my ($self, $username) = @_;
    return 1 unless defined $username && length $username;
    my $val = $prefs->get("sq_dpl_access_${username}");
    return 1 unless defined $val;    # Default: access
    return $val ? 1 : 0;
}

sub _allowedUserList {
    my $self = shift;
    # Return list of usernames with sq_dpl_access enabled.
    # Since prefs are flat, we iterate user records from Auth::Manager.
    require Plugins::SlimPing::Core::Container;
    my $mgr   = Plugins::SlimPing::Core::Container->get('auth_manager');
    my $users = $mgr->getUsers();
    my @allowed;
    for my $u (@$users) {
        my $uname = $u->{username};
        next unless defined $uname && length $uname;
        my $val = $prefs->get("sq_dpl_access_${uname}");
        push @allowed, $uname unless defined $val && !$val;
    }
    return \@allowed;
}

# --- Internal: Helpers ---

sub _exposureCreatedAt {
    my ($self, $exposure_id) = @_;
    my $ts = $prefs->get("dpl_exposure_created_${exposure_id}");
    unless ($ts) {
        $ts = time();
        $prefs->set("dpl_exposure_created_${exposure_id}", $ts);
    }
    return $ts;
}

# Pure helper function (not a method) — intentionally called as _iso8601($epoch)
# rather than $self->_iso8601($epoch) since it has no object dependency.
sub _iso8601 {
    my ($epoch) = @_;
    return '' unless defined $epoch;
    my @lt = gmtime($epoch);
    return sprintf(
        '%04d-%02d-%02dT%02d:%02d:%02dZ',
        $lt[5] + 1900, $lt[4] + 1, $lt[3],
        $lt[2], $lt[1], $lt[0]
    );
}

# --- Stub Client ---
#
# A minimal stub that satisfies the LMS client API surface that DPL4's
# getNextDynamicPlaylistTracks and getInternalParameters call.  This is NOT
# a real player — it exists only so DPL4's parameter-resolution code can
# read per-client state (cachedArtists, cachedAlbums) and the client ID
# without a real Slim::Player::Client connected.

package Plugins::SlimPing::Core::DynamicPlaylistBridge::StubClient;

sub id {
    my $self = shift;
    return $self->{id};
}

sub name {
    return 'SlimPing Dynamic Playlist Bridge';
}

# Per-client plugin data store.  DPL4's getInternalParameters reads
# cachedArtists and cachedAlbums from pluginData; our stub returns
# empty hashes so preselection parameters are skipped.
sub pluginData {
    my $self = shift;
    my $key  = shift;
    $self->{_pluginData} ||= {};
    if (@_) {
        $self->{_pluginData}{$key} = shift;
    }
    return $self->{_pluginData}{$key};
}

# Stub out methods that LMS or DPL4 may call on a real client but that
# are irrelevant for our headless bridge.  All return sensible defaults.
sub hasDigitalIn { 0 }
sub power         { 0 }
sub isPlaying     { 0 }
sub controller    { return $_[0] }  # return self

1;  # StubClient package return

1;  # DynamicPlaylistBridge package return
