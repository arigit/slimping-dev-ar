# SlimPing - An LMS Plugin exposing an OpenSubsonic REST API
#
# Copyright (C) 2026 John Willis
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program.  If not, see <http://www.gnu.org/licenses/>.
#

#
# Core/ShareStore.pm - Share persistence for SlimPing
#
# SQLite-backed store for time-limited, revocable share tokens.  All mutations
# are immediate committed writes -- no flush timer needed.  Follows the same
# singleton pattern as UserStore, StarStore, etc.
#

package Plugins::SlimPing::Core::ShareStore;

use strict;
use warnings;

use Digest::SHA qw(sha256_hex);

use Plugins::SlimPing::Core::Logging;
use Plugins::SlimPing::Schema;
require Plugins::SlimPing::Core::UserStore;

my $log   = Plugins::SlimPing::Core::Logging->getLogger();
my $prefs = Plugins::SlimPing::Core::Logging->getPrefs();

my $_instance;

# In-memory per-share IP set for diversity tracking (max 5000 tokens x ~20 IPs ~ 1 MB).
# Cleared on LMS restart -- approximate guard, not exact.
my %_share_ips;

sub getInstance {
    my $class = shift;
    $_instance //= bless {}, $class;
    return $_instance;
}


sub _generateToken {
    my $rand;
    sysopen(my $fh, '/dev/urandom', 0)
        or die "SlimPing: cannot open /dev/urandom for entropy: $!";
    sysread($fh, $rand, 32) == 32
        or die "SlimPing: short read from /dev/urandom";
    close($fh);
    return substr(sha256_hex($rand), 0, 32);
}


sub createShare {
    my ($self, $username, $sq_ids, $description, $ttl) = @_;

    # Normalise and sanitise description.
    $description = _sanitiseDescription($description);

    # Validate TTL against server bounds
    $ttl = _clampTtl($ttl);

    # Cap checks
    my $max_entries = $prefs->get('max_share_entries');
    if (scalar(@$sq_ids) > $max_entries) {
        return { error => { code => 0, message => "Share exceeds maximum $max_entries entries" } };
    }

    my $user_cap = $prefs->get('share_user_cap');
    my $user_count = $self->countByUser($username);
    if ($user_count >= $user_cap) {
        return { error => { code => 0, message => "User has reached maximum $user_cap active shares" } };
    }

    my $global_cap = $prefs->get('share_global_cap');
    my $global_count = $self->_countAllActive();
    if ($global_count >= $global_cap) {
        return { error => { code => 0, message => "Server has reached maximum $global_cap total shares" } };
    }

    # Lookup user_id
    my $user_row = Plugins::SlimPing::Core::UserStore->getInstance->getByUsername($username);
    return Plugins::SlimPing::Utils::Errors->notFound('User') unless $user_row;

    # Generate a unique token
    my $token;
    my $schema = Plugins::SlimPing::Schema->connect();
    while (1) {
        $token = _generateToken();
        my $existing = $schema->resultset('Share')
            ->search({ token => $token })->first();
        last unless $existing;
    }

    my $now    = time();
    my $expiry = $now + $ttl;

    # Atomic insert: share + entries in a transaction
    my $share;
    $schema->txn_do(sub {
        $share = $schema->resultset('Share')->create({
            user_id     => $user_row->id(),
            token       => $token,
            description => $description,
            created_at  => $now,
            expires_at  => $expiry,
        });

        for my $sq_id (@$sq_ids) {
            $schema->resultset('ShareEntry')->create({
                share_id  => $share->id(),
                sq_id     => $sq_id,
                item_type => _itemTypeFromId($sq_id),
            });
        }
    });

    # Initialise in-memory IP diversity set
    $_share_ips{$token} = {};

    return $share;
}

sub getShares {
    my ($self, $username) = @_;
    my $user_row = Plugins::SlimPing::Core::UserStore->getInstance->getByUsername($username);
    return [] unless $user_row;

    my $now = time();
    my $rs  = Plugins::SlimPing::Schema->connect()->resultset('Share')
        ->search(
            { user_id => $user_row->id(), expires_at => { '>' => $now } },
            { order_by => { -desc => 'created_at' } }
        );

    return [ map { $self->_shapeShare($_) } $rs->all() ];
}

sub getShareByToken {
    my ($self, $token) = @_;
    return undef unless defined $token && length $token;
    return undef unless $token =~ /\A[0-9a-f]{32}\z/;

    my $share = Plugins::SlimPing::Schema->connect()->resultset('Share')
        ->search({ token => $token })->first();
    return undef unless $share;

    # Expiry check -- expired shares are returned as undef (same as not-found)
    return undef if $share->expires_at() && time() > $share->expires_at();

    return $self->_shapeShare($share);
}

sub updateShare {
    my ($self, $token, $description, $new_ttl) = @_;

    my $share = Plugins::SlimPing::Schema->connect()->resultset('Share')
        ->search({ token => $token })->first();
    return 0 unless $share;

    if (defined $description) {
        $share->update({ description => _sanitiseDescription($description) });
    }

    if (defined $new_ttl) {
        $share->update({ expires_at => time() + _clampTtl($new_ttl) });
    }

    return 1;
}

sub deleteShare {
    my ($self, $token) = @_;
    my $share = Plugins::SlimPing::Schema->connect()->resultset('Share')
        ->search({ token => $token })->first();
    return 0 unless $share;
    $share->delete();   # CASCADE removes share_entry rows
    delete $_share_ips{$token};
    return 1;
}

sub recordVisit {
    my ($self, $token) = @_;
    my $share = Plugins::SlimPing::Schema->connect()->resultset('Share')
        ->search({ token => $token })->first();
    return unless $share;
    $share->update({
        visit_count     => ($share->visit_count() // 0) + 1,
        last_visited_at => time(),
    });
}

sub getAllShares {
    my $self = shift;
    my $rs = Plugins::SlimPing::Schema->connect()->resultset('Share')
        ->search({}, { order_by => { -desc => 'created_at' } });
    return [ map { $self->_shapeShare($_) } $rs->all() ];
}

sub revokeShare {
    my ($self, $token) = @_;
    return $self->deleteShare($token);
}

sub revokeAllShares {
    my $self = shift;
    my $rs = Plugins::SlimPing::Schema->connect()->resultset('Share');
    my $count = 0;
    while (my $share = $rs->next()) {
        $share->delete();
        delete $_share_ips{ $share->token() };
        $count++;
    }
    return $count;
}

sub pruneExpired {
    my $self = shift;
    my $now  = time();
    my $rs   = Plugins::SlimPing::Schema->connect()->resultset('Share')
        ->search({ expires_at => { '<' => $now } });
    my $count = 0;
    while (my $share = $rs->next()) {
        delete $_share_ips{ $share->token() };
        $share->delete();
        $count++;
    }
    if ($count) {
        $log->info("SlimPing: pruned $count expired share(s)");
    }
}

sub countByUser {
    my ($self, $username) = @_;
    my $user_row = Plugins::SlimPing::Core::UserStore->getInstance->getByUsername($username);
    return 0 unless $user_row;

    my $now = time();
    return Plugins::SlimPing::Schema->connect()->resultset('Share')
        ->search(
            { user_id => $user_row->id(), expires_at => { '>' => $now } }
        )->count();
}

sub _countAllActive {
    my $now = time();
    return Plugins::SlimPing::Schema->connect()->resultset('Share')
        ->search({ expires_at => { '>' => $now } })->count();
}


sub recordIp {
    my ($self, $token, $ip) = @_;
    return unless defined $token && defined $ip;

    $_share_ips{$token} //= {};
    $_share_ips{$token}{$ip} = 1;

    my $max_ips = $prefs->get('share_max_unique_ips');
    my $count   = scalar(keys %{ $_share_ips{$token} });
    return $count if $count <= $max_ips;

    # Auto-revoke: too many unique IPs.  Token is a bearer credential --
    # only log the first 4 chars so operators can correlate without exposing
    # the full secret.
    my $token_short = substr($token, 0, 4);
    $log->warn("SlimPing: share $token_short... auto-revoked -- $count unique IPs (limit $max_ips)");
    $self->revokeShare($token);
    return $count;
}

sub getUniqueIpCount {
    my ($self, $token) = @_;
    return 0 unless exists $_share_ips{$token};
    return scalar(keys %{ $_share_ips{$token} });
}


# Sanitise a share description: replace control characters with spaces and
# truncate to 500 characters.  Returns empty string for undef input.
sub _sanitiseDescription {
    my ($desc) = @_;
    $desc //= '';
    $desc =~ s/[\x00-\x1f\x7f]/ /g;
    return substr($desc, 0, 500);
}

# Clamp a TTL value to server-configured min and max bounds.  Defaults to the
# configured share_default_ttl when called with undef.
sub _clampTtl {
    my ($ttl) = @_;
    $ttl //= $prefs->get('share_default_ttl');
    my $min = $prefs->get('share_min_ttl');
    my $max = $prefs->get('share_max_ttl');
    $ttl = $min if $ttl < $min;
    $ttl = $max if $ttl > $max;
    return $ttl;
}

# Shape a DBIx::Class Share row into the API hashref form
sub shapeShare {
    my ( $self, $dbix_share ) = @_;
    return $self->_shapeShare($dbix_share);
}

sub _shapeShare {
    my ($self, $share) = @_;

    my $user    = $share->user();
    my $entries = $share->share_entries();

    require Plugins::SlimPing::Core::Container;
    my $mapper = Plugins::SlimPing::Core::Container->get('library_mapper');

    my @entry_list;
    while (my $e = $entries->next()) {
        my $track = $mapper->getTrackById( $e->sq_id() );
        push @entry_list, $track if $track;
    }

    my $cover_art = @entry_list ? ($entry_list[0]{coverArt} // '') : '';

    return {
        id          => $share->token(),
        description => $share->description() // '',
        username    => $user ? $user->username() : '(deleted)',
        entry       => \@entry_list,
        coverArt    => $cover_art,
        created     => Plugins::SlimPing::Core::LibraryMapper::_iso8601( $share->created_at() // time() ),
        expires     => Plugins::SlimPing::Core::LibraryMapper::_iso8601( $share->expires_at() // 0 ),
        lastVisited => Plugins::SlimPing::Core::LibraryMapper::_iso8601( $share->last_visited_at() // 0 ),
        visitCount  => ($share->visit_count() // 0) + 0,
    };
}

sub _itemTypeFromId {
    my ($sq_id) = @_;
    return '' unless defined $sq_id;
    return 'track'    if $sq_id =~ /^sq_tr_/;
    return 'album'    if $sq_id =~ /^sq_al_/;
    return 'playlist' if $sq_id =~ /^sq_pl_/;
    return 'radio'    if $sq_id =~ /^sq_rd_/;
    return '';
}

1;
