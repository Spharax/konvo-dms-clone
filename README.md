# Insta – Instagram DMs Only

Personal-use iOS app that loads `https://www.instagram.com` in a `WKWebView`, hides the Home / Explore / Reels entry points, and bounces those routes back to `/direct/inbox/`. Reels, posts, and stories opened from DMs still work.

**Personal use only. This violates Instagram's Terms of Service. Do not distribute.**

## Setup

1. New Xcode project: iOS App, SwiftUI, **minimum deployment target iOS 16.0**.
2. Delete the generated `ContentView.swift` / app file and add everything in `Insta/` to the target.
3. **App name:** Target → General → *Display Name* = `Insta`
   (or build setting `INFOPLIST_KEY_CFBundleDisplayName = Insta`, or `CFBundleDisplayName` in Info.plist).
4. Target → Signing & Capabilities → set `Insta.entitlements` as the entitlements file only if you need Screen Time (otherwise leave it unset).
5. Host `rules.json` (GitHub raw etc.) and set the URL in the in-app Settings (gear icon). Push the updated `rules.json` in this folder to your repo.

App icon is not included. Add an `AppIcon` asset catalog and set `ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon` if you want one.

## Review fixes (2026-10-28)

- **Infinite mutation loop (CPU/battery):** `applyHide()` rewrote `style.textContent` on every DOM mutation, which itself triggered the observer again. CSS is now only written when it changes, and the observer only watches for the `<style>` tag being removed.
- Hide rules are now emitted as CSS, one rule per selector, so remote `hideSelectors` also apply to elements added later and one bad selector can't break the rest. (Before, the persistent CSS was hardcoded and ignored the remote list.)
- `autocorrectionDisabled()` and `AuthorizationCenter.requestAuthorization(for:)` are iOS 16 APIs, but the README said iOS 15 → compile errors. Minimum is now iOS 16.
- Back navigation: added `allowsBackForwardNavigationGestures` (swipe back after opening a reel/post/story).
- Data race: remote rules were assigned from a background `URLSession` thread while the navigation delegate read them on main. Now applied on the main thread.
- Navigation policy only judges main-frame navigations (an iframe pointing at `/` could previously redirect the whole app).
- Remote fetch now checks for HTTP 200, throttles to once per 60 s, and tolerates missing keys in the JSON.
- JS redirect and history hooks now install immediately at document start instead of waiting for `DOMContentLoaded`.
- `rules.json`: removed the wildcard `[aria-label*='Home'|'Explore'|'Reels']` and `a[href*='/explore'|'/reels']` selectors, which could hide unrelated elements and links inside DM threads.
- Screen Time toggle was a no-op; it's now disabled and labelled as not implemented.
- Removed unused `rulesHandler` message handler and unused `import WebKit` in the app file.

## Additional fixes (post-review)

- Settings changes to the rules URL now post a notification that forces an immediate refetch (bypassing the 60 s throttle) and applies the new rules without requiring a manual navigation.
- Remote rules are passed to JS as a JSON string and `JSON.parse`d, avoiding fragile object-literal interpolation.
- Fetch failures (network, non-200, decode) now log in DEBUG builds.
- In-flight `URLSession` tasks are cancelled on deinit and on a new fetch.
- MutationObserver also watches `subtree` for more reliable style re-attachment.
- History hook guards against non-function originals.
- ScreenTimeManager marked as unused stub.
- Removed leftover old `KonvoClone/` sources.
- Dropped `ASSETCATALOG_COMPILER_APPICON_NAME` (no asset catalog in the repo).

## Known behavior to test on a device

- Instagram's mobile-web **Search** tab goes through `/explore/`, which is blocked, so Search will likely bounce to the inbox. Allow-list `/explore/search/` in `blockedPaths` logic if you need it.
- The gear button sits over the top-right corner of Instagram's header.
- Instagram changes its DOM often; update `rules.json` rather than rebuilding.

## Getting an .ipa (no Mac needed)

1. Push this whole folder to a GitHub repo (keep `project.yml`, `Insta/`, and `.github/`).
2. GitHub → Actions → **Build IPA** → Run workflow (it also runs on every push to `main`).
3. When it finishes, download the `Insta-ipa` artifact and unzip it to get `Insta.ipa`.
4. The IPA is **unsigned**. Install it with Sideloadly or AltStore, which sign it with your Apple ID.
   (Free Apple IDs: the app expires after 7 days and must be re-signed.)

Or with a Mac: open the project in Xcode → Product → Archive → Distribute App → Custom → Development/Ad Hoc.
