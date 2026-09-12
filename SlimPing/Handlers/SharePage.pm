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
# Handlers/SharePage.pm - HTML share landing page for SlimPing
#
# Renders the self-contained HTML page that recipients see when they open a
# share link in a browser.  Owns the header derivation, track listing, inline
# CSS, and the minimal JS audio player.  All HTML output is pure ASCII with
# entity-escaped user-supplied strings for XSS prevention.
#

package Plugins::SlimPing::Handlers::SharePage;

use strict;
use warnings;

require Plugins::SlimPing::Core::LibraryMapper;

# Build and serve the HTML share landing page.
# Receives the already-shaped $share hashref from Handlers::Sharing.
sub serveSharePage {
    my ( $httpClient, $response, $share ) = @_;

    my $token   = $share->{id};
    my $entries = $share->{entry};
    my $count   = scalar @$entries;
    my $first   = $entries->[0];
    my $base = _escapeHtml(Plugins::SlimPing::Core::LibraryMapper->_requestBaseUrl() || '');

    # Header derivation
    my ( $type_label, $title, $subtitle );
    if ( $count == 1 ) {
        $type_label = 'Track';
        $title      = _escapeHtml( $first->{title} || 'Untitled' );
        my @sub_parts;
        push @sub_parts, _escapeHtml( $first->{artist} )
          if defined $first->{artist} && length $first->{artist};
        push @sub_parts, _escapeHtml( $first->{album} )
          if defined $first->{album} && length $first->{album};
        $subtitle = join( " | ", @sub_parts );
    }
    else {
        my $album      = $first->{album} // '';
        my $same_album = 1;
        for my $e (@$entries) {
            if ( ( $e->{album} // '' ) ne $album ) {
                $same_album = 0;
                last;
            }
        }
        if ( $same_album && length $album ) {
            $type_label = 'Album';
            $title      = _escapeHtml($album);
            my @sub_parts;
            push @sub_parts, _escapeHtml( $first->{artist} )
              if defined $first->{artist} && length $first->{artist};
            push @sub_parts, _escapeHtml( $first->{year} )
              if defined $first->{year} && length $first->{year};
            $subtitle = join( " | ", @sub_parts );
        }
        else {
            $type_label = 'Collection';
            $title      = "$count tracks";
            $subtitle   = _escapeHtml( $first->{artist} || '' );
        }
    }

    my $meta_line = _buildMetaLine(
        ( $count == 1 ? $first : undef ), $share,
        ( $count > 1  ? $count : undef )
    );

    # URLs -- $base is entity-escaped above; $token is hex-only
    my $cover_url    = "$base/rest/shareMetadata.view?share=$token&track=0";
    my $playlist_url = "$base/rest/shareStream.view?share=$token&playlist=1";

    # Track rows
    my $track_rows = '';
    for my $i ( 0 .. $#$entries ) {
        my $e       = $entries->[$i];
        my $num     = $i + 1;
        my $t       = _escapeHtml( $e->{title} || 'Untitled' );
        my $artist  = _escapeHtml( $e->{artist} || '' );
        my $album   = _escapeHtml( $e->{album}  || '' );
        my $dur     = $e->{duration} // 0;
        my $min     = int( $dur / 60 );
        my $sec     = $dur % 60;
        my $dur_str = sprintf( '%d:%02d', $min, $sec );
        my $url = "$base/rest/shareStream.view?share=$token&track=$i";
        $track_rows
          .= qq{<tr><td class="num">$num</td><td class="title"><a class="track-link" href="$url" data-title="$t" data-artist="$artist" data-album="$album" data-duration="$dur">$t</a></td><td class="dur">$dur_str</td></tr>\n};
    }

    # Description block (if present).  + signs have already been
    # converted to spaces at the input boundary in Handlers::Sharing.
    my $desc = _escapeHtml( $share->{description} || '' );
    my $desc_block = '';
    if ( length $desc ) {
        $desc_block = qq{<p class="description">Share Note: $desc</p>};
    }

    my $username_esc = _escapeHtml( $share->{username} || 'Someone' );

    # Build HTML
    my $html = <<'PAGE';
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
PAGE

    $html .= qq{<title>$title -- SlimPing</title>\n};

    $html .= <<'PAGE';
<style>
:root {
  --bg: #ffffff;
  --fg: #1f2937;
  --fg-secondary: #6b7280;
  --fg-muted: #9ca3af;
  --border: #e5e7eb;
  --border-light: #f3f4f6;
  --row-hover: #f5f3ff;
  --accent: #667eea;
  --accent-2: #764ba2;
  --header-text: #ffffff;
  --button-bg: #ffffff;
  --button-fg: #667eea;
  --button-ghost-bg: rgba(255,255,255,0.15);
  --button-ghost-border: rgba(255,255,255,0.3);
}
@media (prefers-color-scheme: dark) {
  :root {
    --bg: #0d1117;
    --fg: #c9d1d9;
    --fg-secondary: #8b949e;
    --fg-muted: #484f58;
    --border: #21262d;
    --border-light: #161b22;
    --row-hover: rgba(102,126,234,0.08);
  }
}
*, *::before, *::after { box-sizing: border-box; margin: 0; padding: 0; }
body {
  font-family: system-ui, -apple-system, sans-serif;
  background: var(--bg);
  color: var(--fg);
  line-height: 1.5;
  -webkit-font-smoothing: antialiased;
}
.page { max-width: 640px; margin: 0 auto; }
.header {
  background: linear-gradient(135deg, var(--accent), var(--accent-2));
  padding: 32px 28px 28px;
  color: var(--header-text);
}
.header-inner { display: flex; gap: 24px; align-items: flex-start; }
.cover-art {
  width: 128px; height: 128px;
  border-radius: 8px;
  background: rgba(255,255,255,0.15);
  border: 1px solid rgba(255,255,255,0.2);
  flex-shrink: 0;
  object-fit: cover;
}
.cover-art-placeholder {
  width: 128px; height: 128px;
  border-radius: 8px;
  background: rgba(255,255,255,0.15);
  border: 1px solid rgba(255,255,255,0.2);
  flex-shrink: 0;
  display: flex; align-items: center; justify-content: center;
}
.cover-art-placeholder svg { opacity: 0.5; }
.type-badge {
  font-size: 12px; text-transform: uppercase; letter-spacing: 2px;
  opacity: 0.8; margin-bottom: 6px; font-weight: 600;
}
.header h2 { font-size: 22px; font-weight: 700; line-height: 1.2; margin-bottom: 4px; }
.header .subtitle { font-size: 15px; font-weight: 500; }
.header .meta { font-size: 13px; opacity: 0.75; margin-top: 2px; }
.header .description { font-size: 13px; opacity: 0.8; margin-top: 10px; font-style: italic; line-height: 1.4; }
.buttons { margin-top: 22px; display: flex; gap: 12px; flex-wrap: wrap; }
.btn-primary {
  background: var(--button-bg); color: var(--button-fg);
  padding: 10px 28px; border-radius: 24px; font-size: 14px;
  font-weight: 700; text-decoration: none; display: inline-flex;
  align-items: center; gap: 8px; border: none; cursor: pointer;
}
.btn-primary:hover { opacity: 0.9; }
.btn-ghost {
  background: var(--button-ghost-bg);
  border: 1px solid var(--button-ghost-border);
  color: var(--header-text); padding: 10px 28px; border-radius: 24px;
  font-size: 14px; font-weight: 600; text-decoration: none; cursor: pointer;
}
.btn-ghost:hover { background: rgba(255,255,255,0.25); }
.tracklist { padding: 12px 24px 20px; }
.tracklist table { width: 100%; border-collapse: collapse; }
.tracklist th {
  text-align: left; padding: 8px 12px; color: var(--fg-secondary);
  font-size: 11px; text-transform: uppercase; letter-spacing: 1px;
  font-weight: 600; border-bottom: 1px solid var(--border);
}
.tracklist th.num { width: 40px; }
.tracklist th.dur { width: 56px; text-align: right; }
.tracklist td {
  padding: 10px 12px; font-size: 14px; border-bottom: 1px solid var(--border-light);
}
.tracklist td.num { color: var(--fg-muted); }
.tracklist td.title { font-weight: 500; }
.tracklist td.title a { color: var(--fg); text-decoration: none; }
.tracklist td.title a:hover { color: var(--accent); text-decoration: underline; }
.tracklist td.dur { color: var(--fg-secondary); font-size: 13px; text-align: right; }
.tracklist tr:hover td { background: var(--row-hover); }
.player-section {
  padding: 16px 24px; margin-top: 24px;
  border-top: 1px solid var(--border);
  background: var(--border-light);
  border-radius: 8px;
}
.player-track-info {
  font-size: 14px; font-weight: 500; margin-bottom: 10px;
  color: var(--fg);
}
.player-time-bar {
  display: flex; align-items: center; gap: 8px; margin-bottom: 10px;
}
.player-time {
  font-size: 12px; color: var(--fg-secondary);
  min-width: 38px; font-variant-numeric: tabular-nums;
}
.player-time:last-child { text-align: right; }
.player-seek {
  flex: 1; height: 4px; cursor: pointer;
  -webkit-appearance: none; appearance: none;
  background: var(--border);
  border-radius: 2px; outline: none;
}
.player-seek::-webkit-slider-thumb {
  -webkit-appearance: none; width: 12px; height: 12px;
  border-radius: 50%; background: var(--accent); cursor: pointer;
}
.player-seek::-moz-range-thumb {
  width: 12px; height: 12px;
  border-radius: 50%; background: var(--accent); cursor: pointer; border: none;
}
.player-controls {
  display: flex; align-items: center; justify-content: center; gap: 8px;
}
.player-btn {
  background: none; border: 1px solid var(--border);
  color: var(--fg); padding: 6px 16px; border-radius: 16px;
  font-size: 13px; cursor: pointer;
}
.player-btn:hover { background: var(--row-hover); }
.player-btn:active { opacity: 0.7; }
.player-btn-play {
  background: var(--accent); color: #fff; border-color: var(--accent);
  padding: 6px 28px; min-width: 80px;
}
.player-btn-play:hover { opacity: 0.85; background: var(--accent); }
.player-btn-play.paused { background: var(--accent); }
.footer {
  padding: 14px 24px; border-top: 1px solid var(--border);
  font-size: 12px; color: var(--fg-muted);
  display: flex; align-items: center; gap: 8px;
}
.footer .brand { font-weight: 600; color: var(--accent); }
</style>
</head>
<body>
<div class="page">
PAGE

    # Header section
    $html .= qq{<div class="header">\n};
    $html .= qq{<div class="header-inner">\n};

    # Cover art with fallback to submarine SVG placeholder
    $html
      .= qq{<img class="cover-art" src="$cover_url" alt="Cover art" onerror="this.style.display='none';this.nextElementSibling.style.display='flex'">\n};
    $html .= qq{<div class="cover-art-placeholder" style="display:none">\n};
    $html
      .= qq{<svg width="48" height="48" viewBox="0 0 24 24"><rect x="5" y="13" width="14" height="5" rx="2.5" fill="rgba(255,255,255,0.85)"/><rect x="10" y="10.5" width="4" height="2.5" rx="0.8" fill="rgba(255,255,255,0.85)"/><circle cx="9" cy="15.5" r="0.7" fill="#667eea"/><circle cx="12" cy="15.5" r="0.7" fill="#667eea"/><circle cx="15" cy="15.5" r="0.7" fill="#667eea"/></svg>\n};
    $html .= qq{</div>\n};

    # Text block
    $html .= qq{<div>\n};
    $html .= qq{<div class="type-badge">$type_label</div>\n};
    $html .= qq{<h2>$title</h2>\n};
    $html .= qq{<p class="subtitle">$subtitle</p>\n} if length $subtitle;
    $html .= qq{<p class="meta">$meta_line</p>\n} if $meta_line;
    $html .= $desc_block;
    $html .= qq{</div>\n</div>\n};

    # Buttons
    $html .= qq{<div class="buttons">\n};
    $html .= qq{<button id="play-all-btn" class="btn-primary" type="button">Play All</button>\n};
    $html .= qq{</div>\n</div>\n};

    # Inline audio player (hidden until a track is played)
    $html .= qq{<div class="player-section" id="player-section" style="display:none">\n};
    $html .= qq{<div class="player-track-info" id="player-track-info"></div>\n};
    $html .= qq{<div class="player-time-bar">\n};
    $html .= qq{<span class="player-time" id="player-time-current">0:00</span>\n};
    $html .= qq{<input type="range" class="player-seek" id="player-seek" min="0" max="100" value="0" step="any">\n};
    $html .= qq{<span class="player-time" id="player-time-total">0:00</span>\n};
    $html .= qq{</div>\n};
    $html .= qq{<div class="player-controls">\n};
    $html .= qq{<button class="player-btn" id="player-prev" title="Previous track">Prev</button>\n};
    $html .= qq{<button class="player-btn player-btn-play" id="player-play-pause">Play</button>\n};
    $html .= qq{<button class="player-btn" id="player-next" title="Next track">Next</button>\n};
    $html .= qq{</div>\n};
    $html .= qq{<audio id="audio-player" preload="metadata" playsinline></audio>\n};
    $html .= qq{</div>\n};

    # Track listing
    $html .= qq{<div class="tracklist">\n<table>\n};
    $html
      .= qq{<thead><tr><th class="num">#</th><th>Title</th><th class="dur">Duration</th></tr></thead>\n};
    $html .= qq{<tbody>\n$track_rows</tbody>\n</table>\n</div>\n};

    # Footer
    my $footer_line
      = "SlimPing | Shared by $username_esc | For private streaming only";
    $html .= qq{<div class="footer">$footer_line</div>\n};

    $html .= qq{</div>\n};

    # Inline audio player -- intercepts track-link clicks and the Play All
    # button.  Controls: prev/next, play/pause, seek bar, time display.
    $html .= <<'PAGE';
<script>
(function(){
  var audio = document.getElementById('audio-player');
  var section = document.getElementById('player-section');
  var info = document.getElementById('player-track-info');
  var timeCur = document.getElementById('player-time-current');
  var timeTot = document.getElementById('player-time-total');
  var seek = document.getElementById('player-seek');
  var playPauseBtn = document.getElementById('player-play-pause');
  var prevBtn = document.getElementById('player-prev');
  var nextBtn = document.getElementById('player-next');
  var playAllBtn = document.getElementById('play-all-btn');
  var linkEls = document.querySelectorAll('.track-link');

  var tracks = [];
  for (var i = 0; i < linkEls.length; i++) {
    tracks.push({
      url: linkEls[i].getAttribute('href'),
      title: linkEls[i].getAttribute('data-title') || linkEls[i].textContent,
      artist: linkEls[i].getAttribute('data-artist') || '',
      album: linkEls[i].getAttribute('data-album') || '',
      duration: parseInt(linkEls[i].getAttribute('data-duration'), 10) || 0
    });
  }

  var currentIndex = -1;
  var currentUrl = null;
  var seeking = false;
  var seekTimeout = null;
  var autoAdvanced = false;

  function fmtTime(sec) {
    if (!isFinite(sec) || sec < 0) return '0:00';
    var m = Math.floor(sec / 60);
    var s = Math.floor(sec % 60);
    return m + ':' + (s < 10 ? '0' : '') + s;
  }

  // Always prefer the known track duration from share metadata -- streamed
  // audio often reports a bogus finite duration derived from buffer length.
  function trackDuration() {
    if (currentIndex >= 0 && tracks[currentIndex].duration > 0) {
      return tracks[currentIndex].duration;
    }
    var dur = audio.duration;
    return (isFinite(dur) && dur > 0) ? dur : 0;
  }

  function updateTime() {
    var ct = audio.currentTime;
    var dur = trackDuration();
    timeCur.textContent = fmtTime(ct);
    if (dur > 0 && !seeking) {
      seek.value = (ct / dur) * 100;
    }
  }

  function updateTotal() {
    var dur = trackDuration();
    if (dur > 0) {
      timeTot.textContent = fmtTime(dur);
      seek.max = 100;
    }
  }

  function setPlayingState() {
    playPauseBtn.textContent = audio.paused ? 'Play' : 'Pause';
    playPauseBtn.classList.toggle('paused', audio.paused);
  }

  function playIndex(idx) {
    if (idx < 0 || idx >= tracks.length) return;
    currentIndex = idx;
    currentUrl = tracks[idx].url;
    audio.src = currentUrl;
    info.textContent = (idx + 1) + ' of ' + tracks.length + ': ' + tracks[idx].title;
    section.style.display = 'block';
    // Show known duration immediately -- streamed audio won't report it.
    if (tracks[idx].duration > 0) {
      timeTot.textContent = fmtTime(tracks[idx].duration);
      seek.max = 100; seek.value = 0;
    } else {
      timeTot.textContent = '0:00';
    }
    timeCur.textContent = '0:00';
    autoAdvanced = false;
    audio.play();
    updateMediaSession(idx);
    section.scrollIntoView({behavior:'smooth', block:'nearest'});
  }

  // Update the Media Session API so mobile lock-screen / notification
  // controls show artwork, title, and artist instead of a generic icon.
  function updateMediaSession(idx) {
    if (!('mediaSession' in navigator)) return;
    var t = tracks[idx];
    var coverImg = document.querySelector('.cover-art');
    var artwork = [];
    if (coverImg && coverImg.src) {
      artwork.push({ src: coverImg.src, sizes: '512x512', type: 'image/jpeg' });
    }
    navigator.mediaSession.metadata = new MediaMetadata({
      title: t.title,
      artist: t.artist || '',
      album: t.album || '',
      artwork: artwork
    });
  }

  // Media Session action handlers for lock-screen / notification controls
  if ('mediaSession' in navigator) {
    navigator.mediaSession.setActionHandler('previoustrack', function() {
      if (currentIndex > 0) playIndex(currentIndex - 1);
    });
    navigator.mediaSession.setActionHandler('nexttrack', function() {
      if (currentIndex >= 0 && currentIndex < tracks.length - 1) playIndex(currentIndex + 1);
    });
  }

  // Per-track click handlers
  for (var i = 0; i < linkEls.length; i++) {
    linkEls[i].addEventListener('click', function(e) {
      e.preventDefault();
      var url = this.getAttribute('href');
      for (var j = 0; j < tracks.length; j++) {
        if (tracks[j].url === url) {
          if (currentUrl === url && currentIndex === j) {
            if (audio.paused) { audio.play(); } else { audio.pause(); }
            return;
          }
          playIndex(j);
          return;
        }
      }
    });
  }

  // Play All button
  playAllBtn.addEventListener('click', function(e) {
    e.preventDefault();
    playIndex(0);
  });

  // Transport controls
  playPauseBtn.addEventListener('click', function() {
    if (!currentUrl && tracks.length > 0) { playIndex(0); return; }
    if (audio.paused) { audio.play(); } else { audio.pause(); }
  });

  prevBtn.addEventListener('click', function() {
    if (currentIndex > 0) playIndex(currentIndex - 1);
  });

  nextBtn.addEventListener('click', function() {
    if (currentIndex >= 0 && currentIndex < tracks.length - 1) playIndex(currentIndex + 1);
  });

  // Seek bar -- uses metadata duration fallback for streamed audio
  seek.addEventListener('input', function() {
    seeking = true;
    var dur = trackDuration();
    if (dur > 0) {
      timeCur.textContent = fmtTime((seek.value / 100) * dur);
    }
  });
  seek.addEventListener('change', function() {
    var dur = trackDuration();
    if (dur > 0) {
      audio.currentTime = (seek.value / 100) * dur;
    }
    seeking = true;
    clearTimeout(seekTimeout);
    seekTimeout = setTimeout(function() { seeking = false; }, 500);
  });

  // Audio events
  audio.addEventListener('seeked', function() {
    seeking = false;
    clearTimeout(seekTimeout);
  });
  audio.addEventListener('loadedmetadata', function() {
    updateTotal();
    updateTime();
    timeCur.textContent = fmtTime(audio.currentTime);
    setPlayingState();
  });
  audio.addEventListener('timeupdate', function() {
    updateTime();
    // Fallback end-of-track detection for streamed audio where the
    // 'ended' event is unreliable (chunked/ICY delivery).  When
    // playback reaches within 2 s of the known duration, auto-advance.
    if (autoAdvanced) return;
    var dur = trackDuration();
    if (dur > 0 && currentIndex >= 0 && !audio.paused) {
      if (audio.currentTime >= dur - 2) {
        autoAdvanced = true;
        if (currentIndex < tracks.length - 1) {
          playIndex(currentIndex + 1);
        }
      }
    }
  });
  audio.addEventListener('play', setPlayingState);
  audio.addEventListener('pause', setPlayingState);
  audio.addEventListener('ended', function() {
    setPlayingState();
    seek.value = 100;
    timeCur.textContent = timeTot.textContent;
    if (!autoAdvanced && currentIndex >= 0 && currentIndex < tracks.length - 1) {
      playIndex(currentIndex + 1);
    }
  });
})();
</script>
</body>
</html>

PAGE

    $response->code(200);
    $response->header( 'Content-Type'   => 'text/html; charset=utf-8' );
    $response->header( 'Content-Length' => length($html) );
    $response->header( 'Cache-Control'  => 'private, no-store' );
    Slim::Web::HTTP::addHTTPResponse( $httpClient, $response, \$html );
}

# HTML entity encode user-supplied strings to prevent XSS.
sub _escapeHtml {
    my ($text) = @_;
    return '' unless defined $text;
    $text =~ s/&/&amp;/g;
    $text =~ s/</&lt;/g;
    $text =~ s/>/&gt;/g;
    $text =~ s/"/&quot;/g;
    $text =~ s/'/&#39;/g;
    return $text;
}

# Format a Unix epoch as "14 May 2026".
sub _formatExpiryDate {
    my ($epoch) = @_;
    return '' unless $epoch;
    my @lt = localtime($epoch);
    my @months = qw(Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec);
    return sprintf( '%d %s %d', $lt[3], $months[ $lt[4] ], $lt[5] + 1900 );
}

# Build a metadata line for the share page header, e.g.
# "3:42 | Rock | 12 tracks | Expires 14 May 2026"
sub _buildMetaLine {
    my ( $entry, $share, $count ) = @_;
    my @parts;
    if ($entry) {
        my $dur = $entry->{duration} // 0;
        if ($dur) {
            push @parts, sprintf( '%d:%02d', int( $dur / 60 ), $dur % 60 );
        }
        push @parts, _escapeHtml( $entry->{genre} ) if $entry->{genre};
    }
    if ($count) {
        push @parts, "$count tracks";
    }
    if ( $share->{expires} ) {
        push @parts, 'Expires ' . _formatExpiryDate( $share->{expires} );
    }
    return join( ' | ', @parts );
}

1;
