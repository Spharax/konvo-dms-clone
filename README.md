# Konvo Clone – Instagram DMs Only

Personal-use iOS app that clones the core behavior of **Konvo: DMs Only**.

It loads `https://www.instagram.com` inside a `WKWebView`, injects CSS/JS to hide the Feed / Explore / Reels surfaces, and forces navigation back to `/direct/inbox/` whenever a blocked route is hit. Individual reels, posts, and stories opened from DMs remain functional.

**Personal use only. This violates Instagram’s Terms of Service. Do not distribute.**

## Architecture

- Pure SwiftUI + `WKWebView` (`UIViewRepresentable`)
- Script injected at `atDocumentStart`
- Hides elements by `href` path (language-independent) + optional aria-label fallbacks
- Navigation policy + JS history hooks redirect `/`, `/explore/`, `/reels/` → `/direct/inbox/`
- Allows `/reel/{id}/`, `/p/{id}/`, `/stories/...`, and all `/direct/` routes
- Opens directly to inbox on launch
- Remote rules JSON (fetched on each page load, last successful copy cached in `UserDefaults`)
- Optional Screen Time stub (FamilyControls / ManagedSettings) – off by default

## Project Structure

```
KonvoClone/
├── KonvoClone/
│   ├── KonvoCloneApp.swift
│   ├── ContentView.swift
│   ├── InstagramWebView.swift
│   ├── ScreenTimeManager.swift
│   └── KonvoClone.entitlements
└── rules.json
```

## Building

1. Create a new Xcode project (iOS App, SwiftUI, minimum iOS 15+).
2. Replace the generated files with the ones in this folder (or copy the sources into your project).
3. Add the four `.swift` files to your target.
4. Set the deployment target to iOS 15.0 or later.
5. In **Info.plist** (or target settings) add:
   - `NSAppTransportSecurity` if needed (usually not, Instagram is HTTPS).
   - For Screen Time: `com.apple.developer.family-controls` entitlement (requires Apple approval even for personal devices; leave disabled unless you request it).
6. Build & run on a device or simulator.

**User-Agent** is set to a recent iPhone Safari string so Instagram serves the mobile web experience.

## Remote Rules

Host the included `rules.json` somewhere reachable (GitHub raw, your own server, etc.).

Default URL in the app points to this repo:
`https://raw.githubusercontent.com/Spharax/konvo-dms-clone/main/rules.json`

In the app, open the gear icon → Settings and paste any other raw URL if you want.

On every page finish the app fetches the JSON, caches it, and re-injects the updated `blockedPaths` / `hideSelectors` into the page via `window.__applyKonvoRules`.

If the fetch fails, the last cached copy is used.

Instagram changes its DOM frequently. Update the JSON when the bottom nav or icons change; no App Store rebuild required.

## Testing Checklist

- [ ] App opens straight to `/direct/inbox/`
- [ ] Bottom navigation has no Home / Explore / Reels entry points (or they are hidden)
- [ ] Tapping a reel shared inside a DM opens and plays the reel
- [ ] Story replies open the story viewer
- [ ] Search and Profile remain usable
- [ ] Message requests and group chats work
- [ ] Password is never stored by the app (login happens entirely on Instagram’s page)

## Optional Screen Time

`ScreenTimeManager.swift` contains the skeleton for FamilyControls + ManagedSettings + DeviceActivity.

It is disabled by default. Enabling it requires:

- The Family Controls entitlement
- User authorization via `AuthorizationCenter`
- A `FamilyActivityPicker` so the user selects the Instagram app
- Logic for the two daily passes (5 min + 1 min)

This matches Konvo’s optional shield feature. Leave it off unless you specifically need it.

## Notes

- Cookies and session stay inside the `WKWebsiteDataStore`. The app never sees the password.
- For best results, test on a physical device; Instagram’s mobile web can behave differently in the simulator.
- If Instagram starts blocking the remote JSON via CSP, fall back to the cached rules or ship an updated injection script.

**Fixed bugs (2026-10-28 review):**

- Injection script was added to the configuration *after* the `WKWebView` was created, so it never ran. Now added before creation.
- Cached rules are now baked into the initial injected script so the first paint already respects the last successful rules.
- `target="_blank"` / `window.open` links (common for shared media) now load in the same web view instead of being dropped.
- Blocking logic is slightly more precise so individual `/reel/{id}/` paths are never treated as the Reels tab.
