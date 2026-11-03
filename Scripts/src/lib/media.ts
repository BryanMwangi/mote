// What the media strip needs from a page: which media element is the one
// playing (or last played), and a short report of it for Swift.

/** What Mote's media strip shows, sent to Swift as JSON. */
export interface MediaReport {
  /** The track's title, or the page's when the site gives none. */
  title: string;
  artist: string;
  playing: boolean;
  /** The media session actions the site handles itself. */
  actions: string[];
}

/** Titles and names are cut to this many characters. */
export const LIMIT = 200;

/**
 * The element the strip controls: one playing with sound, else one playing
 * at all, else the one furthest into its media (paused part way).
 */
export function currentMedia(root: ParentNode): HTMLMediaElement | null {
  const all = [...root.querySelectorAll<HTMLMediaElement>('video, audio')];
  const playing = all.filter((media) => !media.paused && !media.ended);
  return (
    playing.find((media) => !media.muted && media.volume > 0) ??
    playing[0] ??
    all
      .filter((media) => media.currentTime > 0 && !media.ended)
      .toSorted((a, b) => b.currentTime - a.currentTime)[0] ??
    null
  );
}

function clip(text: string | undefined): string {
  return (text ?? '').trim().slice(0, LIMIT);
}

/** The report for `media`, or null when there is nothing to control. */
export function describe(
  media: HTMLMediaElement | null,
  metadata: { title?: string; artist?: string } | null | undefined,
  pageTitle: string,
  actions: Iterable<string>,
): MediaReport | null {
  if (!media) return null;
  return {
    title: clip(metadata?.title) || clip(pageTitle),
    artist: clip(metadata?.artist),
    playing: !media.paused && !media.ended,
    actions: [...actions].toSorted(),
  };
}
