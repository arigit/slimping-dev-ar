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
# Core/SonicRegistry.pm - Provider registry for sonic similarity data
#
# Third-party mixer plugins (e.g. DSTM mixers with analysis databases)
# register a provider here to supply the OpenSubsonic sonic endpoints
# (getSonicSimilarTracks, findSonicPath) and the getSimilarSongs upgrade.
# The built-in 'dstm' provider (Core/MixerBridge) is registered at plugin
# init and is the fallback when no third-party provider exists.
#
# A provider may also declare deferred => 1 to answer from a callback (see
# API/DeferredResponse.pm and the FAQ in docs/dstm-plugin-integration.md).
# That applies to similarTracks; findPath stays synchronous.
#
# See docs/dstm-plugin-integration.md for the author-facing contract.
#
# Stateless class - class methods only, no constructor.
#

package Plugins::SlimPing::Core::SonicRegistry;

use strict;
use warnings;

use Plugins::SlimPing::Core::Logging;

my $log = Plugins::SlimPing::Core::Logging->getLogger();

# Id of the built-in bridge provider.  Reserved: third-party providers
# must not register under it (see docs/dstm-plugin-integration.md).
use constant BUILTIN_ID => 'dstm';

# id => { id, name, similarTracks, findPath, deferred }
my %_providers;

# Registration order (ids), so "most recently registered wins" is
# deterministic across plugin load order.
my @_order;

# Register (or replace) a provider.  Returns 1 on success, undef when the
# provider is missing its id or similarTracks callback.
#
# A provider may declare deferred => 1 to answer from a callback instead of
# returning synchronously: its similarTracks then receives a $done coderef and
# may return before calling it.  Everything else is unchanged, so providers
# that do not declare it behave exactly as before.
sub registerProvider {
    my ( $class, $provider ) = @_;

    unless ( ref $provider eq 'HASH' && $provider->{id} ) {
        $log->warn('SlimPing: sonic provider registration rejected: missing id');
        return undef;
    }
    unless ( ref $provider->{similarTracks} eq 'CODE' ) {
        $log->warn( 'SlimPing: sonic provider registration rejected for '
              . $provider->{id}
              . ': similarTracks is not a code ref' );
        return undef;
    }

    if ( !exists $_providers{ $provider->{id} } ) {
        push @_order, $provider->{id};
    }
    $_providers{ $provider->{id} } = $provider;
    $log->debug( 'SlimPing: sonic provider registered: '
          . $provider->{id}
          . ( $provider->{deferred} ? ' (deferred)' : '' ) );
    return 1;
}

# Read-only enumeration for the settings diagnostics table.  Returns an
# arrayref of { id, name, has_similar_tracks, has_find_path, deferred }.
sub listProviders {
    my ($class) = @_;

    my @out;
    for my $id (@_order) {
        my $p = $_providers{$id} or next;
        push @out,
          {
            id                 => $id,
            name               => $p->{name} || $id,
            has_similar_tracks => ( ref $p->{similarTracks} eq 'CODE' ) ? 1 : 0,
            has_find_path      => ( ref $p->{findPath} eq 'CODE' )      ? 1 : 0,
            deferred           => $p->{deferred} ? 1 : 0,
          };
    }
    return \@out;
}

# The provider to query: the most recently registered third-party provider,
# or the built-in 'dstm' provider when no third-party provider is
# registered.  Returns undef when nothing is registered.
sub bestProvider {
    my ($class) = @_;

    for my $id ( reverse @_order ) {
        next if $id eq BUILTIN_ID;
        return $_providers{$id};
    }
    return $_providers{BUILTIN_ID};
}

1;
