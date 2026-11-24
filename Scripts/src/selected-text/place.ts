/** Where a selection sits on its page: the passage around it, and the heading it falls under. */
export interface SelectionPlace {
  around: string;
  heading: string;
}

const BLOCK =
  'p, li, td, th, dd, dt, blockquote, pre, figcaption, h1, h2, h3, h4, h5, h6, article, section, div';
const HEADINGS = 'h1, h2, h3, h4, h5, h6';
/** How much of the passage, around the selection, at most. */
const ROOM = 600;

/**
 * The selection's place in `document`, or null with nothing selected: the
 * text of the block it starts in, cut to about 600 characters around it, and
 * the nearest heading before that block. Enough for an assistant to tell
 * which part of the page is meant, without the whole page.
 */
export function selectionPlace(document: Document): SelectionPlace | null {
  const selection = document.getSelection();
  const chosen = selection?.toString().trim() ?? '';
  if (!selection || selection.rangeCount === 0 || !chosen) return null;
  const start = selection.getRangeAt(0).startContainer;
  const element = start instanceof Element ? start : start.parentElement;
  const block = element?.closest(BLOCK) ?? document.body;
  const text = (block?.textContent ?? '').replaceAll(/\s+/g, ' ').trim();
  const at = Math.max(0, text.indexOf(chosen.replaceAll(/\s+/g, ' ').slice(0, 40)));
  const from = Math.max(0, Math.min(at - ROOM / 3, text.length - ROOM));
  const around =
    (from > 0 ? '…' : '') + text.slice(from, from + ROOM) + (from + ROOM < text.length ? '…' : '');
  let heading = '';
  for (const candidate of document.querySelectorAll(HEADINGS)) {
    const before =
      candidate === block || !!(candidate.compareDocumentPosition(block!) & Node.DOCUMENT_POSITION_FOLLOWING);
    if (!before) break;
    heading = (candidate.textContent ?? '').replaceAll(/\s+/g, ' ').trim();
  }
  return { around, heading };
}
