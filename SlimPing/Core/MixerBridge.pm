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
# Core/MixerBridge.pm - Bridge from the OpenSubsonic sonic endpoints to
# Lyrion's built-in DSTM (Don't Stop The Music) feature
#
# Registers itself with Core::SonicRegistry as the 'dstm' provider.  The
# provider callback invokes the DSTM handler configured for the Subsonic
# session's virtual player (Slim::Plugin::DontStopTheMusic::Plugin
# ->getHandler), seeding the handler by appending seed tracks to the END of
# the virtual player's live playlist (appending leaves the currently
# playing track and index untouched; the appended seed is truncated away
# afterwards, unconditionally).
#
# The bridge requires an ACTIVE virtual player for the session: virtual
# players exist only while a stream is active, so cold calls (no active
# stream) return no results.  Registry providers are unaffected.
#
# Stateless class - class methods only, no constructor.
#

package Plugins::SlimPing::Core::MixerBridge;

use strict;
use warnings;

use Scalar::Util qw(blessed);

use Slim::Utils::Prefs;
use Plugins::SlimPing::Core::Logging;

# Declare the Slim:: modules used unqualified below so the module is
# self-declaring (the require is a no-op inside LMS, where they are
# always loaded).
require Slim::Schema;
require Slim::Player::Playlist;
require Slim::Player::Source;
require Slim::Utils::PluginManager;

my $log   = Plugins::SlimPing::Core::Logging->getLogger();
my $prefs = Plugins::SlimPing::Core::Logging->getPrefs();

# Number of tracks requested per feed top-up.
use constant TOPUP_COUNT => 20;

# Register the built-in 'dstm' sonic provider.  Called from
# Plugin::postinitPlugin.  Idempotent (SonicRegistry replaces on re-register).
sub register {
    my ($class) = @_;

    require Plugins::SlimPing::Core::SonicRegistry;
    Plugins::SlimPing::Core::SonicRegistry->registerProvider(
        {
            id            => Plugins::SlimPing::Core::SonicRegistry::BUILTIN_ID(),
            name          => 'Lyrion DSTM',
            similarTracks => sub { $class->similarTracks(@_) },

            # No findPath: Handlers::Sonic falls back to the chained walk.
        }
    );
    return 1;
}

# Find the active SlimPing virtual player whose name matches a Subsonic
# client name.  Virtual player names are "SlimPing: <client_name> (<sq_id>)"
# (see Core/VirtualPlayer.pm _buildPlayer).  Returns the client object or
# undef when no stream is active for that client.  If two sessions share
# a client_name, the first match wins.
sub findClient {
    my ( $class, $client_name ) = @_;
    return undef unless defined $client_name && length $client_name;

    my $prefix = "SlimPing: $client_name (";
    require Slim::Player::Client;
    for my $client ( Slim::Player::Client::clients() ) {
        my $name = $client->name() || '';
        return $client if index( $name, $prefix ) == 0;
    }
    return undef;
}

# --- SonicRegistry provider callback ---------------------------------------

# Registry callback: similar tracks for a seed.  Returns an arrayref of
# { track => Slim::Schema::Track, similarity => undef } (undef similarity
# becomes -1 in the response).  Returns [] when the bridge cannot serve
# the request: DSTM absent, no provider configured for the client, no
# active virtual player, or a conflicting plugin owns the queue.
sub similarTracks {
    my ( $class, $track, $count, $ctx ) = @_;

    return [] unless _dstmEnabled();
    my $client = $ctx->{client} || return [];
    return [] unless _handlerFor($client);

    my $seed = $ctx->{seed_tracks} || ( $track ? [ $track, @{ _queueSeed($ctx) } ] : undef );
    $seed ||= _composeFeedSeed($client);
    return [] unless $seed && @$seed;
    $seed = [@$seed];    # copy: never mutate a caller's arrayref
    splice( @$seed, _seedWindow() ) if @$seed > _seedWindow();

    my $urls = _invokeHandler( $client, $seed, $count );
    return [] unless $urls && @$urls;

    my %seen = map { _urlKey($_) => 1 } @$seed;
    my @out;
    for my $url (@$urls) {
        next if $seen{$url}++;
        my $obj = eval { Slim::Schema->objectForUrl($url) };
        next if $@ || !$obj;
        push @out, { track => $obj, similarity => undef };
    }
    return \@out;
}

# --- Feed top-up ------------------------------------------------------------

# Request a batch of tracks for the client's OWN playlist (the feed case)
# and return the URLs, deduped against the playlist.  Used by
# onPlaylistChange; also usable by the handlers for queue top-up.
sub mixTracks {
    my ( $class, $client, $count ) = @_;

    return [] unless _dstmEnabled();
    return [] unless _handlerFor($client);

    my $seed = _composeFeedSeed($client);
    return [] unless $seed && @$seed;
    $seed = [@$seed];    # copy, then cap like the endpoint path
    splice( @$seed, _seedWindow() ) if @$seed > _seedWindow();

    my $urls = _invokeHandler( $client, $seed, $count );
    return [] unless $urls && @$urls;

    my %seen = map { _urlKey($_) => 1 } @$seed;
    return [ grep { !$seen{$_}++ } @$urls ];
}

# Feed top-up entry point, subscribed from Plugin::postinitPlugin to
# virtual-player playlist events.  Mirrors native DSTM's own guards:
# repeat off, queue near the end, last track mixable, no conflicting
# plugin active.
sub onPlaylistChange {
    my ($request) = @_;

    my $client = $request->client();
    return unless $client;
    my $name = $client->name() || '';
    return unless $name =~ /^SlimPing: /;
    return if $request->source && $request->source eq __PACKAGE__;

    my $level = $prefs->get('dstm_mix_level') || 'off';
    return unless $level eq 'feed' || $level eq 'similarity' || $level eq 'full';

    return if Slim::Player::Playlist::repeat($client);

    my $songIndex      = Slim::Player::Source::streamingSongIndex($client) || 0;
    my $songsRemaining = Slim::Player::Playlist::count($client) - $songIndex - 1;
    my $threshold      = $prefs->get('dstm_topup_threshold') // 2;
    return if $songsRemaining >= $threshold;

    my $last     = Slim::Player::Playlist::playList($client)->[-1] || return;
    my $duration = eval { $last->duration };
    return unless $duration;

    my $tracks = __PACKAGE__->mixTracks( $client, TOPUP_COUNT );
    return unless $tracks && @$tracks;

    # Respect the server maxPlaylistLength pref, trimming from the front
    # like native DSTM.
    my $max   = preferences('server')->get('maxPlaylistLength');
    my $count = Slim::Player::Playlist::count($client) || 0;
    if ( $max && $count + scalar(@$tracks) > $max ) {
        my $excess = $count + scalar(@$tracks) - $max;
        for ( 1 .. $excess ) {
            my $req = $client->execute( [ 'playlist', 'delete', 0 ] );
            $req->source(__PACKAGE__);
        }
    }

    my $req = $client->execute( [ 'playlist', 'addtracks', 'listRef', $tracks ] );
    $req->source(__PACKAGE__);
    $log->info( 'SlimPing: DSTM feed top-up appended ' . scalar(@$tracks) . ' tracks' );
}

# --- Private helpers --------------------------------------------------------

# Is the Lyrion DSTM plugin installed and enabled?
sub _dstmEnabled {
    my ($class) = @_;
    my $ok = 0;
    eval { $ok = 1 if Slim::Utils::PluginManager->isEnabled('Slim::Plugin::DontStopTheMusic::Plugin'); };
    return $ok ? 1 : 0;
}

# Resolve the DSTM handler for the client, refusing when a conflicting
# plugin owns the queue (mirrors native DSTM behaviour).
#
# DSTM's provider pref is per-client and virtual players have transient
# ids, so the virtual player never carries a configured provider.  The
# token comes from the dstm_provider pref (explicit) or is auto-detected
# from the first LMS client that has one configured; it is applied to the
# client's DSTM pref so getHandler() resolves it.
#
# The pref must be restored after the invocation (in _invokeHandler):
# leaving it set would arm NATIVE DSTM for the virtual player, which would
# then run its own mixing on the same queue.
sub _handlerFor {
    my ( $class, $client ) = @_;
    return undef unless $client;

    my $token = _providerToken();
    return undef unless $token;

    require Slim::Plugin::DontStopTheMusic::Plugin;
    my $handler = eval {
        preferences('plugin.dontstopthemusic')->client($client)->set( 'provider', $token );
        Slim::Plugin::DontStopTheMusic::Plugin->getHandler($client);
    };
    return undef if $@ || !$handler;

    # Native DSTM declares this as a plain function, not a method; call it
    # fully qualified so the client argument actually reaches it.
    my $conflict = eval { Slim::Plugin::DontStopTheMusic::Plugin::isConflictingPluginActive($client) };
    return undef if $@ || $conflict;

    return $handler;
}

# The DSTM provider token to use: the dstm_provider pref when set, else
# the first non-empty provider token configured on any LMS client.
# Returns '' when nothing is configured.
sub _providerToken {
    my ($class) = @_;

    my $explicit = $prefs->get('dstm_provider') || '';
    return $explicit if $explicit;

    require Slim::Player::Client;
    my $dstm_prefs = preferences('plugin.dontstopthemusic');
    for my $c ( Slim::Player::Client::clients() ) {
        my $token = $dstm_prefs->client($c)->get('provider') || '';
        return $token if $token;
    }
    return '';
}

# Seed for the feed case: the client's own live playlist.
sub _composeFeedSeed {
    my ( $class, $client ) = @_;
    return undef unless $client;

    my @tracks = @{ Slim::Player::Playlist::playList($client) || [] };
    return undef unless @tracks;
    return \@tracks;
}

# Pad the seed from the Subsonic session's saved queue (getPlayQueue data
# in SessionState).  Returns an arrayref of Track objects (possibly empty).
sub _queueSeed {
    my ($ctx) = @_;
    return [] unless $ctx->{username};

    require Plugins::SlimPing::Core::Container;
    my $state = eval { Plugins::SlimPing::Core::Container->get('session_state') };
    return [] if $@ || !$state;

    my $queue = eval { $state->getQueue( $ctx->{username}, $ctx->{client_name} ) };
    return [] if $@ || !$queue || !$queue->{entry};

    my $mapper = eval { Plugins::SlimPing::Core::Container->get('library_mapper') };
    return [] if $@ || !$mapper;

    my @out;
    for my $sq_id ( @{ $queue->{entry} } ) {
        my ( undef, $raw_id ) = eval { $mapper->decodeId($sq_id) };
        next if $@ || !defined $raw_id;
        my $t = eval { Slim::Schema->find( 'Track', $raw_id ) };
        next if $@ || !$t;
        push @out, $t;
    }
    return \@out;
}

sub _seedWindow {
    my ($class) = @_;
    my $window = $prefs->get('dstm_seed_window') // 5;
    return $window if $window > 0;
    return 5;
}

sub _urlKey {
    my ($thing) = @_;
    return blessed($thing) ? $thing->url : "$thing";
}

# Append the seed to the END of the client's playlist, invoke the
# configured DSTM handler, collect the returned track URLs, then truncate
# the appended seed unconditionally.  Appending (rather than clearing)
# leaves the currently playing track and index untouched.  Returns an
# arrayref of track URLs, or undef on failure.
sub _invokeHandler {
    my ( $class, $client, $seed_tracks, $count ) = @_;

    require Slim::Plugin::DontStopTheMusic::Plugin;
    my $handler = eval { Slim::Plugin::DontStopTheMusic::Plugin->getHandler($client) };
    return undef if $@ || !$handler;

    my $orig_count = Slim::Player::Playlist::count($client) || 0;
    my @urls;

    # Snapshot the client's DSTM provider pref so it can be restored after
    # the invocation: leaving it set would arm native DSTM for the virtual
    # player (it would then mix on its own during the stream).
    my $dstm_prefs    = preferences('plugin.dontstopthemusic');
    my $prev_provider = eval { $dstm_prefs->client($client)->get('provider') };

    eval {
        for my $t (@$seed_tracks) {
            my $u   = _urlKey($t);
            my $req = $client->execute( [ 'playlist', 'add', $u ] );
            $req->source(__PACKAGE__);
        }

        # Lyrion's DSTM handler contract is callback-shaped.  SlimPing's
        # endpoints are synchronous and this bridge adapts the callback to a
        # return value, so a handler that defers its callback cannot be served
        # here: the result would arrive after the response had been built.
        # A mixer that needs to answer later registers a deferred sonic
        # provider instead (see docs/dstm-plugin-integration.md).
        my $done = 0;
        $handler->(
            $client,
            sub {
                my ( $c, $tracks ) = @_;
                if ( $tracks && ref $tracks eq 'ARRAY' ) {
                    @urls = @$tracks;
                    splice( @urls, $count ) if @urls > $count;
                }
                $done = 1;
            }
        );

        $log->warn(
            'SlimPing: DSTM handler did not call back synchronously, so its result is lost; '
              . 'a mixer that must answer later should register a deferred sonic provider'
        ) unless $done;
    };
    my $err = $@;
    $err && $log->warn("SlimPing: DSTM handler error: $err");

    # Truncate the appended seed unconditionally (also when the handler
    # died).  Guarded against infinite loops.
    my $guard = scalar(@$seed_tracks) + 10;
    my $cur   = Slim::Player::Playlist::count($client) || 0;
    while ( $cur > $orig_count && $guard-- > 0 ) {
        eval {
            my $req = $client->execute( [ 'playlist', 'delete', $orig_count ] );
            $req->source(__PACKAGE__);
        };
        $@ && $log->warn("SlimPing: DSTM seed truncation failed: $@");
        $cur = Slim::Player::Playlist::count($client) || 0;
    }

    # Restore the client's DSTM provider pref (also when the handler died).
    eval { $dstm_prefs->client($client)->set( 'provider', $prev_provider ); };
    $@ && $log->warn("SlimPing: DSTM provider pref restore failed: $@");

    return \@urls;
}

1;
