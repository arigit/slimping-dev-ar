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
# Handlers/Playback.pm - Playback reporting and token info
#
# scrobble (core Subsonic) and reportPlayback (OpenSubsonic extension) both
# converge on _recordPlayback which writes to SessionState.  scrobble carries
# a submission flag (false = now playing, true = completed play) while
# reportPlayback carries a state enum (playing/stopped/paused) plus a
# position -- state=stopped only counts as a completed play (LMS stats,
# Last.fm/ListenBrainz) once _playedEnough clears the standard scrobble
# threshold, so stopping or skipping a track early does not record a full
# play. Alternative Play Count is fed separately, mirroring how APC tracks
# real LMS players (see _apcTrack).
# tokenInfo returns metadata about the API key used for the current request.
#

package Plugins::SlimPing::Handlers::Playback;

use strict;
use warnings;

use Time::HiRes qw();
require Digest::SHA;

use Plugins::SlimPing::API::Router;
use Plugins::SlimPing::Core::Logging;
require Plugins::SlimPing::Core::Container;
require Plugins::SlimPing::Core::PlaybackReporter;
require Plugins::SlimPing::Utils::Errors;
require Plugins::SlimPing::Utils::Params;

my $log   = Plugins::SlimPing::Core::Logging->getLogger();
my $prefs = Plugins::SlimPing::Core::Logging->getPrefs();

# Standard Last.fm/LMS scrobble threshold: a track counts as "played" once
# playback passes half its length or this many seconds, whichever comes
# first.
use constant SCROBBLE_THRESHOLD_MAX_SECS => 240;

# APC playback tracking: "$username:$client" => { username, media_id,
# position_secs, max_pos, stopping, done, gen } for the current pass
# through the last track reportPlayback saw on that client. max_pos = the
# furthest position this pass reached, which is what gets reported (APC's
# own players count a play the moment the threshold is crossed, however
# far back the listener jumps afterwards); stopping = a stopped is waiting
# to learn whether a next track follows; done = this pass's APC outcome
# has been settled; gen = id of the only stop/pause timer still allowed to
# act on it.
# One entry per user+client, so it cannot grow unbounded. An entry also
# marks the client as a reportPlayback client, whose APC events come from
# here rather than from the scrobble endpoint (see scrobble).
my %_apc_tracks;
my $_apc_gen = 0;

# "$username:$client" => { media_id, at } for the last track _apcTrack
# reported as skipped. Clients that report the next track before sending
# stopped for the previous one would otherwise have that late stopped
# counted twice (and end the new track).
my %_apc_skipped;
use constant APC_LATE_STOP_SECS => 30;

# A stopped followed by a different track within this window was a skip
# (or a natural end moving to the next track); with nothing following, it
# was a plain stop.
use constant APC_STOP_GRACE_SECS => 10;

# A pause with no further report for this long is taken as abandoned
# playback (e.g. the client app was closed) and settled like a plain stop.
use constant APC_PAUSE_TIMEOUT_SECS => 900;

# Back within this many seconds of the start of the same track, after
# getting further than this beyond it, is a new pass through the track:
# the client resetting its last track at the end of the queue (Symfonium
# reports playing at 0 instead of stopping), or the listener restarting it.
use constant APC_RESTART_SECS => 10;

# A pause this close to the track's end is the client stopping at the end
# of its queue (Symfonium pauses on the last track instead of sending
# stopped) -- a natural finish, settled at once rather than via the pause
# timeout.
use constant APC_END_SLACK_SECS => 2;

# In-memory dedup: "$username:$sq_id" => epoch of last scrobble submission.
# Prevents the same track being scrobbled multiple times within the configured
# window, matching LMS's checkScrobble behaviour where a track is only queued
# once at the halfway mark.
my %_recent_scrobbles;

sub registerHandlers {
    my $class = shift;
    Plugins::SlimPing::API::Router->registerHandler('scrobble',       \&scrobble);
    Plugins::SlimPing::API::Router->registerHandler('reportPlayback', \&reportPlayback);
    Plugins::SlimPing::API::Router->registerHandler('tokenInfo',      \&tokenInfo);
}

# scrobble -- core Subsonic endpoint (since 1.5.0)
# submission=false  -> now-playing notification  -> store in SessionState
# submission=true (or absent, per spec default) -> completed play -> clear state + forward to Last.fm
sub scrobble {
    my ($args) = @_;
    my $p        = $args->{params};
    my $username = $args->{user}{username};
    my $client   = $p->{c} || 'unknown';

    my @ids = Plugins::SlimPing::Utils::Params->multiParam($p->{id});

    if (@ids) {
        my $is_submission = !defined $p->{submission} || $p->{submission} ne 'false';

        # Clients that also use reportPlayback (e.g. Symfonium, which sends
        # reportPlayback with ignoreScrobble=true and scrobbles completions
        # here) already report every ended track to APC with its real
        # percent -- a 100% from here would count finished tracks twice.
        my $skip_apc = exists $_apc_tracks{"$username:$client"};

        for my $id (@ids) {
            _recordPlayback($username, $id, 0, $client, $is_submission,
                skip_apc => $skip_apc);
        }
    }

    return {};
}

# reportPlayback -- OpenSubsonic extension (playbackReport)
# state=playing/starting -> now-playing with position
# state=stopped          -> completed play, clear state + forward to Last.fm
# state=paused           -> now-playing update without scrobble side-effects
sub reportPlayback {
    my ($args) = @_;
    my $p        = $args->{params};
    my $username = $args->{user}{username};
    my $client   = $p->{c} || 'unknown';

    my $media_id = $p->{mediaId}
        or return Plugins::SlimPing::Utils::Errors->missingParam('mediaId');

    # OpenSubsonic spec: mediaType is required (song or podcast).
    my $media_type = $p->{mediaType} || '';
    unless ( $media_type eq 'song' || $media_type eq 'podcast' ) {
        return {
            error => {
                code    => 10,
                message => 'Required parameter mediaType must be "song" or "podcast"'
            }
        };
    }

    # Gate on per-user toggle for the playbackReport extension.
    my $mgr = Plugins::SlimPing::Core::Container->get('auth_manager');
    unless ( $mgr->isPlaybackReportAccepted($username) ) {
        return {
            error => {
                code    => 50,
                message => 'Playback report not enabled for this user'
            }
        };
    }

    my $position_secs = ($p->{positionMs} // 0) / 1000;
    my $state         = $p->{state} || 'playing';
    my $ignore_scrobble = ($p->{ignoreScrobble} || '') eq 'true';
    my $is_submission   = ($state eq 'stopped' && !$ignore_scrobble
        && _playedEnough($media_id, $position_secs));

    # ignoreScrobble only suppresses LMS stats / Last.fm / ListenBrainz
    # (the client scrobbles completions itself). APC still gets every
    # ended track: skipped tracks never reach the scrobble endpoint.
    _apcTrack($username, $client, $media_id, $state,
        defined $p->{positionMs} ? $position_secs : undef);

    # Store timeline state for getNowPlaying (playbackReport extension).
    my $ss = Plugins::SlimPing::Core::Container->get('session_state');
    $ss->updatePlaybackState(
        username      => $username,
        client_name   => $client,
        state         => $state,
        position_ms   => $p->{positionMs} // 0,
        playback_rate => $p->{playbackRate} // 1.0,
    );

    # APC was already told about this stop by _apcTrack, with the real
    # percent played -- keep the completed-play path from sending a 100%.
    _recordPlayback($username, $media_id, $position_secs, $client, $is_submission,
        skip_apc => 1);

    return {};
}

# Feed reportPlayback events to Alternative Play Count, mirroring how APC
# itself tracks real LMS players (its external reportplayback API is
# stateless -- every call is final: >= APC's played threshold records a
# play, anything below records a skip):
#
#   - Moving on to a different track ends the previous one and it is
#     always reported with its percent played -- a play or a skip, as APC
#     decides. This covers skip-to-next and natural ends alike, whether or
#     not the client sent stopped first (APC's "newsong").
#   - A plain stop (stopped, no next track within APC_STOP_GRACE_SECS) and
#     an abandoned pause (no report for APC_PAUSE_TIMEOUT_SECS) are only
#     reported if the track reached APC's played threshold. APC records
#     nothing for a stop or pause of its own players below the threshold,
#     so these must not be sent as skips. A plain stop always settles the
#     track; an abandoned pause below the threshold stays open, so resuming
#     it later (or moving on from it) still reports, as APC's players do.
#   - A pause alone reports nothing; resuming and finishing gives one event.
#     A pause at the very end of the track is the end of the client's queue
#     and settles immediately.
#   - Returning to the start of the same track (APC_RESTART_SECS) after
#     reaching APC's threshold completes that pass -- reported at once --
#     and begins a new one. Other jumps back just continue the pass.
#   - A pass that never got past position 0 was never listened to and is
#     not reported (e.g. the track Symfonium resets to at the queue end).
#
# A repeated stopped, or a late stopped for a track already reported as
# skipped, is ignored so APC never sees the same play twice.
sub _apcTrack {
    my ($username, $client, $media_id, $state, $position_secs) = @_;

    my $key  = "$username:$client";
    my $now  = Time::HiRes::time();
    my $prev = $_apc_tracks{$key};

    $log->debug(sprintf "SlimPing: APC track %s: %s %s pos=%s",
        $key, $state, $media_id, defined $position_secs ? sprintf('%.1fs', $position_secs) : 'none');

    if ($state eq 'stopped' && (!$prev || $prev->{media_id} ne $media_id)) {
        my $skipped = $_apc_skipped{$key};
        if ($skipped && $skipped->{media_id} eq $media_id
            && $now - $skipped->{at} < APC_LATE_STOP_SECS) {
            $log->debug("SlimPing: APC ignoring late stopped for already-skipped $media_id");
            return;
        }
    }

    if ($prev && $prev->{media_id} ne $media_id) {
        _apcEndOnNext($key, $prev, $now);
        $prev = undef;
    }

    # Reports without positionMs fall back to the last known position.
    $position_secs //= $prev ? $prev->{position_secs} : 0;

    if ($state eq 'stopped') {
        return if $prev && ($prev->{stopping} || $prev->{done});
        my $track = $prev || _apcNewTrack($username, $media_id);
        _apcSetPosition($track, $position_secs);
        $track->{stopping} = 1;
        _apcArmTimer($key, $track, APC_STOP_GRACE_SECS);
        $_apc_tracks{$key} = $track;
        return;
    }

    # Any other report cancels a pending stop/pause timer.
    my $track = $prev;
    if ($track && $track->{stopping}) {
        # Same track reported again after a stop: that was a plain stop,
        # and this is a new pass through the track.
        _apcSettle($track);
        $track = undef;
    }
    elsif ($track && $position_secs <= APC_RESTART_SECS
        && $track->{max_pos} > $position_secs + APC_RESTART_SECS) {
        # Back at the start: a pass that reached the threshold is complete.
        if ($track->{done}) {
            $track = undef;
        } elsif (_apcReachedThreshold($track)) {
            _apcSettle($track);
            $track = undef;
        }
    }
    $track ||= _apcNewTrack($username, $media_id);

    _apcSetPosition($track, $position_secs);
    $track->{gen} = ++$_apc_gen;
    if ($state eq 'paused' && !$track->{done}) {
        my $duration = _trackDuration($media_id);
        if ($duration > 0 && $position_secs >= $duration - APC_END_SLACK_SECS) {
            _apcSettle($track);
        } else {
            _apcArmTimer($key, $track, APC_PAUSE_TIMEOUT_SECS);
        }
    }

    $_apc_tracks{$key} = $track;
    return;
}

# The client moved on to a different track: report the previous pass with
# how far it got -- a play or a skip, as APC decides -- unless it was
# already settled or never started.
sub _apcEndOnNext {
    my ($key, $track, $now) = @_;
    return if $track->{done};

    if ($track->{max_pos} <= 0) {
        $log->debug("SlimPing: APC not reporting $track->{media_id} -- never played past 0s");
        return;
    }

    _apcReportEnded($track->{username}, $track->{media_id}, $track->{max_pos});
    $_apc_skipped{$key} = { media_id => $track->{media_id}, at => $now };
}

sub _apcSetPosition {
    my ($track, $position_secs) = @_;
    $track->{position_secs} = $position_secs;
    $track->{max_pos}       = $position_secs if $position_secs > $track->{max_pos};
}

sub _apcReachedThreshold {
    my ($track) = @_;
    my $percent = _percentPlayed($track->{media_id}, $track->{max_pos});
    return defined $percent
        && $percent >= Plugins::SlimPing::Core::AlternatePlayCount->playedThresholdPercent;
}

sub _apcNewTrack {
    my ($username, $media_id) = @_;
    return { username => $username, media_id => $media_id,
             position_secs => 0, max_pos => 0, stopping => 0, done => 0, gen => 0 };
}

# One pending timer per track: arming a new one (or any later report)
# bumps gen, so an older timer finds itself stale and does nothing.
sub _apcArmTimer {
    my ($key, $track, $secs) = @_;
    $track->{gen} = ++$_apc_gen;
    Slim::Utils::Timers::setTimer(undef, time() + $secs, \&_apcTimerFired, $key, $track->{gen});
}

# Named timer callback -- LMS's PerlRunTime.pm crashes on anonymous
# coderefs when INFOLOG is enabled.
sub _apcTimerFired {
    my (undef, $key, $gen) = @_;
    my $track = $_apc_tracks{$key};
    return unless $track && $track->{gen} == $gen;
    _apcSettle($track, paused => !$track->{stopping});
}

# Settle a track that ended without a next track following (plain stop or
# abandoned pause): report it only if it reached APC's played threshold.
# Below the threshold, a stop still closes the track, but a pause leaves it
# open -- the client may resume it.
sub _apcSettle {
    my ($track, %opts) = @_;
    return if $track->{done};
    $track->{stopping} = 0;

    my $percent   = _percentPlayed($track->{media_id}, $track->{max_pos});
    my $threshold = Plugins::SlimPing::Core::AlternatePlayCount->playedThresholdPercent;

    if (defined $percent && $percent >= $threshold) {
        $track->{done} = 1;
        _apcReportEnded($track->{username}, $track->{media_id}, $track->{max_pos});
        return;
    }

    $track->{done} = 1 unless $opts{paused};
    $log->debug(sprintf "SlimPing: APC not reporting %s -- %s at %s, below APC threshold %d%%",
        $track->{media_id}, $opts{paused} ? 'paused' : 'stopped',
        defined $percent ? sprintf('%d%%', $percent) : 'unknown duration', $threshold);
}

sub _apcReportEnded {
    my ($username, $media_id, $position_secs) = @_;

    my $percent = _percentPlayed($media_id, $position_secs);
    unless (defined $percent) {
        $log->debug("SlimPing: APC skipped for $media_id -- track duration unknown");
        return;
    }

    $log->debug(sprintf "SlimPing: APC ended %s at %.1fs (%d%%)",
        $media_id, $position_secs, $percent + 0.5);
    Plugins::SlimPing::Core::PlaybackReporter->reportApc($media_id, $username, $percent);
}

# Percent of the track played (0-100, may be fractional), or undef when the
# track's duration cannot be determined.
sub _percentPlayed {
    my ($media_id, $position_secs) = @_;

    my $duration = _trackDuration($media_id);
    return undef unless $duration > 0;

    my $percent = 100 * ($position_secs || 0) / $duration;
    $percent = 0   if $percent < 0;
    $percent = 100 if $percent > 100;
    return $percent;
}

# Track length in seconds from the LMS library, or 0 when unknown.
sub _trackDuration {
    my ($media_id) = @_;

    my $mapper = Plugins::SlimPing::Core::Container->get('library_mapper');
    my (undef, $raw_id) = eval { $mapper->decodeId($media_id) };
    return 0 if $@ || !defined $raw_id;

    require Slim::Schema;
    my $track = Slim::Schema->find('Track', $raw_id);
    return 0 unless $track;

    return $track->secs || 0;
}

# A "stopped" report fires identically whether the track finished
# naturally or the client stopped/skipped it 5 seconds in -- reportPlayback
# just tells us playback ended, not how much of it played. Require reaching
# the standard Last.fm/LMS scrobble threshold (half the track, capped at
# SCROBBLE_THRESHOLD_MAX_SECS) before treating a stop as a completed play.
# Conservative on missing data: no known position or duration -> not counted.
sub _playedEnough {
    my ($media_id, $position_secs) = @_;
    return 0 unless $position_secs && $position_secs > 0;

    my $duration = _trackDuration($media_id);
    return 0 unless $duration > 0;

    my $threshold = $duration / 2;
    $threshold = SCROBBLE_THRESHOLD_MAX_SECS if $threshold > SCROBBLE_THRESHOLD_MAX_SECS;

    return $position_secs >= $threshold;
}

# Shared helper -- both endpoints converge here
sub _recordPlayback {
    my ($username, $track_id, $position_secs, $client_name, $is_submission, %opts) = @_;

    my $ss = Plugins::SlimPing::Core::Container->get('session_state');

    if ($is_submission) {
        $ss->clearNowPlaying($username, $client_name);

        # Dedup: reject scrobbles for the same track within the configured
        # window.  Matches LMS's checkScrobble behaviour where a track is
        # only queued once at the halfway mark.
        my $dedup_key = "$username:$track_id";
        my $now       = time();
        my $window    = $prefs->get('scrobble_dedup_window') // 240;
        if ( my $last = $_recent_scrobbles{$dedup_key} ) {
            if ( $now - $last < $window ) {
                $log->debug("SlimPing: scrobble dedup skipped for $track_id (last submission " . ($now - $last) . "s ago)");
                return;
            }
        }
        $_recent_scrobbles{$dedup_key} = $now;

        # Periodic sweep: every 50th scrobble, prune entries older than
        # 2x the window so the hash does not grow unbounded.
        if ( keys(%_recent_scrobbles) % 50 == 0 ) {
            my $cutoff = $now - ( $window * 2 );
            delete @_recent_scrobbles{ grep { $_recent_scrobbles{$_} < $cutoff } keys %_recent_scrobbles };
        }

        Plugins::SlimPing::Core::PlaybackReporter->report(
            $track_id, $username, submission => 1, skip_apc => $opts{skip_apc}
        );
    } else {
        $ss->setNowPlaying($username, $track_id, $position_secs // 0, $client_name);
    }

    return;
}

sub tokenInfo {
    my ($args) = @_;
    my $api_key = $args->{params}{k};

    if ($api_key) {
        my $user = Plugins::SlimPing::Core::Container->get('auth_manager')
            ->getUserByApiKey($api_key);
        if ($user) {
            for my $key (@{ $user->{api_keys} || [] }) {
                if (defined $key->{key_hash} && $key->{key_hash} eq Digest::SHA::sha256_hex($api_key)) {
                    # tokenInfo spec only defines 'username', but label/
                    # created/lastUsed are returned by every major
                    # OpenSubsonic server (Navidrome, Airsonic, Gonic)
                    # and are expected by client API-key management UIs.
                    return {
                        tokenInfo => {
                            label    => $key->{label}    || '',
                            created  => $key->{created},
                            lastUsed => $key->{last_used},
                            username => $user->{username},
                        }
                    };
                }
            }
        }
    }

    return { tokenInfo =>
        { label => '', created => undef, lastUsed => undef, username => '' } };
}

1;
