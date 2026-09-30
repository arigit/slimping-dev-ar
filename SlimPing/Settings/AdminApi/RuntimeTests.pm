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
# Settings/AdminApi/RuntimeTests.pm - run the in-server runtime tests
#
# GET plugins/SlimPing/settings/runtime_tests
#
# Synchronous by design: every suite under Tests/ is pure logic, so the whole
# run completes within the request and there is no test id or polling
# endpoint. Admin-gated like every other settings JSON endpoint.
#

package Plugins::SlimPing::Settings::AdminApi::RuntimeTests;

use strict;
use warnings;

use JSON::XS ();
use Slim::Web::HTTP;

use Plugins::SlimPing::Core::Logging;
use Plugins::SlimPing::Auth::AdminGate;
require Plugins::SlimPing::Tests::SelfTest;

my $log  = Plugins::SlimPing::Core::Logging->getLogger();
my $json = JSON::XS->new->utf8->allow_nonref;

sub handle {
    my ( $httpClient, $response ) = @_;

    my $request = $response->request();

    my ( $auth_ok, $err_code, $err_msg, $actor ) =
      Plugins::SlimPing::Auth::AdminGate::requireAdmin( $httpClient, $request, json_endpoint => 1 );
    return Plugins::SlimPing::Auth::AdminGate::denyAdmin( $httpClient, $response, $err_code, $err_msg )
      unless $auth_ok;

    my $method = $request->method();
    my ( $result, $status ) = ( {}, 200 );

    if ( $method eq 'GET' ) {
        my ( $summary, $results ) = Plugins::SlimPing::Tests::SelfTest->runAllSuites();
        $result = {
            ok      => ( $summary->{failed} > 0 ? 0 : 1 ),
            summary => $summary,
            results => $results,
        };
        $log->info( sprintf 'SlimPing runtime tests: %d checks, %d passed, %d failed',
            $summary->{checks}, $summary->{passed}, $summary->{failed} );
    }
    else {
        $status = 405;
        $result = { ok => 0, error => 'Method not allowed' };
    }

    my $body_json = $json->encode($result);
    $response->header( 'Content-Type'   => 'application/json; charset=utf-8' );
    $response->header( 'Content-Length' => length($body_json) );
    $response->code($status);
    Slim::Web::HTTP::addHTTPResponse( $httpClient, $response, \$body_json );
}

1;
