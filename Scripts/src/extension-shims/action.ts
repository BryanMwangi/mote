// chrome.action (and the older chrome.browserAction).

import { resolved } from './callbacks';
import { createEvent } from './events';
import { fill } from './members';
import type { Shim } from './types';

/**
 * The popup an extension sets for its button, told to the browser too:
 * Mote opens a popup itself (see Extensions.press), and has to know
 * which page it is now. The browser is told the page and the tab's index,
 * or -1 for every tab (`action.popup`).
 */
export function tellPopups({ chrome, put, native }: Shim): void {
  // A version 2 extension's page button is `pageAction`, as TWP's is.
  for (const name of ['action', 'browserAction', 'pageAction']) {
    const action = chrome[name];
    if (!action || typeof action.setPopup !== 'function') continue;
    const setPopup = action.setPopup.bind(action);
    put(action, 'setPopup', (details: { popup?: string; tabId?: number } = {}, callback?: unknown) => {
      const tell = (index: number) => native('action.popup', [details.popup || '', index]).catch(() => {});
      if (typeof details.tabId === 'number' && chrome.tabs) {
        chrome.tabs.get(details.tabId).then(
          (t: { index: number }) => tell(t.index),
          () => {},
        );
      } else tell(-1);
      return setPopup(details, callback);
    });
  }
}

export function fillAction(shim: Shim): void {
  fill(shim, 'action', {
    getUserSettings: resolved({ isOnToolbar: true }),
    onUserSettingsChanged: createEvent(),
    setBadgeTextColor: resolved(undefined),
    getBadgeTextColor: resolved([255, 255, 255, 255]),
  });
  // A page button shown or hidden for a tab is WebKit's enabled or not: a
  // translator turns its on for pages in another language (TWP calls show on
  // every page, and stopped with a TypeError on each).
  const page = shim.chrome.pageAction;
  if (page) {
    const turn = (on: boolean) => (tabId: number, callback?: () => void) => {
      const act = on ? page.enable : page.disable;
      const done = typeof act === 'function' ? Promise.resolve(act.call(page, tabId)).catch(() => {}) : Promise.resolve();
      return typeof callback === 'function' ? void done.then(() => callback()) : done;
    };
    fill(shim, 'pageAction', { show: turn(true), hide: turn(false) });
  }
}
