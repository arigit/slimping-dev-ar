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
# Utils/Format.pm - Presentation formatting helpers
#
# Stateless utility for formatting values for display output (durations,
# bitrates, file sizes, etc.).  Distinct from Utils::Params which normalises
# untrusted HTTP input to a known shape.
#

package Plugins::SlimPing::Utils::Format;

use strict;
use warnings;

# Format a duration in seconds as "m:ss" or "h:mm:ss".
# Returns '0:00' for undef, zero, or negative input.
sub formatDuration {
    my ($class, $secs) = @_;
    return '0:00' unless $secs && $secs > 0;
    my $m = int($secs / 60);
    my $s = int($secs % 60);
    my $h = int($m / 60);
    $m = $m % 60;
    return $h > 0 ? sprintf('%d:%02d:%02d', $h, $m, $s) : sprintf('%d:%02d', $m, $s);
}

1;
