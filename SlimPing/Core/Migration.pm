# Core/Migration.pm - One-shot migration from old prefs-backed stores to SQLite
#
# Reads the legacy prefs keys, inserts their data into the new DB tables,
# sets a sentinel pref, then deletes the old keys.  Session data is NOT
# migrated -- it is ephemeral and clients re-report immediately.
#
# Idempotent: the sentinel pref (schema_migrated_v1) prevents re-running.
# All prefs reads complete before the DB transaction; all prefs writes
# happen only after a successful commit.  A crash at any point leaves the
# sentinel unset so the migration retries on the next plugin load.

package Plugins::SlimPing::Core::Migration;

use strict;
use warnings;

use Plugins::SlimPing::Core::Logging;

my $log   = Plugins::SlimPing::Core::Logging->getLogger();
my $prefs = Plugins::SlimPing::Core::Logging->getPrefs();

sub run {
    # v2 migration runs independently of v1 — it must fire even when v1 already
    # completed on a previous startup.
    _runV2();

    return if $prefs->get('schema_migrated_v1');

    $log->info('SlimPing: starting prefs-to-SQLite migration');

    require Plugins::SlimPing::Schema;
    require Plugins::SlimPing::Core::UserStore;
    require Digest::SHA;

    my $schema    = Plugins::SlimPing::Schema->connect();
    my $userStore = Plugins::SlimPing::Core::UserStore->getInstance();

    # --- Phase 1: read every byte of old data BEFORE touching the DB ---

    my $old_users_raw = $prefs->get('users');
    my $old_users     = ref $old_users_raw eq 'ARRAY' ? $old_users_raw : [];

    unless (@$old_users) {
        $log->info('SlimPing: no legacy users to migrate -- marking migration complete');
        $prefs->set('schema_migrated_v1', 1);
        return;
    }

    # Snapshot all per-user annotation data so the transaction never calls
    # back into the prefs file.
    my %legacy;
    for my $old (@$old_users) {
        next unless $old->{username};
        my $u = $old->{username};
        $legacy{$u}{user}       = $old;
        $legacy{$u}{stars}      = $prefs->get("stars_$u")      || {};
        $legacy{$u}{ratings}    = $prefs->get("ratings_$u")    || {};
        $legacy{$u}{bookmarks}  = $prefs->get("bookmarks_$u")  || {};
    }

    # --- Phase 2: migrate into SQLite inside a single transaction ---

    my $migrated_users     = 0;
    my $migrated_stars     = 0;
    my $migrated_ratings   = 0;
    my $migrated_bookmarks = 0;
    my %username_to_id;

    eval {
        $schema->txn_do(sub {
            for my $username (sort keys %legacy) {
                my $entry = $legacy{$username};
                my $old   = $entry->{user};

                my $user = $schema->resultset('User')->find_or_create({
                    username       => $old->{username},
                    password_hash  => $old->{password_hash}  || '',
                    password_plain => $old->{password_plain} || '',
                    admin          => $old->{admin} ? 1 : 0,
                    enabled        => exists $old->{enabled} ? ($old->{enabled} ? 1 : 0) : 1,
                    last_login     => $old->{last_login},
                    jukebox_player => $old->{jukebox_player},
                    created_at     => time(),
                });
                $username_to_id{$username} = $user->id();
                $migrated_users++;

                # API keys -- explicit find to avoid depending on a registered
                # unique constraint name in the Result class
                for my $old_key (@{ $old->{api_keys} || [] }) {
                    my $exists = $schema->resultset('ApiKey')->search({
                        key_hash => $old_key->{key_hash},
                    })->first();
                    unless ($exists) {
                        $user->api_keys()->create({
                            key_hash     => $old_key->{key_hash},
                            prefix       => $old_key->{prefix}    || '',
                            label        => $old_key->{label}     || 'Default',
                            created_at   => $old_key->{created}   || time(),
                            last_used_at => $old_key->{last_used},
                        });
                    }
                }

                # Stars -- PRIMARY KEY (user_id, sq_id) catches re-entry duplicates
                my $stars = $entry->{stars};
                for my $bucket (qw(tracks albums artists)) {
                    my $entries = $stars->{$bucket} || {};
                    my $type    = $bucket eq 'tracks' ? 'track'
                                : $bucket eq 'albums' ? 'album'
                                : 'artist';
                    for my $sq_id (keys %$entries) {
                        my $exists = $schema->resultset('Star')->search({
                            user_id => $user->id(),
                            sq_id   => $sq_id,
                        })->count();
                        unless ($exists) {
                            $schema->resultset('Star')->create({
                                user_id    => $user->id(),
                                sq_id      => $sq_id,
                                item_type  => $type,
                                starred_at => $entries->{$sq_id} // 0,
                            });
                            $migrated_stars++;
                        }
                    }
                }

                # Ratings -- PRIMARY KEY (user_id, sq_id) catches re-entry duplicates
                my $ratings = $entry->{ratings};
                for my $sq_id (keys %$ratings) {
                    my $exists = $schema->resultset('Rating')->search({
                        user_id => $user->id(),
                        sq_id   => $sq_id,
                    })->count();
                    unless ($exists) {
                        $schema->resultset('Rating')->create({
                            user_id  => $user->id(),
                            sq_id    => $sq_id,
                            rating   => $ratings->{$sq_id},
                            rated_at => time(),
                        });
                        $migrated_ratings++;
                    }
                }

                # Bookmarks -- explicit lookup; safe even before uq_bookmark_user_sq
                my $bookmarks = $entry->{bookmarks};
                for my $sq_id (keys %$bookmarks) {
                    my $bm     = $bookmarks->{$sq_id};
                    my $exists = $schema->resultset('Bookmark')->search({
                        user_id => $user->id(),
                        sq_id   => $sq_id,
                    })->count();
                    unless ($exists) {
                        $schema->resultset('Bookmark')->create({
                            user_id      => $user->id(),
                            sq_id        => $sq_id,
                            position_ms  => $bm->{position} // 0,
                            comment      => $bm->{comment} // '',
                            created_at   => $bm->{created} // time(),
                            changed_at   => $bm->{changed} // time(),
                        });
                        $migrated_bookmarks++;
                    }
                }
            }
        });
    };
    if ($@) {
        $log->error("SlimPing: migration DB transaction failed -- rolled back, will retry on next load: $@");
        die $@;
    }

    # --- Phase 3: only after the DB commit succeeded, mutate prefs ---

    $prefs->set('schema_migrated_v1', 1);

    $prefs->remove('users');
    for my $username (keys %username_to_id) {
        $prefs->remove("stars_$username");
        $prefs->remove("ratings_$username");
        $prefs->remove("bookmarks_$username");
    }

    my $keys_cleaned = 1 + (3 * scalar keys %username_to_id);

    $log->warn(
        "SlimPing AUDIT\taction=migration\t"
      . "detail=users=$migrated_users,stars=$migrated_stars,"
      . "ratings=$migrated_ratings,bookmarks=$migrated_bookmarks,"
      . "prefs_keys_cleaned=$keys_cleaned"
    );

    return;
}

# --- v2: Dynamic Playlist Exposure dedup table ---

sub _runV2 {
    return if $prefs->get('schema_migrated_v2');

    $log->info('SlimPing: migration v2 -- creating sq_dynamic_playlist_history');

    require Plugins::SlimPing::Schema;
    my $schema = Plugins::SlimPing::Schema->connect();

    eval {
        $schema->storage->dbh->do(q{
            CREATE TABLE IF NOT EXISTS sq_dynamic_playlist_history (
                id            INTEGER PRIMARY KEY AUTOINCREMENT,
                exposure_id   VARCHAR(255) NOT NULL,
                track_url     TEXT NOT NULL,
                added         INTEGER NOT NULL,
                UNIQUE(exposure_id, track_url)
            )
        });
        $prefs->set('schema_migrated_v2', 1);
        $log->info('SlimPing: migration v2 complete');
    };
    if ($@) {
        $log->error("SlimPing: migration v2 failed -- will retry on next load: $@");
    }
}

1;
