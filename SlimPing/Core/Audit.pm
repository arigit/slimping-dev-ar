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
# Core/Audit.pm - Admin-action audit log helper for SlimPing.
#
# Writes single-line tab-separated entries to the main `plugin.slimping`
# log category at WARN level so operators always see them at the default
# log setting.  Lines start with the literal token `AUDIT` so they're
# trivially greppable / filterable from regular plugin output.
#
# Format:
#   SlimPing AUDIT  actor=<u>  ip=<ip>  action=<verb>  target=<noun>  [detail=<extra>]
#
# Use record() from any handler that mutates user state (create/delete user,
# role change, API key add/delete, password reset, lan_mode toggle, etc).
#

package Plugins::SlimPing::Core::Audit;

use strict;
use warnings;

use Plugins::SlimPing::Core::Logging;

my $log = Plugins::SlimPing::Core::Logging->getLogger();

# record(actor => 'alice', ip => '203.0.113.4', action => 'create_user',
#        target => 'bob', detail => 'admin=1')
#
# Any field may be omitted; missing fields are written as '-'.  Emitted at
# WARN so admin actions are always visible at the default log level.
sub record {
    my (%args) = @_;
    my $actor  = $args{actor}  // '-';
    my $ip     = $args{ip}     // '-';
    my $action = $args{action} // '-';
    my $target = $args{target} // '-';
    my $detail = $args{detail};

    # Control characters would corrupt the single-line log format -- strip them.
    for ( $actor, $ip, $action, $target ) {
        s/[\t\r\n]/ /g if defined;
    }

    my $line = "SlimPing AUDIT\tactor=$actor\tip=$ip\taction=$action\ttarget=$target";
    if ( defined $detail && length $detail ) {
        $detail =~ s/[\t\r\n]/ /g;
        $line .= "\tdetail=$detail";
    }
    $log->warn($line);
    return;
}

1;
