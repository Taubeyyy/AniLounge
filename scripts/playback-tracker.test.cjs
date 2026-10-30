const { test } = require('node:test');
const assert = require('node:assert/strict');
const vm = require('node:vm');
const fs = require('node:fs');
const path = require('node:path');
const template = fs.readFileSync(path.join(__dirname, '../AniLounge/Resources/PlaybackTracker.js'), 'utf8');
function video(duration = 1440, src = 'https://cdn.example/episode.mp4?token=secret') {
    const handlers = {};
    return {
        duration, currentTime: 0, currentSrc: src, readyState: 1, paused: false, ended: false,
        seekable: { length: 1, start: () => 0, end: () => duration },
        addEventListener: (name, fn) => (handlers[name] ||= []).push(fn),
        emit(name) { (handlers[name] || []).forEach(fn => fn()); }
    };
}
function setup(videos, { seconds = 600, duration = 1440, resources = [] } = {}) {
    const messages = [];
    let now = 10000;
    const window = { webkit: { messageHandlers: { aniProgress: { postMessage: x => messages.push(x) } } }, addEventListener() {} };
    const document = { baseURI: 'https://host.example/watch', documentElement: {}, querySelectorAll: () => videos, addEventListener() {} };
    vm.runInNewContext(template.replace('__ANILOUNGE_CONFIG__', JSON.stringify({ token: 'test', seconds, duration })), {
        window, document, URL, Date: { now: () => now }, performance: { getEntriesByType: () => resources.map(name => ({ name })) },
        MutationObserver: class { observe() {} }
    });
    return { messages, window, tick: () => { now += 5000; }, progress: () => messages.filter(m => m.kind === 'progress'), sources: () => messages.filter(m => m.kind === 'source') };
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
    const ambiguous = setup([other], { resources: [manifest, 'https://cdn.example/another.m3u8'] });
    other.emit('playing'); assert.equal(ambiguous.sources().length, 0);
});
test('native-to-web fallback can seek the same video and flushing saves latest time', () => {
    const v = video(); const env = setup([v]); v.emit('playing');
    env.window.aniLoungeSeek(800); assert.equal(v.currentTime, 800);
    env.window.aniLoungeFlush(); assert.equal(env.progress().at(-1).seconds, 800);
    env.window.aniLoungeSeek(NaN); assert.equal(v.currentTime, 800);
});
