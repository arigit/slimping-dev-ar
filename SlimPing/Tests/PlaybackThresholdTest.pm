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
# Tests/PlaybackThresholdTest.pm - runtime coverage for the scrobble threshold
#
# A reportPlayback "stopped" says only that playback ended, so SlimPing applies
# the standard half-the-track-or-240-seconds scrobble rule before recording a
# completed play.  These cases pin that rule, including the cap that stops a
# long track being counted after only a few minutes.
#
# Runs inside LMS -- PlaybackReporter is a plugin module.
#

package Plugins::SlimPing::Tests::PlaybackThresholdTest;

use strict;
use warnings;

# [ label, duration seconds, position seconds, expected ]
my @CASES = (
    [ 'no position reported',               300,  0,     0 ],
    [ 'no position reported (undef)',       300,  undef, 0 ],
    [ 'unknown duration',                   0,    120,   0 ],
    [ 'negative position',                  300,  -5,    0 ],
    [ 'short track, below half',            100,  49,    0 ],
    [ 'short track, exactly half',          100,  50,    1 ],
    [ 'short track, past half',             100,  80,    1 ],
    [ 'below the 240s cap',                 600,  200,   0 ],
    [ 'exactly the 240s cap',               600,  240,   1 ],
    [ 'very long track, cap still applies', 3600, 239,   0 ],
    [ 'very long track, cap reached',       3600, 240,   1 ],
);

sub runChecks {
    my ($class) = @_;

    my @checks;
    require Plugins::SlimPing::Core::PlaybackReporter;

    for my $case (@CASES) {
        my ( $label, $duration, $position, $expected ) = @$case;
        my $got = eval { Plugins::SlimPing::Core::PlaybackReporter->playedEnough( $duration, $position ) };
        if ($@) {
            my $error = $@;
            chomp $error;
            push @checks, { label => $label, ok => 0, detail => "died: $error" };
            next;
        }
        push @checks,
          {
            label  => $label,
            ok     => ( ( $got ? 1 : 0 ) == $expected ) ? 1 : 0,
            detail => "expected $expected, got "
              . ( $got ? 1 : 0 )
              . " (duration=$duration position="
              . ( defined $position ? $position : 'undef' ) . ')',
          };
    }

    return \@checks;
}

1;
