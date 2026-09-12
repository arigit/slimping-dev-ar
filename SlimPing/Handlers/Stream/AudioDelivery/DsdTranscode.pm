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
# Handlers/Stream/AudioDelivery/DsdTranscode.pm - DSD transcoding and detection helpers
#
# Extracted from AudioDelivery.pm.  Handles DSD format detection, lossless
# suffix detection, output sample rate selection, and DSD->FLAC->MP3 delivery
# paths.
#

package Plugins::SlimPing::Handlers::Stream::AudioDelivery::DsdTranscode;

use strict;
use warnings;

require Plugins::SlimPing::Core::Container;
require Plugins::SlimPing::Core::Logging;

my $log = Plugins::SlimPing::Core::Logging->getLogger();


# Determine the output sample rate for DSD->FLAC transcoding.
# Reads the exotic_target_rate preference (default 44100, CD quality).
# DSD at 44.1kHz produces manageable file sizes for streaming.
# 88.2/176.4kHz available for high-bandwidth setups via settings.
sub selectOutputRate {
    my ($track) = @_;
    my $prefs = Plugins::SlimPing::Core::Logging->getPrefs();
    my $rate  = $prefs->get('exotic_target_rate');
    $rate = 44100  if $rate < 44100;
    $rate = 176400 if $rate > 176400;
    return $rate;
}

1;
