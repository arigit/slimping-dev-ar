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
# Core/PluginProbe.pm - Probing optional integration plugins
#
# Startup probes for the plugins SlimPing integrates with when they are present
# (Alternative Play Count, Ratings Light, and so on).  Two things have to be
# right for an integration to work: the plugin must be installed and loadable,
# and it must be new enough to expose the dispatch SlimPing calls.  An older
# release would otherwise reject every call and log a warning per play or
# rating.
#
# Perl detail worth stating, because getting it wrong silently disables an
# integration: `require $module` with a string value treats it as a *filename*,
# not a module name, so `require 'Plugins::Foo::Plugin'` looks for a file with
# that literal name and always fails.  This module converts the module name to a
# path itself and requires that, which searches @INC as expected.
#
# The version comes from the plugin's own install.xml, next to the module file
# reported in %INC, rather than from PluginManager internals.  When it cannot be
# read the probe stays optimistic: it is better to enable a working integration
# than to disable it because an LM/S release moved something.
#

package Plugins::SlimPing::Core::PluginProbe;

use strict;
use warnings;

# Module name to a path relative to an @INC entry.
sub moduleFile {
    my ( $class, $module ) = @_;
    return undef unless defined $module && length $module;

    ( my $file = $module ) =~ s{::}{/}g;
    return "$file.pm";
}

# Full path of a module in @INC, or undef.  Does not load anything.
sub findModuleFile {
    my ( $class, $module ) = @_;

    my $file = $class->moduleFile($module) or return undef;

    for my $dir (@INC) {
        next if ref $dir;
        my $path = "$dir/$file";
        return $path if -f $path;
    }

    return undef;
}

# Load a module by name.  Returns 1 on success (including already loaded).
sub loadModule {
    my ( $class, $module ) = @_;

    my $file = $class->moduleFile($module) or return 0;
    return eval { require $file; 1 } ? 1 : 0;
}

# The plugin's declared version, or undef when it cannot be determined.
sub installedVersion {
    my ( $class, $module ) = @_;

    my $file = $class->moduleFile($module)                    or return undef;
    my $path = $INC{$file} || $class->findModuleFile($module) or return undef;

    ( my $dir = $path ) =~ s{[/\\][^/\\]+$}{};
    my $install = "$dir/install.xml";

    open my $fh, '<', $install or return undef;
    local $/;
    my $xml = <$fh>;
    close $fh;

    return undef unless defined $xml;
    return $1 if $xml =~ m{<version>\s*([^<\s]+)\s*</version>};
    return undef;
}

# Compare dotted version strings numerically, so 3.10 is newer than 3.9.
# Any non-numeric suffix on a part (a dev build's "0005-dev") is ignored.
sub versionAtLeast {
    my ( $class, $have, $need ) = @_;
    return 0 unless defined $have && defined $need;

    my @have = $class->_parts($have);
    my @need = $class->_parts($need);

    for my $i ( 0 .. $#need ) {
        my $have_part = $have[$i] // 0;
        my $need_part = $need[$i] // 0;
        return 1 if $have_part > $need_part;
        return 0 if $have_part < $need_part;
    }

    return 1;
}

sub _parts {
    my ( $class, $version ) = @_;
    return map { /^(\d+)/ ? 0 + $1 : 0 } split /\./, $version;
}

# Is an optional integration plugin installed, loadable and new enough?
sub available {
    my ( $class, $module, $min_version ) = @_;

    return 0 unless $class->loadModule($module);

    my $version = $class->installedVersion($module);
    return 1 unless defined $version;

    return $class->versionAtLeast( $version, $min_version );
}

1;
