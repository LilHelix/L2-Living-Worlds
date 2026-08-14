#!/usr/bin/env python3
"""Generate PhantomPopulations from the game's own spawn data.

Placing phantoms by hand in the editor is accurate but slow. This tool derives one
phantom <population> per real hunting zone straight from dist/game/data/spawns, so every
zone gets phantoms at the level the server actually spawns monsters there, sitting inside
the real hunting area, with no manual authoring.

It reuses the same spawn/NPC reading that tools/build_knowledge.py does, so the level
bands it writes match the 60_zones_generated.txt knowledge facts exactly.

    cd "L2J_Mobius_CT_0_Interlude github"
    python3 tools/build_populations.py            # writes dist/game/data/PhantomPopulations.generated.xml
    python3 tools/build_populations.py --help     # all knobs

SAFE BY DEFAULT: it writes a SEPARATE file (PhantomPopulations.generated.xml) and never
touches your hand-authored PhantomPopulations.xml. The game server only reads the file
named PhantomPopulations.xml, so the generated side file does not load on its own. To test
the generated set, back up your live file and swap it in - see the printed instructions.

For each zone file the tool:
  - collects every Monster spawn point (territory-polygon centroid or inline x/y/z),
  - centers the group on the monster-count-weighted average of those points,
  - sizes the scatter radius from how far the monsters actually spread,
  - reads the real min/max monster level for the level band,
  - scales the phantom count by how many monsters the zone holds.

Server-side, each spawn point is re-snapped to the ground via geodata, so the z it writes
is only a hint. Pure stdlib. Deterministic (sorted) so regeneration gives stable diffs.
"""

import argparse
import math
import os
import re
import xml.etree.ElementTree as ET
from collections import defaultdict

HERE = os.path.dirname(os.path.abspath(__file__))
PROJECT = os.path.dirname(HERE)  # the "L2J_Mobius_CT_0_Interlude github" dir
DATA = os.path.join(PROJECT, "dist", "game", "data")
DEFAULT_OUT = os.path.join(DATA, "PhantomPopulations.generated.xml")

# Territory folders that are not open-world hunting grounds. Their spawns are event/siege/
# instance or pure map-grid tiles, so we skip them by default (override with --include).
SKIP_TERRITORIES = {"Castles", "SevenSigns", "Others"}

# Readable town per territory folder, only used to annotate the output for the reader.
TERRITORY_TOWN = {
    "TalkingIsland": "Talking Island", "Gludin": "Gludin Village", "Gludio": "Gludio",
    "Dion": "Dion", "Giran": "Giran", "Oren": "Oren", "Aden": "Aden",
    "Hunters": "Hunters Village", "Rune": "Rune", "Goddard": "Goddard",
    "Schuttgart": "Schuttgart", "Innadril": "Heine", "DarkElfTerritory": "the Dark Elf Village",
    "ElvenTerritory": "the Elven Village", "OrcTerritory": "the Orc Village",
    "DwarvenTerritory": "the Dwarven Village",
}

_CAMEL = re.compile(r"(?<=[a-z0-9])(?=[A-Z])|(?<=[A-Z])(?=[A-Z][a-z])")
_LOWER_WORDS = {"of", "the", "and", "near", "for"}


def readable(stem):
    """Turn a spawn filename stem into a human zone name, or '' if it has no real name.

    'DragonValleyMonsters' -> 'Dragon Valley'; '19_16_PaganAltar' -> 'Pagan Altar'.
    Pure map-grid tiles like '17_20' have no name -> ''. (Same rule as build_knowledge.py.)
    """
    for suf in ("Monsters", "Monster", "Spawns", "Spawn", "NPCs", "NPC"):
        if stem.endswith(suf) and stem != suf:
            stem = stem[: -len(suf)]
    stem = stem.replace("_", " ")
    words = [w for w in _CAMEL.sub(" ", stem).split() if w]
    while words and words[0].isdigit():  # drop leading map-grid coordinates
        words.pop(0)
    if not words or all(w.isdigit() for w in words):
        return ""
    return " ".join(w.lower() if i and w.lower() in _LOWER_WORDS else w
                    for i, w in enumerate(words)).strip()


def parse_root(path):
    try:
        return ET.parse(path).getroot()
    except ET.ParseError as e:
        print(f"  ! skip {os.path.relpath(path, DATA)}: {e}")
        return None


def load_monster_levels():
    """id -> level, for NPCs typed Monster (the only thing a hunting phantom farms)."""
    levels = {}
    npc_dir = os.path.join(DATA, "stats", "npcs")
    for dp, _, fns in os.walk(npc_dir):
        for fn in sorted(fns):
            if not fn.endswith(".xml"):
                continue
            root = parse_root(os.path.join(dp, fn))
            if root is None:
                continue
            for npc in root.iter("npc"):
                nid = npc.get("id")
                lvl = npc.get("level")
                if nid and lvl and lvl.isdigit() and (npc.get("type") == "Monster"):
                    levels[nid] = int(lvl)
    return levels


def territory_center(spawn):
    """Centroid (x, y) and mid z of a <territory> polygon, or None if it has no nodes."""
    node = spawn.find("territory")
    if node is None:
        return None
    xs, ys = [], []
    for n in node.findall("node"):
        try:
            xs.append(int(n.get("x")))
            ys.append(int(n.get("y")))
        except (TypeError, ValueError):
            continue
    if not xs:
        return None
    try:
        z = (int(node.get("minZ")) + int(node.get("maxZ"))) // 2
    except (TypeError, ValueError):
        z = 0
    return (sum(xs) // len(xs), sum(ys) // len(ys), z)


def collect_zone_points(levels):
    """Walk spawns/*; per zone file return (zone, territory, points, mob_levels).

    points     : list of (x, y, z, weight) - a territory spawn contributes one weighted
                 point (its centroid, weight = monsters in it); an inline-coordinate
                 monster contributes its own point. Used for center / radius / count.
    mob_levels : every individual monster's level in the zone, so the level band matches
                 build_knowledge.py's 60_zones_generated.txt exactly.
    Non-monster NPCs (town folk, gatekeepers) are ignored.
    """
    zones = []
    spawn_root = os.path.join(DATA, "spawns")
    for dp, _, fns in os.walk(spawn_root):
        for fn in sorted(fns):
            if not fn.endswith(".xml"):
                continue
            path = os.path.join(dp, fn)
            rel = os.path.relpath(path, spawn_root)
            territory = rel.split(os.sep)[0]
            stem = os.path.splitext(fn)[0]
            if stem.endswith("NPCs"):  # town folk / merchant files, never a hunting ground
                continue
            zone = readable(stem)
            if not zone:  # nameless map-grid tile
                continue
            root = parse_root(path)
            if root is None:
                continue
            points = []
            mob_levels = []
            for spawn in root.iter("spawn"):
                center = territory_center(spawn)
                block_weight = 0
                for n in spawn.findall("npc"):
                    nid = n.get("id")
                    if nid not in levels:
                        continue
                    try:
                        c = int(n.get("count") or 1)
                    except ValueError:
                        c = 1
                    # inline-coordinate monster: its own point
                    if n.get("x") is not None:
                        try:
                            points.append((int(n.get("x")), int(n.get("y")),
                                           int(n.get("z") or 0), c))
                        except (TypeError, ValueError):
                            pass
                    else:
                        block_weight += c
                    mob_levels.extend([levels[nid]] * c)
                if center and block_weight:
                    x, y, z = center
                    points.append((x, y, z, block_weight))
            if points and mob_levels:
                zones.append((zone, territory, points, mob_levels))
    return zones


def build_population(zone, territory, points, mob_levels, args):
    """Reduce a zone's monster points to one <population> dict, or None if out of range."""
    total_w = sum(p[3] for p in points) or 1
    cx = round(sum(p[0] * p[3] for p in points) / total_w)
    cy = round(sum(p[1] * p[3] for p in points) / total_w)
    cz = round(sum(p[2] * p[3] for p in points) / total_w)

    lo = int(min(mob_levels))
    hi = int(max(mob_levels))
    if hi < args.level_floor or lo > args.level_ceiling:
        return None
    # never ask a phantom to roll above the player level cap (a few zones seed a stray
    # over-cap mob); clamp the band so every rolled level is a legal character level.
    hi = min(hi, args.level_ceiling)
    lo = min(lo, hi)

    # radius: how far the monsters actually spread from the center (mean 2D distance,
    # padded), clamped so tiny camps and sprawling valleys both stay sane.
    dists = [math.hypot(p[0] - cx, p[1] - cy) for p in points]
    spread = round((sum(dists) / len(dists)) * 1.4) if dists else 0
    radius = max(args.min_radius, min(args.max_radius, spread or args.min_radius))

    # count: scale by how many monsters the zone holds, clamped to [1, max-per-zone].
    count = max(1, min(args.max_per_zone, round(total_w / args.density)))

    return {
        "name": zone.title(),
        "town": TERRITORY_TOWN.get(territory),
        "x": cx, "y": cy, "z": cz,
        "radius": radius, "count": count,
        "minLevel": lo, "maxLevel": hi,
        "territory": territory,
    }


def comment_safe(text):
    """XML comments may not contain a double hyphen; collapse any '--' so the file stays
    well-formed no matter what a zone or town name contains."""
    while "--" in text:
        text = text.replace("--", "-")
    return text


def render(pops, args):
    out = []
    out.append('<?xml version="1.0" encoding="UTF-8"?>')
    out.append("<!--")
    out.append("\tAUTO-GENERATED by tools/build_populations.py from dist/game/data/spawns.")
    out.append("\tOne <population> per real hunting zone: center, radius, level band and count")
    out.append("\tare all derived from where the server actually spawns monsters.")
    out.append("")
    out.append("\tThis file is NOT loaded by the server on its own. The game reads only")
    out.append("\tPhantomPopulations.xml. To test this set, back up that file and swap this in:")
    out.append("")
    out.append("\t  cp PhantomPopulations.xml PhantomPopulations.xml.bak")
    out.append("\t  cp PhantomPopulations.generated.xml PhantomPopulations.xml")
    out.append("\t  # in game: //phantom reload    (or restart)   then restore the .bak when done")
    out.append("")
    out.append("\tSafe to hand-edit or to merge chosen lines into your own file. Tune it with the")
    out.append("\tdensity, max-per-zone, min-radius and max-radius options (run the tool with -h).")
    out.append("-->")
    out.append("<list>")
    last_territory = None
    for p in sorted(pops, key=lambda q: (q["territory"], q["name"])):
        if p["territory"] != last_territory:
            town = TERRITORY_TOWN.get(p["territory"])
            label = f"{p['territory']}" + (f" ({town})" if town else "")
            out.append(f"\t<!-- ===== {comment_safe(label)} ===== -->")
            last_territory = p["territory"]
        near = f'  near {comment_safe(p["town"])}' if p["town"] else ""
        out.append(
            f'\t<population name="{p["name"]}" x="{p["x"]}" y="{p["y"]}" z="{p["z"]}"'
            f' radius="{p["radius"]}" count="{p["count"]}"'
            f' minLevel="{p["minLevel"]}" maxLevel="{p["maxLevel"]}" respawn="true" />'
            f'{" <!--" + near + " -->" if near else ""}'
        )
    out.append("</list>")
    return "\n".join(out) + "\n"


def main():
    ap = argparse.ArgumentParser(description="Generate PhantomPopulations from spawn data.")
    ap.add_argument("--out", default=DEFAULT_OUT, help="output path (default: the .generated.xml side file)")
    ap.add_argument("--density", type=float, default=30.0,
                    help="monsters per phantom; lower = denser crowds (default 30)")
    ap.add_argument("--max-per-zone", type=int, default=6, help="cap phantoms in one zone (default 6)")
    ap.add_argument("--min-radius", type=int, default=400, help="smallest scatter radius (default 400)")
    ap.add_argument("--max-radius", type=int, default=2500, help="largest scatter radius (default 2500)")
    ap.add_argument("--level-floor", type=int, default=1, help="skip zones whose top level is below this")
    ap.add_argument("--level-ceiling", type=int, default=80, help="skip zones whose bottom level is above this")
    ap.add_argument("--include", action="append", default=[],
                    help="territory folder to include even though it is skipped by default (repeatable)")
    args = ap.parse_args()

    global SKIP_TERRITORIES
    SKIP_TERRITORIES = SKIP_TERRITORIES - set(args.include)

    if not os.path.isdir(DATA):
        raise SystemExit(f"game data not found at {DATA}")

    print("Loading monster levels...")
    levels = load_monster_levels()
    print(f"  {len(levels)} monster templates")
    print("Reading spawns...")
    zones = collect_zone_points(levels)

    pops = []
    for zone, territory, points, mob_levels in zones:
        if territory in SKIP_TERRITORIES:
            continue
        pop = build_population(zone, territory, points, mob_levels, args)
        if pop:
            pops.append(pop)

    text = render(pops, args)
    with open(args.out, "w", encoding="utf-8") as fh:
        fh.write(text)

    print(f"  wrote {len(pops)} populations to {os.path.relpath(args.out, PROJECT)}")
    lvls = sorted({(p["minLevel"], p["maxLevel"]) for p in pops})
    print(f"  level bands span {min(l for l, _ in lvls)}-{max(h for _, h in lvls)}")
    print("Done. This is a SIDE file; the server still loads PhantomPopulations.xml.")
    print("To test: back up PhantomPopulations.xml, copy this over it, then //phantom reload.")


if __name__ == "__main__":
    main()
