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
# Core/ExternalProcess.pm - Non-blocking external process runner
#
# Provides fork+exec lifecycle with LMS-native pipe-based completion
# detection for running external binaries (flac, dsdplay) without blocking
# LMS's single-threaded event loop.  Replaces all system() calls in
# AudioDelivery.pm.
#
# Completion detection uses Slim::Networking::Select::addRead on a pipe
# whose write-end is held open by the child.  When the child exits the
# kernel closes the write-end, the pipe EOF fires the addRead callback
# through LMS's EV event loop -- the same mechanism LMS uses internally
# for transcode pipeline process monitoring.
#
# Startup gating via auditCapabilities() detects missing binaries at plugin
# init so the dispatch never enters a doomed path.  Runtime failures fall
# through to MP3 transcode via the on_error callback.
#

package Plugins::SlimPing::Core::ExternalProcess;

use strict;
use warnings;

use POSIX;
use Slim::Utils::Timers;
require Slim::Networking::Select;
use Plugins::SlimPing::Core::Logging;

my $log = Plugins::SlimPing::Core::Logging->getLogger();

# Resolved binary paths from startup audit.  undef = not available.
my $_HAVE_FLAC;
my $_HAVE_DSDPLAY;

# Platform capability.  Set by auditCapabilities() at startup.
# 0 = external process execution unavailable (Regular Windows, or fork-less Perl).
# 1 = fork/exec/pipe available (Linux, macOS, BSD, Cygwin).
my $_CAN_FORK;

# In-flight transcode state.  Keyed by $cache_key.
my %_IN_FLIGHT;

# Maintenance sweep interval (seconds).
use constant MAINTENANCE_INTERVAL => 30;

# --- Startup audit ------------------------------------------------------------

sub auditCapabilities {
    # Platform gate: Windows Perl lacks fork(), pipe-based completion
    # detection, and /bin/sh.  External binary processing is unavailable
    # regardless of whether binaries (flac.exe, dsdplay.exe) exist on PATH.
    my $is_windows = defined &main::ISWINDOWS && main::ISWINDOWS;
    if ($is_windows) {
        $log->warn("SlimPing: ExternalProcess disabled on Windows (fork unavailable)");
        $_CAN_FORK    = 0;
        $_HAVE_FLAC    = undef;
        $_HAVE_DSDPLAY = undef;
        _cleanupOrphanedTempFiles();
        _startMaintenanceSweep();
        return {};
    }

    $_CAN_FORK = 1;

    my %binaries = (
        flac    => \$_HAVE_FLAC,
        dsdplay => \$_HAVE_DSDPLAY,
    );
    for my $bin (keys %binaries) {
        my $path = eval { Slim::Utils::Misc::findbin($bin) };
        if ($@) {
            $log->warn("SlimPing: ExternalProcess capability $bin lookup error: $@");
            $path = undef;
        }
        ${ $binaries{$bin} } = defined $path ? $path : undef;
        if (${ $binaries{$bin} }) {
            $log->info("SlimPing: ExternalProcess capability $bin -> $path");
        } else {
            $log->warn("SlimPing: ExternalProcess capability $bin NOT FOUND");
        }
    }
    _cleanupOrphanedTempFiles();
    _startMaintenanceSweep();
    return \%binaries;
}

# --- In-flight state accessors ------------------------------------------------

sub haveFlac    { return defined $_HAVE_FLAC; }
sub haveDsdplay { return defined $_HAVE_DSDPLAY; }
sub canFork     { return $_CAN_FORK; }

sub flacPath    { return $_HAVE_FLAC; }
sub dsdplayPath { return $_HAVE_DSDPLAY; }

# --- Core API: spawn ----------------------------------------------------------

# Fork a child process to run @$cmd, writing output to $tmp_path.
# Returns immediately -- the caller's event-loop iteration continues.
# Completion is detected via pipe EOF through Slim::Networking::Select,
# the same mechanism LMS uses internally for transcode pipeline monitoring.
#
# Required args:
#   cmd          => [$bin, @args]   (full path from auditCapabilities)
#   tmp_path     => '/tmp/...'      (output file, must be writable)
#   cache_key    => "$sq_id:$suffix:$sample_range"
#   timeout_s    => 120
#   on_complete  => sub { ... }     (tmp_path is valid, non-empty)
#   on_error     => sub { ... }     (degrade to MP3 pipeline)
#
# Optional:
#   httpClient   => $httpClient     (for close-handler tracking)
#   response     => $response
#
# Returns 1 on success, 0 if a duplicate is already in-flight
# (caller should fall through to MP3 pipeline).
sub spawn {
    my ($class, %args) = @_;

    my $cmd          = $args{cmd};
    my $tmp_path     = $args{tmp_path};
    my $cache_key    = $args{cache_key};
    my $cache_sq_id  = $args{cache_sq_id};
    my $cache_suffix = $args{cache_suffix};
    my $timeout_s    = $args{timeout_s}   // 120;
    my $on_complete  = $args{on_complete};
    my $on_error     = $args{on_error};
    my $httpClient   = $args{httpClient};
    my $response     = $args{response};

    # Platform guard: all current callers check haveFlac()/haveDsdplay()
    # before reaching spawn(), so this should never fire in normal operation.
    # It exists as a backstop against future code paths that might bypass
    # the capability gates.
    unless ($_CAN_FORK) {
        $log->error("SlimPing: ExternalProcess::spawn called but fork unavailable — platform gate bypassed?");
        $on_error->("platform unsupported") if $on_error;
        return 0;
    }

    return 0 unless $cmd && ref $cmd eq 'ARRAY' && @$cmd;
    return 0 unless $cache_key;
    return 0 unless $on_complete && $on_error;

    # In-flight deduplication: register as a waiter on the existing
    # transcode instead of starting a duplicate.  Waiter callers may
    # pass an empty tmp_path (prepareFormatOutput returned undef) --
    # the dedup check above handles them before tmp_path validation.
    if ( my $existing = $_IN_FLIGHT{$cache_key} ) {
        push @{ $existing->{waiters} }, { on_complete => $on_complete, on_error => $on_error };
        $log->debug("SlimPing: ExternalProcess waiter registered for $cache_key");
        return 2;
    }

    # Only validate tmp_path for actual transcode starts (not waiters).
    return 0 unless $tmp_path;

    # Create a pipe for completion detection.  The write-end is held open
    # by the child process.  When the child exits the kernel closes it,
    # delivering EOF on the read-end which fires the addRead callback
    # through LMS's EV event loop.
    #
    # $^F controls which FDs survive exec().  Default is 2 (only stdin/
    # stdout/stderr survive).  We bump it so the pipe FDs survive.
    local $^F = 999;
    pipe(my $read_fh, my $write_fh);

    my $pid = fork();
    unless (defined $pid) {
        close($read_fh);
        close($write_fh);
        $log->error("SlimPing: ExternalProcess fork failed: $!");
        $on_error->("fork failed: $!");
        return 1;
    }

    if ($pid == 0) {
        # --- CHILD ---
        close($read_fh);
        eval { Plugins::SlimPing::Schema->disconnect(); };
        _execChild( $cmd,
            keep_fds => [ fileno($write_fh) ],
        );
    }

    # --- PARENT ---
    # Close the write-end.  The only remaining write-end is in the child.
    # When the child exits the kernel closes it, producing EOF on $read_fh.
    close($write_fh);

    my $entry = {
        pid           => $pid,
        tmp_path      => $tmp_path,
        cache_key     => $cache_key,
        cache_sq_id   => $cache_sq_id,
        cache_suffix  => $cache_suffix,
        read_fh       => $read_fh,
        on_complete   => $on_complete,
        on_error      => $on_error,
        waiters       => [],
        httpClient    => $httpClient,
        response      => $response,
        timeout_s     => $timeout_s,
        started_at    => time(),
        fired         => 0,
        timer         => undef,
        close_handler => undef,
        stuck_sweeps  => 0,
    };
    $_IN_FLIGHT{$cache_key} = $entry;

    # Register the pipe read-end with LMS's EV event loop.  addRead
    # creates an EV I/O watcher; when the child exits and the pipe gets
    # EOF, EV fires the callback from within its normal event dispatch.
Slim::Networking::Select::addRead($read_fh, sub { _onChildExit($cache_key); });

    # Arm the one-shot timeout.  If the child hasn't exited by the
    # timeout, we kill it -- the resulting pipe EOF will fire the
    # addRead callback which handles cleanup.
    $entry->{timer} = Slim::Utils::Timers::setTimer(
        undef, time() + $timeout_s, sub { _handleTimeout($cache_key); }
    );

    if ($httpClient) {
        $entry->{close_handler} = sub {
            my ($closedClient) = @_;
            return unless $closedClient && $closedClient eq $httpClient;
            _cleanupEntry($cache_key, 'client disconnect');
        };
        push @Slim::Web::HTTP::closeHandlers, $entry->{close_handler};
    }

    $log->debug("SlimPing: ExternalProcess spawned pid=$pid key=$cache_key");
    return 1;
}

# Fork two or three child processes connected by internal pipes — no shell.
# Stage 1 (decode) writes to pipe 1; optional stage 2 (intermediate) reads
# from pipe 1 and writes to pipe 2; final stage (encode) reads from the last
# pipe and writes output to $tmp_path.  Completion is detected via pipe EOF
# from the encode child (same mechanism as spawn).
#
# Required args (same as spawn, plus):
#   cmd_decode       => [$bin, @args]    (writes to STDOUT)
#   cmd_encode       => [$bin, @args]    (reads from STDIN, writes to $tmp_path)
#   cmd_intermediate => [$bin, @args]    (optional middle stage, reads from
#                                         STDIN, writes to STDOUT)
sub spawnPipeline {
    my ($class, %args) = @_;

    my $cmd_decode      = $args{cmd_decode};
    my $cmd_encode      = $args{cmd_encode};
    my $cmd_intermediate = $args{cmd_intermediate};
    my $tmp_path         = $args{tmp_path};
    my $cache_key        = $args{cache_key};
    my $cache_sq_id      = $args{cache_sq_id};
    my $cache_suffix     = $args{cache_suffix};
    my $timeout_s        = $args{timeout_s}   // 120;
    my $on_complete      = $args{on_complete};
    my $on_error         = $args{on_error};
    my $httpClient       = $args{httpClient};
    my $response         = $args{response};

    my $three_stage = defined $cmd_intermediate
        && ref $cmd_intermediate eq 'ARRAY' && @$cmd_intermediate;

    unless ($_CAN_FORK) {
        $log->error("SlimPing: spawnPipeline called but fork unavailable");
        $on_error->("platform unsupported") if $on_error;
        return 0;
    }

    return 0 unless $cache_key;
    return 0 unless $on_complete && $on_error;

    # In-flight dedup — same as spawn().  Must sit before cmd/tmp_path
    # validation so waiter callers (which pass empty commands and path)
    # can register on an existing transcode instead of starting a duplicate.
    if ( my $existing = $_IN_FLIGHT{$cache_key} ) {
        push @{ $existing->{waiters} }, { on_complete => $on_complete, on_error => $on_error };
        $log->debug("SlimPing: spawnPipeline waiter registered for $cache_key");
        return 2;
    }

    # Remaining validation only applies to actual transcode starts.
    return 0 unless $cmd_decode && ref $cmd_decode eq 'ARRAY' && @$cmd_decode;
    return 0 unless $cmd_encode && ref $cmd_encode eq 'ARRAY' && @$cmd_encode;
    return 0 unless $tmp_path;

    local $^F = 999;

    # Create IPC pipe 1 (decode → intermediate or encode).
    pipe(my $ipc1_read, my $ipc1_write);

    # Create IPC pipe 2 (intermediate → encode), only for three-stage.
    my ( $ipc2_read, $ipc2_write );
    if ($three_stage) {
        pipe($ipc2_read, $ipc2_write);
    }

    # Create completion pipe — write end held by encode child.
    pipe(my $comp_read, my $comp_write);

    # --- Fork decode child (stage 1) ---
    my $decode_pid = _forkExecChild(
        'decode', $cmd_decode,
        stdin_fd   => undef,
        stdout_fd  => fileno($ipc1_write),
        keep_fds   => [ fileno($ipc1_write) ],
    );
    unless (defined $decode_pid) {
        close($_) for ( grep defined, $ipc1_read, $ipc1_write,
            $ipc2_read, $ipc2_write, $comp_read, $comp_write );
        $log->error("SlimPing: spawnPipeline decode fork failed: $!");
        $on_error->("decode fork failed: $!");
        return 1;
    }

    close($ipc1_write);

    # --- Fork intermediate child (stage 2, optional) ---
    my $intermediate_pid;
    if ($three_stage) {
        $intermediate_pid = _forkExecChild(
            'intermediate', $cmd_intermediate,
            stdin_fd  => fileno($ipc1_read),
            stdout_fd => fileno($ipc2_write),
            keep_fds  => [ fileno($ipc1_read), fileno($ipc2_write) ],
        );
        unless (defined $intermediate_pid) {
            close($_) for ( grep defined, $ipc1_read, $ipc2_read, $ipc2_write,
                $comp_read, $comp_write );
            kill('TERM', $decode_pid);
            waitpid($decode_pid, 0);
            $log->error("SlimPing: spawnPipeline intermediate fork failed: $!");
            $on_error->("intermediate fork failed: $!");
            return 1;
        }
        close($ipc1_read);
        close($ipc2_write);
    }

    # --- Fork encode child (final stage) ---
    my $enc_stdin_fd = $three_stage ? fileno($ipc2_read) : fileno($ipc1_read);
    my $encode_pid = _forkExecChild(
        'encode', $cmd_encode,
        stdin_fd   => $enc_stdin_fd,
        keep_fds   => [ $enc_stdin_fd, fileno($comp_write) ],
    );
    unless (defined $encode_pid) {
        close($_) for ( grep defined, $three_stage ? $ipc2_read : $ipc1_read,
            $comp_read, $comp_write );
        kill('TERM', $decode_pid);
        waitpid($decode_pid, 0);
        if ($intermediate_pid) {
            kill('TERM', $intermediate_pid);
            waitpid($intermediate_pid, 0);
        }
        $log->error("SlimPing: spawnPipeline encode fork failed: $!");
        $on_error->("encode fork failed: $!");
        return 1;
    }

    close($three_stage ? $ipc2_read : $ipc1_read);
    close($comp_write);

    # --- Parent: register entry and completion watcher ---
    my $entry = {
        pid              => $encode_pid,
        decode_pid       => $decode_pid,
        intermediate_pid => $intermediate_pid,
        tmp_path         => $tmp_path,
        cache_key        => $cache_key,
        cache_sq_id      => $cache_sq_id,
        cache_suffix     => $cache_suffix,
        read_fh          => $comp_read,
        on_complete      => $on_complete,
        on_error         => $on_error,
        waiters          => [],
        httpClient       => $httpClient,
        response         => $response,
        timeout_s        => $timeout_s,
        started_at       => time(),
        fired            => 0,
        timer            => undef,
        close_handler    => undef,
        stuck_sweeps     => 0,
    };
    $_IN_FLIGHT{$cache_key} = $entry;

Slim::Networking::Select::addRead($comp_read, sub { _onChildExit($cache_key); });

    $entry->{timer} = Slim::Utils::Timers::setTimer(
        undef, time() + $timeout_s, sub { _handleTimeout($cache_key); }
    );

    if ($httpClient) {
        $entry->{close_handler} = sub {
            my ($closedClient) = @_;
            return unless $closedClient && $closedClient eq $httpClient;
            _cleanupEntry($cache_key, 'client disconnect');
        };
        push @Slim::Web::HTTP::closeHandlers, $entry->{close_handler};
    }

    $log->debug("SlimPing: spawnPipeline decode_pid=$decode_pid "
        . ( $intermediate_pid ? "intermediate_pid=$intermediate_pid " : '' )
        . "encode_pid=$encode_pid key=$cache_key");
    return 1;
}

# Fork a child and call _execChild in it.  Used by spawnPipeline.
sub _forkExecChild {
    my ($label, $cmd, %opts) = @_;
    my $pid = fork();
    return $pid unless defined $pid && $pid == 0;
    _execChild($cmd, %opts);
}

# Prepare a forked child for exec: optionally redirect stdin/stdout, redirect
# stderr to a temp log, close all other inherited FDs, reset signal handlers,
# and exec @$cmd.  Does NOT fork - the caller must have forked.
#
#   stdin_fd    - fd to dup2 to STDIN (undef = leave as-is)
#   stdout_fd   - fd to dup2 to STDOUT (undef = leave as-is)
#   output_path - if set and stdout_fd is undef, open this file for STDOUT
#   keep_fds    - arrayref of additional fds to preserve
sub _execChild {
    my ($cmd, %opts) = @_;
    my $stdin_fd    = $opts{stdin_fd};
    my $stdout_fd   = $opts{stdout_fd};
    my $output_path = $opts{output_path};
    my $keep_fds    = $opts{keep_fds} // [];

    if ( defined $stdin_fd ) {
        POSIX::dup2( $stdin_fd, fileno(STDIN) );
        POSIX::close($stdin_fd) unless $stdin_fd == fileno(STDIN);
    }

    if ( defined $stdout_fd ) {
        POSIX::dup2( $stdout_fd, fileno(STDOUT) );
        POSIX::close($stdout_fd) unless $stdout_fd == fileno(STDOUT);
    } elsif ( defined $output_path ) {
        open( my $out_fh, '>', $output_path ) or POSIX::_exit(127);
        POSIX::dup2( fileno($out_fh), fileno(STDOUT) );
        POSIX::close($out_fh);
    }

    # Redirect stderr to a temp log.  Include $$ (child PID after fork)
    # so concurrent spawnPipeline children don't collide on filenames.
    my $err_path = Slim::Utils::Misc::getTempDir() . '/slimping_err_'
      . time() . '_' . $$ . '_' . int( rand(999999) ) . '.log';
    my $err_fh;
    open( $err_fh, '>>', $err_path )
      or open( $err_fh, '>>', '/tmp/slimping_err.log' );
    POSIX::dup2( fileno($err_fh), fileno(STDERR) );
    my $err_fd = fileno($err_fh);

    # Build set of FDs to preserve: redirected stdin/stdout, stderr log,
    # and any caller-specified extras (e.g. completion pipe write-end).
    my %keep = map { $_ => 1 } (
        ( defined $stdin_fd  ? fileno(STDIN)  : () ),
        ( defined $stdout_fd || defined $output_path ? fileno(STDOUT) : () ),
        $err_fd,
        @$keep_fds,
    );

    if ( opendir( my $fd_dir, '/proc/self/fd' ) ) {
        for my $entry ( readdir($fd_dir) ) {
            next unless $entry =~ /^\d+$/;
            my $fd = int($entry);
            next if $fd < 3 || $keep{$fd};
            POSIX::close($fd);
        }
        closedir($fd_dir);
    } else {
        for my $fd ( 3 .. 1023 ) {
            next if $keep{$fd};
            POSIX::close($fd);
        }
    }

    eval { untie(*STDERR); };
    for my $sig (keys %SIG) {
        next if $sig eq '__WARN__' || $sig eq '__DIE__';
        $SIG{$sig} = 'DEFAULT';
    }
    exec(@$cmd) or POSIX::_exit(127);
}

# --- Completion callback (fired by addRead via EV event loop) -----------------
# --- Completion callback (fired by addRead via EV event loop) -----------------

sub _onChildExit {
    my ($cache_key) = @_;
    my $entry = $_IN_FLIGHT{$cache_key};

    # Entry may have been cleaned up by a different path (close-handler,
    # timeout, maintenance sweep, killAll).
    unless ($entry) {
        return;
    }

    # Remove the EV I/O watcher for the pipe.
Slim::Networking::Select::removeRead($entry->{read_fh});

    # Cancel the timeout timer -- child already exited.
    Slim::Utils::Timers::killTimers(undef, $entry->{timer})
      if $entry->{timer};

    # Close the pipe read-end.
    close(delete $entry->{read_fh});

    # Reap the child.
    my $pid = $entry->{pid};
    my $ret = waitpid($pid, &WNOHANG);

    if ($ret == $pid) {
        _handleExit($cache_key, $ret, $?);
        return;
    }

    if ($ret == 0) {
        # Child still running but pipe got EOF?  Unusual -- the child
        # may have explicitly closed the write-end.  Block-wait briefly.
        $ret = waitpid($pid, 0);
        if ($ret == $pid) {
            _handleExit($cache_key, $ret, $?);
            return;
        }
        _fireError($cache_key, 'pipe EOF but child still alive after block-wait');
        return;
    }

    if ($ret == -1) {
        if ($!{ECHILD}) {
            # Another handler reaped our child.  Treat as success if
            # the temp file is non-empty.
            if (-f $entry->{tmp_path} && -s $entry->{tmp_path}) {
                _fireComplete($cache_key);
            } else {
                _fireError($cache_key, 'ECHILD - child reaped externally, no output');
            }
        } else {
            _fireError($cache_key, "waitpid error: $!");
        }
        return;
    }
}

# --- Exit / error handling ----------------------------------------------------

sub _handleExit {
    my ($cache_key, $pid, $status) = @_;
    my $entry = $_IN_FLIGHT{$cache_key};
    return unless $entry;

    # Reap any earlier pipeline stages.  Earlier stages should already have
    # exited — SIGPIPE from downstream closing IPC, or normal EOF.
    for my $extra_pid ( grep defined, $entry->{decode_pid}, $entry->{intermediate_pid} ) {
        my $ret = waitpid( $extra_pid, &WNOHANG );
        if ( $ret <= 0 ) {
            kill('TERM', $extra_pid);
            Slim::Utils::Timers::setTimer( undef, time() + 1.0, sub {
                my $r = waitpid( $extra_pid, &WNOHANG );
                kill('KILL', $extra_pid) if $r == 0;
                waitpid( $extra_pid, 0 );
            });
        }
    }

    if ($status == 0) {
        if (-f $entry->{tmp_path} && -s $entry->{tmp_path}) {
            _fireComplete($cache_key);
        } else {
            _fireError($cache_key, 'child exited 0 but output file empty');
        }
    } elsif ($status & 127) {
        my $sig = $status & 127;
        _fireError($cache_key, "child killed by signal $sig");
    } else {
        my $exit_code = $status >> 8;
        _fireError($cache_key, "child exited $exit_code");
    }
}

sub _handleTimeout {
    my ($cache_key) = @_;
    my $entry = $_IN_FLIGHT{$cache_key};
    return unless $entry;

    $log->warn("SlimPing: ExternalProcess timeout for $cache_key (pid=$entry->{pid})");

    # SIGTERM with 2s grace, then SIGKILL.
    # When the child dies the pipe write-end closes, EOF fires the
    # addRead callback which handles cleanup via _onChildExit.
    kill('TERM', $entry->{pid});
    Slim::Utils::Timers::setTimer(undef, time() + 2.0, sub {
        my $ret = waitpid($entry->{pid}, &WNOHANG);
        if ($ret == 0) {
            kill('KILL', $entry->{pid});
            waitpid($entry->{pid}, 0);
        }
        # Pipe EOF will fire addRead -> _onChildExit, which calls _fireError.
        # As a backstop, fire directly if the entry somehow still exists.
        $entry = $_IN_FLIGHT{$cache_key};
        _fireError($cache_key, 'timeout') if $entry;
    });
}

# --- Callback dispatch --------------------------------------------------------

sub _fireComplete {
    my ($cache_key) = @_;
    my $entry = delete $_IN_FLIGHT{$cache_key};
    return unless $entry;
    return if $entry->{fired}++;

    # Clean up any remaining event-loop resources.
Slim::Networking::Select::removeRead($entry->{read_fh})    if $entry->{read_fh};
    close($entry->{read_fh})         if $entry->{read_fh};
    Slim::Utils::Timers::killTimers(undef, $entry->{timer})
      if $entry->{timer};

    _removeCloseHandler($entry);

    # Resolve the serve path ONCE before firing any callbacks.
    # finishFormatOutput handles the temp->cache rename, metadata write,
    # inflight marker clearing, and size tracking in a single call.
    # When cache_sq_id is not set (legacy callers), serve from temp directly.
    my $serve_path = $entry->{tmp_path};
    if ( $entry->{cache_sq_id} ) {
        eval {
            require Plugins::SlimPing::Core::TranscodeCache;
            $serve_path = Plugins::SlimPing::Core::TranscodeCache->getInstance
              ->finishFormatOutput(
                $entry->{cache_sq_id}, $entry->{tmp_path},
                $entry->{cache_suffix} || 'tmp'
              );
        };
        if ($@) {
            $log->warn("SlimPing: finishFormatOutput error for $cache_key: $@");
        }
    }

    $entry->{on_complete}->($serve_path);

    for my $w ( @{ $entry->{waiters} } ) {
        $w->{on_complete}->($serve_path);
    }
}

sub _fireError {
    my ($cache_key, $reason) = @_;
    my $entry = delete $_IN_FLIGHT{$cache_key};
    return unless $entry;
    return if $entry->{fired}++;

    # Clean up any remaining event-loop resources.
Slim::Networking::Select::removeRead($entry->{read_fh})    if $entry->{read_fh};
    close($entry->{read_fh})         if $entry->{read_fh};
    Slim::Utils::Timers::killTimers(undef, $entry->{timer})
      if $entry->{timer};

    _removeCloseHandler($entry);

    # Discard any partial output and clear the TranscodeCache inflight
    # marker so the next request starts a fresh transcode.
    if ( $entry->{cache_sq_id} ) {
        eval {
            require Plugins::SlimPing::Core::TranscodeCache;
            Plugins::SlimPing::Core::TranscodeCache->getInstance
              ->discardFormatOutput(
                $entry->{cache_sq_id}, $entry->{tmp_path},
                $entry->{cache_suffix} || 'tmp'
              );
        };
    }
    elsif ( $entry->{tmp_path} && -f $entry->{tmp_path} ) {
        unlink($entry->{tmp_path});
    }

    $log->warn("SlimPing: ExternalProcess error for $cache_key: $reason");

    # Fire error callbacks for the original caller AND all waiters.
    # Each waiter is a separate HTTP client that needs a response --
    # dropping them silently leaves connections hanging until timeout.
    # DSD on_error now returns a Subsonic error (no DirectPipeline fallback),
    # so firing N+1 callbacks is safe and cheap.
    $entry->{on_error}->($reason);
    for my $w ( @{ $entry->{waiters} } ) {
        $w->{on_error}->($reason);
    }
    undef $entry->{waiters};
}

sub _removeCloseHandler {
    my ($entry) = @_;
    return unless $entry->{close_handler};
    @Slim::Web::HTTP::closeHandlers = grep {
        $_ ne $entry->{close_handler}
    } @Slim::Web::HTTP::closeHandlers;
}

# --- Orphaned temp file cleanup -----------------------------------------------

sub _cleanupOrphanedTempFiles {
    my $tmp_dir = Slim::Utils::Misc::getTempDir();
    return unless defined $tmp_dir && -d $tmp_dir;
    my $now   = time();
    my $count = 0;
    opendir( my $dh, $tmp_dir ) or return;
    for my $f ( readdir($dh) ) {
        next unless $f =~ /^slimping_(out|xfmt|cue|err)_/;
        my $full = "$tmp_dir/$f";
        next unless -f $full;
        my $age = $now - ( ( stat($full) )[9] // $now );
        next unless $age > 7200;  # 2 h -- safe for 45+ min DSD tracks
        unlink($full);
        $count++;
    }
    closedir($dh);
    $log->info("SlimPing: ExternalProcess cleaned up $count orphaned temp files") if $count;
}

# --- Maintenance sweep --------------------------------------------------------

# Counter for periodic temp-file cleanup.  Runs every 20 sweeps (10 minutes)
# with a 2-hour age threshold -- safe for 45+ minute DSD tracks.  This is a
# safety net; under normal operation the disk cache is enabled and temp files
# are renamed into the cache directory (no cleanup needed).
my $_maintenance_ticks = 0;

sub _startMaintenanceSweep {
    Slim::Utils::Timers::setTimer(
        undef, time() + MAINTENANCE_INTERVAL, \&_maintenanceSweep
    );
}

sub _maintenanceSweep {
    my $count = 0;
    for my $key (keys %_IN_FLIGHT) {
        my $e = $_IN_FLIGHT{$key};
        next unless $e && $e->{pid};
        my $ret = waitpid($e->{pid}, &WNOHANG);
        if ($ret == -1 && $!{ECHILD}) {
            _cleanupEntry($key, 'ECHILD sweep');
            $count++;
        } elsif ($ret > 0) {
            _handleExit($key, $ret, $?);
            $count++;
        } elsif ($ret == 0) {
            # Process still running.  Track how long it has been stuck.
            # D-state (uninterruptible I/O — stale NFS mount, defective
            # block device) prevents SIGTERM/SIGKILL from working and
            # waitpid() returns 0 indefinitely.
            $e->{stuck_sweeps}++;
            if ( $e->{stuck_sweeps} >= 10 ) {   # 10 sweeps = 5 minutes
                $log->warn("SlimPing: pid $e->{pid} stuck for $e->{stuck_sweeps} sweeps"
                    . " — child may be in uninterruptible I/O, forcibly cleaning $key");
                _fireError($key, "child stuck in D-state after $e->{stuck_sweeps} sweeps");
                $count++;
            }
        }
    }
    $log->debug("SlimPing: maintenance sweep cleaned $count entries") if $count;

    if ( ++$_maintenance_ticks % 20 == 0 ) {
        _cleanupOrphanedTempFiles();
    }

    _startMaintenanceSweep();
}

# --- Cleanup ------------------------------------------------------------------

sub _cleanupEntry {
    my ($key, $reason) = @_;
    my $e = delete $_IN_FLIGHT{$key};
    return unless $e;

    # Remove EV watcher and close pipe.
    Slim::Networking::Select::removeRead($e->{read_fh}) if $e->{read_fh};
    close($e->{read_fh})         if $e->{read_fh};
    Slim::Utils::Timers::killTimers(undef, $e->{timer})
      if $e->{timer};

    if ($e->{pid}) {
        kill('TERM', $e->{pid});
        Slim::Utils::Timers::setTimer(undef, time() + 2.0, sub {
            my $ret = waitpid($e->{pid}, &WNOHANG);
            if ($ret == 0) {
                kill('KILL', $e->{pid});
                waitpid($e->{pid}, 0);
            }
        });
    }
    for my $extra_pid ( grep defined, $e->{decode_pid}, $e->{intermediate_pid} ) {
        kill('TERM', $extra_pid);
        Slim::Utils::Timers::setTimer( undef, time() + 2.0, sub {
            my $r = waitpid( $extra_pid, &WNOHANG );
            kill('KILL', $extra_pid) if $r == 0;
            waitpid( $extra_pid, 0 );
        });
    }

    # Discard any partial output via the TranscodeCache API so the
    # inflight marker is cleared.  Falls back to manual unlink when
    # the caller did not provide cache coordinates (legacy path).
    if ( $e->{cache_sq_id} ) {
        eval {
            require Plugins::SlimPing::Core::TranscodeCache;
            Plugins::SlimPing::Core::TranscodeCache->getInstance
              ->discardFormatOutput(
                $e->{cache_sq_id}, $e->{tmp_path},
                $e->{cache_suffix} || 'tmp'
              );
        };
    }
    elsif ( $e->{tmp_path} && -f $e->{tmp_path} ) {
        unlink($e->{tmp_path});
    }

    $log->debug("SlimPing: ExternalProcess cleanup $key ($reason)");
}

sub killAll {
    for my $key (keys %_IN_FLIGHT) {
        _cleanupEntry($key, 'killAll/shutdown');
    }
}

1;
