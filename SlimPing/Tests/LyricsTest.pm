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
# Tests/LyricsTest.pm - runtime coverage for synced lyrics handling
#
# getLyricsBySongId must hand clients timed lines whenever any source has
# them.  These cases pin the local source choice (a synced sidecar beats
# unsynced tag lyrics), the LRC parse, and the [offset:] direction: positive
# makes lyrics appear sooner, so it is subtracted from every timestamp.
#
# Runs inside LMS -- the module under test is part of the plugin.
#

package Plugins::SlimPing::Tests::LyricsTest;

use strict;
use warnings;

my $SYNCED   = "[00:01.00]First line\n[00:05.50]Second line";
my $UNSYNCED = "First line\nSecond line";
my $SRT      = "1\n00:00:01,000 --> 00:00:04,000\nFirst line";

sub runChecks {
    my ($class) = @_;

    my @checks;
    require Plugins::SlimPing::Handlers::Lyrics;

    my $check = sub {
        my ( $label, $ok, $detail ) = @_;
        push @checks, { label => $label, ok => $ok ? 1 : 0, detail => $detail };
    };

    # --- Local source choice ---------------------------------------------

    my $choose = sub {
        my ( $embedded, $sidecar ) = @_;
        my $read = 0;
        my $got  = Plugins::SlimPing::Handlers::Lyrics::_chooseLocalLyrics( $embedded, sub { $read++; $sidecar } );
        return ( $got, $read );
    };
    my $show = sub { defined $_[0] ? "'$_[0]'" : 'undef' };

    my ( $got, $read ) = $choose->( $SYNCED, $UNSYNCED );
    $check->( 'synced tag lyrics win without reading a sidecar',
        ( $got // '' ) eq $SYNCED && !$read, 'got ' . $show->($got) . ", sidecar reads $read" );

    ($got) = $choose->( $UNSYNCED, $SYNCED );
    $check->( 'synced sidecar beats unsynced tag lyrics', ( $got // '' ) eq $SYNCED, 'got ' . $show->($got) );

    ($got) = $choose->( $UNSYNCED, $SRT );
    $check->( 'SRT sidecar counts as synced', ( $got // '' ) eq $SRT, 'got ' . $show->($got) );

    ($got) = $choose->( $UNSYNCED, "Other text" );
    $check->( 'unsynced tag lyrics beat an unsynced sidecar', ( $got // '' ) eq $UNSYNCED, 'got ' . $show->($got) );

    ($got) = $choose->( undef, $UNSYNCED );
    $check->( 'sidecar used when the tag has no lyrics', ( $got // '' ) eq $UNSYNCED, 'got ' . $show->($got) );

    ($got) = $choose->( "  \n", undef );
    $check->( 'blank lyrics count as none', !defined $got, 'got ' . $show->($got) );

    # --- LRC parse -------------------------------------------------------

    my ( $lines, $synced, $cues ) = Plugins::SlimPing::Handlers::Lyrics::_parseLrc($SYNCED);
    $check->(
        'LRC lines are synced with millisecond starts',
        $synced && @$lines == 2 && $lines->[0]{start} == 1000 && $lines->[1]{start} == 5500
          && $lines->[1]{value} eq 'Second line',
        'starts ' . join( ',', map { $_->{start} // 'undef' } @$lines )
    );

    ( $lines, $synced ) = Plugins::SlimPing::Handlers::Lyrics::_parseLrc("[ar:Someone]\n[offset:+500]\n$SYNCED");
    $check->(
        'positive [offset:] shows lyrics sooner',
        $synced && @$lines == 2 && $lines->[0]{start} == 500 && $lines->[1]{start} == 5000,
        'starts ' . join( ',', map { $_->{start} // 'undef' } @$lines )
    );

    ($lines) = Plugins::SlimPing::Handlers::Lyrics::_parseLrc("[offset:-250]\n$SYNCED");
    $check->( 'negative [offset:] shows lyrics later', $lines->[0]{start} == 1250, "start $lines->[0]{start}" );

    ($lines) = Plugins::SlimPing::Handlers::Lyrics::_parseLrc("[offset:+3000]\n$SYNCED");
    $check->( 'offset never makes a start negative', $lines->[0]{start} == 0, "start $lines->[0]{start}" );

    ( $lines, $synced, $cues ) =
      Plugins::SlimPing::Handlers::Lyrics::_parseLrc("[offset:+100]\n[00:02.00]<00:02.00>Hello</00:02.00> <00:02.50>world</00:02.50>");
    $check->(
        'ELRC word cues keep their text and follow the offset',
        $cues && @$cues == 1 && $lines->[0]{value} eq 'Hello world'
          && $cues->[0]{cue}[0]{start} == 1900 && $cues->[0]{cue}[1]{start} == 2400,
        $cues
        ? 'cue starts ' . join( ',', map { $_->{start} } @{ $cues->[0]{cue} } ) . ", line '$lines->[0]{value}'"
        : 'no cue lines'
    );

    return \@checks;
}

1;
