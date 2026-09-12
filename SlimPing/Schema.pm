# SlimPing/Schema.pm - DBIx::Class schema for SlimPing's SQLite persistence layer
#
# Manages the connection to slimpping.db in LMS's cachedir.  Result classes
# under Schema/Result/ define the table mappings.  Callers go through
# repository modules (Core::UserStore, etc.), not the schema directly.
#
# Schema->connect() is idempotent -- second call returns the cached instance.
# deploySchema() uses raw DDL (CREATE IF NOT EXISTS) -- no SQL::Translator needed.

package Plugins::SlimPing::Schema;

use strict;
use warnings;

use base 'DBIx::Class::Schema';

use File::Spec::Functions qw(catdir catfile);

use Plugins::SlimPing::Core::Logging;

# Result classes must be loaded so DBIx::Class can resolve table relationships.
__PACKAGE__->load_classes(qw(
    Result::User
    Result::ApiKey
    Result::Star
    Result::Rating
    Result::Bookmark
    Result::Session
    Result::Share
    Result::ShareEntry
));

my $log = Plugins::SlimPing::Core::Logging->getLogger();
my $prefs = Plugins::SlimPing::Core::Logging->getPrefs();

my $_schema;

sub connect {
    my $class = shift;

    return $_schema if $_schema;

    my $cachedir = Slim::Utils::Prefs::preferences('server')->get('cachedir');
    my $dbDir = catdir($cachedir, 'slimping');
    mkdir $dbDir unless -d $dbDir;

    my $dbPath = catfile($dbDir, 'slimping.db');
    my $dsn = "dbi:SQLite:dbname=$dbPath";

    $_schema = $class->SUPER::connect($dsn, '', '', {
        RaiseError => 1,
        PrintError => 0,
        AutoCommit => 1,
        sqlite_unicode => 1,
    });

    # Crash-safe WAL journal; concurrent reads from multiple LMS dispatcher threads.
    $_schema->storage->dbh->do('PRAGMA journal_mode=WAL');
    $_schema->storage->dbh->do('PRAGMA foreign_keys=ON');
    $_schema->storage->dbh->do('PRAGMA busy_timeout = 5000');
    $_schema->storage->dbh->do('PRAGMA synchronous = NORMAL');
    $_schema->storage->dbh->do('PRAGMA secure_delete = ON');

    # Checkpoint any orphaned WAL frames from an unclean shutdown before
    # anything reads the database.  Without this, writes that completed
    # successfully (ShareStore creates, etc.) can vanish on restart.
    $_schema->storage->dbh->do('PRAGMA wal_checkpoint(TRUNCATE)');

    $log->info("SlimPing: connected to SQLite at $dbPath (WAL mode)");

    return $_schema;
}

sub deploySchema {
    my $class = shift;
    my $dbh   = $class->dbh();

    $dbh->do(q{
        CREATE TABLE IF NOT EXISTS "user" (
            id             INTEGER PRIMARY KEY AUTOINCREMENT,
            username       TEXT UNIQUE NOT NULL,
            password_hash  TEXT NOT NULL,
            password_plain TEXT NOT NULL,
            admin          INTEGER DEFAULT 0,
            enabled        INTEGER DEFAULT 1,
            last_login     INTEGER,
            jukebox_player TEXT,
            created_at     INTEGER NOT NULL
        )
    });

    # Add radioFolder column if missing (added for per-user internet radio override)
    {
        my $has_radio_folder = eval {
            my $info = $dbh->selectall_arrayref("PRAGMA table_info('user')");
            $info && scalar(grep { $_->[1] eq 'radioFolder' } @$info);
        };
        unless ($has_radio_folder) {
            $dbh->do('ALTER TABLE "user" ADD COLUMN radioFolder TEXT');
        }
    }

    # Add scrobble_enabled and playcount_sync_enabled if missing (playcount sync + scrobbling features)
    {
        my $info = $dbh->selectall_arrayref("PRAGMA table_info('user')");
        unless ($info && scalar(grep { $_->[1] eq 'scrobble_enabled' } @$info)) {
            $dbh->do('ALTER TABLE "user" ADD COLUMN scrobble_enabled INTEGER NOT NULL DEFAULT 1');
        }
    }
    {
        my $info = $dbh->selectall_arrayref("PRAGMA table_info('user')");
        unless ($info && scalar(grep { $_->[1] eq 'playcount_sync_enabled' } @$info)) {
            $dbh->do('ALTER TABLE "user" ADD COLUMN playcount_sync_enabled INTEGER NOT NULL DEFAULT 1');
        }
    }

    # Migrate playback-recording preferences to their final column names.
    # Phase 1: rename record_lms_stats -> log_playback_to_lms
    {
        my $info = $dbh->selectall_arrayref("PRAGMA table_info('user')");
        my $has_new = $info && scalar(grep { $_->[1] eq 'log_playback_to_lms' } @$info);
        my $has_old = $info && scalar(grep { $_->[1] eq 'record_lms_stats' } @$info);

        unless ($has_new) {
            if ($has_old) {
                eval { $dbh->do(
                    'ALTER TABLE "user" RENAME COLUMN record_lms_stats TO log_playback_to_lms'
                ); };
                if ($@) {
                    $log->warn("SlimPing: RENAME COLUMN record_lms_stats failed — using ADD+COPY fallback: $@");
                    $dbh->do(
                        'ALTER TABLE "user" ADD COLUMN log_playback_to_lms INTEGER NOT NULL DEFAULT 1'
                    );
                    $dbh->do(
                        'UPDATE "user" SET log_playback_to_lms = COALESCE(record_lms_stats, 1)'
                    );
                }
            }
            else {
                $dbh->do(
                    'ALTER TABLE "user" ADD COLUMN log_playback_to_lms INTEGER NOT NULL DEFAULT 1'
                );
            }
        }
    }

    # Phase 2: rename record_playback_report -> accept_playback_report
    {
        my $info = $dbh->selectall_arrayref("PRAGMA table_info('user')");
        my $has_new = $info && scalar(grep { $_->[1] eq 'accept_playback_report' } @$info);
        my $has_old = $info && scalar(grep { $_->[1] eq 'record_playback_report' } @$info);

        unless ($has_new) {
            if ($has_old) {
                eval { $dbh->do(
                    'ALTER TABLE "user" RENAME COLUMN record_playback_report TO accept_playback_report'
                ); };
                if ($@) {
                    $log->warn("SlimPing: RENAME COLUMN record_playback_report failed — using ADD+COPY fallback: $@");
                    $dbh->do(
                        'ALTER TABLE "user" ADD COLUMN accept_playback_report INTEGER NOT NULL DEFAULT 1'
                    );
                    $dbh->do(
                        'UPDATE "user" SET accept_playback_report = COALESCE(record_playback_report, 1)'
                    );
                }
            }
            else {
                $dbh->do(
                    'ALTER TABLE "user" ADD COLUMN accept_playback_report INTEGER NOT NULL DEFAULT 1'
                );
            }
        }
    }

    $dbh->do(q{
        CREATE TABLE IF NOT EXISTS api_key (
            id           INTEGER PRIMARY KEY AUTOINCREMENT,
            user_id      INTEGER NOT NULL REFERENCES "user"(id) ON DELETE CASCADE,
            key_hash     TEXT NOT NULL,
            prefix       TEXT NOT NULL,
            label        TEXT DEFAULT 'Default',
            created_at   INTEGER NOT NULL,
            last_used_at INTEGER
        )
    });
    # Dedup before building unique indexes -- defends against partial migration
    # runs from before these indexes existed.
    $dbh->do('DELETE FROM api_key WHERE id NOT IN (SELECT MIN(id) FROM api_key GROUP BY key_hash)');
    $dbh->do('CREATE UNIQUE INDEX IF NOT EXISTS idx_apikey_key_hash ON api_key(key_hash)');
    $dbh->do('DELETE FROM api_key WHERE id NOT IN (SELECT MIN(id) FROM api_key GROUP BY user_id, prefix)');
    $dbh->do('CREATE UNIQUE INDEX IF NOT EXISTS idx_apikey_user_prefix ON api_key(user_id, prefix)');

    $dbh->do(q{
        CREATE TABLE IF NOT EXISTS star (
            user_id    INTEGER NOT NULL REFERENCES "user"(id) ON DELETE CASCADE,
            sq_id      TEXT NOT NULL,
            item_type  TEXT NOT NULL,
            starred_at INTEGER NOT NULL,
            PRIMARY KEY (user_id, sq_id)
        )
    });
    $dbh->do(q{
        CREATE TABLE IF NOT EXISTS rating (
            user_id  INTEGER NOT NULL REFERENCES "user"(id) ON DELETE CASCADE,
            sq_id    TEXT NOT NULL,
            rating   INTEGER NOT NULL,
            rated_at INTEGER NOT NULL,
            PRIMARY KEY (user_id, sq_id)
        )
    });
    $dbh->do('CREATE INDEX IF NOT EXISTS idx_rating_sq_id ON rating(sq_id)');

    $dbh->do(q{
        CREATE TABLE IF NOT EXISTS bookmark (
            id          INTEGER PRIMARY KEY AUTOINCREMENT,
            user_id     INTEGER NOT NULL REFERENCES "user"(id) ON DELETE CASCADE,
            sq_id       TEXT NOT NULL,
            position_ms INTEGER NOT NULL,
            comment     TEXT DEFAULT '',
            created_at  INTEGER NOT NULL,
            changed_at  INTEGER NOT NULL
        )
    });
    $dbh->do('CREATE INDEX IF NOT EXISTS idx_bookmark_user_sq ON bookmark(user_id, sq_id)');
    $dbh->do('DELETE FROM bookmark WHERE id NOT IN (SELECT MAX(id) FROM bookmark GROUP BY user_id, sq_id)');
    $dbh->do('CREATE UNIQUE INDEX IF NOT EXISTS uq_bookmark_user_sq ON bookmark(user_id, sq_id)');
    $dbh->do('CREATE INDEX IF NOT EXISTS idx_bookmark_user_changed ON bookmark(user_id, changed_at)');

    $dbh->do(q{
        CREATE TABLE IF NOT EXISTS session (
            user_id           INTEGER NOT NULL REFERENCES "user"(id) ON DELETE CASCADE,
            client_name       TEXT NOT NULL DEFAULT '',
            now_playing_track TEXT,
            position_secs     INTEGER,
            started_at        INTEGER,
            last_seen_at      INTEGER NOT NULL,
            play_queue        TEXT DEFAULT '[]',
            queue_index       INTEGER DEFAULT 0,
            PRIMARY KEY (user_id, client_name)
        )
    });
    $dbh->do('CREATE INDEX IF NOT EXISTS idx_session_last_seen ON session(last_seen_at)');

    # Durable key-value store for plugin metadata (HMAC signing keys, etc.).
    # Must be created before any _readMetaKey/_writeMetaKey calls below.
    # Same raw-DBI pattern as text_cache — no DBIx::Class Result class needed.
    $dbh->do(q{
        CREATE TABLE IF NOT EXISTS plugin_metadata (
            meta_key   TEXT PRIMARY KEY,
            meta_value TEXT NOT NULL
        )
    });

    # Migrate from the old stub share table (Phase C) which had sq_id as the
    # primary content column.  The new schema uses a share_entry junction table
    # for multi-entry shares.  SQLite can't drop columns, so when the old column
    # is detected and the sentinel hasn't fired, we recreate both tables.
    # The stub table has no real rows so no data is lost.
    # The sentinel ensures this destructive migration runs exactly once.
    my $share_migrated = $class->_readMetaKey('schema_share_migrated');
    unless ($share_migrated) {
        my $has_old_sq_id = eval {
            my $info = $dbh->selectall_arrayref("PRAGMA table_info('share')");
            $info && scalar(grep { $_->[1] eq 'sq_id' } @$info);
        };
        if ($has_old_sq_id) {
            $log->info('SlimPing: migrating share table from stub schema (sq_id column detected)');
            $dbh->do('DROP TABLE IF EXISTS share_entry');
            $dbh->do('DROP TABLE IF EXISTS share');
        }
        $class->_writeMetaKey('schema_share_migrated', 1);
    }

    $dbh->do(q{
        CREATE TABLE IF NOT EXISTS share (
            id              INTEGER PRIMARY KEY AUTOINCREMENT,
            user_id         INTEGER NOT NULL REFERENCES "user"(id) ON DELETE CASCADE,
            token           TEXT NOT NULL,
            description     TEXT DEFAULT '',
            created_at      INTEGER NOT NULL,
            expires_at      INTEGER,
            last_visited_at INTEGER,
            visit_count     INTEGER DEFAULT 0
        )
    });
    $dbh->do('CREATE UNIQUE INDEX IF NOT EXISTS uq_share_token ON share(token)');
    $dbh->do('CREATE INDEX IF NOT EXISTS idx_share_user_id ON share(user_id)');
    $dbh->do('CREATE INDEX IF NOT EXISTS idx_share_expires ON share(expires_at)');

    $dbh->do(q{
        CREATE TABLE IF NOT EXISTS share_entry (
            share_id  INTEGER NOT NULL REFERENCES share(id) ON DELETE CASCADE,
            sq_id     TEXT NOT NULL,
            item_type TEXT NOT NULL,
            PRIMARY KEY (share_id, sq_id)
        )
    });

    # Persistent text cache for artist biographies.  The Music & Artist Info
    # plugin does not yet persist biographies to disk.  See Core/TextCacheStore.pm.
    $dbh->do(q{
        CREATE TABLE IF NOT EXISTS text_cache (
            cache_key  TEXT PRIMARY KEY,
            content    TEXT NOT NULL,
            fetched_at INTEGER NOT NULL
        )
    });

    # Add ttl column if missing (TTL expiry for bio cache, negative sentinels)
    {
        my $has_ttl = eval {
            my $info = $dbh->selectall_arrayref("PRAGMA table_info('text_cache')");
            $info && scalar(grep { $_->[1] eq 'ttl' } @$info);
        };
        unless ($has_ttl) {
            $dbh->do('ALTER TABLE text_cache ADD COLUMN ttl INTEGER');
        }
    }

    $log->info('SlimPing: schema deployed');
    return;
}

sub dbh {
    my $class = shift;
    return $class->connect()->storage->dbh;
}

# Durable key-value accessors for the plugin_metadata table.
# Read returns undef when the key does not exist or the table is
# unavailable (pre-deploySchema).  Write uses INSERT OR REPLACE so
# existing keys are updated in-place without a separate existence check.
sub _readMetaKey {
    my ($class, $key) = @_;
    my ($value) = $class->dbh()->selectrow_array(
        'SELECT meta_value FROM plugin_metadata WHERE meta_key = ?',
        undef, $key
    );
    return $value;
}

sub _writeMetaKey {
    my ($class, $key, $value) = @_;
    $class->dbh()->do(
        'INSERT OR REPLACE INTO plugin_metadata (meta_key, meta_value) VALUES (?, ?)',
        undef, $key, $value
    );
    return;
}

sub disconnect {
    my $class = shift;
    if ($_schema && $_schema->storage && $_schema->storage->dbh) {
        # Flush the WAL before disconnecting so committed data reaches the
        # main database file.  PASSIVE is safe even with concurrent readers
        # (checkpoints only if no readers are blocking).
        eval { $_schema->storage->dbh->do('PRAGMA wal_checkpoint(PASSIVE)'); };
        $_schema->storage->dbh->disconnect();
    }
    $_schema = undef;
    return;
}

1;
