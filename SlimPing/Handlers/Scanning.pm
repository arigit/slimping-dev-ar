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
# Handlers/Scanning.pm - Library scan control handlers
#
# Wraps Slim::Control::Request rescan commands.  startScan triggers a
# library rescan (admin only); getScanStatus reports current progress.
#

package Plugins::SlimPing::Handlers::Scanning;

use strict;
use warnings;

use Slim::Control::Request;
use Slim::Music::Import;

use Plugins::SlimPing::API::Router;
use Plugins::SlimPing::Auth::Permissions;
use Plugins::SlimPing::Core::Logging;

my $log = Plugins::SlimPing::Core::Logging->getLogger();

sub registerHandlers {
    my $class = shift;
    Plugins::SlimPing::API::Router->registerHandler('getScanStatus', \&getScanStatus);
    Plugins::SlimPing::API::Router->registerHandler('startScan',     \&startScan);
}

sub getScanStatus {
    my ($args) = @_;

    my $scanning = Slim::Music::Import->stillScanning() ? \1 : \0;
    my $count    = Slim::Music::Import->can('totalCount')
        ? (Slim::Music::Import->totalCount() // 0) : 0;
    my $current  = Slim::Music::Import->can('currentCount')
        ? (Slim::Music::Import->currentCount() // 0) : 0;
    my $phase    = Slim::Music::Import->can('scanningPhase')
        ? (Slim::Music::Import->scanningPhase() // '') : '';

    # OpenSubsonic spec only defines 'scanning' and 'count'.  'current'
    # and 'phase' originated in the reference Subsonic server and are
    # returned by all major implementations (Navidrome, Gonic, Airsonic).
    # Clients use them for scan-progress UIs.
    my $status_data = {
        scanning => $scanning,
        count    => 0 + int($count),
        current  => 0 + int($current),
        phase    => $phase,
    };

    # Py-opensonic and several other client libraries access 'scanstatus'
    # (lowercase) instead of the spec-correct 'scanStatus'.
    
    # Looking at other server code, many servers in the ecosystem return 
    # one form or the other so both keys are permanent.
    return {
        scanStatus => $status_data,
        scanstatus => $status_data,
    };
}

sub startScan {
    my ($args) = @_;
    if (my $err = Plugins::SlimPing::Auth::Permissions->requireRole($args->{user}, 'adminRole')) {
        return $err;
    }

    my $mode = $args->{params}{mode} // 'fast';

    # The rescan request executes asynchronously — we return success before
    # the scan starts.  Runtime failures (e.g. missing music directory)
    # surface only in the LMS server log, not in this API response.
    my $request = Slim::Control::Request->new('rescan');
    $request->addParam('_mode', $mode eq 'full' ? 'wipecache' : 'fast');

    $request->callback(sub {
        my $r = shift;
        if ($r->isError()) {
            $log->error(
                sprintf(
                    'SlimPing: rescan request failed: %s',
                    $r->getResult() // 'unknown error'
                )
            );
        }
    });

    $request->execute();

    return { scanStatus => { scanning => \1, count => 0 } };
}

1;
