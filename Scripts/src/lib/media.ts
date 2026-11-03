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
  /** The site describes what plays (`mediaSession.metadata`) or handles its
   * controls: a player, not a decoration. */
  session: boolean;
}

/** Titles and names are cut to this many characters. */
export const LIMIT = 200;

/** WebKit's count of audio bytes decoded, where it has one. */
type Decoding = HTMLMediaElement & { webkitAudioDecodedByteCount?: number };

/**
 * Whether an element can be heard: not muted, not at zero volume, and, once
 * it has played a couple of seconds, with some audio decoded. Muted autoplay
 * backgrounds and GIF-like videos aren't.
 */
export function audible(media: HTMLMediaElement): boolean {
  if (media.muted || media.volume === 0) return false;
  const decoded = (media as Decoding).webkitAudioDecodedByteCount;
  return typeof decoded !== 'number' || decoded > 0 || media.currentTime < 2;
}

/**
 * The element the strip controls: one playing that can be heard, else the
 * audible one furthest into its media (paused part way). Silent ones never.
 */
export function currentMedia(root: ParentNode): HTMLMediaElement | null {
  const all = [...root.querySelectorAll<HTMLMediaElement>('video, audio')].filter(audible);
  return (
    all.find((media) => !media.paused && !media.ended) ??
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
  const handled = [...actions].toSorted();
  return {
    title: clip(metadata?.title) || clip(pageTitle),
    artist: clip(metadata?.artist),
    playing: !media.paused && !media.ended,
    actions: handled,
    session: Boolean(metadata?.title) || handled.length > 0,
  };
}
