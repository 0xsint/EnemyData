-- Mission metadata used to turn a briefing into an expected enemy roster.
-- Multipliers are tuning knobs, not datamined values. Tweak to taste.

local T = {}

T.difficulties = {
  "Trivial", "Easy", "Medium", "Challenging", "Hard",
  "Extreme", "Suicide Mission", "Impossible", "Helldive", "Super Helldive",
}

T.factions = {
  terminids = {
    name = "Terminids",
    subfactions = {
      predator_strain = { name = "Predator Strain",
        mult = { hunter = 2.5, pouncer = 2.5, stalker = 2.0, scavenger = 0.5 } },
      spore_burst = { name = "Spore Burst Strain",
        mult = { charger = 0.2 } },
      rupture_strain = { name = "Rupture Strain",
        mult = { warrior = 0.4, charger = 0.3 } },
    },
  },
  automatons = {
    name = "Automatons",
    subfactions = {
      jet_brigade = { name = "Jet Brigade",
        mult = { trooper = 0.4 } },
      incineration_corps = { name = "Incineration Corps",
        mult = { hulk_scorcher = 3.0, hulk_bruiser = 0.3, trooper = 0.5 } },
      cyborg_legion = { name = "Cyborg Legion",
        mult = { trooper = 0.5, raider = 0.5 } },
    },
  },
  illuminate = {
    name = "Illuminate",
    -- A weight of 0 removes an enemy: the wiki lists these as absent with that subfaction.
    subfactions = {
      appropriators = { name = "Appropriators",
        mult = { crescent_overseer = 0 } },
      vote_snatchers = { name = "Vote Snatchers",
        mult = { watcher = 0, overseer = 0, elevated_overseer = 0, crescent_overseer = 0, harvester = 0 } },
    },
  },
}

-- Multipliers per enemy class (light/medium/heavy/boss) and for air units.
T.mission_types = {
  eradicate  = { name = "Eradicate",
    mult = { light = 1.5, medium = 1.3, heavy = 0.8, boss = 0.5 } },
  blitz      = { name = "Blitz: Search and Destroy",
    mult = { light = 1.0, medium = 1.0, heavy = 1.2, boss = 1.0 } },
  defense    = { name = "Defense / Evacuation",
    mult = { light = 1.3, medium = 1.2, heavy = 1.0, boss = 1.0 } },
  objective  = { name = "Standard Objective",
    mult = { light = 1.0, medium = 1.0, heavy = 1.0, boss = 1.0 } },
  assassinate = { name = "Assassination / High-Value Target",
    mult = { light = 0.8, medium = 1.0, heavy = 1.3, boss = 2.5 } },
  air        = { name = "Air Superiority (gunship/flyer heavy)",
    mult = { light = 1.0, medium = 1.0, heavy = 1.0, boss = 1.0, air = 3.0 } },
}

-- Likelihood labels by share of the roster.
T.tiers = {
  { min = 0.12, label = "Common",   note = "you will fight these constantly" },
  { min = 0.05, label = "Uncommon", note = "expect several every mission" },
  { min = 0.00, label = "Rare",     note = "few, but bring an answer for them" },
}

return T
