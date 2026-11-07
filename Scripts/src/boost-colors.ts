// A boost's colours, as Zen's boosts colour a page in the engine
// (nsZenBoostsBackend.cpp): every colour the page sets moves toward the
// boost's colour in Oklab, dark ones toward the first dot and light ones
// toward the second, its lightness kept near its own. Only colours the page
// declares (text, backgrounds, borders) change; pictures stay as they are.
// Runs in Mote's own world, from Boosts.swift, with `moteConfig`.

interface BoostColors {
  /** "#rrggbb" for each dot; none for the page's own colours. */
  primary?: string;
  secondary?: string;
  /** How far colours move, 0 to 1. */
  strength: number;
}

declare const moteConfig: BoostColors;

declare global {
  interface Window {
    __moteBoostColors?: { set(colors: BoostColors): void };
  }
}

type Lab = [number, number, number];
type RGB = [number, number, number];

const PROPERTIES = [
  "color",
  "background-color",
  "border-top-color",
  "border-right-color",
  "border-bottom-color",
  "border-left-color",
];
const SKIP = /^(IMG|PICTURE|VIDEO|CANVAS|IFRAME|svg|image|SOURCE)$/;
/** Elements done at a time, so a long page never holds one up. */
const PER_FRAME = 700;

const linear = (c: number): number =>
  c <= 0.04045 ? c / 12.92 : ((c + 0.055) / 1.055) ** 2.4;
const srgb = (c: number): number =>
  c <= 0.0031308 ? 12.92 * c : 1.055 * Math.max(c, 0) ** (1 / 2.4) - 0.055;

export function oklab([r, g, b]: RGB): Lab {
  const [lr, lg, lb] = [linear(r / 255), linear(g / 255), linear(b / 255)];
  const l = Math.cbrt(
    0.4122214708 * lr + 0.5363325363 * lg + 0.0514459929 * lb,
  );
  const m = Math.cbrt(
    0.2119034982 * lr + 0.6806995451 * lg + 0.1073969566 * lb,
  );
  const s = Math.cbrt(
    0.0883024619 * lr + 0.2817188376 * lg + 0.6299787005 * lb,
  );
  return [
    0.2104542553 * l + 0.793617785 * m - 0.0040720468 * s,
    1.9779984951 * l - 2.428592205 * m + 0.4505937099 * s,
    0.0259040371 * l + 0.7827717662 * m - 0.808675766 * s,
  ];
}

const channel = (v: number): number =>
  Math.round(Math.min(Math.max(srgb(v), 0), 1) * 255);

export function rgb([L, A, B]: Lab): RGB {
  const l = (L + 0.3963377774 * A + 0.2158037573 * B) ** 3;
  const m = (L - 0.1055613458 * A - 0.0638541728 * B) ** 3;
  const s = (L - 0.0894841775 * A - 1.291485548 * B) ** 3;
  return [
    channel(4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s),
    channel(-1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s),
    channel(-0.0041960863 * l - 0.7034186147 * m + 1.707614701 * s),
  ];
}

const hex = (text: string): RGB =>
  [1, 3, 5].map((at) => parseInt(text.slice(at, at + 2), 16)) as RGB;

export function filter(
  color: RGB,
  first: Lab,
  second: Lab,
  strength: number,
): RGB {
  const [L, A, B] = oklab(color);
  // Dark colours lean to the first dot, light ones to the second, smoothly.
  const half = Math.min(Math.max(0.5 - strength * 0.45, 0.05), 0.5);
  let t = Math.min(Math.max((L - (0.5 - half)) / (2 * half), 0), 1);
  t = t * t * (3 - 2 * t);
  const pick = first.map((v, i) => v + ((second[i] as number) - v) * t) as Lab;
  const a = A + (pick[1] - A) * strength;
  const b = B + (pick[2] - B) * strength;
  const shift = pick[0] - L;
  const lightness = L + shift * strength * strength * 0.5;
  const turn = (shift > 0 ? -1 : 1) * strength * strength * 0.25;
  return rgb([
    lightness,
    a * Math.cos(turn) - b * Math.sin(turn),
    a * Math.sin(turn) + b * Math.cos(turn),
  ]);
}

const parse = (value: string): { color: RGB; alpha: string } | null => {
  const found =
    /^rgba?\(([\d.]+),\s*([\d.]+),\s*([\d.]+)(?:,\s*([\d.]+))?\)$/.exec(value);
  if (!found || found[4] === "0") return null;
  return {
    color: [Number(found[1]), Number(found[2]), Number(found[3])],
    alpha: found[4] ?? "1",
  };
};

if (!window.__moteBoostColors) {
  /** Each element's own colours before the boost, and its inline ones to put back. */
  const original = new WeakMap<
    Element,
    { computed: (string | null)[]; inline: string[] }
  >();
  const touched = new Set<Element>();
  let current: { first: Lab; second: Lab; strength: number } | null = null;
  let queue: Element[] = [];
  let scheduled = false;

  const paint = (element: Element): void => {
    if (
      !current ||
      SKIP.test(element.tagName) ||
      !(element instanceof HTMLElement || element instanceof SVGElement)
    )
      return;
    let saved = original.get(element);
    if (!saved) {
      const style = getComputedStyle(element);
      saved = {
        computed: PROPERTIES.map((property) =>
          style.getPropertyValue(property),
        ),
        inline: PROPERTIES.map((property) =>
          element.style.getPropertyValue(property),
        ),
      };
      original.set(element, saved);
    }
    PROPERTIES.forEach((property, i) => {
      const read = parse(saved.computed[i] ?? "");
      if (!read || !current) return;
      const [r, g, b] = filter(
        read.color,
        current.first,
        current.second,
        current.strength,
      );
      element.style.setProperty(
        property,
        `rgba(${r}, ${g}, ${b}, ${read.alpha})`,
        "important",
      );
    });
    touched.add(element);
  };

  const drain = (): void => {
    scheduled = false;
    for (const element of queue.splice(0, PER_FRAME)) paint(element);
    if (queue.length) schedule();
  };
  const schedule = (): void => {
    if (scheduled) return;
    scheduled = true;
    // A task, not a frame: frames stop for a page out of sight, which is
    // still to be coloured when it shows.
    setTimeout(drain, 0);
  };

  const unpaint = (): void => {
    for (const element of touched) {
      const saved = original.get(element);
      if (
        !saved ||
        !(element instanceof HTMLElement || element instanceof SVGElement)
      )
        continue;
      PROPERTIES.forEach((property, i) => {
        const value = saved.inline[i];
        if (value) element.style.setProperty(property, value);
        else element.style.removeProperty(property);
      });
    }
    touched.clear();
  };

  const start = (): void => {
    // The page's own canvas, when it leaves it to the browser: white, moved too.
    const root = document.documentElement;
    if (
      !parse(getComputedStyle(root).backgroundColor) &&
      document.body &&
      !parse(getComputedStyle(document.body).backgroundColor)
    ) {
      root.style.setProperty("background-color", "rgb(255, 255, 255)");
    }
    queue = [root, ...document.querySelectorAll("*")];
    schedule();
  };

  new MutationObserver((changes) => {
    if (!current) return;
    for (const change of changes) {
      for (const node of change.addedNodes) {
        if (node instanceof Element)
          queue.push(node, ...node.querySelectorAll("*"));
      }
    }
    if (queue.length) schedule();
  }).observe(document, { childList: true, subtree: true });

  window.__moteBoostColors = {
    set(colors) {
      unpaint();
      queue = [];
      current =
        colors.primary && colors.strength > 0
          ? {
              first: oklab(hex(colors.primary)),
              second: oklab(hex(colors.secondary ?? colors.primary)),
              strength: Math.min(colors.strength, 1),
            }
          : null;
      if (!current) return;
      if (document.readyState === "loading")
        document.addEventListener("DOMContentLoaded", start, { once: true });
      else start();
    },
  };
}

window.__moteBoostColors.set(moteConfig);
