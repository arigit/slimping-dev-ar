package Plugins::SlimPing::Utils::ShellQuote;

# Shell argument quoting for external process pipelines.
#
# This is a stateless utility; no constructor needed.  All three audio
# delivery sub-modules (AudioDelivery, CueLossless, FileServe) need to
# quote file paths and binary paths for shell command construction.
# A single copy here avoids the cross-module hard-reference pattern
# (which breaks silently if the original sub is renamed or removed).

use strict;
use warnings;

# Quote a string for safe use as a single shell argument.
# Wraps the value in single quotes and escapes any embedded single quotes
# with the standard '"'"' dance.  Inside single quotes, all other shell
# metacharacters (&, |, $, `, \, etc.) are literal.
sub shellQuote {
    my ($s) = @_;
    $s =~ s/'/'"'"'/g;
    return "'" . $s . "'";
}

1;
