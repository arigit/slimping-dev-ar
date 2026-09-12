package Plugins::SlimPing::Schema::Result::ShareEntry;

use strict;
use warnings;

use base 'DBIx::Class::Core';

__PACKAGE__->source_name('ShareEntry');
__PACKAGE__->table('share_entry');
__PACKAGE__->add_columns(
    share_id  => { data_type => 'integer', is_nullable => 0 },
    sq_id     => { data_type => 'text', is_nullable => 0 },
    item_type => { data_type => 'text', is_nullable => 0 },
);
__PACKAGE__->set_primary_key('share_id', 'sq_id');

__PACKAGE__->belongs_to(
    share => 'Plugins::SlimPing::Schema::Result::Share',
    'share_id',
);

1;
