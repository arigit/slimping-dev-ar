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

package Plugins::SlimPing::Settings::AdminApi::Users;

use strict;
use warnings;

use JSON::XS ();
use Slim::Web::HTTP;

use Plugins::SlimPing::Core::Logging;
use Plugins::SlimPing::Auth::AdminGate;
use Plugins::SlimPing::Core::Audit;
use Plugins::SlimPing::Utils::Params;
require Plugins::SlimPing::Core::Container;

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

    my $mgr = Plugins::SlimPing::Core::Container->get('auth_manager');
    my ( $result, $status ) = ( {}, 200 );

    if ( $method eq 'GET' ) {

        my $users = $mgr->getUsers();
        # Enrich with dpl_access from plugin prefs (not stored in the DB)
        for my $u (@$users) {
            my $dpl_val = $prefs->get("sq_dpl_access_$u->{username}");
            $u->{dpl_access} = defined $dpl_val ? $dpl_val : 1;
        }
        $result = { users => $users };

    }
    elsif ( $method eq 'POST' ) {
        my $body = eval { $json->decode( $request->content() || '{}' ) };
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

        if ( $action eq 'create' ) {
            my $admin = Plugins::SlimPing::Utils::Params->coerceBool($body->{admin});
            $mgr->createUser(
                username => $body->{username},
                password => $body->{password},
                admin    => $admin,
            );
            Plugins::SlimPing::Core::Audit::record(
                actor  => $actor,
                ip     => $ip,
                action => 'create_user',
                target => $body->{username} // '-',
                detail => "admin=$admin",
            );
            $result = { ok => 1 };
        }
        elsif ( $action eq 'add_key' ) {
            my $key = $mgr->addApiKey( $body->{username}, $body->{label} );
            Plugins::SlimPing::Core::Audit::record(
                actor  => $actor,
                ip     => $ip,
                action => 'add_api_key',
                target => $body->{username} // '-',
                detail => 'label=' . ( $body->{label} // 'Default' ),
            );
            $result = { key => $key };
        }
        elsif ( $action eq 'set_admin' ) {
            unless ( $body->{username} ) {
                $status = 400;
                $result = { error => 'username is required' };
            }
            else {
                my $admin = Plugins::SlimPing::Utils::Params->coerceBool($body->{admin});
                my $ok    = $mgr->setAdmin( $body->{username}, $admin );
                if ($ok) {
                    Plugins::SlimPing::Core::Audit::record(
                        actor  => $actor,
                        ip     => $ip,
                        action => 'set_admin',
                        target => $body->{username},
                        detail => "admin=$admin",
                    );
                    $result = { ok => 1 };
                }
                else {
                    $status = 404;
                    $result = { error => 'User not found' };
                }
            }
        }
        elsif ( $action eq 'set_jukebox_player' ) {
            unless ( $body->{username} ) {
                $status = 400;
                $result = { error => 'username is required' };
            }
            else {
                my $player_id = $body->{player_id};
                my $ok =
                  $mgr->setJukeboxPlayer( $body->{username}, $player_id );
                if ($ok) {
                    Plugins::SlimPing::Core::Audit::record(
                        actor  => $actor,
                        ip     => $ip,
                        action => 'set_jukebox_player',
                        target => $body->{username},
                        detail => 'player_id=' . ( $player_id // 'cleared' ),
                    );
                    $result = { ok => 1 };
                }
                else {
                    $status = 404;
                    $result = { error => 'User not found' };
                }
            }
        }
        elsif ( $action eq 'set_alias' ) {
            my $ok = $mgr->setAlias( $body->{username}, $body->{alias} );
            if ($ok) {
                Plugins::SlimPing::Core::Audit::record(
                    actor  => $actor,
                    ip     => $ip,
                    action => 'set_alias',
                    target => $body->{username},
                    detail => 'alias=' . ( $body->{alias} // 'cleared' ),
                );
                $result = { ok => 1 };
            }
            else {
                $status = 400;
                $result = { error => 'username is required' };
            }
        }
        elsif ( $action eq 'revoke_key' ) {
            unless ( $body->{username} && $body->{key_id} ) {
                $status = 400;
                $result = { error => 'username and key_id are required' };
            }
            else {
                my $ok = $mgr->deleteApiKey( $body->{username}, $body->{key_id} );
                if ($ok) {
                    Plugins::SlimPing::Core::Audit::record(
                        actor   => $actor,
                        ip      => $ip,
                        action  => 'revoke_api_key',
                        target  => $body->{username},
                        detail  => 'key_id=' . $body->{key_id},
                    );
                    $result = { ok => 1 };
                }
                else {
                    $status = 404;
                    $result = { error => 'User or API key not found' };
                }
            }
        }
        elsif ( $action eq 'set_password' ) {
            unless ( $body->{username} && $body->{password} ) {
                $status = 400;
                $result = { error => 'username and password are required' };
            }
            else {
                my $ok = $mgr->setPassword( $body->{username}, $body->{password} );
                if ($ok) {
                    Plugins::SlimPing::Core::Audit::record(
                        actor  => $actor,
                        ip     => $ip,
                        action => 'set_password',
                        target => $body->{username},
                        detail => 'password changed',
                    );
                    $result = { ok => 1 };
                }
                else {
                    $status = 404;
                    $result = { error => 'User not found' };
                }
            }
        }
        elsif ( $action eq 'set_enabled' ) {
            unless ( $body->{username} ) {
                $status = 400;
                $result = { error => 'username is required' };
            }
            else {
                my $enabled = Plugins::SlimPing::Utils::Params->coerceBool($body->{enabled});
                my $ok = $mgr->setEnabled( $body->{username}, $enabled );
                if ($ok) {
                    Plugins::SlimPing::Core::Audit::record(
                        actor  => $actor,
                        ip     => $ip,
                        action => 'set_enabled',
                        target => $body->{username},
                        detail => "enabled=$enabled",
                    );
                    $result = { ok => 1 };
                }
                else {
                    $status = 404;
                    $result = { error => 'User not found' };
                }
            }
        }
        elsif ( $action eq 'set_radio_folder' ) {
            unless ( $body->{username} ) {
                $status = 400;
                $result = { error => 'username is required' };
            }
            else {
                my $folder = $body->{radio_folder};
                my $ok = $mgr->setRadioFolder( $body->{username}, $folder );
                if ($ok) {
                    Plugins::SlimPing::Core::Audit::record(
                        actor  => $actor,
                        ip     => $ip,
                        action => 'set_user_radio_folder',
                        target => $body->{username},
                        detail => 'folder=' . ( $folder // '(root)' ),
                    );
                    $result = { ok => 1 };
                }
                else {
                    $status = 404;
                    $result = { error => 'User not found' };
                }
            }
        }

        elsif ( $action eq 'set_scrobble_enabled' ) {
            unless ( $body->{username} ) {
                $status = 400;
                $result = { error => 'username is required' };
            }
            else {
                my $enabled = Plugins::SlimPing::Utils::Params->coerceBool($body->{scrobble_enabled});
                my $ok = $mgr->setScrobbleEnabled( $body->{username}, $enabled );
                if ($ok) {
                    Plugins::SlimPing::Core::Audit::record(
                        actor  => $actor,
                        ip     => $ip,
                        action => 'set_scrobble_enabled',
                        target => $body->{username},
                        detail => "scrobble_enabled=$enabled",
                    );
                    $result = { ok => 1 };
                }
                else {
                    $status = 404;
                    $result = { error => 'User not found' };
                }
            }
        }
        elsif ( $action eq 'set_playcount_sync_enabled' ) {
            unless ( $body->{username} ) {
                $status = 400;
                $result = { error => 'username is required' };
            }
            else {
                my $enabled = Plugins::SlimPing::Utils::Params->coerceBool($body->{playcount_sync_enabled});
                my $ok = $mgr->setPlaycountSyncEnabled( $body->{username}, $enabled );
                if ($ok) {
                    Plugins::SlimPing::Core::Audit::record(
                        actor  => $actor,
                        ip     => $ip,
                        action => 'set_playcount_sync_enabled',
                        target => $body->{username},
                        detail => "playcount_sync_enabled=$enabled",
                    );
                    $result = { ok => 1 };
                }
                else {
                    $status = 404;
                    $result = { error => 'User not found' };
                }
            }
        }
        elsif ( $action eq 'set_playback_logging' ) {
            unless ( $body->{username} ) {
                $status = 400;
                $result = { error => 'username is required' };
            }
            else {
                my $enabled = Plugins::SlimPing::Utils::Params->coerceBool($body->{playback_logging});
                my $ok = $mgr->setPlaybackLogging( $body->{username}, $enabled );
                if ($ok) {
                    Plugins::SlimPing::Core::Audit::record(
                        actor  => $actor,
                        ip     => $ip,
                        action => 'set_playback_logging',
                        target => $body->{username},
                        detail => "playback_logging=$enabled",
                    );
                    $result = { ok => 1 };
                }
                else {
                    $status = 404;
                    $result = { error => 'User not found' };
                }
            }
        }
        elsif ( $action eq 'set_accept_playback_report' ) {
            unless ( $body->{username} ) {
                $status = 400;
                $result = { error => 'username is required' };
            }
            else {
                my $enabled = Plugins::SlimPing::Utils::Params->coerceBool($body->{accept_playback_report});
                my $ok = $mgr->setAcceptPlaybackReport( $body->{username}, $enabled );
                if ($ok) {
                    Plugins::SlimPing::Core::Audit::record(
                        actor  => $actor,
                        ip     => $ip,
                        action => 'set_accept_playback_report',
                        target => $body->{username},
                        detail => "accept_playback_report=$enabled",
                    );
                    $result = { ok => 1 };
                }
                else {
                    $status = 404;
                    $result = { error => 'User not found' };
                }
            }
        }
        elsif ( $action eq 'set_dpl_access' ) {
            unless ( $body->{username} ) {
                $status = 400;
                $result = { error => 'username is required' };
            }
            else {
                my $enabled = Plugins::SlimPing::Utils::Params::coerceBool( $body->{dpl_access} );
                $prefs->set( "sq_dpl_access_$body->{username}", $enabled ? 1 : 0 );
                Plugins::SlimPing::Core::Audit::record(
                    actor  => $actor,
                    ip     => $ip,
                    action => 'set_dpl_access',
                    target => $body->{username},
                    detail => "dpl_access=$enabled",
                );
                $result = { ok => 1 };
            }
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

    my $body = $json->encode($result);
    $response->header( 'Content-Type'   => 'application/json; charset=utf-8' );
    $response->header( 'Content-Length' => length($body) );
    $response->code($status);
    Slim::Web::HTTP::addHTTPResponse( $httpClient, $response, \$body );
}

1;
