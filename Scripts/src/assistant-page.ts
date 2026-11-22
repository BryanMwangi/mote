// What the assistant does inside a page, on its behalf (AssistantTools+Page.swift):
// the numbered list of what can be clicked or typed into, and clicking, typing,
// choosing, ticking, scrolling, finding and reading tables there.
//
// Run on demand in Mote's own world, never the page's, so the page can't see
// or change the list. A number keeps meaning the same element until the page
// goes away: elements found later are numbered after, never in between.

export type Args = {
  n?: number;
  text?: string;
  how?: 'replace' | 'insert' | 'append';
  value?: string;
  on?: boolean;
  to?: 'top' | 'bottom';
  by?: number;
  key?: string;
  label?: string;
};

declare global {
  interface Window {
    __moteOutline?: Element[];
  }
}

const PICKABLE =
  'a[href],button,input:not([type=hidden]),select,textarea,summary,[role=button],[role=link],[role=checkbox],[role=tab],[role=menuitem],[contenteditable=""],[contenteditable=true]';
/** The most elements listed at once, and the most of a list's or table's text. */
const MOST = 250;
const MOST_TEXT = 20000;

function shown(item: Element): boolean {
  const box = item.getBoundingClientRect();
  return box.width > 0 && box.height > 0;
}

function isPassword(item: Element): boolean {
  return item instanceof HTMLInputElement && item.type === 'password';
}

/** An editor the page draws itself (an email's body), as the browser marks it. */
function isEditor(item: Element): boolean {
  const said = item.getAttribute('contenteditable');
  return (item as HTMLElement).isContentEditable || said === '' || said === 'true';
}

/** What an element says it is, briefly, for the list and the person's question. */
export function describe(item: Element): string {
  const input = item as HTMLInputElement;
  // A list's text is every option's; what it's called is elsewhere.
  const said =
    (item instanceof HTMLSelectElement ? '' : (item as HTMLElement).innerText) ||
    item.getAttribute('aria-label') ||
    input.placeholder ||
    item.getAttribute('title') ||
    input.name ||
    (['submit', 'button'].includes(input.type) ? input.value : '') ||
    '';
  return said.trim().replace(/\s+/g, ' ').slice(0, 80);
}

/** A form field, or a widget that stands for one, as opposed to a link or button. */
function isField(item: Element): boolean {
  if (item instanceof HTMLInputElement) return !['submit', 'button', 'reset', 'image'].includes(item.type);
  return (
    item instanceof HTMLSelectElement ||
    item instanceof HTMLTextAreaElement ||
    isEditor(item) ||
    ['combobox', 'textbox', 'listbox'].includes(item.getAttribute('role') ?? '')
  );
}

/** Words for the list, kept short and on one line. */
function brief(said: string, most = 60): string {
  const line = said.trim().replace(/\s+/g, ' ');
  return line.length > most ? `${line.slice(0, most - 1)}…` : line;
}

/** What a field holds now, as the person sees it: a list's chosen option by
 * what it says (its value when it says nothing), never a password. */
export function shownValue(item: Element): string | null {
  if (item instanceof HTMLSelectElement) {
    const option = item.options[item.selectedIndex];
    if (!option) return '';
    return option.text.trim() || option.value;
  }
  if (item instanceof HTMLInputElement) {
    if (['checkbox', 'radio'].includes(item.type)) return null;
    if (item.type === 'password') return item.value ? '••••' : '';
    if (item.type === 'file') return [...(item.files ?? [])].map((file) => file.name).join(', ');
    return item.value;
  }
  if (item instanceof HTMLTextAreaElement) return item.value;
  if (isField(item)) return (item as HTMLElement).innerText ?? '';
  return null;
}

/** Required, and whether the page or the browser finds it wrong, with why. */
function validity(item: Element): string {
  const field = item as HTMLInputElement;
  const notes: string[] = [];
  if (field.required || item.getAttribute('aria-required') === 'true') notes.push('required');
  const wrong = field.validity ? !field.validity.valid : false;
  if (wrong || item.getAttribute('aria-invalid') === 'true') {
    notes.push(field.validationMessage ? `invalid: ${brief(field.validationMessage)}` : 'invalid');
  }
  return notes.length ? ` (${notes.join(', ')})` : '';
}

/** One line of the list: number, kind, name, what it holds, its state, where it goes. */
function entry(item: Element, n: number): string {
  const input = item as HTMLInputElement;
  const role = item.getAttribute('role');
  const kind =
    role && !(item instanceof HTMLInputElement)
      ? role
      : item.tagName.toLowerCase() + (input.type ? `(${input.type})` : '');
  const field = isField(item);
  const name = field ? brief(labelOf(item)) || describe(item) : describe(item);
  const value = field ? shownValue(item) : null;
  const holds = value === null ? '' : value === '' ? ' = (empty)' : ` = "${brief(value)}"`;
  const state =
    input.type === 'checkbox' || input.type === 'radio' ? (input.checked ? ' [on]' : ' [off]') : '';
  const href = (item as HTMLAnchorElement).href ? ` -> ${(item as HTMLAnchorElement).href}` : '';
  return `[${n}] ${kind} ${name}${holds}${state}${field ? validity(item) : ''}${href}`;
}

/** Numbers what can be picked, keeping earlier numbers; the list as text. */
export function outline(root: Document = document): string {
  const known = (window.__moteOutline ??= []);
  for (const item of root.querySelectorAll(PICKABLE)) {
    if (known.length >= 2000) break;
    if (!known.includes(item)) known.push(item);
  }
  const lines: string[] = [];
  known.forEach((item, n) => {
    if (lines.length >= MOST || !item.isConnected || !shown(item)) return;
    lines.push(entry(item, n));
  });
  return lines.join('\n');
}

/** The fields the page would refuse to send as they are: required and empty,
 * or wrong by the browser's or the page's own checks. One line each. */
export function problems(): string[] {
  if (!window.__moteOutline?.length) outline();
  return (window.__moteOutline ?? []).flatMap((item, n) => {
    if (!item.isConnected || !isField(item)) return [];
    const said = validity(item);
    const field = item as HTMLInputElement;
    const empty = shownValue(item) === '' && !(field.type === 'checkbox' && field.checked);
    const required = said.includes('required');
    if (!said.includes('invalid') && !(required && empty)) return [];
    return [entry(item, n)];
  });
}

/** The element numbered `n`, while it's still in the page. */
/** A field's label, as a person reads it: its <label>, else what it says it is. */
export function labelOf(item: Element): string {
  const field = item as HTMLInputElement;
  // Hidden labels count: they're what the field is called, shown or not.
  const byFor =
    field.labels?.[0] ?? (field.id ? document.querySelector(`label[for="${CSS.escape(field.id)}"]`) : null);
  const wrapping = item.closest('label');
  const named = item.getAttribute('aria-labelledby');
  const labelled = named
    ? named
        .split(/\s+/)
        .map((id) => document.getElementById(id)?.textContent ?? '')
        .join(' ')
    : '';
  // A label round the field holds the field's own words too (a list's options).
  const own = (label: Element | null) => (label?.textContent ?? '').replace(item.textContent ?? '', '');
  const said =
    own(byFor) ||
    labelled ||
    item.getAttribute('aria-label') ||
    own(wrapping) ||
    field.placeholder ||
    item.getAttribute('title') ||
    item.closest('fieldset')?.querySelector('legend')?.textContent ||
    field.name ||
    '';
  return said.trim().replace(/\s+/g, ' ');
}

/** The number of the form field whose label says `label`: the same words, else containing them. */
export function findField(label: string): number | null {
  if (!window.__moteOutline?.length) outline();
  const known = window.__moteOutline ?? [];
  const wanted = label.trim().toLowerCase();
  const fields = known
    .map((item, n) => ({ item, n }))
    .filter(
      ({ item }) =>
        item.isConnected &&
        (item instanceof HTMLInputElement ||
          item instanceof HTMLSelectElement ||
          item instanceof HTMLTextAreaElement ||
          isEditor(item)),
    );
  const exact = fields.find(({ item }) => labelOf(item).toLowerCase() === wanted);
  const near = exact ?? fields.find(({ item }) => labelOf(item).toLowerCase().includes(wanted));
  return near ? near.n : null;
}

/** What kind of field an element is, for filling it the right way. */
export function kindOf(item: Element | null): string {
  if (!item) return 'gone';
  if (item instanceof HTMLSelectElement) return 'select';
  if (item instanceof HTMLInputElement) {
    if (item.type === 'checkbox' || item.type === 'radio' || item.type === 'password') return item.type;
    return 'text';
  }
  if (item.getAttribute('role') === 'checkbox') return 'checkbox';
  return 'text';
}

function numbered(n: number | undefined): Element | null {
  if (n === undefined) return null;
  const found = window.__moteOutline?.[n];
  return found && found.isConnected ? found : null;
}

function setValue(field: HTMLInputElement | HTMLTextAreaElement, value: string): void {
  const prototype =
    field instanceof HTMLTextAreaElement ? HTMLTextAreaElement.prototype : HTMLInputElement.prototype;
  const setter = Object.getOwnPropertyDescriptor(prototype, 'value')?.set;
  if (setter) setter.call(field, value);
  else field.value = value;
  field.dispatchEvent(new Event('input', { bubbles: true }));
  field.dispatchEvent(new Event('change', { bubbles: true }));
}

/**
 * Writes into a field or an editor: plain fields through the value setter, as
 * typing would; rich editors (an email's body) through insertText, which they
 * take as typing, so their undo and handlers work. No number: where the caret is.
 */
export function write(target: Element | null, text: string, how: Args['how'] = 'replace'): string {
  const field = target ?? document.activeElement;
  if (!field || field === document.body) return 'nowhere';
  if (isPassword(field)) return 'password';
  (field as HTMLElement).focus();
  if (field instanceof HTMLInputElement || field instanceof HTMLTextAreaElement) {
    if (field.readOnly || field.disabled) return 'locked';
    const now = field.value;
    const next = how === 'append' ? now + text : how === 'insert' ? insertAtCaret(field, text) : text;
    setValue(field, next);
    return 'done';
  }
  if (isEditor(field)) {
    const selection = window.getSelection();
    if (how === 'replace' && selection) {
      selection.selectAllChildren(field);
    } else if (how === 'append' && selection) {
      selection.selectAllChildren(field);
      selection.collapseToEnd();
    }
    // Rich editors listen for this as if typed; the fallback sets the text.
    const typed =
      typeof document.execCommand === 'function' && document.execCommand('insertText', false, text);
    if (!typed) {
      field.textContent = how === 'append' ? (field.textContent ?? '') + text : text;
      field.dispatchEvent(new InputEvent('input', { bubbles: true, data: text }));
    }
    return 'done';
  }
  return 'not-editable';
}

function insertAtCaret(field: HTMLInputElement | HTMLTextAreaElement, text: string): string {
  const start = field.selectionStart ?? field.value.length;
  const end = field.selectionEnd ?? start;
  return field.value.slice(0, start) + text + field.value.slice(end);
}

/** What a field holds; never a password. */
export function readField(target: Element | null): string {
  if (!target) return 'gone';
  if (isPassword(target)) return 'password';
  if (
    target instanceof HTMLInputElement ||
    target instanceof HTMLTextAreaElement ||
    target instanceof HTMLSelectElement
  ) {
    return target.value;
  }
  return (target as HTMLElement).innerText ?? '';
}

/** Picks an option of a list by its value or what it says. */
export function choose(target: Element | null, value: string): string {
  if (!(target instanceof HTMLSelectElement)) return target ? 'not-a-list' : 'gone';
  const wanted = value.trim().toLowerCase();
  const option = [...target.options].find(
    (item) => item.value.toLowerCase() === wanted || item.text.trim().toLowerCase() === wanted,
  );
  if (!option) return `no-option: ${[...target.options].map((item) => item.text.trim()).join(' | ')}`;
  target.value = option.value;
  target.dispatchEvent(new Event('input', { bubbles: true }));
  target.dispatchEvent(new Event('change', { bubbles: true }));
  return 'done';
}

/** Ticks or unticks a box, by clicking it so the page hears it. */
export function check(target: Element | null, on: boolean): string {
  if (!target) return 'gone';
  const checked =
    target instanceof HTMLInputElement ? target.checked : target.getAttribute('aria-checked') === 'true';
  if (checked !== on) (target as HTMLElement).click();
  return 'done';
}

/** Up to twenty places the words appear, each with some of what's around it. */
export function find(text: string, root: Document = document): string[] {
  const needle = text.trim().toLowerCase();
  if (!needle) return [];
  const found: string[] = [];
  const walker = root.createTreeWalker(root.body, NodeFilter.SHOW_TEXT);
  for (let node = walker.nextNode(); node && found.length < 20; node = walker.nextNode()) {
    const words = node.textContent ?? '';
    let at = words.toLowerCase().indexOf(needle);
    while (at >= 0 && found.length < 20) {
      const start = Math.max(0, at - 80);
      found.push(
        words
          .slice(start, at + needle.length + 80)
          .replace(/\s+/g, ' ')
          .trim(),
      );
      at = words.toLowerCase().indexOf(needle, at + needle.length);
    }
  }
  return found;
}

/** The page's tables as Markdown, one after another. */
export function tables(root: Document = document): string {
  const out: string[] = [];
  let length = 0;
  for (const table of root.querySelectorAll('table')) {
    const rows = [...table.rows].map((row) =>
      [...row.cells].map((cell) =>
        (cell.innerText || cell.textContent || '').trim().replace(/\s+/g, ' ').replace(/\|/g, '\\|'),
      ),
    );
    if (rows.length === 0) continue;
    const width = Math.max(...rows.map((row) => row.length));
    const line = (cells: string[]) =>
      `| ${[...cells, ...Array(width - cells.length).fill('')].join(' | ')} |`;
    const text = [line(rows[0]!), line(Array(width).fill('---')), ...rows.slice(1).map(line)].join('\n');
    if (length + text.length > MOST_TEXT) break;
    out.push(text);
    length += text.length;
  }
  return out.join('\n\n');
}

/** Where an element is in the window, for the cursor to go to; null if gone. */
export function place(
  target: Element | null,
): { x: number; y: number; w: number; h: number; sx: number; sy: number } | null {
  if (!target) return null;
  const box = target.getBoundingClientRect();
  return { x: box.x, y: box.y, w: box.width, h: box.height, sx: window.scrollX, sy: window.scrollY };
}

export function run(op: string, args: Args = {}): unknown {
  const target = numbered(args.n);
  switch (op) {
    case 'outline':
      return outline();
    case 'describe':
      return target ? describe(target) : null;
    case 'rect':
      if (target) target.scrollIntoView({ block: 'center', inline: 'nearest' });
      return place(target);
    case 'click':
      if (!target) return 'gone';
      (target as HTMLElement).click();
      return 'done';
    case 'focus':
      if (!target) return 'gone';
      (target as HTMLElement).focus();
      return 'done';
    case 'write':
      if (args.n !== undefined && !target) return 'gone';
      return write(target, args.text ?? '', args.how);
    case 'read':
      return readField(target);
    case 'choose':
      return choose(target, args.value ?? '');
    case 'check':
      return check(target, args.on ?? true);
    case 'scroll':
      if (target) target.scrollIntoView({ block: 'center' });
      else if (args.to === 'top') window.scrollTo({ top: 0 });
      else if (args.to === 'bottom') window.scrollTo({ top: document.documentElement.scrollHeight });
      else window.scrollBy({ top: args.by ?? window.innerHeight * 0.8 });
      return 'done';
    case 'key': {
      // Without a window to send real keys through: the events, as the page sees them.
      const at = target ?? document.activeElement ?? document.body;
      for (const type of ['keydown', 'keypress', 'keyup']) {
        at.dispatchEvent(
          new KeyboardEvent(type, { key: args.key ?? 'Enter', bubbles: true, cancelable: true }),
        );
      }
      if (args.key === 'Enter' && at instanceof HTMLInputElement) at.form?.requestSubmit();
      return 'done';
    }
    case 'find':
      return find(args.text ?? '');
    case 'find-field': {
      const n = findField(args.label ?? '');
      return n === null ? null : String(n);
    }
    case 'kind':
      return kindOf(target);
    case 'tables':
      return tables();
    case 'problems':
      return problems();
    case 'selection':
      return window.getSelection()?.toString() ?? '';
    case 'code': {
      // A one-time code goes only where the page asks for one.
      const field = document.querySelector<HTMLInputElement>(
        'input[autocomplete="one-time-code"], input[name*="otp" i], input[name*="code" i][inputmode="numeric"]',
      );
      return field ? write(field, args.text ?? '', 'replace') : 'nowhere';
    }
    default:
      return 'unknown';
  }
}
