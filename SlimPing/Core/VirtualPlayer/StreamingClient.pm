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
# Core/VirtualPlayer/StreamingClient.pm - LMS virtual-player subclass for SlimPing
#
# Extracted from VirtualPlayer.pm.  Contains the inline Slim::Player::HTTP
# subclass (Plugins::SlimPing::Core::StreamingClient) that properly terminates
# the HTTP streaming response when the track ends, plus pre-buffer priming state
# that lives on the same player instance.
#

package Plugins::SlimPing::Core::VirtualPlayer::StreamingClient;

use strict;
use warnings;

use Slim::Player::HTTP;
require Plugins::SlimPing::Core::Logging;
require Plugins::SlimPing::Core::PipelinePool;
require Plugins::SlimPing::Core::TranscodeCache;

my $log = Plugins::SlimPing::Core::Logging->getLogger();

# Pre-buffer priming: accumulate audio before sending to the client so the
# transcode pipeline has time to fill its pipe buffers and the client receives
# a healthy initial burst.  Target is 128 KB of MP3 audio (~3.2 s at 320 kbps).
# Max retries bounds the phase at 15 polls x 0.4 s RETRY_TIME = 6 s.  On timeout,
# any buffered data is flushed immediately rather than discarded.
my $PRIME_BUFFER_BYTES = 131072;                # 128 KB
my $PRIME_MAX_RETRIES  = 15;                     # 6 s max

# Pre-buffer priming state.  Keyed by client ID.  Set in _startPlayback
# before addStreamingResponse starts the write watcher; consumed and deleted
# by the primed path in nextChunk.  Cleaned up by _cleanupDisconnectedPlayers
# for clients that disconnect during priming.
my %_prime_buffer;                               # client_id => accumulated MP3 data
my %_prime_count;                                # client_id => retry counter

# Cross-module accessor: called by VirtualPlayer::_startPlayback to initiate
# pre-buffer priming for a new transcode stream.
sub _initPrimeBuffer {
    my ($client_id) = @_;
    $_prime_buffer{ $client_id } = '';
    $_prime_count{ $client_id }  = 0;
    $log->debug( "SlimPing: prime buffer initiated for " . $client_id );
}

# Cross-module accessor: called by PlayerCleanup to drop orphaned priming
# state for a player that disconnected before priming completed.
sub _deletePrimeState {
    my ($player_id) = @_;
    delete $_prime_buffer{ $player_id };
    delete $_prime_count{ $player_id };
}

# Inline subclass of Slim::Player::HTTP that properly terminates the HTTP
# streaming response when the track ends.
#
# Slim::Player::HTTP::nextChunk returns undef on end-of-stream.  LMS's
# sendStreamingResponse (Slim/Web/HTTP.pm:2299) treats undef as "no data
# yet, retry later" -- it sets a timer and re-enters polling.  After the
# controller fires playerStopped, the player enters the stop state and
# sendStreamingResponse falls into its silence path (line 2211), sending
# silence MP3 frames indefinitely.  The connection never closes, so
# Subsonic clients hang waiting for an end-of-stream signal.
#
# The fix: return a reference to an empty string (not undef) on EOS.
# sendStreamingResponse sees a defined-but-empty chunk at line 2293 and
# calls forgetClient, which closes the streaming socket cleanly.  The
# controller events fired are identical to the parent -- only the return
# value to the HTTP streaming layer differs.
{

    package Plugins::SlimPing::Core::StreamingClient;
    use base qw(Slim::Player::HTTP);

    # Per-instance model overrides.  Keyed by client ID so convert.conf rules
    # can target specific Subsonic clients (e.g. slimping-symfonium).
    my %_instance_model;

    # Per-instance live-stream flag.  Live streams (internet radio) never
    # reach a genuine EOF -- STREAMOUT means a temporary buffer underrun
    # between segments, not end-of-stream.  Finite remote URLs (favourites
    # pointing to HTTP MP3s) are NOT live and must still terminate on EOF.
    my %_is_live_stream;

    # Override the player model so custom-convert.conf rules can target only
    # SlimPing virtual players without affecting real Squeezebox hardware.
    # LMS's TranscodingHelper calls $client->model() to match the clienttype
    # field in convert.conf profiles.
    #
    # When _instance_model is set for this client, the value is the full model
    # string (e.g. 'slimping-symfonium').  Otherwise falls back to 'slimping'
    # which matches all generic SlimPing rules.
    sub model {
        my $client = $_[0];
        return $_instance_model{ $client->id } || 'slimping';
    }

    sub modelName { 'SlimPing Virtual Player' }

    # LMS's serverstatusQuery calls vfdmodel() on every player whose model
    # is not 'http' (Queries.pm:2652).  Slim::Player::HTTP never defines it
    # because the guard skips it.  Our model override ('slimping') now trips
    # the guard, so we must provide a stub to prevent a method-not-found crash.
    sub vfdmodel { 'none' }

    # Set a per-client model override.  Called by streamViaPipeline after
    # construction.  $client_model is a normalised token safe for use as a
    # convert.conf clienttype field (lowercase, alphanumeric plus hyphens).
    sub _setModel {
        my ( $client, $client_model ) = @_;
        $_instance_model{ $client->id } = $client_model
          if defined $client_model && length $client_model;
        $log->debug( "SlimPing: client model set to " . ( $client_model || 'slimping' ) . " for " . $client->id );
    }

    # Mark a client as streaming live content (internet radio).  Live streams
    # never reach a genuine EOF -- STREAMOUT is a temporary buffer underrun
    # between segments.  Finite remote URLs (favourites, shares) are NOT live.
    sub _setLiveStream {
        my ( $client, $flag ) = @_;
        $_is_live_stream{ $client->id } = $flag ? 1 : 0;
        $log->debug( "SlimPing: live stream flag set to " . ( $flag ? 1 : 0 ) . " for " . $client->id );
    }

    sub nextChunk {
        my $client = $_[0];
        my $chunk  = Slim::Player::Source::nextChunk(@_);

        # --- Phase 0: cache ingest + pool push (always runs) ---------------

        Plugins::SlimPing::Core::TranscodeCache->getInstance->ingestChunk(
            $client->id, $chunk );

        if ( defined($chunk) && length($$chunk) ) {
            Plugins::SlimPing::Core::PipelinePool::pushChunk(
                $client->id, $chunk );
        }

        if (    defined($chunk)
             && length($$chunk) == 0
             && !$_is_live_stream{ $client->id } )
        {
            Plugins::SlimPing::Core::PipelinePool::pushChunk(
                $client->id, $chunk );
        }

        # --- Phase 1: live stream fast-path ----------------------------------
        # Live streams never reach a genuine EOF -- return the chunk (or undef)
        # directly without entering the prime-buffer or EOS logic below.
        if ( $_is_live_stream{ $client->id } ) {
            return $chunk;
        }

        # --- Phase 2: pre-buffer priming -----------------------------------

        if ( exists $_prime_buffer{ $client->id } ) {
            if ( defined($chunk) && length($$chunk) > 0 ) {
                $_prime_buffer{ $client->id } .= $$chunk;
                if ( length( $_prime_buffer{ $client->id } ) >= $PRIME_BUFFER_BYTES ) {
                    my $data = delete $_prime_buffer{ $client->id };
                    delete $_prime_count{ $client->id };
                    $log->debug(
                        sprintf(
                            'SlimPing: prime flush (full, %d bytes) for %s',
                            length($data), $client->id
                        )
                    );
                    return \$data;
                }
                return undef;
            }

            if ( defined($chunk) && length($$chunk) == 0 ) {
                my $data = delete $_prime_buffer{ $client->id };
                delete $_prime_count{ $client->id };
                if ( length($data) ) {
                    $log->debug(
                        sprintf(
                            'SlimPing: prime flush (EOS, %d bytes) for %s',
                            length($data), $client->id
                        )
                    );
                    return \$data;
                }
                # Empty buffer at EOS -- fall through to normal EOS handling
            }
            else {
                # Undefined chunk -- no data available yet.
                my $ss = $client->controller()->{'streamingState'};
                if ( defined($ss) && $ss == 2 ) {
                    my $data = delete $_prime_buffer{ $client->id };
                    delete $_prime_count{ $client->id };
                    if ( length($data) ) {
                        $log->debug(
                            sprintf(
                                'SlimPing: prime flush (STREAMOUT, %d bytes) for %s',
                                length($data), $client->id
                            )
                        );
                        return \$data;
                    }
                    # Empty buffer at STREAMOUT -- fall through to normal EOS
                }
                else {
                    $_prime_count{ $client->id }++;
                    if ( $_prime_count{ $client->id } > $PRIME_MAX_RETRIES ) {
                        my $data = delete $_prime_buffer{ $client->id };
                        delete $_prime_count{ $client->id };
                        if ( length($data) ) {
                            $log->debug(
                                sprintf(
                                    'SlimPing: prime flush (timeout, %d bytes) for %s',
                                    length($data), $client->id
                                )
                            );
                            return \$data;
                        }
                        $log->debug(
                            "SlimPing: prime timeout with no data for " . $client->id );
                    }
                }
            }

            # Still priming: return undef so LMS retries after 0.4 s.
            # Once prime state is cleared (EOS / STREAMOUT / timeout), fall
            # through to Phase 3 so the normal terminal handling takes over.
            return undef if exists $_prime_buffer{ $client->id };
        }

        # --- Phase 3: normal EOS handling ----------------------------------

        if ( defined($chunk) && length($$chunk) == 0 ) {
            $log->debug("SlimPing: StreamingClient EOS (empty ref)");
            $client->controller()->playerEndOfStream($client);
            $client->controller()->playerReadyToStream($client);
            $client->controller()->playerStopped($client);

            return \q{};
        }

        if ( !defined($chunk) ) {
            my $ss = $client->controller()->{'streamingState'};
            if ( defined($ss) && $ss == 2 ) {
                $log->debug("SlimPing: StreamingClient EOS (STREAMOUT with undef)");
                $client->controller()->playerEndOfStream($client);
                $client->controller()->playerReadyToStream($client);
                $client->controller()->playerStopped($client);
                return \q{};
            }
        }

        return $chunk;
    }

}

1;
