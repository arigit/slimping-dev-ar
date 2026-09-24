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
# Core/PlaybackReporter.pm - Unified play-reporting pipeline
#
# Single entry point for all client-reported plays.  Called from
# Playback.pm when a Subsonic client submits a scrobble or
# reportPlayback.  Gates on per-user preferences and updates
# LMS play statistics plus optional scrobbling and Alternative Play
# Count (APC) reporting services.
#
# Replaces PlaycountSync (tracks.playcount only) and PlayStatsRecorder
# (tracks_persistent only) — both tables are now updated in one call.

package Plugins::SlimPing::Core::PlaybackReporter;

use strict;
use warnings;

require Plugins::SlimPing::Core::AlternatePlayCount;
require Plugins::SlimPing::Core::Container;
require Plugins::SlimPing::Core::Logging;

my $log   = Plugins::SlimPing::Core::Logging->getLogger();
my $prefs = Plugins::SlimPing::Core::Logging->getPrefs();

# In-memory dedup: "$username:$sq_id" => epoch of last recorded play.
# Prevents the same track being recorded twice within the configured
# window.  Needed because exotic-format streams (DSD, CUE) fire via
# both the VirtualPlayer EOS path AND the client scrobble API call.
my %_recent_plays;

# Report a completed play.  Called from Playback.pm when a Subsonic
# client submits a scrobble or reportPlayback, and from
# StreamingClient::nextChunk at EOS for exotic-format streams.
#
# $sq_id    - SlimPing virtual track ID (e.g. "sq_tr_42461")
# $username - authenticated username (for per-user pref gates)
# %params   - additional context from the API call
#   submission - boolean: true = completed play, false = now-playing only
#   skip_apc   - boolean: caller already reported this play to APC with
#                the real percent played (reportPlayback path), so do not
#                send a second, 100% event
#
# Returns 1 on success, 0 if no action was taken (now-playing ping,
# missing params, preference gate closed, dedup hit).  Never throws.
sub report {
    my ( $class, $sq_id, $username, %params ) = @_;

    return 0 unless defined $sq_id && length $sq_id;
    return 0 unless defined $username && length $username;

    # Now-playing pings are not completed plays.
    return 0 unless $params{submission};

    # Dedup: reject plays for the same track within the configured
    # window.  Protects against double-counting when both the
    # VirtualPlayer EOS path and the client scrobble fire.
    my $dedup_key = "$username:$sq_id";
    my $now       = time();
    my $window    = $prefs->get('scrobble_dedup_window') // 240;
    if ( my $last = $_recent_plays{$dedup_key} ) {
        if ( $now - $last < $window ) {
            $log->debug("SlimPing: PlaybackReporter dedup skipped for $sq_id ($username)");
            return 0;
        }
    }
    $_recent_plays{$dedup_key} = $now;

    # Periodic sweep: every 50th play, prune entries older than
    # 2x the window so the hash does not grow unbounded.
    if ( keys(%_recent_plays) % 50 == 0 ) {
        my $cutoff = $now - ( $window * 2 );
        delete @_recent_plays{ grep { $_recent_plays{$_} < $cutoff } keys %_recent_plays };
    }

    my $mgr = Plugins::SlimPing::Core::Container->get('auth_manager');
    return 0 unless $mgr;

    # Gate on per-user preference for Lyrion stats recording. APC is an
    # alternate tracker of the same "track played" fact, so it rides the
    # same gate as the LMS stats update rather than getting its own pref.
    if ( $mgr->isPlaybackLoggingEnabled($username) ) {
        _updateLmsStats($sq_id);
        _dispatchApc($sq_id) unless $params{skip_apc};
    }

    # Scrobbling: Scrobbler.pm applies its own per-user gate internally
    # (isScrobbleEnabled) — we do not double-gate here.
    _dispatchScrobble( $sq_id, $username );

    return 1;
}

# Report a playback-ended event (stop, skip or natural end) to Alternative
# Play Count with how much of the track played. Deliberately separate from
# report(): APC gets every ended track, however little played, and applies
# its own play/skip rules -- report()'s completed-play gate does not apply.
# Rides the same per-user log_playback_to_lms gate as report()'s APC call.
sub reportApc {
    my ( $class, $sq_id, $username, $percent ) = @_;

    return 0 unless defined $sq_id && length $sq_id;
    return 0 unless defined $username && length $username;
    return 0 unless Plugins::SlimPing::Core::AlternatePlayCount->apcAvailable;

    my $mgr = Plugins::SlimPing::Core::Container->get('auth_manager');
    return 0 unless $mgr && $mgr->isPlaybackLoggingEnabled($username);

    _dispatchApc( $sq_id, $percent );
    return 1;
}

# --- Internal helpers --------------------------------------------------------

# Update LMS tracks_persistent (playcount, lastplayed) AND tracks
# (playcount, lastplayed).  tracks_persistent is updated first so that
# Recently Played is correct even if the tracks update fails.  The
# tracks_persistent row feeds Recently Played / APC / Material UI and
# SlimPing's own RawQueries/Queries/Shapes SQL paths; the tracks row
# feeds Subsonic API responses via the DBIx accessor path.
sub _updateLmsStats {
    my ($sq_id) = @_;

    my $mapper = Plugins::SlimPing::Core::Container->get('library_mapper');
    return unless $mapper;

    my ( undef, $raw_id ) = eval { $mapper->decodeId($sq_id) };
    if ( $@ || !defined $raw_id ) {
        $log->warn("SlimPing: PlaybackReporter decode failed for $sq_id");
        return;
    }

    require Slim::Schema;
    my $track = Slim::Schema->find( 'Track', $raw_id );
    unless ($track) {
        $log->warn("SlimPing: PlaybackReporter track $raw_id not found for $sq_id");
        return;
    }

    # Update via LMS's own Track accessor methods — they delegate to
    # tracks_persistent internally (Track.pm:662-673).  Direct resultset
    # manipulation bypasses the retrievePersistent chain and may not
    # commit correctly against the attached persist.db.
    return 0 unless main::STATISTICS;

    eval {
        # Track accessors delegate to tracks_persistent internally
        # (Track.pm:662-673).  They gate on main::STATISTICS themselves;
        # we gate here too so the skip is logged.
        $track->playcount( ( $track->playcount() || 0 ) + 1 );
        $track->lastplayed( time() );
        $log->debug("SlimPing: play recorded for $sq_id ("
              . ( $track->urlmd5 || '?' ) . ")" );
    };
    if ($@) {
        $log->warn("SlimPing: PlaybackReporter stats update failed for $sq_id: $@");
    }
}

# Dispatch to Last.fm / ListenBrainz via the existing Scrobbler module.
# Scrobbler.pm is a stateless class-method-only module — no getInstance().
# It applies its own per-user gate (isScrobbleEnabled) internally.
sub _dispatchScrobble {
    my ( $sq_id, $username ) = @_;

    eval { Plugins::SlimPing::Core::Scrobbler->submit( $username, $sq_id ); };
    if ($@) {
        $log->warn("SlimPing: PlaybackReporter scrobble dispatch failed for $sq_id: $@");
    }
}

# Dispatch to the Alternative Play Count plugin's external reportplayback
# API, if installed. AlternatePlayCount.pm applies its own availability
# gate internally and is a no-op when the plugin is not present.
sub _dispatchApc {
    my ( $sq_id, $percent ) = @_;

    eval { Plugins::SlimPing::Core::AlternatePlayCount->submit( $sq_id, $percent ); };
    if ($@) {
        $log->warn("SlimPing: PlaybackReporter APC dispatch failed for $sq_id: $@");
    }
}

1;
