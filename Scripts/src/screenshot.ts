// The screenshot overlay, as Firefox's: the page dims, the element under the
// pointer is outlined, and a click takes it or a drag takes a region; or
// Save Visible and Save Full Page at the top right. Swift awaits `run()`
// (Screenshot.swift) in Mote's own world and takes the picture once the
// overlay is gone.

import { elementName } from './element-picker/describe';

/** What was chosen: a region in page coordinates, with how far the page was scrolled. */
export type ShotChoice =
  | { kind: 'visible' | 'full' | 'cancel' }
  | { kind: 'copy' | 'save'; rect: [number, number, number, number]; scroll: [number, number] };

const STYLE = `
  :host { all: initial; }
  .dim { position: fixed; inset: 0; z-index: 2147483646; cursor: crosshair; background: rgba(0,0,0,.45);
    font: 13px -apple-system, BlinkMacSystemFont, sans-serif; color: #fff; }
  /* With a box out, its shadow dims the rest instead. */
  .dim.boxed { background: transparent; }
  .hint { position: fixed; left: 50%; top: 50%; transform: translate(-50%, -50%); text-align: center;
    font-size: 22px; font-weight: 500; line-height: 1.35; pointer-events: none; max-width: 520px; }
  .hint button { pointer-events: auto; margin-top: 18px; }
  .box { position: fixed; display: none; border: 2px dashed rgba(255,255,255,.95); border-radius: 3px;
    box-shadow: 0 0 0 99999px rgba(0,0,0,.45); pointer-events: none; }
  .tag { position: absolute; top: -24px; left: 0; background: #171717; color: #fff; font-size: 11px;
    padding: 2px 7px; border-radius: 5px; white-space: nowrap; }
  .corner { position: fixed; top: 12px; right: 12px; display: flex; gap: 8px; padding: 8px;
    background: rgba(40,40,40,.9); border-radius: 12px; }
  .actions { position: fixed; display: none; gap: 8px; }
  button { font: 500 12px -apple-system, BlinkMacSystemFont, sans-serif; color: #fff; background: rgba(60,60,60,.95);
    border: 1px solid rgba(255,255,255,.18); border-radius: 8px; padding: 7px 12px; cursor: default; }
  button:hover { background: rgba(85,85,85,.95); }
  button.main { background: #fff; color: #171717; }
`;

export function run(): Promise<ShotChoice> {
  return new Promise((resolve) => {
    const host = document.createElement('div');
    const root = host.attachShadow({ mode: 'closed' });
    root.innerHTML = `<style>${STYLE}</style>
      <div class="dim">
        <div class="box"><div class="tag"></div></div>
        <div class="hint">Drag or click on the page to select a region.<br>Press Esc to cancel.<br><button data-do="cancel">Cancel</button></div>
        <div class="corner"><button data-do="visible">Save Visible</button><button data-do="full">Save Full Page</button></div>
        <div class="actions"><button data-do="cancel">Cancel</button><button data-do="copy">Copy</button><button data-do="save" class="main">Download</button></div>
      </div>`;
    document.documentElement.appendChild(host);
    const dim = root.querySelector('.dim') as HTMLDivElement;
    const box = root.querySelector('.box') as HTMLDivElement;
    const tag = root.querySelector('.tag') as HTMLDivElement;
    const hint = root.querySelector('.hint') as HTMLDivElement;
    const actions = root.querySelector('.actions') as HTMLDivElement;

    let picked: DOMRect | null = null;
    let hovered: DOMRect | null = null;
    let start: { x: number; y: number } | null = null;

    const show = (rect: DOMRect, label: string): void => {
      box.style.display = 'block';
      dim.classList.add('boxed');
      Object.assign(box.style, {
        left: `${rect.left}px`,
        top: `${rect.top}px`,
        width: `${rect.width}px`,
        height: `${rect.height}px`,
      });
      tag.textContent = label;
      tag.style.display = label ? 'block' : 'none';
    };

    /** What's under the overlay at a point. */
    const under = (x: number, y: number): Element | null => {
      host.style.pointerEvents = 'none';
      const found = document.elementFromPoint(x, y);
      host.style.pointerEvents = '';
      return found === document.documentElement || found === document.body ? null : found;
    };

    const finish = (choice: ShotChoice): void => {
      document.removeEventListener('keydown', onKey, true);
      host.remove();
      // Two frames, so the picture is taken of the page without the overlay.
      requestAnimationFrame(() => requestAnimationFrame(() => resolve(choice)));
    };

    const onKey = (event: KeyboardEvent): void => {
      if (event.key !== 'Escape') return;
      event.preventDefault();
      event.stopPropagation();
      finish({ kind: 'cancel' });
    };
    document.addEventListener('keydown', onKey, true);

    root.addEventListener('click', (event) => {
      const what = (event.target as HTMLElement).closest('button')?.dataset.do;
      if (!what) return;
      event.stopPropagation();
      if (what === 'copy' || what === 'save') {
        if (!picked) return;
        finish({
          kind: what,
          rect: [picked.left + scrollX, picked.top + scrollY, picked.width, picked.height],
          scroll: [scrollX, scrollY],
        });
      } else {
        finish({ kind: what as 'visible' | 'full' | 'cancel' });
      }
    });

    dim.addEventListener('mousemove', (event) => {
      if (picked) return;
      if (start && event.buttons & 1) {
        const left = Math.min(start.x, event.clientX);
        const top = Math.min(start.y, event.clientY);
        show(
          new DOMRect(left, top, Math.abs(event.clientX - start.x), Math.abs(event.clientY - start.y)),
          '',
        );
        return;
      }
      const element = under(event.clientX, event.clientY);
      hovered = element ? element.getBoundingClientRect() : null;
      if (element && hovered) {
        show(hovered, elementName(element));
      } else {
        box.style.display = 'none';
        dim.classList.remove('boxed');
      }
    });

    dim.addEventListener('mousedown', (event) => {
      if (picked || (event.target as HTMLElement).closest('button')) return;
      event.preventDefault();
      start = { x: event.clientX, y: event.clientY };
    });

    dim.addEventListener('mouseup', (event) => {
      if (picked || !start) return;
      const dragged = Math.abs(event.clientX - start.x) > 4 || Math.abs(event.clientY - start.y) > 4;
      const rect = dragged
        ? new DOMRect(
            Math.min(start.x, event.clientX),
            Math.min(start.y, event.clientY),
            Math.abs(event.clientX - start.x),
            Math.abs(event.clientY - start.y),
          )
        : hovered;
      start = null;
      if (!rect || rect.width < 2 || rect.height < 2) return;
      picked = rect;
      show(rect, '');
      hint.style.display = 'none';
      // Under the selection, or inside its foot when it reaches the window's bottom.
      const top = Math.min(rect.bottom + 8, innerHeight - 44);
      Object.assign(actions.style, {
        display: 'flex',
        top: `${top}px`,
        left: `${Math.max(8, Math.min(rect.right - 230, innerWidth - 238))}px`,
      });
    });
  });
}
