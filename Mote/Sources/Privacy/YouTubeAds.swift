import WebKit

/// YouTube's video ads, before and in the middle of a video, aren't other
/// addresses a block list can stop: they come inside the player's own data
/// (`adPlacements`, `playerAds`, `adSlots`). As uBlock Origin's scriptlets
/// do, they're taken out of that data, in the page's own world, as it's read:
/// from `ytInitialPlayerResponse`, `JSON.parse` and fetched JSON. Only on
/// YouTube, and only with ad blocking on (see PageScripts).
enum YouTubeAds {
    static var userScript: WKUserScript {
        WKUserScript(source: script, injectionTime: .atDocumentStart, forMainFrameOnly: false, in: .page)
    }

    static let script = """
        (() => {
          if (!/(^|\\.)youtube(-nocookie)?\\.com$/.test(location.hostname)) return;
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
          const like = (wrapper, original) => {
            Object.defineProperty(wrapper, 'toString', { value: original.toString.bind(original) });
            return wrapper;
          };
          const parse = JSON.parse;
          JSON.parse = like(function () { return prune(parse.apply(this, arguments)); }, parse);
          const json = Response.prototype.json;
          Response.prototype.json = like(function () { return json.apply(this, arguments).then(prune); }, json);
          let initial;
          Object.defineProperty(window, 'ytInitialPlayerResponse', {
            configurable: true,
            get: () => initial,
            set: (value) => { initial = prune(value); },
          });
        })();
        """
}
