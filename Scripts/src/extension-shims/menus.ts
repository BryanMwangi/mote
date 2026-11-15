// chrome.contextMenus and chrome.menus.

import { enumOf, fill } from './members';
import type { Shim } from './types';

export function fillMenus(shim: Shim): void {
  const contextTypes = enumOf(
    'all',
    'page',
    'frame',
    'selection',
    'link',
    'editable',
    'image',
    'video',
    'audio',
    'launcher',
    'browser_action',
    'page_action',
    'action',
  );
  fill(shim, 'contextMenus', {
    ContextType: contextTypes,
    ItemType: enumOf('normal', 'checkbox', 'radio', 'separator'),
  });
  fill(shim, 'menus', {
    ContextType: contextTypes,
    ItemType: enumOf('normal', 'checkbox', 'radio', 'separator'),
  });
}

/** A menu entry's properties, as far as the shim reads them. */
export interface MenuProperties {
  contexts?: string[];
  [key: string]: unknown;
}

/**
 * Context menu entries in the names WebKit takes for the extension's
 * manifest version: a version 3 one's button is `action`; a version 2
 * one's `browser_action` or `page_action`, and WebKit refuses the whole
 * entry for one it doesn't know. There is no app launcher at all.
 */
export function mendMenuProperties<P extends MenuProperties | null | undefined>(props: P, version = 3): P {
  if (!props || !Array.isArray(props.contexts)) return props;
  const button = (c: string): string => {
    if (version >= 3) return c === 'browser_action' || c === 'page_action' ? 'action' : c;
    return c === 'action' ? 'browser_action' : c;
  };
  const contexts = [...new Set(props.contexts.map(button).filter((c) => c !== 'launcher'))];
  return { ...withoutFilePatterns(props), contexts: contexts.length ? contexts : ['page'] };
}

/**
 * Only web address patterns: WebKit refuses the whole entry for a `file://`
 * or `ftp://` one; the others stay. One that had none is left as it was.
 */
function withoutFilePatterns<P extends MenuProperties>(props: P): P {
  const mended: MenuProperties = { ...props };
  for (const key of ['documentUrlPatterns', 'targetUrlPatterns']) {
    const patterns = props[key];
    if (!Array.isArray(patterns)) continue;
    const kept = patterns.filter(
      (p) => typeof p !== 'string' || p === '<all_urls>' || /^(\*|https?|wss?):/.test(p),
    );
    if (kept.length) mended[key] = kept;
  }
  return mended as P;
}

/**
 * The titles of the entries an extension has, told to the browser as they
 * change: WebKit puts them in a page's menu without saying whose they are,
 * and the browser leads each with its extension's icon, found by its title.
 */
function noteTitles(shim: Shim, titles: Map<unknown, string>): (change: () => void) => void {
  let told = '';
  return (change) => {
    change();
    const list = [...new Set(titles.values())];
    const text = JSON.stringify(list);
    if (text === told) return;
    told = text;
    void shim.native('menus.titles', [list]).catch(() => undefined);
  };
}

export function mendMenus(shim: Shim): void {
  const { chrome, put, runtime } = shim;
  const version = (() => {
    try {
      return Number(runtime.getManifest().manifest_version) || 3;
    } catch {
      return 3;
    }
  })();
  const titles = new Map<unknown, string>();
  const tell = noteTitles(shim, titles);
  const keep = (id: unknown, title: unknown) => {
    if (typeof title === 'string') titles.set(id, title);
  };
  for (const name of ['contextMenus', 'menus']) {
    const menus = chrome[name];
    if (!menus || typeof menus.create !== 'function') continue;
    const create = menus.create.bind(menus);
    put(menus, 'create', (props: MenuProperties, callback?: unknown) => {
      const id = create(mendMenuProperties(props, version), callback);
      tell(() => keep(props?.id ?? id, props?.title));
      return id;
    });
    if (typeof menus.remove === 'function') {
      const remove = menus.remove.bind(menus);
      put(menus, 'remove', (id: unknown, ...rest: unknown[]) => {
        tell(() => titles.delete(id));
        return remove(id, ...rest);
      });
    }
    if (typeof menus.removeAll === 'function') {
      const removeAll = menus.removeAll.bind(menus);
      put(menus, 'removeAll', (...rest: unknown[]) => {
        tell(() => titles.clear());
        return removeAll(...rest);
      });
    }
    // A WebKit without update still gets create mended, and the rest of the shim.
    if (typeof menus.update !== 'function') continue;
    const update = menus.update.bind(menus);
    put(menus, 'update', (id: unknown, props: MenuProperties, callback?: unknown) => {
      tell(() => keep(id, props?.title));
      return update(id, mendMenuProperties(props, version), callback);
    });
  }
}
