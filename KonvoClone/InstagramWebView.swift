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
        
        // Add the injection script BEFORE creating the web view
        let script = WKUserScript(
            source: context.coordinator.injectionScript,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true
        )
        configuration.userContentController.addUserScript(script)
        configuration.userContentController.add(context.coordinator, name: "rulesHandler")
        
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.customUserAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1"
        
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        
        // Open directly to inbox
        if let url = URL(string: "https://www.instagram.com/direct/inbox/") {
            webView.load(URLRequest(url: url))
        }
        
        return webView
    }
    
    func updateUIView(_ uiView: WKWebView, context: Context) {}
    
    func makeCoordinator() -> Coordinator {
        Coordinator()
    }
    
    class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {
        let injectionScript: String
        private var cachedRules: Rules?
        
        override init() {
            // Default rules that can be overridden by remote JSON
            let defaultRules = Rules(
                blockedPaths: ["/", "/explore/", "/reels/"],
                hideSelectors: [
                    "a[href='/']",
                    "a[href='/explore/']",
                    "a[href='/reels/']",
                    "a[href*='/explore/']",
                    "a[href*='/reels/']"
                ]
            )
            
            // Try to load cached rules for the initial script
            if let data = UserDefaults.standard.data(forKey: "cachedRules"),
               let rules = try? JSONDecoder().decode(Rules.self, from: data) {
                cachedRules = rules
            } else {
                cachedRules = defaultRules
            }
            
            let rulesJSON = (try? String(data: JSONEncoder().encode(cachedRules!), encoding: .utf8)) ?? "{}"
            
            self.injectionScript = """
            (function() {
                window.__konvoRules = \(rulesJSON);
                
                const DEFAULT_BLOCKED = ['/', '/explore/', '/reels/'];
                const INBOX = '/direct/inbox/';
                
                function getRules() {
                    return window.__konvoRules || { blockedPaths: DEFAULT_BLOCKED, hideSelectors: [] };
                }
                
                function pathShouldBlock(path) {
                    const rules = getRules();
                    const blocked = rules.blockedPaths || DEFAULT_BLOCKED;
                    return blocked.some(b => {
                        if (b === '/' || b === '') return path === '/' || path === '';
                        // Exact match or starts with the blocked path (but not individual media)
                        return path === b || (path.startsWith(b) && !path.includes('/reel/') && !path.includes('/p/') && !path.includes('/stories/'));
                    });
                }
                
                function redirectIfNeeded() {
                    const path = location.pathname;
                    if (pathShouldBlock(path)) {
                        console.log('[Konvo] Redirecting from', path, 'to', INBOX);
                        location.replace(INBOX);
                    }
                }
                
                function applyHide() {
                    const rules = getRules();
                    const selectors = rules.hideSelectors || [];
                    
                    // Apply remote/default selectors
                    selectors.forEach(sel => {
                        try {
                            document.querySelectorAll(sel).forEach(el => {
                                el.style.setProperty('display', 'none', 'important');
                                el.style.setProperty('visibility', 'hidden', 'important');
                            });
                        } catch (e) {}
                    });
                    
                    // Persistent CSS
                    let style = document.getElementById('konvo-style');
                    if (!style) {
                        style = document.createElement('style');
                        style.id = 'konvo-style';
                        document.head.appendChild(style);
                    }
                    style.textContent = `
                        a[href="/"], a[href="/explore/"], a[href="/reels/"],
                        a[href*="/explore/"], a[href*="/reels/"] {
                            display: none !important;
                            visibility: hidden !important;
                        }
                    `;
                }
                
                function setup() {
                    applyHide();
                    redirectIfNeeded();
                    
                    const obs = new MutationObserver(() => {
                        applyHide();
                        redirectIfNeeded();
                    });
                    obs.observe(document.documentElement || document.body, {
                        childList: true,
                        subtree: true
                    });
                    
                    // SPA navigation hooks
                    const origPush = history.pushState;
                    history.pushState = function() {
                        origPush.apply(this, arguments);
                        setTimeout(() => { applyHide(); redirectIfNeeded(); }, 50);
                    };
                    const origReplace = history.replaceState;
                    history.replaceState = function() {
                        origReplace.apply(this, arguments);
                        setTimeout(() => { applyHide(); redirectIfNeeded(); }, 50);
                    };
                    window.addEventListener('popstate', () => setTimeout(() => { applyHide(); redirectIfNeeded(); }, 50));
                }
                
                if (document.readyState === 'loading') {
                    document.addEventListener('DOMContentLoaded', setup);
                } else {
                    setup();
                }
                
                window.__applyKonvoRules = function(rules) {
                    window.__konvoRules = rules;
                    applyHide();
                    redirectIfNeeded();
                };
            })();
            """
            super.init()
        }
        
        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            // Reserved for future use
        }
        
        // Handle target="_blank" or window.open by loading in the same web view
        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
            if navigationAction.targetFrame == nil {
                webView.load(navigationAction.request)
            }
            return nil
        }
        
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            fetchAndApplyRules(webView: webView)
        }
        
        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            guard let url = navigationAction.request.url,
                  url.host?.contains("instagram.com") == true else {
                decisionHandler(.allow)
                return
            }
            
            let path = url.path
            
            // Always allow individual media and all DM routes
            if path.contains("/reel/") || path.contains("/p/") || path.contains("/stories/") || path.hasPrefix("/direct/") {
                decisionHandler(.allow)
                return
            }
            
            let blocked = cachedRules?.blockedPaths ?? ["/", "/explore/", "/reels/"]
            let shouldBlock = blocked.contains { b in
                if b == "/" || b == "" { return path == "/" || path.isEmpty }
                return path == b || path.hasPrefix(b)
            }
            
            if shouldBlock {
                if let inbox = URL(string: "https://www.instagram.com/direct/inbox/") {
                    webView.load(URLRequest(url: inbox))
                }
                decisionHandler(.cancel)
                return
            }
            
            decisionHandler(.allow)
        }
        
        private func fetchAndApplyRules(webView: WKWebView) {
            let urlString = UserDefaults.standard.string(forKey: "rulesURL") ?? "https://raw.githubusercontent.com/Spharax/konvo-dms-clone/main/rules.json"
            guard let url = URL(string: urlString) else { return }
            
            URLSession.shared.dataTask(with: url) { [weak self] data, _, error in
                guard let self = self, let data = data, error == nil else { return }
                do {
                    let rules = try JSONDecoder().decode(Rules.self, from: data)
                    self.cachedRules = rules
                    self.saveRules(rules)
                    let json = String(data: try JSONEncoder().encode(rules), encoding: .utf8) ?? "{}"
                    DispatchQueue.main.async {
                        let js = "if (window.__applyKonvoRules) window.__applyKonvoRules(\(json));"
                        webView.evaluateJavaScript(js, completionHandler: nil)
                    }
                } catch {
                    print("Rules decode error: \(error)")
                }
            }.resume()
        }
        
        private func saveRules(_ rules: Rules) {
            if let data = try? JSONEncoder().encode(rules) {
                UserDefaults.standard.set(data, forKey: "cachedRules")
            }
        }
    }
}

struct Rules: Codable {
    var blockedPaths: [String]
    var hideSelectors: [String]
}
