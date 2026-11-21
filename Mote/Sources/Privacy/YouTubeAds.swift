import WebKit

/// YouTube's video ads, before and in the middle of a video, aren't other
/// addresses a block list can stop: they come inside the player's own data
/// (`adPlacements`, `playerAds`, `adSlots`). As uBlock Origin's scriptlets
/// do, they're taken out of that data, in the page's own world, as it's read:
/// from `ytInitialPlayerResponse`, `JSON.parse` and fetched JSON. Only on
/// YouTube, and only with ad blocking on (see PageScripts).
///
/// YouTube looks for that: a patched function's source, name or length, or
/// a fresh frame's untouched copy. So, as uBlock Origin's do, each patch is a
/// Proxy of the native function, which reads as native even to
/// `Function.prototype.toString`; a frame added to the page is patched too;
/// and the callback YouTube runs when it finds tampering
/// (`onAbnormalityDetected`) is never run.
enum YouTubeAds {
    static var userScript: WKUserScript {
        WKUserScript(source: script, injectionTime: .atDocumentStart, forMainFrameOnly: false, in: .page)
    }

    static let script = """
        (() => {
          if (!/(^|\\.)youtube(-nocookie)?\\.com$/.test(location.hostname)) return;
          // Each patch, by the native function it stands for.
          const natives = new WeakMap();
          const nativeToString = Function.prototype.toString;
          const toString = new Proxy(nativeToString, {
            apply: (target, self, args) => Reflect.apply(target, natives.get(self) ?? self, args),
          });
          natives.set(toString, nativeToString);
          Function.prototype.toString = toString;
          const patch = (owner, name, apply) => {
            const native = owner?.[name];
            if (typeof native !== 'function' || natives.has(native)) return;
            const proxy = new Proxy(native, { apply });
            natives.set(proxy, native);
            owner[name] = proxy;
          };

          const keys = ['adPlacements', 'playerAds', 'adSlots'];
          const prune = (value) => {
            if (Array.isArray(value)) {
              value.forEach(prune);
            } else if (value && typeof value === 'object') {
              for (const key of keys) if (key in value) delete value[key];
              if (value.playerResponse) prune(value.playerResponse);
            }
            return value;
          };
          const patchRealm = (realm) => {
            patch(realm.JSON, 'parse', (target, self, args) => prune(Reflect.apply(target, self, args)));
            patch(realm.Response?.prototype, 'json', (target, self, args) => Reflect.apply(target, self, args).then(prune));
          };
          patchRealm(window);

          // A frame's own JSON.parse and Response would go round the patches.
          patch(Node.prototype, 'appendChild', (target, self, args) => {
            const added = Reflect.apply(target, self, args);
            try {
              if (args[0] instanceof HTMLIFrameElement && args[0].contentWindow) patchRealm(args[0].contentWindow);
            } catch {}
            return added;
          });

          // What YouTube runs on finding the page tampered with.
          patch(Promise.prototype, 'then', (target, self, args) => {
            if (typeof args[0] === 'function' && Reflect.apply(nativeToString, args[0], []).includes('onAbnormalityDetected')) {
              args[0] = function () {};
            }
            return Reflect.apply(target, self, args);
          });

          let initial;
          Object.defineProperty(window, 'ytInitialPlayerResponse', {
            configurable: true,
            get: () => initial,
            set: (value) => { initial = prune(value); },
          });
        })();
        """
}
