# Releasing Radio Taiso 64

The checklist for getting a version out. Everything below uses the kit that
`make release VERSION=x.y` writes to `build/release/`:

| file | use |
|---|---|
| `RadioTaiso64_v<x.y>.zip` | the download: prg + d64 + README.txt + 2x screenshots |
| `RadioTaiso64.d64`, `RadioTaiso64.prg` | loose copies for sites that want a bare image/file |
| `README.txt` | release notes (paste into descriptions) |
| `screenshots/*.png` | 2x, crisp (768 px wide) for itch.io, Lemon64, forums, social |
| `screenshots-native/*.png` | 384 px wide, for CSDb (native resolution) |
| `cover-itch-630x500.png` | itch.io cover image |

Keep one identity everywhere: name **Radio Taiso 64**, author **Advancing
Development**, year, the ko-fi and radiotaiso.org links, and the credit line
"Coded with assistance from Anthropic's Claude" (in the README and in every
description — the scene appreciates disclosure, and it forestalls questions).

## 0. Cut the version

1. Bump `VERSION` in the Makefile if this is not the number already there;
   update the status log in `HANDOFF.md` and the notes in `release/README.txt`
   if the feature list changed.
2. `make test` (all screenshots OK), `make run` for a real-time check.
3. `make release VERSION=x.y`, look at every PNG in `build/release/screenshots/`.
4. `git commit`, then `git tag -a v<x.y> -m "Radio Taiso 64 v<x.y>"`.

## 1. GitHub — source and the canonical download (do this first)

Every other listing wants a stable URL and most reviewers look for source.

1. The code is MIT-licensed (`LICENSE`, added 2026-09-04); the music is your
   own, the Shinonome font is public domain (`tools/fonts/README.md`).
2. The repo is https://github.com/AdvancingDevelopment/c64radiotaiso (created
   with `gh repo create c64radiotaiso --public --source=. --push`). Push the
   branch and the tag: `git push origin main v<x.y>`.
3. `gh release create v<x.y> build/release/RadioTaiso64_v<x.y>.zip
   build/release/RadioTaiso64.d64 build/release/RadioTaiso64.prg
   --title "Radio Taiso 64 v<x.y>" --notes-file build/release/RELEASE_NOTES.md`
   (`RELEASE_NOTES.md` is generated from `release/NOTES.md`).
4. Put the release URL into the itch/CSDb/archive descriptions.

## 2. itch.io — the friendly storefront

1. Account: https://itch.io/register (pick a URL slug, e.g. `advancing`).
   Dashboard → "Create new project".
2. Fields: Title "Radio Taiso 64"; Project URL slug `radio-taiso-64`;
   Classification "Game" (best discoverability; "Tool" is the honest
   alternative); Kind of project "Downloadable"; Release status "Released";
   Pricing "No payments" or "$0 or donate" (pay-what-you-want with a $0
   minimum, which fits the ko-fi link); Uploads: the zip (label it "All
   files"), plus the .d64 and .prg on their own (tick no OS — C64 files);
   Genre "Sports" (closest) ; Tags: `commodore-64`, `c64`, `8-bit`, `retro`,
   `fitness`, `exercise`, `japanese`, `radio-taiso`, `demoscene`, `homebrew`;
   Made with "ACME, VICE"; Average session "A few minutes"; Inputs
   "Keyboard, Joystick"; Languages "English, Japanese".
3. Cover: `cover-itch-630x500.png`. Screenshots: all six from
   `screenshots/`. Description: the README text reworked into two or three
   short paragraphs plus the key table; link radiotaiso.org and the GitHub
   release; mention PAL/NTSC and "LOAD"*",8 / RUN".
4. Optional but worth it: a 30-60 s video. VICE → Media → "Record movie"
   (ffmpeg is installed), or record the screen; upload it to YouTube and
   paste the link in the itch page's video field.
5. Publish: set visibility "Public", then write a first devlog post ("v1.0
   released") — devlogs show up in itch's feeds.
6. Optional: a browser-playable version. itch can host an HTML5 build; a
   page embedding a JS C64 emulator with the .d64 (e.g. the VICE.js or
   c64js projects) lets people try it without downloading. Check the
   emulator's licence and that it handles the border tricks first.

## 3. CSDb — the C64 scene database (csdb.dk)

1. Register (https://csdb.dk → "Register"); accounts are approved by hand,
   allow a day. Add yourself as a scener (handle "Advancing" or your name)
   and, if you want the group credit, a group "Advancing Development".
2. "Add release": name "Radio Taiso 64"; type "C64 Game" (or "C64 Misc." —
   it is a fitness follow-along, either is accepted; Game gets more eyes);
   release date; released by your scener/group; credits: Code, Music,
   Graphics, Design → you, and in the release notes state the Claude
   assistance plainly (CSDb credits are for people). Download: upload the
   zip (CSDb hosts it) and/or link the GitHub release. Screenshots: use
   `screenshots-native/` (CSDb wants native-resolution PNGs, 384x272 PAL and
   384x247 NTSC are fine). Notes: the README text; mention PAL+NTSC.
3. Expect comments and a rating. Bug reports there are worth acting on
   (real-hardware users). A fix is a new version entry or an update to the
   same entry with a note.
4. Post a short announcement in the CSDb forum "News" thread only if there
   is one for new releases; otherwise the entry itself is the announcement.

## 4. Lemon64 — the C64 games site (lemon64.com)

1. Database entries are added by the Lemon64 staff from submissions:
   register on the site, then use the game submission / "missing game"
   form (Contribute menu) with title, developer/publisher "Advancing
   Development", year 2026, genre, PAL/NTSC, a link to the download (GitHub
   or itch) and a couple of 2x screenshots.
2. Announce it on the Lemon64 forums (register separately) in the
   Games / Homebrew section: title, a screenshot, the itch and GitHub links,
   one paragraph, keys. Reply to questions; the forum is where feedback lands.

## 5. Internet Archive — permanent home (archive.org)

1. Account at https://archive.org/account/signup, then "Upload".
2. One item: the zip, the .d64, the .prg, README.txt and the screenshots.
   Metadata: title "Radio Taiso 64 (Commodore 64, 2026)"; media type
   "Software"; description (README); subject tags "Commodore 64; C64; Radio
   Taiso; homebrew; radio calisthenics; 2026"; language "English; Japanese";
   creator "Advancing Development"; date; licence (Creative Commons or
   "Free to download and share", matching README.txt).
3. In-browser play: the Archive runs C64 software in the browser when an
   item carries the emulation metadata (an `emulator` field naming the
   VICE C64 profile and `emulator_ext` for the d64). The exact field values
   change over time — check the current Internet Archive help page on
   software emulation ("Emularity") before setting them; if they do not
   apply, the item is still a fine permanent download.

## 6. Also worth listing (optional, 10 minutes each)

- **Demozoo** (demozoo.org) — demoscene database, cross-links CSDb; add the
  production under your scener/group with the same files and screenshots.
- **Pouet** (pouet.net) — add as type "game" (platform C64) with a download
  link and a screenshot; comments and thumbs come from the scene.
- **GameBase64** (gb64.com) — the big C64 games database; submissions go
  through their forum/contact, they want the d64 and screenshots.
- **Indie Retro News** and **Vintage is the New Old** — tip forms/emails for
  new homebrew; send the itch link, three screenshots and the one-paragraph
  blurb.

## 7. Announce

- radiotaiso.org: a "C64 version" page/link to the itch page (and the
  GitHub release), with one screenshot and the keys.
- Reddit: r/c64, r/Commodore, r/retrogaming (respect self-promo rules; one
  post each, with a screenshot and the free link).
- Mastodon / Bluesky / X: #c64 #commodore64 #demoscene #retrogaming
  #radiotaiso; a 20-second clip beats a screenshot.
- Forums: Lemon64 (see above), the CSDb entry, AtariAge's "Other 8-bit"
  is not the place (Atari); the "C64 Scene Database" Facebook groups and
  the Commodore Users groups pick up itch links.
- Ko-fi: a post there pointing at the release, since the program links to it.

## 8. After the release

- Watch CSDb/Lemon64/itch comments for real-hardware reports (PAL vs NTSC,
  SD2IEC loading, joystick ports).
- Fixes: bump `VERSION` (1.0.1), repeat section 0, update the GitHub release,
  itch uploads (keep the old zip as well, itch shows both) and the CSDb entry.
