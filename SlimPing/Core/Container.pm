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
# Core/Container.pm - Lightweight dependency-injection container for SlimPing
#
# Services are registered by name during plugin post-initialisation and
# retrieved by name wherever they are needed.  This avoids tight coupling
# between modules and makes unit-testing straightforward by allowing
# mock services to be registered in place of the real ones.
#

package Plugins::SlimPing::Core::Container;

use strict;
use warnings;

use Plugins::SlimPing::Core::Logging;

my $log = Plugins::SlimPing::Core::Logging->getLogger();

my %_services;

# Register a named service instance in the container.
# Dies if name or instance is undefined (a programmer error during init).
# Warns -- rather than dies -- when overwriting an existing service so that
# legitimate hot-reload re-registration is non-fatal but still surfaced.
sub register {
    my ($class, $name, $instance) = @_;
    die "SlimPing::Container: register requires a service name"
        unless defined $name;
    die "SlimPing::Container: register requires a service instance for '$name'"
        unless defined $instance;
    if ( exists $_services{$name} ) {
        $log->warn("Container: overwriting service '$name'");
    }
    $_services{$name} = $instance;
}

# Retrieve a previously registered service by name.
# Dies if the requested service has not been registered.
sub get {
    my ($class, $name) = @_;
    die "SlimPing::Container: unknown service '$name'" unless exists $_services{$name};
    return $_services{$name};
}

# Register the three default Phase A services.
# Called from Plugin::postinitPlugin once all modules are loadable.
sub registerDefaultServices {
    my $class = shift;

    require Plugins::SlimPing::Auth::Manager;
    $class->register('auth_manager',
        Plugins::SlimPing::Auth::Manager->getInstance());

    require Plugins::SlimPing::Core::LibraryMapper;
    $class->register('library_mapper',
        Plugins::SlimPing::Core::LibraryMapper->getInstance());

    require Plugins::SlimPing::Core::SessionState;
    $class->register('session_state',
        Plugins::SlimPing::Core::SessionState->getInstance());
}

1;
