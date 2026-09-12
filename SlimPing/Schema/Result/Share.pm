package Plugins::SlimPing::Schema::Result::Share;

use strict;
use warnings;

use base 'DBIx::Class::Core';

__PACKAGE__->source_name('Share');
__PACKAGE__->table('share');
__PACKAGE__->add_columns(
    id              => { data_type => 'integer', is_auto_increment => 1 },
    user_id         => { data_type => 'integer', is_nullable => 0 },
    token           => { data_type => 'text', is_nullable => 0 },
    description     => { data_type => 'text', default_value => '' },
    created_at      => { data_type => 'integer', is_nullable => 0 },
    expires_at      => { data_type => 'integer', is_nullable => 1 },
    last_visited_at => { data_type => 'integer', is_nullable => 1 },
    visit_count     => { data_type => 'integer', default_value => 0 },
);
__PACKAGE__->set_primary_key('id');

__PACKAGE__->belongs_to(
    user => 'Plugins::SlimPing::Schema::Result::User',
    'user_id',
);

__PACKAGE__->has_many(
    share_entries => 'Plugins::SlimPing::Schema::Result::ShareEntry',
    'share_id',
);

1;
