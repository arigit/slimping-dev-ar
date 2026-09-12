# Core/Scrobbler.pm - Feed Subsonic scrobbles into LMS's AudioScrobbler plugin
#
# Stateless utility -- class methods only, no constructor.  Called from
# Playback.pm when scrobble (submission=true) or reportPlayback (state=stopped)
# reports a completed play.
#
# Appends completed-play entries to the AudioScrobbler queue on a configured
# gateway player.  Only kicks submitScrobble when the queue was empty before
# our append (gateway player is idle).  When the player is active, our entries
# ride along with the next natural flush.
#
# Gated at three levels:
#   1. AudioScrobbler plugin installed (startup probe flag)
#   2. Server-level scrobble_gateway_player pref configured
#   3. Per-user scrobble_enabled column (default 1)

package Plugins::SlimPing::Core::Scrobbler;

use strict;
use warnings;

use URI::Escape qw(uri_escape_utf8);

use Plugins::SlimPing::Core::Logging;
require Plugins::SlimPing::Core::Container;

my $log   = Plugins::SlimPing::Core::Logging->getLogger();
my $prefs = Plugins::SlimPing::Core::Logging->getPrefs();

# Set once by Plugin.pm at startup -- plugins cannot be installed mid-session.
my $_scrobbler_available = 0;

# Rate-limit gateway-player warnings so a persistent configuration issue
# (missing account, disconnected player) does not log on every scrobble.
my %_warned_gateways;

sub setScrobblerAvailable { $_scrobbler_available = $_[1] ? 1 : 0; }
sub scrobblerAvailable    { return $_scrobbler_available; }

# Enqueue a completed play on the gateway player's AudioScrobbler queue.
# Returns 1 on success, 0 on skip/failure (all failures are logged, caller
# ignores the return value -- the Subsonic endpoint always returns {} to the client).
sub submit {
    my ($class, $username, $sq_id) = @_;

    return 0 unless $_scrobbler_available;
    return 0 unless $username && $sq_id;

    my $gateway_id = $prefs->get('scrobble_gateway_player');
    unless ($gateway_id && length $gateway_id) {
        return 0;
    }

    # Per-user toggle
    my $mgr = Plugins::SlimPing::Core::Container->get('auth_manager');
    unless ($mgr->isScrobbleEnabled($username)) {
        $log->debug("SlimPing: scrobbling disabled for $username -- skipping");
        return 0;
    }

    # Resolve track metadata
    my $mapper = Plugins::SlimPing::Core::Container->get('library_mapper');
    my (undef, $raw_id) = eval { $mapper->decodeId($sq_id) };
    if ($@) {
        $log->warn("SlimPing: scrobbler decode failed for $sq_id: $@");
        return 0;
    }
    return 0 unless defined $raw_id;

    my $track = Slim::Schema->find('Track', $raw_id);
    unless ($track) {
        $log->warn("SlimPing: scrobbler track not found for $sq_id (raw=$raw_id)");
        return 0;
    }

    # Resolve gateway player client
    my $gateway_client = Slim::Player::Client::getClient($gateway_id);
    unless ($gateway_client) {
        unless ($_warned_gateways{"$gateway_id:disconnected"}++) {
            $log->warn("SlimPing: scrobbler gateway player '$gateway_id' not found or disconnected");
        }
        return 0;
    }

    # Check AudioScrobbler account is configured on the gateway player
    require Slim::Plugin::AudioScrobbler::Plugin;
    my $account = Slim::Plugin::AudioScrobbler::Plugin::getAccount($gateway_client);
    unless ($account) {
        unless ($_warned_gateways{"$gateway_id:noaccount"}++) {
            $log->warn("SlimPing: scrobbler gateway player '$gateway_id' has no AudioScrobbler account configured");
        }
        return 0;
    }

    # Clear any previous warnings for this gateway player now that it is healthy.
    delete $_warned_gateways{"$gateway_id:disconnected"};
    delete $_warned_gateways{"$gateway_id:noaccount"};

    # Build queue entry in AudioScrobbler format (matches checkScrobble in Plugin.pm)
    my $source_type = $prefs->get('scrobble_source_type') || 'P';
    my $entry = {
        _url => $track->url,
        a    => uri_escape_utf8($track->artistName || ''),
        t    => uri_escape_utf8($track->title),
        i    => time(),
        o    => $source_type,
        r    => '',
        l    => $track->secs || '',
        b    => uri_escape_utf8(($track->album && $track->album->get_column('title')) || ''),
        n    => $track->tracknum || '',
        m    => $track->musicbrainz_id || '',
    };

    # Append to gateway player's scrobble queue
    my $queue = Slim::Plugin::AudioScrobbler::Plugin::getQueue($gateway_client);
    my $was_empty = !(@$queue);  # check before we append

    push @$queue, $entry;
    Slim::Plugin::AudioScrobbler::Plugin::setQueue($gateway_client, $queue);

    $log->debug("SlimPing: scrobble queued for $sq_id on gateway player '$gateway_id'");

    # Only kick submission if the queue was empty -- gateway player is idle.
    # If queue was non-empty, a submitScrobble timer is already pending (set by
    # checkScrobble after the last newsong event) and our entry will ride along
    # with the next natural flush.
    if ($was_empty) {
        eval {
            Slim::Plugin::AudioScrobbler::Plugin::submitScrobble($gateway_client);
        };
        if ($@) {
            $log->warn("SlimPing: scrobbler submitScrobble failed: $@");
        }
    }

    return 1;
}

1;
