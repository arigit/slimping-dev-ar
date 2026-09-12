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
# Core/TextCacheStore.pm - Persistent text-content cache for artist biographies
#
# Caches artist biographies and similar long-form text content fetched from the
# Music & Artist Info (MAI) plugin.  MAI does not persist biographies to disk
# (unlike lyrics, which MAI caches in its lyricsFolder).  This store fills that
# gap so repeated getArtistInfo2 requests do not re-fetch from MAI on every call.
#
# The store is intentionally minimal: raw DBI, no DBIx::Class result class.
# TTL-based expiry is checked on get() with a bulk purge() available for
# admin/UI use.
#

package Plugins::SlimPing::Core::TextCacheStore;

use strict;
use warnings;

use Plugins::SlimPing::Core::Logging;
use Plugins::SlimPing::Schema;

my $log   = Plugins::SlimPing::Core::Logging->getLogger();
my $prefs = Plugins::SlimPing::Core::Logging->getPrefs();

my $_instance;

sub getInstance {
    my $class = shift;
    $_instance //= bless {}, $class;
    return $_instance;
}

# Retrieve cached text content.  Returns the content string on hit, undef on miss.
# Expired rows (fetched_at + ttl < now) are deleted on read.  Rows with NULL ttl
# never expire.
sub get {
    my ($self, $cache_key) = @_;
    return undef unless defined $cache_key && length $cache_key;

    my $dbh = Plugins::SlimPing::Schema->dbh();
    my ($content, $fetched_at, $ttl) = $dbh->selectrow_array(
        'SELECT content, fetched_at, ttl FROM text_cache WHERE cache_key = ?',
        undef, $cache_key,
    );
    return undef unless defined $content;

    if (defined $ttl && $fetched_at + $ttl < time()) {
        $dbh->do('DELETE FROM text_cache WHERE cache_key = ?', undef, $cache_key);
        return undef;
    }

    return $content;
}

# Store text content.  Upserts on cache_key so repeated fetches for the same
# artist overwrite the old entry.  $ttl_seconds is optional — undef means the
# row never expires, preserving backward compatibility with existing callers.
sub put {
    my ($self, $cache_key, $content, $ttl_seconds) = @_;
    return undef unless defined $cache_key && length $cache_key;
    return undef unless defined $content;

    my $dbh = Plugins::SlimPing::Schema->dbh();
    $dbh->do(
        'INSERT OR REPLACE INTO text_cache (cache_key, content, fetched_at, ttl) VALUES (?, ?, ?, ?)',
        undef, $cache_key, $content, time(), $ttl_seconds,
    );
    return 1;
}

# Delete all expired rows.  Rows with NULL ttl are never deleted.
sub purge {
    my ($self) = @_;

    my $dbh   = Plugins::SlimPing::Schema->dbh();
    my $now   = time();
    my $count = $dbh->do(
        'DELETE FROM text_cache WHERE ttl IS NOT NULL AND fetched_at + ttl < ?',
        undef, $now,
    );
    return $count;
}

1;
