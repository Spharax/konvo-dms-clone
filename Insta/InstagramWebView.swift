import SwiftUI
import UIKit
import WebKit

struct InstagramWebView: UIViewRepresentable {
    @Binding var loadFailed: Bool
    var reloadToken: Int

    func makeUIView(context: Context) -> WKWebView {
        context.coordinator.loadFailed = $loadFailed
        context.coordinator.lastReloadToken = reloadToken

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
        webView.customUserAgent = Self.safariUserAgent

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

    func updateUIView(_ uiView: WKWebView, context: Context) {
        context.coordinator.loadFailed = $loadFailed
        guard context.coordinator.lastReloadToken != reloadToken else { return }
        context.coordinator.lastReloadToken = reloadToken
        loadFailed = false
        uiView.load(URLRequest(url: Coordinator.inboxURL))
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    /// Matches the running OS so Instagram is not served an iOS 17 page on an iOS 16 device.
    private static var safariUserAgent: String {
        let dotted = UIDevice.current.systemVersion
        let underscored = dotted.replacingOccurrences(of: ".", with: "_")
        return "Mozilla/5.0 (iPhone; CPU iPhone OS \(underscored) like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/\(dotted) Mobile/15E148 Safari/604.1"
    }

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
        var loadFailed: Binding<Bool> = .constant(false)
        var lastReloadToken = 0

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
            let rulesLiteral = Self.jsStringLiteral(rulesJSON)

            // Raw string: JS can contain backslashes/backticks freely; Swift interpolation is \#( )
            self.injectionScript = #"""
            (function() {
                if (window.__instaInstalled) return;
                window.__instaInstalled = true;
                try {
                    window.__instaRules = JSON.parse(\#(rulesLiteral));
                } catch (e) {
                    window.__instaRules = {};
                    console.warn('Insta: failed to parse initial rules', e);
                }

                const INBOX = '/direct/inbox/';
                const DEFAULT_BLOCKED = ['/', '/explore/', '/reels/'];
                const NAV_HREFS = ['/', '/explore/', '/reels/'];

                function getRules() { return window.__instaRules || {}; }

                \#(Self.pathLogicJS)

                function redirectIfNeeded() {
                    if (shouldBlock(location.pathname)) location.replace(INBOX);
                }

                // Reject selectors that can hide the whole page or break out of the rule.
                function isSafeSelector(s) {
                    if (typeof s !== 'string') return false;
                    const t = s.trim();
                    if (!t || t.length > 180) return false;
                    if (/[{}@\\<>]|\/\*|\*\//.test(t)) return false;
                    if (/^(?:\*|html|body)$/i.test(t)) return false;
                    return true;
                }

                // One CSS rule per selector so a single invalid selector can't break the others.
                function buildCSS() {
                    const sels = getRules().hideSelectors || [];
                    return sels
                        .filter(isSafeSelector)
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
                    hideNavLinks();
                    watchStyle();
                }

                // Language-independent: hide the Home / Explore / Reels entries by href, not aria-label.
                function hideNavLinks() {
                    const nodes = document.querySelectorAll('a[href]');
                    for (let i = 0; i < nodes.length; i++) {
                        const href = nodes[i].getAttribute('href') || '';
                        if (NAV_HREFS.indexOf(href) !== -1) {
                            nodes[i].style.setProperty('display', 'none', 'important');
                            nodes[i].style.setProperty('visibility', 'hidden', 'important');
                        }
                    }
                }

                function hook(name) {
                    const current = history[name];
                    if (current && current.__instaHook) return;
                    const orig = (current && current.__instaOrig) || current;
                    if (typeof orig !== 'function') return;
                    const wrapped = function() {
                        const result = orig.apply(this, arguments);
                        setTimeout(redirectIfNeeded, 0);
                        return result;
                    };
                    wrapped.__instaHook = true;
                    wrapped.__instaOrig = orig;
                    try { history[name] = wrapped; } catch (e) { /* non-configurable; ignore */ }
                }
                function reassertHooks() {
                    hook('pushState');
                    hook('replaceState');
                }
                reassertHooks();
                window.addEventListener('popstate', redirectIfNeeded);
                redirectIfNeeded();

                // Instagram's bundle often replaces history.pushState after document start.
                // Re-assert our wrapper, and re-hide nav links, without watching every DOM node.
                setInterval(function() {
                    reassertHooks();
                    hideNavLinks();
                }, 1500);

                let watched = null;
                function watchStyle() {
                    const target = document.head || document.documentElement;
                    if (!target || watched === target) return;
                    watched = target;
                    new MutationObserver(function() {
                        if (!styleEl || !styleEl.isConnected) applyHide();
                    }).observe(target, { childList: true });
                }

                function init() {
                    applyHide();
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
            loadFailed.wrappedValue = false
            fetchAndApplyRules(webView: webView, force: false)
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            handleLoadFailure(error)
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            handleLoadFailure(error)
        }

        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            loadFailed.wrappedValue = true
        }

        private func handleLoadFailure(_ error: Error) {
            let ns = error as NSError
            if ns.domain == NSURLErrorDomain && ns.code == NSURLErrorCancelled { return }
            loadFailed.wrappedValue = true
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

        // Single source of truth for the Swift and injected-JS path rules.
        // pathLogicJS is generated from these same lists — keep them together.
        static let allowedExact = ["/p", "/reel", "/stories"]
        static let allowedPrefixes = ["/direct/", "/explore/search/", "/p/", "/reel/", "/stories/"]

        static var pathLogicJS: String {
            let exact = allowedExact.map { "'\($0)'" }.joined(separator: ", ")
            let prefixes = allowedPrefixes.map { "'\($0)'" }.joined(separator: ", ")
            return """
            function isAllowed(path) {
                const exact = [\(exact)];
                const prefixes = [\(prefixes)];
                if (exact.indexOf(path) !== -1) return true;
                return prefixes.some(function(p) { return path.startsWith(p); });
            }
            function shouldBlock(path) {
                if (isAllowed(path)) return false;
                const blocked = getRules().blockedPaths || DEFAULT_BLOCKED;
                return blocked.some(function(b) {
                    return (b === '/' || b === '') ? (path === '/' || path === '') : path.startsWith(b);
                });
            }
            """
        }

        static func isAllowed(path: String) -> Bool {
            if allowedExact.contains(path) { return true }
            return allowedPrefixes.contains { path.hasPrefix($0) }
        }

        static func shouldBlock(path: String, rules: Rules) -> Bool {
            if isAllowed(path: path) { return false }
            return rules.blockedPaths.contains { b in
                if b == "/" || b.isEmpty { return path == "/" || path.isEmpty }
                return path.hasPrefix(b)
            }
        }

        /// JSON text as a JS double-quoted string literal, safe inside a user script.
        static func jsStringLiteral(_ value: String) -> String {
            let escaped = value
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
                .replacingOccurrences(of: "\n", with: "\\n")
                .replacingOccurrences(of: "\r", with: "\\r")
                .replacingOccurrences(of: "\u{2028}", with: "\\u2028")
                .replacingOccurrences(of: "\u{2029}", with: "\\u2029")
            return "\"\(escaped)\""
        }

        // MARK: Remote rules

        private func fetchAndApplyRules(webView: WKWebView, force: Bool) {
            // Don't hammer the host on every page finish unless forced
            if !force && Date().timeIntervalSince(lastFetch) <= 60 { return }

            let urlString = UserDefaults.standard.string(forKey: "rulesURL") ?? Self.defaultRulesURL
            guard let url = URL(string: urlString),
                  url.scheme?.lowercased() == "https",
                  url.host != nil else {
                #if DEBUG
                print("Insta: rules URL must be https")
                #endif
                return
            }

            var request = URLRequest(url: url)
            request.cachePolicy = .reloadIgnoringLocalCacheData
            request.timeoutInterval = 10

            pendingTask?.cancel()
            // Declared first: the completion captures it, and `let task = dataTask { ... task ... }`
            // is a use-before-declaration error in Swift.
            var task: URLSessionDataTask?
            task = URLSession.shared.dataTask(with: request) { [weak self, weak webView] data, response, error in
                let status = (response as? HTTPURLResponse)?.statusCode ?? -1
                let decoded: Rules? = {
                    guard let data = data, error == nil, status == 200 else { return nil }
                    return try? JSONDecoder().decode(Rules.self, from: data)
                }()

                DispatchQueue.main.async {
                    guard let self = self else { return }
                    if let task, self.pendingTask === task { self.pendingTask = nil }

                    guard let rules = decoded,
                          let json = (try? JSONEncoder().encode(rules)).flatMap({ String(data: $0, encoding: .utf8) })
                    else {
                        #if DEBUG
                        print("Insta: rules fetch failed (status=\(status), error=\(error?.localizedDescription ?? "nil"))")
                        #endif
                        return
                    }

                    self.lastFetch = Date()
                    self.rules = rules
                    UserDefaults.standard.set(try? JSONEncoder().encode(rules), forKey: "cachedRules")
                    // Argument passing avoids hand-escaping the JSON into a JS string.
                    webView?.callAsyncJavaScript(
                        "if (window.__applyInstaRules) window.__applyInstaRules(rulesJSON);",
                        arguments: ["rulesJSON": json],
                        in: nil,
                        in: .page
                    ) { result in
                        #if DEBUG
                        if case .failure(let err) = result { print("Insta: JS apply failed: \(err)") }
                        #endif
                    }
                }
            }
            pendingTask = task
            task?.resume()
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

    private enum CodingKeys: String, CodingKey {
        case blockedPaths, hideSelectors
    }

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

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(blockedPaths, forKey: .blockedPaths)
        try c.encode(hideSelectors, forKey: .hideSelectors)
    }
}
