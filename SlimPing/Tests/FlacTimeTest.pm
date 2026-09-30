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
# Tests/FlacTimeTest.pm - runtime coverage for the flac seek time formatter
#
# CueLossless::formatFlacTime feeds both `flac --skip` (CUE segments and DSD
# seeks) and `flac --until` (CUE segment length).  flac accepts only MM:SS.SS
# or a bare sample count, and rejects H:MM:SS.SS outright, so the previous
# hour-aware form silently broke every segment starting more than an hour into
# its source file.  These cases pin the accepted form and the rounding.
#
# Runs inside LMS -- the module under test is part of the plugin.  The values
# were confirmed against flac 1.4.2.
#

package Plugins::SlimPing::Tests::FlacTimeTest;

use strict;
use warnings;

# [ label, input seconds, expected output ]
my @CASES = (
    [ 'zero seconds',                            0,      '0:00.00' ],
    [ 'sub-second value',                        0.5,    '0:00.50' ],
    [ 'just under a minute carries the minute',  59.996, '1:00.00' ],
    [ 'exactly one minute',                      60,     '1:00.00' ],
    [ 'under an hour is unchanged',              3106,   '51:46.00' ],
    [ 'exactly one hour counts minutes past 59', 3600,   '60:00.00' ],
    [ 'past the hour (the reported failure)',    3773.6, '62:53.60' ],
    [ 'ten hours',                               36000,  '600:00.00' ],
    [ 'undef defaults to zero',                  undef,  '0:00.00' ],
);

sub runChecks {
    my ($class) = @_;

    my @checks;
    require Plugins::SlimPing::Handlers::Stream::AudioDelivery::CueLossless;

    for my $case (@CASES) {
        my ( $label, $secs, $expected ) = @$case;
        my $got = eval { Plugins::SlimPing::Handlers::Stream::AudioDelivery::CueLossless::formatFlacTime($secs) };
        if ($@) {
            my $error = $@;
            chomp $error;
            push @checks, { label => $label, ok => 0, detail => "died: $error" };
            next;
        }
        push @checks,
          {
            label  => $label,
            ok     => ( defined $got && $got eq $expected ) ? 1 : 0,
            detail => "expected $expected, got " . ( defined $got ? $got : 'undef' ),
          };
    }

    return \@checks;
}

1;
