# Server Control Panel

A standalone, modern editor for your server's `.ini` config files - rates, fake-player
behaviour, auto-play, premium and more - **plus a visual editor for how recruited phantoms
fight**. No install, no build, no login, **no Python/Flask**: one self-contained HTML file,
opened in a browser.

## Quick start

1. Open `index.html` in **Chrome / Edge / Brave** (Chromium browsers can write files in place).
2. Click **Open config folder** and pick your server's `game/config` directory.
3. Edit with the friendly panels (toggles, number boxes) or the **Raw editor** (every key in
   any file). Changed files light up.
4. Click **Save changes** - the values are written straight back into the `.ini` files.
5. In-game, run `//reload config` (or restart the server) to apply. Some settings only take
   effect on a restart.

The folder you pick is **remembered** between visits. Next time you open the page it either
loads straight away, or (if the browser has dropped write permission) shows a single **Reopen
&lt;folder&gt;** button - one click, no re-navigating the picker. Use **Pick a different folder** /
**Change folder** to point it somewhere else.

> **Firefox / Safari:** those browsers can't write files directly. The panel still works -
> click **Load config files**, edit, and it **downloads** the edited `.ini`s for you to copy
> back into `game/config` yourself.

## What it edits

- **Curated panels** - the settings that matter for the Living World, grouped and explained:
  - **Experience & SP**, **Drops & Spoil**, **Quests & Economy** (`Rates.ini`)
  - **Fake Players** (`Custom/FakePlayers.ini`) - including the AI party toggles
  - **Auto Play** (`Custom/AutoPlay.ini`)
  - **Premium** (`Custom/PremiumSystem.ini`)
- **Raw editor** - every key in any `.ini` in the folder, for power users.
- **Phantom Playstyles** - a visual editor for `game/data/PhantomPlaystyles.xml` (see below).

Fields tagged **new** (phantom party XP/SP share, phantom loot/adena share, recruit enchant
chance & range) are backed by new server code. That code only has to be compiled into
`GameServer.jar` **once** (a one-time build step when the server is updated - not something you
do to change a value). Once a server build that includes them is running, they apply with
`//reload config` just like every other setting here.

## Phantom Playstyles

This tab edits **how recruited phantoms fight**: which skills each class lineage uses, under
what conditions, and - most importantly - **in what order**. Order *is* priority: the engine
casts the first listed entry whose conditions pass, so dragging a row up genuinely changes
behaviour. That ordering is invisible in a text editor, which is the main reason this tab exists.

It reads a **different folder** from the config panels - your server's `game/data` directory -
picked separately and remembered on its own. Click **Open data folder** in the tab (you can
point it at `game/data`, at `game`, or at the pack root and it will find the rest). The first
open indexes the skill and skill-tree data next to the playstyle file, which takes a moment;
after that it's cached and instant until the datapack changes.

What it gives you:

- **The real skill data** on every row - MP cost, reuse, cast range, weapon requirement - read
  from your own `stats/skills`, not a hardcoded table.
- **A level slider (1–80).** Rows the member can't use at that level are dimmed, with *learned
  at 36* on the ones it hasn't reached. This answers "what does my level-25 archer actually
  cast?" by dragging a slider. (Answer: Power Shot. That's the whole kit until 36.)
- **Drag to reorder**, or the ↑/↓ buttons.
- **A condition builder** generated from the schema: pick `MOBS_NEAR` and the "how many" box
  appears. You can't write a condition without its parameter, or a parameter without its condition.
- **An add-skill picker filtered to the lineage** - only skills those classes actually learn,
  each annotated with its learn level. Skills the party manager owns (taunts, Ultimate Defense,
  Sleep, Dryad Root, Resurrection) are blocked, because the manager casts those with its own
  threat/survival logic and two systems fighting over them is a bug.
- **New / clone / delete playstyles**, including for lineages that have none today.
- **Live warnings** - the same rules as `tools/validate_playstyles.py`, shown inline: a skill the
  lineage never learns, a duplicate class claim that would make the entry dead code, a coverage
  hole that would leave a member with nothing to cast at some level.

Save, then run **`//phantom playstyle`** in-game. No restart, no jar rebuild - the change is live
immediately, so you can tune a rotation while standing next to the party.

### Skill icons (optional)

**There is no folder on your server you can point this at.** The server files contain no artwork at
all - every skill only *names* its icon (`<icon>icon.skill0056</icon>`) and the game client resolves
that name against its own textures at render time. So the folder has to be one you create.

The pictures live in your **client**, not your server:

```
<Lineage 2 client>\systextures\Icon.utx
```

(The reference `icon.skill0056` reads as package `Icon`, texture `skill0056` - so `Icon.utx` is the
package holding them.)

To get them out:

1. Open `systextures\Icon.utx` with an Unreal package tool - **UModel** (`umodel.exe`) is the usual
   choice; older L2 tools like Unreal Package Explorer also work.
2. Export the textures as **PNG** into any folder you like.
3. In this tab, click **Choose icon folder** and pick that folder.

The panel searches the folder **and one level of subfolders**, case-insensitively, so you don't have
to flatten or rename anything - most tools export into a `Icon\` subfolder and that works as-is. It
then tells you exactly what it found, e.g. *"Indexed 3,412 images - matched 91 of the 95 skill icons
in this file"*, so a wrong folder is obvious immediately rather than silently showing nothing.

Formats read: `.png`, `.jpg`, `.webp`, `.gif`, `.bmp`. **Not `.tga`** - browsers can't display it, so
if your tool defaults to TGA, switch the export to PNG.

Without an icon folder, rows show colour-coded type badges instead. That's the design's primary
visual language anyway: what you're tuning is *when* a skill fires and in what order, which a
ROTATION/CONTROL/AOE chip says more clearly than 32×32 client art does.

### Two things the editor will tell you, but that are worth knowing up front

- **Support classes** (Bishop, Prophet, Elder, Warcryer, Overlord and their lines) ignore
  playstyles entirely - the party manager's support tick plays those classes. You can write one,
  but nothing will read it.
- **Summoner lineages** work, but only the caster's own skills fire; servitor control isn't
  implemented yet.

## Safety

For `.ini` files, saving only rewrites the **value** of keys that already exist, preserving every
comment, banner and blank line exactly (the same approach the in-game `//rates` panel uses). A key
that isn't in your file yet (older install) is appended at the end of that file. Nothing is
reordered or deleted.

`PhantomPlaystyles.xml` is held to the same standard, and then some. That file's header and
per-lineage comments are most of its value, so the editor never re-serialises it as XML: every line
keeps its original text and is only rewritten if you actually edit it. Editing one condition
changes exactly one line, and a row's own explanatory comment moves with it when you drag it.

On load the panel proves this to itself - it re-serialises the file it just read and compares byte
for byte. **If it can't reproduce your file exactly, editing is disabled** and it says so, rather
than risk reformatting something you hand-tuned. The **Self-test** button re-runs that check and
reports the first differing line.

Both parsers are covered by `tests/js/playstyle_editor_test.js`, which runs the panel's real code
against the shipped data files.
