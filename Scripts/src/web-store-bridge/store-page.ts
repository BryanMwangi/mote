/** Marks the elements the bridge has handled, with what they are. */
export type Mark = 'add' | 'theirs' | 'banner' | 'promo';

/** Our "Add to Mote" button. */
export const OUR_BUTTON = 'button[data-mote="add"]';

/** Extensions Mote has, and the one it is installing, as Swift reports them. */
export interface StoreState {
  installed: string[];
  busy: string | null;
}

/** A banner taller in text than this is more than a banner: it has reached the header. */
const MAX_BANNER_TEXT = 160;

/** Attributes that tie the store's button to the store's own handlers, or disable it. */
const STORE_ATTRIBUTES = ['disabled', 'jsaction', 'jscontroller', 'jsname', 'jslog', 'aria-describedby'];

/**
 * The extension id in a store page's path (`/detail/<slug>/<id>` or
 * `/detail/<id>`, then perhaps more of the path), or null elsewhere. This only decides what the button shows:
 * Swift installs from the tab's own URL, never from anything the page says.
 */
export function extensionID(pathname: string): string | null {
  const match = pathname.match(/\/detail\/(?:[^/]+\/)?([a-p]{32})(?:\/|$)/);
  return match?.[1] ?? null;
}

/** The store's own install button: disabled in other browsers, and mentioning Chrome. */
export function storeInstallButton(document: Document): HTMLButtonElement | null {
  for (const button of document.querySelectorAll<HTMLButtonElement>('button[disabled]')) {
    if (!button.dataset.mote && /chrome/i.test(button.textContent || '')) return button;
  }
  return null;
}

/**
 * The banner around `button`: from the button up, as far as it goes without
 * taking in the header beside it — short, and holding no install button.
 */
export function bannerAround(button: Element): HTMLElement | null {
  let banner: HTMLElement | null = null;
  let up = button.parentElement;
  while (up && up !== button.ownerDocument.body) {
    if (up.querySelector('button[disabled], button[data-mote]')) break;
    if ((up.innerText || '').length > MAX_BANNER_TEXT) break;
    banner = up;
    up = up.parentElement;
  }
  return banner;
}

/**
 * Hides the "Switch to Chrome" prompts: the floating card, known by the Chrome
 * logo it carries in any language — it sits right over the button — and the
 * banner around each enabled button whose label mentions Chrome.
 */
export function hidePromotions(document: Document): void {
  for (const card of document.querySelectorAll<HTMLElement>('[role="dialog"]')) {
    if (!card.dataset.mote && card.querySelector('img[src*="productlogos/chrome"]')) {
      card.style.display = 'none';
      mark(card, 'promo');
    }
  }
  for (const button of document.querySelectorAll<HTMLButtonElement>('button:not([disabled])')) {
    if (button.dataset.mote || !/chrome/i.test(button.getAttribute('aria-label') || '')) continue;
    const banner = bannerAround(button);
    if (banner && !banner.dataset.mote) {
      banner.style.display = 'none';
      mark(banner, 'banner');
    }
  }
}

/**
 * Hides the store's install button and puts a copy beside it, stripped of what
 * disables it and ties it to the store's handlers, so it keeps the store's own
 * shape and colour. Returns the copy.
 */
export function replaceInstallButton(original: HTMLButtonElement, parent: ParentNode): HTMLButtonElement {
  const ours = original.cloneNode(true) as HTMLButtonElement;
  for (const name of STORE_ATTRIBUTES) ours.removeAttribute(name);
  mark(ours, 'add');
  mark(original, 'theirs');
  original.style.display = 'none';
  parent.insertBefore(ours, original.nextSibling);
  return ours;
}

/** What our button says for the extension `id`, and whether it can be pressed. */
export function buttonState(state: StoreState, id: string | null): { label: string; disabled: boolean } {
  const installed = !!id && state.installed.includes(id);
  const busy = !!id && state.busy === id;
  return {
    label: installed ? 'Added to Mote' : busy ? 'Adding…' : 'Add to Mote',
    disabled: installed || busy,
  };
}

/** Replaces the button's last words only, so it keeps the store's icon and layout. */
export function setLabel(button: HTMLElement, text: string): void {
  const walker = button.ownerDocument.createTreeWalker(button, NodeFilter.SHOW_TEXT);
  let last: Node | null = null;
  for (let node = walker.nextNode(); node; node = walker.nextNode()) {
    if (node.nodeValue?.trim()) last = node;
  }
  if (last) last.nodeValue = text;
  else button.textContent = text;
}

function mark(element: HTMLElement, what: Mark): void {
  element.dataset.mote = what;
}

/**
 * addons.mozilla.org: the add-on's id as Mote keeps it ("amo-" and its slug,
 * kept to letters, digits and dashes; InstalledExtension.firefoxID).
 */
export function amoID(pathname: string): string | null {
  const slug = /\/addon\/([^/]+)/.exec(pathname)?.[1];
  return slug
    ? 'amo-' +
        decodeURIComponent(slug)
          .toLowerCase()
          .replace(/[^a-z0-9-]/g, '')
    : null;
}

/** addons.mozilla.org's "Download Firefox and get the extension", not yet replaced. */
export function amoGetFirefoxButton(document: Document): HTMLElement | null {
  return document.querySelector<HTMLElement>('a.GetFirefoxButton-button:not([data-mote])');
}

/** Puts "Add to Mote" in place of that link, in its own style, and hides it. */
export function replaceAMOButton(original: HTMLElement): HTMLButtonElement {
  const ours = original.ownerDocument.createElement('button');
  ours.className = original.className;
  ours.textContent = 'Add to Mote';
  mark(ours, 'add');
  mark(original, 'theirs');
  original.style.display = 'none';
  original.parentNode?.insertBefore(ours, original.nextSibling);
  return ours;
}
