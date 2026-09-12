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

package Plugins::SlimPing::Settings::AdminApi::NowPlaying;

use strict;
use warnings;

use JSON::XS ();
use Slim::Web::HTTP;

use Plugins::SlimPing::Core::Logging;
use Plugins::SlimPing::Auth::AdminGate;
require Plugins::SlimPing::Core::Container;
require Plugins::SlimPing::Utils::Params;
require Plugins::SlimPing::Utils::Format;

my $log   = Plugins::SlimPing::Core::Logging->getLogger();
my $prefs = Plugins::SlimPing::Core::Logging->getPrefs();
my $json  = JSON::XS->new->utf8->allow_nonref;

sub handle {
    my ( $httpClient, $response ) = @_;

    my ( $auth_ok, $err_code, $err_msg ) =
      Plugins::SlimPing::Auth::AdminGate::requireAdmin( $httpClient, $response->request(), json_endpoint => 1 );
    return Plugins::SlimPing::Auth::AdminGate::denyAdmin( $httpClient, $response, $err_code, $err_msg )
      unless $auth_ok;

    my $sessions =
      Plugins::SlimPing::Core::Container->get('session_state')->getActiveSessions();

    # Enrich sessions with track info where possible
    my $mapper = Plugins::SlimPing::Core::Container->get('library_mapper');
    my @enriched;
    for my $s (@$sessions) {
        my %entry = %$s;
        if ( $s->{track_id} ) {
            my $track = $mapper->getTrackById( $s->{track_id} );
            if ($track) {
                $entry{track_title}  = $track->{title}  || '';
                $entry{track_artist} = $track->{artist} || '';
            }
        }
        $entry{last_seen_fmt} = scalar localtime( $s->{last_seen} );
        $entry{position_fmt}  = Plugins::SlimPing::Utils::Format->formatDuration( $s->{position} );
        push @enriched, \%entry;
    }

    my $body = $json->encode( { sessions => \@enriched } );
    $response->header( 'Content-Type'   => 'application/json; charset=utf-8' );
    $response->header( 'Content-Length' => length($body) );
    $response->code(200);
    Slim::Web::HTTP::addHTTPResponse( $httpClient, $response, \$body );
}

1;
