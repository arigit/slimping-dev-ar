package Plugins::SlimPing::Schema::Result::ApiKey;

use strict;
use warnings;

use base 'DBIx::Class::Core';

__PACKAGE__->source_name('ApiKey');
__PACKAGE__->table('api_key');
__PACKAGE__->add_columns(
    id           => { data_type => 'integer', is_auto_increment => 1 },
    user_id      => { data_type => 'integer', is_nullable => 0 },
    key_hash     => { data_type => 'text', is_nullable => 0 },
    prefix       => { data_type => 'text', is_nullable => 0 },
    label        => { data_type => 'text', default_value => 'Default' },
    created_at   => { data_type => 'integer', is_nullable => 0 },
    last_used_at => { data_type => 'integer', is_nullable => 1 },
);
__PACKAGE__->set_primary_key('id');
__PACKAGE__->add_unique_constraint(['key_hash']);
__PACKAGE__->add_unique_constraint('uq_apikey_user_prefix', ['user_id', 'prefix']);

__PACKAGE__->belongs_to(
    user => 'Plugins::SlimPing::Schema::Result::User',
    'user_id',
);

1;
