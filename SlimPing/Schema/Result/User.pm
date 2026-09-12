package Plugins::SlimPing::Schema::Result::User;

use strict;
use warnings;

use base 'DBIx::Class::Core';

__PACKAGE__->source_name('User');
__PACKAGE__->table('user');
__PACKAGE__->add_columns(
    id             => { data_type => 'integer', is_auto_increment => 1 },
    username       => { data_type => 'text', is_nullable => 0 },
    password_hash  => { data_type => 'text', is_nullable => 0 },
    password_plain => { data_type => 'text', is_nullable => 0 },
    admin          => { data_type => 'integer', default_value => 0 },
    enabled        => { data_type => 'integer', default_value => 1 },
    last_login     => { data_type => 'integer', is_nullable => 1 },
    jukebox_player => { data_type => 'text', is_nullable => 1 },
    radioFolder             => { data_type => 'text', is_nullable => 1 },
    scrobble_enabled        => { data_type => 'integer', default_value => 1 },
    playcount_sync_enabled  => { data_type => 'integer', default_value => 1 },
    log_playback_to_lms     => { data_type => 'integer', default_value => 1 },
    accept_playback_report  => { data_type => 'integer', default_value => 1 },
    created_at              => { data_type => 'integer', is_nullable => 0 },
);
__PACKAGE__->set_primary_key('id');
__PACKAGE__->add_unique_constraint(['username']);

__PACKAGE__->has_many(
    api_keys  => 'Plugins::SlimPing::Schema::Result::ApiKey',
    'user_id',
    { cascade_delete => 1 },
);
__PACKAGE__->has_many(
    stars     => 'Plugins::SlimPing::Schema::Result::Star',
    'user_id',
    { cascade_delete => 1 },
);
__PACKAGE__->has_many(
    ratings   => 'Plugins::SlimPing::Schema::Result::Rating',
    'user_id',
    { cascade_delete => 1 },
);
__PACKAGE__->has_many(
    bookmarks => 'Plugins::SlimPing::Schema::Result::Bookmark',
    'user_id',
    { cascade_delete => 1 },
);
__PACKAGE__->has_many(
    sessions  => 'Plugins::SlimPing::Schema::Result::Session',
    'user_id',
    { cascade_delete => 1 },
);

1;
