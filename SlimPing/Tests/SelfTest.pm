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
# Tests/SelfTest.pm - In-server runtime test aggregator
#
# SlimPing cannot run conventional Perl unit tests: the plugin has no context
# until it is loaded inside a running Lyrion Music Server process. Logic that
# is not reachable over HTTP -- timer-driven state machines, time formatting,
# rating conversion -- is therefore verified by runtime tests that execute
# inside the LMS process and are triggered from the settings page (or the
# plugins/SlimPing/settings/runtime_tests JSON endpoint).
#
# Each suite is a plain module under Tests/ exposing runChecks(), which returns
# an arrayref of { label, ok, detail } hashes. Detail is only read when ok is
# false. A suite must not need a configured client, a live library scan or
# network access; anything that does belongs in the pytest OpenSubsonic harness
# under tests/ instead.
#

package Plugins::SlimPing::Tests::SelfTest;

use strict;
use warnings;

use Plugins::SlimPing::Core::Logging;

my $log = Plugins::SlimPing::Core::Logging->getLogger();

# [ human label, module, what it covers ]
my @SUITES = (
    [
        'CUE and DSD seek time formatting',
        'Plugins::SlimPing::Tests::FlacTimeTest',
        'flac --skip/--until accepted forms, including minutes past 59',
    ],
    [
        'reportPlayback scrobble threshold',
        'Plugins::SlimPing::Tests::PlaybackThresholdTest',
        'half-the-track-or-240s rule before a stop counts as a play',
    ],
    [
        'Alternative Play Count pass tracking',
        'Plugins::SlimPing::Tests::ApcTrackerTest',
        'play, skip, stop, pause, scrobble and restart event orderings',
    ],
    [
        'One APC report per play',
        'Plugins::SlimPing::Tests::PlaybackSubmissionTest',
        'a play the pass tracker owns is never dispatched to APC a second time',
    ],
    [
        'Deferred provider responses',
        'Plugins::SlimPing::Tests::DeferredResponseTest',
        'once-only completion, restored request context, watchdog and disconnect rails',
    ],
    [
        'Ratings Light rating conversion',
        'Plugins::SlimPing::Tests::RatingsLightTest',
        'percent to stars, stars to percent, and the round trip',
    ],
    [
        'Synced lyrics',
        'Plugins::SlimPing::Tests::LyricsTest',
        'local source choice, LRC parse and [offset:] direction',
    ],
    [
        'Optional integration probes',
        'Plugins::SlimPing::Tests::PluginProbeTest',
        'module-to-file conversion, version comparison and plugin detection',
    ],
);

# Registered suites as plain hashes, for display before a run.
sub suites {
    my ($class) = @_;
    return map { { label => $_->[0], module => $_->[1], description => $_->[2] } } @SUITES;
}

# Run every registered suite. Returns ( $passed, \@failures ) -- the shape used
# by the optional-integration self-tests elsewhere in the plugin, so a caller
# that only wants a pass/fail answer does not need the structured results.
sub runAllChecks {
    my ($class) = @_;

    my ( $summary, $results ) = $class->runAllSuites();
    my @failures;
    for my $suite (@$results) {
        push @failures, map { "$suite->{label}: $_->{label} - $_->{detail}" }
          grep { !$_->{ok} } @{ $suite->{checks} };
    }

    return ( $summary->{failed} == 0, \@failures );
}

# Run every registered suite. Returns ( \%summary, \@results ) where each result
# is { label, module, passed, checks => [ { label, ok, detail } ] }. A suite
# that fails to load or throws is reported as a single failed check so the
# caller never has to handle a partial run.
sub runAllSuites {
    my ($class) = @_;

    my @results;
    my %summary = ( suites => 0, checks => 0, passed => 0, failed => 0 );

    for my $suite ( $class->suites() ) {
        my $entry = {
            label  => $suite->{label},
            module => $suite->{module},
            passed => 1,
            checks => [],
        };

        my $loaded = eval {
            ( my $file = $suite->{module} ) =~ s{::}{/}g;
            require "$file.pm";
            my $checks = $suite->{module}->runChecks();
            $entry->{checks} = $checks if $checks && ref $checks eq 'ARRAY';
            1;
        };
        if ( !$loaded ) {
            my $error = $@ || 'unknown error';
            chomp $error;
            $entry->{checks} = [ { label => 'suite load', ok => 0, detail => $error } ];
        }

        for my $check ( @{ $entry->{checks} } ) {
            $summary{checks}++;
            if ( $check->{ok} ) {
                $summary{passed}++;
            }
            else {
                $summary{failed}++;
                $entry->{passed} = 0;
                $log->warn( sprintf 'SlimPing runtime test failed: %s / %s - %s',
                    $suite->{label}, $check->{label}, $check->{detail} // 'no detail' );
            }
        }

        $summary{suites}++;
        push @results, $entry;
    }

    return ( \%summary, \@results );
}

1;
