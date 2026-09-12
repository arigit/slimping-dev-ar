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
# Core/TranscodeCache/Backend/RAM.pm - In-memory LRU storage for transcoded audio
#
# Stores complete or populating MP3 byte buffers indexed by cache key.
# Eviction is LRU with dual caps (byte count + track count).  The byte cap
# may be temporarily exceeded by one in-flight entry; enforcement fires on
# the next write and evicts down to 80% of the cap.
#
# LRU ordering uses an array (@lru_order) of key strings rather than linked
# hashrefs to avoid reference cycles that Perl's refcount GC cannot collect.
#

package Plugins::SlimPing::Core::TranscodeCache::Backend::RAM;

use strict;
use warnings;

use Time::HiRes qw(time);

# Try to load the plugin logger; fall back to a silent stand-in when
# running without the LMS runtime (e.g. unit tests).
my $log;
BEGIN {
    $log = eval {
        require Plugins::SlimPing::Core::Logging;
        Plugins::SlimPing::Core::Logging->getLogger();
    };
    if ($@) {
        # No-op logger for environments where LMS is not available.
        $log = bless( {}, 'Plugins::SlimPing::Core::TranscodeCache::Backend::RAM::_NullLog' );
    }
}

{
    package Plugins::SlimPing::Core::TranscodeCache::Backend::RAM::_NullLog;
    our $AUTOLOAD;
    sub AUTOLOAD { }
    sub DESTROY  { }
}

sub new {
    my ( $class, %args ) = @_;
    my $max_bytes  = $args{max_bytes}  // 104_857_600;
    my $max_tracks = $args{max_tracks} // 10;

    my $self = {
        max_bytes     => $max_bytes,
        max_tracks    => $max_tracks,
        target_bytes  => int( $max_bytes * 0.8 ),
        per_entry_max => int( $max_bytes * 0.5 ),
        on_evict      => undef,    # $coderef->($key, $entry) — set by facade
        entries       => {},
        lru_order     => [],
        stats         => {
            bytes_used  => 0,
            track_count => 0,
            hits        => 0,
            misses      => 0,
            evictions   => 0,
        },
    };

    bless $self, $class;
    return $self;
}

sub startEntry {
    my ( $self, $key ) = @_;
    return 0 unless defined $key && length $key;

    $self->_removeEntry($key) if exists $self->{entries}{$key};
    $self->_evict();

    $self->{entries}{$key} = {
        data      => \do { my $buf = ''; },
        populated => 0,
        complete  => 0,
        mtime     => time(),
    };
    $self->_bumpLRU($key);
    return 1;
}

sub appendChunk {
    my ( $self, $key, $chunk ) = @_;
    return 0 unless defined $key && defined $chunk && length $chunk;
    my $entry = $self->{entries}{$key} or return 0;
    return 0 if $entry->{complete};

    my $new_size = $entry->{populated} + length($chunk);
    if ( $new_size > $self->{per_entry_max} ) {
        $log->warn("SlimPing: RAM cache entry $key exceeds per-entry max, discarding");
        $self->_removeEntry($key);
        return 0;
    }

    ${ $entry->{data} } .= $chunk;
    $entry->{populated} = $new_size;
    $entry->{mtime}     = time();
    $self->{stats}{bytes_used} += length($chunk);
    return 1;
}

sub finishEntry {
    my ( $self, $key ) = @_;
    return 0 unless defined $key;
    my $entry = $self->{entries}{$key} or return 0;
    return 0 if $entry->{complete};

    # Discard zero-byte entries — the player disconnected before delivering
    # any audio (client abort during pipeline ramp-up, network drop, etc.).
    if ( $entry->{populated} == 0 ) {
        $self->_removeEntry($key);
        return 0;
    }

    $entry->{complete} = 1;
    $self->{stats}{track_count}++;
    return 1;
}

sub get {
    my ( $self, $key ) = @_;
    my $entry = $self->{entries}{$key};
    unless ($entry) {
        $self->{stats}{misses}++;
        return undef;
    }

    $self->{stats}{hits}++;
    $entry->{mtime} = time();
    $self->_bumpLRU($key);
    return {
        data      => $entry->{data},
        populated => $entry->{populated},
        complete  => $entry->{complete},
    };
}

sub _evict {
    my ($self) = @_;

    while (
        @{ $self->{lru_order} }
        && (   $self->{stats}{bytes_used} > $self->{target_bytes}
            || $self->{stats}{track_count} > $self->{max_tracks} )
      )
    {
        my $victim;
        for my $i ( 0 .. $#{ $self->{lru_order} } ) {
            my $k = $self->{lru_order}[$i];
            my $e = $self->{entries}{$k};
            next unless $e && $e->{complete};
            $victim = $k;
            last;
        }
        last unless $victim;

        # Demotion callback — facade writes entry to disk before removal.
        if ( $self->{on_evict} ) {
            eval { $self->{on_evict}->( $victim, $self->{entries}{$victim} ); };
        }
        $self->_removeEntry($victim);
        $self->{stats}{evictions}++;
        $log->debug("SlimPing: RAM cache evicted $victim");
    }
}

sub removeEntry {
    my ( $self, $key ) = @_;
    return $self->_removeEntry($key);
}

sub _removeEntry {
    my ( $self, $key ) = @_;
    my $entry = delete $self->{entries}{$key} or return;
    $self->{stats}{bytes_used} -= $entry->{populated};
    $self->{stats}{track_count}-- if $entry->{complete};
    $self->{lru_order} = [ grep { $_ ne $key } @{ $self->{lru_order} } ];
}

sub _bumpLRU {
    my ( $self, $key ) = @_;
    $self->{lru_order} = [ grep { $_ ne $key } @{ $self->{lru_order} } ];
    push @{ $self->{lru_order} }, $key;
}

sub flush {
    my ($self) = @_;
    $self->{entries}   = {};
    $self->{lru_order} = [];
    $self->{stats}     = {
        bytes_used  => 0,
        track_count => 0,
        hits        => $self->{stats}{hits},
        misses      => $self->{stats}{misses},
        evictions   => $self->{stats}{evictions},
    };
    $log->info('SlimPing: RAM cache flushed');
}

sub stats {
    my ($self) = @_;
    return {
        bytes_used  => $self->{stats}{bytes_used},
        track_count => $self->{stats}{track_count},
        hits        => $self->{stats}{hits},
        misses      => $self->{stats}{misses},
        evictions   => $self->{stats}{evictions},
        max_bytes   => $self->{max_bytes},
        max_tracks  => $self->{max_tracks},
        entries     => [
            map { { key => $_, %{ $self->{entries}{$_} } } }
              grep { exists $self->{entries}{$_} } @{ $self->{lru_order} }
        ],
    };
}

1;
