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
# Tests/DeferredResponseTest.pm - the deferred provider contract
#
# Two things are covered here:
#
#   1. API/DeferredResponse.pm - the rails that stop a pending response from
#      becoming a leak or a corrupted connection: completion happens once, the
#      request context is restored before the payload is built, the watchdog
#      answers when a provider never calls back, a disconnected client is
#      dropped, and a builder that dies becomes an error envelope rather than a
#      request that never answers.
#   2. Handlers/Sonic.pm - an opt-in deferred provider is called with a
#      completion coderef, the handler returns without a result, and the
#      payload is built from the rows the provider eventually supplies.
#
# Nothing here touches the real listener registry: the provider is faked over
# SonicRegistry->bestProvider, because registerProvider is permanent by design
# and a test provider left behind would answer real sonic requests.
#

package Plugins::SlimPing::Tests::DeferredResponseTest;

use strict;
use warnings;

sub runChecks {
    my ($class) = @_;

    require Plugins::SlimPing::API::DeferredResponse;
    require Plugins::SlimPing::Handlers::Sonic;
    require Plugins::SlimPing::Core::SonicRegistry;
    require Slim::Utils::Timers;
    require Slim::Web::HTTP;

    my $DR = 'Plugins::SlimPing::API::DeferredResponse';

    my @checks;

    my $expect = sub {
        my ( $label, $ok, $detail ) = @_;
        push @checks, { label => $label, ok => $ok ? 1 : 0, detail => $detail };
        return;
    };

    # A fake HTTP client: connected() drives the disconnect rail.
    my $client = sub { return bless { connected => $_[0] }, 'DeferredResponseTest::Client' };

    # Register a pending response with a capturing finaliser.
    my $defer = sub {
        my (%args) = @_;
        my @sent;
        my $done = $DR->defer(
            label          => $args{label} || 'test',
            httpClient     => $args{client},
            context        => $args{context},
            timeout        => $args{timeout},
            timeout_result => $args{timeout_result},
            finalise       => sub { push @sent, $_[0]; },
        );
        return ( $done, \@sent );
    };

    # --- 1. completion is once-only ------------------------------------------

    {
        my $c = $client->(1);
        my ( $done, $sent ) = $defer->( client => $c );

        $done->( sub { return { ok => 1 } } );
        $done->( sub { return { ok => 2 } } );    # a second callback must not answer

        $expect->(
            'a deferred response answers once, whatever the provider does',
            @$sent == 1 && $sent->[0]{ok} == 1,
            @$sent == 1
              ? 'the second completion was ignored'
              : 'expected 1 response, got ' . @$sent,
        );
    }

    # --- 2. the builder runs after the request context is restored -----------

    {
        my @order;
        my $c = $client->(1);
        my ( $done, $sent ) = $defer->(
            client  => $c,
            context => sub { push @order, 'context' },
        );

        $done->( sub { push @order, 'builder'; return { ok => 1 } } );

        $expect->(
            'the payload builder runs with the request identity restored',
            join( ',', @order ) eq 'context,builder',
            'call order was ' . join( ',', @order ),
        );
    }

    # --- 3. the watchdog answers when the provider never calls back ----------

    {
        my $c = $client->(1);
        local @Slim::Utils::Timers::TIMERS = ();
        my ( $done, $sent ) = $defer->(
            client         => $c,
            timeout        => 5,
            timeout_result => { fallback => 1 },
        );

        my $armed = $Slim::Utils::Timers::TIMERS[-1];

        $armed->{cb}->( @{ $armed->{args} } ) if $armed;
        $done->( sub { return { late => 1 } } );    # arrives after the watchdog

        $expect->(
            'a provider that never calls back is answered by the watchdog',
            $armed && @$sent == 1 && $sent->[0]{fallback},
            !$armed       ? 'no watchdog timer was armed'
              : @$sent == 1 ? 'the fallback result was sent and the late builder ignored'
              :               'expected 1 response, got ' . @$sent,
        );
    }

    # --- 4. a disconnected client is not written to --------------------------

    {
        my $gone = $client->(0);
        my ( $done, $sent ) = $defer->( client => $gone );

        $done->( sub { return { ok => 1 } } );

        $expect->(
            'a response for a disconnected client is dropped',
            @$sent == 0,
            @$sent == 0 ? 'nothing written to a dead socket' : 'wrote to a closed socket',
        );
    }

    # --- 5. a dying builder becomes an error envelope ------------------------

    {
        my $c = $client->(1);
        my ( $done, $sent ) = $defer->( client => $c );

        $done->( sub { die "the provider returned nonsense\n" } );

        $expect->(
            'a builder that dies answers with an error envelope',
            @$sent == 1 && ref $sent->[0]{error} eq 'HASH' && defined $sent->[0]{error}{code},
            @$sent == 1 ? 'error envelope sent' : 'expected 1 response, got ' . @$sent,
        );
    }

    # --- 6. a client close drops only that client's entry --------------------

    {
        my $a = $client->(1);
        my $b = $client->(1);
        my ( $done_a, $sent_a ) = $defer->( client => $a, label => 'a' );
        my ( $done_b, $sent_b ) = $defer->( client => $b, label => 'b' );

        # A close handler, so the client is the first argument -- not a method
        # call.
        Plugins::SlimPing::API::DeferredResponse::_onClientClose($a);

        $done_a->( sub { return { a => 1 } } );
        $done_b->( sub { return { b => 1 } } );

        $expect->(
            'a client disconnect drops that request and leaves the others alone',
            @$sent_a == 0 && @$sent_b == 1,
            sprintf( 'dropped=%d other=%d', scalar @$sent_a, scalar @$sent_b ),
        );
    }

    # --- 7. nothing is left pending ------------------------------------------

    {
        my $pending = $DR->pendingCount();
        $expect->( 'the pending map drains', $pending == 0, "pending=$pending" );
    }

    # --- 8. a deferred provider is called with a completion ------------------

    {
        my $fake_track = bless { fake_id => 'tk1' }, 'DeferredResponseTest::Track';

        local *Plugins::SlimPing::Handlers::Sonic::_level        = sub { return 'similarity' };
        local *Plugins::SlimPing::Handlers::Sonic::_resolveTrack = sub { return $fake_track };
        local *Plugins::SlimPing::Handlers::Sonic::_sonicMatchEntry = sub {
            my ($row) = @_;
            return { entry => { id => $row->{track}{fake_id} }, similarity => $row->{similarity} };
        };

        my ( $provider_cb, $provider_args );
        local *Plugins::SlimPing::Core::SonicRegistry::bestProvider = sub {
            return {
                id            => 'fake_deferred',
                name          => 'Fake deferred provider',
                deferred      => 1,
                similarTracks => sub {
                    my ( $track, $count, $ctx, $cb ) = @_;
                    $provider_args = [ $track, $count, $ctx ];
                    $provider_cb   = $cb;
                    return;
                },
            };
        };

        my @builders;
        my $args = {
            params      => { id => 'sq_tr_1', count => 5 },
            user        => { username => 'u' },
            client_name => 'c',
            defer       => sub {
                return sub { my ($builder) = @_; push @builders, $builder };
            },
        };

        my $returned = Plugins::SlimPing::Handlers::Sonic::getSonicSimilarTracks($args);

        my $called_with_completion = $provider_cb && ref $provider_cb eq 'CODE';
        my $timeout_fallback = ref $args->{defer_timeout_result} eq 'HASH'
          && ref $args->{defer_timeout_result}{sonicMatch} eq 'ARRAY';

        $expect->(
            'a deferred provider is handed a completion and the handler returns no result',
            !defined $returned && $called_with_completion && $timeout_fallback,
            sprintf(
                'returned=%s completion=%s timeout_fallback=%s',
                defined $returned ? 'a result' : 'none',
                $called_with_completion ? 'yes' : 'no',
                $timeout_fallback ? 'yes' : 'no',
            ),
        );

        $provider_cb->( [ { track => { fake_id => 'tk1' }, similarity => 0.5 } ] );
        my $payload = @builders ? $builders[0]->() : undef;

        $expect->(
            'the deferred rows become the sonicMatch payload',
            $payload
              && $payload->{sonicMatch}[0]{entry}{id} eq 'tk1'
              && $payload->{sonicMatch}[0]{similarity} == 0.5,
            $payload
              ? sprintf( 'entries=%d', scalar @{ $payload->{sonicMatch} } )
              : 'no builder captured',
        );
    }

    return \@checks;
}

package DeferredResponseTest::Client;

sub connected { return $_[0]{connected} }

1;
