# Depotticker

A clean portfolio tracker for Mac, iPhone and iPad: current prices, real gains and losses in euros, readable charts, widgets, a menu bar item, CSV import and export, and a built-in MCP server for AI agents.

Website and help: https://depotticker.com/

## Install

Download the latest Mac build from [Releases](https://github.com/dottenbr/depotticker/releases/latest), unzip it and move Depotticker to Applications. It needs macOS 26 or later on Apple silicon and updates itself.

## Build

| What | How |
| --- | --- |
| Direct-download Mac app (Developer ID, Sparkle updates) | `./build.sh install` |
| Release archive and update feed | `./build.sh release` |
| App Store builds for Mac, iPhone and iPad | `xcodegen` then open `Depotticker.xcodeproj` |

The direct build needs the full Xcode (the Command Line Tools alone lack the SwiftUI macro plugin). The App Store project needs [XcodeGen](https://github.com/yonaskolb/XcodeGen).

## Layout

- `Sources/Depotticker` – the app, shared by all platforms
- `Widget` – the WidgetKit extension
- `Config`, `Resources`, `project.yml` – App Store project, entitlements, icons, privacy manifest
- `Support`, `build.sh` – direct-download build
- `site` – the website (Astro), including help pages and the update feed
- `docs` – only the update feed and a redirect at the old GitHub Pages address, for version 0.1
- `Tests` – unit tests for the calculations and the importers (`swift test`)
- `AppStore` – listing texts and screenshots

## Data source

Exchange prices are licensed data, so Depotticker ships without a built-in price feed. Each user picks a source in the app (Settings › Price source):

- **German exchanges (free)**: the delayed trade files Deutsche Börse publishes under MiFIR Article 13 for Xetra, Frankfurt and Tradegate, 15 minutes delayed, no key. The app downloads the whole-market files on the user's device, paced to respect the file service's rate limit, and keeps only the user's ISINs (`DeutscheBoerse.swift`). ISINs come from ESMA's instrument register and OpenFIGI (`Instruments.swift`). No history: closes are collected from first use.
- **EODHD** with the user's own API key. The app talks to EODHD directly from the user's device; prices are delayed by about 15 minutes, and daily closes are split-adjusted in the app. A portfolio needs one of EODHD's paid personal plans.
- **Yahoo Finance (unofficial)**, in the direct-download build only (compile flag `DIRECT`). Yahoo's terms do not permit automated access, so it is never the default; installs that already used it keep it until they switch. The App Store builds contain no Yahoo code.

Exchange rates with every source except Yahoo are the European Central Bank's euro reference rates (one fixing per working day, free to reuse with the source named).

Depotticker is not investment advice.

## Website

The site in `site/` is built with [Astro](https://astro.build) and served from https://depotticker.com by a Cloudflare Worker (`wrangler.jsonc`). It does not deploy on push.

```sh
pnpm --dir site install
pnpm --dir site dev      # local preview
pnpm --dir site run deploy   # build and deploy; needs CLOUDFLARE_API_TOKEN and CLOUDFLARE_ACCOUNT_ID
```

`./build.sh release` writes the update feed to `site/public/appcast.xml` and the version to `site/src/release.json`, so deploy the site after publishing a release.

## Licence

MIT, see [LICENSE](LICENSE). Depotticker uses [Sparkle](https://sparkle-project.org) (MIT) for updates in the direct-download Mac build.
