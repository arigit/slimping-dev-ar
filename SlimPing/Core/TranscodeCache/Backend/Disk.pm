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
# Core/TranscodeCache/Backend/Disk.pm - File-based binary storage for transcode cache
#
# Optional persistent backing store.  Each cache entry is a pair of files:
#   <cachedir>/slimping/transcode_cache/<safe_key>.mp3   — binary MP3 data
#   <cachedir>/slimping/transcode_cache/<safe_key>.json  — entry metadata
#
# Filenames are derived from the cache key via MD5 to avoid filesystem issues
# (colons in FAT32 paths, case-insensitive collisions).  All disk operations
# are eval-wrapped — failures silently fall through to the normal pipeline.
#

package Plugins::SlimPing::Core::TranscodeCache::Backend::Disk;

use strict;
use warnings;

use Plugins::SlimPing::Core::Logging;
use Digest::MD5      qw(md5_hex);
use File::Path       qw(make_path);
use File::Spec::Functions qw(catfile catdir);
use File::stat;
use JSON::XS         ();
use Time::HiRes      qw(time);

my $log = Plugins::SlimPing::Core::Logging->getLogger();

use constant SENTINEL_FILENAME => '.slimping_cache_dir';

# Expose the sentinel filename so the TranscodeCache facade can construct
# sentinel paths without instantiating the backend.  use constant creates a
# parameterless subroutine, which cannot be dereferenced as a scalar variable
# cross-package — this class method provides a clean accessor instead.
sub sentinelFilename {
    return SENTINEL_FILENAME;
}

# Resolve the disk cache base directory from a custom path or the LMS server
# cachedir.  Factored as a class method so the unified forceFlushAll can
# discover the directory without instantiating the backend.
#
# Validates the custom path: rejects non-absolute paths and paths containing
# .. segments.  This is the single choke point for cache_disk_path validation,
# covering both the HTML settings form and the AdminApi JSON save path.
sub resolveBaseDir {
    my ( $class, $custom_path ) = @_;

    if ( length $custom_path ) {
        if ( $custom_path !~ m{^/} ) {
            $log->warn(
"SlimPing: cache_disk_path must be an absolute path, refusing '$custom_path'"
            );
            return undef;
        }
        if ( $custom_path =~ m{/\.\./} || $custom_path =~ m{/\.\.$} ) {
            $log->warn(
"SlimPing: cache_disk_path must not contain .. segments, refusing '$custom_path'"
            );
            return undef;
        }
        return $custom_path;
    }

    my $cachedir = eval {
        Slim::Utils::Prefs::preferences('server')->get('cachedir');
    };
    return undef if $@ || !$cachedir;

    return catdir( $cachedir, 'slimping', 'transcode_cache' );
}

# Check whether a directory contains only files that look like SlimPing
# cache entries (32-char MD5 hex stem + .mp3/.flac/.json extension).
# Returns 1 if every file in the directory matches the pattern (or the
# directory is empty), 0 if any non-matching file is found.
#
# Used for bootstrapping: pre-sentinel cache directories from earlier
# plugin versions are safe to claim and sweep.  Directories containing
# foreign files are rejected — they may be misconfigured paths.
sub _directoryLooksLikeSlimpingCache {
    my ( $class, $dir ) = @_;
    return 0 unless $dir && -d $dir;

    my $result = 0;
    eval {
        opendir my $dh, $dir or die "opendir($dir): $!";
        for my $f ( readdir $dh ) {
            next if $f =~ /^\.\.?$/;
            # SlimPing cache entries: 32-char lowercase MD5 hex stem
            # with .mp3, .flac, or .json extension.
            unless ( $f =~ /^[a-f0-9]{32}\.(mp3|flac|json)$/ ) {
                closedir $dh;
                $result = 0;
                return;
            }
            $result = 1;
        }
        closedir $dh;
    };
    if ($@) {
        $log->warn("SlimPing: cannot read directory $dir: $@");
        return 0;
    }
    return $result;
}

# Verify the sentinel file exists before any destructive directory sweep.
# Returns 1 if safe, 0 if the sentinel is missing (logs a warning).
sub _verifySentinel {
    my ($self) = @_;
    my $path = catfile( $self->{base_dir}, SENTINEL_FILENAME );
    unless ( -f $path ) {
        $log->warn(
"SlimPing: sentinel missing from $self->{base_dir} — refusing destructive sweep.
The cache directory may have been replaced or tampered with."
        );
        return 0;
    }
    return 1;
}

sub new {
    my ( $class, %args ) = @_;
    my $max_mb   = $args{max_mb}  // 2048;
    my $base_dir = $args{base_dir} || '';

    # Route every path through resolveBaseDir — the single choke point for
    # validation (absolute, no ..) and default-path resolution.  A custom
    # path is validated; an empty string falls through to the server cachedir.
    $base_dir = $class->resolveBaseDir($base_dir);
    return undef unless $base_dir;

    my $self = {
        max_bytes    => $max_mb * 1024 * 1024,
        target_bytes => int( $max_mb * 1024 * 1024 * 0.8 ),
        base_dir     => $base_dir,
    };

    # Directory safety gating.  If the directory does not exist or is empty
    # with no subdirectories, it is safe to claim.  If it already exists and
    # contains our sentinel, it was previously initialised by us.  If it
    # exists with content but no sentinel, refuse — it may be a misconfigured
    # path pointing at real data.
    my $sentinel_path = catfile( $base_dir, SENTINEL_FILENAME );
    if ( -d $base_dir ) {
        if ( -f $sentinel_path ) {
            $log->info("SlimPing: disk cache directory $base_dir has sentinel — proceeding");
        } else {
            my $empty = 1;
            eval {
                opendir my $dh, $base_dir or die "opendir($base_dir): $!";
                for my $f ( readdir $dh ) {
                    next if $f =~ /^\.\.?$/;
                    $empty = 0;
                    last;
                }
                closedir $dh;
            };
            if ($@) {
                $log->warn("SlimPing: cannot read disk cache directory $base_dir: $@");
                return undef;
            }
            unless ($empty) {
                # Check whether the directory looks like a pre-sentinel
                # SlimPing cache (only MD5-hex-named .mp3/.flac/.json files).
                # If so, sweep it clean and claim it — this is a legitimate
                # upgrade from an earlier plugin version.
                if ( $class->_directoryLooksLikeSlimpingCache($base_dir) ) {
                    $log->info(
"SlimPing: reclaiming pre-sentinel cache directory $base_dir — sweeping old entries"
                    );
                    eval {
                        opendir my $dh2, $base_dir
                          or die "opendir($base_dir): $!";
                        for my $f2 ( readdir $dh2 ) {
                            next if $f2 =~ /^\.\.?$/;
                            unlink catfile( $base_dir, $f2 );
                        }
                        closedir $dh2;
                    };
                    if ($@) {
                        $log->warn(
"SlimPing: failed to sweep pre-sentinel cache directory $base_dir: $@"
                        );
                        return undef;
                    }
                } else {
                    $log->warn(
"SlimPing: disk cache directory $base_dir is not empty and has no sentinel — refusing to use it.
The directory may be misconfigured.  Set cache_disk_path to an empty or dedicated directory,
or remove the existing files if they are old SlimPing cache artifacts."
                    );
                    return undef;
                }
            }
            $log->info("SlimPing: claiming empty directory $base_dir as disk cache");
        }
    } else {
        eval { make_path($base_dir); };
        if ($@) {
            $log->warn("SlimPing: disk cache directory unavailable ($base_dir): $@");
            return undef;
        }
    }

    # Create or refresh the sentinel file so sweep operations can verify
    # this directory belongs to SlimPing.
    eval {
        open my $fh, '>', $sentinel_path or die "open($sentinel_path): $!";
        close $fh;
    };
    if ($@) {
        $log->warn("SlimPing: cannot write sentinel to $base_dir: $@");
        return undef;
    }

    bless $self, $class;
    $log->info("SlimPing: disk cache initialised at $base_dir (max $max_mb MB)");
    return $self;
}

sub _safeFilename {
    my ( $self, $key ) = @_;
    return md5_hex($key);
}

# Returns the data file path for a cache key.  The extension is always .mp3
# because this method is only used for regular transcode entries (which are
# always MP3 output from the SlimPing pipeline).  Format-cache entries and
# other non-MP3 entries use a different key scheme and must NOT call this
# method — use _metaPath and construct the data path suffix-aware instead.
sub _dataPath {
    my ( $self, $key ) = @_;
    return catfile( $self->{base_dir}, $self->_safeFilename($key) . '.mp3' );
}

sub _metaPath {
    my ( $self, $key ) = @_;
    return catfile( $self->{base_dir}, $self->_safeFilename($key) . '.json' );
}

sub _writeMeta {
    my ( $self, $key, $meta ) = @_;
    my $meta_path = $self->_metaPath($key);
    eval {
        open my $fh, '>', $meta_path or die "open failed: $!";
        print $fh JSON::XS::encode_json($meta);
        close $fh or die "close failed: $!";
    };
    if ($@) {
        $log->warn("SlimPing: disk cache metadata write failed for $key ($meta_path): $@");
    }
}

sub _readMeta {
    my ( $self, $key ) = @_;
    my $path = $self->_metaPath($key);
    return undef unless -f $path;
    my $meta = eval {
        open my $fh, '<', $path or die "open failed: $!";
        local $/;
        my $json = <$fh>;
        close $fh;
        return JSON::XS::decode_json($json);
    };
    if ($@) {
        $log->warn("SlimPing: disk cache metadata read failed for $key ($path): $@");
        return undef;
    }
    return $meta;
}

sub startEntry {
    my ( $self, $key ) = @_;
    return 0 unless $key;

    # Remove any previous entry for this key — a re-requested track
    # must start fresh.  Without this, appendChunk writes new partial
    # data on top of the old complete file, corrupting it.  Matching
    # RAM backend behaviour where startEntry replaces the old entry.
    $self->removeEntry($key);

    $self->_writeMeta( $key, {
        populated => 0,
        complete  => 0,
        mtime     => time(),
    });
    return 1;
}

sub appendChunk {
    my ( $self, $key, $chunk ) = @_;
    return 0 unless $key && defined $chunk && length $chunk;

    eval {
        my $fh;
        if ( open $fh, '>>', $self->_dataPath($key) ) {
            binmode $fh;
            print $fh $chunk;
            close $fh;

            my $meta = $self->_readMeta($key) || { populated => 0, complete => 0 };
            my $len  = length($chunk);
            $meta->{populated} += $len;
            $meta->{mtime}     = time();
            $self->_writeMeta( $key, $meta );
        }
    };
    if ($@) {
        $log->warn("SlimPing: disk cache write error for $key: $@");
    }
    return 1;
}

sub finishEntry {
    my ( $self, $key ) = @_;
    return 0 unless $key;
    my $meta = $self->_readMeta($key) or return 0;
    $meta->{complete} = 1;
    $self->_writeMeta( $key, $meta );
    $self->_enforceSizeLimit();
    return 1;
}

sub get {
    my ( $self, $key ) = @_;
    return undef unless $key;

    my $meta = $self->_readMeta($key) or return undef;
    return undef unless $meta->{complete};

    my $data_path = $self->_dataPath($key);
    return undef unless -f $data_path;

    my $data = eval {
        open my $fh, '<', $data_path or return undef;
        binmode $fh;
        local $/;
        my $bytes = <$fh>;
        close $fh;
        return \$bytes;
    };
    return undef unless $data;

    $meta->{mtime} = time();
    $self->_writeMeta( $key, $meta );

    return {
        data      => $data,
        populated => $meta->{populated},
        complete  => 1,
    };
}

sub _enforceSizeLimit {
    my ($self) = @_;
    return unless -d $self->{base_dir};
    return unless $self->_verifySentinel();

    my @entries;
    eval {
        opendir my $dh, $self->{base_dir} or die "opendir failed: $!";
        for my $f ( readdir $dh ) {
            next unless $f =~ /\.json$/;
            my $json_path = catfile( $self->{base_dir}, $f );
            my $json_meta = $self->_readMetaFromFile($json_path);
            next unless $json_meta && $json_meta->{complete};
            push @entries, {
                json_path => $json_path,
                mtime     => $json_meta->{mtime} // 0,
                size      => $json_meta->{populated} // 0,
                suffix    => $json_meta->{suffix} // 'mp3',
            };
        }
        closedir $dh;
    };
    return if $@;

    @entries = sort { $a->{mtime} <=> $b->{mtime} } @entries;

    my $total = 0;
    $total += $_->{size} for @entries;

    while ( @entries && $total > $self->{target_bytes} ) {
        my $victim = shift @entries;
        $total -= $victim->{size};
        my $ext = ( $victim->{suffix} || 'mp3' );
        $ext = 'mp3' if $ext !~ /\A[a-z0-9_.-]+\z/i;
        ( my $data_path = $victim->{json_path} ) =~ s/\.json$/.$ext/;
        unlink $data_path;
        unlink $victim->{json_path};
        $log->debug("SlimPing: disk cache evicted (LRU, size enforcement)");
    }

    # Cull incomplete entries older than 24 hours - orphans from interrupted
    # streams that will never become complete.  These are invisible to the
    # size-enforcement loop above (which only counts complete entries).
    eval {
        opendir my $dh2, $self->{base_dir} or die "opendir failed: $!";
        my $cutoff = time() - 86400;
        for my $f ( readdir $dh2 ) {
            next unless $f =~ /\.json$/;
            my $json_path = catfile( $self->{base_dir}, $f );
            my $meta = $self->_readMetaFromFile($json_path);
            next unless $meta && !$meta->{complete};
            next unless ( $meta->{mtime} // 0 ) < $cutoff;
            my $ext2 = ( $meta->{suffix} || 'mp3' );
            $ext2 = 'mp3' if $ext2 !~ /\A[a-z0-9_.-]+\z/i;
            ( my $data_path = $json_path ) =~ s/\.json$/.$ext2/;
            unlink $data_path;
            unlink $json_path;
            $log->debug("SlimPing: disk cache culled incomplete orphan");
        }
        closedir $dh2;
    };
    if ($@) {
        $log->warn("SlimPing: disk cache orphan cull failed: $@");
    }
}

sub _readMetaFromFile {
    my ( $self, $path ) = @_;
    return undef unless -f $path;
    eval {
        open my $fh, '<', $path or return undef;
        local $/;
        my $json = <$fh>;
        close $fh;
        return JSON::XS::decode_json($json);
    };
}

sub stats {
    my ($self) = @_;
    return undef unless $self->{base_dir} && -d $self->{base_dir};

    my $bytes = 0;
    my $count = 0;
    eval {
        opendir my $dh, $self->{base_dir} or die "opendir failed: $!";
        for my $f ( readdir $dh ) {
            next unless $f =~ /\.json$/;
            my $meta = $self->_readMetaFromFile( catfile( $self->{base_dir}, $f ) );
            next unless $meta;
            $bytes += $meta->{populated} // 0;
            $count++ if $meta->{complete};
        }
        closedir $dh;
    };
    if ($@) {
        $log->warn("SlimPing: disk cache stats collection failed: $@");
    }

    return {
        bytes_used  => $bytes,
        track_count => $count,
        max_bytes   => $self->{max_bytes},
    };
}

sub removeEntry {
    my ( $self, $key ) = @_;
    return unless $key;
    eval {
        unlink $self->_dataPath($key);
        unlink $self->_metaPath($key);
    };
}

sub flush {
    my ($self) = @_;
    return unless $self->{base_dir} && -d $self->{base_dir};
    return unless $self->_verifySentinel();

    eval {
        opendir my $dh, $self->{base_dir} or die "opendir failed: $!";
        for my $f ( readdir $dh ) {
            next if $f =~ /^\.\.?$/;
            next if $f eq SENTINEL_FILENAME;   # preserve the sentinel itself
            unlink catfile( $self->{base_dir}, $f );
        }
        closedir $dh;
    };
    if ($@) {
        $log->warn("SlimPing: disk cache flush failed: $@");
    } else {
        $log->info('SlimPing: disk cache flushed');
    }
}

1;
