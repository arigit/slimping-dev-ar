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
# Utils/ResponseTrimmer.pm - Client-aware response field trimming
#
# Strips fields from a response hashref in-place based on minimalClients
# and legacyClients preference lists.  Applied once at the Router level
# after handler dispatch, before ResponseFormatter runs.
#

package Plugins::SlimPing::Utils::ResponseTrimmer;

use strict;
use warnings;

use Plugins::SlimPing::Core::Logging;

# OpenSubsonic extension fields to strip for legacy clients.
# Navidrome's LegacyClients list strips these; we follow that precedent.
my %_legacy_strip = map { $_ => 1 } qw(
    musicBrainzId genres replayGain isrc contributors moods
    explicitStatus mediaType sortName displayArtist displayAlbumArtist
    displayComposer albumArtists artists contributors channelCount
    samplingRate bitDepth played bpm comment replayGain
    groupings works
);

# trim($class, $data, $client_name) -> $data (modified in-place)
#
# Applies minimalClients and legacyClients rules to the response.
# Returns the same reference for chaining convenience.
sub trim {
    my ($class, $data, $client_name) = @_;

    return $data unless $data && ref $data eq 'HASH';
    return $data unless defined $client_name && length $client_name;

    my $prefs = Plugins::SlimPing::Core::Logging->getPrefs();
    my $minimal_csv = $prefs->get('minimalClients') || '';
    my $legacy_csv  = $prefs->get('legacyClients')  || '';

    my %minimal_clients = map { $_ => 1 } grep { length $_ } split /\s*,\s*/, $minimal_csv;
    my %legacy_clients  = map { $_ => 1 } grep { length $_ } split /\s*,\s*/, $legacy_csv;

    return $data unless %minimal_clients || %legacy_clients;
    return $data unless $minimal_clients{$client_name} || $legacy_clients{$client_name};

    if ($minimal_clients{$client_name}) {
        _trimMinimal($data);
    }

    if ($legacy_clients{$client_name}) {
        _trimLegacy($data);
    }

    return $data;
}

# Strip to Child-schema minimum: id, isDir, title plus type-specific required fields.
# Traverses response keys to find arrays of items and strips each one.
sub _trimMinimal {
    my ($data) = @_;

    for my $key (keys %$data) {
        my $val = $data->{$key};
        next unless ref $val eq 'HASH';

        # Direct entity: { song => { id => ..., title => ... } }
        if (my $entity = _entityType($key)) {
            _stripToMinimal($val, $entity);
        } else {
            # Container: { searchResult3 => { artist => [...], album => [...], song => [...] } }
            # or: { artists => { index => [ { artist => [...] } ] } }
            # or: { indexes => { index => [ ... ] } }
            _trimMinimal($val);
        }

        # Arrays of children: { randomSongs => { song => [...] } }
        if (my $entity = _entityType($key)) {
            my $list = $val->{$entity};
            if (ref $list eq 'ARRAY') {
                _stripToMinimal($_, $entity) for @$list;
            }
        }
    }
}

# Determine the entity type from a response key name.
sub _entityType {
    my ($key) = @_;
    return 'artist' if $key =~ /artist/i;
    return 'album'  if $key =~ /album/i;
    return 'song'   if $key =~ /^(song|track|child|entry)$/i;
    return 'genre'  if $key =~ /genre/i;
    return 'playlist' if $key =~ /playlist/i;
    return undef;
}

# Strip a single entity hashref to its minimal schema-required fields.
sub _stripToMinimal {
    my ($hash, $type) = @_;
    return unless ref $hash eq 'HASH';

    my %keep = (
        id    => $hash->{id},
        isDir => $hash->{isDir} // \0,
        title => $hash->{title},
    );
    $keep{name}  = $hash->{name}  if exists $hash->{name};
    $keep{isDir} = $hash->{isDir} if exists $hash->{isDir};

    # Clear the hash and repopulate with only the minimal set.
    %$hash = %keep;
}

# Strip OpenSubsonic extension fields from a response tree.
sub _trimLegacy {
    my ($data) = @_;

    for my $key (keys %$data) {
        my $val = $data->{$key};
        next unless defined $val;

        if (ref $val eq 'HASH') {
            # Strip extension fields from the hash itself
            _stripLegacyFields($val);
            # Recurse into nested containers
            _trimLegacy($val);
            # Handle arrays inside: { song => [...] }
            for my $inner_key (keys %$val) {
                my $inner_val = $val->{$inner_key};
                if (ref $inner_val eq 'ARRAY') {
                    for my $item (@$inner_val) {
                        if (ref $item eq 'HASH') {
                            _stripLegacyFields($item);
                            _trimLegacy($item);
                        }
                    }
                }
            }
        } elsif (ref $val eq 'ARRAY') {
            for my $item (@$val) {
                if (ref $item eq 'HASH') {
                    _stripLegacyFields($item);
                    _trimLegacy($item);
                }
            }
        }
    }
}

# Strip extension fields from a single entity hashref.
sub _stripLegacyFields {
    my ($hash) = @_;
    return unless ref $hash eq 'HASH';
    delete $hash->{$_} for grep { $_legacy_strip{$_} } keys %$hash;
}

1;
