# Core/UserStore.pm - DB-backed user and API key repository
#
# Replaces the prefs-backed data layer formerly in Auth::Manager.
# All CRUD operations go through DBIx::Class result sets against
# the user and api_key tables.
#
# Singleton -- connect() is idempotent, call getInstance() to retrieve.

package Plugins::SlimPing::Core::UserStore;

use strict;
use warnings;

use Digest::SHA qw(sha256_hex);

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

# --- User CRUD ---------------------------------------------------------------

sub getUsers {
    my $self = shift;
    my $rs = Plugins::SlimPing::Schema->connect()->resultset('User');
    return [$rs->search({}, { order_by => 'username' })->all()];
}

sub getByUsername {
    my ($self, $username) = @_;
    return undef unless $username;
    return Plugins::SlimPing::Schema->connect()
        ->resultset('User')
        ->search({ username => $username })->first();
}

sub getById {
    my ($self, $id) = @_;
    return undef unless defined $id;
    return Plugins::SlimPing::Schema->connect()
        ->resultset('User')
        ->find($id);
}

sub createUser {
    my ($self, %args) = @_;
    my %RESERVED = map { $_ => 1 } qw(_anon system root);
    return undef if $RESERVED{ $args{username} };
    my $schema = Plugins::SlimPing::Schema->connect();
    return $schema->resultset('User')->create({
        username       => $args{username},
        password_hash  => $args{password_hash},
        password_plain => $args{password_plain},
        admin          => $args{admin} ? 1 : 0,
        enabled        => 1,
        created_at     => time(),
    });
}

sub deleteUser {
    my ($self, $username) = @_;
    my $user = $self->getByUsername($username)
        or return 0;
    $user->delete();    # cascades through all FK relationships
    return 1;
}

sub updateUser {
    my ($self, $username, $changes) = @_;
    my $rs = Plugins::SlimPing::Schema->connect()
        ->resultset('User')
        ->search({ username => $username });
    return 0 unless $rs->count;
    $rs->update($changes);
    return 1;
}

sub setEnabled {
    my ($self, $username, $enabled) = @_;
    return $self->updateUser($username, { enabled => $enabled ? 1 : 0 });
}

sub setScrobbleEnabled {
    my ($self, $username, $enabled) = @_;
    return $self->updateUser($username, { scrobble_enabled => $enabled ? 1 : 0 });
}

sub setPlaycountSyncEnabled {
    my ($self, $username, $enabled) = @_;
    return $self->updateUser($username, { playcount_sync_enabled => $enabled ? 1 : 0 });
}

sub setPlaybackLogging {
    my ( $self, $username, $enabled ) = @_;
    return $self->updateUser( $username, { log_playback_to_lms => $enabled ? 1 : 0 } );
}

sub setAcceptPlaybackReport {
    my ( $self, $username, $enabled ) = @_;
    return $self->updateUser( $username, { accept_playback_report => $enabled ? 1 : 0 } );
}

sub setAdmin {
    my ($self, $username, $admin) = @_;
    return $self->updateUser($username, { admin => $admin ? 1 : 0 });
}

sub setPassword {
    my ($self, $username, $password_hash, $password_plain) = @_;
    return $self->updateUser($username, {
        password_hash  => $password_hash,
        password_plain => $password_plain,
    });
}

sub setJukeboxPlayer {
    my ($self, $username, $player_id) = @_;
    return $self->updateUser($username, { jukebox_player => $player_id });
}

sub setRadioFolder {
    my ($self, $username, $folder) = @_;
    return $self->updateUser($username, { radioFolder => $folder });
}

sub recordLogin {
    my ($self, $username) = @_;
    return $self->updateUser($username, { last_login => time() });
}

# --- API key CRUD ------------------------------------------------------------

sub getByApiKey {
    my ($self, $api_key) = @_;
    return undef unless defined $api_key && length $api_key;
    my $candidate = sha256_hex($api_key);

    my $schema = Plugins::SlimPing::Schema->connect();
    my $key = $schema->resultset('ApiKey')->search({ key_hash => $candidate })->first();
    return undef unless $key;

    $key->update({ last_used_at => time() });
    return $key->user();
}

sub addApiKey {
    my ($self, $username, $plain_key, $label) = @_;
    my $user = $self->getByUsername($username)
        or return undef;

    my $stored = Plugins::SlimPing::Schema->connect()
        ->resultset('ApiKey')->find_or_create({
            key_hash   => sha256_hex($plain_key),
            user_id    => $user->id,
            prefix     => substr($plain_key, 0, 8),
            label      => $label || 'Default',
            created_at => time(),
        });

    my %data = $stored->get_columns();
    delete $data{key_hash};
    return { %data, key => $plain_key };
}

sub deleteApiKey {
    my ($self, $username, $key_id) = @_;
    my $user = $self->getByUsername($username)
        or return 0;

    my $key = $user->api_keys()->find($key_id)
        or return 0;
    $key->delete();
    return 1;
}

sub relabelApiKey {
    my ($self, $username, $key_id, $label) = @_;
    my $user = $self->getByUsername($username)
        or return 0;

    my $key = $user->api_keys()->find($key_id)
        or return 0;
    $key->update({ label => $label // 'Default' });
    return 1;
}

# --- Display name aliases (stays in prefs -- this is config, not relational) --

sub getDisplayName {
    my ($self, $username) = @_;
    return $username unless $username;
    my $aliases = $prefs->get('pref_user_aliases') || {};
    return $aliases->{$username} || $username;
}

sub setAlias {
    my ($self, $username, $alias) = @_;
    return 0 unless $username;
    my $aliases = $prefs->get('pref_user_aliases') || {};
    if (defined $alias && $alias ne '') {
        $aliases->{$username} = $alias;
    } else {
        delete $aliases->{$username};
    }
    $prefs->set('pref_user_aliases', $aliases);
    return 1;
}

# --- Server salt --------------------------------------------------------------

sub getServerSalt {
    my $self = shift;
    unless ($prefs->get('server_salt')) {
        require Plugins::SlimPing::Auth::Manager;
        $prefs->set('server_salt', Plugins::SlimPing::Auth::Manager->generateApiKey());
    }
    return $prefs->get('server_salt');
}

1;
