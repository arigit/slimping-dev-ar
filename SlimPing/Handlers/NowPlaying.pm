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
# Handlers/NowPlaying.pm - Play queue and play-state handlers
#
# Manages per-user play queues (getPlayQueue/savePlayQueue) via the
# lightweight SessionState store.  getNowPlaying is handled by Browse.pm
# -- it reads from live LMS players which is what Subsonic clients
# actually expect from that endpoint.
#

package Plugins::SlimPing::Handlers::NowPlaying;

use strict;
use warnings;

use Plugins::SlimPing::API::Router;
require Plugins::SlimPing::Core::Container;
require Plugins::SlimPing::Utils::Errors;
require Plugins::SlimPing::Utils::Params;

sub registerHandlers {
    my $class = shift;
    Plugins::SlimPing::API::Router->registerHandler('getPlayQueue',         \&getPlayQueue);
    Plugins::SlimPing::API::Router->registerHandler('savePlayQueue',        \&savePlayQueue);
    Plugins::SlimPing::API::Router->registerHandler('getPlayQueueByIndex',  \&getPlayQueueByIndex);
    Plugins::SlimPing::API::Router->registerHandler('savePlayQueueByIndex', \&savePlayQueueByIndex);
}

my $mapper   = sub { Plugins::SlimPing::Core::Container->get('library_mapper') };
my $sessions = sub { Plugins::SlimPing::Core::Container->get('session_state') };

sub getPlayQueue {
    my ($args) = @_;

    my $username    = $args->{user}{username};
    my $client_name = $args->{client_name};
    my $queue       = $sessions->()->getQueue($username, $client_name);

    # Batch-resolve track IDs with prefetch instead of calling getTrackById()
    # N times -- each call would trigger individual find() + shapeTrack() with
    # lazy loads for album, artist, and genre.
    my @entries;
    my $mapper_obj = $mapper->();
    my @raw_ids;
    my @sq_ids = @{ $queue->{entry} };
    my %sq_to_raw;
    for my $sq_id (@sq_ids) {
        my (undef, $raw_id) = $mapper_obj->decodeId($sq_id);
        if (defined $raw_id) {
            push @raw_ids, $raw_id;
            $sq_to_raw{$raw_id} = $sq_id;
        }
    }

    my %shaped;
    if (@raw_ids) {
        my @track_objs = $mapper_obj->getTracksByIds(\@raw_ids);

        my $track_genre = $mapper_obj->batchFetchTrackGenres(\@track_objs);

        # Batch-fetch annotations so shapeTrack does zero per-track lookups.
        my @track_rows = map { [ $_->id() ] } @track_objs;
        my ($starred, $ratings) = $mapper_obj->_batchFetchAnnotations('track', \@track_rows);

        %shaped = map {
            my $encoded = $mapper_obj->encodeId('track', $_->id());
            $_->id() => $mapper_obj->shapeTrack($_, $track_genre->{$_->id()}, undef, {
                starredAt        => $starred->{$encoded},
                rating           => $ratings->{$encoded},
                bookmarkPosition => undef,
            })
        } @track_objs;
    }

    for my $sq_id (@sq_ids) {
        my (undef, $raw_id) = $mapper_obj->decodeId($sq_id);
        if (defined $raw_id && $shaped{$raw_id}) {
            push @entries, $shaped{$raw_id};
        } else {
            push @entries, { id => $sq_id, title => '(unknown)' };
        }
    }

    my $changed_ts = $queue->{changed};
    my $changed_iso = Plugins::SlimPing::Core::LibraryMapper::_iso8601($changed_ts)
        // Plugins::SlimPing::Core::LibraryMapper::_iso8601(time());

    return {
        playQueue => {
            entry     => \@entries,
            current   => $queue->{current},
            position  => $queue->{position},
            username  => $queue->{username},
            changed   => $changed_iso,
            changedBy => $queue->{changedBy} // '',
        }
    };
}

sub savePlayQueue {
    my ($args) = @_;

    my $p           = $args->{params};
    my $username    = $args->{user}{username};
    my $client_name = $args->{client_name};

    my @ids = Plugins::SlimPing::Utils::Params->multiParam($p->{id});

    # Per OpenSubsonic spec: if entry is non-empty, current must be
    # a valid track ID in the entry list and is a string, not an index.
    if (@ids && defined $p->{current} && length $p->{current}) {
        my %id_set = map { $_ => 1 } @ids;
        unless ($id_set{$p->{current}}) {
            # Code 0 rather than 10: the parameter is present but has an
            # invalid value.  Subsonic has no "invalid value" error code;
            # Navidrome uses 0 for this case.
            return Plugins::SlimPing::Utils::Errors->error(0,
                'current must be a valid track ID in the entry list');
        }
    }

    # Per OpenSubsonic spec, position is in milliseconds.
    $sessions->()->saveQueue(
        username    => $username,
        client_name => $client_name,
        track_ids   => \@ids,
        current     => $p->{current},
        position    => $p->{position},
    );

    return {};
}

# indexBasedQueue extension: returns currentIndex (integer position) and
# position in milliseconds instead of the legacy current (track ID string)
# and position in seconds.  Reuses the getPlayQueue batch-resolve logic so
# the track shaping path stays in one place.
sub getPlayQueueByIndex {
    my ($args) = @_;

    # Delegate to the legacy handler for all track resolution and shaping.
    my $result = getPlayQueue($args);
    my $queue  = $result->{playQueue};

    # Compute currentIndex from the track ID stored in SessionState.
    my @sq_ids = map { $_->{id} } @{ $queue->{entry} };
    my $current_track_id = delete $queue->{current};
    my $idx = 0;
    if ( defined $current_track_id && length $current_track_id ) {
        for my $i ( 0 .. $#sq_ids ) {
            if ( $sq_ids[$i] eq $current_track_id ) {
                $idx = $i;
                last;
            }
        }
    }

    # SessionStore keeps position in seconds; OpenSubsonic index-based spec
    # requires milliseconds.
    $queue->{position} = int( ( $queue->{position} // 0 ) * 1000 );
    $queue->{currentIndex} = $idx;

    return $result;
}

# indexBasedQueue extension: accepts currentIndex and position in ms.
# Converts to the legacy representation (current track ID, position in
# seconds) and delegates to the existing SessionState storage.
sub savePlayQueueByIndex {
    my ($args) = @_;

    my $p           = $args->{params};
    my $username    = $args->{user}{username};
    my $client_name = $args->{client_name};

    my @ids = Plugins::SlimPing::Utils::Params->multiParam( $p->{id} );
    my $index = $p->{currentIndex};

    # Convert currentIndex to a track ID for SessionState storage.
    # currentIndex is optional per the OpenSubsonic spec; omit when absent.
    my $current_id;
    if ( defined $index && length $index ) {
        if ( $index < 0 || $index > $#ids ) {
            return Plugins::SlimPing::Utils::Errors->error( 0,
                'currentIndex out of range' );
        }
        $current_id = $ids[$index];
    }

    # Convert position from milliseconds to seconds for storage.
    my $position_secs = int( ( $p->{position} // 0 ) / 1000 );

    $sessions->()->saveQueue(
        username    => $username,
        client_name => $client_name,
        track_ids   => \@ids,
        current     => $current_id,
        position    => $position_secs,
    );

    return {};
}

1;
