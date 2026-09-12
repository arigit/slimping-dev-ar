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
# Core/StreamGate.pm - Shared validation gates for overlay stream/metadata handlers
#
# Stateless class methods for the boilerplate preamble every overlay handler
# repeats: feature toggle, rate-limit gate, required-parameter extraction, and
# rate-limit clear-on-success.  Used by shareStream, shareMetadata, radioStream,
# and radioMetadata.
#

package Plugins::SlimPing::Core::StreamGate;

use strict;
use warnings;

# Returns 1 (and sends error) if $feature_name is disabled, so callers can:
#   return if requireFeature(...);
# Returns 0 if the feature is enabled and the handler should continue.
sub requireFeature {
    my ( $class, $httpClient, $response, $feature_name, $label ) = @_;
    return 0
      if Plugins::SlimPing::Core::Logging->isFeatureEnabled($feature_name);
    require Plugins::SlimPing::Core::VirtualPlayer;
    Plugins::SlimPing::Core::VirtualPlayer->sendStreamError(
        $httpClient, $response, 0, "Not implemented: $label" );
    return 1;
}

# Rate-limit gate.  Returns ($ip) on pass; on fail, sends error and returns
# empty list so callers can write:
#   my ($ip) = StreamGate->gateIp($httpClient, $response, $request) or return;
sub gateIp {
    my ( $class, $httpClient, $response, $request ) = @_;
    require Plugins::SlimPing::Auth::RateLimit;
    require Plugins::SlimPing::Core::VirtualPlayer;
    my $ip =
      Plugins::SlimPing::Core::VirtualPlayer->remoteIp( $httpClient, $request );
    if ( Plugins::SlimPing::Auth::RateLimit->isLocked( $ip, '_anon' ) ) {
        Plugins::SlimPing::Core::VirtualPlayer->sendStreamError(
            $httpClient, $response, 40,
            'Too many failed attempts - try again later' );
        return ();
    }
    return ($ip);
}

# Required-parameter gate.  Returns ($value) on pass; on fail, records a
# rate-limit failure, sends error, and returns empty list so callers can write:
#   my ($sq_id) = StreamGate->requireParam(
#       httpClient => $httpClient, response => $response,
#       ip => $ip, value => $p->{sq_id}, param_name => 'sq_id' ) or return;
sub requireParam {
    my $class     = shift;
    my %args      = @_;
    my $httpClient = $args{httpClient} or die 'requireParam: httpClient required';
    my $response  = $args{response}   or die 'requireParam: response required';
    my $ip        = $args{ip};
    my $value     = $args{value};
    my $paramName = $args{param_name};

    return ($value) if defined $value && length $value;
    require Plugins::SlimPing::Auth::RateLimit;
    require Plugins::SlimPing::Core::VirtualPlayer;
    Plugins::SlimPing::Auth::RateLimit->recordFailure( $ip, '_anon' );
    Plugins::SlimPing::Core::VirtualPlayer->sendStreamError(
        $httpClient, $response, 10,
        "Required parameter $paramName is missing" );
    return ();
}

# Clear the '_anon' rate-limit bucket for this IP after successful validation.
sub clearGate {
    my ( $class, $ip ) = @_;
    require Plugins::SlimPing::Auth::RateLimit;
    Plugins::SlimPing::Auth::RateLimit->clearSuccess( $ip, '_anon' );
}

1;
