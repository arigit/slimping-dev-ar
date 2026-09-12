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

package Plugins::SlimPing::Settings::AdminApi::Server;

use strict;
use warnings;

use JSON::XS ();
use Slim::Web::HTTP;
use Slim::Player::Client;

use Plugins::SlimPing::Core::Logging;
use Plugins::SlimPing::Auth::AdminGate;
use Plugins::SlimPing::Auth::RateLimit;
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
    my ( $result, $status ) = ( {}, 200 );

    if ( $method eq 'GET' ) {

        # Return the list of folder names from the LMS favourites OPML so the
        # settings UI can populate the radio folder dropdown dynamically.
        require Slim::Plugin::Favorites::OpmlFavorites;
        my $favs  = Slim::Plugin::Favorites::OpmlFavorites->new();
        my $level = $favs->toplevel();
        my @folders;
        for my $entry (@$level) {
            next unless $entry->{outline};
            next if ( $entry->{type} // '' ) eq 'link';
            push @folders, { name => $entry->{text} // '' };
        }
        $result = { folders => \@folders };

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

        if ( $action eq 'save_exposure' ) {
            my $mode = $body->{exposed_libraries_mode} // 'all';
            $prefs->set( 'exposed_libraries_mode', $mode );

            if ( $mode eq 'selected' ) {
                my $ids = $body->{exposed_library_ids};
                $prefs->set( 'exposed_library_ids',
                    ref $ids eq 'ARRAY' ? $ids : [] );
            }
            else {
                $prefs->remove('exposed_library_ids');
            }

            Plugins::SlimPing::Core::Container->get('library_mapper')
              ->invalidateFolderCache();
            $log->info("SlimPing: exposure mode updated to '$mode' (via AJAX)");
            Plugins::SlimPing::Core::Audit::record(
                actor  => $actor,
                ip     => $ip,
                action => 'set_exposure',
                target => 'libraries',
                detail => "mode=$mode",
            );
            $result = { ok => 1 };
        }
        elsif ( $action eq 'save_admin_access' ) {
            my $mode = $body->{admin_access} // 'lan_open';
            unless ( grep { $_ eq $mode }
                qw(lan_open loopback_open auth_required) )
            {
                $status = 400;
                $result = { error => "Unknown admin_access mode '$mode'" };
            }
            else {
                $prefs->set( 'admin_access', $mode );
                $log->info("SlimPing: admin_access updated to '$mode'");
                Plugins::SlimPing::Core::Audit::record(
                    actor  => $actor,
                    ip     => $ip,
                    action => 'set_admin_access',
                    target => 'gate',
                    detail => "mode=$mode",
                );
                $result = { ok => 1 };
            }
        }
        elsif ( $action eq 'save_lan_mode' ) {
            my $on = Plugins::SlimPing::Utils::Params->coerceBool( $body->{lan_mode} );
            $prefs->set( 'lan_mode', $on );
            $log->info("SlimPing: lan_mode updated to $on");
            Plugins::SlimPing::Core::Audit::record(
                actor  => $actor,
                ip     => $ip,
                action => 'set_lan_mode',
                target => 'subsonic_auth',
                detail => "lan_mode=$on",
            );
            $result = { ok => 1 };
        }
        elsif ( $action eq 'save_allow_plain_password' ) {
            my $on = Plugins::SlimPing::Utils::Params->coerceBool( $body->{allow_plain_password} );
            $prefs->set( 'allow_plain_password', $on );
            $log->info("SlimPing: allow_plain_password updated to $on");
            Plugins::SlimPing::Core::Audit::record(
                actor  => $actor,
                ip     => $ip,
                action => 'set_allow_plain_password',
                target => 'subsonic_auth',
                detail => "allow_plain_password=$on",
            );
            $result = { ok => 1 };
        }
        elsif ( $action eq 'reset_rate_limits' ) {
            my $cleared = Plugins::SlimPing::Auth::RateLimit->clearAll();
            $log->info("SlimPing: rate-limit state cleared ($cleared buckets)");
            Plugins::SlimPing::Core::Audit::record(
                actor  => $actor,
                ip     => $ip,
                action => 'reset_rate_limits',
                target => 'auth',
                detail => "buckets=$cleared",
            );
            $result = { ok => 1, cleared => $cleared };
        }
        elsif ( $action eq 'save_trust_xff' ) {
            my $on = Plugins::SlimPing::Utils::Params->coerceBool( $body->{trust_xff} );
            $prefs->set( 'trust_xff', $on );
            $log->info("SlimPing: trust_xff updated to $on");
            Plugins::SlimPing::Core::Audit::record(
                actor  => $actor,
                ip     => $ip,
                action => 'set_trust_xff',
                target => 'gate',
                detail => "trust_xff=$on",
            );
            $result = { ok => 1 };
        }
        elsif ( $action eq 'save_features' ) {
            for my $pref_name (
                qw(proxy_remote_streams feature_internet_radio feature_podcasts
                   lms_favourites_bridge
                   feature_sharing
                   client_quirks_enabled quirk_substreamer_artwork
                   cache_disk_enabled)
              )
            {
                if ( exists $body->{$pref_name} ) {
                    $prefs->set( $pref_name, Plugins::SlimPing::Utils::Params->coerceBool($body->{$pref_name}) );
                }
            }
            # Numeric search3 caps (0 = disabled).
            for my $pref_name (qw(maxAlbumCount maxArtistCount maxSongCount)) {
                if ( exists $body->{$pref_name} ) {
                    my $val = int( $body->{$pref_name} // 0 );
                    $val = 0 if $val < 0;
                    $prefs->set( $pref_name, $val );
                }
            }
            # Remote stream governance caps (always on -- no 0 / disabled).
            if ( exists $body->{remote_stream_cap} ) {
                my $val = int( $body->{remote_stream_cap} // 10 );
                $val = 1  if $val < 1;
                $val = 50 if $val > 50;
                $prefs->set( 'remote_stream_cap', $val );
            }
            if ( exists $body->{remote_stream_rate_limit} ) {
                my $val = int( $body->{remote_stream_rate_limit} // 3 );
                $val = 1  if $val < 1;
                $val = 20 if $val > 20;
                $prefs->set( 'remote_stream_rate_limit', $val );
            }
            if ( exists $body->{remote_stream_rate_window} ) {
                my $val = int( $body->{remote_stream_rate_window} // 10 );
                $val = 5   if $val < 5;
                $val = 120 if $val > 120;
                $prefs->set( 'remote_stream_rate_window', $val );
            }
            # MAI integration uses a tri-state select (auto/on/off), not a checkbox.
            if ( exists $body->{feature_mai_integration} ) {
                my $val = $body->{feature_mai_integration};
                $prefs->set( 'feature_mai_integration',
                    ($val eq 'on' || $val eq 'off') ? $val : 'auto' );
            }
            # MAI text integration: on_demand (fetch when client asks) or off.
            if ( exists $body->{feature_mai_text} ) {
                my $val = $body->{feature_mai_text};
                $prefs->set( 'feature_mai_text',
                    ($val eq 'on_demand' || $val eq 'off') ? $val : 'on_demand' );
            }
            # MAI biography positive cache TTL in hours (24-2160, default 2160 = 90 days).
            if ( exists $body->{mai_bio_positive_ttl} ) {
                my $val = int( $body->{mai_bio_positive_ttl} // 2160 );
                $val = 2160 if $val < 24 || $val > 2160;
                $prefs->set( 'mai_bio_positive_ttl', $val * 3600 );
            }
            # MAI biography negative cache TTL in hours (24-720, default 720 = 30 days).
            if ( exists $body->{mai_bio_negative_ttl} ) {
                my $val = int( $body->{mai_bio_negative_ttl} // 720 );
                $val = 720 if $val < 24 || $val > 720;
                $prefs->set( 'mai_bio_negative_ttl', $val * 3600 );
            }
            # Similar-song depth uses a tri-state select (basic/enhanced/full).
            if ( exists $body->{feature_similar_depth} ) {
                my $val = $body->{feature_similar_depth};
                $prefs->set( 'feature_similar_depth',
                    ($val eq 'basic' || $val eq 'enhanced' || $val eq 'full') ? $val : 'basic' );
            }
            # MAI external request concurrency cap (5-50).
            if ( exists $body->{mai_external_cap} ) {
                my $val = int( $body->{mai_external_cap} // 20 );
                $val = 20 if $val < 5 || $val > 50;
                $prefs->set( 'mai_external_cap', $val );
            }
            # MAI request rate: max external requests per minute (1-60).
            # Default 10 to account for MAI's internal 2x+ HTTP fan-out
            # (e.g. each biography call hits Wikipedia search + page fetch).
            if ( exists $body->{mai_request_rate} ) {
                my $val = int( $body->{mai_request_rate} // 10 );
                $val = 10 if $val < 1 || $val > 60;
                $prefs->set( 'mai_request_rate', $val );
            }
            # MAI deferred queue max entries (10-2000).  Requests rejected by
            # the rate-limit or concurrency cap are queued for later processing
            # instead of being silently dropped.
            if ( exists $body->{mai_queue_max} ) {
                my $val = int( $body->{mai_queue_max} // 500 );
                $val = 500 if $val < 10 || $val > 2000;
                $prefs->set( 'mai_queue_max', $val );
            }
            # Exotic format target: mp3 or flac.
            if ( exists $body->{exotic_target} ) {
                my $val = $body->{exotic_target};
                $prefs->set( 'exotic_target',
                    ( $val eq 'mp3' || $val eq 'flac' ) ? $val : 'flac' );
            }
            # Exotic format sample rate: 44100, 88200, or 176400.
            if ( exists $body->{exotic_target_rate} ) {
                my $val = int( $body->{exotic_target_rate} // 88200 );
                $val = 44100  if $val < 44100;
                $val = 176400 if $val > 176400;
                $prefs->set( 'exotic_target_rate', $val );
            }
            # Store caps: per-user and global limits for stars and bookmarks.
            if ( exists $body->{star_user_cap} ) {
                my $val = int( $body->{star_user_cap} // 5000 );
                $val = 0 if $val < 0;
                $prefs->set( 'star_user_cap', $val );
            }
            if ( exists $body->{star_global_cap} ) {
                my $val = int( $body->{star_global_cap} // 500_000 );
                $val = 0 if $val < 0;
                $prefs->set( 'star_global_cap', $val );
            }
            if ( exists $body->{bookmark_user_cap} ) {
                my $val = int( $body->{bookmark_user_cap} // 1000 );
                $val = 0 if $val < 0;
                $prefs->set( 'bookmark_user_cap', $val );
            }
            if ( exists $body->{bookmark_global_cap} ) {
                my $val = int( $body->{bookmark_global_cap} // 20_000 );
                $val = 0 if $val < 0;
                $prefs->set( 'bookmark_global_cap', $val );
            }
            # Session and token TTL.
            if ( exists $body->{session_ttl_days} ) {
                my $val = int( $body->{session_ttl_days} // 7 );
                $val = 7   if $val < 1;
                $val = 365 if $val > 365;
                $prefs->set( 'session_ttl_days', $val );
            }
            if ( exists $body->{radio_token_ttl} ) {
                my $val = int( $body->{radio_token_ttl} // 7776000 );
                $val = 3600     if $val < 3600;
                $val = 31536000 if $val > 31536000;
                $prefs->set( 'radio_token_ttl', $val );
            }
            # Data enrichment settings.
            if ( exists $body->{genre_count_per_entity} ) {
                my $val  = int( $body->{genre_count_per_entity} // 3 );
                my %valid = map { $_ => 1 } ( 1, 2, 3, 5, 10 );
                $val = 3 unless $valid{$val};
                $prefs->set( 'genre_count_per_entity', $val );
            }
            if ( exists $body->{exposed_contributor_roles} ) {
                my $val = $body->{exposed_contributor_roles} // '';
                $val =~ s/[^A-Z_,]//g;    # strip anything that is not uppercase, underscore, or comma
                $val =~ s/,{2,}/,/g;       # collapse consecutive commas
                $val =~ s/^,|,$//g;        # strip leading and trailing commas
                $val ||= 'ARTIST,COMPOSER,CONDUCTOR,BAND,ALBUMARTIST,TRACKARTIST';
                $prefs->set( 'exposed_contributor_roles', $val );
            }
            # Transcode cache caps.
            if ( exists $body->{cache_ram_max_mb} ) {
                my $val = int( $body->{cache_ram_max_mb} // 100 );
                $val = 5   if $val < 5;       # min 5 MB
                $val = 500 if $val > 500;      # max 500 MB
                $prefs->set( 'cache_ram_max_mb', $val );
            }
            if ( exists $body->{cache_ram_max_tracks} ) {
                my $val = int( $body->{cache_ram_max_tracks} // 10 );
                $val = 1  if $val < 1;
                $val = 50 if $val > 50;
                $prefs->set( 'cache_ram_max_tracks', $val );
            }
            if ( exists $body->{cache_disk_max_mb} ) {
                my $val = int( $body->{cache_disk_max_mb} // 2048 );
                $val = 50   if $val < 50;
                $val = 10240 if $val > 10240;              # max 10 GB
                $prefs->set( 'cache_disk_max_mb', $val );
            }
            if ( exists $body->{cache_disk_path} ) {
                my $val = $body->{cache_disk_path} // '';
                if ( length $val ) {
                    # Reject relative paths and paths with '..' segments.
                    if ( $val !~ m{^/} ) {
                        $log->warn("SlimPing: rejecting non-absolute cache_disk_path: $val");
                        return { error => 'cache_disk_path must be an absolute path' };
                    }
                    if ( $val =~ m{/\.\./} || $val =~ m{/\.\.$} ) {
                        $log->warn("SlimPing: rejecting cache_disk_path with .. segments: $val");
                        return { error => 'cache_disk_path must not contain .. segments' };
                    }
                    # Warn if outside the LMS cache directory (not a hard block
                    # — operators with custom volume mounts may have good reason).
                    my $cachedir = eval {
                        Slim::Utils::Prefs::preferences('server')->get('cachedir');
                    };
                    if ( $cachedir && index( $val, $cachedir ) != 0 ) {
                        $log->warn("SlimPing: cache_disk_path ($val) is outside LMS cachedir ($cachedir)");
                    }
                }
                $prefs->set( 'cache_disk_path', $val );
            }
            $log->info('SlimPing: feature toggles updated');
            Plugins::SlimPing::Core::Audit::record(
                actor  => $actor,
                ip     => $ip,
                action => 'save_features',
                target => 'features',
                detail => 'proxy='
                  . ( $prefs->get('proxy_remote_streams') )
                  . ' radio='
                  . ( $prefs->get('feature_internet_radio') )
                  . ' podcasts='
                  . ( $prefs->get('feature_podcasts') )
                  . ' mai='
                  . ( $prefs->get('feature_mai_integration') )
                  . ' mai_text='
                  . ( $prefs->get('feature_mai_text') )
                  . ' mai_cap='
                  . ( $prefs->get('mai_external_cap') )
                  . ' mai_rate='
                  . ( $prefs->get('mai_request_rate') )
                  . ' mai_queue='
                  . ( $prefs->get('mai_queue_max') )
                  . ' bio_pos_ttl='
                  . ( $prefs->get('mai_bio_positive_ttl') )
                  . ' bio_neg_ttl='
                  . ( $prefs->get('mai_bio_negative_ttl') )
                  . ' similar='
                  . ( $prefs->get('feature_similar_depth') ),
            );
            $result = { ok => 1 };
        }
        elsif ( $action eq 'save_radio_folder' ) {
            my $folder  = $body->{radio_folder}  // '';
            return { error => 'Invalid radio folder name' }
                unless $folder =~ /^[\x20-\x7e]{0,255}$/;
            my $recurse = Plugins::SlimPing::Utils::Params->coerceBool($body->{radio_folder_recurse});
            $prefs->set( 'radioFolder',        $folder );
            $prefs->set( 'radioFolderRecurse', $recurse );
            $log->info("SlimPing: radioFolder updated to '$folder' recurse=$recurse (via AJAX)");
            Plugins::SlimPing::Core::Audit::record(
                actor  => $actor,
                ip     => $ip,
                action => 'set_radio_folder',
                target => 'internet_radio',
                detail => 'folder=' . ( $folder || '(root)' ) . " recurse=$recurse",
            );
            $result = { ok => 1 };
        }
        elsif ( $action eq 'save_scrobble_settings' ) {
            my $gateway = $body->{scrobble_gateway_player} // '';
            my $source  = $body->{scrobble_source_type}    // 'P';
            unless ( grep { $_ eq $source } qw(P R E) ) {
                $status = 400;
                $result = { error => "Invalid source type '$source'; valid: P, R, E" };
            }
            elsif ( $gateway && length $gateway ) {
                # Validate the selected player has AudioScrobbler enabled.
                my $client = Slim::Player::Client::getClient($gateway);
                if ( !$client ) {
                    $status = 400;
                    $result = { error => "Player '$gateway' not found or disconnected" };
                }
                elsif ( !eval { require Slim::Plugin::AudioScrobbler::Plugin; 1 }
                    || !Slim::Plugin::AudioScrobbler::Plugin::getAccount($client) )
                {
                    $status = 400;
                    $result = {
                        error =>
                          "Player '$gateway' does not have an AudioScrobbler account configured"
                    };
                }
                else {
                    $prefs->set( 'scrobble_gateway_player', $gateway );
                    $prefs->set( 'scrobble_source_type',    $source );
                    $log->info("SlimPing: scrobble settings updated gateway='$gateway' source='$source'");
                    Plugins::SlimPing::Core::Audit::record(
                        actor  => $actor,
                        ip     => $ip,
                        action => 'save_scrobble_settings',
                        target => 'scrobbling',
                        detail => "gateway=$gateway source=$source",
                    );
                    $result = { ok => 1 };
                }
            }
            else {
                # Empty gateway = disabled, always allowed.
                $prefs->set( 'scrobble_gateway_player', $gateway );
                $prefs->set( 'scrobble_source_type',    $source );
                $log->info("SlimPing: scrobble settings updated gateway='$gateway' source='$source'");
                Plugins::SlimPing::Core::Audit::record(
                    actor  => $actor,
                    ip     => $ip,
                    action => 'save_scrobble_settings',
                    target => 'scrobbling',
                    detail => "gateway=$gateway source=$source",
                );
                $result = { ok => 1 };
            }
        }
        elsif ( $action eq 'rotate_stream_tokens' ) {
            unless ( $body->{confirm} ) {
                $status = 400;
                $result = { error => 'Set confirm=true to rotate the signing key' };
            }
            else {
                my $mgr = Plugins::SlimPing::Core::Container->get('auth_manager');
                my $ok = $mgr->rotateHmacSigningKey();
                if ($ok) {
                    $log->info(
                        "SlimPing: stream token signing key rotated by '$actor' from $ip");
                    Plugins::SlimPing::Core::Audit::record(
                        actor  => $actor,
                        ip     => $ip,
                        action => 'rotate_stream_tokens',
                        target => 'auth',
                        detail => 'All outstanding radio and transcode tokens invalidated',
                    );
                    $result = { ok => 1 };
                }
                else {
                    $status = 500;
                    $result = { error => 'Key rotation failed -- check server logs' };
                }
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

    my $body_json = $json->encode($result);
    $response->header( 'Content-Type'   => 'application/json; charset=utf-8' );
    $response->header( 'Content-Length' => length($body_json) );
    $response->code($status);
    Slim::Web::HTTP::addHTTPResponse( $httpClient, $response, \$body_json );
}

1;
