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
# Utils/StoreHelpers.pm - DBIx utility functions shared across Store modules
#
# Provides flushForUser and flushAll as stateless class methods so the
# four annotation Stores (Bookmark, Session, Star, Rating) don't each
# carry byte-for-byte identical copies of the same DBIx plumbing.
#

package Plugins::SlimPing::Utils::StoreHelpers;

use strict;
use warnings;

use Plugins::SlimPing::Schema;
require Plugins::SlimPing::Core::UserStore;

# Delete all rows from a resultset, returning the count deleted.
sub flushAll {
    my ($class, $resultset_name) = @_;

    my $rs    = Plugins::SlimPing::Schema->connect()->resultset($resultset_name);
    my $count = $rs->count();
    $rs->delete();
    return $count;
}

# Delete all rows for a user from a given resultset, returning the count deleted.
sub flushForUser {
    my ($class, $username, $resultset_name) = @_;

    my $schema = Plugins::SlimPing::Schema->connect();
    my $user   = Plugins::SlimPing::Core::UserStore->getInstance->getByUsername($username)
        or return 0;

    my $count = $schema->resultset($resultset_name)->search({ user_id => $user->id() })->count();
    $schema->resultset($resultset_name)->search({ user_id => $user->id() })->delete();
    return $count;
}

1;
