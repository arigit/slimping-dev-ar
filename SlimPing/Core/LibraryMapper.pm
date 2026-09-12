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
# Core/LibraryMapper.pm - Sole gateway to Slim::Schema for SlimPing
#
# Virtualises all LMS data into Subsonic data shapes.  No handler module may
# touch Slim::Schema directly -- all access must go through this module.
#
# Key responsibilities:
#   - Virtualised ID scheme: all LMS IDs exposed as opaque sq_<type>_<raw_id>
#     tokens; no raw database IDs or filesystem paths ever appear in API output
#   - Shaped data accessors for artists, albums, tracks, genres, and folders
#   - Query cache with 300 s TTL, evicted on LMS rescan; slimping.folders uses FOLDERS_CACHE_TTL
#   - resolveFilePath() for internal Stream/Jukebox handler internal use ONLY
#   - resolveTrackDbUrl() returns db:track.id=<id> URLs for LMS menu items
#

package Plugins::SlimPing::Core::LibraryMapper;

use strict;
use warnings;

use Slim::Schema;
use Slim::Utils::Cache;
use Time::HiRes qw(time);
use Plugins::SlimPing::Core::Logging;

# Sub-modules of the facade.  Each is loaded at compile time so the public
# method surface is fully populated by the time any handler dispatches.
require Plugins::SlimPing::Core::LibraryMapper::Shapes;
require Plugins::SlimPing::Core::LibraryMapper::Queries;
require Plugins::SlimPing::Core::LibraryMapper::Streaming;
require Plugins::SlimPing::Core::LibraryMapper::ArtistInfo;
require Plugins::SlimPing::Core::LibraryMapper::RawQueries;

my $log   = Plugins::SlimPing::Core::Logging->getLogger();
my $prefs = Plugins::SlimPing::Core::Logging->getPrefs();
my $_instance;

# Current request's authenticated username.  Set by the Router after auth so
# shapeTrack/shapeAlbum/shapeArtist can annotate responses with the calling
# user's stars and ratings without every handler passing username explicitly.
my $_request_username;

# Current request's base URL (scheme + host).  Set by the Router after auth so
# getInternetRadioStations can construct FQDN stream URLs without every handler
# passing the request context explicitly.
my $_request_base_url;

# Whether the Music & Artist Info plugin was detected at startup.
# Set once by Plugin.pm -- plugins cannot be installed or removed mid-session.
my $_mai_available;

sub setRequestUser {
    my ($class, $username) = @_;
    $_request_username = $username;
}

sub setRequestBaseUrl {
    my ($class, $base_url) = @_;
    $_request_base_url = $base_url;
}

sub setMaiAvailable {
    my ($class, $available) = @_;
    $_mai_available = $available;
}

# Accessors used by sub-modules to read facade-owned request-context state.
# Sub-modules have their own package and cannot see the lexical `my` vars above.
sub _requestUsername { return $_request_username; }
sub _requestBaseUrl  { return $_request_base_url; }
sub _maiAvailable    { return $_mai_available; }
sub maiAvailable     { return $_mai_available; }  # public accessor for non-sub-module callers

# Strip surrounding whitespace and quotes from a search query string.
# Some clients (e.g. Symfonium) quote-wrap empty search terms; an empty-or-blank
# query after cleaning is treated as match-all by Queries.pm.
sub cleanSearchQuery {
    my ( $class, $query ) = @_;
    return $query unless defined $query;
    $query =~ s/^[\s"']+//;
    $query =~ s/[\s"']+$//;
    return $query;
}

# Returns the icon URL for a radio station, or undef.  Implementation in
# LibraryMapper::Streaming, which owns the radio URL/icon caches.
sub getRadioIconUrl {
    my $self = ref $_[0] ? shift : shift->getInstance();
    return Plugins::SlimPing::Core::LibraryMapper::Streaming::getRadioIconUrl($self, @_);
}

sub getRadioName {
    my $self = ref $_[0] ? shift : shift->getInstance();
    return Plugins::SlimPing::Core::LibraryMapper::Streaming::getRadioName($self, @_);
}

# Prefix map: internal type name => sq_ prefix character sequence
my %_prefix = (
    track    => 'tr',
    album    => 'al',
    artist   => 'ar',
    folder   => 'f',
    playlist => 'pl',
    genre    => 'g',
    radio            => 'rd',
    dynamic_playlist => 'dpl',
);

my %_prefix_reverse = reverse %_prefix;

# Cache entries expire after 300 seconds.  Also evicted when LMS fires a
# 'rescan done' event (subscribed in Plugin.pm) via cache-generation bump.
use constant CACHE_TTL => 300;

# The folder list is cached with a matching 300 s TTL because virtual libraries
# can be created or modified without triggering a rescan.  The TTL gives a
# self-healing fallback if invalidateFolderCache is ever not called.
use constant FOLDERS_CACHE_TTL => 300;

sub getInstance {
    my $class = shift;
    $_instance //= bless {
        _cache     => Slim::Utils::Cache->new(),
        _cache_gen => 0,
    }, $class;
    return $_instance;
}

# --- ID scheme ----------------------------------------------------------------

sub encodeId {
    my ($class_or_self, $type, $raw_id) = @_;
    my $pfx = $_prefix{$type};
    unless ($pfx) {
        $log->error("SlimPing: encodeId called with unknown type '$type'");
        return undef;
    }
    # URL-based tracks (internet radio stations in playlists) produce a
    # URL-derived hash that Perl sees as a signed 64-bit integer — the
    # high bit makes it negative.  abs() normalises it without breaking
    # uniqueness: a unique negative maps to a unique positive.
    my $normalised = ( $raw_id =~ /^-\d+$/ ) ? abs($raw_id) : $raw_id;
    return "sq_${pfx}_${normalised}";
}

sub decodeId {
    my ($class_or_self, $sq_id) = @_;
    return (undef, undef) unless defined $sq_id;
    # Raw ID is \w+ to accommodate non-numeric IDs (e.g. radio station identifiers
    # in future phases) without breaking the current numeric database-ID use case.
    my ($pfx, $raw) = ($sq_id =~ /^sq_([a-z]+)_(\w+)$/);
    return (undef, undef) unless defined $pfx;
    my $type = $_prefix_reverse{$pfx};
    return (undef, undef) unless defined $type;
    # Coerce to number only when the raw value is purely numeric (DB row IDs).
    my $id = ($raw =~ /^\d+$/) ? $raw + 0 : $raw;
    return ($type, $id);
}

# Decode a musicFolderId HTTP parameter into a raw LMS library ID, applying
# exposure-mode checks.  Returns undef for "All Music" (folder 0), missing,
# invalid, or unexposed folder IDs -- callers treat undef as no filter.
#
# Accepts both integer IDs (the canonical format per the OpenSubsonic spec) and
# legacy sq_f_* strings so clients that cached the old format continue to work.
sub decodeLibraryParam {
    my ($class_or_self, $params) = @_;
    my $folder_id = $params->{musicFolderId};
    return undef unless defined $folder_id;

    my $raw;

    # Try the sq_f_* wire format first (legacy clients).
    my (undef, $decoded) = $class_or_self->decodeId($folder_id);
    if (defined $decoded) {
        $raw = $decoded;
    }
    elsif ( $folder_id =~ /^\d+$/ ) {
        # Plain integer — the canonical format.  0 is "All Music".
        my $int_id = 0 + $folder_id;
        return undef if $int_id == 0;

        # Reverse-map the integer to a virtual-library canonical ID.
        require Slim::Music::VirtualLibraries;
        my $libs = Slim::Music::VirtualLibraries->getLibraries() || {};
        for my $lib_key ( keys %$libs ) {
            my $lib = $libs->{$lib_key};
            if ( $class_or_self->folderCanonicalToInt( $lib->{id} ) == $int_id ) {
                $raw = $lib->{id};
                last;
            }
        }
        return undef unless defined $raw;
    }
    else {
        return undef;
    }

    return undef unless $raw && $raw ne '0';

    my $mode = $prefs->get('exposed_libraries_mode');
    return undef if $mode eq 'default_only';
    if ($mode eq 'selected') {
        my $ids     = $prefs->get('exposed_library_ids');
        my %allowed = map { $_ => 1 } @{ ref $ids eq 'ARRAY' ? $ids : [] };
        return undef unless $allowed{$raw};
    }

    # $raw is the stable string ID (e.g. "audioBooks"); convert to the hashed
    # key LMS uses in library_track.library / library_album.library columns.
    require Slim::Music::VirtualLibraries;
    return Slim::Music::VirtualLibraries->getRealId($raw) || undef;
}

# Convert a virtual-library canonical string ID into a stable positive integer
# suitable for use as a MusicFolder.id in the OpenSubsonic response.  Uses a
# djb2 hash clamped to 31 bits — not cryptographically strong, but good enough
# to avoid collisions across the handful of libraries a real-world LMS instance
# will ever have.  Zero is reserved for "All Music".
sub folderCanonicalToInt {
    my ($class_or_self, $canonical_id) = @_;
    my $hash = 5381;
    $hash = ( ( $hash << 5 ) + $hash + ord($_) ) & 0x7FFFFFFF for split //, $canonical_id;
    return $hash || 1;    # ensure non-zero
}

# --- Music folders (LMS virtual libraries) ------------------------------------

sub getMusicFolders {
    my $self = ref $_[0] ? shift : shift->getInstance();
    return Plugins::SlimPing::Core::LibraryMapper::Queries::getMusicFolders($self, @_);
}

# --- Artists ------------------------------------------------------------------

sub getArtists {
    my $self = ref $_[0] ? shift : shift->getInstance();
    return Plugins::SlimPing::Core::LibraryMapper::RawQueries::getArtists($self, @_);
}

sub getArtistById {
    my $self = ref $_[0] ? shift : shift->getInstance();
    return Plugins::SlimPing::Core::LibraryMapper::Queries::getArtistById($self, @_);
}

sub getArtistsByIds {
    my $self = ref $_[0] ? shift : shift->getInstance();
    return Plugins::SlimPing::Core::LibraryMapper::Queries::getArtistsByIds($self, @_);
}

sub enrichArtistAlbumCounts {
    my $self = ref $_[0] ? shift : shift->getInstance();
    return Plugins::SlimPing::Core::LibraryMapper::Queries::enrichArtistAlbumCounts($self, @_);
}

sub getAlbumsByArtist {
    my $self = ref $_[0] ? shift : shift->getInstance();
    return Plugins::SlimPing::Core::LibraryMapper::Queries::getAlbumsByArtist($self, @_);
}

# --- Albums -------------------------------------------------------------------

sub getAlbumById {
    my $self = ref $_[0] ? shift : shift->getInstance();
    return Plugins::SlimPing::Core::LibraryMapper::Queries::getAlbumById($self, @_);
}

sub getAlbumsByIds {
    my $self = ref $_[0] ? shift : shift->getInstance();
    return Plugins::SlimPing::Core::LibraryMapper::Queries::getAlbumsByIds($self, @_);
}

sub enrichAlbumAggregates {
    my $self = ref $_[0] ? shift : shift->getInstance();
    return Plugins::SlimPing::Core::LibraryMapper::Queries::enrichAlbumAggregates($self, @_);
}

sub getTracksByAlbum {
    my $self = ref $_[0] ? shift : shift->getInstance();
    return Plugins::SlimPing::Core::LibraryMapper::Queries::getTracksByAlbum($self, @_);
}

sub getAlbumList {
    my $self = ref $_[0] ? shift : shift->getInstance();
    return Plugins::SlimPing::Core::LibraryMapper::RawQueries::getAlbumList($self, @_);
}

sub getRandomSongIds {
    my $self = ref $_[0] ? shift : shift->getInstance();
    return Plugins::SlimPing::Core::LibraryMapper::RawQueries::getRandomSongIds($self, @_);
}

# --- Tracks -------------------------------------------------------------------

sub getTrackById {
    my $self = ref $_[0] ? shift : shift->getInstance();
    return Plugins::SlimPing::Core::LibraryMapper::Queries::getTrackById($self, @_);
}

sub getTracksByIds {
    my $self = ref $_[0] ? shift : shift->getInstance();
    return Plugins::SlimPing::Core::LibraryMapper::Queries::getTracksByIds($self, @_);
}

sub resolveFilePath {
    my $self = ref $_[0] ? shift : shift->getInstance();
    return Plugins::SlimPing::Core::LibraryMapper::Streaming::resolveFilePath($self, @_);
}

sub resolveStreamUrl {
    my $self = ref $_[0] ? shift : shift->getInstance();
    return Plugins::SlimPing::Core::LibraryMapper::Streaming::resolveStreamUrl($self, @_);
}

sub getCueStartTime {
    my $self = ref $_[0] ? shift : shift->getInstance();
    return Plugins::SlimPing::Core::LibraryMapper::Streaming::getCueStartTime($self, @_);
}

sub resolveCoverArtUrl {
    my $self = ref $_[0] ? shift : shift->getInstance();
    return Plugins::SlimPing::Core::LibraryMapper::Streaming::resolveCoverArtUrl($self, @_);
}

sub resolveTrackDbUrl {
    my $self = ref $_[0] ? shift : shift->getInstance();
    return Plugins::SlimPing::Core::LibraryMapper::Streaming::resolveTrackDbUrl($self, @_);
}

sub resolveAlbumDbUrl {
    my $self = ref $_[0] ? shift : shift->getInstance();
    return Plugins::SlimPing::Core::LibraryMapper::Streaming::resolveAlbumDbUrl($self, @_);
}

sub resolveArtistDbUrl {
    my $self = ref $_[0] ? shift : shift->getInstance();
    return Plugins::SlimPing::Core::LibraryMapper::Streaming::resolveArtistDbUrl($self, @_);
}

sub getTracksByUrls {
    my $self = ref $_[0] ? shift : shift->getInstance();
    return Plugins::SlimPing::Core::LibraryMapper::Queries::getTracksByUrls($self, @_);
}

sub idsInLibrary {
    my $self = ref $_[0] ? shift : shift->getInstance();
    return Plugins::SlimPing::Core::LibraryMapper::Queries::idsInLibrary($self, @_);
}

sub getAlbumObject {
    my $self = ref $_[0] ? shift : shift->getInstance();
    return Plugins::SlimPing::Core::LibraryMapper::Queries::getAlbumObject($self, @_);
}

# --- Artist artwork (MAI integration) -----------------------------------------

# Returns true when the Music & Artist Info plugin is detected AND the
# feature_mai_integration pref is not explicitly set to 'off'.
sub isMaiArtworkAvailable {
    my $self = ref $_[0] ? shift : shift->getInstance();
    my $mode = $prefs->get('feature_mai_integration');
    return 0 if defined $mode && ($mode eq 'off' || $mode eq '0');
    return 0 unless $_mai_available;
    require Slim::Utils::Prefs;
    my $mai_prefs = Slim::Utils::Prefs::preferences('plugin.musicartistinfo');
    return 0 unless $mai_prefs->get('artistImageFolder');
    return 1;
}

# Resolve a local filesystem path for an artist's MAI artwork image.
# Returns a path string on success, undef when no local artwork exists.
sub getArtistArtworkPath {
    my ($self, $sq_artist_id) = @_;
    my (undef, $raw_id) = $self->decodeId($sq_artist_id);
    return undef unless defined $raw_id;
    return undef unless $self->isMaiArtworkAvailable();
    my $artist = Slim::Schema->find('Contributor', $raw_id);
    return undef unless $artist;
    my $path = eval {
        Plugins::MusicArtistInfo::LocalArtwork->getArtistPhoto({
            artist    => $artist->name(),
            artist_id => $artist->id(),
            rawUrl    => 1,
        });
    };
    my $err = $@;
    if ($err) {
        $log->debug(
            sprintf(
                'MAI getArtistPhoto (rawUrl) threw for artist id=%s name=%s: %s',
                $artist->id() // '?', $artist->name() // '?', $err
            )
        );
        return undef;
    }
    return undef unless $path;
    return $path;
}

# --- Genres -------------------------------------------------------------------

sub getGenres {
    my $self = ref $_[0] ? shift : shift->getInstance();
    return Plugins::SlimPing::Core::LibraryMapper::RawQueries::getGenres($self, @_);
}

sub getTracksByGenre {
    my $self = ref $_[0] ? shift : shift->getInstance();
    return Plugins::SlimPing::Core::LibraryMapper::Queries::getTracksByGenre($self, @_);
}

# --- Top songs ----------------------------------------------------------------

sub getTopSongs {
    my $self = ref $_[0] ? shift : shift->getInstance();
    return Plugins::SlimPing::Core::LibraryMapper::Queries::getTopSongs($self, @_);
}

# --- Similar songs ------------------------------------------------------------

sub getSimilarSongs {
    my $self = ref $_[0] ? shift : shift->getInstance();
    require Plugins::SlimPing::Core::LibraryMapper::RelatedSongs;
    return Plugins::SlimPing::Core::LibraryMapper::RelatedSongs::getSimilarSongs($self, @_);
}

# Delegates to getSimilarSongs — identical implementation, separate API endpoint.
sub getSimilarSongs2 {
    return getSimilarSongs(@_);
}

# --- Search -------------------------------------------------------------------

sub search {
    my $self = ref $_[0] ? shift : shift->getInstance();
    return Plugins::SlimPing::Core::LibraryMapper::RawQueries::search($self, @_);
}

# --- Library membership helpers -----------------------------------------------

# Forwarder retained on the facade because Handlers/Lists.pm:290 calls it
# directly as $mapper_obj->_batchGenreHint(...).  Implementation in Queries.pm.
sub _batchGenreHint {
    my $self = ref $_[0] ? shift : shift->getInstance();
    return Plugins::SlimPing::Core::LibraryMapper::Queries::_batchGenreHint($self, @_);
}

# Batch-resolve track genres for an array of Track objects.  Replaces the
# duplicated genre_track JOIN idiom that previously lived in every handler
# that needed shapeTrack-ready genre hints.  Implementation in Queries.pm.
sub batchFetchTrackGenres {
    my $self = ref $_[0] ? shift : shift->getInstance();
    return Plugins::SlimPing::Core::LibraryMapper::Queries::batchFetchTrackGenres($self, @_);
}

# Batch-resolve all genres for raw track IDs, returning an arrayref per track
# (capped by genre_count_per_entity pref).  Unlike batchFetchTrackGenres which
# returns a single genre per track, this returns all genres for multi-genre
# aware callers.  Implementation in Queries.pm.
sub batchFetchAllTrackGenres {
    my $self = ref $_[0] ? shift : shift->getInstance();
    return Plugins::SlimPing::Core::LibraryMapper::Queries::batchFetchAllTrackGenres($self, @_);
}

# Batch-resolve track contributors (via contributor_track) and composer names for
# an array of raw track IDs.  Returns two hashrefs keyed by track ID.  Accepts an
# optional role filter hashref.  Implementation in Queries.pm.
sub batchFetchTrackContributors {
    my $self = ref $_[0] ? shift : shift->getInstance();
    return Plugins::SlimPing::Core::LibraryMapper::Queries::batchFetchTrackContributors($self, @_);
}

# Batch-resolve contributor roles for raw contributor IDs (contributor_track
# and contributor_album union).  Returns { artist_id => [lowercase_role_name, ...] }.
# Implementation in Queries.pm.
sub batchFetchArtistRoles {
    my $self = ref $_[0] ? shift : shift->getInstance();
    return Plugins::SlimPing::Core::LibraryMapper::Queries::batchFetchArtistRoles($self, @_);
}

# Batch-resolve album-level genres for raw album IDs.  Returns a hashref of
# album_id => [genre_name, ...] capped by genre_count_per_entity pref.
# Implementation in Queries.pm.
sub batchFetchAlbumGenres {
    my $self = ref $_[0] ? shift : shift->getInstance();
    return Plugins::SlimPing::Core::LibraryMapper::Queries::batchFetchAlbumGenres($self, @_);
}

# Batch-resolve album-level artists/album-artists for raw album IDs.  Returns a
# hashref of album_id => [{id, name}, ...].  Implementation in Queries.pm.
sub batchFetchAlbumArtists {
    my $self = ref $_[0] ? shift : shift->getInstance();
    return Plugins::SlimPing::Core::LibraryMapper::Queries::batchFetchAlbumArtists($self, @_);
}

# Batch-resolve album data (id, title, contributor_id, contributor_name) for an
# array of Track objects via raw SQL.  Returns a hashref of { album_id => { ...} }
# lightweight hashrefs -- no DBIx objects are created, so nothing enters the
# identity map.  Used by shapePlaylist where tracks come through the PlaylistTrack
# resultset, which cannot carry Track-level prefetch.
# Implementation in Queries.pm.
sub batchFetchAlbumDataForTracks {
    my $self = ref $_[0] ? shift : shift->getInstance();
    return Plugins::SlimPing::Core::LibraryMapper::Queries::batchFetchAlbumDataForTracks($self, @_);
}

# --- Cache helpers -------------------------------------------------------------

# _cached($self, $cache_key, $compute_fn[, $ttl]) -> $result
#
# Cache-or-compute pattern.  The key is suffixed with .gN where N is the current
# cache generation; a rescan bumps the generation via invalidateCache, instantly
# invalidating all cached entries without needing to enumerate per-library variants
# or pagination combinations.
#
# $ttl defaults to CACHE_TTL (300 s -- also invalidated on rescan).
sub _cached {
    my ($self, $cache_key, $compute_fn, $ttl) = @_;
    $self = $self->getInstance() unless ref $self;
    $ttl //= CACHE_TTL;

    my $gen_key = "$cache_key.g$self->{_cache_gen}";
    my $cached = $self->{_cache}->get($gen_key);
    return $cached if $cached;

    my $result = $compute_fn->();
    $self->{_cache}->set($gen_key, $result, $ttl);
    return $result;
}

# --- Cache invalidation -------------------------------------------------------

sub invalidateCache {
    my $self = ref $_[0] ? $_[0] : $_[0]->getInstance();
    $self->{_cache_gen}++;
    $self->{_cache}->remove('slimping.folders');
    $log->info(sprintf('SlimPing: cache generation bumped to %d', $self->{_cache_gen}));
}

# Clear the folder cache entry (called when exposure prefs change).
sub invalidateFolderCache {
    my $self = ref $_[0] ? $_[0] : $_[0]->getInstance();
    $self->{_cache}->remove('slimping.folders');
    $log->info('SlimPing: folder cache invalidated');
}


# --- Data shape methods -------------------------------------------------------
#
# Forwarders to Plugins::SlimPing::Core::LibraryMapper::Shapes.  See that
# module for implementation; the forwarders preserve the public method
# surface so handlers continue to call $mapper->shapeArtist(...) etc.

sub shapeArtist {
    my $self = ref $_[0] ? shift : shift->getInstance();
    return Plugins::SlimPing::Core::LibraryMapper::Shapes::shapeArtist($self, @_);
}

sub shapeArtistLegacy {
    my $self = ref $_[0] ? shift : shift->getInstance();
    return Plugins::SlimPing::Core::LibraryMapper::Shapes::shapeArtistLegacy($self, @_);
}

sub shapeAlbum {
    my $self = ref $_[0] ? shift : shift->getInstance();
    return Plugins::SlimPing::Core::LibraryMapper::Shapes::shapeAlbum($self, @_);
}

sub shapePlaylist {
    my $self = ref $_[0] ? shift : shift->getInstance();
    return Plugins::SlimPing::Core::LibraryMapper::Shapes::shapePlaylist($self, @_);
}

sub shapeTrack {
    my $self = ref $_[0] ? shift : shift->getInstance();
    return Plugins::SlimPing::Core::LibraryMapper::Shapes::shapeTrack($self, @_);
}

sub _mimeType {
    my $self = ref $_[0] ? shift : shift;
    return Plugins::SlimPing::Core::LibraryMapper::Shapes::_mimeType($self, @_);
}

sub isLosslessFormat {
    return Plugins::SlimPing::Core::LibraryMapper::Shapes::isLosslessFormat(@_);
}

sub isDsdFormat {
    return Plugins::SlimPing::Core::LibraryMapper::Shapes::isDsdFormat(@_);
}

sub outputMime {
    return Plugins::SlimPing::Core::LibraryMapper::Shapes::outputMime();
}

sub shapeArtistInfoLegacy {
    my $self = ref $_[0] ? shift : shift->getInstance();
    return Plugins::SlimPing::Core::LibraryMapper::ArtistInfo::shapeArtistInfoLegacy($self, @_);
}

sub shapeArtistInfo {
    my $self = ref $_[0] ? shift : shift->getInstance();
    return Plugins::SlimPing::Core::LibraryMapper::ArtistInfo::shapeArtistInfo($self, @_);
}

# --- Internet Radio ------------------------------------------------------------

sub getInternetRadioStations {
    my $self = ref $_[0] ? shift : shift->getInstance();
    return Plugins::SlimPing::Core::LibraryMapper::Streaming::getInternetRadioStations($self, @_);
}

# --- Time helper --------------------------------------------------------------

# Convert a Unix epoch to ISO 8601 (UTC).  Returns undef for undef/negative
# input so that callers that pass NULL timestamp columns get a clean undef.
# Accepts 0 (epoch-zero) as a valid sentinel for "unknown timestamp".
sub _iso8601 {
    my ($epoch) = @_;
    return undef unless defined $epoch && $epoch >= 0;
    my @t = gmtime($epoch);
    return sprintf('%04d-%02d-%02dT%02d:%02d:%02dZ',
        $t[5] + 1900, $t[4] + 1, $t[3], $t[2], $t[1], $t[0]);
}

# --- Duplicate consolidations (promoted from sub-modules) ----------------------

# Find the most common genre ID for an artist's tracks via raw SQL.
# Promoted from ArtistInfo.pm and RelatedSongs.pm duplicates.
sub _artistPrimaryGenreId {
    my ($self, $artist) = @_;
    $self = $self->getInstance() unless ref $self;
    my $dbh = Slim::Schema->dbh;
    my $sth = $dbh->prepare_cached(
        'SELECT gt.genre FROM contributor_track ct'
      . ' JOIN genre_track gt ON gt.track = ct.track'
      . ' WHERE ct.contributor = ? AND ct.role = 1'
      . ' GROUP BY gt.genre ORDER BY COUNT(*) DESC LIMIT 1'
    );
    $sth->execute($artist->id());
    my ($genre_id) = $sth->fetchrow_array();
    $sth->finish();
    return $genre_id;
}

# Returns up to $count contributor IDs for artists sharing the seed artist's
# primary genre, excluding the seed artist, in random order.  Empty list when
# no primary genre is found.
# Merged from _candidateArtistIds (ArtistInfo.pm) and _genreArtistIds (RelatedSongs.pm).
sub _genreArtistIds {
    my ($self, $artist, $count) = @_;
    $self = $self->getInstance() unless ref $self;

    my $genre_id = $self->_artistPrimaryGenreId($artist);
    return () unless $genre_id;

    my $dbh = Slim::Schema->dbh;
    my $sth = $dbh->prepare_cached(
        'SELECT DISTINCT ct.contributor FROM contributor_track ct'
      . ' JOIN genre_track gt ON gt.track = ct.track'
      . ' WHERE gt.genre = ? AND ct.contributor != ?'
    );
    $sth->execute($genre_id, $artist->id());
    my @ids = map { $_->[0] } @{ $sth->fetchall_arrayref() };
    $sth->finish();
    return () unless @ids;

    require List::Util;
    my @picked = List::Util::shuffle(@ids);
    splice(@picked, $count) if @picked > $count;
    return @picked;
}

# Batch-fetch star and rating annotations for an array of raw-ID rows.
# Returns ($starred_batch, $rating_batch) hashrefs keyed by encoded ID.
# $type is the encode prefix type ('artist', 'album', 'track').
# Used by Queries.pm and RawQueries.pm sub-modules.
sub _batchFetchAnnotations {
    my ($self, $type, $rows) = @_;
    $self = $self->getInstance() unless ref $self;

    my $starred = {};
    my $ratings = {};

    my $username = $_request_username;
    return ($starred, $ratings) unless $username && $rows && @$rows;

    require Plugins::SlimPing::Core::Annotations;
    my @encoded = map { $self->encodeId($type, $_->[0]) } @$rows;
    $starred = Plugins::SlimPing::Core::Annotations->getStarredBatch($username, \@encoded);
    $ratings = Plugins::SlimPing::Core::Annotations->getRatingBatch($username, \@encoded);

    # Merge bridged LMS favourites (the server-global OPML file) into the
    # starred batch.  SlimPing store timestamps win; bridged ids fill gaps
    # only.  Skipped when the bridge has nothing, so unstarred libraries
    # pay no extra work.
    require Plugins::SlimPing::Core::LmsFavorites;
    my $lms = Plugins::SlimPing::Core::LmsFavorites->list();
    if ( grep { keys %{ $lms->{$_} || {} } } qw(tracks albums artists) ) {
        my $bucket = $lms->{ $type . 's' } || {};
        my $ts     = Plugins::SlimPing::Core::LmsFavorites->timestamp();
        if ( defined $ts ) {
            $starred->{$_} = $ts for grep { !exists $starred->{$_} && exists $bucket->{$_} } @encoded;
        }
    }

    return ( $starred, $ratings );
}

1;
