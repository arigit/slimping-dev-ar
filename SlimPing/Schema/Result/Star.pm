package Plugins::SlimPing::Schema::Result::Star;

use strict;
use warnings;

use base 'DBIx::Class::Core';

__PACKAGE__->source_name('Star');
__PACKAGE__->table('star');
__PACKAGE__->add_columns(
    user_id    => { data_type => 'integer', is_nullable => 0 },
    sq_id      => { data_type => 'text', is_nullable => 0 },
    item_type  => { data_type => 'text', is_nullable => 0 },
    starred_at => { data_type => 'integer', is_nullable => 0 },
);
__PACKAGE__->set_primary_key(qw(user_id sq_id));

__PACKAGE__->belongs_to(
    user => 'Plugins::SlimPing::Schema::Result::User',
    'user_id',
);

1;
