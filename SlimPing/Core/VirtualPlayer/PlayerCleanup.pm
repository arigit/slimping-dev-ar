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
# Core/VirtualPlayer/PlayerCleanup.pm - Virtual-player cleanup and lifecycle
#
# Extracted from VirtualPlayer.pm.  Handles disconnected-player cleanup
# for slimping-* virtual players that LMS's native HTTP player path does
# not clean up.  Provides the close-handler hook registration, orphaned
# pref/m3u sweep, and both the per-tick and aggressive (shutdown) cleanup
# routines.
#

package Plugins::SlimPing::Core::VirtualPlayer::PlayerCleanup;

use strict;
use warnings;

use Slim::Player::Client;
use Slim::Web::HTTP;
require Plugins::SlimPing::Core::Logging;
require Plugins::SlimPing::Core::PipelinePool;
require Plugins::SlimPing::Core::TranscodeCache;
require Plugins::SlimPing::Core::VirtualPlayer::RemoteGovernor;
require Plugins::SlimPing::Core::VirtualPlayer::StreamingClient;
require Plugins::SlimPing::Core::VirtualPlayer::StreamEnricher;

my $log = Plugins::SlimPing::Core::Logging->getLogger();

# One-shot flag for registering the close-handler cleanup hook.  Registered
# lazily on the first streamViaPipeline call -- no per-player timer overhead.
my $_cleanup_registered = 0;

# Register a single close-handler hook on LMS's HTTP close path.  When any
# HTTP socket closes, the handler scans for disconnected virtual players
# (slimping-* IDs) and calls forgetClient on them.  LMS normally skips
# forgetClient for HTTP players -- closeStreamingSocket only nulls the
# streamingsocket.  Without this, every aborted share/radio stream leaks a
# player entry in the clients list, eventually exhausting listener caps.
#
# Registered lazily on the first streamViaPipeline call.  The handler is
# a single code ref on @closeHandlers -- zero per-player timer overhead.
sub _registerCleanupHandler {
    return if $_cleanup_registered;
    $_cleanup_registered = 1;

    push @Slim::Web::HTTP::closeHandlers, \&_cleanupDisconnectedPlayers;
    $log->debug("SlimPing: close-handler cleanup registered");
}

# Remove client preference entries from the persisted YAML prefs so
# the player is not resurrected on the next LMS restart.  forgetClient
# removes from the in-memory clientHash but does NOT touch the prefs
# file -- without this, stale slimping-* players return as generic
# Slim::Player::Client objects after every restart.
sub _removeClientPrefs {
    my ($client_id) = @_;
    require Slim::Utils::Prefs;
    require Slim::Utils::Prefs::Client;
    foreach my $namespace ( @{ Slim::Utils::Prefs::namespaces() } ) {
        Slim::Utils::Prefs::preferences($namespace)->remove(
            $Slim::Utils::Prefs::Client::clientPreferenceTag . ':' . $client_id
        );
    }
}

# Sweep orphaned pref entries -- clients that exist in the persisted
# YAML prefs (visible to ClientCleanup) but have no corresponding entry
# in the in-memory client hash.  These accumulate from sessions before
# this cleanup was in place.
sub _cleanupOrphanedPrefs {
    my $count = 0;
    require Slim::Utils::Prefs;
    my $prefs = Slim::Utils::Prefs::preferences('server');
    for my $client_pref ( $prefs->allClients ) {
        my $id = $client_pref->{clientid};
        next unless index( $id, 'slimping-' ) == 0;
        next if Slim::Player::Client::getClient($id);

        $log->debug("SlimPing: cleaning up orphaned pref entry for $id");
        _removeClientPrefs($id);
        $count++;
    }
    return $count;
}

# Delete orphaned clientplaylist M3U files from the LMS prefs directory.
# Called once at startup from postinitPlugin -- at that point no slimping-*
# players exist in memory, so every matching file is guaranteed to be a
# zombie.  New files are suppressed by the startupPlaylistLoading flag in
# _startPlayback, so this sweep is a one-off historical cleanup.
sub _sweepOrphanedPlaylistFiles {
    require Slim::Utils::OSDetect;
    require File::Spec::Functions;

    my $prefs_dir = Slim::Utils::OSDetect::dirsFor('prefs');
    return 0 unless $prefs_dir && -d $prefs_dir;

    my $pattern = File::Spec::Functions::catfile( $prefs_dir, 'clientplaylist_slimping-*.m3u' );
    my @files   = glob($pattern);
    my $count   = 0;

    for my $file (@files) {
        if ( unlink($file) ) {
            $count++;
        } else {
            $log->warn("SlimPing: failed to delete orphaned playlist file $file ($!)");
        }
    }

    if ($count) {
        $log->info("SlimPing: cleaned up $count orphaned clientplaylist files");
    }
    return $count;
}

# Public method -- callable from Plugin.pm (startup/shutdown/periodic) and
# AdminApi (manual button).  Cleans up disconnected slimping-* virtual
# players that LMS would otherwise leak (HTTP players bypass Slimproto's
# forget_disconnected_client timer).  Returns count of players removed.
sub cleanupDisconnectedPlayers {
    my $count = 0;
    for my $player ( Slim::Player::Client::clients() ) {
        next unless index( $player->id(), 'slimping-' ) == 0;

        # Stale player resurrected from prefs after an LMS restart --
        # these are generic Slim::Player::Client objects, not HTTP
        # players.  Clean them up without the pipeline/pool handling
        # that only applies to real HTTP player instances.
        if ( !$player->isa('Slim::Player::HTTP') ) {
            $log->debug("SlimPing: cleaning up pref-resurrected player " . $player->id);
            _removeClientPrefs( $player->id() );
            Slim::Player::Client::forgetClient($player);
            Plugins::SlimPing::Core::VirtualPlayer::RemoteGovernor::_releaseRemoteSlot( $player->id() );
            $count++;
            next;
        }

        next if $player->connected();

        $log->debug("SlimPing: cleaning up disconnected virtual player " . $player->id);

        # Clean up any orphaned prime buffer state from a client that
        # disconnected during priming.  Safe no-op for unprimed players.
        Plugins::SlimPing::Core::VirtualPlayer::StreamingClient::_deletePrimeState( $player->id );
        Plugins::SlimPing::Core::VirtualPlayer::StreamEnricher::_deleteCueStopState( $player->id );

        # If this player is a pooled primary, notify PipelinePool so it
        # starts the grace timer instead of immediately tearing down.
        # When listeners remain, the pool keeps the player alive via a
        # keep-alive timer -- do NOT forget the player.
        my $kept = Plugins::SlimPing::Core::PipelinePool->notifyPlayerGone(
            $player->id );

        unless ($kept) {
            # Finalise any in-flight cache entry for this player.
            # The socket has closed so the stream has genuinely ended.
            # The defined-EOS-sentinel path in nextChunk also calls
            # finaliseStream, but STREAMOUT (undef chunk with
            # streamingState==2) and client disconnects only reach
            # us here.  Safe to call on unregistered players (no-op).
            eval {
                Plugins::SlimPing::Core::TranscodeCache->getInstance
                  ->finaliseStream( $player->id );
            };
            _removeClientPrefs( $player->id() );
            Slim::Player::Client::forgetClient($player);
        }
        Plugins::SlimPing::Core::VirtualPlayer::RemoteGovernor::_releaseRemoteSlot( $player->id() );
        $count++;
    }
    Plugins::SlimPing::Core::VirtualPlayer::RemoteGovernor::_reconcileRemoteSlots();

    # Sweep pooled listeners whose HTTP sockets died without _fanOutTick
    # detecting the disconnect.  Prevents zombie pools from keeping the
    # pipeline alive indefinitely.
    Plugins::SlimPing::Core::PipelinePool->sweepStaleListeners();

    # Also sweep orphaned pref entries that have no in-memory client at
    # all -- these are invisible to the clientHash loop above but still
    # show up in ClientCleanup and get resurrected on every LMS restart.
    $count += _cleanupOrphanedPrefs();

    return $count;
}

# Aggressive variant for plugin shutdown -- removes ALL slimping-* players
# regardless of connection state.  Active streams will be terminated.
sub cleanupAllPlayers {
    my $count = 0;
    for my $player ( Slim::Player::Client::clients() ) {
        next unless index( $player->id(), 'slimping-' ) == 0;

        # Pref-resurrected players (generic Client, not HTTP).
        if ( !$player->isa('Slim::Player::HTTP') ) {
            $log->debug("SlimPing: shutdown cleanup for pref-resurrected player " . $player->id);
            _removeClientPrefs( $player->id() );
            Slim::Player::Client::forgetClient($player);
            Plugins::SlimPing::Core::VirtualPlayer::RemoteGovernor::_releaseRemoteSlot( $player->id() );
            $count++;
            next;
        }

        $log->debug("SlimPing: shutdown cleanup for virtual player " . $player->id);

        Plugins::SlimPing::Core::VirtualPlayer::StreamingClient::_deletePrimeState( $player->id );
        Plugins::SlimPing::Core::VirtualPlayer::StreamEnricher::_deleteCueStopState( $player->id );

        Plugins::SlimPing::Core::PipelinePool->notifyPlayerGone( $player->id );

        eval {
            Plugins::SlimPing::Core::TranscodeCache->getInstance
              ->finaliseStream( $player->id );
        };
        _removeClientPrefs( $player->id() );
        Slim::Player::Client::forgetClient($player);
        Plugins::SlimPing::Core::VirtualPlayer::RemoteGovernor::_releaseRemoteSlot( $player->id() );
        $count++;
    }
    Plugins::SlimPing::Core::VirtualPlayer::RemoteGovernor::_reconcileRemoteSlots();
    $count += _cleanupOrphanedPrefs();
    return $count;
}

# Named sub so LMS's realNameForCodeRef (PerlRunTime.pm:117) does not crash on
# an anonymous coderef when INFOLOG is enabled.  Pushed onto @closeHandlers by
# _registerCleanupHandler on the first streamViaPipeline call.
sub _cleanupDisconnectedPlayers {
    cleanupDisconnectedPlayers();
}

1;
