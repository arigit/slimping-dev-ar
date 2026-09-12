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
# API/ResponseFormatter.pm - Serialises handler data to JSON or XML
#
# Handlers return plain Perl hashrefs.  ResponseFormatter wraps them in the
# Subsonic envelope and serialises to the requested format.
#
# No Slim:: dependencies -- this module must remain testable standalone.
#

package Plugins::SlimPing::API::ResponseFormatter;

use strict;
use warnings;

use Encode qw(decode_utf8 is_utf8);
use JSON::XS ();
use Scalar::Util qw(looks_like_number);

use constant SUBSONIC_VERSION => '1.16.1';
use constant SERVER_TYPE      => 'SlimPing (Lyrion)';

our $SERVER_VERSION = '';

my $json_codec = JSON::XS->new->utf8->canonical(0);

# init($plugin_version)
#
# Called once at plugin startup with the plugin version string.
# Sets the serverVersion field to "pluginVersion-LMSVersion".
sub init {
    my ($class, $plugin_version) = @_;
    $SERVER_VERSION = ($plugin_version // 'unknown') . '-' . ($::VERSION // 'unknown');
}

# render($class, $data, $format) -> string
#
# $data   - hashref of handler result (may contain 'error' key for failures)
# $format - 'json' or 'xml' (defaults to 'xml')
#
# Returns the serialised Subsonic envelope as a UTF-8 string.
sub render {
    my ($class, $data, $format) = @_;
    $format //= 'xml';

    my $has_error = exists $data->{error};

    my $envelope = {
        'subsonic-response' => {
            status        => ($has_error ? 'failed' : 'ok'),
            version       => SUBSONIC_VERSION,
            type          => SERVER_TYPE,
            serverVersion => $SERVER_VERSION || $::VERSION || 'unknown',
            openSubsonic  => \1,    # JSON::XS encodes scalar ref \1 as true
            %$data,
        }
    };

    _utf8Normalise($envelope);

    return ($format eq 'json')
        ? $json_codec->encode(_stripUndef($envelope))
        : _toXml($envelope);
}

# _utf8Normalise($data) -> $data
#
# Recursively walks hashrefs and arrayrefs, calling decode_utf8 on any scalar
# value that lacks the Perl UTF-8 flag.  Strings from raw DBI fetches may
# contain valid UTF-8 bytes without the flag; JSON::XS->utf8 would treat them
# as Latin-1 and double-encode them.  Normalising the flag before encoding
# prevents garbled non-ASCII characters in JSON responses.
# SCALAR refs (\1 / \0 used for Subsonic boolean values) are left untouched.
sub _utf8Normalise {
    my ($data) = @_;
    return $data unless ref $data;
    if (ref $data eq 'HASH') {
        for my $k (keys %$data) {
            my $v = $data->{$k};
            if (!ref $v) {
                $data->{$k} = decode_utf8($v) unless is_utf8($v) || looks_like_number($v);
            } elsif (ref $v ne 'SCALAR') {
                _utf8Normalise($v);
            }
        }
    } elsif (ref $data eq 'ARRAY') {
        for my $i (0 .. $#$data) {
            my $v = $data->[$i];
            if (!ref $v) {
                $data->[$i] = decode_utf8($v) unless is_utf8($v) || looks_like_number($v);
            } elsif (ref $v ne 'SCALAR') {
                _utf8Normalise($v);
            }
        }
    }
    return $data;
}

# _stripUndef($data) -> $data
#
# Recursively removes undef values from hashrefs and arrayrefs so that
# JSON::XS never emits null literals.  Clients (e.g. Symfonium) may use
# strict JSON parsers that reject null where a typed value is expected.
# This mirrors the XML path where _renderElement skips undef keys.
sub _stripUndef {
    my ($data) = @_;
    return $data unless ref $data;
    if (ref $data eq 'HASH') {
        my %clean;
        for my $k (keys %$data) {
            my $v = $data->{$k};
            next unless defined $v;
            $clean{$k} = _stripUndef($v);
        }
        return \%clean;
    }
    if (ref $data eq 'ARRAY') {
        return [ map { _stripUndef($_) } grep { defined $_ } @$data ];
    }
    return $data;
}

#
# Recursively serialises the Subsonic envelope hashref to XML without an
# external XML module so the formatter remains testable in any Perl environment.
#
# Conventions (matching Subsonic XML reference output):
#   - Scalar envelope keys become attributes on <subsonic-response>
#   - SCALAR refs (\1 / \0) become "true" / "false" attribute values
#   - undef values are skipped (optional fields omitted)
#   - Hashref keys become child elements; scalar/SCALAR-ref sub-keys become
#     attributes, ref sub-keys become nested child elements
#   - Arrayrefs become repeated child elements named after their key
sub _toXml {
    my ($data) = @_;

    my $inner = $data->{'subsonic-response'};

    my @attrs = ('xmlns="http://subsonic.org/restapi"');
    my @children;

    for my $key (sort keys %$inner) {
        my $val = $inner->{$key};
        if (ref $val && ref $val ne 'SCALAR') {
            push @children, _renderElement($key, $val);
        } else {
            my $text = ref $val eq 'SCALAR' ? ($$val ? 'true' : 'false') : $val;
            my $escaped = _xmlEscape($text);
            push @attrs, qq{$key="$escaped"};
        }
    }

    my $attr_str = @attrs ? ' ' . join(' ', @attrs) : '';

    if (@children) {
        return qq{<?xml version="1.0" encoding="UTF-8"?>\n}
             . qq{<subsonic-response$attr_str>\n}
             . join("\n", @children) . "\n"
             . qq{</subsonic-response>\n};
    }

    return qq{<?xml version="1.0" encoding="UTF-8"?>\n}
         . qq{<subsonic-response$attr_str />\n};
}

# Recursively render a Perl value as an XML element.
#
#   HASH   -- scalar/SCALAR-ref values become attributes; ref values become children
#   ARRAY  -- each entry becomes a child element with the parent's key as its name
#   SCALAR -- text content: "true" / "false"
#   undef  -- empty element (rare; callers should skip undef keys before here)
sub _renderElement {
    my ($key, $val) = @_;

    return '' unless defined $key && length $key;

    if (ref $val eq 'ARRAY') {
        my @items;
        for my $entry (@$val) {
            next unless defined $entry;
            push @items, _renderElement($key, $entry);
        }
        return join("\n", @items);
    }

    if (ref $val eq 'HASH') {
        my @elem_attrs;
        my @elem_children;
        for my $k (sort keys %$val) {
            my $v = $val->{$k};
            next unless defined $v;
            if (ref $v && ref $v ne 'SCALAR') {
                push @elem_children, _renderElement($k, $v);
            } else {
                my $text = ref $v eq 'SCALAR' ? ($$v ? 'true' : 'false') : $v;
                my $escaped = _xmlEscape($text);
                push @elem_attrs, qq{$k="$escaped"};
            }
        }
        my $attr_str = @elem_attrs ? ' ' . join(' ', @elem_attrs) : '';
        if (@elem_children) {
            return qq{<$key$attr_str>\n}
                 . join("\n", @elem_children) . "\n"
                 . qq{</$key>};
        }
        return qq{<$key$attr_str />};
    }

    if (ref $val eq 'SCALAR') {
        my $text = $$val ? 'true' : 'false';
        return qq{<$key>$text</$key>};
    }

    # Plain scalar -- text content
    return qq{<$key>} . _xmlEscape($val) . qq{</$key>};
}

# _xmlEscape($str) -> string
#
# Escapes special XML characters in an attribute value.
sub _xmlEscape {
    my ($str) = @_;
    $str =~ s/&/&amp;/g;
    $str =~ s/"/&quot;/g;
    $str =~ s/</&lt;/g;
    $str =~ s/>/&gt;/g;
    return $str;
}

# --- REST URL helpers ---------------------------------------------------------
#
# One source of truth for the REST URL shape.  If we ever version the endpoint
# (/rest/v2/...) or add query-string conventions, the change happens here.
# Callers that need an FQDN URL pass base_url => $scheme_host as the keyword.

sub coverArtUrl {
    my ($class, $id, %opts) = @_;
    return undef unless defined $id && length $id;
    my $size = $opts{size};
    my $url  = "/rest/getCoverArt.view?id=$id";
    $url .= "&size=$size" if defined $size;
    return ($opts{base_url} // '') . $url;
}

sub streamUrl {
    my ($class, $id, %opts) = @_;
    return undef unless defined $id && length $id;
    my $url = ($opts{base_url} // '') . '/rest/stream.view?id=' . $id;
    if ($opts{token}) {
        $url .= '&t_stream=' . $opts{token};
        $url .= '&token_expires=' . $opts{token_expires}
          if defined $opts{token_expires};
    }
    return $url;
}

# Construct a self-authenticating radio stream URL pointing to the overlay
# radioStream.view endpoint.  t_stream and token_expires are always embedded
# because radioStream.view requires an HMAC credential.
sub radioStreamUrl {
    my ($class, $id, %opts) = @_;
    return undef unless defined $id && length $id;
    my $url = ($opts{base_url} // '') . '/rest/radioStream.view?sq_id=' . $id;
    if ($opts{token}) {
        $url .= '&t_stream=' . $opts{token};
        $url .= '&token_expires=' . $opts{token_expires}
          if defined $opts{token_expires};
    }
    return $url;
}

1;
