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
# Utils/IconUtils.pm - Menu icon resolution for LMS Material skin compatibility
#
# Follows patterns from https://github.com/CDrummond/lms-material/wiki/10-Icons
# PNG is the default format; Material skin auto-detects SVG when the PNG file
# is named <name>_svg.png.
#

package Plugins::SlimPing::Utils::IconUtils;

use strict;
use warnings;

use Plugins::SlimPing::Core::Logging;

my $log = Plugins::SlimPing::Core::Logging->getLogger();

my %ICON_DEFINITIONS = (
    'author' => {
        png         => 'plugins/SlimPing/html/images/author_svg.png',
        svg         => 'plugins/SlimPing/html/images/author.svg',
        description => 'Author/person icon',
    },
    'bookmarks' => {
        png         => 'plugins/SlimPing/html/images/bookmarks_svg.png',
        svg         => 'plugins/SlimPing/html/images/bookmarks.svg',
        description => 'Bookmarks icon',
    },
    'complete' => {
        png         => 'plugins/SlimPing/html/images/complete_svg.png',
        svg         => 'plugins/SlimPing/html/images/complete.svg',
        description => 'Starred/complete icon',
    },
    'icon' => {
        png         => 'plugins/SlimPing/html/images/icon_svg.png',
        svg         => 'plugins/SlimPing/html/images/icon.svg',
        description => 'Main plugin icon',
    },
    'info' => {
        png         => 'plugins/SlimPing/html/images/info_svg.png',
        svg         => 'plugins/SlimPing/html/images/info.svg',
        description => 'Information icon',
    },
    'nowplaying' => {
        png         => 'plugins/SlimPing/html/images/nowplaying_svg.png',
        svg         => 'plugins/SlimPing/html/images/nowplaying.svg',
        description => 'Now playing icon',
    },
    'statistics' => {
        png         => 'plugins/SlimPing/html/images/statistics_svg.png',
        svg         => 'plugins/SlimPing/html/images/statistics.svg',
        description => 'Statistics icon',
    },
    'time' => {
        png         => 'plugins/SlimPing/html/images/time_svg.png',
        svg         => 'plugins/SlimPing/html/images/time.svg',
        description => 'Time/duration icon',
    },
);

my %ICON_PATH_CACHE;

my $DEFAULT_ICON = 'icon';

sub getIcon {
    my ($class, $icon_name, $format) = @_;
    $format ||= 'png';

    my $cache_key = "$icon_name:$format";
    return $ICON_PATH_CACHE{$cache_key} if exists $ICON_PATH_CACHE{$cache_key};

    unless (exists $ICON_DEFINITIONS{$icon_name}) {
        $log->warn("IconUtils: Unknown icon requested: $icon_name");
        my $fallback_path = $ICON_DEFINITIONS{$DEFAULT_ICON}->{$format};
        $ICON_PATH_CACHE{$cache_key} = $fallback_path;
        return $fallback_path;
    }

    my $icon_path = $ICON_DEFINITIONS{$icon_name}->{$format};
    $ICON_PATH_CACHE{$cache_key} = $icon_path;
    return $icon_path;
}

1;
