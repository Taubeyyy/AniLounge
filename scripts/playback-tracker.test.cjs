const { test } = require('node:test');
const assert = require('node:assert/strict');
const vm = require('node:vm');
const fs = require('node:fs');
const path = require('node:path');
const template = fs.readFileSync(path.join(__dirname, '../AniLounge/Resources/PlaybackTracker.js'), 'utf8');
function video(duration = 1440, src = 'https://cdn.example/episode.mp4?token=secret') {
    const handlers = {};
    return {
        playCalls: 0, play() { this.playCalls++; return Promise.resolve(); },
        duration, currentTime: 0, currentSrc: src, readyState: 1, paused: false, ended: false,
        seekable: { length: 1, start: () => 0, end: () => duration },
        addEventListener: (name, fn) => (handlers[name] ||= []).push(fn),
        emit(name) { (handlers[name] || []).forEach(fn => fn()); }
    };
}
function setup(videos, { seconds = 600, duration = 1440, resources = [], autoPlay = false, button = null } = {}) {
    const messages = [];
    const timers = [];
    let now = 10000;
    const window = { webkit: { messageHandlers: { aniProgress: { postMessage: x => messages.push(x) } } }, addEventListener() {} };
    const document = { baseURI: 'https://host.example/watch', documentElement: {}, querySelectorAll: () => videos, querySelector: () => button, addEventListener() {} };
    vm.runInNewContext(template.replace('__ANILOUNGE_CONFIG__', JSON.stringify({ token: 'test', seconds, duration, autoPlay })), {
        window, document, URL, Date: { now: () => now }, performance: { getEntriesByType: () => resources.map(name => ({ name })) },
        MutationObserver: class { observe() {} }, setTimeout: fn => timers.push(fn)
    });
    return { messages, window, runTimers: () => timers.splice(0).forEach(fn => fn()), tick: () => { now += 5000; }, progress: () => messages.filter(m => m.kind === 'progress'), sources: () => messages.filter(m => m.kind === 'source') };
}
test('restores position, reports signed source once, throttles and saves completion', () => {
    const v = video(); const env = setup([v]);
    assert.equal(v.currentTime, 600);
    assert.equal(env.messages.length, 0);
    v.emit('playing');
    assert.equal(env.progress()[0].seconds, 600);
    assert.equal(env.sources()[0].url, v.currentSrc);
    v.currentTime = 610; v.emit('timeupdate'); assert.equal(env.progress().length, 1);
    env.tick(); v.emit('timeupdate'); assert.equal(env.progress().at(-1).seconds, 610);
    assert.equal(env.sources().length, 1);
    v.currentTime = 1440; v.ended = true; v.emit('ended'); assert.equal(env.progress().at(-1).ended, true);
});
test('short advertisements and nonfinite media never become progress or sources', () => {
    for (const duration of [15, 89, Infinity, NaN]) {
        const v = video(duration); const env = setup([v]);
        v.emit('playing'); v.emit('timeupdate'); v.emit('pause');
        assert.equal(v.currentTime, 0); assert.equal(env.messages.length, 0);
    }
});
test('waits for seekable metadata and refuses mismatched episode lengths', () => {
    const v = video(); v.seekable.length = 0;
    setup([v]); assert.equal(v.currentTime, 0);
    v.seekable.length = 1; v.emit('canplay'); assert.equal(v.currentTime, 600);
    const other = video(120); setup([other]); other.emit('playing'); assert.equal(other.currentTime, 0);
});
test('shorter simultaneous clips cannot replace a playing episode', () => {
    const main = video(), ad = video(120); const env = setup([main, ad]);
    main.emit('playing'); ad.emit('playing'); ad.emit('pause');
    assert.equal(env.progress().length, 1); assert.equal(env.progress()[0].duration, 1440);
});
test('a single observed HLS manifest supports blob players; ambiguous sources stay in WebKit', () => {
    const manifest = 'https://cdn.example/master.m3u8?token=abc';
    const v = video(1440, 'blob:https://host.example/123'); const env = setup([v], { resources: [manifest, manifest] });
    v.emit('playing'); assert.equal(env.sources()[0].url, manifest);
    const other = video(1440, 'blob:https://host.example/456');
    const ambiguous = setup([other], { resources: ['https://cdn.example/a/index.m3u8', 'https://other.example/b/index.m3u8'] });
    other.emit('playing'); assert.equal(ambiguous.sources().length, 0);
});
test('VOE-style master plus variant playlists resolve to the master', () => {
    const master = 'https://edge.example/engine/hls/abc/master.m3u8?t=1';
    const variant = 'https://edge.example/engine/hls/abc/index-v1-a1.m3u8?t=1';
    const v = video(1440, 'blob:https://host.example/1'); const env = setup([v], { resources: [master, variant] });
    v.emit('playing'); assert.equal(env.sources()[0].url, master);
    const unnamed = video(1440, 'blob:https://host.example/2');
    const first = 'https://edge.example/x/playlist.m3u8', second = 'https://edge.example/x/720.m3u8';
    const env2 = setup([unnamed], { resources: [first, second] });
    unnamed.emit('playing'); assert.equal(env2.sources()[0].url, first);
});
test('native-to-web fallback can seek the same video and flushing saves latest time', () => {
    const v = video(); const env = setup([v]); v.emit('playing');
    env.window.aniLoungeSeek(800); assert.equal(v.currentTime, 800);
    env.window.aniLoungeFlush(); assert.equal(env.progress().at(-1).seconds, 800);
    env.window.aniLoungeSeek(NaN); assert.equal(v.currentTime, 800);
});


test('one-tap mode discovers the media URL and starts eligible media once without a page click', () => {
    const v = video(); const env = setup([v], { autoPlay: true });
    assert.equal(v.playCalls, 1);
    assert.equal(env.sources()[0].url, v.currentSrc);
    assert.equal(env.progress().length, 0); // Discovery is not evidence of viewing.
    v.emit('canplay'); v.emit('progress'); assert.equal(v.playCalls, 1);
    v.emit('playing'); assert.equal(env.progress()[0].seconds, 600);
});
test('one-tap mode does not auto-start short ads or take over another playing video', () => {
    const ad = video(30), main = video(), extra = video();
    const env = setup([ad, main, extra], { autoPlay: true });
    assert.equal(ad.playCalls, 0); assert.equal(main.playCalls, 1); assert.equal(extra.playCalls, 0);
    assert.equal(env.sources().length, 1);
});

test('preload="none" players are woken and started without a tap', () => {
    const v = video(NaN); v.readyState = 0; v.paused = true; v.preload = 'none';
    v.loadCalls = 0; v.load = function () { this.loadCalls++; };
    const env = setup([v], { autoPlay: true });
    assert.equal(v.preload, 'metadata'); assert.equal(v.loadCalls, 1);
    v.emit('loadstart'); assert.equal(v.loadCalls, 1, 'wakes only once');
    env.runTimers(); assert.equal(v.playCalls, 1);
});
test('the player big play button is pressed once when nothing plays; links never', () => {
    const v = video(NaN, ''); v.readyState = 0; v.paused = true;
    const button = { clicks: 0, click() { this.clicks++; }, closest: () => null };
    const env = setup([v], { autoPlay: true, button });
    env.runTimers(); assert.equal(button.clicks, 1); assert.equal(v.playCalls, 0, 'no source, nothing to play directly');
    const link = { clicks: 0, click() { this.clicks++; }, closest: () => ({}) };
    const other = video(NaN, ''); other.readyState = 0; other.paused = true;
    setup([other], { autoPlay: true, button: link }).runTimers(); assert.equal(link.clicks, 0);
    const off = { clicks: 0, click() { this.clicks++; }, closest: () => null };
    const manual = video(NaN, ''); manual.readyState = 0; manual.paused = true;
    setup([manual], { autoPlay: false, button: off }).runTimers(); assert.equal(off.clicks, 0);
});
test('MediaSource players (blob, e.g. JW Player on VOE) are never reloaded or started by the tracker', () => {
    const v = video(NaN, 'blob:https://host.example/stream'); v.readyState = 0; v.paused = true; v.preload = 'none';
    v.loadCalls = 0; v.load = function () { this.loadCalls++; };
    const env = setup([v], { autoPlay: true });
    v.emit('loadstart'); env.runTimers();
    assert.equal(v.loadCalls, 0, 'load() would drop the stream');
    assert.equal(v.preload, 'none');
    assert.equal(v.playCalls, 0, 'starting is left to the player API');
});
