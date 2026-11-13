import { describe as suite, expect, it } from 'vitest';

import { audible, currentMedia, describe, LIMIT } from '../src/lib/media';

function media(
  kind: 'video' | 'audio',
  state: { paused?: boolean; muted?: boolean; time?: number; volume?: number; decoded?: number },
): HTMLMediaElement {
  const element = document.createElement(kind);
  Object.defineProperty(element, 'paused', { value: state.paused ?? true });
  Object.defineProperty(element, 'ended', { value: false });
  Object.defineProperty(element, 'muted', { value: state.muted ?? false });
  Object.defineProperty(element, 'currentTime', { value: state.time ?? 0 });
  Object.defineProperty(element, 'volume', { value: state.volume ?? 1 });
  if (state.decoded !== undefined) {
    Object.defineProperty(element, 'webkitAudioDecodedByteCount', { value: state.decoded });
  }
  document.body.append(element);
  return element;
}

suite('media strip', () => {
  it('leaves muted, silent and soundless videos alone, as backgrounds and GIFs are', () => {
    document.body.innerHTML = '';
    media('video', { paused: false, muted: true, time: 30 });
    media('video', { paused: false, volume: 0, time: 30 });
    media('video', { paused: false, time: 30, decoded: 0 });
    expect(currentMedia(document)).toBeNull();
    expect(audible(media('video', { paused: false, time: 1, decoded: 0 }))).toBe(true);
    expect(audible(media('video', { paused: false, time: 30, decoded: 5000 }))).toBe(true);
  });

  it('controls what plays with sound before what plays muted', () => {
    document.body.innerHTML = '';
    media('video', { paused: false, muted: true });
    const heard = media('audio', { paused: false });
    expect(currentMedia(document)).toBe(heard);
  });

  it('falls back to what was paused part way', () => {
    document.body.innerHTML = '';
    media('video', {});
    const paused = media('audio', { time: 42 });
    expect(currentMedia(document)).toBe(paused);
  });

  it('has nothing to control on a page with untouched media', () => {
    document.body.innerHTML = '';
    media('video', {});
    expect(currentMedia(document)).toBeNull();
    expect(describe(null, null, 'Page', [])).toBeNull();
  });

  it('controls a player playing outside the page', () => {
    document.body.innerHTML = '';
    const outside = media('audio', { paused: false });
    outside.remove();
    expect(currentMedia(document)).toBeNull();
    expect(currentMedia(document, [outside])).toBe(outside);
  });

  it('takes a site that plays and pauses its own track for a player, with no element in sight', () => {
    const track = { title: 'Song', artist: 'Band' };
    expect(describe(null, track, 'Page', ['pause', 'play'], 'paused')).toMatchObject({
      title: 'Song',
      playing: false,
    });
    expect(describe(null, track, 'Page', ['pause', 'play'], 'playing')?.playing).toBe(true);
    expect(describe(null, track, 'Page', ['play'], 'playing')).toBeNull();
    expect(describe(null, null, 'Page', ['pause', 'play'], 'playing')).toBeNull();
    expect(describe(null, track, 'Page', ['pause', 'play'], 'none')).toBeNull();
  });

  it('prefers the session title, and cuts long ones', () => {
    document.body.innerHTML = '';
    const playing = media('audio', { paused: false });
    expect(describe(playing, { title: 'Song', artist: 'Band' }, 'Page', ['nexttrack'])).toEqual({
      title: 'Song',
      artist: 'Band',
      playing: true,
      actions: ['nexttrack'],
      session: true,
      video: false,
    });
    expect(describe(playing, null, 'Page', [])?.session).toBe(false);
    expect(describe(playing, null, 'x'.repeat(500), [])?.title.length).toBe(LIMIT);
  });
});
