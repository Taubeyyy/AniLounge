// Isolated WebKit world, in every frame. Only report media that actually starts playing.
(() => {
    const config = __ANILOUNGE_CONFIG__;
    const states = new WeakMap();
    let primary = null;
    let lastSent = 0;
    const eligible = v => Number.isFinite(v.duration) && v.duration >= 90 && v.duration <= 86400;
    const later = typeof setTimeout === 'function' ? setTimeout : null;
    // Big play buttons of common hoster players. Only these controls are ever clicked, never links.
    const PLAY_BUTTONS = '.vjs-big-play-button, .jw-display-icon-display, .plyr__control--overlaid, .fp-ui .fp-play, button[aria-label="Play"]';
    const hasSource = v => !!(v.currentSrc || v.src || (typeof v.querySelector === 'function' && v.querySelector('source[src]')));
    const playing = () => [...document.querySelectorAll('video')].some(v => !v.paused && v.readyState > 1);
    function direct(value) {
        try {
            const u = new URL(value, document.baseURI);
            return u.protocol === 'https:' && !u.username && !u.password && /\.(mp4|m4v|m3u8)$/i.test(u.pathname) ? u.href : null;
        } catch (_) { return null; }
    }
    function source(v) {
        const state = states.get(v);
        if ((!state.played && !config.autoPlay) || !eligible(v) || primary !== v) return;
        let url = direct(v.currentSrc || v.src);
        // MSE may expose a blob URL. Use the frame's HLS manifest when it is unambiguous:
        // one manifest, a single "master" playlist, or playlists that all live in one folder
        // (master plus its variants, as VOE serves them) where the first loaded is the master.
        if (!url && (v.currentSrc || '').startsWith('blob:')) {
            const manifests = [...new Set(performance.getEntriesByType('resource')
                .map(e => direct(e.name)).filter(u => u && new URL(u).pathname.toLowerCase().endsWith('.m3u8')))];
            const folder = u => { const p = new URL(u); return p.origin + p.pathname.replace(/[^/]*$/, ''); };
            const masters = manifests.filter(u => /master[^/]*\.m3u8$/i.test(new URL(u).pathname));
            if (manifests.length === 1) url = manifests[0];
            else if (masters.length === 1) url = masters[0];
            else if (manifests.length > 1 && new Set(manifests.map(folder)).size === 1) url = manifests[0];
        }
        if (!url || state.source === url) return;
        state.source = url;
        window.webkit.messageHandlers.aniProgress.postMessage({ token: config.token, kind: 'source', url });
    }
    function report(v, force = false) {
        const state = states.get(v);
        if (!state || !state.played || !eligible(v) || primary !== v || !Number.isFinite(v.currentTime)) return;
        if (!force && Date.now() - lastSent < 5000) return;
        lastSent = Date.now();
        window.webkit.messageHandlers.aniProgress.postMessage({
            token: config.token, kind: 'progress', seconds: v.currentTime, duration: v.duration, ended: v.ended === true
        });
        source(v);
    }
    function restore(v) {
        const state = states.get(v);
        if (state.restored || !eligible(v) || v.readyState < 1 || v.seekable.length === 0) return;
        const matches = !config.duration || Math.abs(v.duration - config.duration) <= Math.max(45, config.duration * 0.08);
        if (!matches) { state.restored = true; return; }
        const target = Math.min(config.seconds || 0, Math.max(0, v.duration - 1));
        if (target <= 0 || v.currentTime > 3) { state.restored = true; return; }
        for (let i = 0; i < v.seekable.length; i++) {
            if (v.seekable.start(i) <= target && target <= v.seekable.end(i)) {
                try { v.currentTime = target; state.restored = true; } catch (_) { /* retry when playable */ }
                return;
            }
        }
    }
    function attach(v) {
        if (states.has(v)) return;
        states.set(v, { played: false, restored: false, source: null });
        v.addEventListener('playing', () => {
            if (!eligible(v)) return;
            if (primary && primary !== v && !primary.paused && primary.duration > v.duration) return;
            primary = v; states.get(v).played = true; restore(v); report(v, true);
        });
        function tryStart() {
            restore(v);
            const state = states.get(v);
            if (!config.autoPlay || state.autoAttempted || !eligible(v) || v.readyState < 1) return;
            if (primary && primary !== v) return;
            state.autoAttempted = true; primary = v; source(v);
            const promise = v.play();
            if (promise && promise.catch) promise.catch(() => {});
        }
        // Players with preload="none" never load metadata on their own: ask for it once.
        function wake() {
            const state = states.get(v);
            if (!config.autoPlay || state.woken || v.readyState > 0 || !hasSource(v)) return;
            state.woken = true;
            try { if (v.preload === 'none') v.preload = 'metadata'; if (typeof v.load === 'function') v.load(); } catch (_) {}
        }
        ['loadedmetadata', 'canplay', 'progress'].forEach(event => v.addEventListener(event, tryStart));
        ['loadstart', 'suspend', 'emptied'].forEach(event => v.addEventListener(event, wake));
        wake();
        v.addEventListener('timeupdate', () => { if (states.get(v).played) restore(v); report(v); });
        ['pause', 'ended'].forEach(event => v.addEventListener(event, () => report(v, true)));
        restore(v);
        tryStart();
    }
    function scan() { document.querySelectorAll('video').forEach(attach); }
    scan();
    // Fallbacks so the viewer never needs an extra tap: start a sourced video that still has
    // no metadata, then press the player's own big play button if nothing runs yet.
    if (config.autoPlay && later) {
        later(() => {
            if (primary || playing()) return;
            document.querySelectorAll('video').forEach(v => {
                const state = states.get(v);
                if (!state || state.autoAttempted || v.readyState > 0 || !hasSource(v)) return;
                state.autoAttempted = true;
                const promise = v.play();
                if (promise && promise.catch) promise.catch(() => {});
            });
        }, 1800);
        later(() => {
            if (primary || playing() || typeof document.querySelector !== 'function') return;
            const button = document.querySelector(PLAY_BUTTONS);
            if (button && !(button.closest && button.closest('a')) && typeof button.click === 'function') button.click();
        }, 3600);
    }
    new MutationObserver(scan).observe(document.documentElement, { childList: true, subtree: true });
    window.addEventListener('pagehide', () => { if (primary) report(primary, true); });
    document.addEventListener('visibilitychange', () => { if (primary) report(primary, true); });
    window.aniLoungeSeek = seconds => {
        if (primary && Number.isFinite(seconds) && eligible(primary)) {
            try { primary.currentTime = Math.min(Math.max(0, seconds), primary.duration - 1); } catch (_) {}
        }
    };
    window.aniLoungeFlush = () => { if (primary) report(primary, true); };
})();

