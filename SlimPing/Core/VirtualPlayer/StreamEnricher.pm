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
# Core/VirtualPlayer/StreamEnricher.pm - ICY metadata enrichment and CUE stop timers
#
# Extracted from VirtualPlayer.pm.  Contains three timer-driven concerns:
#
# 1. ICY metadata enrichment -- recurring timer that fetches stream title
#    and artwork from protocol handlers for remote (internet radio) streams.
#
# 2. Local metadata injection -- one-shot timer that injects caller-provided
#    metadata (title, artist, album) onto local file tracks shortly after
#    playback starts.
#
# 3. CUE stop timer -- periodic timer that stops playback when a CUE
#    segment's duration elapses.  Separate from the ICY timer because CUE
#    files are local multi-track containers.
#

package Plugins::SlimPing::Core::VirtualPlayer::StreamEnricher;

use strict;
use warnings;

require Plugins::SlimPing::Core::Container;
require Plugins::SlimPing::Core::Logging;
require Plugins::SlimPing::Core::VirtualPlayer::ArtworkBridge;

use Slim::Player::Client;
use Slim::Utils::Timers;

my $log = Plugins::SlimPing::Core::Logging->getLogger();

# Maximum enrichment retries before abandoning a zombie stream.  Each retry
# fires at 3 s; 20 retries = 60 s of patience before we give up on a remote
# stream that accepted the TCP connection but never delivered data.
use constant ENRICH_MAX_RETRIES => 20;

# Enrichment state for recurring ICY metadata / artwork timers.  Keyed by
# virtual player client ID so the timer callback (a named sub, not a closure)
# can retrieve the context it needs.
my %_enrich_state;

# One-shot metadata-inject state for local files.  Keyed by client ID so the
# named timer callback can retrieve sq_id, meta, and artwork_cache_key.
my %_local_meta_state;

# CUE / split-track stop timer state.  Keyed by client ID.  Set by
# _scheduleCueStop when a stream needs duration-limited playback (local
# files with audio_offset > 0).  Consumed by _cueStopTick which fires
# periodically to stop the player once the segment duration elapses.
# Separate from the ICY enrichment timer -- CUE stop is purely a
# local-file concern and must not depend on remote/ICY conditions.
my %_cue_stop_state;                             # client_id => { sq_id, cue_duration_s, cue_started_at }

# Cross-module accessor: called by PlayerCleanup to drop CUE stop state
# for a player that disconnected before its segment elapsed.
sub _deleteCueStopState {
    my ($player_id) = @_;
    delete $_cue_stop_state{ $player_id };
}

sub _scheduleEnrichment {
    my ( $client, $args ) = @_;
    return unless $args->{enable_icy} && $args->{is_remote} && $args->{artwork_cache_key};

    require Slim::Music::Info;

    my $meta       = $args->{meta};
    my $source_url = $args->{source_url};
    if ( $meta && (%$meta) ) {
        my $title = Slim::Music::Info::getCurrentTitle( $client, $source_url, 0, $meta );
        Slim::Music::Info::setCurrentTitle( $source_url, $title, undef )
          if $title;
    }

    $_enrich_state{ $client->id } = {
        sq_id             => $args->{sq_id},
        source_url        => $source_url,
        artwork_cache_key => $args->{artwork_cache_key},
        last_title        => undef,
        last_cover_url    => undef,
        retries           => 0,
    };
    $log->debug( "SlimPing: enrichment timer scheduled for $args->{sq_id} (in 6s)" );
    Slim::Utils::Timers::setTimer( $client, time() + 6.0, \&_enrichTick );
}

# Schedule a periodic timer to stop the virtual player once the CUE
# segment duration has elapsed.  Separate from the ICY enrichment timer
# -- CUE files are local multi-track containers and must not depend on
# remote-stream or ICY-metadata conditions.
sub _scheduleCueStop {
    my ( $client, $args ) = @_;
    my $cue_dur = $args->{cue_duration_s} // 0;
    return unless $cue_dur > 0;

    $_cue_stop_state{ $client->id } = {
        sq_id          => $args->{sq_id},
        cue_duration_s => $cue_dur,
        cue_started_at => time(),
    };
    Slim::Utils::Timers::setTimer( $client, time() + 2.0, \&_cueStopTick );
}

sub _cueStopTick {
    my $client = shift;
    my $state  = $_cue_stop_state{ $client->id };
    return unless $state;

    # Client removed from the player list -- clean up.
    unless ( grep { $_ eq $client } Slim::Player::Client::clients() ) {
        delete $_cue_stop_state{ $client->id };
        return;
    }
    if ( !$client->connected() ) {
        delete $_cue_stop_state{ $client->id };
        Slim::Player::Client::forgetClient($client);
        return;
    }

    my $elapsed = time() - $state->{cue_started_at};
    if ( $elapsed >= $state->{cue_duration_s} ) {
        $log->debug(
            sprintf(
                'SlimPing: CUE segment ended for %s (elapsed=%ds dur=%ds)',
                $state->{sq_id}, $elapsed, $state->{cue_duration_s}
            )
        );
        delete $_cue_stop_state{ $client->id };
        $client->execute( ['stop'] );
        return;
    }

    # Check again in 2 seconds.
    Slim::Utils::Timers::setTimer( $client, time() + 2.0, \&_cueStopTick );
}

sub _scheduleLocalMetaInjection {
    my ( $client, $args ) = @_;
    return if $args->{is_remote};
    return unless $args->{artwork_cache_key} || ( $args->{meta} && %{ $args->{meta} } );

    $_local_meta_state{ $client->id } = {
        sq_id             => $args->{sq_id},
        meta              => $args->{meta},
        artwork_cache_key => $args->{artwork_cache_key},
    };

    Slim::Utils::Timers::setTimer( $client, time() + 0.2, \&_localMetadataTimer );
}

sub _enrichShouldRetry {
    my ( $state, $error_label ) = @_;
    if ( ++$state->{retries} > ENRICH_MAX_RETRIES ) {
        $log->warn("SlimPing: enrichment abandoned for $state->{sq_id} after $state->{retries} retries");
        delete $_enrich_state{ $state->{client_id} };
        return 0;
    }
    $log->debug("SlimPing: enrichment $error_label for $state->{sq_id} (attempt $state->{retries})");
    Slim::Utils::Timers::setTimer( $state->{_client}, time() + 3.0, \&_enrichTick );
    return 1;
}

sub _enrichTick {
    my $client = shift;
    $log->debug( "SlimPing: enrichment tick started for " . $client->id );
    my $state = $_enrich_state{ $client->id };
    unless ($state) {
        $log->warn( "SlimPing: enrichment state missing for " . $client->id );
        return;
    }
    $state->{_client}   = $client;
    $state->{client_id} = $client->id;

    # Stop once the client is gone (Slim::Player::Client forgetClient
    # removes the player from the clients list).
    unless ( grep { $_ eq $client } Slim::Player::Client::clients() ) {
        $log->debug("SlimPing: enrichment stopped for $state->{sq_id} -- client removed");
        delete $_enrich_state{ $client->id };
        return;
    }

    # LMS clears streamingsocket on disconnect (closeStreamingSocket) but
    # does NOT call forgetClient for HTTP players -- they stay in clients().
    # Clean up the zombie player so it doesn't count against share/radio
    # listener caps.
    if ( !$client->connected() ) {
        $log->debug("SlimPing: enrichment stopped for $state->{sq_id} -- client disconnected, forgetting player");
        delete $_enrich_state{ $client->id };
        Slim::Player::Client::forgetClient($client);
        return;
    }

    my $song = eval { $client->playingSong() };
    if ($@) {
        $log->warn("SlimPing: playingSong error for $state->{sq_id}: $@");
        return if _enrichShouldRetry( $state, 'playingSong error' );
        return;
    }
    if ( !$song ) {
        return if _enrichShouldRetry( $state, 'waiting for song' );
        return;
    }

    if ( $state->{retries} ) {
        $log->debug("SlimPing: enrichment song available for $state->{sq_id} after $state->{retries} attempt(s)");
        $state->{retries} = 0;
    }

    # Unified metadata relay: use the same resolution chain as LMS's native
    # UI (Slim::Player::Player.pm:590-631).  Get the schema track from the
    # playlist, then ask the protocol handler for ALL enriched metadata in
    # one call.  This covers every source uniformly -- HTTP, IceCast, BBC
    # Sounds, Radio Now Playing, custom plugins, etc.
    require Slim::Player::Playlist;
    my $track = eval { Slim::Player::Playlist::track($client) };
    if ($@) {
        $log->warn("SlimPing: Playlist::track error for $state->{sq_id}: $@");
        return if _enrichShouldRetry( $state, 'Playlist::track error' );
        return;
    }
    unless ($track) {
        return if _enrichShouldRetry( $state, 'waiting for track' );
        return;
    }

    my $track_url = eval { $track->url };
    if ($@) {
        $log->warn("SlimPing: track url error for $state->{sq_id}: $@");
        return if _enrichShouldRetry( $state, 'track url error' );
        return;
    }
    my $title;
    my $cover_url;

    my $is_remote = eval { $track->isRemoteURL };
    if ($@) {
        $log->warn("SlimPing: isRemoteURL error for $state->{sq_id}: $@");
        $is_remote = 0;
    }
    if ( $track_url && $is_remote ) {

        # Remote: get everything from the protocol handler.  This is the
        # single unified source -- getMetadataFor returns {cover, icon,
        # title, artist, duration, bitrate, ...} filled in by whatever
        # protocol handler or plugin owns the stream.
        my $handler = Slim::Player::ProtocolHandlers->handlerForURL($track_url);
        my $remote_meta;
        if ( $handler && $handler->can('getMetadataFor') ) {
            $remote_meta = eval { $handler->getMetadataFor( $client, $track_url ) };
            if ($@) {
                $log->warn("SlimPing: getMetadataFor error for $state->{sq_id}: $@");
            }
        }

        if ( $remote_meta && ref $remote_meta eq 'HASH' ) {

            # ICY StreamTitle: construct Artist - Title when both fields are
            # present in the protocol handler metadata.  When only one field is
            # populated (station-level data between tracks, e.g. {artist=>"BBC
            # Radio 6 Music", title=>""}), fall through to LMS's getCurrentTitle
            # which handles incomplete metadata gracefully and avoids producing
            # "Station Name - " with a trailing dash.
            if ( $remote_meta->{artist} && $remote_meta->{title} ) {
                $title = $remote_meta->{artist} . ' - ' . $remote_meta->{title};
            } elsif ( $remote_meta->{title} ) {
                $title = $remote_meta->{title};
            } else {
                require Slim::Music::Info;
                $title = Slim::Music::Info::getCurrentTitle(
                    $client, $track_url, 0, $remote_meta );
            }

            # Artwork: protocol-handler-resolved image URL.
            $cover_url = $remote_meta->{cover} || $remote_meta->{icon};
        }

        # Fallback: handler didn't return metadata -- use LMS's standard
        # title lookup (still respects enrichment plugins).
        require Slim::Music::Info;
        $title //= Slim::Music::Info::getCurrentTitle( $client, $track_url );
    }
    else {
        # Local: standard title from track URL.
        require Slim::Music::Info;
        $title = Slim::Music::Info::getCurrentTitle( $client, $track_url )
          if $track_url;
    }

    # Pin a canonical metadata URL so the synchronous initial write (keyed on
    # $source_url) and every recurring tick write use the same ICY cache key.
    # LMS may rewrite URLs through playlist indirection, causing $track_url
    # to diverge from the source URL passed by the caller.
    my $meta_url = $state->{canonical_url} ||= $state->{source_url};

    # ICY StreamTitle: update when the resolved title changes.
    if ( $title
        && ( !defined $state->{last_title} || $title ne $state->{last_title} ) )
    {
        require Slim::Music::Info;
        eval { Slim::Music::Info::setCurrentTitle( $meta_url, $title, undef ); };
        if ($@) {
            $log->warn("SlimPing: ICY title set error for $state->{sq_id}: $@");
        }
        $state->{last_title} = $title;
        $log->debug("SlimPing: ICY title updated for $state->{sq_id}: $title");
    }

    # Sideband artwork: fetch the protocol-handler-resolved image URL
    # and cache the bytes.  For local tracks, read coverArt() from the
    # schema track (database-backed -- no URL fetch needed).
    if ( $state->{artwork_cache_key} ) {

        if ($cover_url) {

            # Remote: handler resolved an image URL -- fetch it
            # asynchronously via LMS's non-blocking HTTP client so a
            # slow artwork server never stalls the event loop.
            if ( !defined $state->{last_cover_url}
                || $cover_url ne $state->{last_cover_url} )
            {
                # Mark URL as seen immediately so concurrent ticks
                # do not launch duplicate fetches while this one
                # is in-flight.
                $state->{last_cover_url} = $cover_url;

                my $cache_key = $state->{artwork_cache_key};
                my $sq_id     = $state->{sq_id};
                require Slim::Networking::SimpleAsyncHTTP;
                Slim::Networking::SimpleAsyncHTTP->new(
                    sub {
                        my $http     = shift;
                        my $art_data = $http->content();
                        if ( length($art_data) ) {
                            Plugins::SlimPing::Core::VirtualPlayer::ArtworkBridge::_setArtworkCache(
                                $cache_key, $art_data, 'image/jpeg' );
                            $log->debug(
                                "SlimPing: artwork fetched for $sq_id ("
                                  . length($art_data)
                                  . " bytes)" );
                        }
                    },
                    sub {
                        $log->warn(
                            "SlimPing: artwork fetch failed for $sq_id");
                        # Let the next tick retry.
                        $state->{last_cover_url} = undef;
                    },
                    { timeout => 10 },
                )->get($cover_url);
            }
            else {
                $log->debug(
                    "SlimPing: artwork URL unchanged for $state->{sq_id}, skipping fetch");
            }
        }
        else {
            # Local / no handler cover: use database coverArt.
            my ( $art_data, $art_type );
            eval { ( $art_data, $art_type ) = $track->coverArt() };
            if ($@) {
                $log->warn("SlimPing: artwork coverArt error for $state->{sq_id}: $@");
            }
            if ($art_data) {
                Plugins::SlimPing::Core::VirtualPlayer::ArtworkBridge::_setArtworkCache(
                    $state->{artwork_cache_key}, $art_data, $art_type || 'image/jpeg' );
                $log->debug(
                    "SlimPing: artwork cached for $state->{artwork_cache_key} ("
                      . length($art_data)
                      . " bytes, $art_type)" );
            }
            else {
                $log->debug("SlimPing: no artwork data from song for $state->{sq_id}");
            }
        }
    }

    $log->debug("SlimPing: enrichment tick complete for $state->{sq_id}, rescheduling");
    Slim::Utils::Timers::setTimer( $client, time() + 5.0, \&_enrichTick );
}

sub _localMetadataTimer {
    my $client = shift;
    my $state  = delete $_local_meta_state{ $client->id };
    return unless $state;

    my $sq_id             = $state->{sq_id};
    my $meta              = $state->{meta};
    my $artwork_cache_key = $state->{artwork_cache_key};

    my $song = eval { $client->playingSong() };
    if ($@) {
        $log->warn("SlimPing: playingSong error in metadata timer for $sq_id: $@");
        return;
    }
    return unless $song;

    if ( $meta && (%$meta) ) {
        my $track = eval { $song->track() };
        if ($@) {
            $log->warn("SlimPing: track() error in metadata timer for $sq_id: $@");
        }
        if ($track) {
            eval {
                $track->title( $meta->{title} )
                  if $meta->{title};
                $track->artist( $meta->{artist} )
                  if $meta->{artist};
            };
            if ($@) {
                $log->warn("SlimPing: metadata inject error for $sq_id: $@");
            }
            $log->debug("SlimPing: metadata injected for $sq_id")
              if $meta->{title};
        }
    }

    if ($artwork_cache_key) {
        my $track = eval { $song->track() };
        my ( $art_data, $art_type ) = $track ? eval { $track->coverArt() } : ();
        if ($@) {
            $log->warn("SlimPing: artwork coverArt error for $artwork_cache_key (non-remote): $@");
        }
        elsif ($art_data) {
            Plugins::SlimPing::Core::VirtualPlayer::ArtworkBridge::_setArtworkCache(
                $artwork_cache_key, $art_data, $art_type || 'image/jpeg' );
            $log->debug("SlimPing: artwork cached for $artwork_cache_key");
        }
    }
}

1;
