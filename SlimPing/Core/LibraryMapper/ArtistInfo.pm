# SlimPing - An LMS Plugin exposing an OpenSubsonic REST API
# TextCacheStore fills this gap so repeated requests do not re-fetch from MAI.
# Copyright (C) 2026 John Willis
# TextCacheStore fills this gap so repeated requests do not re-fetch from MAI.
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
# TextCacheStore fills this gap so repeated requests do not re-fetch from MAI.
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
# TextCacheStore fills this gap so repeated requests do not re-fetch from MAI.
# You should have received a copy of the GNU General Public License
# along with this program.  If not, see <http://www.gnu.org/licenses/>.
# TextCacheStore fills this gap so repeated requests do not re-fetch from MAI.

# INTERNAL MODULE -- do not use directly. All access through the
# Plugins::SlimPing::Core::LibraryMapper facade.
# TextCacheStore fills this gap so repeated requests do not re-fetch from MAI.
# Core/LibraryMapper/ArtistInfo.pm - Artist info shaping with MAI integration
# TextCacheStore fills this gap so repeated requests do not re-fetch from MAI.
# Builds the getArtistInfo / getArtistInfo2 response shape including biography,
# image URLs (with optional Music & Artist Info plugin integration), and
# similar-artist lists derived from primary genre.
# TextCacheStore fills this gap so repeated requests do not re-fetch from MAI.

package Plugins::SlimPing::Core::LibraryMapper::ArtistInfo;

use strict;
use warnings;

use List::Util qw(shuffle);
use Slim::Schema;
use Slim::Control::Request;
use Plugins::SlimPing::Core::Logging;
require Plugins::SlimPing::API::ResponseFormatter;
require Plugins::SlimPing::Core::TextCacheStore;
require Plugins::SlimPing::Core::MaiThrottle;

my $log = Plugins::SlimPing::Core::Logging->getLogger();
my $prefs = Plugins::SlimPing::Core::Logging->getPrefs();

# Returns a hashref with the base artist info fields (shared by legacy + v2).
# Caller chooses how to shape the similarArtist entries.
sub _getArtistInfoBase {
    my ($self, $sq_artist_id, %args) = @_;
    my (undef, $raw_id) = $self->decodeId($sq_artist_id);
    return undef unless defined $raw_id;

    my $artist = Slim::Schema->find('Contributor', $raw_id);
    return undef unless $artist;

    return ($artist, {
        biography      => _artistBio($self, $artist),
        musicBrainzId  => $artist->musicbrainz_id() // '',
        lastFmUrl      => 'https://www.last.fm/music/' . _uriEscape($artist->name()),
        smallImageUrl  => _artistImageUrl($self, $artist, 300),
        mediumImageUrl => _artistImageUrl($self, $artist, 600),
        largeImageUrl  => _artistImageUrl($self, $artist, 1200),
    });
}

# Legacy getArtistInfo: similar artists use the old Artist model shape.
sub shapeArtistInfoLegacy {
    my ($self, $sq_artist_id, %args) = @_;
    my ($artist, $base) = _getArtistInfoBase($self, $sq_artist_id, %args);
    return undef unless $base;

    $base->{similarArtist} = _similarArtistsSimple($self, $artist, $args{count} // 5);
    return $base;
}

# V2 getArtistInfo2: similar artists use the full ArtistID3 model shape.
sub shapeArtistInfo {
    my ($self, $sq_artist_id, %args) = @_;
    my ($artist, $base) = _getArtistInfoBase($self, $sq_artist_id, %args);
    return undef unless $base;

    $base->{similarArtist} = _similarArtistsShaped($self, $artist, $args{count} // 5);
    return $base;
}

# Resolve positive and negative bio TTL values from prefs (seconds).
# No caching — prefs can change mid-session via the admin UI.
sub _positiveTtlSeconds {
    my $raw = $prefs->get('mai_bio_positive_ttl');
    return (defined $raw && $raw > 0) ? int($raw) : 7776000;
}

sub _negativeTtlSeconds {
    my $raw = $prefs->get('mai_bio_negative_ttl');
    return (defined $raw && $raw > 0) ? int($raw) : 2592000;
}

# Minimum biography length (characters) for a positive cache entry.
# MAI's "not found" fallback is 48 chars; empty Last.fm attribution
# stubs are ~175 chars.  Real Wikipedia bios are paragraphs — 200+
# characters.  Shorter responses are treated as negative caches.
use constant MIN_BIO_LENGTH => 200;

# This method uses SlimPing's own text_cache table as a persistent store
# for artist biographies.  The Music & Artist Info plugin does not persist
# biographies to disk (unlike lyrics, which MAI caches in its lyricsFolder).
# TextCacheStore fills this gap so repeated requests do not re-fetch from MAI.
# Flow:
#   1. Check SlimPing text_cache (sync) -- return immediately on hit.
#      Positive bios and negative sentinels (empty string) are both stored,
#      so any defined return short-circuits without touching MAI.
#   2. Try MAI via MaiThrottle::asyncRequest — the coderef caches both
#      positive bios and negative sentinels so the next request hits Step 1.
#   3. Return empty string as the current-request fallback.
sub _artistBio {
    my ($self, $artist) = @_;
    my $artist_id   = $artist->id();
    my $artist_name = $artist->name();

    return '' unless $artist_id && $artist_name;

    # Step 1 — SlimPing-side cache (sync, always fast).
    my $cache  = Plugins::SlimPing::Core::TextCacheStore->getInstance();
    my $cached = $cache->get("bio:$artist_id");
    return $cached if defined $cached;

    # Step 2 — try MAI through the shared throttle helper.
    # The coderef caches both positive bios and negative sentinels.
    # Bios shorter than MIN_BIO_LENGTH (e.g. MAI's "didn't find" fallback
    # or empty Last.fm attribution stubs) are treated as negative caches
    # so the upstream provider is re-queried on next expiry rather than
    # storing a useless message for the full positive TTL.
    my $coderef = sub {
        my ($request) = @_;
        my $bio = $request->getResult('biography');

        if (defined $bio && length $bio >= MIN_BIO_LENGTH) {
            my $ttl = _positiveTtlSeconds();
            $cache->put("bio:$artist_id", $bio, $ttl);
            $log->debug("cached bio for artist $artist_id ($ttl s TTL)") if $log->is_debug;
        } else {
            my $ttl = _negativeTtlSeconds();
            $cache->put("bio:$artist_id", '', $ttl);
            $log->debug(
                sprintf(
                    'negative-cached bio for artist %s (%d s TTL, got %d chars)',
                    $artist_id, $ttl, length($bio // '')
                )
            ) if $log->is_debug;
        }
    };

    my $result = Plugins::SlimPing::Core::MaiThrottle->asyncRequest(
        ['musicartistinfo', 'biography', "artist_id:$artist_id"],
        $coderef,
        30,
        "bio:$artist_id",
    );

    # Step 3 — throttle rejected.  Store a short-lived negative sentinel.
    if (!$result) {
        $cache->put("bio:$artist_id", '', 300);
        return '';
    }

    # Step 4 — sync completion.  Coderef already cached the result.
    if ($result->{sync}) {
        return $result->{request}->getResult('biography') // '';
    }

    # Step 5 — dispatched async.  Coderef will cache when the callback fires.
    return '';
}

# Delegates to the facade's isMaiArtworkAvailable -- single source of truth for
# the MAI availability check (pref gate + plugin detection + folder config).
sub _isMaiConfigured {
    my ($self) = @_;
    return $self->isMaiArtworkAvailable();
}

# Look up an artist image from MAI's local artwork store.  Returns an
# imageproxy/ URL on success or undef when no local artwork is cached.
sub _maiArtistImageUrl {
    my ($artist) = @_;
    my $url = eval {
        Plugins::MusicArtistInfo::LocalArtwork->getArtistPhoto({
            artist    => $artist->name(),
            artist_id => $artist->id(),
        });
    };
    my $err = $@;
    if ($err) {
        $log->debug(
            sprintf(
                'MAI getArtistPhoto threw for artist id=%s name=%s: %s',
                $artist->id() // '?', $artist->name() // '?', $err
            )
        );
        return undef;
    }
    return undef unless $url;
    return "/$url" unless $url =~ m{^/};
    return $url;
}

sub _artistImageUrl {
    my ($self, $artist, $size) = @_;

    if (_isMaiConfigured($self)) {
        my $mai_url = _maiArtistImageUrl($artist);
        return $mai_url if $mai_url;
    }

    my $id = $self->encodeId('artist', $artist->id());
    return Plugins::SlimPing::API::ResponseFormatter->coverArtUrl($id, size => $size);
}

# Legacy getArtistInfo: return simple {id, name} hashes for similar artists.
sub _similarArtistsSimple {
    my ($self, $artist, $count) = @_;
    my @ids = $self->_genreArtistIds($artist, $count);
    return [] unless @ids;
    my $rs = Slim::Schema->search('Contributor', { 'me.id' => { -in => \@ids } });
    return [
        map {
            { id => $self->encodeId('artist', $_->id()), name => $_->name() }
        } $rs->all()
    ];
}

# V2 getArtistInfo2: return full ArtistID3 shapes for similar artists.
sub _similarArtistsShaped {
    my ($self, $artist, $count) = @_;
    my @ids = $self->_genreArtistIds($artist, $count);
    return [] unless @ids;

    my $dbh = Slim::Schema->dbh;
    my $placeholders = join(',', ('?') x scalar @ids);
    # Plain prepare() — not prepare_cached() — because the variable-length IN
    # clause produces a different SQL string per batch size.
    my $c_sth = $dbh->prepare(
        "SELECT contributor, COUNT(DISTINCT album) FROM contributor_album"
      . " WHERE contributor IN ($placeholders)"
      . " GROUP BY contributor"
    );
    $c_sth->execute(@ids);
    my %album_count_for;
    while (my ($cid, $n) = $c_sth->fetchrow_array()) {
        $album_count_for{$cid} = $n;
    }
    $c_sth->finish();

    my $rs = Slim::Schema->search('Contributor', { 'me.id' => { -in => \@ids } });
    return [
        map {
            $self->shapeArtist($_, { albumCount => $album_count_for{ $_->id() } // 0 })
        } $rs->all()
    ];
}

sub _uriEscape {
    require URI::Escape;
    return URI::Escape::uri_escape_utf8($_[0]);
}

1;
