<div align="center">

<img src="assets/banner.svg" alt="Artifact Widgets" width="100%">

<br>

[![macOS](https://img.shields.io/badge/macOS-14%2B-000000?logo=apple&logoColor=white)](#install)
[![Swift](https://img.shields.io/badge/Swift-5-F05138?logo=swift&logoColor=white)](Sources/main.swift)
[![Universal](https://img.shields.io/badge/Apple%20Silicon%20%2B%20Intel-universal-blue)](#build-from-source)
[![License: MIT](https://img.shields.io/badge/license-MIT-green)](LICENSE)
[![Download](https://img.shields.io/github/v/release/baldiga/artifact-widgets?label=download&logo=apple&color=d97757)](https://github.com/baldiga/artifact-widgets/releases/latest)

**Pin your [Claude](https://claude.ai) artifacts to the macOS desktop as live, interactive widgets.**
Dashboards, trackers, scorecards, and anything else you've published as an artifact.

</div>

---

## Why

Artifacts are great, but they live in a browser tab. Artifact Widgets puts the ones you check every day right on your desktop, always up to date, with no tab-hunting.

## Features

| | |
|---|---|
| 🔴 **Live** | Each widget is a real web view signed in to your claude.ai account, so artifacts that pull live data keep updating, even while covered by other windows. |
| 🪟 **Looks like a widget** | No title bar. claude.ai's page bar and toolbars are hidden so only the artifact shows. |
| 📋 **Pick from your account** | *New Widget → From Your Account* lists your artifacts (and ones shared with you), most recently viewed first. |
| 🖥️ **Lives on the desktop** | Above desktop icons, below normal windows, on every Space. Or float widgets above everything. |
| ➕ **As many as you want** | Every widget has its own artifact, size, position, zoom and auto-refresh. |

## Install

1. Download **[`Artifact-Widgets-1.0.dmg`](https://github.com/baldiga/artifact-widgets/releases/latest/download/Artifact-Widgets-1.0.dmg)** from the [latest release](https://github.com/baldiga/artifact-widgets/releases/latest), open it, and drag the app to **Applications**.
2. Launch it. The app isn't signed with an Apple developer ID, so the first launch needs **System Settings → Privacy & Security → Open Anyway** (one time only).
3. Sign in to claude.ai in the window that opens, then click the grid icon in the menu bar → **New Widget → From Your Account**.

> Requires macOS 14 (Sonoma) or newer, on Apple Silicon or Intel.

## Usage

| Where | What |
|---|---|
| **Menu bar grid icon** | New Widget (from your account, a saved list, or any link), Reload All, Keep Widgets Above Windows, Sign in, Launch at Login |
| **Hover a widget** | A pill appears top-right: drag the arrows to move, `≡` for the widget menu |
| **`≡` widget menu** | Switch artifact, Reload, Auto-refresh, Zoom, Hide claude.ai Toolbars, Open in Browser, New Widget, Remove |
| **⌘-drag** | Move a widget by dragging anywhere on it |
| **Widget edges** | Resize |

## Build from source

Needs only Apple's Command Line Tools (`xcode-select --install`), not full Xcode.

```bash
git clone https://github.com/baldiga/artifact-widgets.git
cd artifact-widgets

./build.sh --install    # build and install to ~/Applications
./build.sh --package    # build and make dist/Artifact-Widgets-1.0.dmg
```

Releases are built the same way by GitHub Actions on a Mac runner ([`.github/workflows/release.yml`](.github/workflows/release.yml)): bump `VERSION` in `build.sh`, then run the **Release** workflow from the Actions tab (or push a `v<VERSION>` tag) and the DMG is attached to a new release.

`build.sh` compiles `Sources/main.swift` for arm64 and x86_64, merges them with `lipo`, adds the icon (`Resources/AppIcon.icns`, drawn by `tools/make_icon.swift`) and ad-hoc signs the bundle.

## How it works

<details>
<summary><b>Under the hood</b></summary>

<br>

- **Widgets** are `NSWindow`s at desktop-icon level + 1 with a transparent title bar, each holding a `WKWebView`. All web views share the default persistent `WKWebsiteDataStore`, so one claude.ai sign-in covers every widget and survives restarts.
- **Clean mode** injects a stylesheet into the artifact page and into the artifact's frame (`*.claudeusercontent.com`) that hides claude.ai's top bar, bottom toolbar, tips and the artifact runtime's toolbar. claude.ai's Content Security Policy blocks `<style>` tags, so it uses a constructed stylesheet (`document.adoptedStyleSheets`).
- **Live while covered:** WebKit normally suspends pages in hidden windows. The app turns off window-occlusion detection on each web view so live data keeps loading.
- **From Your Account** loads claude.ai's Artifacts gallery in a hidden, off-screen web view and reads the list that page itself requests. The result is cached so the picklist shows instantly; it refreshes at launch and when a menu opens (at most every 5 minutes).

</details>

> ⚠️ This relies on how claude.ai's pages are built, so a claude.ai update can break clean mode or the account picklist. Widgets and saved links keep working regardless. The CSS selectors are at the top of `Sources/main.swift` (`pageCSS`, `frameCSS`).

## Files on your Mac

Everything lives in `~/Library/Application Support/ArtifactWidgets/`:

| File | Purpose |
|---|---|
| `widgets.json` | Your widgets and saved list (menu bar → Edit Config File, then Reload Config File) |
| `account_artifacts.json` | Cached account artifact list |
| `log.txt` | Load and error log |
| `debug` | Create this empty file to log a content summary of every page and frame after it loads |

**Uninstall:** quit from the menu bar, delete the app, and delete the folder above.

## Disclaimer

Unofficial, and not affiliated with or endorsed by Anthropic.

## Author

Built by **[Amir Baldiga](https://amirbaldiga.com)**, GTM engineer building in public. [LinkedIn](https://linkedin.com/in/amirbaldiga) · [GitHub](https://github.com/baldiga)

## License

[MIT](LICENSE) © 2026 Amir Baldiga
