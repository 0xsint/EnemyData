"""Regenerates data/enemies.lua from data/wiki_stats.json (numbers from helldivers.wiki.gg) plus the
project's own metadata below: id, class, spawn weight, subfaction, tags and the short tip.

    python build/gen_enemies.py

Edit the META table here (or refresh wiki_stats.json) and rerun; don't hand-edit enemies.lua.
"""
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
WIKI = json.loads((ROOT / "data" / "wiki_stats.json").read_text(encoding="utf-8"))

# (wiki page, id, display name, faction, class, weight, extras)
# extras: sub=subfaction, air=True, aliases=[...], hp=override main hp, parts={name: hp} overrides,
#         estimate=True (stats borrowed or guessed), min_diff=override, tip=...
META = [
    # ------------------------------------------------------------------ TERMINIDS
    ("Scavenger", "scavenger", "Scavenger", "terminids", "light", 10, dict(aliases=["scav"], tip="Anything kills it. Kill it early so it can't call a breach.")),
    ("Pouncer", "pouncer", "Pouncer", "terminids", "light", 4, dict(tip="Leaps from range. Dodge sideways, then finish it up close.")),
    ("Hunter", "hunter", "Hunter", "terminids", "light", 7, dict(hp=160, parts={"Claws (x2)": 60, "Legs (x4)": 60}, tip="Fast leaper that slows you. Keep moving and use automatic fire.")),
    ("Shrieker", "shrieker", "Shrieker", "terminids", "light", 2, dict(air=True, tip="Flying swarm from Shrieker Nests. Destroy the nest towers.")),
    ("Warrior", "warrior", "Warrior", "terminids", "light", 9, dict(hp=325, parts={"Head": 150, "Claws (x2)": 100, "Legs (x4)": 100}, tip="Light armor all over. Aim for the head.")),
    ("Alpha_Warrior", "alpha_warrior", "Alpha Warrior", "terminids", "medium", 2, dict(tip="Tougher Warrior that leads packs. Focus the head.")),
    ("Bile_Spitter", "bile_spitter", "Bile Spitter", "terminids", "light", 4, dict(tip="Fragile ranged acid. Kill it before it lands a volley.")),
    ("Bile_Warrior", "bile_warrior", "Bile Warrior", "terminids", "light", 2, dict(tip="Acid-filled Warrior. Kill it at range so it doesn't burst on you.")),
    ("Hive_Guard", "hive_guard", "Hive Guard", "terminids", "medium", 3, dict(tip="Plated front. Flank it, or use medium pen on the head.")),
    ("Brood_Commander", "brood_commander", "Brood Commander", "terminids", "medium", 4, dict(aliases=["brood"], tip="Keeps fighting headless and bleeds out. Legs and body are softer.")),
    ("Nursing_Spewer", "nursing_spewer", "Nursing Spewer", "terminids", "medium", 3, dict(tip="Slow. Mouth and butt are unarmored and fatal.")),
    ("Bile_Spewer", "bile_spewer", "Bile Spewer", "terminids", "medium", 3, dict(tip="Artillery acid. Mouth or butt; armor gets heavier on Extreme+.")),
    ("Stalker", "stalker", "Stalker", "terminids", "medium", 2, dict(tip="Invisible ambusher. Destroy the Stalker Lair to stop them.")),
    ("Alpha_Commander", "alpha_commander", "Alpha Commander", "terminids", "medium", 1, dict(tip="Pack leader. High priority; head first.")),
    ("Charger", "charger", "Charger", "terminids", "heavy", 3, dict(tip="Dodge the charge. Strip a leg plate and shoot the flesh, or hit the butt.")),
    ("Charger_Behemoth", "charger_behemoth", "Charger Behemoth", "terminids", "heavy", 1, dict(aliases=["behemoth"], tip="Tankier Charger. Same weak spots: legs, butt, underside.")),
    ("Impaler", "impaler", "Impaler", "terminids", "heavy", 1, dict(tip="Its face is only lightly armored when it attacks with tentacles.")),
    ("Bile_Titan", "bile_titan", "Bile Titan", "terminids", "boss", 1, dict(aliases=["titan", "bt"], tip="Heavy pen on the head; pop the belly sacs to stop the vomit.")),
    ("Dragonroach", "dragonroach", "Dragonroach", "terminids", "boss", 1, dict(air=True, tip="Flying heavy. Shoot the wings to bring it down.")),
    ("Hive_Lord", "hivelord", "Hive Lord", "terminids", "boss", 1, dict(aliases=["hivelord"], tip="Giant burrowing worm. Stay mobile; use your heaviest stratagems.")),
    ("Predator_Hunter", "predator_hunter", "Predator Hunter", "terminids", "light", 5, dict(sub="predator_strain", tip="Tougher, faster Hunter. Keep moving.")),
    ("Predator_Stalker", "predator_stalker", "Predator Stalker", "terminids", "medium", 3, dict(sub="predator_strain", tip="Predator Strain Stalker. Can show up anywhere.")),
    ("Spore_Burst_Bile_Titan", "spore_bile_titan", "Spore Bile Titan", "terminids", "boss", 1, dict(sub="spore_burst", tip="Spore Burst Bile Titan: bigger head pool, tougher sacs.")),
    ("Spore_Charger", "spore_charger", "Spore Charger", "terminids", "heavy", 3, dict(sub="spore_burst", tip="Spore cloud blocks vision. Same weak spots as a Charger.")),
    ("Rupture_Warrior", "rupture_warrior", "Rupture Warrior", "terminids", "light", 6, dict(sub="rupture_strain", tip="Burrows. Its head and claws are medium-armored.")),
    ("Rupture_Spewer", "rupture_spewer", "Rupture Spewer", "terminids", "medium", 2, dict(sub="rupture_strain", tip="Burrowing Spewer. Mouth and butt are unarmored.")),
    ("Rupture_Charger", "rupture_charger", "Rupture Charger", "terminids", "heavy", 3, dict(sub="rupture_strain", tip="Burrowing Charger with an anti-tank-grade head. Go for the butt and legs.")),

    # ----------------------------------------------------------------- AUTOMATONS
    ("Trooper", "trooper", "Trooper", "automatons", "light", 10, dict(tip="Headshots. Comes in large numbers.")),
    ("Trooper", "raider", "Raider", "automatons", "light", 10, dict(estimate=True, tip="Standard bot infantry. Stats from the wiki's Trooper page.")),
    ("Brawler", "brawler", "Brawler", "automatons", "light", 3, dict(tip="Melee bot. Its left arm is fatal; keep your distance.")),
    ("Commissar", "commissar", "Commissar", "automatons", "light", 3, dict(tip="Fires a flare that calls reinforcements. Kill first.")),
    ("Assault_Raider", "assault_raider", "Assault Raider", "automatons", "light", 3, dict(tip="Shoot the jetpack; it explodes.")),
    ("Rocket_Raider", "rocket_raider", "Rocket Raider", "automatons", "light", 3, dict(tip="Rockets ragdoll you. Headshot from cover.")),
    ("MG_Raider", "mg_raider", "MG Raider", "automatons", "light", 3, dict(tip="Shoot the backpack.")),
    ("Marauder", "marauder", "Marauder", "automatons", "light", 2, dict(tip="Armored torso. Head or legs.")),
    ("Berserker", "berserker", "Berserker", "automatons", "medium", 4, dict(tip="Chainsaw melee. Head, stomach or pelvis while backing up.")),
    ("Devastator", "devastator", "Devastator", "automatons", "medium", 5, dict(tip="Headshot. The torso needs medium pen.")),
    ("Heavy_Devastator", "heavy_devastator", "Heavy Devastator", "automatons", "medium", 3, dict(tip="Shoot around the shield: head, stomach, or the backpack.")),
    ("Rocket_Devastator", "rocket_devastator", "Rocket Devastator", "automatons", "medium", 3, dict(tip="Rockets ragdoll you. Head, or shoot the rocket pods off.")),
    ("Scout_Strider", "scout_strider", "Scout Strider", "automatons", "medium", 3, dict(aliases=["strider"], tip="Heavy front plate. Shoot the exposed pilot or the legs.")),
    ("Reinforced_Scout_Strider", "reinforced_scout_strider", "Reinforced Scout Strider", "automatons", "medium", 2, dict(tip="No exposed pilot. Legs, waist, or the rocket pods.")),
    ("Hulk_Bruiser", "hulk_bruiser", "Hulk Bruiser", "automatons", "heavy", 2, dict(aliases=["hulk"], tip="Heavy pen to the eye, or flank and shoot the back heatsink.")),
    ("Hulk_Scorcher", "hulk_scorcher", "Hulk Scorcher", "automatons", "heavy", 2, dict(tip="Keep distance. Eye, or the back heatsink.")),
    ("Hulk_Obliterator", "hulk_obliterator", "Hulk Obliterator", "automatons", "heavy", 1, dict(tip="Rocket Hulk. Eye or heatsink; stay out of its line of fire.")),
    ("Gunship", "gunship", "Gunship", "automatons", "heavy", 1, dict(air=True, tip="Shoot a thruster. Destroy Gunship Facilities to stop spawns.")),
    ("Dropship", "dropship", "Dropship", "automatons", "heavy", 1, dict(air=True, tip="Anti-tank only. Usually better to clear the drop zone.")),
    ("Annihilator_Tank", "annihilator_tank", "Annihilator Tank", "automatons", "heavy", 1, dict(aliases=["tank"], tip="Turret heatsink at the back takes 200% damage.")),
    ("Shredder_Tank", "shredder_tank", "Shredder Tank", "automatons", "heavy", 1, dict(tip="Same weak spot as the Annihilator: rear turret heatsink.")),
    ("Barrager_Tank", "barrager_tank", "Barrager Tank", "automatons", "heavy", 1, dict(tip="Artillery tank. Launch tubes and engine bay are softer.")),
    ("War_Strider", "war_strider", "War Strider", "automatons", "heavy", 1, dict(tip="Hip joints are medium armor and fatal.")),
    ("Factory_Strider", "factory_strider", "Factory Strider", "automatons", "boss", 1, dict(aliases=["fs", "factory"], tip="Belly panels and rear engine are softer. Kill the chin guns first.")),
    ("Jet_Brigade_Trooper", "jet_trooper", "Jet Brigade Trooper", "automatons", "light", 6, dict(sub="jet_brigade", tip="Shoot the jetpack; it explodes.")),
    ("Jet_Brigade_Commissar", "jet_commissar", "Jet Brigade Commissar", "automatons", "light", 2, dict(sub="jet_brigade", tip="Flare caller with a jetpack. Kill first.")),
    ("Jet_Brigade_MG_Raider", "jet_mg_raider", "Jet Brigade MG Raider", "automatons", "light", 2, dict(sub="jet_brigade", tip="Shoot the jetpack.")),
    ("Jet_Brigade_Devastator", "jet_devastator", "Jet Brigade Devastator", "automatons", "medium", 3, dict(sub="jet_brigade", tip="Headshot; the jetpack doesn't kill it.")),
    ("Jet_Brigade_Hulk_Bruiser", "jet_hulk_bruiser", "Jet Brigade Hulk Bruiser", "automatons", "heavy", 1, dict(sub="jet_brigade", tip="Its jetpack replaces the heatsink and is fatal.")),
    ("Jet_Brigade_Hulk_Scorcher", "jet_hulk_scorcher", "Jet Brigade Hulk Scorcher", "automatons", "heavy", 1, dict(sub="jet_brigade", tip="Its jetpack replaces the heatsink and is fatal.")),
    ("Pyro_Trooper", "flame_trooper", "Pyro Trooper", "automatons", "light", 5, dict(sub="incineration_corps", tip="Flamethrower. Never let it get close.")),
    ("Incendiary_Rocket_Raider", "incendiary_rocket_raider", "Incendiary Rocket Raider", "automatons", "light", 3, dict(sub="incineration_corps", tip="Fire rockets. Headshot from cover.")),
    ("Incendiary_MG_Devastator", "incendiary_mg_devastator", "Incendiary MG Devastator", "automatons", "medium", 2, dict(sub="incineration_corps", tip="Shielded. Shoot around the shield.")),
    ("Conflagration_Devastator", "conflagration_devastator", "Conflagration Devastator", "automatons", "medium", 2, dict(sub="incineration_corps", tip="Shielded flame Devastator. Head or stomach.")),
    ("Hulk_Firebomber", "hulk_firebomber", "Hulk Firebomber", "automatons", "heavy", 2, dict(sub="incineration_corps", tip="Eye or back heatsink. Keep your distance.")),
    ("Radical", "radical", "Radical", "automatons", "medium", 4, dict(sub="cyborg_legion", tip="Cyborg. Head is the quickest kill.")),
    ("Agitator", "agitator", "Agitator", "automatons", "medium", 3, dict(sub="cyborg_legion", tip="Helmeted cyborg. Break the helmet or go for the legs.")),
    ("Vox_Engine", "vox_engine", "Vox Engine", "automatons", "boss", 1, dict(sub="cyborg_legion", tip="Fatal hatches. Strip the tracks and weapons first.")),

    # ----------------------------------------------------------------- ILLUMINATE
    ("Voteless", "voteless", "Voteless", "illuminate", "light", 10, dict(tip="Shambling horde. Machine guns and fire.")),
    ("Voteless_Medium", "voteless_medium", "Voteless Medium", "illuminate", "light", 4, dict(tip="Shambling horde. Headshots.")),
    ("Voteless_Heavy", "voteless_heavy", "Voteless Heavy", "illuminate", "light", 2, dict(tip="Shambling horde. Headshots.")),
    ("Watcher", "watcher", "Watcher", "illuminate", "light", 2, dict(air=True, tip="Flying spotter that calls reinforcements. Kill on sight.")),
    ("Overseer", "overseer", "Overseer", "illuminate", "medium", 5, dict(tip="Head is medium-armored; the torso is softer.")),
    ("Elevated_Overseer", "elevated_overseer", "Elevated Overseer", "illuminate", "medium", 3, dict(air=True, tip="Shoot the jetpack to drop it.")),
    ("Crescent_Overseer", "crescent_overseer", "Crescent Overseer", "illuminate", "medium", 2, dict(tip="Shoot the backpack; it's fatal.")),
    ("Fleshmob", "fleshmob", "Fleshmob", "illuminate", "heavy", 2, dict(tip="Huge unarmored pool. Fire, machine guns and explosives.")),
    ("Harvester", "harvester", "Harvester", "illuminate", "boss", 1, dict(aliases=["tripod"], tip="Break the shield, then a hip joint.")),
    ("Stingray", "stingray", "Stingray", "illuminate", "heavy", 1, dict(air=True, min_diff=6, tip="Strafing flyer. Hit it while it turns.")),
    ("Leviathan", "leviathan", "Leviathan", "illuminate", "boss", 1, dict(air=True, tip="Flying warship. Break line of sight.")),
    ("Obtruder", "obtruder", "Obtruder", "illuminate", "light", 3, dict(sub="appropriators", air=True, tip="Watcher variant. Kill it before it calls help.")),
    ("Veracitor", "veracitor", "Veracitor", "illuminate", "heavy", 1, dict(sub="appropriators", tip="Piloted mech. Cockpit weak spot and internals.")),
    ("Gatekeeper", "gatekeeper", "Gatekeeper", "illuminate", "heavy", 1, dict(sub="appropriators", tip="Piloted mech. Rear and cockpit weak spots.")),
    ("Wretch", "wretch", "Wretch", "illuminate", "light", 4, dict(sub="vote_snatchers", tip="Fast melee. Legs carry its whole health.")),
    ("Crusher", "crusher", "Crusher", "illuminate", "heavy", 1, dict(sub="vote_snatchers", tip="Regenerates. Head or legs, and keep firing.")),
]


def lua_string(text):
    return '"' + text.replace("\\", "\\\\").replace('"', '\\"') + '"'


def part_lua(part, overrides):
    name, hp, av, to_main, fatal = part
    hp = overrides.get(name, hp)
    fields = ["name = " + lua_string(name)]
    if hp is None:
        fields.append("shared = true")  # uses the main health pool
    else:
        fields.append(f"hp = {hp}")
    fields.append(f"armor = {av}")
    if fatal:
        fields.append("fatal = true")
    fields.append(f"to_main = {(to_main or 0) / 100:g}")
    return "{ " + ", ".join(fields) + " }"


def entry_lua(page, eid, name, faction, cls, weight, extra):
    wiki = WIKI[page]
    hp = extra.get("hp", wiki["hp"])
    min_diff = extra.get("min_diff", wiki.get("min_diff")) or 1
    lines = [f"  {{ id = {lua_string(eid)}, name = {lua_string(name)}, faction = {lua_string(faction)}, class = {lua_string(cls)},",
             f"    min_diff = {min_diff}, weight = {weight}, hp = {hp}, armor = {wiki['av']},"]
    extras = []
    if extra.get("sub"):
        extras.append(f"subfaction = {lua_string(extra['sub'])}")
    if extra.get("air"):
        extras.append("tags = { air = true }")
    if extra.get("estimate"):
        extras.append("estimate = true")
    if extras:
        lines.append("    " + ", ".join(extras) + ",")
    parts = [part_lua(p, extra.get("parts", {})) for p in wiki["parts"]]
    lines.append("    parts = {")
    for p in parts:
        lines.append(f"      {p},")
    lines.append("    },")
    if extra.get("aliases"):
        lines.append("    aliases = { " + ", ".join(lua_string(a) for a in extra["aliases"]) + " },")
    lines.append(f"    weak = {lua_string(extra['tip'])} }},")
    return "\n".join(lines)


HEADER = '''-- Helldivers 2 enemy database (Lua 5.1). GENERATED by build/gen_enemies.py; edit META there and rerun.
--
-- Health, armor and body parts come from the community wiki (helldivers.wiki.gg), fetched 2026-11-01,
-- via data/wiki_stats.json. Where the wiki lists two values by difficulty, the Challenging+ one is used.
-- Class, spawn weight, subfaction and the tips are this project's own.
--
-- Fields:
--   id, name, faction ("terminids" | "automatons" | "illuminate"), class ("light"|"medium"|"heavy"|"boss")
--   min_diff    lowest difficulty (1-10) it normally spawns on
--   weight      relative spawn frequency once fully unlocked (for the estimate)
--   hp          main health pool; reaching 0 kills the enemy
--   armor       main armor value: 0 Unarmored, 1 Very Light, 2 Light, 3 Medium, 4 Heavy, 5-10 Tank I-VI.
--               Hurting it needs armor penetration (AP) at least this high.
--   parts       { name, hp, armor, fatal, to_main } per body part. shared = true means the part uses
--               the main health pool. to_main is the fraction of part damage passed to main health.
--   weak        tactical tip; aliases: extra names for `ping`; tags: { air = true }
--   subfaction  only spawns when the mission has this subfaction
--   estimate    the numbers are borrowed from a similar enemy, not this one's own wiki page

return {
'''

blocks = []
current = None
for row in META:
    faction = row[3]
    if faction != current:
        current = faction
        blocks.append(f"  {'-' * 66} {faction.upper()}")
    blocks.append(entry_lua(*row))
out = HEADER + "\n".join(blocks) + "\n}\n"
(ROOT / "data" / "enemies.lua").write_text(out, encoding="utf-8")
print(f"wrote data/enemies.lua: {len(META)} enemies from {len(WIKI) - 1} wiki pages")
