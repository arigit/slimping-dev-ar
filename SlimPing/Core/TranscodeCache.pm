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
# Core/TranscodeCache.pm - Transparent transcode cache facade for SlimPing
#
# Singleton that fronts the RAM and optional Disk storage backends for
# transcoded/re-encoded MP3 data.  Callers use lookup() to check for a
# cached track before dispatching to the pipeline, and registerStream() /
# ingestChunk() / finaliseStream() to populate the cache from an active
# pipeline.
#
# The cache key is "$sq_id:$output_br_kbps" — track identity plus the
# snapped output bitrate.  Different bitrates of the same track are
# separate entries.
#
# Cache errors never prevent streaming — all backend operations are
# eval-wrapped and fall through to the normal pipeline on failure.
#

package Plugins::SlimPing::Core::TranscodeCache;

use strict;
use warnings;

use Plugins::SlimPing::Core::Logging;

my $log   = Plugins::SlimPing::Core::Logging->getLogger();
my $prefs = Plugins::SlimPing::Core::Logging->getPrefs();

my $_instance;

sub getInstance {
    my $class = shift;
    return $_instance if $_instance;

    require Plugins::SlimPing::Core::TranscodeCache::Backend::RAM;
    my $ram = Plugins::SlimPing::Core::TranscodeCache::Backend::RAM->new(
        max_bytes  => $prefs->get('cache_ram_max_mb') * 1024 * 1024,
        max_tracks => $prefs->get('cache_ram_max_tracks'),
    );

    $_instance = bless {
        ram          => $ram,
        disk         => undef,
        populating   => {},
        inflight     => {},
        fmt_complete => {},      # in-RAM format-output cache (survives without disk tier)
    }, $class;

    $_instance->_initDisk();

    # Wire RAM eviction to demote entries to disk when the disk tier is enabled.
    $ram->{on_evict} = sub {
        my ( $key, $entry ) = @_;
        return unless $_instance->{disk} && $entry && $entry->{data};
        eval {
            $_instance->{disk}->startEntry($key);
            $_instance->{disk}->appendChunk( $key, ${ $entry->{data} } );
            $_instance->{disk}->finishEntry($key);
        };
        if ($@) {
            $log->warn("SlimPing: cache demotion to disk failed for $key: $@");
        }
    };

    return $_instance;
}

# NOTE: When changing the cache key scheme, bump CACHE_FORMAT_VERSION in
# Plugins::SlimPing::Plugin to force a flush of all persistent entries.
sub buildKey {
    my ( $class, $sq_id, $output_br ) = @_;
    return undef unless defined $sq_id && length $sq_id;
    $output_br //= 0;
    return "$sq_id:$output_br";
}

# Return the disk cache base directory for use by the slimping:// protocol
# handler, which needs to resolve cache filenames to full paths.
sub getDiskCacheDir {
    my $self = shift;
    return $self->{disk} ? $self->{disk}->{base_dir} : undef;
}

sub parseKey {
    my ( $class, $key ) = @_;
    return () unless defined $key && length $key;
    return split /:/, $key, 2;
}

sub lookup {
    my ( $self, $sq_id, $output_br ) = @_;
    return undef unless $sq_id;

    my $key = $self->buildKey( $sq_id, $output_br // 0 );

    my $ram_entry = $self->{ram}->get($key);
    if ($ram_entry) {
        return {
            status    => $ram_entry->{complete} ? 'complete' : 'populating',
            data      => $ram_entry->{data},
            populated => $ram_entry->{populated},
        };
    }

    if ( $self->{disk} ) {
        my $disk_entry = eval { $self->{disk}->get($key) };
        if ( $disk_entry && $disk_entry->{data} ) {
            $self->{ram}->startEntry($key);
            $self->{ram}->appendChunk( $key, ${ $disk_entry->{data} } );
            $self->{ram}->finishEntry($key);
            return {
                status    => 'complete',
                data      => $disk_entry->{data},
                populated => $disk_entry->{populated},
            };
        }
    }

    return undef;
}

sub registerStream {
    my ( $self, $player_id, $sq_id, $output_br, $expected_bytes ) = @_;
    return unless $player_id && $sq_id && $expected_bytes && $expected_bytes > 0;

    my $key = $self->buildKey( $sq_id, $output_br );
    $self->{populating}{$player_id} = {
        key            => $key,
        sq_id          => $sq_id,
        output_br      => $output_br,
        expected_bytes => $expected_bytes // 0,
    };

    $self->{ram}->startEntry($key);
    if ( $self->{disk} ) {
        eval { $self->{disk}->startEntry($key); };
        if ($@) {
            $log->warn("SlimPing: cache disk startEntry failed for $key: $@");
        }
    }
    $log->debug("SlimPing: cache stream registered for $key (player=$player_id)");
}

sub ingestChunk {
    my ( $self, $player_id, $chunk_ref ) = @_;
    return unless $player_id && $chunk_ref;

    my $info = $self->{populating}{$player_id} or return;
    my $data = $$chunk_ref;

    if ( defined($data) && length($data) == 0 ) {
        $self->finaliseStream( $player_id, 1 );
        return;
    }

    return unless defined($data) && length($data);

    eval { $self->{ram}->appendChunk( $info->{key}, $data ); };
    if ($@) {
        $log->warn("SlimPing: cache ingest error for $info->{key}: $@");
    }

    if ( $self->{disk} ) {
        eval { $self->{disk}->appendChunk( $info->{key}, $data ); };
        if ($@) {
            $log->warn("SlimPing: cache disk ingest error for $info->{key}: $@");
        }
    }
}

sub finaliseStream {
    my ( $self, $player_id, $trust_size ) = @_;
    my $info = delete $self->{populating}{$player_id} or return;

    # Discard entries with unknown expected size — we cannot verify
    # completeness, and a truncated entry served as a cache hit would
    # appear as a broken/cut-off track to the client.
    if ( !$info->{expected_bytes} ) {
        $log->debug("SlimPing: cache discarding entry with unknown size for $info->{key}");
        $self->{ram}->removeEntry( $info->{key} );
        $self->{disk}->removeEntry( $info->{key} ) if $self->{disk};
        return;
    }

    # Discard entries that cannot be a complete transcode.  All slimping
    # transcode rules encode CBR, so a genuine end-of-stream entry tracks
    # the byte estimate closely.  Short entries arise from two failure
    # modes: a client that disconnected mid-stream (finalised with
    # trust_size=0 by the cleanup path), and a pipeline that died
    # mid-stream (STREAMOUT masquerades as natural EOS because the next
    # read on the closed pipe returns 0, finalising with trust_size=1
    # after only a few hundred bytes).  Even when EOS is trusted, anything
    # below 80% of the estimate is a dead pipeline and must never serve
    # as a cache hit.
    my $ram_entry = $self->{ram}->get( $info->{key} );

    if (
           $ram_entry
        && $ram_entry->{populated} < $info->{expected_bytes}
        && (  !$trust_size
            || $ram_entry->{populated} < $info->{expected_bytes} * 0.8 )
      )
    {
        $log->debug(
            sprintf(
                'SlimPing: cache discarding partial entry for %s (%d/%d bytes)',
                $info->{key},
                $ram_entry->{populated},
                $info->{expected_bytes}
            )
        );
        $self->{ram}->removeEntry( $info->{key} );
        $self->{disk}->removeEntry( $info->{key} ) if $self->{disk};
        return;
    }

    # When another finaliseStream already cleaned the RAM entry for
    # this key (concurrent player race), there is nothing to promote.
    # Clean up any disk orphan and bail out — do NOT fall through to
    # Disk->finishEntry which would blindly mark it complete=1.
    unless ($ram_entry) {
        $self->{disk}->removeEntry( $info->{key} ) if $self->{disk};
        return;
    }

    $self->{ram}->finishEntry( $info->{key} );
    if ( $self->{disk} ) {
        eval { $self->{disk}->finishEntry( $info->{key} ); };
        if ($@) {
            $log->warn("SlimPing: cache disk finishEntry failed for $info->{key}: $@");
        }
    }

    $log->debug("SlimPing: cache stream finalised for $info->{key}");
}

sub stats {
    my ($self)     = @_;
    my $ram_stats  = $self->{ram}->stats();
    my $disk_stats = $self->{disk} ? eval { $self->{disk}->stats() } : undef;

    return {
        ram  => $ram_stats,
        disk => $disk_stats,
    };
}

# Whether the disk backend is currently active.  Because the backend is
# initialised once at startup and never cleared when the pref changes,
# this can return true even after cache_disk_enabled is set to 0.
sub isDiskActive {
    my ($self) = @_;
    return $self->{disk} ? 1 : 0;
}

# Return the path to the clean-shutdown marker file stored in LMS's temp
# directory (not the cache directory).  The marker's existence signals that
# the previous plugin shutdown was clean, so no orphan sweep is needed.
sub _shutdownMarkerPath {
    return Slim::Utils::Misc::getTempDir() . '/slimping_clean_shutdown';
}

sub _initDisk {
    my ($self) = @_;
    return unless $prefs->get('cache_disk_enabled');
    return if $self->{disk};

    require Plugins::SlimPing::Core::TranscodeCache::Backend::Disk;
    my $disk = Plugins::SlimPing::Core::TranscodeCache::Backend::Disk->new(
        max_mb   => $prefs->get('cache_disk_max_mb'),
        base_dir => $prefs->get('cache_disk_path'),
    );
    if ($disk) {
        $self->{disk} = $disk;
        $log->info('SlimPing: disk cache backend initialised');

        my $marker = $self->_shutdownMarkerPath();
        if ( -f $marker ) {
            unlink($marker);
            $log->info('SlimPing: clean shutdown detected -- skipping orphan sweep');
        }
        else {
            $self->_sweepOrphanedCacheFiles();
        }
    }
}

# Remove data files in the disk cache directory that have no corresponding
# .json metadata.  These are orphans from transcodes that crashed between
# writing the data file and finishFormatOutput writing the completeness
# marker.  Without this, a crashed transcode leaves a partial .flac that
# lookupFormatFile (via prepareFormatOutput) would serve as a cache hit.
sub _sweepOrphanedCacheFiles {
    my ($self) = @_;
    return unless $self->{disk} && $self->{disk}->_verifySentinel();

    my $dir = $self->{disk}->{base_dir};
    return unless $dir && -d $dir;

    my $removed = 0;
    eval {
        opendir( my $dh, $dir ) or die "opendir($dir): $!";

        # TODO: single-pass — sweep data files in the same loop instead of
        # building %json_stems and rewinding for a second pass.
        my %json_stems;
        for my $f ( readdir($dh) ) {
            if ( $f =~ /\.json$/ ) {
                ( my $stem = $f ) =~ s/\.json$//;
                $json_stems{$stem} = 1;
            }
        }
        rewinddir($dh);
        my $sentinel_name = $self->{disk}->sentinelFilename();
        for my $f ( readdir($dh) ) {
            next if $f =~ /^\.\.?$/;
            next if $f =~ /\.json$/;
            next if $f eq $sentinel_name;    # preserve the sentinel
            ( my $stem = $f ) =~ s/\.[^.]+$//;
            unless ( $json_stems{$stem} ) {
                my $full = "$dir/$f";        # double-slash harmless if $dir has trailing /
                unlink($full);
                $removed++;
                $log->info("SlimPing: removed orphaned cache file: $f");
            }
        }
        closedir($dh);
    };
    if ($@) {
        $log->warn("SlimPing: orphan sweep failed: $@");
    }
    $log->info("SlimPing: orphan sweep removed $removed file(s) from disk cache") if $removed;
}

# Unified cache flush entry point.  Called by:
#   - Plugin::postInitPlugin (cache format version bump)
#   - Core::Settings (settings page flush button)
#   - Settings::AdminApi::Data (admin API flush action)
#
# Flushes the disk cache directory (regardless of current cache_disk_enabled
# setting) and the RAM backend.  All destructive operations are sentinel-gated.
# Path validation happens in Backend::Disk::resolveBaseDir.
sub forceFlushAll {
    my ($class) = @_;

    # Disk: resolve path and sweep all files.  Works even when
    # cache_disk_enabled is 0 so stale files from a previous enable
    # are cleaned up too.  Sentinel verification prevents operating
    # on a misconfigured directory.
    #
    # Backend::Disk uses File::Spec::Functions — the require below
    # makes catfile/catdir available in the symbol table for the
    # fully-qualified calls used in this method.
    require Plugins::SlimPing::Core::TranscodeCache::Backend::Disk;
    my $disk_class = 'Plugins::SlimPing::Core::TranscodeCache::Backend::Disk';

    my $disk_path = $disk_class->resolveBaseDir( $prefs->get('cache_disk_path') );

    if ( $disk_path && -d $disk_path ) {

        # Verify sentinel before sweeping.  Use the class method to get the
        # sentinel filename — use constant subroutines cannot be dereferenced
        # as scalars cross-package.
        my $sentinel_name = $disk_class->sentinelFilename();
        my $sentinel_path = File::Spec::Functions::catfile( $disk_path, $sentinel_name );

        my $may_sweep = 0;
        if ( -f $sentinel_path ) {
            $may_sweep = 1;
        }
        elsif ( $disk_class->_directoryLooksLikeSlimpingCache($disk_path) ) {

            # Pre-sentinel cache directory from an earlier plugin version —
            # the contents are recognisably SlimPing cache files, so it is
            # safe to sweep.  Write the sentinel afterwards so future
            # sweeps use the fast path.
            $log->info("SlimPing: forceFlushAll reclaiming pre-sentinel cache directory $disk_path");
            $may_sweep = 1;
        }
        else {
            $log->warn("SlimPing: forceFlushAll refusing to sweep $disk_path — sentinel missing");
        }

        if ($may_sweep) {
            eval {
                opendir my $dh, $disk_path or die "opendir($disk_path): $!";
                my $removed = 0;
                for my $f ( readdir $dh ) {
                    next if $f =~ /^\.\.?$/;
                    next if $f eq $sentinel_name;    # preserve the sentinel
                    unlink File::Spec::Functions::catfile( $disk_path, $f );
                    $removed++;
                }
                closedir $dh;
                $log->info("SlimPing: forceFlushAll removed $removed file(s) from disk cache");

                # Write the sentinel after a successful sweep so future
                # operations (Disk::new, Disk::flush) use the fast path.
                # This is essential for pre-sentinel directories — without
                # it, Disk::new() will refuse them and disable the disk tier.
                eval {
                    open my $fh, '>', $sentinel_path
                      or die "open($sentinel_path): $!";
                    close $fh;
                };
                if ($@) {
                    $log->warn("SlimPing: forceFlushAll could not write sentinel to $disk_path: $@");
                }
            };
            if ($@) {
                $log->warn("SlimPing: forceFlushAll disk sweep failed: $@");
            }
        }
    }

    # RAM: flush singleton if it exists (creates it early if not).
    # At startup the RAM backend is always empty, so this is a
    # correctness safeguard — the real work is the disk sweep above.
    eval {
        my $cache = $class->getInstance;
        $cache->{ram}->flush();
        $cache->{populating} = {};
    };
    if ($@) {
        $log->warn("SlimPing: forceFlushAll RAM flush failed: $@");
    }
}

sub flush {
    my ($self) = @_;
    $self->{ram}->flush();
    $self->{populating}   = {};
    $self->{fmt_complete} = {};
    if ( $self->{disk} ) {
        eval { $self->{disk}->flush(); };
        if ($@) {
            $log->warn("SlimPing: disk cache flush failed: $@");
        }
    }
    $log->info('SlimPing: transcode cache flushed');
}

sub shutdown {
    my ($self) = @_;
    $self->{ram}->flush() if $self->{ram};
    $self->{populating} = {};
    undef $self->{disk};
    $_instance = undef;
}

# --- Format file cache ----------------------------------------------------------

# Single entry point for format-file output path resolution.  Replaces the
# separate lookupFormatFile / storeFormatFile / clearFormatInflight dance.
#
# Returns one of three shapes:
#   { path => $p, size => $n, ready => 1 }  — already cached, serve immediately
#   { path => $p, ready => 0 }              — path reserved, write transcode here
#   undef                                    — transcode inflight, caller waits
#
# When the disk cache is enabled, the reserved path is a temp file.  The
# caller writes transcode output there; finishFormatOutput moves it into the
# cache directory (atomic rename) and writes the .json completeness marker.
# When the disk cache is disabled, the temp file is served directly and
# cleaned up later by the periodic orphan sweep.
#
# SEC-001: cache hits REQUIRE .json metadata with complete=>1.  A .flac file
# without corresponding .json (or with complete=>0) is treated as a miss.
sub prepareFormatOutput {
    my ( $self, $sq_id, $suffix ) = @_;
    return undef unless $sq_id;
    $suffix ||= 'tmp';

    my $inflight_key = "fmt:$sq_id:$suffix";

    # Already inflight — caller must wait (ExternalProcess dedup handles this).
    if ( $self->{inflight}{$inflight_key} ) {
        $log->debug("SlimPing: format cache inflight for $inflight_key");
        return undef;
    }

    # Cache ON: check for a completed entry on disk.
    if ( $self->{disk} ) {
        my $safe      = $self->{disk}->_safeFilename("cue:$sq_id");
        my $path      = $self->{disk}->{base_dir} . "/$safe.$suffix";
        my $meta_path = $self->{disk}->{base_dir} . "/$safe.json";

        if ( -f $path && -f $meta_path ) {

            # FIXME: If _readMetaFromFile throws (corrupt JSON), we silently
            # fall through as a cache miss.  Should log a warning so operators
            # can detect and clean corrupted cache entries.
            my $meta = eval { $self->{disk}->_readMetaFromFile($meta_path) };
            if ($@) {
                $log->warn("SlimPing: corrupt format cache metadata for $sq_id: $@");
            }
            if ( $meta && $meta->{complete} ) {
                my $size = -s $path or return undef;
                utime( undef, undef, $path );
                $log->debug("SlimPing: format cache hit $sq_id ($size bytes)");
                return { path => $path, size => $size, ready => 1 };
            }
        }
    }

    # In-RAM fallback: when the disk tier is disabled (default), track
    # completed format outputs in memory so repeat requests for the same
    # exotic→FLAC transcode don't trigger a fresh 5+ second re-encode.
    if ( my $entry = $self->{fmt_complete}{$inflight_key} ) {
        if ( -f $entry->{path} && -s $entry->{path} ) {
            $log->debug("SlimPing: format cache HIT (RAM) $sq_id ($entry->{size} bytes)");
            return { path => $entry->{path}, size => $entry->{size}, ready => 1 };
        }

        # Temp file was cleaned up (orphan sweep or restart) — forget it.
        delete $self->{fmt_complete}{$inflight_key};
    }

    # Miss — claim the inflight slot and return a reserved path.
    $self->{inflight}{$inflight_key} = 1;

    my $ext      = ( $suffix && $suffix ne 'tmp' ) ? $suffix : 'tmp';
    my $tmp_path = Slim::Utils::Misc::getTempDir() . '/slimping_out_' . time() . '_' . int( rand(999999) ) . '.' . $ext;

    $log->debug("SlimPing: format cache miss $sq_id (path reserved: $tmp_path)");
    return { path => $tmp_path, ready => 0 };
}

# Mark a format transcode as complete.  When the disk cache is enabled, the
# temp file is moved into the cache directory (atomic rename) and .json
# metadata is written with complete=>1.  When disabled, the path is returned
# unchanged and the inflight marker is cleared.  Returns the resolved path
# that all callbacks should serve from.
sub finishFormatOutput {
    my ( $self, $sq_id, $temp_path, $suffix ) = @_;
    return unless $sq_id && $temp_path;
    $suffix ||= 'tmp';

    my $inflight_key = "fmt:$sq_id:$suffix";
    my $resolved     = $temp_path;

    if ( $self->{disk} && -f $temp_path ) {
        my $safe      = $self->{disk}->_safeFilename("cue:$sq_id");
        my $ext       = $suffix;
        my $dest      = $self->{disk}->{base_dir} . "/$safe.$ext";
        my $size      = -s $temp_path;
        my $meta_dest = $self->{disk}->{base_dir} . "/$safe.json";

        # Remove any previous partial entry for this key.
        unlink($dest)      if -f $dest;
        unlink($meta_dest) if -f $meta_dest;

        unless ( rename( $temp_path, $dest ) ) {
            $log->warn("SlimPing: format cache rename failed: $temp_path -> $dest: $!");
            delete $self->{inflight}{$inflight_key};
            return $temp_path;    # serve from temp even though rename failed
        }

        # Write completeness metadata.  Must succeed before we clear the
        # inflight marker — otherwise a concurrent request could see the
        # .flac file without a .json and serve a file it thinks is incomplete.
        my $meta_ok = 0;
        eval {
            my $meta = {
                complete  => 1,
                populated => $size,
                mtime     => time(),
                suffix    => $ext,
            };
            require JSON::XS;
            if ( open my $fh, '>', $meta_dest ) {
                print $fh JSON::XS::encode_json($meta);
                $meta_ok = close($fh);    # close() reports write errors
            }
            else {
                $log->warn("SlimPing: cannot open metadata file $meta_dest: $!");
            }
        };
        if ($@) {
            $log->warn("SlimPing: format cache metadata write error for $sq_id: $@");
        }

        unless ($meta_ok) {

            # Metadata couldn't be written — the data file was already renamed
            # into the cache directory (the rename at line 392 succeeded).
            # The audio data is valid and will be served from the cache path.
            # Clear the inflight marker so retries work; the orphaned data file
            # (no .json companion) will be cleaned by _sweepOrphanedCacheFiles
            # on next startup.
            $log->warn("SlimPing: format cache metadata not persisted for $sq_id — orphan will be swept at restart");
            delete $self->{inflight}{$inflight_key};
            return $dest;    # serve the file anyway (audio is fine, just not tracked)
        }

        # Update disk backend size tracking.
        eval {
            $self->{disk}->{current_bytes} += $size;
            $self->{disk}->_enforceSizeLimit();
        };
        if ($@) {
            $log->warn("SlimPing: format cache size tracking error for $sq_id: $@");
        }

        $log->debug("SlimPing: format cache stored $sq_id ($size bytes)");
        $resolved = $dest;
    }

    # Track the completed output in RAM so repeat requests hit the cache
    # even when the disk tier is disabled (the default).  The temp file
    # survives until the next orphan sweep (2-hour TTL on temp files).
    my $size = -s $resolved;
    if ( $size && $size > 0 ) {
        $self->{fmt_complete}{$inflight_key} = {
            path => $resolved,
            size => $size,
        };
    }

    # Clear the inflight marker — subsequent requests can now hit the cache.
    delete $self->{inflight}{$inflight_key};
    return $resolved;
}

# Discard a failed format transcode.  Removes the temp file, clears the
# inflight marker, and (if cache was on) removes any partial cache entry.
sub discardFormatOutput {
    my ( $self, $sq_id, $temp_path, $suffix ) = @_;
    return unless $sq_id;
    $suffix ||= 'tmp';

    my $inflight_key = "fmt:$sq_id:$suffix";
    delete $self->{inflight}{$inflight_key};
    delete $self->{fmt_complete}{$inflight_key};

    # Remove the temp file if it exists.
    if ( $temp_path && -f $temp_path ) {
        unlink($temp_path);
    }

    # If cache is on, also clean any partial entry at the cache path.
    if ( $self->{disk} ) {
        my $safe      = $self->{disk}->_safeFilename("cue:$sq_id");
        my $ext       = $suffix;
        my $dest      = $self->{disk}->{base_dir} . "/$safe.$ext";
        my $meta_dest = $self->{disk}->{base_dir} . "/$safe.json";
        unlink($dest)      if -f $dest;
        unlink($meta_dest) if -f $meta_dest;
    }

    $log->debug("SlimPing: format cache discarded $sq_id") if $sq_id;
}

1;
