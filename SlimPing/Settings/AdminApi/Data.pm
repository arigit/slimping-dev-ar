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

package Plugins::SlimPing::Settings::AdminApi::Data;

use strict;
use warnings;

use JSON::XS ();
use Slim::Web::HTTP;
use Slim::Control::Request;
use Slim::Utils::Timers;

use Plugins::SlimPing::Core::Logging;
use Plugins::SlimPing::Auth::AdminGate;
use Plugins::SlimPing::Core::Audit;
use Plugins::SlimPing::Core::StarStore;
use Plugins::SlimPing::Core::RatingStore;
use Plugins::SlimPing::Core::BookmarkStore;
use Plugins::SlimPing::Core::SessionStore;
use Plugins::SlimPing::Schema;
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
        my $schema = Plugins::SlimPing::Schema->connect();
        my %counts;
        for my $table (qw(User ApiKey Star Rating Bookmark Session Share)) {
            $counts{ lc $table } = $schema->resultset($table)->count();
        }
        $counts{textcache} = $schema->storage->dbh->selectrow_array(
            'SELECT COUNT(*) FROM text_cache');

        my $cachedir = Slim::Utils::Prefs::preferences('server')->get('cachedir');
        my $db_path  = File::Spec::Functions::catfile($cachedir, 'slimping', 'slimping.db');
        my $db_size  = -s $db_path;

        # Human-readable file size
        my $db_size_fmt;
        if ( !defined $db_size ) {
            $db_size_fmt = 'unknown';
        } elsif ( $db_size < 1024 ) {
            $db_size_fmt = "$db_size B";
        } elsif ( $db_size < 1024 * 1024 ) {
            $db_size_fmt = sprintf( '%.1f KB', $db_size / 1024 );
        } else {
            $db_size_fmt = sprintf( '%.1f MB', $db_size / ( 1024 * 1024 ) );
        }

        $result = {
            row_counts  => \%counts,
            db_size     => $db_size,
            db_size_fmt => $db_size_fmt,
        };

        # Add transcode cache stats if available
        eval {
            require Plugins::SlimPing::Core::TranscodeCache;
            my $stats = Plugins::SlimPing::Core::TranscodeCache->getInstance->stats();
            my $ram   = $stats->{ram};
            my $cache = {
                ram_enabled      => 1,
                ram_entries      => $ram->{track_count} // 0,
                ram_hits         => $ram->{hits}        // 0,
                ram_misses       => $ram->{misses}      // 0,
                ram_evictions    => $ram->{evictions}   // 0,
                ram_track_limit  => $ram->{max_tracks}  // 0,
                ram_bytes_used   => $ram->{bytes_used}  // 0,
                ram_bytes_max    => $ram->{max_bytes}   // 0,
                ram_bytes_fmt    => _fmtBytes( $ram->{bytes_used} // 0 ),
                ram_max_fmt      => _fmtBytes( $ram->{max_bytes}   // 0 ),
            };
            if ( $stats->{disk} ) {
                my $disk = $stats->{disk};
                $cache->{disk_entries}    = $disk->{track_count} // 0;
                $cache->{disk_bytes_used} = $disk->{bytes_used}  // 0;
                $cache->{disk_bytes_max}  = $disk->{max_bytes}   // 0;
                $cache->{disk_bytes_fmt}  = _fmtBytes( $disk->{bytes_used} // 0 );
                $cache->{disk_max_fmt}    = _fmtBytes( $disk->{max_bytes}  // 0 );
            }
            $result->{cache} = $cache;
        };
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

        if ( $action eq 'flush_store' ) {
            my $target = $body->{target} // '';
            my %valid  = map { $_ => 1 } qw(star rating bookmark session share);
            unless ( $valid{$target} ) {
                $status = 400;
                $result = { error => "Invalid target '$target'; valid: star, rating, bookmark, session, share" };
            } else {
                my $count = 0;
                if ( $target eq 'star' ) {
                    $count = Plugins::SlimPing::Core::StarStore->getInstance()->flushAll();
                } elsif ( $target eq 'rating' ) {
                    $count = Plugins::SlimPing::Core::RatingStore->getInstance()->flushAll();
                } elsif ( $target eq 'bookmark' ) {
                    $count = Plugins::SlimPing::Core::BookmarkStore->getInstance()->flushAll();
                } elsif ( $target eq 'session' ) {
                    $count = Plugins::SlimPing::Core::SessionStore->getInstance()->flushAll();
                }
                Plugins::SlimPing::Core::Audit::record(
                    actor  => $actor,
                    ip     => $ip,
                    action => 'flush_store',
                    target => $target,
                    detail => "rows=$count",
                );
                $result = { ok => 1, rows_deleted => $count };
            }
        }
        elsif ( $action eq 'restart_server' ) {
            Plugins::SlimPing::Core::Audit::record(
                actor  => $actor,
                ip     => $ip,
                action => 'restart_server',
            );
            $result = { ok => 1, message => 'Server restart initiated' };
            # Delay restart so the HTTP response can be sent first.
            Slim::Utils::Timers::setTimer( undef, time() + 1.0, sub {
                Slim::Control::Request::executeRequest( undef, ['restartserver'] );
            });
        }
        elsif ( $action eq 'flush_cache' ) {
            eval {
                require Plugins::SlimPing::Core::TranscodeCache;
                Plugins::SlimPing::Core::TranscodeCache->forceFlushAll();
            };
            Plugins::SlimPing::Core::Audit::record(
                actor  => $actor,
                ip     => $ip,
                action => 'flush_cache',
            );
            $result = { ok => 1 };
        }
        elsif ( $action eq 'cleanup_virtual_players' ) {
            require Plugins::SlimPing::Core::VirtualPlayer;
            my $count = Plugins::SlimPing::Core::VirtualPlayer::cleanupDisconnectedPlayers();
            Plugins::SlimPing::Core::Audit::record(
                actor  => $actor,
                ip     => $ip,
                action => 'cleanup_virtual_players',
                detail => "removed=$count",
            );
            $result = { ok => 1, players_removed => $count };
        }
        elsif ( $action eq 'cleanup_orphaned_tracks' ) {
            my $confirm = $body->{confirm} ? 1 : 0;
            require Slim::Schema;

            # Count orphaned tracks: transcode-cache file:// URLs,
            # slimping:// URLs, and temp output files left by earlier
            # plugin versions before the isRemote => 1 protocol handler
            # was deployed.
            my $like_clause = <<'SQL';
(url LIKE 'file://%transcode_cache%'
 OR url LIKE 'file://%slimping_seek_%'
 OR url LIKE 'file://%slimping_out_%'
 OR url LIKE 'slimping://%')
SQL
            my $dbh    = Slim::Schema->dbh;
            my ($count) = $dbh->selectrow_array(
                "SELECT COUNT(*) FROM tracks WHERE $like_clause" );

            unless ($confirm) {
                $result = {
                    ok           => 1,
                    dry_run      => 1,
                    orphan_count => int( $count // 0 ),
                    message      => 'Add "confirm": true to execute deletion',
                };
            } else {
                # Delete tracks_persistent entries via SQL (handles both
                # library.db and attached persist.db setups).  If
                # TrackPersistent is loaded (STATISTICS on), use the
                # resultset; otherwise just delete from the raw table.
                my $persist_deleted = 0;
                eval {
                    require Slim::Schema::TrackPersistent;
                    my $rs   = Slim::Schema->resultset('TrackPersistent');
                    my @urls = @{ $dbh->selectcol_arrayref(
                        "SELECT urlmd5 FROM tracks WHERE $like_clause" ) || [] };
                    for my $urlmd5 (@urls) {
                        my $row = $rs->search( { urlmd5 => $urlmd5 } )->single;
                        if ($row) {
                            $row->delete;
                            $persist_deleted++;
                        }
                    }
                };
                if ($@) {
                    $log->warn("SlimPing: tracks_persistent cleanup failed: $@");
                }

                # Delete orphan junction-table rows, then tracks.
                $dbh->do("DELETE FROM tracks_persistent WHERE urlmd5 IN (SELECT urlmd5 FROM tracks WHERE $like_clause)")
                    unless $persist_deleted;  # fallback if resultset path failed

                $dbh->do("DELETE FROM tracks WHERE $like_clause");

                Plugins::SlimPing::Core::Audit::record(
                    actor  => $actor,
                    ip     => $ip,
                    action => 'cleanup_orphaned_tracks',
                    detail => "count=$count persist=$persist_deleted",
                );
                $result = {
                    ok               => 1,
                    orphan_count     => int( $count // 0 ),
                    persist_deleted  => $persist_deleted // 0,
                };
            }
        }
        elsif ( $action eq 'flush_user_data' ) {
            my $username = $body->{username} // '';
            unless ($username) {
                $status = 400;
                $result = { error => 'username is required' };
            } else {
                my $stars     = Plugins::SlimPing::Core::StarStore->getInstance()->flushForUser($username);
                my $ratings   = Plugins::SlimPing::Core::RatingStore->getInstance()->flushForUser($username);
                my $bookmarks = Plugins::SlimPing::Core::BookmarkStore->getInstance()->flushForUser($username);
                my $sessions  = Plugins::SlimPing::Core::SessionStore->getInstance()->flushForUser($username);
                Plugins::SlimPing::Core::Audit::record(
                    actor  => $actor,
                    ip     => $ip,
                    action => 'flush_user_data',
                    target => $username,
                    detail => "stars=$stars,ratings=$ratings,bookmarks=$bookmarks,sessions=$sessions",
                );
                $result = {
                    ok        => 1,
                    stars     => $stars,
                    ratings   => $ratings,
                    bookmarks => $bookmarks,
                    sessions  => $sessions,
                };
            }
        }
        elsif ( $action eq 'delete_user' ) {
            my $username = $body->{username} // '';
            unless ($username) {
                $status = 400;
                $result = { error => 'username is required' };
            } else {
                my $mgr     = Plugins::SlimPing::Core::Container->get('auth_manager');
                my $deleted = $mgr->deleteUser($username);
                if ($deleted) {
                    Plugins::SlimPing::Core::Audit::record(
                        actor  => $actor,
                        ip     => $ip,
                        action => 'delete_user',
                        target => $username,
                        detail => 'all data cascaded',
                    );
                    $result = { ok => 1, deleted => $username };
                } else {
                    $status = 404;
                    $result = { error => 'User not found' };
                }
            }
        }
        elsif ( $action eq 'reset_database' ) {
            my $schema  = Plugins::SlimPing::Schema->connect();
            my $dbh     = $schema->storage->dbh;
            my $deleted = 0;

            # Delete child tables first to respect FK ordering
            for my $table (qw(Session Share Bookmark Rating Star ApiKey User)) {
                my $count = $schema->resultset($table)->count();
                $schema->resultset($table)->delete();
                $deleted += $count;
            }

            # Remove migration sentinel so prefs migration re-runs on next load
            $prefs->remove('schema_migrated_v1');

            Plugins::SlimPing::Core::Audit::record(
                actor  => $actor,
                ip     => $ip,
                action => 'reset_database',
                target => 'slimpping.db',
                detail => "rows=$deleted -- all tables truncated, sentinel cleared",
            );
            $result = { ok => 1, rows_deleted => $deleted };
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

sub _fmtBytes {
    my ($bytes) = @_;
    return '0 B' unless $bytes && $bytes > 0;
    my @units = qw(B KB MB GB);
    my $i = 0;
    while ( $bytes >= 1024 && $i < 3 ) {
        $bytes /= 1024;
        $i++;
    }
    return sprintf( '%.1f %s', $bytes, $units[$i] );
}

1;
