# Pulsana site — what to fill in before launch

Plain HTML/CSS/JS, no build step. Open `index.html` directly in a browser,
or upload the whole folder to any static host (the `pulsana.org` domain
from your screenshots, GitHub Pages, Netlify, etc).

## Files
- `index.html` — home / project overview
- `join.html` — study agreement + placeholder "get your code" screen
- `instructions.html` — device setup walkthrough
- `faq.html` — 10 Q&A
- `contact.html` — email / WhatsApp / WeChat / contact form
- `assets/style.css` — all styling (colors match the app screenshots: sage green + cream)
- `assets/i18n.js` — every string in EN / RO / ZH — edit here to change copy or fix translations
- `assets/main.js` — language switcher + mobile nav + FAQ accordion
- `assets/join.js` — the front-end-only "reveal code" demo on join.html

## Still needs your input
1. **Photos** — every dashed rectangle is a placeholder. Swap the
   `.photo-placeholder` `<div>` for an `<img src="assets/photos/....jpg">`
   once you have the real screenshots.
2. **Video** — `.video-frame` on `instructions.html` is a placeholder.
   Once you have the tutorial, replace it with a `<video>` tag or an
   embedded player.
3. **Bracelet Bluetooth name** — search each language block in `i18n.js`
   for `instr_step3_watch_name` and fill in the real device name shown
   when scanning.
4. **Consent text** — `join_consent_li1..li5` on the join page is a
   *draft* summary I wrote for this preview, flagged as such on the page
   itself. Swap it for your faculty's reviewed consent form before this
   goes live.
5. **Real enrollment flow** — `join.html` only *previews* the "you're all
   set" screen with a hardcoded demo code (`TRCZFBPD`). Your colleague's
   backend needs to be wired in to actually generate codes and links.
6. **WeChat QR codes** — two placeholder boxes on `contact.html`, swap
   for the real QR images.
7. **Download link** — the "Download the Android app" button on
   `join.html` points to `#`; point it at your APK / Play Store link.

## Language switcher
Stored in `localStorage` under `pulsana-lang`, defaults to the visitor's
browser language (falls back to English). Add a new string anywhere by
adding the same key to all three (`en`, `ro`, `zh`) blocks in `i18n.js`
and referencing it with `data-i18n="yourKey"` in the HTML.
