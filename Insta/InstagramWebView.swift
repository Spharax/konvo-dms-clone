import SwiftUI
import WebKit

struct InstagramWebView: UIViewRepresentable {
    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.allowsInlineMediaPlayback = true
        configuration.mediaTypesRequiringUserActionForPlayback = []

        let preferences = WKWebpagePreferences()
        preferences.allowsContentJavaScript = true
        configuration.defaultWebpagePreferences = preferences

        // The script must be added BEFORE the web view is created
        let script = WKUserScript(
            source: context.coordinator.injectionScript,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true
        )
        configuration.userContentController.addUserScript(script)

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.customUserAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1"

        // Without this there is no way to go back after opening a reel/post/story from a DM
        webView.allowsBackForwardNavigationGestures = true

        #if DEBUG
        if #available(iOS 16.4, *) { webView.isInspectable = true } // Safari > Develop to debug selectors
        #endif

        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        context.coordinator.currentWebView = webView

        webView.load(URLRequest(url: Coordinator.inboxURL))
        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator() }

    // MARK: - Coordinator

    class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        static let inboxURL = URL(string: "https://www.instagram.com/direct/inbox/")!
        static let defaultRulesURL = "https://raw.githubusercontent.com/Spharax/konvo-dms-clone/main/rules.json"
        static let rulesDidChangeNotification = Notification.Name("InstaRulesURLDidChange")

        let injectionScript: String
        private var rules: Rules          // only touched on the main thread
        private var lastFetch = Date.distantPast
        private var pendingTask: URLSessionDataTask?
        fileprivate weak var currentWebView: WKWebView?

        override init() {
            let initial: Rules
            if let data = UserDefaults.standard.data(forKey: "cachedRules"),
               let cached = try? JSONDecoder().decode(Rules.self, from: data) {
                initial = cached
            } else {
                initial = .default
            }
            self.rules = initial

            let rulesJSON = (try? String(data: JSONEncoder().encode(initial), encoding: .utf8)) ?? "{}"

            // Raw string: JS can contain backslashes/backticks freely; Swift interpolation is \#( )
            self.injectionScript = #"""
            (function() {
                if (window.__instaInstalled) return;
                window.__instaInstalled = true;
                window.__instaRules = \#(rulesJSON);

                const INBOX = '/direct/inbox/';
                const DEFAULT_BLOCKED = ['/', '/explore/', '/reels/'];

                function getRules() { return window.__instaRules || {}; }

                // Individual media and all DM routes are always allowed
                function isAllowed(path) {
                    return path.startsWith('/direct/') || path.includes('/reel/') ||
                           path.includes('/p/') || path.includes('/stories/');
                }

                function shouldBlock(path) {
                    if (isAllowed(path)) return false;
                    const blocked = getRules().blockedPaths || DEFAULT_BLOCKED;
                    return blocked.some(b =>
                        (b === '/' || b === '') ? (path === '/' || path === '') : path.startsWith(b));
                }

                function redirectIfNeeded() {
                    if (shouldBlock(location.pathname)) location.replace(INBOX);
                }

                // One CSS rule per selector so a single invalid selector can't break the others.
                function buildCSS() {
                    const sels = getRules().hideSelectors || [];
                    return sels
                        .filter(s => typeof s === 'string' && !/[{}]/.test(s))
                        .map(s => s + ' { display: none !important; visibility: hidden !important; }')
                        .join('\n');
                }

                let styleEl = null;
                function applyHide() {
                    if (!styleEl) {
                        styleEl = document.createElement('style');
                        styleEl.id = 'insta-style';
                    }
                    const css = buildCSS();
                    if (styleEl.textContent !== css) styleEl.textContent = css;
                    const parent = document.head || document.documentElement;
                    if (parent && !styleEl.isConnected) parent.appendChild(styleEl);
                }

                function hook(name) {
                    const orig = history[name];
                    if (typeof orig !== 'function') return;
                    history[name] = function() {
                        const result = orig.apply(this, arguments);
                        setTimeout(redirectIfNeeded, 0);
                        return result;
                    };
                }
                hook('pushState');
                hook('replaceState');
                window.addEventListener('popstate', redirectIfNeeded);
                redirectIfNeeded();

                function init() {
                    applyHide();
                    // Cheap watcher: only re-attaches the <style> if the page removes it.
                    new MutationObserver(() => { if (!styleEl.isConnected) applyHide(); })
                        .observe(document.documentElement, { childList: true, subtree: true });
                }
                if (document.documentElement) init();
                else document.addEventListener('DOMContentLoaded', init);

                window.__applyInstaRules = function(r) {
                    try {
                        window.__instaRules = (typeof r === 'string') ? JSON.parse(r) : r;
                    } catch (e) {
                        console.warn('Insta: failed to apply rules', e);
                        return;
                    }
                    applyHide();
                    redirectIfNeeded();
                };
            })();
            """#
            super.init()

            NotificationCenter.default.addObserver(
                self,
                selector: #selector(rulesURLDidChange),
                name: Self.rulesDidChangeNotification,
                object: nil
            )
        }

        deinit {
            pendingTask?.cancel()
            NotificationCenter.default.removeObserver(self)
        }

        @objc private func rulesURLDidChange() {
            lastFetch = Date.distantPast
            if let webView = currentWebView {
                fetchAndApplyRules(webView: webView, force: true)
            }
        }

        // MARK: WKUIDelegate

        // target="_blank" / window.open -> same web view
        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
            if navigationAction.targetFrame == nil {
                webView.load(navigationAction.request)
            }
            return nil
        }

        // MARK: WKNavigationDelegate

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            fetchAndApplyRules(webView: webView, force: false)
        }

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            // Only judge main-frame navigations to Instagram (iframes must not hijack the page)
            guard navigationAction.targetFrame?.isMainFrame ?? true,
                  let url = navigationAction.request.url,
                  let host = url.host,
                  host == "instagram.com" || host.hasSuffix(".instagram.com") else {
                decisionHandler(.allow)
                return
            }

            if Self.shouldBlock(path: url.path, rules: rules) {
                webView.load(URLRequest(url: Self.inboxURL))
                decisionHandler(.cancel)
            } else {
                decisionHandler(.allow)
            }
        }

        // Mirrors the JS logic – keep in sync with the injected isAllowed/shouldBlock
        private static func shouldBlock(path: String, rules: Rules) -> Bool {
            if path.hasPrefix("/direct/") || path.contains("/reel/") ||
               path.contains("/p/") || path.contains("/stories/") {
                return false
            }
            return rules.blockedPaths.contains { b in
                if b == "/" || b.isEmpty { return path == "/" || path.isEmpty }
                return path.hasPrefix(b)
            }
        }

        // MARK: Remote rules

        private func fetchAndApplyRules(webView: WKWebView, force: Bool) {
            // Don't hammer the host on every page finish unless forced
            if !force && Date().timeIntervalSince(lastFetch) <= 60 { return }
            lastFetch = Date()

            let urlString = UserDefaults.standard.string(forKey: "rulesURL") ?? Self.defaultRulesURL
            guard let url = URL(string: urlString) else {
                #if DEBUG
                print("Insta: invalid rules URL")
                #endif
                return
            }

            var request = URLRequest(url: url)
            request.cachePolicy = .reloadIgnoringLocalCacheData
            request.timeoutInterval = 10

            pendingTask?.cancel()
            pendingTask = URLSession.shared.dataTask(with: request) { [weak self, weak webView] data, response, error in
                defer { self?.pendingTask = nil }

                guard let data = data, error == nil,
                      (response as? HTTPURLResponse)?.statusCode == 200,
                      let rules = try? JSONDecoder().decode(Rules.self, from: data),
                      let json = (try? JSONEncoder().encode(rules)).flatMap({ String(data: $0, encoding: .utf8) })
                else {
                    #if DEBUG
                    let status = (response as? HTTPURLResponse)?.statusCode ?? -1
                    print("Insta: rules fetch failed (status=\(status), error=\(error?.localizedDescription ?? "nil"))")
                    #endif
                    return
                }

                DispatchQueue.main.async {
                    guard let self = self else { return }
                    self.rules = rules
                    UserDefaults.standard.set(try? JSONEncoder().encode(rules), forKey: "cachedRules")
                    // Pass as a JSON string so the JS side can JSON.parse it safely
                    let jsString = json
                        .replacingOccurrences(of: "\\", with: "\\\\")
                        .replacingOccurrences(of: "\"", with: "\\\"")
                        .replacingOccurrences(of: "\n", with: "\\n")
                        .replacingOccurrences(of: "\r", with: "\\r")
                        .replacingOccurrences(of: "\u{2028}", with: "\\u2028")
                        .replacingOccurrences(of: "\u{2029}", with: "\\u2029")
                    webView?.evaluateJavaScript("if (window.__applyInstaRules) window.__applyInstaRules(\"\(jsString)\");", completionHandler: { _, err in
                        #if DEBUG
                        if let err = err { print("Insta: JS apply failed: \(err)") }
                        #endif
                    })
                }
            }
            pendingTask?.resume()
        }

        // Exposed so Settings can request an immediate refresh
        func forceRefresh(webView: WKWebView) {
            fetchAndApplyRules(webView: webView, force: true)
        }
    }
}

struct Rules: Codable {
    var blockedPaths: [String]
    var hideSelectors: [String]

    static let `default` = Rules(
        blockedPaths: ["/", "/explore/", "/reels/"],
        hideSelectors: [
            "a[href='/']",
            "a[href='/explore/']",
            "a[href='/reels/']"
        ]
    )

    init(blockedPaths: [String], hideSelectors: [String]) {
        self.blockedPaths = blockedPaths
        self.hideSelectors = hideSelectors
    }

    // A missing key in the remote JSON falls back to defaults instead of failing the whole decode
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        blockedPaths = try c.decodeIfPresent([String].self, forKey: .blockedPaths) ?? Rules.default.blockedPaths
        hideSelectors = try c.decodeIfPresent([String].self, forKey: .hideSelectors) ?? Rules.default.hideSelectors
    }
}
