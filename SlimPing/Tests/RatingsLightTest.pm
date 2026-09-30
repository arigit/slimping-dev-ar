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
# Tests/RatingsLightTest.pm - runtime coverage for the rating scale conversion
#
# Ratings Light stores whole percent (0-100, 20 per star) and also allows
# half-star values such as 70 = 3.5, while Subsonic's userRating is whole stars
# 0-5.  A wrong conversion silently shows the wrong number of stars, or clears
# a rating, so both directions are pinned here, including the midpoint rule and
# the clamps.
#
# Runs inside LMS -- RatingsLight is a plugin module.  Only the pure conversion
# helpers are covered; the SQL read and the dispatch need a live library.
#

package Plugins::SlimPing::Tests::RatingsLightTest;

use strict;
use warnings;

# [ label, input, expected ] for percentToStars
my @TO_STARS = (
    [ 'zero is unrated',            0,   0 ],
    [ 'one star',                   20,  1 ],
    [ 'just under one star',        19,  1 ],
    [ 'half star rounds up',        10,  1 ],
    [ 'two stars',                  40,  2 ],
    [ 'half star at 3.5 rounds up', 70,  4 ],
    [ 'three stars',                60,  3 ],
    [ 'four stars',                 80,  4 ],
    [ 'five stars',                 100, 5 ],
    [ 'above the scale clamps',     140, 5 ],
);

# [ label, input, expected ] for starsToPercent
my @TO_PERCENT = (
    [ 'unrated clears',          0, 0 ],
    [ 'one star',                1, 20 ],
    [ 'three stars',             3, 60 ],
    [ 'five stars',              5, 100 ],
    [ 'above the scale clamps',  7, 100 ],
    [ 'negative clamps',        -1, 0 ],
);

# [ label, input, expected ] for ratingFromPercent.  undef means "unrated" --
# the caller must fall through to its own store rather than accept a 0.
my @FROM_PERCENT = (
    [ 'clear is unrated',         0,   undef ],
    [ 'half a star is unrated',   9,   undef ],
    [ 'one percent is unrated',   1,   undef ],
    [ 'legacy 1-5 star value: 1', 1,   undef ],
    [ 'legacy 1-5 star value: 3', 3,   undef ],
    [ 'legacy 1-5 star value: 5', 5,   undef ],
    [ 'ten percent is one star',  10,  1 ],
    [ 'one star',                 20,  1 ],
    [ 'half star rounds up',      70,  4 ],
    [ 'five stars',               100, 5 ],
);

sub runChecks {
    my ($class) = @_;

    require Plugins::SlimPing::Core::RatingsLight;
    my $rl = 'Plugins::SlimPing::Core::RatingsLight';

    my @checks;

    for my $case (@TO_STARS) {
        my ( $label, $input, $expected ) = @$case;
        my $got = eval { $rl->percentToStars($input) };
        my $ok  = !$@ && defined $got && $got == $expected;
        push @checks,
          {
            label  => "percentToStars: $label",
            ok     => $ok ? 1 : 0,
            detail => "expected $expected, got " . ( $@ ? "error: $@" : ( defined $got ? $got : 'undef' ) ),
          };
    }

    for my $case (@TO_PERCENT) {
        my ( $label, $input, $expected ) = @$case;
        my $got = eval { $rl->starsToPercent($input) };
        my $ok  = !$@ && defined $got && $got == $expected;
        push @checks,
          {
            label  => "starsToPercent: $label",
            ok     => $ok ? 1 : 0,
            detail => "expected $expected, got " . ( $@ ? "error: $@" : ( defined $got ? $got : 'undef' ) ),
          };
    }

    for my $case (@FROM_PERCENT) {
        my ( $label, $input, $expected ) = @$case;
        my $got = eval { $rl->ratingFromPercent($input) };
        my $ok;
        if ( defined $expected ) {
            $ok = !$@ && defined $got && $got == $expected;
        }
        else {
            $ok = !$@ && !defined $got;
        }
        push @checks,
          {
            label  => "ratingFromPercent: $label",
            ok     => $ok ? 1 : 0,
            detail => 'expected '
              . ( defined $expected ? $expected : 'undef' )
              . ', got '
              . ( $@ ? "error: $@" : ( defined $got ? $got : 'undef' ) ),
          };
    }

    # A whole-star rating must survive a round trip through RL's scale.
    for my $stars ( 1 .. 5 ) {
        my $percent = $rl->starsToPercent($stars);
        my $back    = $rl->ratingFromPercent($percent);
        push @checks,
          {
            label  => "round trip: $stars star(s)",
            ok     => ( defined $back && $back == $stars ) ? 1 : 0,
            detail => "rated $stars, stored as $percent, read back as " . ( defined $back ? $back : 'undef' ),
          };
    }

    return \@checks;
}

1;
