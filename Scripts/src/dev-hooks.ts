// What a coding agent testing a site needs to see (AssistantTools+Dev.swift):
// the page's console messages and uncaught errors, and requests that failed
// or answered with an error. Only on the developer sites (Settings › AI), in
// the page's own world, where its console is; kept in the page, the last 200
// of each, until the agent asks.

export interface DevLog {
  console: string[];
  network: string[];
}

declare global {
  interface Window {
    __moteDevLog?: DevLog;
  }
}

const KEEP = 200;

function keep(list: string[], line: string): void {
  list.push(line.slice(0, 500));
  if (list.length > KEEP) list.shift();
}

function text(value: unknown): string {
  if (value instanceof Error) return `${value.name}: ${value.message}`;
  if (typeof value === 'string') return value;
  try {
    return JSON.stringify(value);
  } catch {
    return String(value);
  }
}

export function install(target: Window = window): DevLog {
  if (target.__moteDevLog) return target.__moteDevLog;
  const log: DevLog = { console: [], network: [] };
  Object.defineProperty(target, '__moteDevLog', { value: log, enumerable: false });

  for (const level of ['log', 'info', 'warn', 'error', 'debug'] as const) {
    const sink = (target as Window & { console: Console }).console;
    const original = sink[level].bind(sink);
    sink[level] = (...args: unknown[]) => {
      keep(log.console, `[${level}] ${args.map(text).join(' ')}`);
      original(...args);
    };
  }
  target.addEventListener(
    'error',
    (event) => {
      const element = event.target as HTMLElement | null;
      // A script, image or stylesheet that didn't load.
      if (element && element !== (target as unknown) && 'src' in element) {
        keep(
          log.network,
          `failed to load ${String((element as unknown as { src?: string; href?: string }).src || (element as unknown as { href?: string }).href || '')}`,
        );
      } else {
        keep(log.console, `[uncaught] ${event.message} (${event.filename}:${event.lineno})`);
      }
    },
    true,
  );
  target.addEventListener('unhandledrejection', (event) =>
    keep(log.console, `[unhandled rejection] ${text(event.reason)}`),
  );

  const fetch = target.fetch?.bind(target);
  if (fetch) {
    target.fetch = async (input: RequestInfo | URL, init?: RequestInit) => {
      const address = input instanceof Request ? input.url : String(input);
      try {
        const response = await fetch(input, init);
        if (response.status >= 400)
          keep(log.network, `${response.status} ${init?.method ?? 'GET'} ${address}`);
        return response;
      } catch (error) {
        keep(log.network, `failed ${init?.method ?? 'GET'} ${address}: ${text(error)}`);
        throw error;
      }
    };
  }
  const requests = (target as Window & { XMLHttpRequest?: typeof XMLHttpRequest }).XMLHttpRequest;
  const open = requests?.prototype.open;
  if (open) {
    requests!.prototype.open = function (
      this: XMLHttpRequest,
      method: string,
      url: string | URL,
      ...rest: unknown[]
    ) {
      this.addEventListener('loadend', () => {
        if (this.status === 0 || this.status >= 400)
          keep(log.network, `${this.status || 'failed'} ${method} ${String(url)}`);
      });
      return (open as (...args: unknown[]) => void).call(this, method, url, ...rest);
    } as typeof open;
  }
  return log;
}

install();
