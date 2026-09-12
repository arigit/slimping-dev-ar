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

package Plugins::SlimPing::Settings::AdminApi::Players;

use strict;
use warnings;

use JSON::XS ();
use Slim::Web::HTTP;
use Slim::Player::Client;

use Plugins::SlimPing::Core::Logging;
use Plugins::SlimPing::Auth::AdminGate;

my $log   = Plugins::SlimPing::Core::Logging->getLogger();
my $prefs = Plugins::SlimPing::Core::Logging->getPrefs();
my $json  = JSON::XS->new->utf8->allow_nonref;

sub handle {
    my ( $httpClient, $response ) = @_;

    my ( $auth_ok, $err_code, $err_msg ) =
      Plugins::SlimPing::Auth::AdminGate::requireAdmin( $httpClient, $response->request(), json_endpoint => 1 );
    return Plugins::SlimPing::Auth::AdminGate::denyAdmin( $httpClient, $response, $err_code, $err_msg )
      unless $auth_ok;

    my @players;
    my %seen_sync_group;

    for my $client ( Slim::Player::Client::clients() ) {
        my $id        = $client->id();
        my $name      = $client->name();
        my $model     = $client->modelName() // '';
        my $is_synced = $client->isSynced() ? \1 : \0;
        my $power     = $client->power()    ? \1 : \0;

        my @sync_members;
        if ( $client->isSynced() ) {

    # When synced, only report the sync-master once. Add a group entry
    # and skip individual member entries (they'll all have the same controller).
            my $controller    = $client->controller();
            my $controller_id = $controller->can('id') ? $controller->id() : '';
            next if $seen_sync_group{$controller_id};
            $seen_sync_group{$controller_id} = 1;

            for my $member ( $controller->activePlayers() ) {
                push @sync_members,
                  {
                    id    => $member->id(),
                    name  => $member->name(),
                    model => $member->modelName() // '',
                  };
            }
        }

        push @players,
          {
            id           => $id,
            name         => $name,
            model        => $model,
            power        => $power,
            sync_master  => $is_synced,
            sync_members => \@sync_members,
          };
    }

    @players = sort { $a->{name} cmp $b->{name} } @players;

    my $body = $json->encode( { players => \@players } );
    $response->header( 'Content-Type'   => 'application/json; charset=utf-8' );
    $response->header( 'Content-Length' => length($body) );
    $response->code(200);
    Slim::Web::HTTP::addHTTPResponse( $httpClient, $response, \$body );
}

1;
