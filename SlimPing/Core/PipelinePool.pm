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
# Core/PipelinePool.pm - Shared pipeline multiplexer for radio and tracks
#
# Pools a single virtual player across concurrent listeners of the same
# underlying stream URL, avoiding duplicate LAME transcodes and upstream
# fetches.  Supports two pool types:
#   radio — live streams, ICY metadata injection, 30 s grace
#   track — finite remote tracks, raw MP3 passthrough, EOS-aware lifecycle
#
# The first listener (primary) gets the full LMS pipeline path; all subsequent
# listeners receive the same raw MP3 chunks via a fan-out write loop.
#

package Plugins::SlimPing::Core::PipelinePool;

use strict;
use warnings;

use Errno qw(EAGAIN EWOULDBLOCK);

use Plugins::SlimPing::Core::Logging;

my $log = Plugins::SlimPing::Core::Logging->getLogger();

use constant GRACE_PERIOD_RADIO  => 30;     # seconds before tearing down an idle radio pool
use constant GRACE_PERIOD_TRACK  => 10;     # seconds before tearing down an idle track pool
use constant BUFFER_SECS         => 10;     # seconds of audio in the ring buffer (both types)
use constant METADATAINTERVAL    => 32768;  # bytes between ICY metadata blocks
use constant SWEEP_MIN_INTERVAL  => 10;     # minimum seconds between stale-listener sweeps

# Pool registry: "type:source_url:br_kbps[:time_offset]" => PoolEntry
my %_pools;

# Maps StreamingClient player ID => pool key (for pushChunk look-up)
my %_player_pool;

# Maps primary httpClient stringified => pool key
my %_primary_pool;

# Maps listener httpClient stringified => listener hashref
my %_listener_map;

# Maps listener httpClient stringified => pool key
my %_listener_pool;

# Timestamp of last sweepStaleListeners run — rate-limits the sweep so it
# does not scan all pool listeners on every LMS HTTP close.
my $_last_sweep_time = 0;


# Called by radioStream when a pool already exists for this URL+bitrate.
# The caller has already built the HTTP response headers (serialised via
# _stringifyHeaders).  Returns 1 when the listener is attached, 0 when the
# pool is stale and the caller should create a new primary.
sub registerListener {
    my $class = shift;
    my %args  = @_;
    my $pool_type   = $args{pool_type}   || 'radio';
    my $source_url  = $args{source_url}  or die 'registerListener: source_url required';
    my $br_kbps     = $args{br_kbps}     or die 'registerListener: br_kbps required';
    my $httpClient  = $args{httpClient}  or die 'registerListener: httpClient required';
    my $headers     = $args{headers}     or die 'registerListener: headers required';
    my $time_offset = $args{time_offset};
    my $enable_icy  = $args{enable_icy}  // 0;

    my $key = _poolKey( $pool_type, $source_url, $br_kbps, $time_offset );
    my $entry = $_pools{$key} or return 0;

    # If the primary player is gone, the pool is stale
    if ( $entry->{player} && !_playerAlive( $entry->{player} ) ) {
        _teardownPool($entry);
        delete $_pools{$key};
        return 0;
    }

    # Track pool that reached EOS — no new listeners, the track is finished
    if ( $entry->{pool_type} && $entry->{pool_type} eq 'track' && $entry->{eos} ) {
        return 0;
    }

    # Cancel grace timer — a listener arrived before teardown
    if ( $entry->{grace_timer} ) {
        Slim::Utils::Timers::killTimers( undef, $entry->{grace_timer} );
        $entry->{grace_timer} = undef;
    }

    # Write response headers and register the fan-out write watcher.
    # Mirror _startPlayback: kill the keep-alive timer so LMS doesn't
    # close this streaming socket after KEEPALIVETIMEOUT (75 s).
    require Slim::Web::HTTP;
    require Slim::Utils::Timers;
    $httpClient->syswrite($headers);
    delete $Slim::Web::HTTP::keepAlives{$httpClient};
    Slim::Utils::Timers::killTimers( $httpClient, \&Slim::Web::HTTP::closeHTTPSocket );

    # Start near the end of the ring buffer so new listeners get at most
    # one ICY metadata interval of catch-up data instead of the full 10 s
    # buffer.  Prevents TCP-buffer overwhelm from blasting the entire
    # history in one burst.
    my $start_head = $entry->{head};
    if ( @{ $entry->{chunks} } > 0 ) {
        my $bytes = 0;
        for ( my $i = $#{ $entry->{chunks} }; $i >= $entry->{head}; $i-- ) {
            $bytes += length( $entry->{chunks}[$i] );
            if ( $bytes >= METADATAINTERVAL ) {
                $start_head = $i;
                last;
            }
        }
    }

    my $listener = {
        httpClient => $httpClient,
        read_head  => $start_head,
        icy_bytes  => 0,
        enable_icy => $enable_icy,
    };
    push @{ $entry->{listeners} }, $listener;
    $_listener_map{"$httpClient"} = $listener;
    $_listener_pool{"$httpClient"} = $key;

    require Slim::Networking::Select;
    Slim::Networking::Select::addWrite( $httpClient, \&_fanOutTick, 1 );

    $log->info( sprintf(
        'SlimPing: pooled listener attached to %s (%d kbps, %d total listeners, icy=%d)',
        $key, $br_kbps, scalar @{ $entry->{listeners} }, $enable_icy
    ) );
    return 1;
}

# Called by streamViaPipeline after constructing a virtual player for a
# radio stream.  Registers this player as the primary (chunk producer) for
# the pool so subsequent requests attach as listeners.
sub registerPrimary {
    my $class = shift;
    my %args  = @_;
    my $pool_type   = $args{pool_type}   || 'radio';
    my $source_url  = $args{source_url}  or die 'registerPrimary: source_url required';
    my $br_kbps     = $args{br_kbps}     or die 'registerPrimary: br_kbps required';
    my $player      = $args{player}      or die 'registerPrimary: player required';
    my $httpClient  = $args{httpClient}  or die 'registerPrimary: httpClient required';
    my $time_offset = $args{time_offset};

    my $key       = _poolKey( $pool_type, $source_url, $br_kbps, $time_offset );
    my $max_bytes = int( ( $br_kbps * 1000 / 8 ) * BUFFER_SECS );

    # Defend against double-registration.  If a pool already exists with
    # an alive primary, this is a near-end probe or duplicate request
    # that escaped the pool check — don't overwrite the running pipeline.
    if ( my $existing = $_pools{$key} ) {
        if ( $existing->{player} && _playerAlive( $existing->{player} ) ) {
            $log->debug("SlimPing: pool $key already has alive primary, skipping registration");
            return;
        }
        # Old pool with dead primary — tear down before replacing
        _teardownPool($existing);
    }

    $_pools{$key} = {
        pool_type           => $pool_type,
        source_url          => $source_url,
        br_kbps             => $br_kbps,
        player              => $player,
        primary_httpClient  => $httpClient,
        chunks              => [],
        head                => 0,
        total_bytes         => 0,
        max_bytes           => $max_bytes,
        listeners           => [],
        eos                 => 0,
        grace_timer         => undef,
        created_at          => time(),
    };
    $_player_pool{ $player->id }   = $key;
    $_primary_pool{"$httpClient"} = $key;

    $log->info( sprintf(
        'SlimPing: %s pool primary registered for %s (%d kbps, %d B buffer)',
        $pool_type, $key, $br_kbps, $max_bytes
    ) );
}

# Called by StreamingClient::nextChunk when this player is a pooled primary.
# Pushes a copy of the raw MP3 chunk into the shared ring buffer so all
# fan-out listeners receive it.  For track pools, detects the end-of-stream
# sentinel (\q{}) and sets the eos flag on the pool entry.
sub pushChunk {
    my ( $player_id, $chunk_ref ) = @_;
    my $key = $_player_pool{$player_id} or return;
    my $entry = $_pools{$key} or return;

    my $data = $$chunk_ref;

    # EOS sentinel: defined, zero-length — the primary's track ended.
    if ( defined $data && length($data) == 0 ) {
        if ( $entry->{pool_type} && $entry->{pool_type} eq 'track' ) {
            $entry->{eos} = 1;
            $log->debug("SlimPing: track pool EOS signalled for $key");
        }
        return;
    }

    return unless length $data;

    push @{ $entry->{chunks} }, $data;
    $entry->{total_bytes} += length($data);

    # Trim buffer to the byte cap
    while (    $entry->{total_bytes} > $entry->{max_bytes}
            && $entry->{head} < @{ $entry->{chunks} } )
    {
        $entry->{total_bytes} -= length( $entry->{chunks}[ $entry->{head} ] );
        $entry->{head}++;
    }
}

# Called by _cleanupDisconnectedPlayers with a player ID.  Looks up the
# pool key from the player-to-pool map and handles lifecycle:
#   radio — 30 s grace timer if no listeners remain
#   track — 10 s grace if no listeners AND no EOS; immediate teardown if EOS
sub notifyPlayerGone {
    my $class     = shift;
    my $player_id = shift;
    my $key = $_player_pool{$player_id} or return 0;
    delete $_player_pool{$player_id};

    my $entry = $_pools{$key} or return 0;
    if ( $entry->{primary_httpClient} ) {
        delete $_primary_pool{ "$entry->{primary_httpClient}" };
    }
    $entry->{primary_httpClient} = undef;

    # Listeners still attached — keep the pipeline alive so the ring
    # buffer continues receiving chunks.  Start a recurring timer that
    # calls nextChunk and feeds the pool independently of the now-closed
    # primary socket.
    if ( @{ $entry->{listeners} } > 0 ) {
        $_player_pool{$player_id} = $key;
        $entry->{keep_alive_player} = $entry->{player};
        require Slim::Utils::Timers;
        Slim::Utils::Timers::setTimer(
            undef, time() + 0.1,
            sub { _keepAliveTick($player_id) },
        );
        $log->info("SlimPing: $key primary gone but listeners remain — keep-alive started");
        return 1;
    }

    # Track pool that reached EOS — tear down immediately, no grace
    if (    $entry->{pool_type} && $entry->{pool_type} eq 'track'
         && $entry->{eos} )
    {
        $log->info("SlimPing: $key track pool finished — tearing down");
        _teardownPool($entry);
        delete $_pools{$key};
        return 0;
    }
    _startGrace( $entry, $key );
    return 0;
}

# Recurring timer callback that keeps a pooled pipeline alive after the
# primary socket closes.  Calls nextChunk on the orphaned player and
# pushes chunks into the ring buffer so fan-out listeners continue
# receiving audio.  Stops when all listeners disconnect or the track
# reaches EOS.
sub _keepAliveTick {
    my ($player_id) = @_;
    my $key = $_player_pool{$player_id} or return;
    my $entry = $_pools{$key} or return;

    # Stop if all listeners have disconnected
    if ( @{ $entry->{listeners} } == 0 ) {
        delete $_player_pool{$player_id};
        _finaliseCacheEntry($player_id);
        _startGrace( $entry, $key );
        return;
    }

    # Stop if the pool has been torn down (EOS reached)
    return unless $_pools{$key};

    my $player = $entry->{player};
    return unless $player && _playerAlive($player);

    my $chunk = eval { Slim::Player::Source::nextChunk($player) };
    if ($@) {
        $log->warn("SlimPing: keep-alive nextChunk error for $key: $@");
        return;
    }

    if ( defined($chunk) && length($$chunk) == 0 ) {
        pushChunk( $player->id, $chunk );
        _finaliseCacheEntry( $player_id, 1 );
        delete $_player_pool{$player_id};

        # For radio pools the virtual player cannot resume after its HTTP
        # socket closes — nextChunk returns EOS immediately once the player
        # stops.  Tear the pool down now and close any lingering listener
        # sockets so clients reconnect and pick up a fresh primary instead
        # of hanging in a zombie pool that will never produce audio.
        if ( $entry->{pool_type} && $entry->{pool_type} eq 'radio' ) {
            my @listeners   = @{ $entry->{listeners} || [] };
            my $n_listeners = scalar @listeners;
            _teardownPool($entry);
            delete $_pools{$key};
            require Slim::Web::HTTP;
            for my $l (@listeners) {
                Slim::Web::HTTP::closeHTTPSocket( $l->{httpClient} )
                    if $l->{httpClient} && $l->{httpClient}->connected();
            }
            $log->info(
                "SlimPing: keep-alive EOS for $key — radio pool torn down, $n_listeners listener(s) closed"
            );
        }
        else {
            $log->debug("SlimPing: keep-alive EOS for $key");
        }
        return;
    }

    if ( defined($chunk) && length($$chunk) ) {
        pushChunk( $player->id, $chunk );
        _ingestCacheChunk( $player_id, $chunk );
    }

    # Reschedule — pump at ~10 Hz to match normal nextChunk cadence
    require Slim::Utils::Timers;
    Slim::Utils::Timers::setTimer(
        undef, time() + 0.1,
        sub { _keepAliveTick($player_id) },
    );
}


sub _poolKey {
    my ( $pool_type, $source_url, $br_kbps, $time_offset ) = @_;
    $pool_type ||= 'radio';
    my $key = "$pool_type:$source_url:$br_kbps";
    $key .= ":$time_offset" if defined $time_offset;
    return $key;
}

# Returns true when a player is still in LMS's active clients list.
sub _playerAlive {
    my ($player) = @_;
    return 0 unless $player;
    return 0 + grep { $_ eq $player } Slim::Player::Client::clients();
}

# Start a grace timer with a duration appropriate to the pool type.
# Radio: 30 s (reconnect to a live station).  Track: 10 s (probe-to-playback gap).
sub _startGrace {
    my ( $entry, $key ) = @_;

    my $period = ( $entry->{pool_type} && $entry->{pool_type} eq 'track' )
      ? GRACE_PERIOD_TRACK : GRACE_PERIOD_RADIO;

    $entry->{grace_timer} = Slim::Utils::Timers::setTimer(
        undef,
        time() + $period,
        sub { _graceTick($key) },
    );

    $log->debug("SlimPing: $key grace timer started (${period}s)");
}

# Named timer callback — LMS's PerlRunTime.pm crashes on anonymous
# coderefs when INFOLOG is enabled.
sub _graceTick {
    my ($key) = @_;
    my $entry = $_pools{$key} or return;

    # A listener may have arrived between timer fire and callback
    if ( @{ $entry->{listeners} } > 0 ) {
        $entry->{grace_timer} = undef;
        return;
    }

    $log->info("SlimPing: $key grace timer expired — tearing down pool");
    _teardownPool($entry);
    delete $_pools{$key};
}


# Named sub registered via Slim::Networking::Select::addWrite for each
# pooled listener.  Drains available chunks from the shared queue, injecting
# ICY metadata blocks at 32768-byte intervals.
sub _fanOutTick {
    my ($httpClient) = @_;
    my $listener = $_listener_map{"$httpClient"};
    unless ($listener) {
        # _removeListener should have deregistered this watcher, but defend
        # against any path that cleared the map without calling removeWrite.
        require Slim::Networking::Select;
        Slim::Networking::Select::removeWrite($httpClient);
        return;
    }
    my $key = $_listener_pool{"$httpClient"}
      or return _cleanupListener($httpClient);
    my $entry = $_pools{$key} or do {
        _cleanupListener($httpClient);
        return;
    };

    # Socket gone — remove listener
    unless ( $httpClient->connected() ) {
        _removeListener( $entry, $httpClient, $key );
        return;
    }

    # Resume a partial write from the previous tick if one exists.
    my $tick_bytes = 0;
    if ( $listener->{pending_track} ) {
        my $result = _syswriteAll(
            $httpClient, \$listener->{pending_track},
            $listener->{pending_track_off}, $listener,
            'pending_track', 'pending_track_off'
        );
        if ( $result == 0 ) {
            _removeListener( $entry, $httpClient, $key );
            return;
        }
        if ( $result < 0 ) {
            return;  # still backpressured, retry next tick
        }
        # Chunk fully written — advance read_head and clear pending state.
        my $chunk_len = length( $listener->{pending_track} );
        delete $listener->{pending_track};
        delete $listener->{pending_track_off};
        $listener->{read_head}++;
        $tick_bytes += $chunk_len;
    }

    if ( $listener->{pending_radio} ) {
        my $result = _syswriteAll(
            $httpClient, \$listener->{pending_radio},
            $listener->{pending_radio_off}, $listener,
            'pending_radio', 'pending_radio_off'
        );
        if ( $result == 0 ) {
            _removeListener( $entry, $httpClient, $key );
            return;
        }
        if ( $result < 0 ) {
            return;  # still backpressured, retry next tick
        }
        my $chunk_len = length( $listener->{pending_radio} );
        delete $listener->{pending_radio};
        delete $listener->{pending_radio_off};
        $listener->{read_head}++;
        $tick_bytes += $chunk_len;
    }

    return if $tick_bytes >= METADATAINTERVAL;

    # Write available chunks, limited to one ICY metadata interval per tick
    # so the client can drain its TCP buffer between event-loop iterations.
    # _writeChunk returns: 1 = success, -1 = backpressure (stop tick), 0 = error.
    my $chunks     = $entry->{chunks};
    $tick_bytes = 0;
    while ( $listener->{read_head} < @$chunks ) {
        my $data   = $chunks->[ $listener->{read_head} ];
        my $result = _writeChunk( $httpClient, $listener, $entry, $data );
        if ( $result == 0 ) {
            _removeListener( $entry, $httpClient, $key );
            return;
        }
        last if $result < 0;  # backpressure (EAGAIN) -- stop tick, retry next time
        $listener->{read_head}++;
        $tick_bytes += length($data);
        last if $tick_bytes >= METADATAINTERVAL;
    }

    # Track pool EOS: all chunks drained, primary has signalled end-of-stream.
    # Close the listener socket cleanly — the track is finished.
    if (    $entry->{pool_type} && $entry->{pool_type} eq 'track'
         && $entry->{eos}
         && $listener->{read_head} >= @$chunks )
    {
        $log->debug("SlimPing: track pool EOS — closing listener socket");
        _closeAndRemoveListener( $entry, $httpClient, $key );
        return;
    }
}

# Write a single raw MP3 chunk to a listener socket, splitting at
# METADATAINTERVAL boundaries to inject ICY StreamTitle blocks.
#
# Return codes:
#   1  => all data written successfully
#  -1  => backpressure (EAGAIN/EWOULDBLOCK) -- caller stops the tick, keeps listener
#   0  => hard error (EPIPE, ECONNRESET, etc.) -- caller must remove the listener
sub _writeChunk {
    my ( $httpClient, $listener, $entry, $data ) = @_;

    return 1 unless length $data;

    # Track pools: raw MP3 passthrough, no ICY framing
    if ( $entry->{pool_type} && $entry->{pool_type} eq 'track' ) {
        return _syswriteAll( $httpClient, \$data, 0, $listener, 'pending_track', 'pending_track_off' );
    }

    # Radio pools: passthrough without ICY for listeners that didn't
    # request it.  Injecting ICY blocks into a stream for a client that
    # doesn't expect them corrupts the MP3 decode.
    unless ( $listener->{enable_icy} ) {
        return _syswriteAll( $httpClient, \$data, 0, $listener, 'pending_radio', 'pending_radio_off' );
    }

    my $remaining = length($data);
    my $offset    = 0;

    while ( $remaining > 0 ) {
        my $until_meta = METADATAINTERVAL - $listener->{icy_bytes};

        if ( $until_meta <= 0 ) {
            # Inject ICY metadata block before writing more audio
            my $inject = _injectICYBlock( $httpClient, $listener, $entry );
            return $inject if $inject <= 0;
            $listener->{icy_bytes} = 0;
            $until_meta = METADATAINTERVAL;
        }

        my $write_len = $remaining < $until_meta ? $remaining : $until_meta;

        my $written = $httpClient->syswrite( substr( $data, $offset, $write_len ) );
        my $status  = _syswriteStatus($written);
        return $status if $status <= 0;

        # Advance by actual bytes written so the ICY interval counter stays
        # accurate even on partial writes.
        $offset                += $written;
        $remaining             -= $written;
        $listener->{icy_bytes} += $written;
    }

    return 1;
}

# Interpret a syswrite return value into a _writeChunk status code.
# Uses the module-level Errno imports (EAGAIN, EWOULDBLOCK).
sub _syswriteStatus {
    my ($written) = @_;
    return 1 if defined $written && $written > 0;
    if ( !defined $written ) {
        return -1 if $! == EAGAIN || $! == EWOULDBLOCK;
        return 0;   # EPIPE, ECONNRESET, etc.
    }
    return -1;      # zero bytes written -- treat as transient backpressure
}

# Write all bytes from $data_ref starting at $offset, tracking partial
# progress in $listener->{$pending_key} and $listener->{$off_key} so the
# next _fanOutTick can resume.  This replaces _syswriteStatus for the
# non-ICY code paths.
#
# Returns: 1 (complete), -1 (backpressure, state saved for retry), 0 (hard error).
sub _syswriteAll {
    my ( $httpClient, $data_ref, $offset, $listener, $pending_key, $off_key ) = @_;

    my $to_write = substr( $$data_ref, $offset );
    return 1 unless length $to_write;

    my $written = $httpClient->syswrite($to_write);

    if ( !defined $written ) {
        return -1 if $! == EAGAIN || $! == EWOULDBLOCK;
        return 0;   # EPIPE, ECONNRESET, etc.
    }

    if ( $written == 0 ) {
        return -1 if $! == EAGAIN || $! == EWOULDBLOCK;
        return 0;   # hard error with zero bytes
    }

    if ( $written < length($to_write) ) {
        # Partial write — save pending state so the next tick resumes
        # from where we left off.
        $listener->{$pending_key} = $$data_ref;
        $listener->{$off_key}     = $offset + $written;
        return -1;
    }

    return 1;  # complete — all bytes written
}

# Build and write an ICY metadata block using the current title from LMS's
# shared ICY title cache (the same cache the primary's sendStreamingResponse
# reads from).
sub _injectICYBlock {
    my ( $httpClient, $listener, $entry ) = @_;

    require Slim::Music::Info;
    require Slim::Player::Source;
    require Slim::Player::Playlist;

    my $player = $entry->{player};
    return unless $player && _playerAlive($player);

    my $title;
    my $song_index = Slim::Player::Source::streamingSongIndex($player);
    my $url = Slim::Player::Playlist::url( $player, $song_index );
    if ($url) {
        $title = Slim::Music::Info::getCurrentTitle( $player, $url );
    }

    $title //= 'Unknown';
    $title =~ tr/'/ /;

    # Build metadata string in standard ICY format (mirrors LMS's
    # sendStreamingResponse at Slim/Web/HTTP.pm:2332)
    my $meta = "StreamTitle='" . $title . "';";
    my $len  = length($meta);

    # Pad to 16-byte boundary, prepend length byte (length / 16)
    $meta .= chr(0) x ( 16 - ( $len % 16 ) );
    my $block = chr( length($meta) / 16 ) . $meta;

    my $status = _syswriteStatus( $httpClient->syswrite($block) );
    $log->debug("SlimPing: fan-out ICY metadata injected: $meta") if $status > 0;
    return $status;
}


# Remove a single listener from a pool.  If no listeners remain and no
# primary is active, start the grace timer.
sub _removeListener {
    my ( $entry, $httpClient, $key ) = @_;

    # De-register the fan-out write watcher before touching pool state so
    # _fanOutTick cannot fire again for this socket after we remove the
    # listener.  Without this the watcher becomes a zombie that burns a
    # select slot and fires on every event-loop iteration.
    require Slim::Networking::Select;
    Slim::Networking::Select::removeWrite($httpClient);

    @{ $entry->{listeners} } = grep {
        $_->{httpClient} ne $httpClient
    } @{ $entry->{listeners} };

    my $listener = $_listener_map{"$httpClient"};
    delete $_listener_map{"$httpClient"};
    delete $_listener_pool{"$httpClient"};

    # Clean up any pending partial-write state so it does not leak.
    if ($listener) {
        delete $listener->{pending_track};
        delete $listener->{pending_track_off};
        delete $listener->{pending_radio};
        delete $listener->{pending_radio_off};
    }

    $log->info( sprintf(
        'SlimPing: listener detached from %s (%d remaining)',
        $key, scalar @{ $entry->{listeners} }
    ) );

    if (    @{ $entry->{listeners} } == 0
         && !$entry->{primary_httpClient}
         && !$entry->{grace_timer} )
    {
        _startGrace( $entry, $key );
    }
}

# Close a listener socket and remove it from the pool.  Used by EOS
# drain-and-close for track pools.  Bypasses the grace-timer check in
# _removeListener because the track has ended.
sub _closeAndRemoveListener {
    my ( $entry, $httpClient, $key ) = @_;

    @{ $entry->{listeners} } = grep {
        $_->{httpClient} ne $httpClient
    } @{ $entry->{listeners} };

    my $listener = $_listener_map{"$httpClient"};
    delete $_listener_map{"$httpClient"};
    delete $_listener_pool{"$httpClient"};

    # Clean up any pending partial-write state so it does not leak.
    if ($listener) {
        delete $listener->{pending_track};
        delete $listener->{pending_track_off};
        delete $listener->{pending_radio};
        delete $listener->{pending_radio_off};
    }

    require Slim::Web::HTTP;
    Slim::Web::HTTP::closeHTTPSocket($httpClient);

    $log->info( sprintf(
        'SlimPing: listener closed for %s (%d remaining)',
        $key, scalar @{ $entry->{listeners} }
    ) );

    # If no listeners remain and the primary is gone, tear down immediately
    if (    @{ $entry->{listeners} } == 0
         && !$entry->{primary_httpClient} )
    {
        _teardownPool($entry);
        delete $_pools{$key};
    }
}

# Clean up stale listener state when the pool entry no longer exists.
sub _cleanupListener {
    my ($httpClient) = @_;
    require Slim::Networking::Select;
    Slim::Networking::Select::removeWrite($httpClient);
    delete $_listener_map{"$httpClient"};
    delete $_listener_pool{"$httpClient"};
}

# Tear down a pool: kill timers, clear state maps, forget player.
sub _teardownPool {
    my ($entry) = @_;

    # Clear primary maps
    if ( $entry->{primary_httpClient} ) {
        delete $_primary_pool{ "$entry->{primary_httpClient}" };
    }
    if ( $entry->{player} ) {
        delete $_player_pool{ $entry->{player}->id };
    }

    # Clear listener maps
    for my $l ( @{ $entry->{listeners} } ) {
        delete $_listener_map{ "$l->{httpClient}" };
        delete $_listener_pool{ "$l->{httpClient}" };
    }

    # Kill grace timer
    if ( $entry->{grace_timer} ) {
        Slim::Utils::Timers::killTimers( undef, $entry->{grace_timer} );
    }

    # Stop and forget the player if still alive.
    # StreamingController exposes stop() not playerStop(), so call execute(['stop'])
    # which routes correctly.  Wrapped in eval so a controller error never prevents
    # forgetClient from running and leaking the player.
    if ( $entry->{player} && _playerAlive( $entry->{player} ) ) {
        eval { $entry->{player}->execute( ['stop'] ) };
        $log->warn("SlimPing: _teardownPool stop error: $@") if $@;
        Slim::Player::Client::forgetClient( $entry->{player} );
    }

    $log->info("SlimPing: pool torn down");
}


# Public method — callable from VirtualPlayer's cleanup handler.
# Sweeps disconnected listeners from every active pool so zombie pools
# with dead sockets eventually drain to zero and tear down.
#
# Rate-limited to at most once per SWEEP_MIN_INTERVAL seconds.  LMS fires
# @closeHandlers on every HTTP close (static files, API calls, etc.) so
# without this the sweep scans all pool listeners on every single request.
sub sweepStaleListeners {
    my $now = time();
    return 0 if ( $now - $_last_sweep_time ) < SWEEP_MIN_INTERVAL;
    $_last_sweep_time = $now;

    my $swept = 0;
    for my $entry ( values %_pools ) {
        next unless $entry->{listeners} && @{ $entry->{listeners} };
        my @alive;
        for my $l ( @{ $entry->{listeners} } ) {
            if ( $l->{httpClient} && $l->{httpClient}->connected() ) {
                push @alive, $l;
            } else {
                delete $_listener_map{ "$l->{httpClient}" };
                delete $_listener_pool{ "$l->{httpClient}" };
            }
        }
        my $removed = @{ $entry->{listeners} } - @alive;
        if ($removed) {
            $log->info("SlimPing: swept $removed stale listener(s) from pool");
            $entry->{listeners} = \@alive;
            $swept += $removed;
        }
    }
    return $swept;
}

# Total pooled listeners across all active pools.
sub pooledListenerCount {
    my $count = 0;
    for my $entry ( values %_pools ) {
        $count += scalar @{ $entry->{listeners} };
    }
    return $count;
}

# Total active pools.
sub activePoolCount {
    return scalar keys %_pools;
}

# Best-effort cache bridge.  _keepAliveTick bypasses StreamingClient
# (and therefore the cache ingest hook in nextChunk), so we feed the
# cache directly from the keep-alive pump.  Failures are silent — the
# cache path is an optimisation, not a correctness requirement.
sub _ingestCacheChunk {
    my ( $player_id, $chunk ) = @_;
    eval {
        require Plugins::SlimPing::Core::TranscodeCache;
        Plugins::SlimPing::Core::TranscodeCache->getInstance
          ->ingestChunk( $player_id, $chunk );
    };
}

sub _finaliseCacheEntry {
    my ( $player_id, $trust_size ) = @_;
    eval {
        require Plugins::SlimPing::Core::TranscodeCache;
        Plugins::SlimPing::Core::TranscodeCache->getInstance
          ->finaliseStream( $player_id, $trust_size );
    };
}

1;
