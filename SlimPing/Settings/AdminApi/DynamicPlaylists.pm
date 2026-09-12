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

package Plugins::SlimPing::Settings::AdminApi::DynamicPlaylists;

use strict;
use warnings;

use JSON::XS ();
use Slim::Web::HTTP;

use Plugins::SlimPing::Core::Logging;
use Plugins::SlimPing::Auth::AdminGate;
use Plugins::SlimPing::Utils::Params;

my $log   = Plugins::SlimPing::Core::Logging->getLogger();
my $prefs = Plugins::SlimPing::Core::Logging->getPrefs();
my $json  = JSON::XS->new->utf8->allow_nonref;

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
        require Plugins::SlimPing::Core::DynamicPlaylistBridge;
        my $bridge = Plugins::SlimPing::Core::DynamicPlaylistBridge->getInstance();

        $result = {
            feature_enabled => $prefs->get('dpl_feature_enabled') ? \1 : \0,
            dpl4_available  => $bridge->isAvailable() ? \1 : \0,
            eligible_count  => $bridge->getExposureCount(),
            eligible_names  => $bridge->getExposureNames(),
            cache_ttl       => $prefs->get('dpl_cache_ttl_seconds') // 300,
            seed_size       => $prefs->get('dpl_seed_size') // 100,
        };
    }
    elsif ( $method eq 'POST' ) {
        my $p = eval { $json->decode( $request->content() ) } // {};

        if ( exists $p->{feature_enabled} ) {
            $prefs->set( 'dpl_feature_enabled', $p->{feature_enabled} ? 1 : 0 );
            $log->info( 'SlimPing: DPL exposure feature ' . ( $p->{feature_enabled} ? 'enabled' : 'disabled' ) );
        }

        if ( exists $p->{cache_ttl} ) {
            my $ttl = int( $p->{cache_ttl} // 300 );
            $ttl = 60  if $ttl < 60;
            $ttl = 3600 if $ttl > 3600;
            $prefs->set( 'dpl_cache_ttl_seconds', $ttl );
        }

        if ( exists $p->{seed_size} ) {
            my $size = int( $p->{seed_size} // 100 );
            $size = 20  if $size < 20;
            $size = 500 if $size > 500;
            $prefs->set( 'dpl_seed_size', $size );
        }

        if ( $p->{reset_caches} ) {
            require Plugins::SlimPing::Core::DynamicPlaylistBridge;
            my $bridge = Plugins::SlimPing::Core::DynamicPlaylistBridge->getInstance();
            $bridge->clearCaches();
            $result->{caches_cleared} = \1;
        }

        if ( $p->{refresh_registry} ) {
            require Plugins::SlimPing::Core::DynamicPlaylistBridge;
            my $bridge = Plugins::SlimPing::Core::DynamicPlaylistBridge->getInstance();
            $bridge->refreshRegistry();
            $result->{registry_refreshed} = \1;
            $result->{eligible_count} = $bridge->getExposureCount();
        }

        $result->{feature_enabled} = $prefs->get('dpl_feature_enabled') ? \1 : \0;
    }
    else {
        ( $result, $status ) = ( { error => 'Method not allowed' }, 405 );
    }

    my $body = $json->encode($result);
    $response->header( 'Content-Type'   => 'application/json; charset=utf-8' );
    $response->header( 'Content-Length' => length($body) );
    $response->code($status);
    Slim::Web::HTTP::addHTTPResponse( $httpClient, $response, \$body );
}

1;
