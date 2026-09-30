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
# API/DeferredResponse.pm - opt-in deferred HTTP responses
#
# A handler normally answers synchronously: it returns a result, and
# Router::dispatch renders it and writes the response.  A handler whose data
# arrives from a callback cannot do that, so it opts in through the request
# args:
#
#     my $done = $args->{defer}->();        # registers the pending response
#
#     $provider->{similarTracks}->( $track, $count, $ctx, sub {
#         my ($rows) = @_;
#         $done->( sub { { sonicMatch => [ ... ] } } );
#     } );
#
#     return;                                # dispatch stops here
#
# The completion takes a *builder* rather than a finished result because
# building an OpenSubsonic payload needs the request's identity: the current
# user, the request base URL and the client name are module-level state that
# Router::dispatch sets per request, and another request overwrites them long
# before a provider calls back.  The builder runs after that identity has been
# restored, so the payload is shaped for the requester rather than for whoever
# happened to be dispatched last.
#
# Three rails keep a pending response from becoming a leak or a corruption:
#
#   - completion is once-only, so a provider that calls back twice -- or calls
#     back after the watchdog has already answered -- is a no-op rather than a
#     second response on the same socket
#   - a watchdog timer answers on the provider's behalf if it never calls back
#   - a client that has disconnected has its pending entry dropped, so a late
#     callback does not write into a closed socket
#
# The watchdog is deliberately short (10s by default, capped at 60s): LMS arms
# its own 75s keep-alive close for the socket, and the response has to be on
# the wire well before that.  A handler that wants its own graceful fallback
# passes it as timeout_result; without one the client gets an error envelope.
#
# A deferred handler still runs on the single-threaded server loop, so this
# buys nothing for a provider that blocks: it only helps one that is genuinely
# event-driven.
#

package Plugins::SlimPing::API::DeferredResponse;

use strict;
use warnings;

use Plugins::SlimPing::Core::Logging;

my $log = Plugins::SlimPing::Core::Logging->getLogger();

use constant DEFAULT_TIMEOUT_SECS => 10;
use constant MAX_TIMEOUT_SECS     => 60;

# token => { token, label, http_client, context, finalise, timeout_result,
#            completed, timeout }
my %_pending;

my $_next_token = 0;

# The close handler is global in LMS (it is called with the closing client), so
# it is registered once rather than per request.
my $_close_handler_registered = 0;

# Register a pending response.  Returns the completion coderef; call it once
# with a builder coderef (or a plain result) when the data is ready.
#
#   httpClient     => the request's HTTP client, for disconnect detection
#   context        => sub {}  re-establishes request-scoped identity
#   finalise       => sub { my ($result) = @_; }  renders and writes
#   timeout        => optional seconds; defaults to 10, capped at 60
#   timeout_result => optional plain result sent when the provider never calls
#   label          => optional endpoint name for logging
sub defer {
    my ( $class, %args ) = @_;

    my $finalise = $args{finalise};
    die 'DeferredResponse: finalise is required' unless ref $finalise eq 'CODE';

    my $timeout = $args{timeout} // DEFAULT_TIMEOUT_SECS;
    $timeout = DEFAULT_TIMEOUT_SECS if $timeout <= 0;
    $timeout = MAX_TIMEOUT_SECS     if $timeout > MAX_TIMEOUT_SECS;

    my $token = ++$_next_token;

    $_pending{$token} = {
        token          => $token,
        label          => $args{label} || 'request',
        http_client    => $args{httpClient},
        context        => $args{context},
        finalise       => $finalise,
        timeout_result => $args{timeout_result},
        timeout        => $timeout,
        completed      => 0,
    };

    _registerCloseHandler();
    _armWatchdog( $token, $timeout );

    return sub { _complete( $token, @_ ) };
}

# Number of responses still waiting on a provider (diagnostics and tests).
sub pendingCount {
    my ($class) = @_;
    return scalar keys %_pending;
}

# Timer entry point: the provider never called back in time, so answer the
# client with the handler's fallback (or an error envelope).
sub _watchdog {
    my ($token) = @_;

    my $entry = $_pending{$token} or return 0;

    $log->warn(
        'SlimPing: deferred ' . $entry->{label} . ' timed out after ' . $entry->{timeout} . 's' );

    return _complete( $token, $entry->{timeout_result} );
}

# Completion.  Once-only: after this, the token is gone and later calls -- a
# second provider callback, or one arriving after the watchdog -- are ignored.
sub _complete {
    my ( $token, $builder ) = @_;

    my $entry = $_pending{$token} or return 0;
    return 0 if $entry->{completed};

    $entry->{completed} = 1;
    delete $_pending{$token};

    # A client that has gone away cannot be answered; writing into the socket
    # would corrupt LMS's connection accounting.
    my $client = $entry->{http_client};
    if ( $client && !$client->connected() ) {
        $log->debug( 'SlimPing: deferred ' . $entry->{label} . ' dropped -- client disconnected' );
        return 0;
    }

    return _answer( $entry, $builder );
}

# Restore the request context, build the payload, hand it to the Router's
# finaliser.  Errors are contained: a dying builder becomes an error envelope
# rather than a request that never answers.
sub _answer {
    my ( $entry, $builder ) = @_;

    my $context = $entry->{context};
    if ( ref $context eq 'CODE' ) {
        eval { $context->() };
        if ($@) {
            my $error = $@;
            chomp $error;
            $log->warn( 'SlimPing: deferred ' . $entry->{label} . " context restore failed: $error" );
        }
    }

    my $result;
    if ( ref $builder eq 'CODE' ) {
        $result = eval { $builder->() };
        if ($@) {
            my $error = $@;
            chomp $error;
            $log->warn( 'SlimPing: deferred ' . $entry->{label} . " builder failed: $error" );
            $result = undef;
        }
    }
    else {
        $result = $builder;
    }

    $result ||= { error => { code => 0, message => 'Deferred response produced no result' } };

    eval { $entry->{finalise}->($result) };
    if ($@) {
        my $error = $@;
        chomp $error;
        $log->warn( 'SlimPing: deferred ' . $entry->{label} . " response failed: $error" );
        return 0;
    }

    return 1;
}

# Drop pending responses for a client that has disconnected, so a late
# provider callback does not write into a dead socket.
sub _onClientClose {
    my ($httpClient) = @_;

    return unless $httpClient;

    for my $token ( keys %_pending ) {
        my $entry = $_pending{$token} or next;
        next unless $entry->{http_client} && $entry->{http_client} == $httpClient;

        $log->debug( 'SlimPing: deferred ' . $entry->{label} . ' abandoned -- client closed the socket' );
        $entry->{completed} = 1;
        delete $_pending{$token};
    }

    return;
}

sub _registerCloseHandler {
    return if $_close_handler_registered;

    require Slim::Web::HTTP;
    Slim::Web::HTTP::addCloseHandler( \&_onClientClose );
    $_close_handler_registered = 1;

    return;
}

sub _armWatchdog {
    my ( $token, $timeout ) = @_;

    require Slim::Utils::Timers;
    Slim::Utils::Timers::setTimer( undef, time() + $timeout, \&_watchdog, $token );

    return;
}

1;
