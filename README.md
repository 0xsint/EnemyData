# Helldivers 2 Enemy Intel (Lua 5.1)

Enemy intel for Helldivers 2, in two forms that share the same data:

- **In-game mod** (`mod/`): a Lua addon for
  [Chef Shared Loader](https://github.com/Th3chef/Chef-Shared-Loader) 1.5+,
  packed into a `9ba626afa44a3aa3.patch_0`. It draws the enemy panel and card
  in the game's HUD.
- **Desktop app** (`main.lua`): a terminal companion you type the mission into.

## In-game mod

### What it shows

```
ENEMY INTEL                                 D7
AUTOMATONS
57 alive  +6 unidentified
----------------------------------------------
COMMON
  40  Trooper              [==========]
  12  Devastator           [===.......]
UNCOMMON
   3  Hulk Bruiser         [=.........]  HVY
RARE
   2  Annihilator Tank     [=.........]  AT
----------------------------------------------
UNIDENTIFIED          ping one to see its hash
   6  Unknown 2ed3696e     [==========]
----------------------------------------------
! BRING ANTI-TANK: Annihilator Tank
```

The ping card, next to your crosshair:

```
>> HULK BRUISER                         20 m
--------------------------------------------
HP      3000
ARMOR   Heavy (AV4)
NEEDS   Heavy pen / anti-materiel
WEAK    Eye 700 AV4  kill
        Heatsink 900 AV1
        Arm 750 AV3
TIP     Anti-tank or AMR to the red eye, or
        flank and shoot the back heatsink.
```

- **Pre-launch briefing** (top right, on the ship and during the drop). The
  next mission's expected enemies (how many of each per 20), the class mix
  and loadout advice. The game doesn't tell mods which mission you picked, so
  the mission comes from one of three places:
  1. **The desktop app.** `lua main.lua missions/your_mission.lua` sends the
     mission to the game. Your ship shows it within 2 seconds, with name,
     planet and mission type. (`--no-send` skips this.)
  2. **Your last mission.** When you get back to the ship, the briefing
     switches to the faction and subfaction you just fought, since operations
     stay on one planet. A mission sent from the app during a mission is kept
     instead.
  3. **F3 / F6 on the ship.** F3 cycles the enemy (every faction and
     subfaction), F6 the difficulty.

  It all lives in `%APPDATA%\Arrowhead\Helldivers2\EnemyIntel.ini`.
  When the first enemies appear, the panel switches to live counts.
- **Mission panel** (right side). The enemies alive around your squad right
  now, by type, with a bar and how many there are. A killed enemy leaves the
  panel within half a second; one that despawns leaves within one 5-second
  scan. When none are around, the panel shows the estimate from
  `data/spawn_tables.lua` for this mission's faction at your difficulty, as
  how many of each to expect in a group of 20 (`~3`).
  Faction and subfaction come from every enemy seen this mission. The panel
  stays hidden on the ship. Rows tagged `HVY` need heavy penetration; rows
  tagged `AT` (in red) need anti-tank.
- **Unidentified enemies** (in the panel, purple). Moving units whose hash no
  name table knows get their own rows with counts, e.g. `Unknown 2ed3696e  6`.
  A hash only appears once one of its units has moved, since scenery never
  moves, and hashes seen on the ship never appear. Ping one to see its full
  hash, then name it in your settings (below); from then on it's a normal row.
- **Ping card** (only when you ping, next to the crosshair). The enemy you aim
  at (within 30°, up to 150 m) gets a card for that exact type and variant: name,
  live distance, max HP, armor, what penetration it needs, weak parts and a
  tip. Every enemy type the mod recognises has stats from the wiki (below).
  Only Raider is marked `~ (estimate)`: the wiki has no Raider page, so it
  uses the Trooper's numbers. The card lists the three easiest kill spots
  (fatal parts, lowest armor first); `main` means the part uses the main
  health pool. It disappears when that
  enemy dies or despawns, or after 8 seconds like the game's mark. Every ping
  replaces the card: a new enemy switches it to that enemy; empty ground, or
  an enemy that has just died or despawned, clears it. The spot where an enemy
  died counts as its corpse for 15 seconds (`corpse_seconds`), so pinging it
  doesn't show whatever is alive behind it.

| Input (defaults) | Does |
|---|---|
| **Q** (your ping key) | ping card |
| **F3** | briefing enemy: cycles each faction and subfaction (saved) |
| **F4** | show/hide the panel |
| **F6** | difficulty for the briefing and estimate (1 to 10, wraps; saved) |

F7 to F11 are left free for Detection Alert and P2P-Ping.

### Your settings: `EnemyIntelSettings.ini`

In `%APPDATA%\Arrowhead\Helldivers2\`, written with defaults on first
run. Saved edits apply within 3 seconds; no restart. The desktop app never
touches this file (it writes the mission plan, `EnemyIntel.ini`).

**The F9 menu** (Chef's options menu, under Enemy Intel) has the layout, ping
targeting, unidentified-enemy and camera settings, so you can change them in
game. The menu and this file stay in step: a change in either one is written
to the other. Key bindings, hash names and ignores are only in this file.

```
ping=keyboard:q            # your ping input; ping=mouse:middle etc. One line each.
panel_key=f4
enemy_key=f3
difficulty_key=f6
panel_x=0.76               # HUD position, fractions of the screen
panel_y=0.78               # y: 0 = bottom edge, 1 = top; blocks grow downward
card_x=0.53
card_y=0.46
font_size=22
rows=8
ping_cone=30
ping_range=150
ping_seconds=8
show_unidentified=true
unidentified_rows=5
camera_aim=true
ignore=31fe436fbf7ba57f                        # hide a hash that isn't an enemy
hash.2ed3696e12a14d4c=Raider Captain           # name a hash...
hash.2ed3696e12a14d4c=Raider Captain|raider    # ...and borrow stats from enemies.lua
```

Lines it can't use are listed in `EnemyIntel.log` as `settings: ignored line`.

### What it can't do, and why

On Steam build 26088801, the engine exposes **no unit health, no
mission info, no marker pings and no camera aim** to Lua. So:

- The card shows **max HP from `data/enemies.lua`**, not HP that drops as you
  shoot. 1.3's experiment settled this: enemies carry no `health`/`hp`/
  `damage` script data, and the engine's component tables only offer generic
  properties.
- A ping is detected from your **ping input**, not from the game's marker.
  - **Camera aim.** The mod tries `World.debug_camera_pose` once, on the
    ship. If it returns a camera near your character, pings aim along your
    real camera. That also tells the mod which squad member is you.
  - **Character facing (fallback).** Used when the camera isn't usable. In
    a squad, the game doesn't say which Helldiver is you (`num_cameras` was 0
    for everyone in your 1.3 log), so the mod takes the best match across the
    whole squad and the card says `(squad)`.
  - **The camera try is crash-safe.** It's recorded in
    `EnemyIntelProbe.txt` in `%APPDATA%\Arrowhead\Helldivers2\` *before* the call. If the game ever dies during
    it, it's never tried again. Delete that file to retry.
- The mission you picked on the galactic map isn't visible to mods, so the
  briefing comes from the app, your last mission, or F3/F6.
- The older Enemy HP mod showed live HP by reading game memory. It turned
  itself off after the last patch, and this mod does not take that route.

**Destroyed units.** Calling any `Unit` function except `alive` on a destroyed
unit kills the game, and `pcall` can't catch it. Version 1.3 crashed this way:
a ping read the position of a gunship that had just been shot down. Since 1.5
every position and facing read checks `Unit.alive` in the same frame, and the
test engine treats any call on a dead unit as a crash.

Unit positions from the engine are temporaries that the next call overwrites,
so the mod copies each one into plain numbers immediately. Version 1.0 didn't,
and every distance came out 0 m. Detection Alert has the same problem; its F7
probe also logged "0.0 m" for every unit.

The first call of anything not yet seen working on this build
(`World.debug_camera_pose`, `Matrix4x4.translation/forward`) is written to the
log **before** it runs. (`Unit.world_rotation`, `Quaternion.forward`,
`Vector3.x/y/z`, `Mouse.*` and `Unit.has_data` all worked in your 1.3 run.) If the game ever crashes, the last line
of `EnemyIntel.log` names the call that caused it.

### Build

The hash-to-name table comes from your local copy of the **Enemy HP** mod at
build time. It isn't stored in this repo. **Ask that mod's author before you
publish a build**, because the table is their work.

```
lua5.1 build/assemble.lua ["<path to Enemy HP>/Addon/0cdb2ce39c96e9a4.lua"]
python <BunkerTurretEye>/tools/build_addon.py --name mods/vixenhunny/enemy_intel --entry dist/enemy_intel.lua --guid c0af6b5b-6405-4cd3-8887-906fe6a98245 --display-name "Enemy Intel" --output dist/Enemy-Intel.zip
```

Reuse that GUID for every update. `assemble.lua` fails the build if any name in
`data/game_names.lua` isn't in the hash table, or points at a missing enemy.

### Install

Import `dist/Enemy-Intel.zip` into Arsenal or HD2MM next to Chef Shared Loader
1.5+. Give Chef the highest priority, enable both, then Purge and Deploy.

Chef lets a mod write only `.log`, `.txt`, `.ini` and a few other extensions in
its log folder, which is why the settings and plan files are `.ini` now. If you
ran the Bingus build, move your `EnemyIntelSettings.cfg` into
`%APPDATA%\Arrowhead\Helldivers2\` and rename it `EnemyIntelSettings.ini`. The
plan file is rewritten by the app and the mod, so it needs no move.

### What the in-game logs showed (1.0, 2026-11-01)

- The unit hashes **match** the Enemy HP table: Raiders, Scout Striders,
  Commissars, Berserkers, Gunships and a Factory Strider were all named, and
  the faction was detected as Automatons.
- Enemies leave the unit list when killed or left behind; live counts fell
  from 64 to 26 during a fight.
- The ship has about 350 animated units, which 1.0 mistook for a mission.
  Fixed in 1.1.
- Every card said "0 m" (stale position temporaries). Fixed in 1.1.

### Checking 1.1 in game

In `%APPDATA%\Arrowhead\Helldivers2\EnemyIntel.log`:

1. **`key Mouse.middle id=...`**: the ping button resolved. If the id is
   `nil`, or the log says `Mouse has neither button_id nor button_index`, pings
   can't be detected on this build.
2. **`ping t=...: <enemy> at N m`** when you ping an enemy, with a sensible
   distance. `no enemy in front` means nothing was within the cone.
3. **`ping card closed ...: died or despawned`** when you kill a pinged enemy.
4. **`basis=squad`** or `cannot tell which player unit is you` in a squad: the
   mod couldn't tell which Helldiver is you, so it uses whichever squadmate
   faces an enemy. The `num_cameras per player` values in that line tell me
   whether that can be fixed.
5. **`named but unmapped`** and **`unknown animated hashes`**: enemies to add
   to `data/game_names.lua`.
6. **`health probe <enemy>: Unit.has_data health=...`**. If any key says
   `true(...)`, live HP may be reachable and the card can be made to count
   down. Also send the `health probe stingray.EntityManager` / `DataComponent`
   lines, which list what those engine tables offer.

### Tests

```
lua5.1 build/assemble.lua && lua5.1 tests/mod_test.lua [--show]
python <BunkerTurretEye>/tools/analysis/check_lua51.py dist/enemy_intel.lua
```

`mod_test.lua` runs the assembled mod against a fake engine that copies the
real engine's quirks: shared position temporaries, a ship full of animated
units, and loading screens with no player. It covers each faction, kills and
despawns leaving the panel, the estimate, subfaction detection, pings (facing
vs nearest, following the target, closing on death, empty pings, expiry, squad
fallback), every key, squad wipe vs loading screen, session end, missing or
failing engine functions, the returned hooks table, and cost with 17,000 units. `--show`
prints what the HUD draws. `check_lua51.py` is the 200-local and no-global
gate from BunkerTurretEye.

## Desktop app

Type in the mission from the briefing screen and get the expected roster, plus
an HP card you can log damage against. Loading a mission also sends it to the
in-game mod as your ship's briefing.

```
lua main.lua missions/example_bots.lua
lua main.lua --faction terminids --subfaction predator_strain --difficulty 9 --type eradicate
lua main.lua                 # asks for the mission
lua main.lua --no-color ...  # if you see raw escape codes (old cmd.exe)
```

- **Briefing:** an enemy frequency chart (COMMON / UNCOMMON / RARE with bars
  and %), the threat mix by class, and loadout advice.
- **HP card:** `ping charger` or `ping 3` opens it; log damage with
  `hit 600 head`. Other commands: `card`, `reset`, `brief`, `help`, `quit`.

Test it with `lua tests/smoke_test.lua`, which renders every faction,
subfaction, difficulty and mission type and damages every enemy part.

## Files

| File | Purpose |
|---|---|
| `data/enemies.lua` | Enemy stats: HP, armor, parts, tips. **Edit for the current patch.** |
| `data/spawn_tables.lua` | Factions, subfactions, mission types and weight multipliers |
| `data/game_names.lua` | Which in-game unit names are enemies, and which stats they use |
| `src/roster.lua` | Roster math shared by the app and the mod |
| `src/briefing.lua`, `src/hp_ui.lua`, `src/term.lua` | Desktop app screens |
| `mod/enemy_intel.lua` | In-game mod body |
| `build/assemble.lua` | Bundles the mod into one loader-ready Lua file |
| `missions/*.lua` | Mission files for the desktop app |

## About the numbers

Health, armor and body-part tables for 81 enemies come from the community wiki,
[helldivers.wiki.gg](https://helldivers.wiki.gg/), fetched 2026-11-01. The
numbers live in `data/wiki_stats.json`. `build/gen_enemies.py` merges them with
this project's own class, spawn weight, subfaction and tips into
`data/enemies.lua`, so edit the generator rather than `enemies.lua`. Where the
wiki gives two values by difficulty (Hunter, Warrior), the Challenging+ one is
used. The wiki's tables sometimes disagree with its own prose (Charger "Butt",
Hive Guard); the tables win.

Armor uses the wiki's classes: 0 Unarmored, 1 Very Light, 2 Light, 3 Medium,
4 Heavy, 5-10 Tank I-VI. You need armor penetration (AP) at least that high.

**The wiki has no unit hashes.** The hash -> name table still comes from the
Enemy HP mod. Every wiki enemy that also has a name in that table is mapped in
`data/game_names.lua`. Enemies with no hash there (Wretch, Crusher, Alpha
Warrior) show up in game as Unidentified until you ping and name them.

The estimate (spawn weights by difficulty and mission type) is this project's
own model, not datamined. The in-game panel shows real counts once enemies
appear.
