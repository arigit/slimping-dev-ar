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
# Handlers/Users.pm - Subsonic user handler (read-only, self-serve)
#
# Only getUser is exposed via the REST API -- it returns the calling user's
# details with full role set.  All user management operations (create, update,
# delete, list, changePassword) are permanently stubbed with code 0 because
# user administration belongs exclusively in the plugin settings UI behind
# LMS web authentication.
#

package Plugins::SlimPing::Handlers::Users;

use strict;
use warnings;

use Plugins::SlimPing::API::Router;
use Plugins::SlimPing::Auth::Permissions;

sub registerHandlers {
    my $class = shift;
    Plugins::SlimPing::API::Router->registerHandler('getUser', \&getUser);
}

sub _shapeUser {
    my ($u) = @_;
    # OpenSubsonic user spec includes optional legacy fields: maxBitRate,
    # folder (int[]), avatarLastChanged.  SlimPing does not support per-user
    # bitrate caps, folder-scoped access control, or user avatars.  Per spec
    # rule "if a server support a field it must return it," these are
    # correctly omitted.  Returning dummy values would be misleading
    # (maxBitRate: 0 blocks all streaming, folder: [] says no access).
    my $roles = Plugins::SlimPing::Auth::Permissions->rolesFor($u);
    return {
        username            => $u->{username},
        adminRole           => $roles->{adminRole}           ? \1 : \0,
        settingsRole        => $roles->{settingsRole}        ? \1 : \0,
        downloadRole        => $roles->{downloadRole}        ? \1 : \0,
        uploadRole          => $roles->{uploadRole}          ? \1 : \0,
        playlistRole        => $roles->{playlistRole}        ? \1 : \0,
        coverArtRole        => $roles->{coverArtRole}        ? \1 : \0,
        commentRole         => $roles->{commentRole}         ? \1 : \0,
        podcastRole         => $roles->{podcastRole}         ? \1 : \0,
        streamRole          => $roles->{streamRole}          ? \1 : \0,
        jukeboxRole         => $roles->{jukeboxRole}         ? \1 : \0,
        shareRole           => $roles->{shareRole}           ? \1 : \0,
        videoConversionRole => $roles->{videoConversionRole} ? \1 : \0,
        scrobblingEnabled   => \1,
    };
}

sub getUser {
    my ($args) = @_;
    my $user = $args->{user};
    return { user => _shapeUser($user) };
}

1;
