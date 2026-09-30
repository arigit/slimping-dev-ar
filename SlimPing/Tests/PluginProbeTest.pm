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
# Tests/PluginProbeTest.pm - runtime coverage for the optional-plugin probes
#
# The integration probes are easy to get wrong in a way that silently disables
# an integration: `require` with a string is a filename, not a module name, so
# a probe written as `eval { require $module }` fails for every plugin and only
# says so in a startup log line.  These checks cover the conversion, the
# version comparison, and the probe against a module that is definitely
# installed -- SlimPing itself.
#
# When the optional integrations are installed their probes are asserted too,
# so a regression here fails the suite on a machine where it matters.
#

package Plugins::SlimPing::Tests::PluginProbeTest;

use strict;
use warnings;

# [ label, version present, version required, expected ]
my @VERSIONS = (
    [ 'older patch release is too old',   '3.1.2',        '3.1.3', 0 ],
    [ 'same patch release is enough',     '3.1.5',        '3.1.3', 1 ],
    [ 'exact minimum',                    '1.9.5',        '1.9.5', 1 ],
    [ 'older minor is too old',           '1.8.9',        '1.9.5', 0 ],
    [ 'numeric minor, not lexical',       '3.10',         '3.9',   1 ],
    [ 'shorter present version is older', '2.0',          '2.0.1', 0 ],
    [ 'longer present version is newer',  '2.0.1',        '2.0',   1 ],
    [ 'development suffix is ignored',    '0.8.0005-dev', '0.0.1', 1 ],
    [ 'major beats minor',                '2.0',          '1.99',  1 ],
);

# Optional integrations: [ label, module, minimum version ]
my @INTEGRATIONS = (
    [ 'Alternative Play Count', 'Plugins::AlternativePlayCount::Plugin', '1.9.5' ],
    [ 'Ratings Light',          'Plugins::RatingsLight::Plugin',         '3.1.3' ],
);

sub runChecks {
    my ($class) = @_;

    require Plugins::SlimPing::Core::PluginProbe;
    my $probe = 'Plugins::SlimPing::Core::PluginProbe';

    my @checks;

    # Module name to path: the bug this suite exists for.
    for my $case (
        [ 'Plugins::Foo::Plugin',          'Plugins/Foo/Plugin.pm' ],
        [ 'Foo',                           'Foo.pm' ],
        [ 'Plugins::RatingsLight::Plugin', 'Plugins/RatingsLight/Plugin.pm' ],
      )
    {
        my ( $module, $expected ) = @$case;
        my $got = eval { $probe->moduleFile($module) };
        push @checks,
          {
            label  => "moduleFile: $module",
            ok     => ( !$@ && defined $got && $got eq $expected ) ? 1 : 0,
            detail => "expected $expected, got " . ( defined $got ? $got : 'undef' ),
          };
    }

    for my $case (@VERSIONS) {
        my ( $label, $have, $need, $expected ) = @$case;
        my $got = eval { $probe->versionAtLeast( $have, $need ) };
        push @checks,
          {
            label  => "versionAtLeast: $label",
            ok     => ( !$@ && ( $got ? 1 : 0 ) == $expected ) ? 1 : 0,
            detail => "$have vs $need: expected $expected, got " . ( $got ? 1 : 0 ),
          };
    }

    # SlimPing is installed by definition, so the probe must find it and read
    # its version.  This is the check that would have caught the filename-vs-
    # module bug in production: it returns 0 there.
    my $version = eval { $probe->installedVersion('Plugins::SlimPing::Plugin') };
    push @checks,
      {
        label  => 'installedVersion: SlimPing itself',
        ok     => ( !$@ && defined $version && $version =~ /^\d/ ) ? 1 : 0,
        detail => 'expected a version from install.xml, got ' . ( defined $version ? $version : 'undef' ),
      };

    my $self_ok = eval { $probe->available( 'Plugins::SlimPing::Plugin', '0.0.1' ) };
    push @checks,
      {
        label  => 'available: an installed module is detected',
        ok     => ( !$@ && $self_ok ) ? 1 : 0,
        detail => 'SlimPing is loaded, so the probe must return true',
      };

    my $too_new = eval { $probe->available( 'Plugins::SlimPing::Plugin', '99.0' ) };
    push @checks,
      {
        label  => 'available: a too-new requirement is rejected',
        ok     => ( !$@ && !$too_new ) ? 1 : 0,
        detail => 'a minimum of 99.0 must not be met',
      };

    my $missing = eval { $probe->available( 'Plugins::SlimPing::NoSuch::Plugin', '1.0' ) };
    push @checks,
      {
        label  => 'available: a missing module is rejected',
        ok     => ( !$@ && !$missing ) ? 1 : 0,
        detail => 'a module that does not exist must not be reported available',
      };

    # Optional integrations, only asserted where they are actually installed.
    for my $integration (@INTEGRATIONS) {
        my ( $label, $module, $min ) = @$integration;
        my $found = eval { $probe->findModuleFile($module) };
        next unless $found;

        my $installed_version = eval { $probe->installedVersion($module) };
        push @checks,
          {
            label  => "$label: version is readable",
            ok     => ( !$@ && defined $installed_version ) ? 1 : 0,
            detail => 'installed at ' . $found . ' but install.xml gave no version',
          };

        my $ok = eval { $probe->available( $module, $min ) };
        push @checks,
          {
            label  => "$label: detected at the required version",
            ok     => ( !$@ && $ok ) ? 1 : 0,
            detail => "$module is installed (version "
              . ( defined $installed_version ? $installed_version : 'unknown' )
              . ") but the probe did not enable it",
          };
    }

    return \@checks;
}

1;
