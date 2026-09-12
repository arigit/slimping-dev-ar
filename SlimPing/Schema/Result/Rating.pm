package Plugins::SlimPing::Schema::Result::Rating;

use strict;
use warnings;

use base 'DBIx::Class::Core';

__PACKAGE__->source_name('Rating');
__PACKAGE__->table('rating');
__PACKAGE__->add_columns(
    user_id  => { data_type => 'integer', is_nullable => 0 },
    sq_id    => { data_type => 'text', is_nullable => 0 },
    rating   => { data_type => 'integer', is_nullable => 0 },
    rated_at => { data_type => 'integer', is_nullable => 0 },
);
__PACKAGE__->set_primary_key(qw(user_id sq_id));

__PACKAGE__->belongs_to(
    user => 'Plugins::SlimPing::Schema::Result::User',
    'user_id',
);

1;
