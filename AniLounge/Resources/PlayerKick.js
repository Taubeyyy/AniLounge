// Page world, every frame. Hoster players such as JW Player (VOE) or video.js only load their
// HLS stream after their own play() runs, which the isolated tracker cannot reach. Ask the
// player API to start, a few times during the first seconds, and stop once anything plays.
// Nothing here clicks the page or follows links.
(() => {
    if (window.__aniLoungeKick) return;
    window.__aniLoungeKick = true;
    let tries = 0;
    const quiet = promise => { if (promise && typeof promise.catch === 'function') promise.catch(() => {}); };
    const running = () => [...document.querySelectorAll('video')].some(v => !v.paused && v.currentTime > 0);
    const timer = setInterval(() => {
        tries += 1;
        if (running() || tries > 24) { clearInterval(timer); return; }
        try {
            if (typeof window.jwplayer === 'function') {
                const jw = window.jwplayer();
                if (jw && typeof jw.getState === 'function') {
                    const state = jw.getState();
                    if (state === 'playing' || state === 'buffering') { clearInterval(timer); return; }
                    if (state === 'idle' || state === 'paused') { if (typeof jw.setMute === 'function') jw.setMute(false); jw.play(true); }
                }
            }
            if (window.videojs && typeof window.videojs.getPlayers === 'function') {
                Object.values(window.videojs.getPlayers()).filter(Boolean).forEach(p => { if (p.paused && p.paused()) quiet(p.play()); });
            }
        } catch (_) { /* hoster scripts change often; never break the page */ }
    }, 750);
})();
