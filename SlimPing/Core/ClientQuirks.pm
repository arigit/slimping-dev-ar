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
# Core/ClientQuirks.pm - Client-specific workaround hooks
#
# A light-touch extension point for client-specific behavioural overrides.
# Each quirk is a named transform registered at init time and gated by:
#   1. A master kill-switch pref (client_quirks_enabled, default on)
#   2. A per-quirk pref (quirk_<name>, default on)
#   3. A client name match against the current request's c= parameter
#
# Hook types:
#   request  - transforms $args before handler dispatch
#   response - transforms the handler result hashref after dispatch
#   stream   - transforms stream args before pipeline dispatch
#
# All hooks bail immediately when the master pref is off, keeping the
# hot path free of overhead for the common (no-quirks) case.
#

package Plugins::SlimPing::Core::ClientQuirks;

use strict;
use warnings;

use Plugins::SlimPing::Core::Logging;

my $log   = Plugins::SlimPing::Core::Logging->getLogger();
my $prefs = Plugins::SlimPing::Core::Logging->getPrefs();

# Current request's client name (c= parameter).  Set by Router after auth.
my $_current_client;

# Quirk registry: name => { description, hook, clients => { name => 1 }, transform => sub, pref => 'quirk_<name>' }
my %_quirks;

# --- Registration ---------------------------------------------------------------

# Called once at plugin init.  Register all known quirks here.
sub init {
    my ($class) = @_;

    # Substreamer: artwork ID underscore bug.
    # SlimPing IDs use underscores (sq_al_12345); Substreamer's artwork URL
    # parser rejects them.  This quirk replaces underscores with hyphens in
    # coverArt IDs in responses, and converts them back in incoming requests
    # so decodeId can still parse them.
    # https://github.com/ghenry22/substreamer/issues/144

    # Response phase: replace _ with - in coverArt IDs
    _registerQuirk(
        name        => 'substreamer_artwork_response',
        description => 'Replace underscores with hyphens in coverArt IDs '
                     . '(github.com/ghenry22/substreamer/issues/144)',
        pref        => 'quirk_substreamer_artwork',
        hook        => 'response',
        clients     => { substreamer => 1 },
        transform   => \&_fixCoverArtUnderscores,
    );

    # Request phase: convert hyphenated IDs back to underscore format
    _registerQuirk(
        name        => 'substreamer_artwork_request',
        description => 'Convert hyphenated coverArt IDs back to underscore format',
        pref        => 'quirk_substreamer_artwork',
        hook        => 'request',
        clients     => { substreamer => 1 },
        transform   => \&_fixIncomingHyphenatedIds,
    );
}

sub _registerQuirk {
    my (%args) = @_;
    my $name = $args{name} or die 'ClientQuirks: quirk registration missing name';
    die "ClientQuirks: duplicate quirk registration '$name'"
        if exists $_quirks{$name};
    my $pref_name = $args{pref} // "quirk_$name";
    $_quirks{$name} = {
        description => $args{description} // '',
        pref        => $pref_name,
        hook        => $args{hook}        // 'response',
        clients     => $args{clients}     // {},
        transform   => $args{transform}   // sub { },
    };
}

# --- Per-request client tracking ------------------------------------------------

sub setRequestClient {
    my ($class, $client_name) = @_;
    $_current_client = undef;
    return unless $prefs->get('client_quirks_enabled');
    $_current_client = $client_name;
}

# --- Hook apply methods ---------------------------------------------------------

# Apply all request-phase quirks matching the current client.
# Called by Router before handler dispatch.
sub applyRequestHooks {
    my ($class, $args) = @_;
    return unless $prefs->get('client_quirks_enabled');
    return unless $_current_client;
    _applyHooks('request', $args);
}

# Apply all response-phase quirks matching the current client.
# Called by Router after handler dispatch, before ResponseFormatter.
# Mutates $result in-place.
sub applyResponseHooks {
    my ($class, $result) = @_;
    return unless $prefs->get('client_quirks_enabled');
    return unless $_current_client;
    return unless $result && ref $result eq 'HASH';
    _applyHooks('response', $result);
}

# Apply all stream-phase quirks matching the current client.
# Called by Stream handler before pipeline dispatch.
sub applyStreamHooks {
    my ($class, $args) = @_;
    return unless $prefs->get('client_quirks_enabled');
    return unless $_current_client;
    _applyHooks('stream', $args);
}

# --- Internal -------------------------------------------------------------------

# Walk registered quirks and apply any that match the current client + hook type.
sub _applyHooks {
    my ($hook_type, $data) = @_;

    for my $name (keys %_quirks) {
        my $q = $_quirks{$name};
        next unless $q->{hook} eq $hook_type;
        next unless $prefs->get( $q->{pref} );
        next unless _clientMatches( $_current_client, $q->{clients} );
        $log->debug("ClientQuirks: applying quirk '$name' for client '$_current_client'");
        $q->{transform}->($data);
    }
}

# Match a client name against a quirk's client allowlist using prefix matching.
# Many clients append version numbers or instance IDs to their base name
# (e.g. substreamer8 matches registered key 'substreamer').
sub _clientMatches {
    my ($current, $clients) = @_;
    return 0 unless defined $current && length $current;
    my $lc = lc $current;
    for my $prefix (keys %$clients) {
        return 1 if $lc eq $prefix || index( $lc, $prefix ) == 0;
    }
    return 0;
}

# --- Stream-level client quirks --------------------------------------------------

# Return a hashref of stream-level quirks for a given client.
# Called once per stream request from VirtualPlayer::streamViaPipeline.
# Returns an empty hashref when no quirks are registered for this client.
sub quirks_for_client {
    my ( $class, $user_agent, $client_name ) = @_;

    my $quirks = {};

    # Feishin: TCP send buffer must be small (LMS's default 64 KB
    # holds ~2.7 s of audio that Feishin never drains, causing
    # audio to stall after the first chunk).  ICY metadata must be
    # disabled (Feishin's HTTP client chokes on injected ICY blocks
    # despite requesting them in the Accept header).
    if ( defined $user_agent && index( lc($user_agent), 'feishin' ) >= 0 ) {
        $quirks->{enable_icy}   = 0;
        $quirks->{sndbuf_bytes} = 16384;
    }

    return $quirks;
}

# --- Quirk transforms -----------------------------------------------------------

# Response-tree walker: calls $callback on every hashref in the tree.
sub _walkResponseTree {
    my ($data, $callback) = @_;
    return unless ref $data eq 'HASH';

    $callback->($data);

    for my $key (keys %$data) {
        my $val = $data->{$key};
        next unless defined $val;

        if (ref $val eq 'HASH') {
            _walkResponseTree($val, $callback);
        }
        elsif (ref $val eq 'ARRAY') {
            for my $item (@$val) {
                _walkResponseTree($item, $callback) if ref $item eq 'HASH';
            }
        }
    }
}

# Replace underscores with hyphens in sq-IDs found in URL fields and in the
# coverArt field.  coverArt is a bare ID but clients construct their own
# cover-art URLs from it, so the underscore in sq_al_12345 ends up in a URL
# that Substreamer's parser truncates at the underscore.
sub _fixCoverArtUnderscores {
    my ($data) = @_;
    _walkResponseTree($data, sub {
        my ($node) = @_;
        for my $key (keys %$node) {
            my $val = $node->{$key};
            next unless defined $val && !ref $val;
            # Transform URL fields AND the coverArt bare ID (clients construct URLs from it).
            next unless $key eq 'coverArt' || ( $val =~ m{/rest/} && $val =~ /sq_/ );
            $val =~ s/\b(sq)_([a-z]+)_(\w+)\b/$1-$2-$3/g;
            $node->{$key} = $val;
        }
    });
}

# Convert hyphenated sq-IDs in the id param back to underscore format
# so decodeId can parse getCoverArt requests (e.g. sq-al-12345 → sq_al_12345).
sub _fixIncomingHyphenatedIds {
    my ($args) = @_;
    return unless $args && ref $args eq 'HASH';
    my $p = $args->{params};
    return unless $p && ref $p eq 'HASH';
    return unless defined $p->{id} && !ref $p->{id} && $p->{id} =~ /sq-/;
    $p->{id} =~ s/\b(sq)-([a-z]+)-(\w+)\b/$1_$2_$3/g;
}

1;
