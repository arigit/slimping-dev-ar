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
# Utils/Params.pm - HTTP parameter normalisation helpers
#
# Stateless utility for flattening multi-value params, clamping numeric
# ranges, and coercing JSON boolean values.
#

package Plugins::SlimPing::Utils::Params;

use strict;
use warnings;

use Plugins::SlimPing::Core::Logging;

my $log = Plugins::SlimPing::Core::Logging->getLogger();

# Flatten a parameter value that may be a scalar or arrayref into a flat list.
# Returns () for undef, @$val for arrayref, ($val) for scalar.
sub multiParam {
    my ($class, $val) = @_;
    return () unless defined $val;
    return ref $val eq 'ARRAY' ? @$val : ($val);
}

# Clamp a numeric value between min and max, falling back to default if undef.
sub clamp {
    my $class   = shift;
    my %args    = @_;
    my $val     = $args{val}     // 0;
    my $min     = $args{min}     // 0;
    my $max     = $args{max}     // 0;
    my $default = $args{default} // 0;

    $val = $default unless defined $args{val};
    $val = $min     if $val < $min;
    $val = $max     if $val > $max;
    return int($val);
}

# Coerce a JSON-decoded value to a clean 0/1.  Handles native scalars (0, 1,
# '0', '1', '', undef) and JSON::PP::Boolean / JSON::XS::Boolean blessed
# reference objects defensively — older JSON::PP::Boolean releases do not
# overload bool, so $obj ? 1 : 0 returns 1 for a JSON false (it is a
# reference, hence truthy).  We dereference when we see a SCALAR ref and
# fall back to a string match for safety.
sub coerceBool {
    my ($class, $v) = @_;
    return 0 unless defined $v;
    if ( ref $v ) {
        # JSON::PP::Boolean is bless \$value, 'JSON::PP::Boolean' where
        # $value is 0 or 1 — dereferencing recovers the raw number.
        if ( ref $v eq 'JSON::PP::Boolean' || ref $v eq 'JSON::XS::Boolean' ) {
            return $$v ? 1 : 0;
        }
        # Unknown ref type — log and default to 0.  All callers are
        # feature or security toggles where default-off is safer.
        $log->warn("SlimPing: coerceBool received unexpected ref type " . ref($v) . ", defaulting to 0");
        return 0;
    }
    return ( $v && $v ne '0' && lc("$v") ne 'false' ) ? 1 : 0;
}

1;
