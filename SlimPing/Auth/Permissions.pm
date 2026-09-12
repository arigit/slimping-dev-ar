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
# Auth/Permissions.pm - Role-based authorisation for SlimPing
#
# Permission model uses a single `admin` boolean stored on each user record.
# The full 12-role Subsonic spec hash is DERIVED from this boolean (plus the
# dynamic jukeboxRole which requires a configured player target).
#
# Role mappings -- User tier (admin => 0):
#   ON:  streamRole, downloadRole, playlistRole, coverArtRole
#   OFF: adminRole, settingsRole, uploadRole, commentRole, podcastRole,
#        shareRole, videoConversionRole
#   DYNAMIC: jukeboxRole (1 when jukebox_player is set, else 0)
#
# Role mappings -- Admin tier (admin => 1):
#   ON:  all roles
#   DYNAMIC: jukeboxRole (1 when jukebox_player is set, else 0)
#
# Usage in a handler:
#   require Plugins::SlimPing::Auth::Permissions;
#   if ( my $err = Plugins::SlimPing::Auth::Permissions->requireRole($args->{user}, 'adminRole') ) {
#       return $err;
#   }
#

package Plugins::SlimPing::Auth::Permissions;

use strict;
use warnings;

# Standard roles for non-admin users.  These are the Subsonic-expected defaults
# for a read-only streaming account: browse, search, stream, download, playlists,
# and cover art.  Everything else requires admin.
my %USER_ROLES = (
    adminRole           => 0,
    settingsRole        => 0,
    downloadRole        => 1,
    uploadRole          => 0,
    playlistRole        => 1,
    coverArtRole        => 1,
    commentRole         => 0,
    podcastRole         => 0,
    streamRole          => 1,
    jukeboxRole         => 0,
    shareRole           => 1,
    videoConversionRole => 0,
);

# Admin users get every role enabled.  jukeboxRole is patched dynamically in
# rolesFor() -- it is only 1 when a jukebox target player is configured.
my %ADMIN_ROLES = map { $_ => 1 } keys %USER_ROLES;

# Returns the effective roles hashref for $user, derived from the admin boolean
# and the jukebox_player assignment.  The hashref is freshly allocated each call
# so callers can mutate it safely.
sub rolesFor {
    my ($class, $user) = @_;
    my $roles = $user->{admin} ? { %ADMIN_ROLES } : { %USER_ROLES };
    $roles->{jukeboxRole} = $user->{jukebox_player} ? 1 : 0;
    return $roles;
}

# Returns true (1) if $user has $role set.
sub hasRole {
    my ($class, $user, $role) = @_;
    return $class->rolesFor($user)->{$role} ? 1 : 0;
}

# Returns undef on success, or a ready-to-return error hashref on failure.
# Callers can write:  return requireRole(...) // do { ... };
# Error code 50 = user not authorised, per Subsonic spec.
sub requireRole {
    my ($class, $user, $role) = @_;
    return undef if $class->hasRole($user, $role);
    return { error => { code => 50, message => 'User is not authorised for this operation' } };
}

1;
