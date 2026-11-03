import { describe as suite, expect, it } from 'vitest';

import { currentMedia, describe, LIMIT } from '../src/lib/media';

function media(
  kind: 'video' | 'audio',
  state: { paused?: boolean; muted?: boolean; time?: number },
): HTMLMediaElement {
  const element = document.createElement(kind);
  Object.defineProperty(element, 'paused', { value: state.paused ?? true });
  Object.defineProperty(element, 'ended', { value: false });
  Object.defineProperty(element, 'muted', { value: state.muted ?? false });
  Object.defineProperty(element, 'currentTime', { value: state.time ?? 0 });
  document.body.append(element);
  return element;
}

suite('media strip', () => {
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

  it('prefers the session title, and cuts long ones', () => {
    document.body.innerHTML = '';
    const playing = media('audio', { paused: false });
    expect(describe(playing, { title: 'Song', artist: 'Band' }, 'Page', ['nexttrack'])).toEqual({
      title: 'Song',
      artist: 'Band',
      playing: true,
      actions: ['nexttrack'],
    });
    expect(describe(playing, null, 'x'.repeat(500), [])?.title.length).toBe(LIMIT);
  });
});
