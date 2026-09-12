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
# Handlers/Playlists.pm - Playlist CRUD handlers
#
# All Slim::Schema access is delegated to Core::PlaylistStore.
#

package Plugins::SlimPing::Handlers::Playlists;

use strict;
use warnings;

use Plugins::SlimPing::API::Router;
use Plugins::SlimPing::Core::LibraryMapper;
require Plugins::SlimPing::Core::Container;
require Plugins::SlimPing::Core::DynamicPlaylistBridge;
require Plugins::SlimPing::Core::PlaylistStore;
require Plugins::SlimPing::Utils::Errors;
require Plugins::SlimPing::Utils::Params;

sub registerHandlers {
    my $class = shift;
    Plugins::SlimPing::API::Router->registerHandler('getPlaylists',   \&getPlaylists);
    Plugins::SlimPing::API::Router->registerHandler('getPlaylist',    \&getPlaylist);
    Plugins::SlimPing::API::Router->registerHandler('createPlaylist', \&createPlaylist);
    Plugins::SlimPing::API::Router->registerHandler('updatePlaylist', \&updatePlaylist);
    Plugins::SlimPing::API::Router->registerHandler('deletePlaylist', \&deletePlaylist);
}

my $mapper     = sub { Plugins::SlimPing::Core::Container->get('library_mapper') };
my $store      = sub { Plugins::SlimPing::Core::PlaylistStore->getInstance() };
my $dpl_bridge = sub { Plugins::SlimPing::Core::DynamicPlaylistBridge->getInstance() };

sub getPlaylists {
    my ($args) = @_;
    require Plugins::SlimPing::Auth::Permissions;
    if (my $err = Plugins::SlimPing::Auth::Permissions->requireRole($args->{user}, 'playlistRole')) {
        return $err;
    }

    my @playlists;

    # Provider 2: DPL4 dynamic playlists (read-only)
    if ( $dpl_bridge->()->isAvailable() && $dpl_bridge->()->isEnabled() ) {
        my @dpl_playlists = $dpl_bridge->()->getExposedPlaylists($args->{user}{username});
        push @playlists, @dpl_playlists;
    }

    # Provider 1: LMS static/SSP playlists
    my @pl_objs = $store->()->getAllPlaylists();
    for my $pl (@pl_objs) {
        push @playlists, $mapper->()->shapePlaylist($pl, 0);
    }

    return { playlists => { playlist => \@playlists } };
}

sub getPlaylist {
    my ($args) = @_;
    require Plugins::SlimPing::Auth::Permissions;
    if (my $err = Plugins::SlimPing::Auth::Permissions->requireRole($args->{user}, 'playlistRole')) {
        return $err;
    }
    my $id = $args->{params}{id}
        or return Plugins::SlimPing::Utils::Errors->missingParam('id');

    my ($type, $raw_id) = Plugins::SlimPing::Core::LibraryMapper->decodeId($id);
    return Plugins::SlimPing::Utils::Errors->notFound('Playlist') unless defined $raw_id;

    # Provider 2: DPL4 dynamic playlist
    if ( $type && $type eq 'dynamic_playlist' ) {
        return { playlist => $dpl_bridge->()->getPlaylistWithTracks($raw_id, $args->{user}{username}) };
    }

    # Provider 1: LMS static/SSP playlist
    my $pl = $store->()->getPlaylist($raw_id);
    return Plugins::SlimPing::Utils::Errors->notFound('Playlist') unless $pl;

    return { playlist => $mapper->()->shapePlaylist($pl, 1) };
}

sub createPlaylist {
    my ($args) = @_;
    require Plugins::SlimPing::Auth::Permissions;
    if (my $err = Plugins::SlimPing::Auth::Permissions->requireRole($args->{user}, 'playlistRole')) {
        return $err;
    }
    my $p    = $args->{params};
    my $name = $p->{name}
        or return Plugins::SlimPing::Utils::Errors->missingParam('name');

    my @song_ids = Plugins::SlimPing::Utils::Params->multiParam($p->{songId});
    my ($pl, $err) = $store->()->createPlaylist($name, \@song_ids);
    return Plugins::SlimPing::Utils::Errors->error(0, $err) if $err;

    return { playlist => $mapper->()->shapePlaylist($pl, 1) };
}

sub updatePlaylist {
    my ($args) = @_;
    require Plugins::SlimPing::Auth::Permissions;
    if (my $err = Plugins::SlimPing::Auth::Permissions->requireRole($args->{user}, 'playlistRole')) {
        return $err;
    }
    my $p  = $args->{params};
    my $id = $p->{playlistId}
        or return Plugins::SlimPing::Utils::Errors->missingParam('playlistId');

    my ($type, $raw_id) = Plugins::SlimPing::Core::LibraryMapper->decodeId($id);
    return Plugins::SlimPing::Utils::Errors->notFound('Playlist') unless defined $raw_id;

    # Guard: DPL playlists are read-only
    return Plugins::SlimPing::Utils::Errors->error(50, 'Dynamic playlists are read-only')
        if $type && $type eq 'dynamic_playlist';

    my $changes = {
        remove_indices => [ Plugins::SlimPing::Utils::Params->multiParam($p->{songIndexToRemove}) ],
        add_song_ids   => [ Plugins::SlimPing::Utils::Params->multiParam($p->{songIdToAdd}) ],
    };
    $changes->{name}    = $p->{name}    if defined $p->{name}    && length $p->{name};
    $changes->{comment} = $p->{comment} if defined $p->{comment};

    my ($pl, $err) = $store->()->updatePlaylist($raw_id, $changes);
    return Plugins::SlimPing::Utils::Errors->error(50, $err) if $err && $err =~ /read-only/;
    return Plugins::SlimPing::Utils::Errors->error(0, $err)  if $err;

    return {};
}

sub deletePlaylist {
    my ($args) = @_;
    require Plugins::SlimPing::Auth::Permissions;
    if (my $err = Plugins::SlimPing::Auth::Permissions->requireRole($args->{user}, 'playlistRole')) {
        return $err;
    }
    my $id = $args->{params}{id}
        or return Plugins::SlimPing::Utils::Errors->missingParam('id');

    my ($type, $raw_id) = Plugins::SlimPing::Core::LibraryMapper->decodeId($id);
    return Plugins::SlimPing::Utils::Errors->notFound('Playlist') unless defined $raw_id;

    # Guard: DPL playlists are read-only
    return Plugins::SlimPing::Utils::Errors->error(50, 'Dynamic playlists are read-only')
        if $type && $type eq 'dynamic_playlist';

    my $err = $store->()->deletePlaylist($raw_id);
    return Plugins::SlimPing::Utils::Errors->error(50, $err) if $err && $err =~ /read-only/;
    return Plugins::SlimPing::Utils::Errors->error(0, $err)  if $err;

    return {};
}

1;
