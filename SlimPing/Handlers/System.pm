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
# Handlers/System.pm - System information and administration handlers
#
# Implements OpenSubsonic system handlers for ping, license information, and
# extension discovery. These are the fundamental system endpoints that clients
# use to verify server availability and discover supported API extensions.
#

package Plugins::SlimPing::Handlers::System;

use strict;
use warnings;

use Plugins::SlimPing::API::Router;

sub registerHandlers {
    my $class = shift;
    Plugins::SlimPing::API::Router->registerHandler('ping',                      \&ping);
    Plugins::SlimPing::API::Router->registerHandler('getLicense',                \&getLicense);
    Plugins::SlimPing::API::Router->registerHandler('getOpenSubsonicExtensions', \&getOpenSubsonicExtensions);
}

sub ping {
    return {};    # Empty payload -- ResponseFormatter adds status:ok and version
}

sub getLicense {
    return {
        license => {
            valid => \1,
            email => '',
            # OpenSubsonic license spec includes optional licenseExpires and
            # trialExpires fields.  SlimPing is a free plugin with no licensing
            # model, so these are correctly omitted per spec rule.
        }
    };
}

sub getOpenSubsonicExtensions {
    return {
        openSubsonicExtensions => [
            { name => 'apiKeyAuthentication', versions => [1] },
            { name => 'formPost',             versions => [1] },
            { name => 'jukeboxControl',       versions => [1] },
            { name => 'savePlayQueue',        versions => [1] },
            { name => 'indexBasedQueue',      versions => [1] },
            { name => 'songLyrics',           versions => [1, 2] },
            { name => 'songRating',           versions => [1] },
            { name => 'star',                 versions => [1] },
            { name => 'coverArtResize',       versions => [1] },
            { name => 'playCount',            versions => [1] },
            { name => 'playbackReport',       versions => [1] },
            { name => 'transcodeDecision',    versions => [1] },
            { name => 'transcodeOffset',      versions => [1] },
            { name => 'transcoding',          versions => [1] },
        ]
    };
}

1;
