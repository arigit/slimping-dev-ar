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
# Handlers/Stubs.pm - Placeholder handlers for unimplemented Phase B and C endpoints
#

package Plugins::SlimPing::Handlers::Stubs;

use strict;
use warnings;

use Plugins::SlimPing::API::Router;

# All unimplemented endpoints return a valid Subsonic error rather than
# an HTTP 404 -- many clients probe capabilities on startup and a 404
# causes them to abort rather than degrade gracefully.
my $_stub = sub {
    return { error => { code => 0, message => 'Not yet implemented' } };
};

# Endpoints permanently stubbed because their functionality belongs
# exclusively in the plugin settings UI or core LMS functionality.
my @PERMANENTLY_STUBBED = qw(
    getUsers createUser updateUser deleteUser changePassword getAvatar
    createInternetRadioStation
    updateInternetRadioStation deleteInternetRadioStation
);

my @OLD_SEARCH = qw(
    search
);

my @CHAT = qw(
    getChatMessages addChatMessage
);

# Podcast and video endpoints are stubbed for now pending a decision on whether to implement them.
# They are low priority and require a lot of work.
my @PODCAST = qw(
    getPodcasts createPodcastChannel deletePodcastChannel getPodcastEpisode
    refreshPodcasts downloadPodcastEpisode deletePodcastEpisode getNewestPodcasts
);

# Endpoints that require capabilities no LMS plugin provides (e.g. audio
# fingerprint analysis, video support, HLS streaming).
my @PERMANENTLY_UNSUPPORTED = qw(
    getSonicSimilarTracks findSonicPath
    getVideos getVideoInfo hls getCaptions    
);

sub registerHandlers {
    my $class = shift;
    for my $endpoint (@PERMANENTLY_STUBBED, @OLD_SEARCH, @CHAT, @PODCAST, @PERMANENTLY_UNSUPPORTED) {
        Plugins::SlimPing::API::Router->registerHandler($endpoint, $_stub);
    }
}

1;
