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
# Handlers/Lyrics.pm - Lyrics retrieval handlers with MAI integration
#
# getLyricsBySongId and getLyrics both try the Music & Artist Info plugin
# synchronously first (embedded tags, MAI disk cache, local .lrc/.txt).
# When MAI needs to go online (LRCLib, Genius) the handler returns the
# best available fallback while MAI's callback caches the result so the
# NEXT request for that track completes synchronously.
#

package Plugins::SlimPing::Handlers::Lyrics;

use strict;
use warnings;

# Lyrics.pm retains direct Slim::Schema access (architecture-check exception).
# It needs DBIx Track row objects to call the LMS plugin-provided lyrics()
# method and navigate the contributor relationship for artist-name matching.
# Abstracting these behind the LibraryMapper facade would require the facade
# to know about LMS Track methods and MAI throttling -- crossing into business
# logic.  This is the only handler with this exception.
use Slim::Schema;
use Slim::Control::Request;
use Time::HiRes qw(time);
use Encode qw(encode);
use Plugins::SlimPing::API::Router;
use Plugins::SlimPing::Core::LibraryMapper;
require Plugins::SlimPing::Core::MaiThrottle;
require Plugins::SlimPing::Utils::Errors;

sub registerHandlers {
    my $class = shift;
    Plugins::SlimPing::API::Router->registerHandler('getLyrics',         \&getLyrics);
    Plugins::SlimPing::API::Router->registerHandler('getLyricsBySongId', \&getLyricsBySongId);
}

sub getLyrics {
    my ($args) = @_;
    my $p      = $args->{params};
    my $artist = $p->{artist} // '';
    my $title  = $p->{title}  // '';

    return Plugins::SlimPing::Utils::Errors->error(10,
        'Required parameters artist and title are missing')
        unless length $artist || length $title;

    # Reject only control characters (0x00-0x1f, 0x7f) and enforce length.
    # Allow full Unicode so names like Bjork, Motley Crue, and Sigur Ros
    # pass through -- LMS/SQLite/ChartLyrics handle them natively.
    return Plugins::SlimPing::Utils::Errors->error(0,
        'Invalid artist or title parameter')
        unless $artist =~ /^[^\x00-\x1f\x7f]{1,500}$/
            && $title  =~ /^[^\x00-\x1f\x7f]{1,500}$/;

    # Search for a matching track in the library.
    my $rs = Slim::Schema->search('Track',
        { 'contributorTracks.role' => 1, 'me.title' => $title },
        { join => 'contributorTracks', prefetch => ['primary_artist'] }
    );

    while (my $track = $rs->next()) {
        if ($track->artist() && $track->artist()->name() =~ /\Q$artist\E/i) {
            # Found a matching track -- check embedded lyrics first, then
            # try MAI with throttle gating.
            my $value = $track->lyrics();

            unless ( defined $value && length $value ) {
                my $mai = _withMaiSlot(
                    ['musicartistinfo', 'lyrics', 'track_id:' . $track->id()],
                    'lyrics_track:' . $track->id() );
                if ( $mai && $mai->{sync} ) {
                    $value = $mai->{result};
                }
            }

            return {
                lyrics => {
                    artist => $artist,
                    title  => $title,
                    value  => $value // '',
                }
            };
        }
    }

    # No matching track in the library -- try MAI directly by artist+title.
    # Gate on MaiThrottle: only call executeRequest when a slot is available.
    my $mai = _withMaiSlot(
        ['musicartistinfo', 'lyrics', "artist:$artist", "title:$title"],
        "lyrics_artist_title:$artist:$title" );
    if ( $mai && $mai->{sync} && $mai->{result} ) {
        return {
            lyrics => {
                artist => $artist,
                title  => $title,
                value  => $mai->{result},
            }
        };
    }

    return { lyrics => { artist => $artist, title => $title, value => '' } };
}

sub getLyricsBySongId {
    my ($args) = @_;
    my $id = $args->{params}{id}
        or return Plugins::SlimPing::Utils::Errors->missingParam('id');

    my (undef, $raw_id) = Plugins::SlimPing::Core::LibraryMapper->decodeId($id);
    return Plugins::SlimPing::Utils::Errors->notFound('Song') unless defined $raw_id;

    # Use search with prefetch rather than find() so the artist lookup is
    # eager-loaded rather than triggering a lazy query.
    my $track = Slim::Schema->search('Track',
        { 'me.id' => $raw_id },
        { prefetch => ['primary_artist'], rows => 1 }
    )->first();
    return Plugins::SlimPing::Utils::Errors->notFound('Song') unless $track;

    my $artist_name = $track->artist() ? $track->artist()->name() : '';

    # Check embedded lyrics first -- fast, local, no external service risk.
    # Only probe MAI when embedded lyrics are absent AND a throttle slot is
    # available.  When MAI completes inline (disk cache, local files) the
    # result is used immediately.  When MAI goes async the external fetch
    # runs in the background and populates the cache for the next request.
    my $lyrics_text = $track->lyrics();

    unless ( defined $lyrics_text && length $lyrics_text ) {
        my $mai = _withMaiSlot(
            ['musicartistinfo', 'lyrics', "track_id:$raw_id"],
            "lyrics_track:$raw_id" );
        if ( $mai && $mai->{sync} ) {
            $lyrics_text = $mai->{result};
        }
    }

    # Check sidecar lyric files before falling back to MAI.  This avoids
    # consuming a throttle slot when synced lyrics already exist on disk.
    # MAI's own sidecar scan runs inside the throttle gate — reading here
    # means zero MAI impact for users with local lyric files.
    unless ( defined $lyrics_text && length $lyrics_text ) {
        $lyrics_text = _readSidecarLyrics($track);
    }

    $lyrics_text //= '';

    # OpenSubsonic songLyrics v2: the enhanced parameter gates v2 fields
    # (kind, cueLine).  When absent or false, the response is v1-compatible
    # — no kind, no cueLine.  Per spec, v1 clients see the same response
    # shape they always have.
    my $enhanced = ( $args->{params}{enhanced} // '' ) eq 'true';

    # Best-effort language detection from LRC metadata tags.
    # Falls back to 'und' (ISO standard for undetermined) when no
    # [la:xx] or [language:xx] tag is present in the lyric text.
    my $lang = _detectLang($lyrics_text);

    # Auto-detect the lyric format and parse to the richest possible
    # OpenSubsonic v2 structure.  Fall back to plain unsynced lines when
    # no timestamps are detected (backward-compatible with v1 clients).
    my ( $lines, $is_synced, $cue_lines, $global_offset );
    if ( $lyrics_text =~ /^\[\d+:\d+\.\d+\]/m ) {
        ( $lines, $is_synced, $cue_lines, $global_offset ) = _parseLrc($lyrics_text);
    }
    elsif ( $lyrics_text =~ /^\d+\s*\n\d{1,2}:\d{2}:\d{2}[,.]\d{3}/s ) {
        ( $lines, $is_synced ) = _parseSrt($lyrics_text);
        $cue_lines     = undef;
        $global_offset = 0;
    }
    else {
        $lines         = [ map { { value => $_ } } split( /\r?\n/, $lyrics_text ) ];
        $is_synced     = 0;
        $cue_lines     = undef;
        $global_offset = 0;
    }

    my $structured = {
        lang           => $lang,
        synced         => $is_synced ? \1 : \0,
        line           => $lines,
        displayArtist  => $artist_name,
        displayTitle   => $track->title(),
        ( $global_offset ? ( offset => int($global_offset) ) : () ),
    };

    # v2 fields: only emitted when the client sends enhanced=true.
    # kind is 'main' for our single lyric track — translation and
    # pronunciation kinds require multi-track support from MAI which
    # is not yet available.
    if ($enhanced) {
        $structured->{kind} = 'main';
    }

    # Word-level cueLine data is gated on three conditions per spec:
    # enhanced=true, synced=true, and word-level timing data exists.
    if ( $enhanced && $is_synced && $cue_lines && @$cue_lines ) {
        $structured->{cueLine} = $cue_lines;
    }

    return {
        lyricsList => {
            structuredLyrics => [ $structured ]
        }
    };
}

# Delegate to MaiThrottle::asyncRequest for slot-gated MAI lyrics dispatch.
# The adapter preserves the existing { sync => 1, result => $lyrics } return
# contract so the three callers (getLyrics, getLyricsBySongId) require no changes.
# $cache_key enables deferred-queue coalescing — repeated requests for the same
# track or artist+title pair only occupy one queue slot.
sub _withMaiSlot {
    my ($params, $cache_key) = @_;
    my $result = Plugins::SlimPing::Core::MaiThrottle->asyncRequest($params, undef, 30, $cache_key);
    return undef unless $result;
    if ($result->{sync}) {
        return { sync => 1, result => $result->{request}->getResult('lyrics') };
    }
    return { sync => 0 };
}

# Best-effort language detection from LRC metadata tags.
# Accepts [la:xx] or [language:xx] with an ISO 639 code (e.g. "ko", "en", "ja-Latn").
# Falls back to 'und' (ISO standard for undetermined) when no tag is present.
sub _detectLang {
    my ($text) = @_;
    return 'und' unless defined $text && length $text;
    if ( $text =~ /^\[la(?:nguage)?:\s*(\w+(?:-\w+)?)\s*\]/im ) {
        return $1;
    }
    return 'und';
}

# Resolve the filesystem path for a track and look for sidecar lyric files
# in the same directory.  Checks extensions in priority order: .lrc, .elrc,
# .ttml, .srt, .txt.  Returns the content of the first match found, or undef.
# This bypasses MAI entirely — pure local filesystem read, zero throttle impact.
sub _readSidecarLyrics {
    my ($track) = @_;

    my $url = eval { $track->url() };
    return undef unless $url && Slim::Music::Info::isFileURL($url);

    my $file_path = Slim::Utils::Misc::pathFromFileURL($url);
    return undef unless defined $file_path && length $file_path;

    # Priority order: richer formats first, plain text last.
    my @suffixes = qw(.lrc .elrc .ttml .srt .txt);
    for my $suffix (@suffixes) {
        my $candidate = $file_path;
        $candidate =~ s/\.\w{2,5}$/$suffix/;
        if ( -r $candidate ) {
            my $content = eval { File::Slurp::read_file($candidate) };
            return $content if defined $content;
        }

        # Also try appending the suffix (e.g., Song.flac.lrc).
        my $appended = $file_path . $suffix;
        if ( -r $appended ) {
            my $content = eval { File::Slurp::read_file($appended) };
            return $content if defined $content;
        }
    }

    return undef;
}

# Parse LRC and Enhanced LRC (ELRC) lyric text into OpenSubsonic v2
# structures.  Standard LRC lines have the form [mm:ss.xx] text.
# ELRC adds word-level timing via <mm:ss.xx>word</mm:ss.xx> tags,
# which are parsed into cueLine entries with UTF-8 byte offsets.
#
# Also parses the LRC [offset: +/-ms] metadata tag and applies it to
# all line and cue timestamps.
#
# Returns: ( \@lines, $is_synced, \@cue_lines, $offset_ms )
#   \@cue_lines is undef when no word-level timing tags are detected.
#   $offset_ms is the parsed [offset:] value in ms (0 if absent).
#   \@cue_lines elements: { index, start, end, value, cue => [...] }
#     cue elements: { byteStart, byteEnd, start, end, value }
sub _parseLrc {
    my ($text) = @_;

    my @lines;
    my @cue_lines;
    my $has_word_cues = 0;

    # Parse the [offset:] metadata tag for global timing adjustment.
    # Format: [offset: +/-ms].  Applied to all line start times and
    # word cue times.  Positive = lyrics appear sooner (per spec).
    my $global_offset = 0;
    if ( $text =~ /^\[offset:\s*([+-]?\d+)\s*\]/im ) {
        $global_offset = int($1);
    }

    for my $raw ( split( /\r?\n/, $text ) ) {
        # Skip metadata tags like [ti:Title], [ar:Artist], [offset:+/-ms].
        next if $raw =~ /^\[(?:ti|ar|al|by|offset|length|id|re|ve|la|en|au|to|lr):/i;    #]

        # Extract all [mm:ss.xx] timestamps from the line.
        my @stamps = ( $raw =~ /\[(\d+):(\d+\.\d+)\]/g );    #[] balance
        next unless @stamps;

        # Build ms offset from the first timestamp, adjusted by the
        # global [offset:] value.  Clamp negative results to zero.
        my $start_ms = int( ( $stamps[0] * 60000 ) + ( $stamps[1] * 1000 ) );
        $start_ms += $global_offset;
        $start_ms = 0 if $start_ms < 0;

        # Strip all [mm:ss.xx] timestamp tags to get the intermediate text.
        ( my $cooked = $raw ) =~ s/\[\d+:\d+\.\d+\]//g;    #[] balance

        # --- ELRC word-level timing extraction ---
        # Extract <mm:ss.xx>word text</mm:ss.xx> pairs BEFORE stripping
        # the markup.  The backreferences \1 and \2 match the opening
        # tag values so only properly paired tags are captured.
        #   Note: index()-based byte offset lookup finds the first
        #   occurrence of each word in the display text.  For lines
        #   with repeated words (e.g. "la la la"), subsequent
        #   occurrences get the first word's offset — an acceptable
        #   trade-off for now since repeated words within a single
        #   lyric line are rare.
        my @word_cues;
        while ( $cooked =~ /<(\d+):(\d+\.\d+)>([^<]*)<\/\1:\2>/g ) {
            my $word_ms = int( ( $1 * 60000 ) + ( $2 * 1000 ) ) + $global_offset;
            $word_ms = 0 if $word_ms < 0;
            push @word_cues, {
                start_ms => $word_ms,
                text     => $3,
            };
        }

        # Strip only the angle-bracket tag MARKUP, preserving the word
        # text between tags.  The previous regex removed the word text
        # too (s/<\d+:\d+\.\d+>[^<]*<\/\d+:\d+\.\d+>//g), which
        # caused ELRC lyrics to display with missing words.
        $cooked =~ s/<\d+:\d+\.\d+>//g;      # opening tags
        $cooked =~ s/<\/\d+:\d+\.\d+>//g;     # closing tags
        $cooked =~ s/^\s+|\s+$//g;

        my $line_index = scalar @lines;
        push @lines, { start => $start_ms, value => $cooked };

        # --- Build cueLine entry when word-level timing exists ---
        if (@word_cues) {
            $has_word_cues = 1;
            my $encoded   = encode( 'UTF-8', $cooked );
            my $cue_count = scalar @word_cues;

            my @cues;
            for ( my $j = 0 ; $j < $cue_count ; $j++ ) {
                my $wc   = $word_cues[$j];
                my $word = $wc->{text};

                # Compute UTF-8 byte offsets into the display text.
                # Feishin (and the spec) expect byte offsets, not
                # character offsets, for correct slicing of multi-byte
                # codepoints in languages like Korean and Japanese.
                my $encoded_word = encode( 'UTF-8', $word );
                my $byte_start   = index( $encoded, $encoded_word );
                next if $byte_start < 0;    # word not found (should not happen)

                my $byte_end = $byte_start + length($encoded_word) - 1;

                # Word end time per spec all-or-nothing rule: since we
                # emit end on all cues, use the next word's start as
                # this word's end.  The last word in the line uses its
                # own start + 200ms as a conservative estimate (ELRC
                # does not encode durations).
                my $word_end;
                if ( $j + 1 < $cue_count ) {
                    $word_end = $word_cues[ $j + 1 ]->{start_ms};
                }
                else {
                    $word_end = $wc->{start_ms} + 200;
                }

                push @cues, {
                    byteStart => $byte_start,
                    byteEnd   => $byte_end,
                    start     => $wc->{start_ms},
                    end       => $word_end,
                    value     => $word,
                };
            }

            # Line end time: use the last cue's end, falling back to
            # line start + 5000ms.
            my $line_end = $cues[-1]{end} || ( $start_ms + 5000 );

            push @cue_lines, {
                start => $start_ms,
                end   => $line_end,
                index => $line_index,
                value => $cooked,
                cue   => \@cues,
            };
        }
    }

    # If no timestamped lines were found, return plain text.
    unless (@lines) {
        return (
            [ map { { value => $_ } } split( /\r?\n/, $text ) ],
            0,
            undef,
            0
        );
    }

    return ( \@lines, 1, $has_word_cues ? \@cue_lines : undef, $global_offset );
}

# Parse SRT (SubRip) lyric text into OpenSubsonic v2 line entries.
# SRT blocks have the form:
#   1
#   00:01:23,450 --> 00:01:26,780
#   Line text here (may span multiple lines)
#   (blank line separates blocks)
#
# Returns: ( \@lines, $is_synced )
sub _parseSrt {
    my ($text) = @_;

    my @lines;
    my @blocks = split( /\n\s*\n/, $text );

    for my $block (@blocks) {
        $block =~ s/^\s+|\s+$//g;
        next unless $block =~ /^\d+\s*\n/;

        my @parts = split( /\n/, $block );
        shift @parts;    # discard index number
        next unless @parts;

        my $ts_line = shift @parts;
        next unless $ts_line =~ m{ (\d{1,2}) : (\d{2}) : (\d{2}) [,.] (\d{3}) }x;
        my $start_ms = int( ( $1 * 3600000 ) + ( $2 * 60000 )
                          + ( $3 * 1000 ) + ( $4 // 0 ) );

        my $value = join( "\n", @parts );
        $value =~ s/^\s+|\s+$//g;
        next unless length $value;

        push @lines, { start => $start_ms, value => $value };
    }

    unless (@lines) {
        return (
            [ map { { value => $_ } } split( /\r?\n/, $text ) ],
            0
        );
    }

    return ( \@lines, 1 );
}

1;
