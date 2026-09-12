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

# SlimPing Plugin - Centralised Logging Utility
#
# This module provides centralised access to the plugin's logger and preferences,
# eliminating duplication across modules.
#
# Usage in any module:
#   use Plugins::SlimPing::Core::Logging;
#
#   my $log   = Plugins::SlimPing::Core::Logging->getLogger();
#   my $prefs = Plugins::SlimPing::Core::Logging->getPrefs();

package Plugins::SlimPing::Core::Logging;

use strict;
use warnings;

use Slim::Utils::Log;
use Slim::Utils::Prefs;

my $log;
my $prefs;
my $server_prefs;

# Initialise logger and preferences at compile time.
# Fail-fast: die here prevents LMS from starting on logger/prefs init failure.
# This is intentional -- a broken plugin should not silently degrade.
BEGIN {
    $log = Slim::Utils::Log::logger('plugin.slimping')
      or die "Failed to initialise SlimPing logger";
    $prefs = Slim::Utils::Prefs::preferences('plugin.slimping')
      or die "Failed to initialise SlimPing preferences";
    $server_prefs = Slim::Utils::Prefs::preferences('server')
      or die "Failed to initialise LMS server preferences";
}

# Get the plugin's logger instance
# Returns: Slim::Utils::Log logger object

sub getLogger {
    return $log;
}

# Get the plugin's preferences instance
# Returns: Slim::Utils::Prefs preferences object

sub getPrefs {
    return $prefs;
}

# Get the LMS-server preferences instance (the 'server' namespace).
# Use this whenever you need to read or write LMS-wide prefs such as
# `authorize`, `transcodeBitrate`, etc.  Plugin-local prefs go through
# getPrefs() -- never mix the two.
# Returns: Slim::Utils::Prefs preferences object
sub getServerPrefs {
    return $server_prefs;
}

# Returns true if the named feature pref is enabled in plugin preferences.
# All features default to enabled (1) when no explicit pref is set.
sub isFeatureEnabled {
    my ( $class, $pref_key ) = @_;
    return 1 unless defined $prefs->get($pref_key);
    return $prefs->get($pref_key) ? 1 : 0;
}

1;
