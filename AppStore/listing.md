# App Store listing (draft)

Screenshots with demo data are in `screenshots/` (iPhone 6.9": 1320 × 2868, iPad 13": 2064 × 2752).
The Mac listing can use `docs/img/mac-overview.png` as a starting point (App Store needs 2880 × 1800).

- **Name:** Depotticker
- **Subtitle:** Your whole portfolio at a glance
- **Bundle ID:** com.depotticker.app (Mac, iPhone and iPad as one universal purchase)
- **Category:** Finance
- **Price:** Free
- **Age rating:** 4+
- **Support URL:** https://depotticker.com/help/
- **Marketing URL:** https://depotticker.com/
- **Privacy policy URL:** https://depotticker.com/privacy/

## Promotional text (170 characters)

All your depots in one place: current prices, real gains in euros, clean charts and widgets. No account, no tracking.

## Description

Depotticker shows every share and fund you own, across all your brokers, in one clean view.

• Several depots, one total. The same share held at two brokers is added up and shown lot by lot.
• Real gains. Value, today's change and total gain in euros, with costs kept in the currency you paid in.
• Purchases and sales. Record each one with date and price, or let the app estimate missing dates from your average price.
• Charts that read well. Pinch to change the range, drag to measure a move, with volume, moving average and your average cost.
• Prices from a licensed vendor with your own API key (EODHD), sent straight from your device.
• Widgets in three sizes, and on the Mac a compact menu bar item that can hide amounts while you share your screen.
• Import and export as CSV, including the Raymond James export.
• Your data stays yours. Positions are stored on your devices and synced through your own iCloud. There is no account and no tracking.

Depotticker is not a broker and gives no investment advice. Prices are delayed by about 15 minutes. A price source with your own API key is required to show prices.

## Keywords (100 characters)

portfolio,stocks,depot,shares,ETF,ticker,widget,gains,dividends,broker,watchlist,euro,investing

## App privacy answers

Data collection: none. The app sends ticker symbols to the price provider to fetch quotes; no identifiers, no analytics, no third-party SDKs for tracking.

## Review notes

No sign-in is needed. Prices need an API key from the data vendor EODHD: open the menu at the top right, choose Price Source…, select EODHD and enter the key given here: <key for review>. Then add a position with the + button (for example AAPL, 10 shares at 150) to see every screen.

## Before submitting

- Done in 0.3: the App Store builds contain no Yahoo code; prices come from EODHD with the user's own key, exchange rates from the ECB.
- Get EODHD's written confirmation that user keys in a free open-source app are allowed (guideline 5.2.2: proof on request).
- Give App Review a way to see prices: a key for the review notes, or a demo mode.
- Sign with an Apple Distribution certificate; enable iCloud (key-value storage) and the app group `group.com.depotticker.app`.
