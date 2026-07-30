# Server Control Panel

A standalone, modern editor for your server's `.ini` config files — rates, fake-player
behaviour, auto-play, premium and more. No install, no build, no login, **no Python/Flask**:
one self-contained HTML file, opened in a browser.

## Quick start

1. Open `index.html` in **Chrome / Edge / Brave** (Chromium browsers can write files in place).
2. Click **Open config folder** and pick your server's `game/config` directory.
3. Edit with the friendly panels (toggles, number boxes) or the **Raw editor** (every key in
   any file). Changed files light up.
4. Click **Save changes** — the values are written straight back into the `.ini` files.
5. In-game, run `//reload config` (or restart the server) to apply. Some settings only take
   effect on a restart.

The folder you pick is **remembered** between visits. Next time you open the page it either
loads straight away, or (if the browser has dropped write permission) shows a single **Reopen
&lt;folder&gt;** button — one click, no re-navigating the picker. Use **Pick a different folder** /
**Change folder** to point it somewhere else.

> **Firefox / Safari:** those browsers can't write files directly. The panel still works —
> click **Load config files**, edit, and it **downloads** the edited `.ini`s for you to copy
> back into `game/config` yourself.

## What it edits

- **Curated panels** — the settings that matter for the Living World, grouped and explained:
  - **Experience & SP**, **Drops & Spoil**, **Quests & Economy** (`Rates.ini`)
  - **Fake Players** (`Custom/FakePlayers.ini`) — including the AI party toggles
  - **Auto Play** (`Custom/AutoPlay.ini`)
  - **Premium** (`Custom/PremiumSystem.ini`)
- **Raw editor** — every key in any `.ini` in the folder, for power users.

Fields tagged **new** (phantom party XP/SP share, phantom loot/adena share, recruit enchant
chance & range) are backed by new server code. That code only has to be compiled into
`GameServer.jar` **once** (a one-time build step when the server is updated — not something you
do to change a value). Once a server build that includes them is running, they apply with
`//reload config` just like every other setting here.

## Safety

Saving only rewrites the **value** of keys that already exist, preserving every comment,
banner and blank line exactly (the same approach the in-game `//rates` panel uses). A key
that isn't in your file yet (older install) is appended at the end of that file. Nothing is
reordered or deleted. The parser has been round-trip verified against the shipped configs.
