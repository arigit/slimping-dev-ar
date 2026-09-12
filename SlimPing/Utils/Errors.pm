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
# Utils/Errors.pm - Subsonic error hashref construction helpers
#
# Stateless utility providing one source of truth for the Subsonic error
# envelope shape.  Handlers call class methods instead of constructing
# { error => { code => N, message => '...' } } inline.
#

package Plugins::SlimPing::Utils::Errors;

use strict;
use warnings;

# Generic error hashref builder.
sub error {
    my ($class, $code, $message) = @_;
    return { error => { code => 0 + $code, message => $message } };
}

# Required parameter missing (code 10).
sub missingParam {
    my ($class, $param_name) = @_;
    return { error => { code => 10, message => "Required parameter $param_name is missing" } };
}

# Entity not found (code 70).
sub notFound {
    my ($class, $entity) = @_;
    return { error => { code => 70, message => "$entity not found" } };
}

# User not authorised (code 50).
sub notAuthorised {
    my ($class) = @_;
    return { error => { code => 50, message => 'User is not authorised for this operation' } };
}

# Extract a required parameter from $params, returning the error hashref if
# missing.  Callers use: Plugins::SlimPing::Utils::Errors->requireId($params, 'id') or return ...;
sub requireId {
    my ($class, $params, $key) = @_;
    $key //= 'id';
    my $val = $params->{$key};
    return $val if defined $val;
    return $class->missingParam($key);
}

# Validate that a parameter value is one of a set of allowed enum values.
# Returns undef if the value is valid or absent, or an error hashref (code 0) if
# the value does not match any allowed entry.
# Callers use: my $err = Plugins::SlimPing::Utils::Errors->requireEnum($type, 'type', ...); return $err if $err;
sub requireEnum {
    my ($class, $val, $param_name, @allowed) = @_;
    return undef unless defined $val;
    my %ok = map { $_ => 1 } @allowed;
    return undef if $ok{$val};
    return $class->error(0, "Unknown value '$val' for parameter '$param_name'. Valid values: " . join(', ', @allowed));
}

# Require at least one of the named parameters to be present and defined.
# Returns () if at least one is present, or an error hashref (code 10) if none are.
# Callers use: Plugins::SlimPing::Utils::Errors->requireOneOf($params, qw(id albumId artistId)) or return ...;
sub requireOneOf {
    my ($class, $params, @keys) = @_;
    for my $key (@keys) {
        return () if defined $params->{$key};
    }
    return $class->missingParam(join(' or ', @keys));
}

1;
