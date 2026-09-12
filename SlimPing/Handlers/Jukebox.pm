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
# Handlers/Jukebox.pm - Jukebox control handler
#
# Translates Subsonic jukeboxControl actions into Slim::Control::Request
# commands against a user-configured real LMS player.  If the target player
# is a sync-group master, all group members are controlled together.
#
# The target player is configured per-user via the settings page (stored as
# user.jukebox_player in plugin prefs).  A user must also have jukeboxRole
# set to 1 -- without it, all actions return Subsonic error code 50.
#

package Plugins::SlimPing::Handlers::Jukebox;

use strict;
use warnings;

use Slim::Player::Client;
use Slim::Player::Source;
use Plugins::SlimPing::API::Router;
use Plugins::SlimPing::Core::Logging;
require Plugins::SlimPing::Core::Container;
require Plugins::SlimPing::Utils::Errors;
require Plugins::SlimPing::Utils::Params;

my $log    = Plugins::SlimPing::Core::Logging->getLogger();
my $mapper = sub { Plugins::SlimPing::Core::Container->get('library_mapper') };

# Per-client entry cache for _get — avoids reshaping the full track list on
# every 1-second poll.  Invalidated by any mutation action (_set, _add,
# _remove, _clear, _shuffle).  Keyed by client MAC ($client->id()).
my %_get_cache;  # $client_id => { entries => \@entries, playlist_obj => $playlist }

sub registerHandlers {
    my $class = shift;
    Plugins::SlimPing::API::Router->registerHandler('jukeboxControl', \&jukeboxControl);
}

sub jukeboxControl {
    my ($args) = @_;

    my $p      = $args->{params};
    my $user   = $args->{user};
    my $action = $p->{action} // 'status';

    # Authorisation check -- user must have jukeboxRole
    require Plugins::SlimPing::Auth::Permissions;
    if (my $err = Plugins::SlimPing::Auth::Permissions->requireRole($user, 'jukeboxRole')) {
        return $err;
    }

    # Resolve the target LMS player
    my $player_id = $user->{jukebox_player};
    unless ($player_id) {
        return Plugins::SlimPing::Utils::Errors->error(50,
            'Jukebox not configured. Set a jukebox player in SlimPing settings.');
    }

    my $client = Slim::Player::Client::getClient($player_id);
    unless ($client) {
        $log->warn("SlimPing: jukebox player '$player_id' not found -- configured player may be offline");
        return Plugins::SlimPing::Utils::Errors->error(70,
            'Jukebox player is offline or no longer connected');
    }

    $log->debug("SlimPing: jukebox action=$action player=$player_id user=$user->{username}");

    return _dispatch($client, $action, $p);
}

# ---------------------------------------------------------------------------
# Action dispatcher
# ---------------------------------------------------------------------------

sub _dispatch {
    my ($client, $action, $p) = @_;

    if ($action eq 'status')    { return _status($client); }
    if ($action eq 'set')       { return _set($client, $p); }
    if ($action eq 'start')     { $client->execute(['play']);           return _status($client); }
    if ($action eq 'stop')      { $client->execute(['stop']);           return _status($client); }
    if ($action eq 'skip')      { return _skip($client, $p); }
    if ($action eq 'add')       { return _add($client, $p); }
    if ($action eq 'clear')     { $client->execute(['playlist', 'clear']);   _clearGetCache($client); return _status($client); }
    if ($action eq 'remove')    { return _remove($client, $p); }
    if ($action eq 'shuffle')   { $client->execute(['playlist', 'shuffle']); _clearGetCache($client); return _status($client); }
    if ($action eq 'get')       { return _get($client); }
    if ($action eq 'setGain')   { return _setGain($client, $p); }

    return Plugins::SlimPing::Utils::Errors->error(0, "Unknown jukebox action: $action");
}

# ---------------------------------------------------------------------------
# Action implementations
# ---------------------------------------------------------------------------

sub _status {
    my ($client, $expected_position) = @_;

    my $playlist = $client->currentPlaylist();
    my $index    = Slim::Player::Source::playingSongIndex($client) // 0;
    my $playing  = $client->isPlaying() ? \1 : \0;
    my $position;

    if ($playing) {
        my $track = $playlist ? $playlist->track($index) : undef;
        $position = $track ? ($client->songElapsedSeconds() // 0) : 0;
    } else {
        $position = 0;
    }

    # During the re-buffering window after a seek, songElapsedSeconds() may briefly
    # report 0 before the new stream position stabilises.  Use the known
    # target position so the client display does not flicker to 0:00.
    if (defined $expected_position && $expected_position > 0 && (!$position || $position < 1)) {
        $position = $expected_position;
    }

    my $vol = $client->volume();
    $vol = 100 unless defined $vol;

    return {
        jukeboxStatus => {
            currentIndex => int($index),
            playing      => $playing,
            gain         => $vol / 100.0,
            position     => int($position),
        }
    };
}

sub _set {
    my ($client, $p) = @_;

    my @ids = Plugins::SlimPing::Utils::Params->multiParam($p->{id});
    unless (@ids) {
        return Plugins::SlimPing::Utils::Errors->missingParam('id');
    }

    my $mapper = Plugins::SlimPing::Core::Container->get('library_mapper');
    my @paths = _resolvePaths($mapper, \@ids);

    # Clear current playlist and load the new tracks.
    # The client controls playback start via an explicit 'start' action.
    $client->execute(['playlist', 'clear']);
    if (@paths) {
        $client->execute(['playlist', 'addtracks', 'listref', \@paths]);
    }

    _clearGetCache($client);

    return _status($client);
}

sub _skip {
    my ($client, $p) = @_;
    my $expected_position;

    if (defined $p->{index}) {
        # Skip to a specific track index
        $client->execute(['playlist', 'index', int($p->{index})]);
    } elsif (defined $p->{offset}) {
        # Seek within the current track to offset seconds
        $expected_position = int($p->{offset});
        $client->execute(['time', $expected_position]);
    } else {
        # Neither index nor offset -- skip forward one track
        $client->execute(['playlist', 'jump', '+1']);
    }

    # After skipping to a track by index, apply optional time offset
    if (defined $p->{index} && defined $p->{offset}) {
        $expected_position = int($p->{offset});
        $client->execute(['time', $expected_position]);
    }

    return _status($client, $expected_position);
}

sub _add {
    my ($client, $p) = @_;
    my @ids = Plugins::SlimPing::Utils::Params->multiParam($p->{id});
    unless (@ids) {
        return Plugins::SlimPing::Utils::Errors->missingParam('id');
    }

    my $mapper = Plugins::SlimPing::Core::Container->get('library_mapper');
    my @paths = _resolvePaths($mapper, \@ids);
    for my $path (@paths) {
        $client->execute(['playlist', 'add', $path]);
    }

    _clearGetCache($client);

    return _status($client);
}

sub _remove {
    my ($client, $p) = @_;
    return Plugins::SlimPing::Utils::Errors->missingParam('index')
        unless defined $p->{index};

    $client->execute(['playlist', 'delete', int($p->{index})]);

    _clearGetCache($client);

    return _status($client);
}

sub _get {
    my ($client) = @_;

    my $playlist = $client->currentPlaylist();
    my $count    = $playlist ? $playlist->count() : 0;
    my $cache    = $_get_cache{$client->id()};

    # Rebuild the entry list only when the playlist object has changed
    # (LMS creates a new playlist object after clear+addtracks) or when
    # no cache entry exists.  Subsequent 1-second polls return instantly.
    my $entries;
    if ($cache && $cache->{playlist_obj} && $cache->{playlist_obj} == $playlist) {
        $entries = $cache->{entries};
    } elsif ($count > 0) {
        # Collect track URLs from the client playlist, then batch-resolve
        # through the facade to avoid per-track album/artist lazy loads.
        my @urls;
        for my $i (0 .. $count - 1) {
            my $track = $playlist->track($i);
            push @urls, $track->url() if $track;
        }

        my @built;
        if (@urls) {
            my %track_by_url = %{ $mapper->()->getTracksByUrls(\@urls) };
            for my $url (@urls) {
                my $track = $track_by_url{$url};
                push @built, $mapper->()->shapeTrack($track) if $track;
            }
        }

        $entries = \@built;
        $_get_cache{$client->id()} = {
            entries      => $entries,
            playlist_obj => $playlist,
        };
    } else {
        $entries = [];
    }

    my $playing  = $client->isPlaying() ? \1 : \0;
    my $index    = Slim::Player::Source::playingSongIndex($client) // 0;
    my $position;
    if ($playing) {
        $position = $client->songElapsedSeconds() // 0;
    } else {
        $position = 0;
    }

    my $vol = $client->volume();
    $vol = 100 unless defined $vol;

    return {
        jukeboxPlaylist => {
            currentIndex => int($index),
            playing      => $playing,
            gain         => $vol / 100.0,
            position     => int($position),
            entry        => $entries,
        }
    };
}

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

sub _setGain {
    my ($client, $p) = @_;
    return Plugins::SlimPing::Utils::Errors->missingParam('gain')
        unless defined $p->{gain};

    my $gain = $p->{gain};
    if ($gain < 0.0 || $gain > 1.0) {
        return Plugins::SlimPing::Utils::Errors->error(0, 'Gain must be between 0.0 and 1.0');
    }

    $client->volume(int($gain * 100));
    return _status($client);
}

# Invalidate the _get entry cache for a client.  Called by every mutation
# action after it modifies the playlist so the next poll returns fresh data.
sub _clearGetCache {
    my ($client) = @_;
    delete $_get_cache{$client->id()};
}

# Resolve sq_tr_ IDs to real filesystem paths for LMS playlist playback.
# Invalid / missing tracks are silently skipped.
sub _resolvePaths {
    my ($mapper, $sq_ids) = @_;
    my @paths;
    for my $sq_id (@$sq_ids) {
        my $path = $mapper->resolveFilePath($sq_id);
        push @paths, $path if defined $path;
    }
    return @paths;
}

1;
