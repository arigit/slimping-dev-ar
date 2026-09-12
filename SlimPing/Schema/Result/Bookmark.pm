package Plugins::SlimPing::Schema::Result::Bookmark;

use strict;
use warnings;

use base 'DBIx::Class::Core';

__PACKAGE__->source_name('Bookmark');
__PACKAGE__->table('bookmark');
__PACKAGE__->add_columns(
    id           => { data_type => 'integer', is_auto_increment => 1 },
    user_id      => { data_type => 'integer', is_nullable => 0 },
    sq_id        => { data_type => 'text', is_nullable => 0 },
    position_ms  => { data_type => 'integer', is_nullable => 0 },
    comment      => { data_type => 'text', default_value => '' },
    created_at   => { data_type => 'integer', is_nullable => 0 },
    changed_at   => { data_type => 'integer', is_nullable => 0 },
);
__PACKAGE__->set_primary_key('id');
__PACKAGE__->add_unique_constraint('uq_bookmark_user_sq', ['user_id', 'sq_id']);

__PACKAGE__->belongs_to(
    user => 'Plugins::SlimPing::Schema::Result::User',
    'user_id',
);

1;
