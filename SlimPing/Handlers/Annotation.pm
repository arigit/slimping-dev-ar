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

# Handlers/Annotation.pm - Annotation endpoints: star, unstar, setRating
#
# REST handlers only.  Star/rating data storage and query methods live in
# Core::Annotations so that Core::LibraryMapper sub-modules can annotate shaped
# responses without depending on a Handler module.
#
# scrobble has moved to Playback.pm where it shares _recordPlayback with
# reportPlayback.

package Plugins::SlimPing::Handlers::Annotation;

use strict;
use warnings;

use Plugins::SlimPing::Core::Logging;
use Plugins::SlimPing::API::Router;
require Plugins::SlimPing::Utils::Errors;

my $log   = Plugins::SlimPing::Core::Logging->getLogger();
my $prefs = Plugins::SlimPing::Core::Logging->getPrefs();

sub registerHandlers {
    my $class = shift;
    Plugins::SlimPing::API::Router->registerHandler('star',      \&star);
    Plugins::SlimPing::API::Router->registerHandler('unstar',    \&unstar);
    Plugins::SlimPing::API::Router->registerHandler('setRating', \&setRating);

}

# --- Handlers -----------------------------------------------------------------

sub star {
    my ($args) = @_;
    my $p    = $args->{params};
    my $err  = Plugins::SlimPing::Utils::Errors->requireOneOf($p, qw(id albumId artistId));
    return $err if $err;
    my $user = $args->{user}{username};
    Plugins::SlimPing::Core::Annotations->modifyStars($user, $p, 1);
    return {};
}

sub unstar {
    my ($args) = @_;
    my $p    = $args->{params};
    my $err  = Plugins::SlimPing::Utils::Errors->requireOneOf($p, qw(id albumId artistId));
    return $err if $err;
    my $user = $args->{user}{username};
    Plugins::SlimPing::Core::Annotations->modifyStars($user, $p, 0);
    return {};
}

sub setRating {
    my ($args) = @_;
    my $p    = $args->{params};
    my $user = $args->{user}{username};
    my $id   = $p->{id}
        or return Plugins::SlimPing::Utils::Errors->missingParam('id');
    my $rating = $p->{rating};
    return Plugins::SlimPing::Utils::Errors->missingParam('rating')
        unless defined $rating;
    $rating = int($rating);
    $rating = 0 if $rating < 0;
    $rating = 5 if $rating > 5;

    Plugins::SlimPing::Core::Annotations->setUserRating($user, $id, $rating);
    return {};
}

1;
