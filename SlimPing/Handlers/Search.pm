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
# Handlers/Search.pm - OpenSubsonic search endpoint handlers
#

package Plugins::SlimPing::Handlers::Search;

use strict;
use warnings;

use Plugins::SlimPing::API::Router;
use Plugins::SlimPing::Core::LibraryMapper;
require Plugins::SlimPing::Core::Container;
require Plugins::SlimPing::Utils::Errors;

sub registerHandlers {
    my $class = shift;
    Plugins::SlimPing::API::Router->registerHandler('search2', \&search2);
    Plugins::SlimPing::API::Router->registerHandler('search3', \&search3);
}

sub search2 { return _search(shift, 2); }
sub search3 { return _search(shift, 3); }

sub _search {
    my ($args, $version) = @_;
    my $p = $args->{params};

    return Plugins::SlimPing::Utils::Errors->missingParam('query')
        unless defined $p->{query};
    my $query = $p->{query};

    $query = Plugins::SlimPing::Core::LibraryMapper->cleanSearchQuery($query);
    my $lib   = Plugins::SlimPing::Core::LibraryMapper->decodeLibraryParam($p);

    my $results = Plugins::SlimPing::Core::Container->get('library_mapper')->search(
        query        => $query,
        artistCount  => $p->{artistCount}  // 20,
        artistOffset => $p->{artistOffset} // 0,
        albumCount   => $p->{albumCount}   // 20,
        albumOffset  => $p->{albumOffset}  // 0,
        songCount    => $p->{songCount}    // 20,
        songOffset   => $p->{songOffset}   // 0,
        library_id   => $lib,
        ( $version == 2 ? (legacy => 1) : () ),
    );

    my $result_key = $version == 2 ? 'searchResult2' : 'searchResult3';
    return {
        $result_key => {
            artist => $results->{artists},
            album  => $results->{albums},
            song   => $results->{songs},
        }
    };
}

1;
