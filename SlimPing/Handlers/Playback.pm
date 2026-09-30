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
# reportPlayback carries a state enum (playing/stopped/paused) and a position:
# a stop only counts as a completed play once _playedEnough clears the standard
# scrobble threshold, so stopping or skipping a track early does not record one.
# Alternative Play Count is fed separately from both, because APC wants every
# ended track -- a play or a skip, as its own threshold decides (see
# Core/ApcTracker.pm).  tokenInfo returns metadata about the API key used for
# the current request.
#

package Plugins::SlimPing::Handlers::Playback;

use strict;
use warnings;

use Time::HiRes qw();
require Digest::SHA;

use Plugins::SlimPing::API::Router;
use Plugins::SlimPing::Core::Logging;
require Plugins::SlimPing::Core::AlternatePlayCount;
require Plugins::SlimPing::Core::Container;
require Plugins::SlimPing::Core::PlaybackReporter;
require Plugins::SlimPing::Utils::Errors;
require Plugins::SlimPing::Utils::Params;

my $log   = Plugins::SlimPing::Core::Logging->getLogger();
my $prefs = Plugins::SlimPing::Core::Logging->getPrefs();

# In-memory dedup: "$username:$sq_id" => epoch of last scrobble submission.
# Prevents the same track being scrobbled multiple times within the configured
# window, matching LMS's checkScrobble behaviour where a track is only queued
# once at the halfway mark.
my %_recent_scrobbles;

# The Alternative Play Count pass tracker for this process.  Built lazily and
# only ever used when the APC plugin is present, so the state stays empty and
# the collaborators are never called otherwise.
my $_apc_tracker;

sub registerHandlers {
    my $class = shift;
    Plugins::SlimPing::API::Router->registerHandler( 'scrobble',       \&scrobble );
    Plugins::SlimPing::API::Router->registerHandler( 'reportPlayback', \&reportPlayback );
    Plugins::SlimPing::API::Router->registerHandler( 'tokenInfo',      \&tokenInfo );
}

# scrobble -- core Subsonic endpoint (since 1.5.0)
# submission=false  -> now-playing notification  -> store in SessionState
# submission=true (or absent, per spec default) -> completed play -> clear state + forward to Last.fm
sub scrobble {
    my ($args)   = @_;
    my $p        = $args->{params};
    my $username = $args->{user}{username};
    my $client   = $p->{c} || 'unknown';

    my @ids = Plugins::SlimPing::Utils::Params->multiParam( $p->{id} );

    if (@ids) {
        my $is_submission = !defined $p->{submission} || $p->{submission} ne 'false';

        # Clients that also use reportPlayback already report every ended track
        # to APC with its real percent, so a completed scrobble from them must
        # not send a second, 100% event.  It only settles a pass that nothing
        # else ended -- some clients finish a queue with a scrobble and no
        # further reportPlayback at all.
        my $skip_apc = Plugins::SlimPing::Core::AlternatePlayCount->apcAvailable
          && _apcTracker()->isTrackedClient( $username, $client );

        for my $id (@ids) {
            _apcTracker()->onScrobbled( $username, $client, $id ) if $skip_apc && $is_submission;
            _recordPlayback( $username, $id, 0, $client, $is_submission, skip_apc => $skip_apc );
        }
    }

    return {};
}

# reportPlayback -- OpenSubsonic extension (playbackReport)
# state=playing/starting -> now-playing with position
# state=stopped          -> completed play, clear state + forward to Last.fm
# state=paused           -> now-playing update without scrobble side-effects
sub reportPlayback {
    my ($args)   = @_;
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

    my $position_secs   = ( $p->{positionMs} // 0 ) / 1000;
    my $state           = $p->{state} || 'playing';
    my $ignore_scrobble = ( $p->{ignoreScrobble} || '' ) eq 'true';

    # A "stopped" report only says playback ended -- not how much of the track
    # played.  Treat it as a completed play (LMS stats, Last.fm, ListenBrainz)
    # only once it clears the standard scrobble threshold.
    my $is_submission = ( $state eq 'stopped' && !$ignore_scrobble && _playedEnough( $media_id, $position_secs ) );

    # Store timeline state for getNowPlaying (playbackReport extension).
    my $ss = Plugins::SlimPing::Core::Container->get('session_state');
    $ss->updatePlaybackState(
        username      => $username,
        client_name   => $client,
        state         => $state,
        position_ms   => $p->{positionMs}   // 0,
        playback_rate => $p->{playbackRate} // 1.0,
    );

    # APC tracking sees every reportPlayback event, so a pass ends with its
    # real percent played rather than as an assumed 100% completion.
    # ignoreScrobble only suppresses LMS stats / Last.fm / ListenBrainz -- the
    # client scrobbles completions itself, and skipped tracks never reach the
    # scrobble endpoint at all.
    if ( Plugins::SlimPing::Core::AlternatePlayCount->apcAvailable ) {
        _apcTracker()
          ->onReport( $username, $client, $media_id, $state, defined $p->{positionMs} ? $position_secs : undef );
    }

    _recordPlayback(
        $username, $media_id, $position_secs, $client, $is_submission,
        stopped  => ( $state eq 'stopped' ? 1 : 0 ),
        skip_apc => 1
    );

    return {};
}

# Shared helper -- both endpoints converge here
sub _recordPlayback {
    my ( $username, $track_id, $position_secs, $client_name, $is_submission, %opts ) = @_;

    my $ss = Plugins::SlimPing::Core::Container->get('session_state');

    if ($is_submission) {
        $ss->clearNowPlaying( $username, $client_name );

        # Dedup: reject scrobbles for the same track within the configured
        # window.  Matches LMS's checkScrobble behaviour where a track is
        # only queued once at the halfway mark.
        my $dedup_key = "$username:$track_id";
        my $now       = time();
        my $window    = $prefs->get('scrobble_dedup_window') // 240;
        if ( my $last = $_recent_scrobbles{$dedup_key} ) {
            if ( $now - $last < $window ) {
                $log->debug(
                    "SlimPing: scrobble dedup skipped for $track_id (last submission " . ( $now - $last ) . "s ago)" );
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

        # Forward skip_apc.  When the APC pass tracker owns this play it has
        # already reported it with the real percentage played, and APC's
        # external reportplayback API is stateless -- a second dispatch records
        # a second play.  Clients may legitimately use both reportPlayback and
        # scrobble for one play, so the deduplication has to happen here.
        Plugins::SlimPing::Core::PlaybackReporter->report(
            $track_id,
            $username,
            submission => 1,
            skip_apc   => $opts{skip_apc} ? 1 : 0,
        );
    }
    elsif ( $opts{stopped} ) {

        # The client says it is no longer playing this track, but it did not
        # clear the scrobble threshold.  Nothing is recorded, and now-playing is
        # cleared rather than re-registered -- a stopped track is not playing.
        $ss->clearNowPlaying( $username, $client_name );
        $log->debug("SlimPing: reportPlayback stopped below the scrobble threshold for $track_id");
    }
    else {
        $ss->setNowPlaying( $username, $track_id, $position_secs // 0, $client_name );
    }

    return;
}

# Has a reported playback position cleared the standard scrobble threshold?
# Duration comes through the mapper facade; the rule itself lives with the rest
# of the play-reporting logic in PlaybackReporter so it can be runtime tested.
sub _playedEnough {
    my ( $media_id, $position_secs ) = @_;

    my $mapper   = Plugins::SlimPing::Core::Container->get('library_mapper');
    my $duration = $mapper ? $mapper->trackDurationSecs($media_id) : 0;

    return Plugins::SlimPing::Core::PlaybackReporter->playedEnough( $duration, $position_secs );
}

# Lazily build the Alternative Play Count pass tracker.  The collaborators are
# wired here rather than inside ApcTracker so it stays free of LMS assumptions
# and can be driven directly by the runtime tests.
sub _apcTracker {
    return $_apc_tracker if $_apc_tracker;

    require Plugins::SlimPing::Core::ApcTracker;

    $_apc_tracker = Plugins::SlimPing::Core::ApcTracker->new(
        durationSecs => sub {
            my ($sq_id) = @_;
            my $mapper = Plugins::SlimPing::Core::Container->get('library_mapper');
            return $mapper ? $mapper->trackDurationSecs($sq_id) : 0;
        },
        thresholdPercent => sub {
            Plugins::SlimPing::Core::AlternatePlayCount->playedThresholdPercent;
        },
        reportEnded => sub {
            my ( $username, $sq_id, $percent ) = @_;
            Plugins::SlimPing::Core::PlaybackReporter->reportApc( $sq_id, $username, $percent );
        },
        armTimer => sub {
            my ( $secs, $callback ) = @_;
            Slim::Utils::Timers::setTimer( undef, Time::HiRes::time() + $secs, $callback );
        },
    );

    return $_apc_tracker;
}

sub tokenInfo {
    my ($args) = @_;
    my $api_key = $args->{params}{k};

    if ($api_key) {
        my $user = Plugins::SlimPing::Core::Container->get('auth_manager')->getUserByApiKey($api_key);
        if ($user) {
            for my $key ( @{ $user->{api_keys} || [] } ) {
                if ( defined $key->{key_hash} && $key->{key_hash} eq Digest::SHA::sha256_hex($api_key) ) {

                    # tokenInfo spec only defines 'username', but label/
                    # created/lastUsed are returned by every major
                    # OpenSubsonic server (Navidrome, Airsonic, Gonic)
                    # and are expected by client API-key management UIs.
                    return {
                        tokenInfo => {
                            label    => $key->{label} || '',
                            created  => $key->{created},
                            lastUsed => $key->{last_used},
                            username => $user->{username},
                        }
                    };
                }
            }
        }
    }

    return { tokenInfo => { label => '', created => undef, lastUsed => undef, username => '' } };
}

1;
