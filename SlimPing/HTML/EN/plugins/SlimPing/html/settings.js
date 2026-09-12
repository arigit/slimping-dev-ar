/* SlimPing Settings JavaScript - Modular functions for settings page */

var SlimPingSettings = (function() {
    'use strict';

    // Wrap fetch so the admin API key (rendered into the page when the operator
    // authenticated via ?k=<key>) is forwarded as Authorization: Bearer to all
    // settings JSON endpoints.  When LMS web auth is enabled the browser sends
    // Basic Auth on every same-origin request automatically and no key is
    // needed; the wrapper is a no-op in that case.
    function spFetch(url, opts) {
        opts = opts || {};
        var key = (typeof window !== 'undefined') ? window.SlimPingAdminKey : '';
        if (key) {
            opts.headers = opts.headers || {};
            if (!opts.headers['Authorization']) {
                opts.headers['Authorization'] = 'Bearer ' + key;
            }
        }
        return fetch(url, opts);
    }

    var modules = {
        UI: {},
        Jukebox: {},
        Users: {},
        Server: {},
        NowPlaying: {},
        Sharing: {},
        init: function() {
            this.UI.init();
            this.Server.init();
            this.Users.initAliasInputs();
            this.Jukebox.populateSelects();
            this.RadioFolder.populate();
            this.Sharing.init();
            this.DynamicPlaylists.init();
            this.DataManagement.refreshStats();
            this.DataManagement.refreshCacheStats();
        }
    };

    // ===== UI MODULE (Accordions) =====
    modules.UI = {
        init: function() {
            this.initAccordions();
        },

        initAccordions: function() {
            var headers = document.querySelectorAll('.settings-accordion-header');
            headers.forEach(function(header) {
                header.addEventListener('click', function() {
                    var accordion = this.closest('.settings-accordion');
                    var content = accordion.querySelector('.settings-accordion-content');
                    var isExpanded = this.getAttribute('aria-expanded') === 'true';

                    this.setAttribute('aria-expanded', !isExpanded);
                    content.style.display = isExpanded ? 'none' : 'block';

                    var accordionId = accordion.getAttribute('data-accordion-id');
                    if (accordionId) {
                        localStorage.setItem('slimping_accordion_' + accordionId, !isExpanded);
                    }
                });

                // Restore accordion state from localStorage
                var accordion = header.closest('.settings-accordion');
                var accordionId = accordion.getAttribute('data-accordion-id');
                if (accordionId) {
                    var isExpanded = localStorage.getItem('slimping_accordion_' + accordionId) === 'true';
                    var content = accordion.querySelector('.settings-accordion-content');
                    header.setAttribute('aria-expanded', isExpanded);
                    content.style.display = isExpanded ? 'block' : 'none';
                }
            });
        }
    };

    // ===== JUKEBOX MODULE =====
    modules.Jukebox = {
        populateSelects: function() {
            var selects = document.querySelectorAll('.sp-jukebox-select');
            if (!selects.length) { return; }
            spFetch('/plugins/SlimPing/settings/players')
                .then(function(r) { return r.json(); })
                .then(function(data) {
                    var players = data.players || [];
                    selects.forEach(function(sel) {
                        var current = sel.getAttribute('data-current');
                        sel.innerHTML = '<option value="">None (jukebox disabled)</option>';
                        var matched = false;
                        players.forEach(function(p) {
                            var label = p.name + ' (' + (p.model || 'unknown') + ')';
                            if (p.sync_master) {
                                label += ' [Sync Group: ' + p.sync_members.map(function(m) { return m.name; }).join(', ') + ']';
                            }
                            var opt = document.createElement('option');
                            opt.value = p.id;
                            opt.textContent = label;
                            if (p.id === current && current !== '') {
                                opt.selected = true;
                                matched = true;
                            }
                            sel.appendChild(opt);
                        });
                        // Preserve current assignment even if the player is offline
                        if (!matched && current && current !== '') {
                            var offlineOpt = document.createElement('option');
                            offlineOpt.value = current;
                            offlineOpt.textContent = current + ' (offline)';
                            offlineOpt.selected = true;
                            sel.appendChild(offlineOpt);
                        }
                    });
                })
                .catch(function(e) {
                    console.error('SlimPing: failed to load player list: ' + e.message);
                });
        },

        setPlayer: function(select) {
            var username = select.getAttribute('data-username');
            var playerId = select.value;
            spFetch('/plugins/SlimPing/settings/users', {
                method: 'POST',
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify({
                    action: 'set_jukebox_player',
                    username: username,
                    player_id: playerId || null
                })
            }).then(function(r) { return r.json(); }).then(function(d) {
                if (!d.ok) { alert('Error: ' + (d.error || 'unknown')); }
            }).catch(function(e) { alert('Network error: ' + e.message); });
        }
    };

    // ===== USERS MODULE =====
    modules.Users = {
        createUser: function() {
            var u = document.getElementById('sp_username').value;
            var p = document.getElementById('sp_password').value;
            var a = document.getElementById('sp_admin').checked;
            if (!u || !p) { alert('Username and password are required.'); return; }
            spFetch('/plugins/SlimPing/settings/users', {
                method: 'POST',
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify({ action: 'create', username: u, password: p, admin: a })
            }).then(function(r) { return r.json(); }).then(function(d) {
                if (d.ok) { location.reload(); }
                else { alert('Error: ' + (d.error || 'unknown')); }
            }).catch(function(e) { alert('Network error: ' + e.message); });
        },

        addApiKey: function(safe) {
            var label = prompt('Key label (leave blank for default):');
            if (label === null) { return; }
            var username = decodeURIComponent(safe);
            spFetch('/plugins/SlimPing/settings/users', {
                method: 'POST',
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify({ action: 'add_key', username: username, label: label || 'Default' })
            }).then(function(r) { return r.json(); }).then(function(d) {
                if (d.key && d.key.key) {
                    var panel = document.getElementById('sp-apikey-panel-' + safe);
                    if (panel) { panel.style.display = ''; }
                    var container = document.getElementById('sp-apikey-' + safe);
                    var input = document.getElementById('sp-apikey-val-' + safe);
                    var lbl = document.getElementById('sp-apikey-lbl-' + safe);
                    if (container && input) {
                        input.value = d.key.key;
                        if (lbl) {
                            lbl.textContent = 'Label: ' + (d.key.label || 'Default')
                                + ' - save this key now, it cannot be retrieved later';
                        }
                        container.style.display = 'block';
                    }
                } else {
                    alert('Error: ' + (d.error || 'unknown'));
                }
            }).catch(function(e) { alert('Network error: ' + e.message); });
        },

        copyKey: function(safe) {
            var input = document.getElementById('sp-apikey-val-' + safe);
            if (!input) { return; }
            input.select();
            input.setSelectionRange(0, 99999);
            try {
                document.execCommand('copy');
                var btn = input.nextElementSibling;
                if (btn) {
                    var orig = btn.textContent;
                    btn.textContent = 'Copied!';
                    setTimeout(function() { btn.textContent = orig; }, 2000);
                }
            } catch (e) {
                alert('Copy failed - please select and copy manually');
            }
        },

        setAdmin: function(username, enabled) {
            spFetch('/plugins/SlimPing/settings/users', {
                method: 'POST',
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify({ action: 'set_admin', username: username, admin: enabled })
            }).then(function(r) { return r.json(); }).then(function(d) {
                if (!d.ok) { alert('Error: ' + (d.error || 'unknown')); }
            }).catch(function(e) { alert('Network error: ' + e.message); });
        },

        setEnabled: function(username, enabled) {
            spFetch('/plugins/SlimPing/settings/users', {
                method: 'POST',
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify({ action: 'set_enabled', username: username, enabled: enabled ? 1 : 0 })
            }).then(function(r) { return r.json(); }).then(function(d) {
                if (!d.ok) { alert('Error: ' + (d.error || 'unknown')); }
            }).catch(function(e) { alert('Network error: ' + e.message); });
        },

        changePassword: function(username) {
            var pw = prompt('Enter new password for ' + username + ':');
            if (pw === null || pw === '') { return; }
            var pw2 = prompt('Confirm new password:');
            if (pw2 === null) { return; }
            if (pw !== pw2) { alert('Passwords do not match.'); return; }
            spFetch('/plugins/SlimPing/settings/users', {
                method: 'POST',
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify({ action: 'set_password', username: username, password: pw })
            }).then(function(r) { return r.json(); }).then(function(d) {
                if (d.ok) { alert('Password changed successfully.'); }
                else { alert('Error: ' + (d.error || 'unknown')); }
            }).catch(function(e) { alert('Network error: ' + e.message); });
        },

        revokeApiKey: function(username, keyId) {
            if (!confirm('Revoke API key ' + keyId + ' for ' + username + '? This cannot be undone.')) { return; }
            spFetch('/plugins/SlimPing/settings/users', {
                method: 'POST',
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify({ action: 'revoke_key', username: username, key_id: keyId })
            }).then(function(r) { return r.json(); }).then(function(d) {
                if (d.ok) { location.reload(); }
                else { alert('Error: ' + (d.error || 'unknown')); }
            }).catch(function(e) { alert('Network error: ' + e.message); });
        },

        setAlias: function(username, alias) {
            spFetch('/plugins/SlimPing/settings/users', {
                method: 'POST',
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify({ action: 'set_alias', username: username, alias: alias || null })
            }).then(function(r) { return r.json(); }).then(function(d) {
                if (!d.ok) { alert('Error: ' + (d.error || 'unknown')); }
            }).catch(function(e) { alert('Network error: ' + e.message); });
        },

        setScrobbleEnabled: function(username, enabled) {
            spFetch('/plugins/SlimPing/settings/users', {
                method: 'POST',
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify({ action: 'set_scrobble_enabled', username: username, scrobble_enabled: enabled })
            });
        },

        setPlaycountSyncEnabled: function(username, enabled) {
            spFetch('/plugins/SlimPing/settings/users', {
                method: 'POST',
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify({ action: 'set_playcount_sync_enabled', username: username, playcount_sync_enabled: enabled })
            });
        },

        setPlaybackLogging: function(username, enabled) {
            spFetch('/plugins/SlimPing/settings/users', {
                method: 'POST',
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify({ action: 'set_playback_logging', username: username, playback_logging: enabled })
            });
        },

        setAcceptPlaybackReport: function(username, enabled) {
            spFetch('/plugins/SlimPing/settings/users', {
                method: 'POST',
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify({ action: 'set_accept_playback_report', username: username, accept_playback_report: enabled })
            });
        },

        toggleApiKeys: function(safe) {
            var panel = document.getElementById('sp-apikey-panel-' + safe);
            if (panel) {
                panel.style.display = panel.style.display === 'none' ? '' : 'none';
            }
        },

        initAliasInputs: function() {
            var inputs = document.querySelectorAll('.sp-alias-input');
            inputs.forEach(function(input) {
                var saveTimeout;
                // Save on blur (field exit)
                input.addEventListener('blur', function() {
                    var username = this.getAttribute('data-username');
                    var value = this.value.trim();
                    modules.Users.setAlias(username, value || null);
                });
                // Save on Enter key
                input.addEventListener('keydown', function(e) {
                    if (e.key === 'Enter') {
                        e.preventDefault();
                        this.blur();
                    }
                });
            });
        }
    };

    // ===== SERVER MODULE =====
    modules.Server = {
        init: function() {
            this.initExposureToggles();
            this.initFeatureToggles();
            this.initClientQuirks();
        },

        initExposureToggles: function() {
            var radios = document.querySelectorAll('.sp-exposure-radio');
            var checklist = document.getElementById('sp-library-checklist');
            radios.forEach(function(radio) {
                radio.addEventListener('change', function() {
                    if (checklist) {
                        checklist.style.display = this.value === 'selected' ? 'block' : 'none';
                    }
                });
            });
        },

        saveExposure: function() {
            var radio = document.querySelector('input[name="exposed_libraries_mode"]:checked');
            var mode = radio ? radio.value : 'all';

            var ids = [];
            if (mode === 'selected') {
                var boxes = document.querySelectorAll('.sp-library-check:checked');
                boxes.forEach(function(cb) { ids.push(cb.value); });
            }

            var resultEl = document.getElementById('sp-exposure-result');
            spFetch('/plugins/SlimPing/settings/server', {
                method: 'POST',
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify({
                    action: 'save_exposure',
                    exposed_libraries_mode: mode,
                    exposed_library_ids: ids
                })
            }).then(function(r) { return r.json(); }).then(function(d) {
                if (d.ok) {
                    if (resultEl) {
                        resultEl.textContent = 'Saved.';
                        resultEl.className = 'sp-save-result sp-save-ok';
                        setTimeout(function() { resultEl.textContent = ''; }, 3000);
                    }
                } else {
                    alert('Error: ' + (d.error || 'unknown'));
                }
            }).catch(function(e) { alert('Network error: ' + e.message); });
        },

        saveAdminAccess: function() {
            var radio = document.querySelector('input[name="admin_access"]:checked');
            var mode = radio ? radio.value : 'lan_open';
            var resultEl = document.getElementById('sp-admin-access-result');
            spFetch('/plugins/SlimPing/settings/server', {
                method: 'POST',
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify({ action: 'save_admin_access', admin_access: mode })
            }).then(function(r) { return r.json(); }).then(function(d) {
                if (d.ok) {
                    if (resultEl) {
                        resultEl.textContent = 'Saved. Reload the page to test the new mode.';
                        resultEl.className = 'sp-save-result sp-save-ok';
                    }
                } else {
                    alert('Error: ' + (d.error || 'unknown'));
                }
            }).catch(function(e) { alert('Network error: ' + e.message); });
        },

        saveLanMode: function() {
            var box = document.getElementById('lan_mode');
            // Send 0/1 not true/false -- JSON::PP::Boolean false on the server
            // can deserialise as a truthy blessed-reference on older Perl
            // installs and silently invert the save.
            var on = (box && box.checked) ? 1 : 0;
            var resultEl = document.getElementById('sp-lan-mode-result');
            spFetch('/plugins/SlimPing/settings/server', {
                method: 'POST',
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify({ action: 'save_lan_mode', lan_mode: on })
            })
                .then(function(r) { return r.json(); }).then(function(d) {
                    if (d.ok) {
                        if (resultEl) {
                            resultEl.textContent = 'Saved.';
                            resultEl.className = 'sp-save-result sp-save-ok';
                            setTimeout(function() { resultEl.textContent = ''; }, 3000);
                        }
                    } else {
                        alert('Error: ' + (d.error || 'unknown'));
                    }
                }).catch(function(e) { alert('Network error: ' + e.message); });
        },

        saveAllowPlainPassword: function() {
            var box = document.getElementById('allow_plain_password');
            var on = (box && box.checked) ? 1 : 0;
            var resultEl = document.getElementById('sp-allow-plain-result');
            spFetch('/plugins/SlimPing/settings/server', {
                method: 'POST',
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify({
                    action: 'save_allow_plain_password',
                    allow_plain_password: on
                })
            }).then(function(r) { return r.json(); }).then(function(d) {
                if (d.ok) {
                    if (resultEl) {
                        resultEl.textContent = 'Saved. Reload the page to refresh the banner.';
                        resultEl.className = 'sp-save-result sp-save-ok';
                    }
                } else {
                    alert('Error: ' + (d.error || 'unknown'));
                }
            }).catch(function(e) { alert('Network error: ' + e.message); });
        },

        resetRateLimits: function() {
            var resultEl = document.getElementById('sp-ratelimit-result');
            spFetch('/plugins/SlimPing/settings/server', {
                method: 'POST',
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify({ action: 'reset_rate_limits' })
            }).then(function(r) { return r.json(); }).then(function(d) {
                if (d.ok) {
                    if (resultEl) {
                        resultEl.textContent = 'Cleared (' + (d.cleared || 0) + ' bucket(s)).';
                        resultEl.className = 'sp-save-result sp-save-ok';
                        setTimeout(function() { resultEl.textContent = ''; }, 4000);
                    }
                } else {
                    alert('Error: ' + (d.error || 'unknown'));
                }
            }).catch(function(e) { alert('Network error: ' + e.message); });
        },

        saveTrustXff: function() {
            var box = document.getElementById('trust_xff');
            // Send 0/1 (see saveLanMode comment).
            var on = (box && box.checked) ? 1 : 0;
            var resultEl = document.getElementById('sp-trust-xff-result');
            spFetch('/plugins/SlimPing/settings/server', {
                method: 'POST',
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify({ action: 'save_trust_xff', trust_xff: on })
            }).then(function(r) { return r.json(); }).then(function(d) {
                if (d.ok) {
                    if (resultEl) {
                        resultEl.textContent = 'Saved.';
                        resultEl.className = 'sp-save-result sp-save-ok';
                        setTimeout(function() { resultEl.textContent = ''; }, 3000);
                    }
                } else {
                    alert('Error: ' + (d.error || 'unknown'));
                }
            }).catch(function(e) { alert('Network error: ' + e.message); });
        },

        initFeatureToggles: function() {
            var self = this;
            var toggles = document.querySelectorAll('.sp-feature-toggle');
            toggles.forEach(function(toggle) {
                toggle.addEventListener('change', function() {
                    self.saveFeatures();
                });
            });
            var selects = document.querySelectorAll('.sp-feature-toggle-select');
            selects.forEach(function(sel) {
                sel.addEventListener('change', function() {
                    self.saveFeatures();
                });
            });
        },

        initClientQuirks: function() {
            var masterToggle = document.getElementById('toggle_client_quirks');
            var quirkToggles = document.querySelectorAll('.sp-quirk-toggle');
            if (!masterToggle) { return; }

            var updateQuirkToggles = function() {
                var enabled = masterToggle.checked;
                quirkToggles.forEach(function(t) {
                    t.disabled = !enabled;
                    if (!enabled) { t.checked = false; }
                });
            };

            // Set initial state on page load
            updateQuirkToggles();

            // Update per-quirk toggles when master changes
            masterToggle.addEventListener('change', function() {
                updateQuirkToggles();
            });
        },

        saveFeatures: function() {
            var toggles = document.querySelectorAll('.sp-feature-toggle');
            var payload = { action: 'save_features' };
            toggles.forEach(function(toggle) {
                if (toggle.type === 'checkbox') {
                    payload[toggle.getAttribute('data-pref')] = toggle.checked ? 1 : 0;
                } else if (toggle.type === 'text' || toggle.type === 'textarea') {
                    payload[toggle.getAttribute('data-pref')] = toggle.value;
                } else {
                    payload[toggle.getAttribute('data-pref')] = parseInt(toggle.value, 10) || 0;
                }
            });

            // Also collect select-based feature prefs (e.g. tri-state MAI integration)
            var selects = document.querySelectorAll('.sp-feature-toggle-select');
            selects.forEach(function(sel) {
                payload[sel.getAttribute('data-pref')] = sel.value;
            });

            var resultEl        = document.getElementById('sp-features-result');
            var advResultEl     = document.getElementById('sp-advanced-result');
            var metaResultEl    = document.getElementById('sp-metadata-result');
            var storeCapsEl     = document.getElementById('sp-store-caps-result');
            var remoteStreamsEl = document.getElementById('sp-remote-streams-result');
            var exoticResultEl  = document.getElementById('sp-exotic-result');
            var cacheConfigEl   = document.getElementById('sp-cache-config-result');
            var enrichmentEl    = document.getElementById('sp-enrichment-result');
            var ttlResultEl     = document.getElementById('sp-ttl-result');
            spFetch('/plugins/SlimPing/settings/server', {
                method: 'POST',
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify(payload)
            }).then(function(r) { return r.json(); }).then(function(d) {
                if (d.ok) {
                    var showSaved = function(el) {
                        if (el) {
                            el.textContent = 'Saved.';
                            el.className = 'sp-save-result sp-save-ok';
                            setTimeout(function() { el.textContent = ''; }, 3000);
                        }
                    };
                    showSaved(resultEl);
                    showSaved(advResultEl);
                    showSaved(metaResultEl);
                    showSaved(storeCapsEl);
                    showSaved(remoteStreamsEl);
                    showSaved(exoticResultEl);
                    showSaved(cacheConfigEl);
                    showSaved(enrichmentEl);
                    showSaved(ttlResultEl);
                } else {
                    alert('Error: ' + (d.error || 'unknown'));
                }
            }).catch(function(e) { alert('Network error: ' + e.message); });
        },

        saveScrobbleGateway: function(playerId) {
            var resultEl = document.getElementById('sp-scrobble-result');
            spFetch('/plugins/SlimPing/settings/server', {
                method: 'POST',
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify({
                    action: 'save_scrobble_settings',
                    scrobble_gateway_player: playerId,
                    scrobble_source_type: document.querySelector('.sp-scrobble-source-select').value
                })
            }).then(function(r) { return r.json(); }).then(function(d) {
                if (d.ok) {
                    resultEl.textContent = 'Saved';
                    resultEl.className = 'sp-save-result sp-save-ok';
                    setTimeout(function() { resultEl.textContent = ''; }, 2000);
                } else {
                    resultEl.textContent = 'Error: ' + (d.error || 'unknown');
                    resultEl.className = 'sp-save-result sp-save-error';
                    setTimeout(function() { location.reload(); }, 1500);
                }
            }).catch(function(e) {
                resultEl.textContent = 'Network error: ' + e.message;
                resultEl.className = 'sp-save-result sp-save-error';
            });
        },

        saveScrobbleSource: function(sourceType) {
            var resultEl = document.getElementById('sp-scrobble-result');
            spFetch('/plugins/SlimPing/settings/server', {
                method: 'POST',
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify({
                    action: 'save_scrobble_settings',
                    scrobble_gateway_player: document.querySelector('.sp-scrobble-gateway-select').value,
                    scrobble_source_type: sourceType
                })
            }).then(function(r) { return r.json(); }).then(function(d) {
                if (d.ok) {
                    resultEl.textContent = 'Saved';
                    resultEl.className = 'sp-save-result sp-save-ok';
                    setTimeout(function() { resultEl.textContent = ''; }, 2000);
                } else {
                    resultEl.textContent = 'Error: ' + (d.error || 'unknown');
                    resultEl.className = 'sp-save-result sp-save-error';
                }
            }).catch(function(e) {
                resultEl.textContent = 'Network error: ' + e.message;
                resultEl.className = 'sp-save-result sp-save-error';
            });
        }
    };

    // ===== RADIO FOLDER MODULE =====
    modules.RadioFolder = {
        populate: function() {
            var selects = document.querySelectorAll('.sp-radio-folder-select');
            if (!selects.length) { return; }
            spFetch('/plugins/SlimPing/settings/server')
                .then(function(r) { return r.json(); })
                .then(function(data) {
                    var folders = data.folders || [];
                    selects.forEach(function(sel) {
                        var current = sel.getAttribute('data-current') || '';
                        var isPerUser = sel.hasAttribute('data-username');
                        var defaultLabel = isPerUser ? 'Default (Use Plugin Setting)' : 'Root (no folder)';
                        sel.innerHTML = '<option value="">' + defaultLabel + '</option>';
                        var matched = false;
                        folders.forEach(function(f) {
                            var opt = document.createElement('option');
                            opt.value = f.name;
                            opt.textContent = f.name;
                            if (f.name === current) {
                                opt.selected = true;
                                matched = true;
                            }
                            sel.appendChild(opt);
                        });
                        if (!matched && current) {
                            var customOpt = document.createElement('option');
                            customOpt.value = current;
                            customOpt.textContent = current + ' (not found)';
                            customOpt.selected = true;
                            sel.appendChild(customOpt);
                        }
                    });
                })
                .catch(function(e) {
                    console.error('SlimPing: failed to load radio folders: ' + e.message);
                });
        },

        save: function() {
            var sel = document.getElementById('radio_folder_select');
            var folder = sel ? sel.value : '';
            var recurseBox = document.getElementById('radio_folder_recurse');
            var recurse = (recurseBox && recurseBox.checked) ? 1 : 0;
            var resultEl = document.getElementById('sp-radio-folder-result');
            var hidden = document.getElementById('radio_folder');
            if (hidden) { hidden.value = folder; }
            spFetch('/plugins/SlimPing/settings/server', {
                method: 'POST',
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify({ action: 'save_radio_folder', radio_folder: folder, radio_folder_recurse: recurse })
            }).then(function(r) { return r.json(); }).then(function(d) {
                if (d.ok) {
                    if (resultEl) {
                        resultEl.textContent = 'Saved.';
                        resultEl.className = 'sp-save-result sp-save-ok';
                        setTimeout(function() { resultEl.textContent = ''; }, 3000);
                    }
                } else {
                    alert('Error: ' + (d.error || 'unknown'));
                }
            }).catch(function(e) { alert('Network error: ' + e.message); });
        },

        setUserFolder: function(select) {
            var username = select.getAttribute('data-username');
            var folder = select.value;
            spFetch('/plugins/SlimPing/settings/users', {
                method: 'POST',
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify({
                    action: 'set_radio_folder',
                    username: username,
                    radio_folder: folder || null
                })
            }).then(function(r) { return r.json(); }).then(function(d) {
                if (!d.ok) { alert('Error: ' + (d.error || 'unknown')); }
            }).catch(function(e) { alert('Network error: ' + e.message); });
        }
    };

    // ===== DATA MANAGEMENT MODULE =====
    modules.DataManagement = {
        refreshStats: function() {
            var resultEl = document.getElementById('sp-db-stats-result');
            if (resultEl) {
                resultEl.textContent = 'Loading...';
                resultEl.className = 'sp-save-result';
            }
            spFetch('/plugins/SlimPing/settings/data')
                .then(function(r) { return r.json(); })
                .then(function(data) {
                    var container = document.getElementById('sp-db-stats');
                    if (!container) { return; }

                    var counts = data.row_counts || {};
                    var rows = [
                        ['Users',     counts.user     || 0],
                        ['API Keys',  counts.apikey   || 0],
                        ['Stars',     counts.star     || 0],
                        ['Ratings',   counts.rating   || 0],
                        ['Bookmarks', counts.bookmark || 0],
                        ['Sessions',     counts.session    || 0],
                        ['Shares',       counts.share      || 0],
                        ['Biographies',  counts.textcache  || 0]
                    ];

                    var html = '<div style="margin-bottom:8px"><strong>DB Size:</strong> ' + (data.db_size_fmt || 'unknown') + '</div>';
                    html += '<table class="stdt" style="margin:0;width:auto;max-width:400px"><tr><th>Table</th><th>Rows</th></tr>';
                    rows.forEach(function(r) {
                        html += '<tr><td>' + r[0] + '</td><td>' + r[1].toLocaleString() + '</td></tr>';
                    });
                    html += '</table>';
                    container.innerHTML = html;

                    if (resultEl) {
                        resultEl.textContent = 'Updated.';
                        resultEl.className = 'sp-save-result sp-save-ok';
                        setTimeout(function() { resultEl.textContent = ''; }, 3000);
                    }
                })
                .catch(function(e) {
                    if (resultEl) {
                        resultEl.textContent = 'Error: ' + e.message;
                        resultEl.className = 'sp-save-result';
                    }
                });
        },

        refreshCacheStats: function() {
            var resultEl = document.getElementById('sp-cache-stats-result');
            if (resultEl) {
                resultEl.textContent = 'Loading...';
                resultEl.className = 'sp-save-result';
            }
            spFetch('/plugins/SlimPing/settings/data')
                .then(function(r) { return r.json(); })
                .then(function(data) {
                    var container = document.getElementById('sp-cache-stats');
                    if (!container) { return; }
                    var c = data.cache;
                    if (!c) {
                        container.innerHTML = '<p class="text-secondary">Cache not initialised. Stream a track to populate.</p>';
                        return;
                    }
                    var html = '<div style="margin-bottom:8px"><strong>RAM usage:</strong> ' + (c.ram_bytes_fmt || '0 B') + ' / ' + (c.ram_max_fmt || 'unknown') + '</div>';
                    html += '<table class="stdt" style="margin:0;width:auto;max-width:400px"><tr><th>Metric</th><th>Value</th></tr>';
                    html += '<tr><td>RAM entries</td><td>' + (c.ram_entries || 0).toLocaleString() + '</td></tr>';
                    html += '<tr><td>Track limit</td><td>' + (c.ram_track_limit || 0).toLocaleString() + '</td></tr>';
                    html += '<tr><td>Cache hits</td><td>' + (c.ram_hits || 0).toLocaleString() + '</td></tr>';
                    html += '<tr><td>Cache misses</td><td>' + (c.ram_misses || 0).toLocaleString() + '</td></tr>';
                    html += '<tr><td>Evictions</td><td>' + (c.ram_evictions || 0).toLocaleString() + '</td></tr>';
                    if (c.disk_bytes_fmt) {
                        html += '<tr><td>Disk entries</td><td>' + (c.disk_entries || 0).toLocaleString() + '</td></tr>';
                        html += '<tr><td>Disk usage</td><td>' + (c.disk_bytes_fmt || '0 B') + ' / ' + (c.disk_max_fmt || 'unknown') + '</td></tr>';
                    }
                    html += '</table>';
                    container.innerHTML = html;
                    if (resultEl) {
                        resultEl.textContent = 'Updated.';
                        resultEl.className = 'sp-save-result sp-save-ok';
                        setTimeout(function() { resultEl.textContent = ''; }, 3000);
                    }
                })
                .catch(function(e) {
                    if (resultEl) {
                        resultEl.textContent = 'Error: ' + e.message;
                        resultEl.className = 'sp-save-result';
                    }
                });
        },

        flushStore: function(target) {
            var labels = {
                star: 'ALL stars',
                rating: 'ALL ratings',
                bookmark: 'ALL bookmarks',
                session: 'ALL sessions',
                share: 'ALL shares'
            };
            var label = labels[target] || target;
            if (!confirm('Flush ' + label + '?\n\nThis removes ' + label + ' for every user. This cannot be undone. The action will be audited.')) { return; }
            if (!confirm('Are you sure? This is your final warning.\n\nFlushing cannot be reversed.')) { return; }

            var resultEl = document.getElementById('sp-flush-result');
            if (resultEl) {
                resultEl.textContent = 'Working...';
                resultEl.className = 'sp-save-result';
            }
            spFetch('/plugins/SlimPing/settings/data', {
                method: 'POST',
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify({ action: 'flush_store', target: target })
            }).then(function(r) { return r.json(); }).then(function(d) {
                if (d.ok) {
                    if (resultEl) {
                        resultEl.textContent = 'Flushed ' + (d.rows_deleted || 0).toLocaleString() + ' ' + label + ' rows.';
                        resultEl.className = 'sp-save-result sp-save-ok';
                    }
                    modules.DataManagement.refreshStats();
                } else {
                    if (resultEl) {
                        resultEl.textContent = 'Error: ' + (d.error || 'unknown');
                        resultEl.className = 'sp-save-result';
                    }
                }
            }).catch(function(e) {
                if (resultEl) {
                    resultEl.textContent = 'Network error: ' + e.message;
                    resultEl.className = 'sp-save-result';
                }
            });
        },

        deleteUser: function(username) {
            if (!confirm('Delete user "' + username + '" and ALL associated data?\n\nThis will permanently remove:\n- The user account and all API keys\n- All stars, ratings, and bookmarks\n- All play queues and session state\n\nThis cannot be undone. The action will be audited.')) { return; }
            if (!confirm('Are you sure? This is your final warning.')) { return; }

            spFetch('/plugins/SlimPing/settings/data', {
                method: 'POST',
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify({ action: 'delete_user', username: username })
            }).then(function(r) { return r.json(); }).then(function(d) {
                if (d.ok) {
                    location.reload();
                } else {
                    alert('Error: ' + (d.error || 'unknown'));
                }
            }).catch(function(e) { alert('Network error: ' + e.message); });
        },

        resetDatabase: function() {
            if (!confirm('RESET the entire SlimPing database?\n\nThis will permanently delete:\n- ALL users and API keys\n- ALL stars, ratings, and bookmarks\n- ALL sessions and shares\n\nYou will be locked out until you create a new user.\nThe migration sentinel will also be cleared.')) { return; }
            if (!confirm('Are you sure? This cannot be undone. Type "reset" below to confirm.')) { return; }
            if (prompt('Type "reset" to confirm database reset:') !== 'reset') {
                alert('Reset cancelled.');
                return;
            }

            var resultEl = document.getElementById('sp-reset-result');
            if (resultEl) {
                resultEl.textContent = 'Working...';
                resultEl.className = 'sp-save-result';
            }
            spFetch('/plugins/SlimPing/settings/data', {
                method: 'POST',
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify({ action: 'reset_database' })
            }).then(function(r) { return r.json(); }).then(function(d) {
                if (d.ok) {
                    if (resultEl) {
                        resultEl.textContent = 'Database reset. ' + (d.rows_deleted || 0).toLocaleString() + ' rows deleted. Reloading...';
                        resultEl.className = 'sp-save-result sp-save-ok';
                    }
                    setTimeout(function() { location.reload(); }, 2000);
                } else {
                    if (resultEl) {
                        resultEl.textContent = 'Error: ' + (d.error || 'unknown');
                        resultEl.className = 'sp-save-result';
                    }
                }
            }).catch(function(e) {
                if (resultEl) {
                    resultEl.textContent = 'Network error: ' + e.message;
                    resultEl.className = 'sp-save-result';
                }
            });
        },

        flushCache: function() {
            if (!confirm('Flush the transcode cache?\n\nThis removes ALL cached transcoded audio from both RAM and disk tiers. Current streams are not affected.')) { return; }

            var resultEl = document.getElementById('sp-flush-cache-result');
            if (resultEl) {
                resultEl.textContent = 'Working...';
                resultEl.className = 'sp-save-result';
            }
            spFetch('/plugins/SlimPing/settings/data', {
                method: 'POST',
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify({ action: 'flush_cache' })
            }).then(function(r) { return r.json(); }).then(function(d) {
                if (d.ok) {
                    if (resultEl) {
                        resultEl.textContent = 'Cache flushed.';
                        resultEl.className = 'sp-save-result sp-save-ok';
                    }
                } else {
                    if (resultEl) {
                        resultEl.textContent = 'Error: ' + (d.error || 'unknown');
                        resultEl.className = 'sp-save-result';
                    }
                }
            }).catch(function(e) {
                if (resultEl) {
                    resultEl.textContent = 'Network error: ' + e.message;
                    resultEl.className = 'sp-save-result';
                }
            });
        },

        cleanupVirtualPlayers: function() {
            var resultEl = document.getElementById('sp-cleanup-vp-result');
            if (resultEl) {
                resultEl.textContent = 'Working...';
                resultEl.className = 'sp-save-result';
            }
            spFetch('/plugins/SlimPing/settings/data', {
                method: 'POST',
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify({ action: 'cleanup_virtual_players' })
            }).then(function(r) { return r.json(); }).then(function(d) {
                if (d.ok) {
                    if (resultEl) {
                        var n = d.players_removed || 0;
                        resultEl.textContent = n + ' stale virtual player' + (n !== 1 ? 's' : '') + ' removed.';
                        resultEl.className = 'sp-save-result sp-save-ok';
                    }
                } else {
                    if (resultEl) {
                        resultEl.textContent = 'Error: ' + (d.error || 'unknown');
                        resultEl.className = 'sp-save-result';
                    }
                }
            }).catch(function(e) {
                if (resultEl) {
                    resultEl.textContent = 'Network error: ' + e.message;
                    resultEl.className = 'sp-save-result';
                }
            });
        },

        cleanupOrphanedTracks: function() {
            var resultEl = document.getElementById('sp-cleanup-orphans-result');
            var show = function(msg, ok) {
                if (resultEl) {
                    resultEl.textContent = msg;
                    resultEl.className = 'sp-save-result' + (ok ? ' sp-save-ok' : '');
                }
            };
            show('Counting orphaned tracks...', false);

            // Dry run first — count without deleting.
            spFetch('/plugins/SlimPing/settings/data', {
                method: 'POST',
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify({ action: 'cleanup_orphaned_tracks' })
            }).then(function(r) { return r.json(); }).then(function(d) {
                if (!d.ok) { show('Error: ' + (d.error || 'unknown'), false); return; }
                var n = d.orphan_count || 0;
                if (n === 0) {
                    show('No orphaned tracks found.', true);
                    return;
                }
                if (!confirm(
                    n + ' orphaned track' + (n !== 1 ? 's' : '') + ' found.\n\n'
                    + 'This will permanently delete these tracks and their\n'
                    + 'playback records from the LMS database.\n\n'
                    + 'Click OK to proceed with cleanup.')) {
                    show('Cleanup cancelled. ' + n + ' orphaned track' + (n !== 1 ? 's' : '') + ' pending.', false);
                    return;
                }

                show('Deleting ' + n + ' orphaned tracks...', false);
                spFetch('/plugins/SlimPing/settings/data', {
                    method: 'POST',
                    headers: { 'Content-Type': 'application/json' },
                    body: JSON.stringify({ action: 'cleanup_orphaned_tracks', confirm: true })
                }).then(function(r) { return r.json(); }).then(function(d2) {
                    if (d2.ok) {
                        var p = d2.persist_deleted || 0;
                        show('Done. ' + n + ' orphaned track' + (n !== 1 ? 's' : '') + ' and ' + p + ' playback record' + (p !== 1 ? 's' : '') + ' removed.' , true);
                        // Refresh stats to reflect the cleanup.
                        setTimeout(function() { SlimPingSettings.refreshDbStats(); }, 500);
                    } else {
                        show('Error: ' + (d2.error || 'unknown'), false);
                    }
                }).catch(function(e) { show('Network error: ' + e.message, false); });
            }).catch(function(e) { show('Network error: ' + e.message, false); });
        },

        restartServer: function() {
            if (!confirm('Restart the LMS server?\n\nThis will interrupt all currently playing streams and client connections. LMS will be unavailable for 5-15 seconds while it restarts.\n\nClick OK to proceed.')) { return; }

            var resultEl = document.getElementById('sp-restart-result');
            if (resultEl) {
                resultEl.textContent = 'Sending restart command...';
                resultEl.className = 'sp-save-result';
            }
            spFetch('/plugins/SlimPing/settings/data', {
                method: 'POST',
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify({ action: 'restart_server' })
            }).then(function(r) { return r.json(); }).then(function(d) {
                if (d.ok) {
                    if (resultEl) {
                        resultEl.textContent = 'Restarting — LMS will be back in a few seconds.';
                        resultEl.className = 'sp-save-result sp-save-ok';
                    }
                } else {
                    if (resultEl) {
                        resultEl.textContent = 'Error: ' + (d.error || 'unknown');
                        resultEl.className = 'sp-save-result';
                    }
                }
            }).catch(function(e) {
                // Network error is expected — server is restarting
                if (resultEl) {
                    resultEl.textContent = 'Restart command sent (server may be restarting).';
                    resultEl.className = 'sp-save-result sp-save-ok';
                }
            });
        }
    };

    // ===== NOW PLAYING MODULE =====
    var _escHtml = function(s) {
        if (!s) { return ''; }
        var div = document.createElement('div');
        div.appendChild(document.createTextNode(s));
        return div.innerHTML;
    };

    modules.NowPlaying = {
        refresh: function() {
            var statusEl = document.getElementById('sp-np-status');
            if (statusEl) {
                statusEl.style.display = 'inline';
                statusEl.textContent = 'Loading...';
                statusEl.className = 'sp-save-result';
            }
            spFetch('/plugins/SlimPing/settings/nowplaying')
                .then(function(r) { return r.json(); })
                .then(function(data) {
                    var sessions = data.sessions || [];
                    var table = document.querySelector('#sp-nowplaying-table table');
                    var emptyMsg = document.getElementById('sp-np-empty');
                    if (!table) { return; }

                    // Remove existing data rows (keep header)
                    table.querySelectorAll('tr.sp-np-row').forEach(function(r) { r.remove(); });

                    if (sessions.length === 0) {
                        if (emptyMsg) { emptyMsg.style.display = ''; }
                        if (statusEl) {
                            statusEl.textContent = 'No active sessions.';
                            statusEl.className = 'sp-save-result';
                            setTimeout(function() { statusEl.style.display = 'none'; }, 3000);
                        }
                        return;
                    }

                    if (emptyMsg) { emptyMsg.style.display = 'none'; }

                    sessions.forEach(function(s) {
                        var tr = document.createElement('tr');
                        tr.className = 'sp-np-row';
                        var artist = s.track_artist ? ' - ' + _escHtml(s.track_artist) : '';
                        tr.innerHTML =
                            '<td>' + _escHtml(s.username) + '</td>' +
                            '<td>' + _escHtml(s.client_name || 'unknown') + '</td>' +
                            '<td>' + _escHtml(s.track_title || s.track_id || 'unknown') + artist + '</td>' +
                            '<td>' + (s.position_fmt || '0:00') + '</td>' +
                            '<td>' + (s.last_seen_fmt || '') + '</td>';
                        table.appendChild(tr);
                    });

                    if (statusEl) {
                        statusEl.textContent = 'Updated (' + sessions.length + ' session' + (sessions.length !== 1 ? 's' : '') + ').';
                        statusEl.className = 'sp-save-result sp-save-ok';
                        setTimeout(function() { statusEl.style.display = 'none'; }, 3000);
                    }
                })
                .catch(function(e) {
                    if (statusEl) {
                        statusEl.textContent = 'Error: ' + e.message;
                        statusEl.className = 'sp-save-result';
                        statusEl.style.color = 'var(--status-error)';
                    }
                });
        }
    };

    // ===== SHARING MODULE =====
    modules.Sharing = {
        init: function() {
            this.loadShareList();
        },

        loadShareList: function() {
            var self = this;
            spFetch('/plugins/SlimPing/settings/shares')
                .then(function(r) { return r.json(); })
                .then(function(data) {
                    var shares = (data.shares && data.shares.share) || [];
                    var tbody = document.getElementById('sp-share-tbody');
                    var table = document.getElementById('sp-share-table');
                    var noShares = document.getElementById('sp-no-shares');
                    var revokeAllBtn = document.getElementById('sp-revoke-all-btn');

                    if (!tbody) { return; }
                    tbody.innerHTML = '';
                    if (shares.length === 0) {
                        if (table) { table.style.display = 'none'; }
                        if (noShares) { noShares.style.display = 'block'; }
                        if (revokeAllBtn) { revokeAllBtn.style.display = 'none'; }
                        return;
                    }

                    if (table) { table.style.display = ''; }
                    if (noShares) { noShares.style.display = 'none'; }
                    if (revokeAllBtn) { revokeAllBtn.style.display = ''; }

                    shares.forEach(function(s) {
                        var row = tbody.insertRow();
                        row.insertCell().textContent = s.description || '-';
                        row.insertCell().textContent = s.username || '-';
                        row.insertCell().textContent = s.created
                            ? new Date(s.created * 1000).toLocaleDateString() : '-';
                        row.insertCell().textContent = s.expires
                            ? new Date(s.expires * 1000).toLocaleString() : 'Never';
                        row.insertCell().textContent = s.visitCount || 0;
                        row.insertCell().textContent = s.lastVisited
                            ? new Date(s.lastVisited * 1000).toLocaleString() : '-';
                        var linkCell = row.insertCell();
                        var link = document.createElement('a');
                        link.href = '/rest/shareStream.view?share=' + encodeURIComponent(s.id);
                        link.textContent = 'Visit';
                        link.target = '_blank';
                        link.rel = 'noopener';
                        linkCell.appendChild(link);
                        var actionCell = row.insertCell();
                        var revokeBtn = document.createElement('button');
                        revokeBtn.className = 'stdclick btn-danger';
                        revokeBtn.textContent = 'Revoke';
                        revokeBtn.onclick = function() {
                            if (confirm('Revoke share "' + (s.description || s.id) + '"?')) {
                                self.revokeShare(s.id);
                            }
                        };
                        actionCell.appendChild(revokeBtn);
                    });
                })
                .catch(function(e) {
                    console.error('SlimPing: failed to load share list', e);
                });
        },

        revokeShare: function(id) {
            var self = this;
            var resultEl = document.getElementById('sp-shares-result');
            spFetch('/plugins/SlimPing/settings/shares', {
                method: 'POST',
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify({ action: 'revoke', id: id })
            })
            .then(function(r) { return r.json(); })
            .then(function(data) {
                if (data.ok) {
                    if (resultEl) {
                        resultEl.textContent = 'Share revoked.';
                        resultEl.className = 'sp-save-result sp-save-ok';
                    }
                    self.loadShareList();
                } else {
                    if (resultEl) {
                        resultEl.textContent = data.error || 'Revoke failed.';
                        resultEl.className = 'sp-save-result sp-save-error';
                    }
                }
            });
        },

        revokeAll: function() {
            if (!confirm('Revoke ALL shares? This cannot be undone. Active streams will continue but new connections will fail.')) {
                return false;
            }
            var self = this;
            var resultEl = document.getElementById('sp-shares-result');
            spFetch('/plugins/SlimPing/settings/shares', {
                method: 'POST',
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify({ action: 'revoke_all' })
            })
            .then(function(r) { return r.json(); })
            .then(function(data) {
                if (data.ok) {
                    if (resultEl) {
                        resultEl.textContent = (data.revoked || 0) + ' share(s) revoked.';
                        resultEl.className = 'sp-save-result sp-save-ok';
                    }
                    self.loadShareList();
                } else {
                    if (resultEl) {
                        resultEl.textContent = data.error || 'Bulk revoke failed.';
                        resultEl.className = 'sp-save-result sp-save-error';
                    }
                }
            });
            return false;
        },

        saveSettings: function() {
            var resultEl = document.getElementById('sp-sharing-settings-result');
            var payload = {
                action: 'save_settings',
                share_min_ttl:         parseInt(document.getElementById('share_min_ttl').value, 10),
                share_default_ttl:     parseInt(document.getElementById('share_default_ttl').value, 10),
                share_max_ttl:         parseInt(document.getElementById('share_max_ttl').value, 10),
                share_max_bitrate:     parseInt(document.getElementById('share_max_bitrate').value, 10),
                share_user_cap:        parseInt(document.getElementById('share_user_cap').value, 10),
                share_global_cap:      parseInt(document.getElementById('share_global_cap').value, 10),
                share_max_listeners:   parseInt(document.getElementById('share_max_listeners').value, 10),
                share_max_unique_ips:  parseInt(document.getElementById('share_max_unique_ips').value, 10)
            };
            spFetch('/plugins/SlimPing/settings/shares', {
                method: 'POST',
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify(payload)
            })
            .then(function(r) { return r.json(); })
            .then(function(data) {
                if (data.ok) {
                    if (resultEl) {
                        resultEl.textContent = 'Settings saved.';
                        resultEl.className = 'sp-save-result sp-save-ok';
                    }
                } else {
                    if (resultEl) {
                        resultEl.textContent = data.error || 'Save failed.';
                        resultEl.className = 'sp-save-result sp-save-error';
                    }
                }
            });
            return false;
        }
    };

    // ===== DYNAMIC PLAYLISTS MODULE =====
    modules.DynamicPlaylists = {
        init: function() {
            var toggle = document.getElementById('pref_dpl_feature_enabled');
            var settings = document.getElementById('sp-dpl-settings');
            if (toggle && settings) {
                settings.style.display = toggle.value === '1' ? '' : 'none';
                toggle.addEventListener('change', function () {
                    var enabled = this.value === '1';
                    settings.style.display = enabled ? '' : 'none';
                    spFetch('/plugins/SlimPing/settings/dynamic_playlists', {
                        method: 'POST',
                        headers: { 'Content-Type': 'application/json' },
                        body: JSON.stringify({ feature_enabled: enabled }),
                    });
                });
            }

            var cacheTtl = document.getElementById('pref_dpl_cache_ttl');
            if (cacheTtl) {
                cacheTtl.addEventListener('change', function () {
                    spFetch('/plugins/SlimPing/settings/dynamic_playlists', {
                        method: 'POST',
                        headers: { 'Content-Type': 'application/json' },
                        body: JSON.stringify({ cache_ttl: parseInt(this.value, 10) || 300 }),
                    });
                });
            }
            var seedSize = document.getElementById('pref_dpl_seed_size');
            if (seedSize) {
                seedSize.addEventListener('change', function () {
                    spFetch('/plugins/SlimPing/settings/dynamic_playlists', {
                        method: 'POST',
                        headers: { 'Content-Type': 'application/json' },
                        body: JSON.stringify({ seed_size: parseInt(this.value, 10) || 100 }),
                    });
                });
            }
        },

        refreshRegistry: function() {
            var resultSpan = document.getElementById('sp-dpl-result');
            spFetch('/plugins/SlimPing/settings/dynamic_playlists', {
                method: 'POST',
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify({ refresh_registry: true }),
            })
            .then(function(r) { return r.json(); })
            .then(function(data) {
                if (data.registry_refreshed) {
                    resultSpan.textContent = 'Registry refreshed - ' + data.eligible_count + ' playlists eligible';
                    resultSpan.className = 'sp-save-result sp-save-ok';
                    setTimeout(function() { resultSpan.textContent = ''; }, 4000);
                }
            })
            .catch(function() {
                resultSpan.textContent = 'Refresh failed';
                resultSpan.className = 'sp-save-result sp-save-error';
            });
        },

        resetCaches: function() {
            if (!confirm('Reset all dynamic playlist caches and dedup history?')) { return false; }
            var resultSpan = document.getElementById('sp-dpl-flush-result');
            spFetch('/plugins/SlimPing/settings/dynamic_playlists', {
                method: 'POST',
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify({ reset_caches: true }),
            })
            .then(function(r) { return r.json(); })
            .then(function(data) {
                if (data.caches_cleared) {
                    resultSpan.textContent = 'Caches cleared';
                    resultSpan.className = 'sp-save-result sp-save-ok';
                    setTimeout(function() { resultSpan.textContent = ''; }, 3000);
                }
            })
            .catch(function() {
                resultSpan.textContent = 'Cache reset failed';
                resultSpan.className = 'sp-save-result sp-save-error';
            });
            return false;
        },

        setUserAccess: function(username, enabled) {
            spFetch('/plugins/SlimPing/settings/users', {
                method: 'POST',
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify({ action: 'set_dpl_access', username: username, dpl_access: enabled })
            }).then(function(r) { return r.json(); }).then(function(d) {
                if (!d.ok) { alert('Error saving DPL access: ' + (d.error || 'unknown')); }
            }).catch(function(e) { alert('Network error: ' + e.message); });
        }
    };

    return {
        init:               function()    { modules.init(); },
        createUser:         function()    { modules.Users.createUser(); },
        addApiKey:          function(u)   { modules.Users.addApiKey(u); },
        copyKey:            function(u)   { modules.Users.copyKey(u); },
        setAdmin:           function(u, e) { modules.Users.setAdmin(u, e); },
        setEnabled:              function(u, e) { modules.Users.setEnabled(u, e); },
        setScrobbleEnabled:     function(u, e) { modules.Users.setScrobbleEnabled(u, e); },
        setPlaycountSyncEnabled: function(u, e) { modules.Users.setPlaycountSyncEnabled(u, e); },
        setPlaybackLogging:     function(u, e) { modules.Users.setPlaybackLogging(u, e); },
        setAcceptPlaybackReport: function(u, e) { modules.Users.setAcceptPlaybackReport(u, e); },
        changePassword:     function(u)   { modules.Users.changePassword(u); },
        revokeApiKey:       function(u, k) { modules.Users.revokeApiKey(u, k); },
        toggleApiKeys:      function(u)   { modules.Users.toggleApiKeys(u); },
        setJukeboxPlayer:   function(sel) { modules.Jukebox.setPlayer(sel); },
        populateJukebox:    function()    { modules.Jukebox.populateSelects(); },
        saveExposure:       function()    { modules.Server.saveExposure(); },
        saveAdminAccess:    function()    { modules.Server.saveAdminAccess(); },
        saveTrustXff:       function()    { modules.Server.saveTrustXff(); },
        resetRateLimits:    function()    { modules.Server.resetRateLimits(); },
        saveLanMode:            function() { modules.Server.saveLanMode(); },
        saveAllowPlainPassword: function() { modules.Server.saveAllowPlainPassword(); },
        saveFeatures:         function()  { modules.Server.saveFeatures(); },
        saveScrobbleGateway:  function(v)  { modules.Server.saveScrobbleGateway(v); },
        saveScrobbleSource:   function(v)  { modules.Server.saveScrobbleSource(v); },
        populateRadioFolders: function()   { modules.RadioFolder.populate(); },
        saveRadioFolder:    function()     { modules.RadioFolder.save(); return false; },
        setUserRadioFolder: function(sel)  { modules.RadioFolder.setUserFolder(sel); },
        refreshNowPlaying:  function()    { modules.NowPlaying.refresh(); },
        refreshDbStats:     function()    { modules.DataManagement.refreshStats(); },
        refreshCacheStats:  function()    { modules.DataManagement.refreshCacheStats(); },
        flushStore:         function(t)   { modules.DataManagement.flushStore(t); },
        flushCache:         function()    { modules.DataManagement.flushCache(); },
        deleteUser:         function(u)   { modules.DataManagement.deleteUser(u); },
        resetDatabase:      function()    { modules.DataManagement.resetDatabase(); },
        cleanupVirtualPlayers: function() { modules.DataManagement.cleanupVirtualPlayers(); },
        cleanupOrphanedTracks: function() { modules.DataManagement.cleanupOrphanedTracks(); },
        restartServer:        function() { modules.DataManagement.restartServer(); },
        revokeShare:        function(id)  { modules.Sharing.revokeShare(id); },
        revokeAllShares:    function()    { modules.Sharing.revokeAll(); },
        saveSharingSettings: function()   { modules.Sharing.saveSettings(); },
        refreshDplRegistry:   function()    { modules.DynamicPlaylists.refreshRegistry(); },
        resetDplCaches:       function()    { modules.DynamicPlaylists.resetCaches(); },
        setDplAccess:         function(u, e) { modules.DynamicPlaylists.setUserAccess(u, e); }
    };

})();

// Global exports for inline event handlers
window.createUser = function() {
    SlimPingSettings.createUser();
    return false;
};

window.addApiKey = function(safe) {
    SlimPingSettings.addApiKey(safe);
    return false;
};

window.changePassword = function(username) {
    SlimPingSettings.changePassword(username);
    return false;
};

window.revokeApiKey = function(username, keyId) {
    SlimPingSettings.revokeApiKey(username, keyId);
    return false;
};

window.toggleApiKeys = function(safe) {
    SlimPingSettings.toggleApiKeys(safe);
    return false;
};

window.copyKey = function(safe) {
    SlimPingSettings.copyKey(safe);
    return false;
};

window.setAdmin = function(username, enabled) {
    SlimPingSettings.setAdmin(username, enabled);
};

window.setEnabled = function(username, enabled) {
    SlimPingSettings.setEnabled(username, enabled);
};

window.setScrobbleEnabled = function(username, enabled) {
    SlimPingSettings.setScrobbleEnabled(username, enabled);
};

window.setPlaycountSyncEnabled = function(username, enabled) {
    SlimPingSettings.setPlaycountSyncEnabled(username, enabled);
};

window.setPlaybackLogging = function(username, enabled) {
    SlimPingSettings.setPlaybackLogging(username, enabled);
};

window.setAcceptPlaybackReport = function(username, enabled) {
    SlimPingSettings.setAcceptPlaybackReport(username, enabled);
};

window.setDplAccess = function(username, enabled) {
    SlimPingSettings.setDplAccess(username, enabled);
};

window.setJukeboxPlayer = function(select) {
    SlimPingSettings.setJukeboxPlayer(select);
};

window.setUserRadioFolder = function(select) {
    SlimPingSettings.setUserRadioFolder(select);
};

window.saveScrobbleGateway = function(playerId) {
    SlimPingSettings.saveScrobbleGateway(playerId);
};

window.saveScrobbleSource = function(sourceType) {
    SlimPingSettings.saveScrobbleSource(sourceType);
};

window.saveAdminAccess = function() {
    SlimPingSettings.saveAdminAccess();
    return false;
};

window.saveTrustXff = function() {
    SlimPingSettings.saveTrustXff();
    return false;
};

window.resetRateLimits = function() {
    if (!confirm('Clear all in-memory auth rate-limit state?')) { return false; }
    SlimPingSettings.resetRateLimits();
    return false;
};

window.saveLanMode = function() {
    SlimPingSettings.saveLanMode();
    return false;
};

window.saveAllowPlainPassword = function() {
    SlimPingSettings.saveAllowPlainPassword();
    return false;
};

window.saveExposure = function() {
    SlimPingSettings.saveExposure();
    return false;
};

window.saveFeatures = function() {
    SlimPingSettings.saveFeatures();
    return false;
};

window.saveRadioFolder = function() {
    SlimPingSettings.saveRadioFolder();
    return false;
};

window.refreshNowPlaying = function() {
    SlimPingSettings.refreshNowPlaying();
    return false;
};

window.deleteUser = function(username) {
    SlimPingSettings.deleteUser(username);
    return false;
};

window.cleanupVirtualPlayers = function() {
    SlimPingSettings.cleanupVirtualPlayers();
    return false;
};

window.resetDatabase = function() {
    SlimPingSettings.resetDatabase();
    return false;
};

// Initialise on DOM ready
if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', function() { SlimPingSettings.init(); });
} else {
    SlimPingSettings.init();
}
