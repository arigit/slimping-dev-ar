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
# Auth/Manager.pm - Authentication and user management for SlimPing
#
# Handles password hashing (SHA-256 with server salt), Subsonic token+salt
# verification (MD5), API key generation, and user CRUD delegation.
#
# User and API key data is stored in the SQLite persistence layer via
# Core::UserStore.  This module owns the auth logic; UserStore owns the
# data access.
#
# Note on password storage: Subsonic's token+salt auth scheme requires the
# server to know the user's plaintext password so it can compute
# MD5(password+salt) and compare with the client-supplied token.  We therefore
# store password_plain on every user record.  API keys are the recommended
# authentication method for any external-facing exposure of the API.
#

package Plugins::SlimPing::Auth::Manager;

use strict;
use warnings;

use Digest::SHA qw(sha256_hex hmac_sha256_hex);
use Digest::MD5 qw(md5_hex);

use Plugins::SlimPing::Core::Logging;

my $log   = Plugins::SlimPing::Core::Logging->getLogger();
my $prefs = Plugins::SlimPing::Core::Logging->getPrefs();

my $_instance;

sub getInstance {
    my $class = shift;
    $_instance //= bless {}, $class;
    return $_instance;
}

# --- Password helpers ---------------------------------------------------------

sub hashPassword {
    my ($self, $password) = @_;
    return sha256_hex($self->_serverSalt() . $password);
}

sub verifyPassword {
    my ($self, $password, $stored_hash) = @_;
    my $candidate = sha256_hex($self->_serverSalt() . $password);
    return _constantTimeEq($candidate, $stored_hash);
}

sub verifyToken {
    my ($self, $plaintext_password, $token, $salt) = @_;
    my $candidate = md5_hex($plaintext_password . $salt);
    return _constantTimeEq($candidate, $token);
}

# Verify a Subsonic token+salt pair for a given username without ever exposing
# the plaintext password to the caller.  The caller (Middleware) never sees
# password_plain or password_hash -- it asks "is this token valid?" rather than
# "give me the password so I can check."
sub verifyTokenForUser {
    my ($self, $username, $token, $salt) = @_;
    my $row = _userStore()->getByUsername($username) or return 0;
    return $self->verifyToken($row->password_plain, $token, $salt);
}

sub verifyPasswordForUser {
    my ($self, $username, $password) = @_;
    my $row = _userStore()->getByUsername($username) or return 0;
    return $self->verifyPassword($password, $row->password_hash);
}

sub _serverSalt {
    my $self = shift;
    unless ($prefs->get('server_salt')) {
        $prefs->set('server_salt', $self->generateApiKey());
    }
    return $prefs->get('server_salt');
}

# --- API key helpers ----------------------------------------------------------

sub generateApiKey {
    my $rand;
    sysopen(my $fh, '/dev/urandom', 0)
        or die "SlimPing: cannot open /dev/urandom for entropy: $!";
    sysread($fh, $rand, 32) == 32
        or die "SlimPing: short read from /dev/urandom (got " . length($rand // '') . " bytes)";
    close($fh);
    return substr(sha256_hex($rand), 0, 32);
}

sub _constantTimeEq {
    my ($a, $b) = @_;
    return 0 unless defined $a && defined $b;
    return 0 if length($a) != length($b);
    my $diff = 0;
    for (my $i = 0; $i < length($a); $i++) {
        $diff |= ord(substr($a, $i, 1)) ^ ord(substr($b, $i, 1));
    }
    return $diff == 0 ? 1 : 0;
}

# --- HMAC stream tokens (radio + share self-authentication) --------------------

# Return the HMAC signing key used for stream tokens (radio + shares).
# Reads from the plugin's durable SQLite store, with a one-time migration
# from the legacy LMS prefs key.  The key is domain-separated from server_salt
# (which is used for password hashing) and generated from /dev/urandom on
# first access.
# Public accessor for the HMAC signing key.  Used by transcode token
# generation in Endpoints.pm so it does not need to call the private
# _hmacSigningKey() across module boundaries.
sub getHmacSigningKey {
    my $self = shift;
    return $self->_hmacSigningKey();
}

sub _hmacSigningKey {
    my $self = shift;

    # Primary: plugin database (durable, survives prefs corruption / hard crash)
    {
        require Plugins::SlimPing::Schema;
        my $key = eval { Plugins::SlimPing::Schema->_readMetaKey('hmac_signing_key'); };
        if ($@) {
            $log->warn("SlimPing: cannot read HMAC signing key from database: $@");
        }
        return $key if defined $key && length $key;
    }

    # One-time migration: recover from legacy LMS prefs, then delete
    my $legacy = $prefs->get('hmac_signing_key');
    if ( defined $legacy && length $legacy ) {
        $log->info("SlimPing: migrating HMAC signing key from prefs to plugin database");
        eval {
            require Plugins::SlimPing::Schema;
            Plugins::SlimPing::Schema->_writeMetaKey( 'hmac_signing_key', $legacy );
        };
        if ($@) {
            $log->error("SlimPing: failed to migrate HMAC key to database: $@");
            return $legacy;
        }
        $prefs->remove('hmac_signing_key');
        return $legacy;
    }

    # Cold start: generate and persist to database
    my $key = $self->generateApiKey();
    eval {
        require Plugins::SlimPing::Schema;
        Plugins::SlimPing::Schema->_writeMetaKey( 'hmac_signing_key', $key );
    };
    if ($@) {
        die "SlimPing: cannot persist HMAC signing key to database: $@";
    }
    $log->warn(
        "SlimPing: new HMAC signing key generated"
          . " — all outstanding stream tokens are now invalid" );
    return $key;
}

# Public method for the settings UI: rotate the HMAC signing key, immediately
# invalidating every outstanding radio stream token and transcode token across
# all users.  Returns 1 on success, 0 on failure.
sub rotateHmacSigningKey {
    my $self = shift;

    my $new_key = $self->generateApiKey();
    eval {
        require Plugins::SlimPing::Schema;
        Plugins::SlimPing::Schema->_writeMetaKey( 'hmac_signing_key', $new_key );
    };
    if ($@) {
        $log->error("SlimPing: failed to persist rotated HMAC key: $@");
        return 0;
    }

    # Clear any stale cached copy of the transcode signing key so that
    # transcode tokens also rotate immediately rather than surviving
    # with the old key until LMS restart.
    {
        require Plugins::SlimPing::Handlers::Stream::TranscodeDecision;
        Plugins::SlimPing::Handlers::Stream::TranscodeDecision::clearTranscodeSigningKey();
    }

    $log->warn(
        "SlimPing: HMAC signing key rotated"
          . " — all outstanding stream and transcode tokens invalidated" );
    return 1;
}

# Generate a self-authenticating stream token for a given resource.
# Returns a 64-char hex HMAC-SHA256 of the resource ID + expiry.
sub generateStreamToken {
    my ($self, $sq_id, $ttl_seconds) = @_;
    my $expiry = time() + $ttl_seconds;
    my $data   = "$sq_id:$expiry";
    my $hmac   = hmac_sha256_hex($data, $self->_hmacSigningKey());
    return ($hmac, $expiry);
}

# Validate a stream token.  Recomputes the HMAC and compares with constant-time
# equality.  Returns ($sq_id, $expiry) on success, empty list on failure.
sub validateStreamToken {
    my ($self, $sq_id, $expiry, $token) = @_;
    return () unless defined $sq_id && length $sq_id;
    return () unless defined $expiry && $expiry > 0;
    return () unless defined $token && length $token;

    # Expiry check before crypto -- don't burn cycles on expired tokens
    if ( time() > $expiry ) {
        $log->debug(
            sprintf(
                'SlimPing: stream token expired for %s (expiry=%d, now=%d, delta=%ds)',
                $sq_id, $expiry, time(), time() - $expiry
            )
        );
        return ();
    }

    my $data  = "$sq_id:$expiry";
    my $key   = $self->_hmacSigningKey();
    my $candidate = hmac_sha256_hex($data, $key);
    unless ( _constantTimeEq($candidate, $token) ) {
        $log->debug(
            sprintf(
                'SlimPing: stream token HMAC mismatch for %s '
                  . '(key_prefix=%s candidate_prefix=%s token_prefix=%s)',
                $sq_id,
                substr( $key,       0, 8 ),
                substr( $candidate, 0, 8 ),
                substr( $token,     0, 8 ),
            )
        );
        return ();
    }

    return ($sq_id, $expiry);
}

# --- User CRUD (delegated to UserStore) ---------------------------------------

sub _userStore {
    require Plugins::SlimPing::Core::UserStore;
    return Plugins::SlimPing::Core::UserStore->getInstance();
}

# Convert a DBIx::Class User row object to a plain hashref so that all downstream
# callers (Middleware, Permissions, AdminGate, Handlers, Menu, etc.) can use
# $user->{column} hashref access as they did before the SQLite migration.
# $row->{column} on a DBIx::Class row returns undef because the blessed hash
# stores internal bookkeeping, not column values directly.
sub _userRowToHash {
    my ($row) = @_;
    my %u = $row->get_columns();
    delete $u{password_plain};
    delete $u{password_hash};
    my @keys = $row->api_keys()->search({}, { order_by => 'created_at' })->all();
    $u{api_keys} = [
        map {
            my %k = $_->get_columns();
            delete $k{key_hash};
            \%k;
        } @keys
    ];
    return \%u;
}

sub getUsers {
    my $rows = _userStore()->getUsers();
    return [ map { _userRowToHash($_) } @$rows ];
}

sub getUser {
    my ($self, $username) = @_;
    my $row = _userStore()->getByUsername($username) or return undef;
    return _userRowToHash($row);
}

sub getDisplayName {
    my ($self, $username) = @_;
    return _userStore()->getDisplayName($username);
}

sub getAlias {
    my ($self, $username) = @_;
    return undef unless $username;
    my $aliases = $prefs->get('pref_user_aliases') || {};
    return $aliases->{$username};
}

sub setAlias {
    my ($self, $username, $alias) = @_;
    return _userStore()->setAlias($username, $alias);
}

sub getUserByApiKey {
    my ($self, $api_key) = @_;
    my $row = _userStore()->getByApiKey($api_key) or return undef;
    return _userRowToHash($row);
}

sub createUser {
    my ($self, %args) = @_;
    my %RESERVED = map { $_ => 1 } qw(_anon system root);
    return undef if $RESERVED{ $args{username} };
    return _userStore()->createUser(
        username       => $args{username},
        password_hash  => $self->hashPassword($args{password}),
        password_plain => $args{password},
        admin          => $args{admin},
    );
}

sub addApiKey {
    my ($self, $username, $label) = @_;
    my $plain = $self->generateApiKey();
    return _userStore()->addApiKey($username, $plain, $label);
}

sub setJukeboxPlayer {
    my ($self, $username, $player_id) = @_;
    return _userStore()->setJukeboxPlayer($username, $player_id);
}

sub setRadioFolder {
    my ($self, $username, $folder) = @_;
    return _userStore()->setRadioFolder($username, $folder);
}

sub setAdmin {
    my ($self, $username, $admin) = @_;
    return _userStore()->setAdmin($username, $admin);
}

sub setPassword {
    my ($self, $username, $password) = @_;
    return _userStore()->setPassword(
        $username,
        $self->hashPassword($password),
        $password,
    );
}

sub setEnabled {
    my ($self, $username, $enabled) = @_;
    return _userStore()->setEnabled($username, $enabled);
}

sub setScrobbleEnabled {
    my ($self, $username, $enabled) = @_;
    return _userStore()->setScrobbleEnabled($username, $enabled);
}

sub setPlaycountSyncEnabled {
    my ($self, $username, $enabled) = @_;
    return _userStore()->setPlaycountSyncEnabled($username, $enabled);
}

sub setPlaybackLogging {
    my ( $self, $username, $enabled ) = @_;
    return _userStore()->setPlaybackLogging( $username, $enabled );
}

sub setAcceptPlaybackReport {
    my ( $self, $username, $enabled ) = @_;
    return _userStore()->setAcceptPlaybackReport( $username, $enabled );
}

sub isScrobbleEnabled {
    my ($self, $username) = @_;
    return 0 unless $username;

    my $user = eval { $self->getUser($username) };
    if ($@) {
        $log->warn("SlimPing: isScrobbleEnabled user lookup failed for $username: $@");
        return 0;
    }
    return 0 unless $user;

    return 1 unless defined $user->{scrobble_enabled};
    return $user->{scrobble_enabled} ? 1 : 0;
}

sub isPlaycountSyncEnabled {
    my ($self, $username) = @_;
    return 0 unless $username;

    my $user = eval { $self->getUser($username) };
    if ($@) {
        $log->warn("SlimPing: isPlaycountSyncEnabled user lookup failed for $username: $@");
        return 0;
    }
    return 0 unless $user;

    return 1 unless defined $user->{playcount_sync_enabled};
    return $user->{playcount_sync_enabled} ? 1 : 0;
}

# Check whether Lyrion play-statistics recording is enabled for a user.
# Defaults to enabled (1) — the pref only gates the NO path.
sub isPlaybackLoggingEnabled {
    my ( $self, $username ) = @_;
    return 0 unless $username;

    my $user = eval { $self->getUser($username) };
    if ($@) {
        $log->warn("SlimPing: isPlaybackLoggingEnabled lookup failed for $username: $@");
        return 0;
    }
    return 0 unless $user;

    return 1 unless defined $user->{log_playback_to_lms};
    return $user->{log_playback_to_lms} ? 1 : 0;
}

# Check whether the playbackReport extension is accepted for a user.
sub isPlaybackReportAccepted {
    my ( $self, $username ) = @_;
    return 0 unless $username;

    my $user = eval { $self->getUser($username) };
    if ($@) {
        $log->warn("SlimPing: isPlaybackReportAccepted lookup failed for $username: $@");
        return 0;
    }
    return 0 unless $user;

    return 1 unless defined $user->{accept_playback_report};
    return $user->{accept_playback_report} ? 1 : 0;
}

sub recordLogin {
    my ($self, $username) = @_;
    return _userStore()->recordLogin($username);
}

sub deleteApiKey {
    my ($self, $username, $key_id) = @_;
    return _userStore()->deleteApiKey($username, $key_id);
}

sub relabelApiKey {
    my ($self, $username, $key_id, $label) = @_;
    return _userStore()->relabelApiKey($username, $key_id, $label);
}

sub deleteUser {
    my ($self, $username) = @_;
    return _userStore()->deleteUser($username);
}

sub updateUser {
    my ($self, $username, $changes) = @_;
    return _userStore()->updateUser($username, $changes);
}

1;
