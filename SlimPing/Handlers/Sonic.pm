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
# Handlers/Sonic.pm - OpenSubsonic sonic endpoints
#
# getSonicSimilarTracks: similar tracks with similarity scores, served by
# the registered sonic provider (Core::SonicRegistry) or the built-in
# DSTM bridge.  Similarity is -1 when the provider has no score.
#
# findSonicPath: a path between two songs, served by a provider's findPath
# capability when present, otherwise a greedy chained walk through the
# provider's similarTracks (hop budget dstm_path_hops).  Partial paths are
# returned as-is; a path that reaches the end song marks it 1.0.
#
# Both endpoints are gated by the dstm_mix_level pref: 'similarity'/'full'
# for getSonicSimilarTracks, 'full' for findSonicPath.  Below the gate the
# handler returns the stub-style code 0 error, consistent with the plugin's
# convention for unimplemented capabilities.
#

package Plugins::SlimPing::Handlers::Sonic;

use strict;
use warnings;

use Plugins::SlimPing::API::Router;
use Plugins::SlimPing::Core::Logging;

my $log   = Plugins::SlimPing::Core::Logging->getLogger();
my $prefs = Plugins::SlimPing::Core::Logging->getPrefs();

sub registerHandlers {
    my $class = shift;
    Plugins::SlimPing::API::Router->registerHandler( 'getSonicSimilarTracks', \&getSonicSimilarTracks );
    Plugins::SlimPing::API::Router->registerHandler( 'findSonicPath',         \&findSonicPath );
}

sub getSonicSimilarTracks {
    my ($args) = @_;

    my $level = _level();
    return _disabledError('getSonicSimilarTracks')
      unless $level eq 'similarity' || $level eq 'full';

    my $params = $args->{params};
    my $id     = $params->{id};
    return { error => { code => 10, message => 'Required parameter id is missing' } }
      unless defined $id && length $id;
    my $count = _clampCount( $params->{count} // 10, 0, 500 );

    my $track = _resolveTrack($id);
    return { error => { code => 70, message => 'Track not found' } } unless $track;

    require Plugins::SlimPing::Core::SonicRegistry;
    my $provider = Plugins::SlimPing::Core::SonicRegistry->bestProvider();
    return { sonicMatch => [] } unless $provider;

    my $ctx = _ctxFor( $args, $provider );

    # A deferred provider answers from a callback.  Hand it a completion, let
    # the Router hold the response open, and build the payload inside the
    # builder so it runs with the request's identity restored (shaping a track
    # needs the requesting user and base URL).
    if ( $provider->{deferred} && ref $args->{defer} eq 'CODE' ) {

        # A provider that never calls back should degrade like one that failed:
        # an empty result, not an error envelope.
        $args->{defer_timeout_result} = { sonicMatch => [] };

        my $done = $args->{defer}->();

        eval {
            $provider->{similarTracks}->(
                $track, $count, $ctx,
                sub {
                    my ($results) = @_;
                    $done->(
                        sub {
                            { sonicMatch => [ map { _sonicMatchEntry($_) } @{ $results || [] } ] };
                        }
                    );
                }
            );
        };
        if ($@) {
            my $error = $@;
            chomp $error;
            $log->warn( 'SlimPing: sonic provider ' . $provider->{id} . " failed: $error" );
            $done->( sub { { sonicMatch => [] } } );
        }

        return;
    }

    my $results = eval { $provider->{similarTracks}->( $track, $count, $ctx ) };
    if ($@) {
        $log->warn( 'SlimPing: sonic provider ' . $provider->{id} . " failed: $@" );
        return { sonicMatch => [] };
    }
    $results ||= [];

    return { sonicMatch => [ map { _sonicMatchEntry($_) } @$results ] };
}

sub findSonicPath {
    my ($args) = @_;

    my $level = _level();
    return _disabledError('findSonicPath') unless $level eq 'full';

    my $params   = $args->{params};
    my $start_id = $params->{startSongId};
    my $end_id   = $params->{endSongId};
    return { error => { code => 10, message => 'Required parameter startSongId is missing' } }
      unless defined $start_id && length $start_id;
    return { error => { code => 10, message => 'Required parameter endSongId is missing' } }
      unless defined $end_id && length $end_id;
    my $count = _clampCount( $params->{count} // 25, 1, 500 );

    my $start = _resolveTrack($start_id);
    return { error => { code => 70, message => 'Track not found' } } unless $start;
    my $end = _resolveTrack($end_id);
    return { error => { code => 70, message => 'Track not found' } } unless $end;

    require Plugins::SlimPing::Core::SonicRegistry;
    my $provider = Plugins::SlimPing::Core::SonicRegistry->bestProvider();
    return { sonicMatch => [] } unless $provider;

    my $ctx = _ctxFor( $args, $provider );

    # A provider that answers similarTracks from a callback has no synchronous
    # answer for the chained walk, so a deferred provider that does not supply
    # its own findPath simply has no path to offer.
    if ( $provider->{deferred} && ref $provider->{findPath} ne 'CODE' ) {
        $log->debug( 'SlimPing: deferred sonic provider ' . $provider->{id} . ' has no synchronous findPath' );
        return { sonicMatch => [] };
    }

    my $path;
    if ( ref $provider->{findPath} eq 'CODE' ) {
        $path = eval { $provider->{findPath}->( $start, $end, $count, $ctx ) };
        $@ && $log->warn( 'SlimPing: sonic provider ' . $provider->{id} . " findPath failed: $@" );
    }
    $path ||= _chainedPath( $provider, $start, $end, $count, $ctx );

    require Plugins::SlimPing::Core::Container;
    my $mapper = Plugins::SlimPing::Core::Container->get('library_mapper');

    my @entries;
    for my $i ( 0 .. $#$path ) {
        my $t   = $path->[$i]{track} or next;
        my $sim = defined $path->[$i]{similarity} ? $path->[$i]{similarity} : -1;
        $sim = -1  if $sim < -1;
        $sim =  1  if $sim > 1;
        $sim = 1.0 if $i == $#$path && $t->id() == $end->id();
        push @entries, { entry => $mapper->shapeTrack($t), similarity => $sim };
    }

    return { sonicMatch => \@entries };
}

# --- Private helpers --------------------------------------------------------

# Greedy walk: at each hop ask the provider for similar tracks and prefer
# the hop sharing the most signal with the end song (artist, then album,
# then genre overlap).  Stops on arrival, on a repeat visit, or when the
# hop budget (dstm_path_hops) is exhausted.  Returns an arrayref of
# { track, similarity } entries - the same shape provider findPath results
# use; the last entry is the end song (similarity 1.0) when the path
# reached it, otherwise all entries carry -1.
sub _chainedPath {
    my ( $provider, $start, $end, $count, $ctx ) = @_;

    my $hops = $prefs->get('dstm_path_hops') // 25;

    my @path;
    my %seen;
    my $current = $start;
    my $i       = 0;

    # The end song's genre set is invariant across the walk; resolve it
    # once (Track::genres() queries the DB per call).
    my %end_genres = map { $_->name() => 1 } $end->genres();

    while ( $current && $i < $hops ) {
        $i++;
        my $id = $current->id();
        return \@path if $seen{$id}++;
        push @path, { track => $current, similarity => -1 };
        if ( $id == $end->id() ) {
            $path[-1]{similarity} = 1.0;
            return \@path;
        }

        my $results = eval { $provider->{similarTracks}->( $current, $count, $ctx ) };
        if ($@) {
            $log->warn( 'SlimPing: sonic provider ' . $provider->{id} . " failed in path walk: $@" );
        }
        $results ||= [];

        my ( $best, $best_score ) = ( undef, -1 );
        for my $r (@$results) {
            my $t     = $r->{track} or next;
            my $score = _signalScore( $t, $end, \%end_genres );
            if ( $score > $best_score ) {
                ( $best, $best_score ) = ( $t, $score );
            }
        }
        $current = $best;
    }

    return \@path;
}

# Similarity signal between two tracks: 3 for the same artist, 2 for the
# same album, 1 per shared genre.  $end_genres is the end song's genre
# name set, resolved once by the caller.
sub _signalScore {
    my ( $track, $end, $end_genres ) = @_;

    my $score = 0;

    if ( $track->artist && $end->artist ) {
        $score += 3 if $track->artist->id() == $end->artist->id();
    }
    if ( $track->album && $end->album ) {
        $score += 2 if $track->album->id() == $end->album->id();
    }

    for my $g ( $track->genres() ) {
        $score++ if $end_genres->{ $g->name() };
    }

    return $score;
}

sub _sonicMatchEntry {
    my ($result) = @_;

    my $track = $result->{track} or return ();
    my $sim   = defined $result->{similarity} ? $result->{similarity} : -1;
    $sim = -1 if $sim < -1;
    $sim =  1 if $sim > 1;

    require Plugins::SlimPing::Core::Container;
    my $mapper = Plugins::SlimPing::Core::Container->get('library_mapper');
    return { entry => $mapper->shapeTrack($track), similarity => $sim };
}

# Request context for the provider call.  The 'dstm' provider needs the
# session's active virtual player; registry providers never see a client.
sub _ctxFor {
    my ( $args, $provider ) = @_;

    my $ctx = {
        username    => $args->{user}{username},
        client_name => $args->{client_name},
    };

    if ( $provider->{id} eq Plugins::SlimPing::Core::SonicRegistry::BUILTIN_ID() ) {
        require Plugins::SlimPing::Core::MixerBridge;
        $ctx->{client} = Plugins::SlimPing::Core::MixerBridge->findClient( $args->{client_name} );
    }

    return $ctx;
}

sub _resolveTrack {
    my ($id) = @_;

    require Plugins::SlimPing::Core::Container;
    my $mapper = Plugins::SlimPing::Core::Container->get('library_mapper');
    my ( $type, $raw_id ) = $mapper->decodeId($id);
    return undef unless $type eq 'track' && defined $raw_id;

    # Facade route (arch lint: handlers must not touch Slim::Schema).
    # getTracksByIds returns DBIx Track objects, unlike getTrackById
    # which returns a shaped hash.
    my @tracks = $mapper->getTracksByIds( [$raw_id] );
    return $tracks[0];
}

sub _clampCount {
    my ( $count, $min, $max ) = @_;
    $count = $min if $count < $min;
    $count = $max if $count > $max;
    return $count;
}

sub _level {
    return $prefs->get('dstm_mix_level') || 'off';
}

sub _disabledError {
    my ($endpoint) = @_;
    return { error => { code => 0, message => "$endpoint is disabled (DSTM integration level)" } };
}

1;
