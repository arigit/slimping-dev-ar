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
# Core/AlternatePlayCount.pm - Feed playback-ended events into Alternative
# Play Count's external dispatch API
#
# Stateless utility -- class methods only, no constructor.  Called via
# PlaybackReporter.pm whenever a track stops playing, completed or not.
#
# The Alternative Play Count plugin (APC, github.com/AF-1/lms-alternativeplaycount)
# cannot see plays SlimPing serves to OpenSubsonic clients -- they never pass
# through a real Slim::Player::Client, so LMS never fires the newsong/status
# events APC normally listens for. Since v1.9.5 APC exposes a CLI dispatch
# for exactly this case:
#
#   ['alternativeplaycount', 'reportplayback', '_mac', '_playername', '_trackid', '_percentplayed']
#
# percentplayed is an integer 0-100. APC records a play at or above its
# playedthreshold_percent pref and a skip below it. SlimPing passes how
# much of the track actually played; which events are sent at all follows
# APC's own player tracking (see Handlers/Playback.pm _apcTrack). Signals
# that carry no position (core scrobble submission=true, VirtualPlayer
# EOS) mean the track finished and report 100.
#
# Gated at two levels:
#   1. AlternativePlayCount plugin installed (startup probe flag)
#   2. Per-user log_playback_to_lms preference (same gate as the LMS stats
#      update -- applied by the caller in PlaybackReporter.pm)

package Plugins::SlimPing::Core::AlternatePlayCount;

use strict;
use warnings;

use Slim::Control::Request;

use Plugins::SlimPing::Core::Logging;
require Plugins::SlimPing::Core::Container;

my $log = Plugins::SlimPing::Core::Logging->getLogger();

# Set once by Plugin.pm at startup -- plugins cannot be installed mid-session.
my $_apc_available = 0;

# Persistent fake identity for the virtual "player" SlimPing reports plays
# under. APC keys its playlist-history/player-list entries by this MAC, so
# it must stay constant across calls and restarts rather than being derived
# per-play or per-user.
use constant APC_MAC         => '02:53:6c:69:6d:50'; # locally-administered; spells "Slimp"
use constant APC_PLAYER_NAME => 'SlimPing';

# APC's played threshold in percent (APC default 20). Only consulted for a
# track that ended without a next track following (plain stop, abandoned
# pause): APC's own player tracking records nothing for those below the
# threshold, while its reportplayback API would record a skip.
sub playedThresholdPercent {
    require Slim::Utils::Prefs;
    my $pct = eval {
        Slim::Utils::Prefs::preferences('plugin.alternativeplaycount')->get('playedthreshold_percent');
    };
    return $pct || 20;
}

sub setApcAvailable { $_apc_available = $_[1] ? 1 : 0; }
sub apcAvailable    { return $_apc_available; }

# Report a playback-ended event to APC. $percent defaults to 100 and is
# clamped to an integer 0-100. Returns 1 on success, 0 on skip/failure (all
# failures are logged, caller ignores the return value -- APC reporting is
# best-effort and never blocks the Subsonic response).
sub submit {
    my ($class, $sq_id, $percent) = @_;

    return 0 unless $_apc_available;
    return 0 unless defined $sq_id && length $sq_id;

    $percent = 100 unless defined $percent;
    $percent = int($percent + 0.5);
    $percent = 0   if $percent < 0;
    $percent = 100 if $percent > 100;

    my $mapper = Plugins::SlimPing::Core::Container->get('library_mapper');
    my (undef, $raw_id) = eval { $mapper->decodeId($sq_id) };
    if ($@ || !defined $raw_id) {
        $log->warn("SlimPing: APC decode failed for $sq_id: $@");
        return 0;
    }

    my $request = eval {
        Slim::Control::Request::executeRequest(undef, [
            'alternativeplaycount', 'reportplayback',
            APC_MAC, APC_PLAYER_NAME, $raw_id, $percent,
        ]);
    };
    if ($@) {
        $log->warn("SlimPing: APC reportplayback dispatch failed for $sq_id: $@");
        return 0;
    }

    if ($request && eval { $request->isStatusError }) {
        $log->warn("SlimPing: APC reportplayback rejected for $sq_id (raw=$raw_id)");
        return 0;
    }

    $log->debug("SlimPing: APC playback reported for $sq_id (raw=$raw_id, $percent%)");
    return 1;
}

1;
