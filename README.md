# Depotticker

A clean portfolio tracker for Mac, iPhone and iPad: live prices, real gains and losses in euros, readable charts, widgets, a menu bar item, CSV import and export, and a built-in MCP server for AI agents.

Website and help: https://dottenbr.github.io/depotticker/

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
- `docs` – website, help pages and the update feed (served by GitHub Pages)

## Data source

Prices, charts, key figures and news come from Yahoo Finance's public web endpoints. They are unofficial, may be delayed and can change without notice. Depotticker is not investment advice.
