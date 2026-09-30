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
# Core/RatingsLight.pm - Rating sync with the Ratings Light plugin
#
# Stateless utility -- class methods only, no constructor.  Called from
# Core/Annotations.pm, the single choke point for rating read/write, so every
# call site (Subsonic API, InfoMenu, LibraryMapper shaping) picks it up.
#
# The Ratings Light plugin (RL, github.com/AF-1/lms-ratingslight) keeps track
# ratings in LMS's own tracks_persistent.rating column (0-100, 20 per star)
# rather than a table of its own, so reads need no dispatch: one batched SQL
# join against tracks_persistent -- the same join RawQueries/Shapes already use
# for playcount/lastplayed -- is as cheap as SlimPing's own rating reads and
# adds no round-trip per song during a client sync.
#
# Writes go through RL's dispatch rather than a raw UPDATE, because RL owns the
# change notifications and backup bookkeeping for that column.  Since v3.1.3 RL
# exposes a "noclient" variant for exactly SlimPing's situation -- ratings set by
# an OpenSubsonic client never pass through a real Slim::Player::Client:
#
#   ['ratingslight', 'setratingpercentnoclient', '_trackid', '_rating', '_incremental']
#
# The trailing _incremental parameter is deliberately omitted: LMS leaves it
# undef and RL then performs an absolute set, which is what a Subsonic
# setRating means.  Only the literal '+' and '-' values make it incremental.
#
# Ratings are server-global.  RL has one rating per track, not one per user, so
# with RL installed a track rating set by any Subsonic user is visible to every
# user.  SlimPing's per-user RatingStore is the fallback for tracks RL has no
# value for, and stays authoritative for album and artist ratings, which RL
# does not have.
#
# The column is read as RL's 0-100 scale.  An LMS database can still hold
# legacy 1-5 star values from before the scale changed (rating 1-5 with
# lastRated unset, as LMS itself never set it); RL folds those to zero, and so
# does ratingFromPercent, so they are reported as unrated rather than as a
# bogus low rating.  Measured on a 21k-track library: 1742 rated rows, all
# reachable through the urlmd5 join, none needing RL's url fallback.
#
# Gated on RL being installed and enabled at the version that added the
# noclient dispatch (startup probe flag).
#

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

# RL stores whole percent 0-100; Subsonic's userRating is whole stars 0-5.
# Round to the nearest star with the midpoint up (70 = 3.5 becomes 4).
sub percentToStars {
    my ( $class, $percent ) = @_;
    return 0 unless defined $percent;

    my $stars = int( ( $percent / 20 ) + 0.5 );
    $stars = 0 if $stars < 0;
    $stars = 5 if $stars > 5;
    return $stars;
}

# A stored percent as a Subsonic rating, or undef when it does not reach a whole
# star.  The column is 0-100, but LMS databases can still hold legacy 1-5 star
# values from before it was scaled (rating 1-5 with lastRated unset).  RL itself
# rounds those to zero, and returning a defined 0 here would shadow the caller's
# own rating with a meaningless value, so anything below half a star is treated
# as unrated and falls through to SlimPing's store.
sub ratingFromPercent {
    my ( $class, $percent ) = @_;

    my $stars = $class->percentToStars($percent);
    return $stars > 0 ? $stars : undef;
}

# Whole stars 0-5 to the percent RL expects.  0 clears the rating.
sub starsToPercent {
    my ( $class, $stars ) = @_;
    return 0 unless defined $stars;

    my $percent = int($stars) * 20;
    $percent = 0   if $percent < 0;
    $percent = 100 if $percent > 100;
    return $percent;
}

# Push a user-set rating (0-5 stars) to Ratings Light.  Returns 1 on success,
# 0 on skip or failure; all failures are logged and the caller ignores the
# return value, because RL sync is best effort and must never block the
# Subsonic response.
#
# RL also refuses writes silently, leaving no error status, while a library scan
# is running or when the track has no tracks_persistent row.  A 1 here therefore
# means "dispatch accepted", not "stored"; the caller keeps its own copy of the
# rating and reads it back when RL has no value for the track.
sub submit {
    my ( $class, $sq_id, $rating ) = @_;

    return 0 unless $_available;
    return 0 unless defined $sq_id && length $sq_id;

    my $mapper = Plugins::SlimPing::Core::Container->get('library_mapper');
    my ( $type, $raw_id ) = eval { $mapper->decodeId($sq_id) };
    if ( $@ || !defined $raw_id || ( $type // '' ) ne 'track' ) {
        return 0;
    }

    my $percent = $class->starsToPercent($rating);

    my $request = eval {
        Slim::Control::Request::executeRequest( undef,
            [ 'ratingslight', 'setratingpercentnoclient', $raw_id, $percent, ] );
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

# Batch-read ratings straight from tracks_persistent.  Accepts an arrayref of
# *track* sq_ids (callers have already filtered out album and artist ids;
# decodeId does not identify as 'track' for those, so they are skipped here too
# as a safety net).  Returns { sq_id => rating(0-5) }, containing only tracks
# with a rating recorded in Ratings Light -- absence means "not rated", the
# same contract as RatingStore::getRatingBatch.
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

    my @raw_ids      = keys %raw_to_sq;
    my $placeholders = join( ',', ('?') x @raw_ids );
    my $sql =
        'SELECT t.id, tp.rating FROM tracks t'
      . ' JOIN tracks_persistent tp ON tp.urlmd5 = t.urlmd5'
      . " WHERE t.id IN ($placeholders) AND tp.rating IS NOT NULL AND tp.rating > 0";

    my %result;
    my $ok = eval {
        my $dbh = Slim::Schema->dbh;
        my $sth = $dbh->prepare($sql);
        $sth->execute(@raw_ids);
        while ( my ( $id, $percent ) = $sth->fetchrow_array() ) {
            my $sq_id = $raw_to_sq{$id} or next;
            my $stars = $class->ratingFromPercent($percent);
            next unless defined $stars;
            $result{$sq_id} = $stars;
        }
        $sth->finish();
        1;
    };
    unless ($ok) {
        my $error = $@ || 'unknown error';
        chomp $error;
        $log->warn("SlimPing: RatingsLight batch rating read failed: $error");
        return {};
    }

    return \%result;
}

# Single-track read.  Returns undef when the track has no RL rating, so the
# caller can fall back to its own store.
sub fetchOne {
    my ( $class, $sq_id ) = @_;
    return undef unless defined $sq_id;

    my $batch = $class->fetchBatch( [$sq_id] );
    return $batch->{$sq_id};
}

1;
