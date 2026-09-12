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
# Core/PlaylistStore.pm - Playlist persistence layer
#
# Encapsulates all Slim::Schema mutation and LMS playlist infrastructure
# calls so that handlers do not import Slim::Schema directly.
# Follows the same singleton pattern as StarStore and BookmarkStore.
#
# This module is in the data-access tier and is granted an
# architecture-check exception.
#

package Plugins::SlimPing::Core::PlaylistStore;

use strict;
use warnings;

use Scalar::Util qw(blessed);
use Slim::Schema;
use Slim::Player::Client;
use Slim::Player::Playlist;
use Slim::Utils::Misc;
use Slim::Utils::Text;
use Slim::Utils::Unicode;
use File::Spec::Functions qw(catfile);

use Plugins::SlimPing::Core::Logging;
require Plugins::SlimPing::Core::LibraryMapper;

my $log   = Plugins::SlimPing::Core::Logging->getLogger();
my $prefs = Plugins::SlimPing::Core::Logging->getPrefs();

my $_instance;

sub getInstance {
    my $class = shift;
    $_instance //= bless {}, $class;
    return $_instance;
}

# --- Read operations -----------------------------------------------------------

sub getAllPlaylists {
    my $self = shift;
    my $rs   = Slim::Schema->rs('Playlist')->getPlaylists('all');
    return $rs ? $rs->all() : ();
}

sub getPlaylist {
    my ( $self, $raw_id ) = @_;
    return undef unless defined $raw_id;
    return Slim::Schema->find( 'Playlist', $raw_id );
}

# --- Write operations ----------------------------------------------------------

sub createPlaylist {
    my ( $self, $name, $song_ids ) = @_;

    my $playlist_dir = Slim::Utils::Misc::getPlaylistDir();
    return ( undef, 'No playlist directory configured in LMS' )
        unless $playlist_dir;

    my $clean = Slim::Utils::Misc::cleanupFilename($name);
    my $url   = Slim::Utils::Misc::fileURLFromPath(
        catfile( $playlist_dir, Slim::Utils::Unicode::encode_locale($clean) . '.m3u' )
    );

    my $pl = Slim::Schema->updateOrCreate({
        url        => $url,
        playlist   => 1,
        attributes => { TITLE => $name, CT => 'ssp' },
    });
    return ( undef, 'Failed to create playlist' ) unless blessed($pl);

    $pl->set_column( 'titlesort', Slim::Utils::Text::ignoreCaseArticles($name) );
    $pl->update;

    if ( $song_ids && @$song_ids ) {
        my @urls = $self->resolveTrackUrls($song_ids);
        $pl->setTracks( \@urls ) if @urls;
    }

    Slim::Schema->forceCommit;
    Slim::Player::Playlist::scheduleWriteOfPlaylist( undef, $pl );

    return ( $pl, undef );
}

sub updatePlaylist {
    my ( $self, $raw_id, $changes ) = @_;

    my $pl = Slim::Schema->find( 'Playlist', $raw_id );
    return ( undef, 'Playlist not found' ) unless $pl;

    if ( ( $pl->content_type() // '' ) ne 'ssp' ) {
        return ( undef, 'This playlist is read-only' );
    }

    if ( defined $changes->{name} && length $changes->{name} ) {
        $pl->set_column( 'title',     $changes->{name} );
        $pl->set_column( 'titlesort', Slim::Utils::Text::ignoreCaseArticles( $changes->{name} ) );
        $pl->update;
    }

    if ( defined $changes->{comment} ) {
        $pl->set_column( 'comment', $changes->{comment} );
        $pl->update;
    }

    my @tracks = $pl->tracks->all();

    my @to_remove = sort { $b <=> $a } @{ $changes->{remove_indices} || [] };
    for my $idx (@to_remove) {
        splice( @tracks, $idx, 1 ) if $idx >= 0 && $idx < scalar @tracks;
    }

    my $to_add = $changes->{add_song_ids} || [];
    if ( @$to_add ) {
        my @new_urls = $self->resolveTrackUrls($to_add);
        push @tracks, map { Slim::Schema->objectForUrl( { url => $_ } ) } @new_urls;
    }

    $pl->setTracks( [ map { $_->url() } @tracks ] );

    Slim::Schema->forceCommit;
    Slim::Player::Playlist::scheduleWriteOfPlaylist( undef, $pl );

    return ( $pl, undef );
}

sub deletePlaylist {
    my ( $self, $raw_id ) = @_;

    my $pl = Slim::Schema->find( 'Playlist', $raw_id );
    return 'Playlist not found' unless $pl;

    if ( ( $pl->content_type() // '' ) ne 'ssp' ) {
        return 'This playlist is read-only';
    }

    # Clear from any active player queues
    for my $client ( Slim::Player::Client::clients() ) {
        if ( $client->currentPlaylist && $client->currentPlaylist->id == $raw_id ) {
            $client->currentPlaylist(0);
            $client->currentPlaylistUpdateTime( Time::HiRes::time() );
        }
    }

    Slim::Player::Playlist::removePlaylistFromDisk($pl);
    $pl->setTracks([]);
    $pl->delete;
    Slim::Schema->forceCommit;

    return undef;
}

# --- Utility -------------------------------------------------------------------

sub resolveTrackUrls {
    my ( $self, $sq_ids ) = @_;
    my @urls;
    for my $sq_id ( @$sq_ids ) {
        my ( undef, $raw_id ) = Plugins::SlimPing::Core::LibraryMapper->decodeId($sq_id);
        if ( !defined $raw_id ) {
            $log->info("SlimPing: unresolvable songId=$sq_id - cannot decode, skipping");
            next;
        }
        my $track = Slim::Schema->find( 'Track', $raw_id );
        if ( !$track ) {
            $log->info("SlimPing: unresolvable songId=$sq_id (raw_id=$raw_id) - track not found, skipping");
            next;
        }
        push @urls, $track->url();
    }
    return @urls;
}

1;
