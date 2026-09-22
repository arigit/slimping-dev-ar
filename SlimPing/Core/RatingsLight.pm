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
# Core/RatingsLight.pm - Two-way rating sync with the Ratings Light plugin
#
# Stateless utility -- class methods only, no constructor.  Called from
# Core/Annotations.pm, the single choke point for per-user rating
# read/write, so every call site (Subsonic API, InfoMenu, LibraryMapper
# shaping) picks this up automatically.
#
# The Ratings Light plugin (RL, github.com/AF-1/lms-ratingslight) stores
# its ratings directly in LMS's own tracks_persistent.rating column (0-100,
# 20 per star) rather than a table of its own. That means reads don't need
# RL's CLI dispatch at all -- a single batched SQL join against
# tracks_persistent (same join RawQueries/Shapes already use for
# playcount/lastplayed) is both correct and just as cheap as SlimPing's own
# rating reads, so fetching per-song ratings during a client sync does not
# add N dispatch round-trips.
#
# Writes still go through RL's own CLI dispatch rather than a raw UPDATE,
# since RL owns rating-change notifications and its virtual-library/backup
# bookkeeping for that column.  Since v?.?.? RL exposes a "noclient" variant
# for exactly SlimPing's situation -- ratings set by an OpenSubsonic client
# never pass through a real Slim::Player::Client:
#
#   ['ratingslight', 'setratingpercentnoclient', '_trackid', '_rating', '_incremental']
#   ['ratingslight', 'getrating', '_trackid']
#
# Gated on RL being installed (startup probe flag). Track ratings only --
# RL has no concept of album/artist ratings, so Annotations.pm falls back
# to SlimPing's own per-user RatingStore for those ids, and for tracks
# whenever RL is not present.

package Plugins::SlimPing::Core::RatingsLight;

use strict;
use warnings;

use Slim::Control::Request;
use Slim::Schema;

use Plugins::SlimPing::Core::Logging;
require Plugins::SlimPing::Core::Container;

my $log = Plugins::SlimPing::Core::Logging->getLogger();

# Set once by Plugin.pm at startup -- plugins cannot be installed mid-session.
my $_available = 0;

sub setAvailable { $_available = $_[1] ? 1 : 0; }
sub available    { return $_available; }

# Push a user-set rating (0-5 stars) to Ratings Light. Returns 1 on success,
# 0 on skip/failure (all failures are logged, caller ignores the return
# value -- RL sync is best-effort and never blocks the Subsonic response).
sub submit {
    my ( $class, $sq_id, $rating ) = @_;

    return 0 unless $_available;
    return 0 unless defined $sq_id && length $sq_id;

    my $mapper = Plugins::SlimPing::Core::Container->get('library_mapper');
    my ( $type, $raw_id ) = eval { $mapper->decodeId($sq_id) };
    if ( $@ || !defined $raw_id || ( $type // '' ) ne 'track' ) {
        return 0;
    }

    my $percent = int($rating) * 20;

    my $request = eval {
        Slim::Control::Request::executeRequest( undef, [
            'ratingslight', 'setratingpercentnoclient', $raw_id, $percent,
        ] );
    };
    if ($@) {
        $log->warn("SlimPing: RatingsLight setrating dispatch failed for $sq_id: $@");
        return 0;
    }

    if ( $request && eval { $request->isStatusError } ) {
        $log->warn("SlimPing: RatingsLight setrating rejected for $sq_id (raw=$raw_id)");
        return 0;
    }

    $log->debug("SlimPing: RatingsLight rating pushed for $sq_id (raw=$raw_id, percent=$percent)");
    return 1;
}

# Batch-read ratings straight from tracks_persistent. Accepts an arrayref of
# *track* sq_ids (callers are expected to have already filtered out
# album/artist ids -- decodeId does not identify as 'track' for those, so
# they are silently skipped here too as a safety net). Returns
# { sq_id => rating(0-5) }, containing only tracks with a rating recorded
# in Ratings Light -- absence means "not rated", same contract as
# RatingStore::getRatingBatch.
sub fetchBatch {
    my ( $class, $sq_ids ) = @_;
    return {} unless $_available;
    return {} unless $sq_ids && ref $sq_ids eq 'ARRAY' && @$sq_ids;

    my $mapper = Plugins::SlimPing::Core::Container->get('library_mapper');
    my %raw_to_sq;
    for my $sq_id (@$sq_ids) {
        my ( $type, $raw_id ) = eval { $mapper->decodeId($sq_id) };
        next if $@ || !defined $raw_id || ( $type // '' ) ne 'track';
        $raw_to_sq{$raw_id} = $sq_id;
    }
    return {} unless keys %raw_to_sq;

    my @raw_ids = keys %raw_to_sq;
    my $placeholders = join( ',', ('?') x @raw_ids );
    my $sql = "SELECT t.id, tp.rating FROM tracks t"
            . " JOIN tracks_persistent tp ON tp.urlmd5 = t.urlmd5"
            . " WHERE t.id IN ($placeholders) AND tp.rating IS NOT NULL AND tp.rating > 0";

    my %result;
    eval {
        my $dbh = Slim::Schema->dbh;
        my $sth = $dbh->prepare($sql);
        $sth->execute(@raw_ids);
        while ( my ( $id, $percent ) = $sth->fetchrow_array() ) {
            my $sq_id = $raw_to_sq{$id} or next;
            # Round to the nearest whole star -- Subsonic's userRating field
            # is an integer 1-5; RL's half-star values (e.g. 70 = 3.5) round
            # up at the midpoint.
            $result{$sq_id} = int( ( $percent / 20 ) + 0.5 );
        }
        $sth->finish();
    };
    if ($@) {
        $log->warn("SlimPing: RatingsLight batch rating read failed: $@");
        return {};
    }
    return \%result;
}

sub fetchOne {
    my ( $class, $sq_id ) = @_;
    return undef unless defined $sq_id;
    my $batch = $class->fetchBatch( [$sq_id] );
    return $batch->{$sq_id};
}

1;
