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

package Plugins::SlimPing::Settings::AdminApi::Shares;

use strict;
use warnings;

use JSON::XS ();
use Slim::Web::HTTP;

use Plugins::SlimPing::Core::Logging;
use Plugins::SlimPing::Auth::AdminGate;
use Plugins::SlimPing::Core::Audit;

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

    my $ip     = Plugins::SlimPing::Auth::AdminGate::remoteIp( $httpClient, $request );
    my $method = $request->method();
    my ( $result, $status ) = ( {}, 200 );

    require Plugins::SlimPing::Handlers::Sharing;

    if ( $method eq 'GET' ) {
        $result = { shares => { share => Plugins::SlimPing::Handlers::Sharing->getAllShares() } };
    }
    elsif ( $method eq 'POST' ) {
        my $body   = eval { $json->decode( $request->content() || '{}' ) };
        if ($@) {
            $log->warn("AdminApi: JSON decode failed: $@");
            my $err = { error => 'Invalid JSON body' };
            my $resp_body = $json->encode($err);
            $response->header('Content-Type'   => 'application/json; charset=utf-8');
            $response->header('Content-Length' => length($resp_body));
            $response->code(400);
            Slim::Web::HTTP::addHTTPResponse($httpClient, $response, \$resp_body);
            return;
        }
        $body //= {};
        my $action = $body->{action}                                     // '';

        if ( $action eq 'revoke' ) {
            my $id = $body->{id};
            unless ($id) {
                $status = 400;
                $result = { error => 'Share ID required' };
            }
            else {
                my $ok = Plugins::SlimPing::Handlers::Sharing->revokeShare($id);
                if ($ok) {
                    Plugins::SlimPing::Core::Audit::record(
                        actor => $actor, ip => $ip, action => 'revoke_share', target => $id );
                    $result = { ok => 1 };
                }
                else {
                    $status = 404;
                    $result = { error => 'Share not found' };
                }
            }
        }
        elsif ( $action eq 'revoke_all' ) {
            my $count = Plugins::SlimPing::Handlers::Sharing->revokeAllShares();
            Plugins::SlimPing::Core::Audit::record(
                actor => $actor, ip => $ip, action => 'revoke_all_shares',
                target => 'shares', detail => "count=$count" );
            $result = { ok => 1, revoked => $count };
        }
        elsif ( $action eq 'save_settings' ) {
            # Numeric prefs with no cross-validation
            for my $pref (qw(share_max_bitrate radio_max_bitrate share_user_cap share_global_cap
                             share_max_listeners share_max_unique_ips)) {
                if ( exists $body->{$pref} ) {
                    $prefs->set( $pref, int( $body->{$pref} ) );
                }
            }
            # TTL values: UI sends hours, store as seconds.  Clamp server-side.
            my $min = int( $body->{share_min_ttl}   // 1 );
            my $max = int( $body->{share_max_ttl}   // 168 );
            my $def = int( $body->{share_default_ttl} // 24 );
            $min = 1   if $min < 1;
            $max = 168 if $max > 168;
            if ( $min >= $max ) { $min = 1; $max = 168; }
            $def = $min if $def < $min;
            $def = $max if $def > $max;
            $prefs->set( 'share_min_ttl',     $min * 3600 );
            $prefs->set( 'share_default_ttl', $def * 3600 );
            $prefs->set( 'share_max_ttl',     $max * 3600 );
            Plugins::SlimPing::Core::Audit::record(
                actor => $actor, ip => $ip, action => 'save_sharing_settings',
                target => 'shares' );
            $result = { ok => 1 };
        }
        else {
            $status = 400;
            $result = { error => "Unknown action '$action'" };
        }
    }
    else {
        $status = 405;
        $result = { error => 'Method not allowed' };
    }

    my $body_json = $json->encode($result);
    $response->header( 'Content-Type'   => 'application/json; charset=utf-8' );
    $response->header( 'Content-Length' => length($body_json) );
    $response->code($status);
    Slim::Web::HTTP::addHTTPResponse( $httpClient, $response, \$body_json );
}

1;
