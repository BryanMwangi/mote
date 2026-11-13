// Generated from Scripts/src/dev-hooks.ts by `pnpm build`. Do not edit.
var moteDevHooks = (function(exports) {

Object.defineProperty(exports, Symbol.toStringTag, { value: 'Module' });
//#region src/dev-hooks.ts
	const KEEP = 200;
	function keep(list, line) {
		list.push(line.slice(0, 500));
		if (list.length > KEEP) list.shift();
	}
	function text(value) {
		if (value instanceof Error) return `${value.name}: ${value.message}`;
		if (typeof value === "string") return value;
		try {
			return JSON.stringify(value);
		} catch {
			return String(value);
		}
	}
	function install(target = window) {
		if (target.__moteDevLog) return target.__moteDevLog;
		const log = {
			console: [],
			network: []
		};
		Object.defineProperty(target, "__moteDevLog", {
			value: log,
			enumerable: false
		});
		for (const level of [
			"log",
			"info",
			"warn",
			"error",
			"debug"
		]) {
			const sink = target.console;
			const original = sink[level].bind(sink);
			sink[level] = (...args) => {
				keep(log.console, `[${level}] ${args.map(text).join(" ")}`);
				original(...args);
			};
		}
		target.addEventListener("error", (event) => {
			const element = event.target;
			if (element && element !== target && "src" in element) keep(log.network, `failed to load ${String(element.src || element.href || "")}`);
			else keep(log.console, `[uncaught] ${event.message} (${event.filename}:${event.lineno})`);
		}, true);
		target.addEventListener("unhandledrejection", (event) => keep(log.console, `[unhandled rejection] ${text(event.reason)}`));
		const fetch = target.fetch?.bind(target);
		if (fetch) target.fetch = async (input, init) => {
			const address = input instanceof Request ? input.url : String(input);
			try {
				const response = await fetch(input, init);
				if (response.status >= 400) keep(log.network, `${response.status} ${init?.method ?? "GET"} ${address}`);
				return response;
			} catch (error) {
				keep(log.network, `failed ${init?.method ?? "GET"} ${address}: ${text(error)}`);
				throw error;
			}
		};
		const requests = target.XMLHttpRequest;
		const open = requests?.prototype.open;
		if (open) requests.prototype.open = function(method, url, ...rest) {
			this.addEventListener("loadend", () => {
				if (this.status === 0 || this.status >= 400) keep(log.network, `${this.status || "failed"} ${method} ${String(url)}`);
			});
			return open.call(this, method, url, ...rest);
		};
		return log;
	}
	install();

//#endregion
exports.install = install;
return exports;
})({});