package Plugins::SlimPing::Schema::Result::Session;

use strict;
use warnings;

use base 'DBIx::Class::Core';

__PACKAGE__->source_name('Session');
__PACKAGE__->table('session');
__PACKAGE__->add_columns(
    user_id           => { data_type => 'integer', is_nullable => 0 },
    client_name       => { data_type => 'text', is_nullable => 0, default_value => '' },
    now_playing_track => { data_type => 'text', is_nullable => 1 },
    position_secs     => { data_type => 'integer', is_nullable => 1 },
    started_at        => { data_type => 'integer', is_nullable => 1 },
    last_seen_at      => { data_type => 'integer', is_nullable => 0 },
    play_queue        => { data_type => 'text', default_value => '[]' },
    queue_index       => { data_type => 'integer', default_value => 0 },
);
__PACKAGE__->set_primary_key(qw(user_id client_name));

__PACKAGE__->belongs_to(
    user => 'Plugins::SlimPing::Schema::Result::User',
    'user_id',
);

1;
