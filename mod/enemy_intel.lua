-- Enemy Intel (Helldivers 2 / Chef Shared Loader 1.5+ / plain Lua 5.1)
--
-- The in-game half of the EnemyData project:
--   * Pre-launch briefing. On the ship and during the drop, the next mission's expected enemies (how
--     many of each per 20), class mix and loadout advice. The mission comes from the plan file, which
--     the EnemyData desktop app writes when you load a mission there, F3/F6 set on the ship, and the
--     mod fills in after each mission with the faction it fought (operations stay on one planet).
--   * Mission panel. The enemies alive around the squad right now, by type, with how common each one
--     is (COMMON / UNCOMMON / RARE), a bar and how many there are. An enemy leaves the panel as soon as
--     it dies or despawns. Animated units no name table knows are listed as UNIDENTIFIED with their
--     counts, once one of their kind has moved (scenery does not) and unless they were seen on the ship.
--     While none are around, it shows the estimate from data/spawn_tables.lua for the faction (and
--     subfaction) detected this mission and the difficulty set with F6, as how many per 20.
--   * Ping card. When you ping, the enemy you aim at gets a card for that exact enemy type and variant:
--     name, distance, max HP, armor, what it takes to hurt it, weak points and a tip. An unidentified
--     one shows its hash and the settings line that names it. The card follows its target and goes away
--     when it dies or despawns, or after 8 s like the game's mark.
--
-- Your settings (ping key, hotkeys, HUD position and size, hash names) live in
-- EnemyIntelSettings.ini, written with defaults on first run and re-read every few seconds. The mission
-- plan (EnemyIntel.ini), the log (EnemyIntel.log) and the camera probe (EnemyIntelProbe.txt) sit beside it
-- in the Chef log folder, %APPDATA%\Arrowhead\Helldivers2. Chef lets a mod write only .log/.txt/.ini
-- files there, which is why these are not .cfg.
--
-- What the engine does not give a mod on build 26088801: no unit health, no mission info and no marker
-- pings are reachable from Lua. So the card shows MAX HP from data/enemies.lua, a ping is detected from
-- the ping input in your settings, and difficulty comes from F6. Aim comes from the game camera if
-- World.debug_camera_pose proves usable (tried once, on the ship), otherwise from character facing.
--
-- Positions: Unit.world_position returns an engine temporary that the next call overwrites, so a
-- stored position silently turns into whichever one was read last (every distance came out 0 m). Every
-- vector is copied into plain numbers the moment it is read; see read_vector.
--
-- Engine calls are those Detection Alert, P2P-Ping and Enemy HP already ran, each under pcall, and the
-- first call of anything not yet seen working on this build is announced in the log beforehand, so a
-- crash names its cause. Nothing here writes game state.
--
-- This is the mod BODY. build/assemble.lua prepends the HD2-Addon header and bundles the modules that
-- `require` returns below, producing the single file the loader runs. The main chunk must stay under
-- Lua 5.1's 200 locals. It writes no global: Chef calls the hooks table it returns at the end.

-- Chef Shared Loader calls this chunk with its helper table as the argument.
local chef = ...

local Roster = require("src.roster")
local ENEMIES = require("data.enemies")
local SPAWN = require("data.spawn_tables")
local GAME_NAMES = require("data.game_names")
local HASH_NAMES = require("generated.hash_names")

local CFG = {
  version = "enemy-intel-1.5",
  log_name = "EnemyIntel", -- chef.own_log: EnemyIntel.log in the Chef log folder
  plan_file = "EnemyIntel.ini", -- the mission plan (app and mod write it)
  user_settings_file = "EnemyIntelSettings.ini", -- yours: keys, layout, names
  probe_file = "EnemyIntelProbe.txt",
  user_settings_check_seconds = 3,

  difficulty = 7, -- for the briefing and the estimate until changed with F6 or the plan file
  mission_type = "objective",
  plan_check_seconds = 2, -- how often the ship re-reads the plan file for a mission sent from the app

  -- Census walk: every unit in the main world, spread over frames like Detection Alert's sampler. It
  -- finds new enemies and drops despawned ones once per pass; kills are dropped faster by prune_dead.
  pass_seconds = 5,
  max_units_per_frame = 2000,
  prune_seconds = 0.5,
  loading_max_animated = 20, -- the in-game log shows loading screens at 0-1 animated units
  ship_max_units = 8000, -- the ship had 2,200-3,400 units in the log, missions 11,000-26,000
  detail_interval = 30, -- seconds between "unknown hash" detail lines in the log

  min_faction_units = 5,
  faction_share = 0.6,
  min_subfaction_units = 3,

  rows = 8,
  estimate_group = 20, -- the estimate shows how many of each to expect in a group this size
  use_num_cameras = true, -- Unit.num_cameras is recorded "ok" on this build by Detection Alert's probe

  -- Unidentified: animated units whose hash is in no name table. A hash is shown once one of its units
  -- has moved more than unknown_move_metres (scenery never moves), unless it was seen on the ship.
  show_unidentified = true,
  unidentified_rows = 5,
  unknown_move_metres = 3,
  ignore_hashes = {}, -- from "ignore=" lines in the settings file
  custom_names = {}, -- hash -> { name, id } from "hash.<hash>=" lines in the settings file

  -- Camera aim: World.debug_camera_pose, tried once on the ship behind the probe file (see CAM below).
  camera_aim = true,
  camera_max_metres = 15, -- the camera must be this close to a player to count as yours

  player_hashes = { ["4d1c334d294dfa97"] = true },

  -- The game's ping input, overridden by "ping=" lines in the settings file. Stingray button names:
  -- Mouse "left" "right" "middle" "extra_1" "extra_2"; Keyboard "q", "e", "f5" and so on.
  ping = {
    buttons = { { device = "Keyboard", name = "q" } },
    cone_degrees = 30, -- how far off your aim an enemy may be and still count as pinged
    range = 150, -- metres
    seconds = 8, -- like a game mark
    -- A ping on an enemy that just died or despawned shows nothing (not whatever is alive behind it).
    -- The spot it was last seen counts as its corpse for this long.
    corpse_seconds = 15,
  },

  -- F7-F11 belong to Detection Alert and P2P-Ping.
  keys = { panel = "f4", enemy = "f3", difficulty = "f6" },

  -- Live HP experiment. No health API is known on this build. The first time each enemy type is
  -- pinged, the mod asks Unit.has_data for these keys on it, and at startup it lists the member names
  -- (no calls) of the engine's component tables. Both go to the log only, to find out whether live
  -- health is reachable at all. (1.3 in game: every key false; the tables offer only generic properties.)
  health_probe = {
    enabled = false,
    keys = { "health", "max_health", "hp", "damage", "health_extension" },
    tables = { "EntityManager", "DataComponent", "ScriptComponent", "Script", "DynamicData", "TagComponent" },
  },

  hud = {
    font = "core/performance_hud/debug",
    font_size = 22,
    line_gap = 5,
    panel_x = 0.76, panel_y = 0.78, -- fractions of the screen; y is measured from the bottom
    card_x = 0.53, card_y = 0.46, -- just right of the crosshair, clear of the panel
    refresh = 0.5,
    max_faults = 5,
    retry_seconds = 2,
    look = {
      title = { r = 238, g = 243, b = 235 },
      dim = { r = 160, g = 168, b = 160 },
      tier = { r = 250, g = 207, b = 96 },
      row = { r = 238, g = 243, b = 235 },
      heavy = { r = 255, g = 170, b = 80 },
      danger = { r = 255, g = 112, b = 105 },
      unknown = { r = 180, g = 160, b = 230 },
      shadow = { r = 12, g = 15, b = 18 },
    },
  },
}

-- Runtime state that is not the census or the HUD.
local S = {
  t = 0, session = false, next_session_check = 0, next_detail = 0, next_prune = 0,
  difficulty = CFG.difficulty, panel_visible = true, card = nil,
  health_probed = {}, -- enemy group -> true once the live-HP experiment has run on it
  plan = nil, -- the next mission for the pre-launch briefing: { faction, subfaction, type, name, planet, source }
  plan_text = nil, -- the plan file's contents as last read or written
  next_plan_check = 0,
  next_empty_pass = 0,
  user_settings_text = nil, next_user_settings_check = 0,
  ship_hashes = {}, -- hashes seen on the ship this session: crew and props, never enemies
}

------------------------------------------------------------------------------------------- logging

-- chef.own_log (called first at startup) sends these lines to EnemyIntel.log. Until then, and if the name
-- is refused, they go to chef_loader.log.
local LOG = { errors = 0 }
local log = chef.log

-- The mod's files that the EnemyData app and you edit: plan, settings, probe. Chef reads and writes
-- them only in its log folder.
local function data_path(name)
  return chef.log_directory .. "\\" .. name
end

local function log_error(where, err)
  LOG.errors = LOG.errors + 1
  if LOG.errors <= 20 or LOG.errors % 100 == 0 then
    log(string.format("ERROR #%d in %s: %s", LOG.errors, where, tostring(err)))
  end
end

-------------------------------------------------------------------------------------- engine access

-- Every call to the game goes through here: resolved once, called under pcall, and the first failure
-- of each API logged. A missing API returns nil forever, so a build without it degrades quietly.
-- Calls in E.announce have not been seen working on this build yet: the first one is logged (and the
-- log flushed) BEFORE it runs, because a native assert kills the game where pcall cannot catch it.
local E = {
  fns = {}, failed = {}, announced = {},
  announce = {
    ["Unit.world_rotation"] = true, ["Quaternion.forward"] = true,
    ["Vector3.x"] = true, ["Vector3.y"] = true, ["Vector3.z"] = true,
    ["Mouse.button_id"] = true, ["Mouse.button_index"] = true, ["Mouse.pressed"] = true,
    ["Unit.has_data"] = true, ["Unit.get_data"] = true,
    ["World.debug_camera_pose"] = true, ["Matrix4x4.translation"] = true, ["Matrix4x4.forward"] = true,
  },
}

local function engine_table(name)
  local engine = rawget(_G, "stingray")
  return type(engine) == "table" and rawget(engine, name) or nil
end

local function engine_fn(space_name, member)
  local key = space_name .. "." .. member
  local fn = E.fns[key]
  if fn == nil then
    local space = engine_table(space_name)
    fn = type(space) == "table" and rawget(space, member) or nil
    if type(fn) ~= "function" then
      fn = false
    end
    E.fns[key] = fn
  end
  return fn or nil
end

local function engine_call(space_name, member, ...)
  local key = space_name .. "." .. member
  local fn = engine_fn(space_name, member)
  if fn == nil then
    if not E.failed[key] then
      E.failed[key] = true
      log(key .. " unavailable")
    end
    return nil
  end
  if E.announce[key] and not E.announced[key] then
    E.announced[key] = true
    log("first call of " .. key .. " (if the game crashes now, this call is why)")
  end
  local ok, result = pcall(fn, ...)
  if ok then
    return result
  end
  if not E.failed[key] then
    E.failed[key] = true
    log(key .. " failed: " .. tostring(result))
  end
  return nil
end

local function in_game_session()
  local network = engine_table("Network")
  if type(network) ~= "table" or type(rawget(network, "game_session")) ~= "function" then
    return false
  end
  local ok, session = pcall(network.game_session)
  return ok and session ~= nil
end

-- 16-digit lowercase resource hash of a unit, or nil. Unit.resource_name returns an IdString64 on this
-- build; its text form carries the hash (e.g. "#ID[4d1c334d294dfa97]").
local function unit_hash(unit)
  local resource = engine_call("Unit", "resource_name", unit)
  if resource == nil then
    return nil
  end
  local text = resource
  if type(resource) ~= "string" then
    text = engine_call("IdString64", "to_string", resource)
    if type(text) ~= "string" then
      return nil
    end
  end
  local hex = text:match("%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x")
  return hex and hex:lower() or nil
end

------------------------------------------------------------------------------------------- vectors

-- Copies an engine Vector3 into { x, y, z } right away, before another engine call can overwrite the
-- temporary. Uses Vector3.x/y/z (what Enemy HP used) or, failing that, field access on the value.
local V = { mode = nil }

local function component(value, axis)
  if V.mode ~= "field" then
    local n = engine_call("Vector3", axis, value)
    if type(n) == "number" then
      V.mode = "function"
      return n
    end
  end
  local ok, n = pcall(function() return value[axis] end)
  if ok and type(n) == "number" then
    if V.mode ~= "field" then
      V.mode = "field"
      log("vectors: reading components as fields")
    end
    return n
  end
  return nil
end

local function read_vector(value)
  if value == nil then
    return nil
  end
  local x = component(value, "x")
  local y = x and component(value, "y")
  local z = y and component(value, "z")
  if not z or x ~= x or y ~= y or z ~= z then
    return nil
  end
  return { x, y, z }
end

-- Calling any other Unit function on a destroyed unit is a native assert that kills the game, and
-- pcall cannot catch it. Stored unit handles (live enemies, players from the last pass, a ping
-- target) can be destroyed at any moment, so every read below checks Unit.alive in the same frame
-- first. 1.3 crashed exactly here: a ping read the position of a gunship that had just been destroyed.
local function is_alive(unit)
  return unit ~= nil and engine_call("Unit", "alive", unit) == true
end

local function position_of(unit)
  if not is_alive(unit) then
    return nil
  end
  return read_vector(engine_call("Unit", "world_position", unit, 0))
end

-- The horizontal direction a unit faces, normalised, or nil.
local function facing_of(unit)
  if not is_alive(unit) then
    return nil
  end
  local rotation = engine_call("Unit", "world_rotation", unit, 0)
  local forward = rotation ~= nil and read_vector(engine_call("Quaternion", "forward", rotation)) or nil
  if forward == nil then
    return nil
  end
  local length = math.sqrt(forward[1] * forward[1] + forward[2] * forward[2])
  if length < 1e-6 then
    return nil
  end
  return { forward[1] / length, forward[2] / length }
end

local function distance(a, b)
  local dx, dy, dz = a[1] - b[1], a[2] - b[2], a[3] - b[3]
  return math.sqrt(dx * dx + dy * dy + dz * dz)
end

--------------------------------------------------------------------------------- mission plan file

-- The pre-launch briefing reads the next mission from EnemyIntel.ini (key=value lines): difficulty,
-- faction, subfaction, type, name, planet, source. Three things write it: the EnemyData desktop app
-- when you load a mission there (source=app), F3/F6 on the ship (source=game), and the mod itself
-- when a mission ends, with the faction it detected (source=last), unless the plan was changed while
-- that mission was running. While on the ship the file is re-read every CFG.plan_check_seconds.
local function read_plan_text()
  local handle = io.open(data_path(CFG.plan_file), "r")
  if not handle then
    return nil
  end
  local ok, body = pcall(handle.read, handle, "*a")
  pcall(handle.close, handle)
  return ok and type(body) == "string" and body or nil
end

local function load_plan()
  local body = read_plan_text()
  if body == nil or body == S.plan_text then
    return
  end
  S.plan_text = body
  local fields = {}
  for key, value in body:gmatch("([%w_]+)=([^\r\n]*)") do
    fields[key] = value
  end
  local difficulty = tonumber(fields.difficulty)
  if difficulty and difficulty >= 1 and difficulty <= 10 then
    S.difficulty = math.floor(difficulty)
  end
  if fields.faction == nil or fields.faction == "" then
    S.plan = nil
    return
  end
  local mission, err = Roster.normalize({
    faction = fields.faction, subfaction = fields.subfaction ~= "" and fields.subfaction or nil,
    difficulty = S.difficulty, type = fields.type ~= "" and fields.type or CFG.mission_type,
  })
  if mission == nil then
    S.plan = nil
    log("plan file ignored: " .. tostring(err))
    return
  end
  S.plan = {
    faction = mission.faction, subfaction = mission.subfaction, type = mission.type,
    name = fields.name ~= "" and fields.name or nil, planet = fields.planet ~= "" and fields.planet or nil,
    source = fields.source,
  }
  log(string.format("plan: %s / %s D%d %s (%s)", S.plan.faction, tostring(S.plan.subfaction), S.difficulty,
    S.plan.type, tostring(S.plan.source)))
end

local function save_plan()
  local plan = S.plan or {}
  local body = table.concat({
    "difficulty=" .. S.difficulty,
    "faction=" .. (plan.faction or ""),
    "subfaction=" .. (plan.subfaction or ""),
    "type=" .. (plan.type or ""),
    "name=" .. (plan.name or ""),
    "planet=" .. (plan.planet or ""),
    "source=" .. (plan.source or ""),
  }, "\n") .. "\n"
  local handle = io.open(data_path(CFG.plan_file), "w")
  if handle then
    pcall(handle.write, handle, body)
    pcall(handle.close, handle)
    S.plan_text = body
  end
end

------------------------------------------------------------------------------------- your settings

-- EnemyIntelSettings.ini holds what you set by hand: ping input, hotkeys, HUD position and size,
-- ping targeting, unidentified-enemy display, hash names and ignores, camera aim. The mod writes it
-- with defaults when it is missing and otherwise only reads it, every user_settings_check_seconds,
-- so a saved edit applies without a restart. Key and name changes are applied by tick (flags below),
-- because the key poller and the name groups are defined further down.
local function settings_template()
  local hud, ping, pings = CFG.hud, CFG.ping, {}
  for _, button in ipairs(ping.buttons) do
    pings[#pings + 1] = "ping=" .. button.device:lower() .. ":" .. button.name
  end
  return table.concat({
    "# Enemy Intel settings. Saved changes apply within a few seconds; no restart needed.",
    "#",
    "# The key or mouse button you ping with in the game. One line each; add lines for more.",
    "#   ping=keyboard:q    ping=mouse:middle    (mouse buttons: left right middle extra_1 extra_2)",
    table.concat(pings, "\n"),
    "#",
    "# Hotkeys (keyboard key names). F7-F11 are used by Detection Alert and P2P-Ping.",
    "panel_key=" .. CFG.keys.panel,
    "enemy_key=" .. CFG.keys.enemy,
    "difficulty_key=" .. CFG.keys.difficulty,
    "#",
    "# Where the HUD sits, as fractions of the screen. x: 0 = left edge, 1 = right edge.",
    "# y: 0 = BOTTOM edge, 1 = top edge; each block grows downward from its y.",
    string.format("panel_x=%.2f", hud.panel_x),
    string.format("panel_y=%.2f", hud.panel_y),
    string.format("card_x=%.2f", hud.card_x),
    string.format("card_y=%.2f", hud.card_y),
    "font_size=" .. hud.font_size,
    "rows=" .. CFG.rows,
    "#",
    "# Ping targeting: how far off your aim (degrees) and how far away (metres) an enemy may be,",
    "# and how long the card stays up (seconds).",
    "ping_cone=" .. ping.cone_degrees,
    "ping_range=" .. ping.range,
    "ping_seconds=" .. ping.seconds,
    "#",
    "# Unidentified enemies (hashes no name table knows): show them, and how many rows.",
    "show_unidentified=" .. tostring(CFG.show_unidentified),
    "unidentified_rows=" .. CFG.unidentified_rows,
    "# Hide a hash that is not an enemy:        ignore=31fe436fbf7ba57f",
    "# Name a hash (ping it to see its hash):  hash.2ed3696e12a14d4c=Raider Captain",
    "# ...and use stats from data/enemies.lua: hash.2ed3696e12a14d4c=Raider Captain|raider",
    "#",
    "# Aim pings with the game camera. Tried once, on the ship; the result is kept in",
    "# EnemyIntelProbe.txt in the Chef log folder (delete that file to try again).",
    "camera_aim=" .. tostring(CFG.camera_aim),
  }, "\n") .. "\n"
end

local function parse_bool(value)
  value = value:lower()
  if value == "true" or value == "yes" or value == "on" or value == "1" then return true end
  if value == "false" or value == "no" or value == "off" or value == "0" then return false end
  return nil
end

-- name -> { table, field, min, max, integer }
local NUMBER_SETTINGS = {
  panel_x = { "hud", "panel_x", 0, 1 }, panel_y = { "hud", "panel_y", 0, 1 },
  card_x = { "hud", "card_x", 0, 1 }, card_y = { "hud", "card_y", 0, 1 },
  font_size = { "hud", "font_size", 10, 60, true },
  rows = { nil, "rows", 1, 20, true }, unidentified_rows = { nil, "unidentified_rows", 0, 20, true },
  ping_cone = { "ping", "cone_degrees", 1, 90 }, ping_range = { "ping", "range", 5, 500 },
  ping_seconds = { "ping", "seconds", 1, 60 },
}

local function apply_user_settings(body)
  local pings, ignore, names, problems = {}, {}, {}, {}
  for raw in (body .. "\n"):gmatch("([^\n]*)\n") do
    local line = raw:gsub("\r", ""):match("^%s*(.-)%s*$")
    if line ~= "" and line:sub(1, 1) ~= "#" then
      local key, value = line:match("^([^=]-)%s*=%s*(.*)$")
      key = key and key:lower()
      local number = key and NUMBER_SETTINGS[key]
      if key == nil then
        problems[#problems + 1] = line
      elseif key == "ping" then
        local device, name = value:lower():match("^(%a+)%s*:%s*([%w_]+)$")
        if device == nil then
          device, name = "keyboard", value:lower():match("^([%w_]+)$")
        end
        if name and (device == "keyboard" or device == "mouse") then
          pings[#pings + 1] = { device = device == "mouse" and "Mouse" or "Keyboard", name = name }
        else
          problems[#problems + 1] = line
        end
      elseif key == "panel_key" or key == "enemy_key" or key == "difficulty_key" then
        local name = value:lower():match("^([%w_]+)$")
        if name then
          CFG.keys[key:sub(1, -5)] = name
        else
          problems[#problems + 1] = line
        end
      elseif number then
        local n = tonumber(value)
        if n and n >= number[3] and n <= number[4] then
          local target = number[1] and CFG[number[1]] or CFG
          target[number[2]] = number[5] and math.floor(n + 0.5) or n
        else
          problems[#problems + 1] = line .. " (allowed " .. number[3] .. "-" .. number[4] .. ")"
        end
      elseif key == "show_unidentified" or key == "camera_aim" then
        local flag = parse_bool(value)
        if flag == nil then
          problems[#problems + 1] = line
        else
          CFG[key] = flag
        end
      elseif key == "ignore" then
        local hash = value:lower():match("^(%x+)$")
        if hash and #hash == 16 then
          ignore[hash] = true
        else
          problems[#problems + 1] = line .. " (needs the full 16-digit hash)"
        end
      elseif key:match("^hash%.%x+$") and #key == 21 then
        local name, id = value:match("^(.-)%s*|%s*([%w_]+)$")
        name = name or value
        if name ~= "" then
          names[key:sub(6)] = { name = name, id = id }
        else
          problems[#problems + 1] = line
        end
      else
        problems[#problems + 1] = line
      end
    end
  end
  if #pings > 0 then
    CFG.ping.buttons = pings
  end
  CFG.ignore_hashes, CFG.custom_names = ignore, names
  return problems
end

local function load_user_settings()
  local path = data_path(CFG.user_settings_file)
  local handle = io.open(path, "r")
  local body
  if handle then
    local ok, text = pcall(handle.read, handle, "*a")
    pcall(handle.close, handle)
    body = ok and type(text) == "string" and text or nil
  else
    body = settings_template()
    local out = io.open(path, "w")
    if out then
      pcall(out.write, out, body)
      pcall(out.close, out)
      log("settings: wrote defaults to " .. path)
    end
  end
  if body == nil or body == S.user_settings_text then
    return
  end
  S.user_settings_text = body
  local problems = apply_user_settings(body)
  S.keys_dirty, S.names_dirty = true, true
  local pings, names = {}, 0
  for _, button in ipairs(CFG.ping.buttons) do
    pings[#pings + 1] = button.device .. "." .. button.name
  end
  for _ in pairs(CFG.custom_names) do
    names = names + 1
  end
  log(string.format("settings: ping=%s panel=%.2f,%.2f card=%.2f,%.2f font=%d named=%d unidentified=%s camera_aim=%s",
    table.concat(pings, ","), CFG.hud.panel_x, CFG.hud.panel_y, CFG.hud.card_x, CFG.hud.card_y,
    CFG.hud.font_size, names, tostring(CFG.show_unidentified), tostring(CFG.camera_aim)))
  for _, problem in ipairs(problems) do
    log("settings: ignored line: " .. problem)
  end
end

--------------------------------------------------------------------------------------- camera aim

-- World.debug_camera_pose has not been seen working on this build, and a native assert kills the game
-- where pcall cannot catch it. So it is tried ONCE, on the ship, with "try camera" appended to the
-- probe file before the call and the outcome after it. A "try" with no outcome means the game died in
-- the call: it is never tried again. "ok" is used from then on; "unusable" (no pose, or a camera far
-- from every player, e.g. a debug camera) is not retried either. Delete the file to try again.
local CAM = { state = "untried" } -- untried | ok | unusable | fatal

local function probe_append(text)
  local handle = io.open(data_path(CFG.probe_file), "a")
  if handle then
    pcall(handle.write, handle, text, "\n")
    pcall(handle.close, handle)
  end
end

local function load_probe_state()
  local path = data_path(CFG.probe_file)
  local handle = io.open(path, "r")
  if not handle then
    return
  end
  local ok, body = pcall(handle.read, handle, "*a")
  pcall(handle.close, handle)
  local last
  for line in ((ok and body or "") .. "\n"):gmatch("([^\r\n]*)\r?\n") do
    local word = line:match("^(%a+) camera")
    if word then
      last = word
    end
  end
  if last == "try" then
    CAM.state = "fatal"
    log("camera aim: the game stopped during the last try, so it is never tried again")
  elseif last == "ok" then
    CAM.state = "ok"
  elseif last == "unusable" then
    CAM.state = "unusable"
  end
  if last then
    log("camera aim: " .. CAM.state .. " (from " .. path .. ")")
  end
end

-- The camera's position and normalised forward direction, copied into numbers, or nil.
local function camera_pose()
  local world = engine_call("Application", "main_world")
  local pose = world ~= nil and engine_call("World", "debug_camera_pose", world) or nil
  if pose == nil then
    return nil
  end
  local pos = read_vector(engine_call("Matrix4x4", "translation", pose))
  local forward = pos and read_vector(engine_call("Matrix4x4", "forward", pose))
  if not forward then
    return nil
  end
  local length = math.sqrt(forward[1] ^ 2 + forward[2] ^ 2 + forward[3] ^ 2)
  if length < 0.5 or length > 1.5 then
    return nil
  end
  return { pos = pos, dir = { forward[1] / length, forward[2] / length, forward[3] / length } }
end

-- The player unit nearest the camera, if it is within camera_max_metres, with that distance.
local function player_at_camera(players, cam)
  local best, best_dist = nil, math.huge
  for _, unit in ipairs(players) do
    local pos = position_of(unit)
    if pos then
      local d = distance(pos, cam.pos)
      if d < best_dist then
        best, best_dist = unit, d
      end
    end
  end
  if best and best_dist <= CFG.camera_max_metres then
    return best, best_dist
  end
  return nil, best_dist
end

local function try_camera_on_ship(players)
  if not CFG.camera_aim or CAM.state ~= "untried" or #players == 0 then
    return
  end
  probe_append("try camera")
  local cam = camera_pose()
  if cam == nil then
    CAM.state = "unusable"
    probe_append("unusable camera: no pose")
  else
    local unit, metres = player_at_camera(players, cam)
    if unit then
      CAM.state = "ok"
      probe_append(string.format("ok camera: %.1f m from your character", metres))
    else
      CAM.state = "unusable"
      probe_append(string.format("unusable camera: %s m from the nearest player",
        metres < math.huge and string.format("%.0f", metres) or "?"))
    end
  end
  log("camera aim: " .. CAM.state .. " after one try on the ship")
end

--------------------------------------------------------------------------------------- enemy groups

-- One group per display name, so MK2/MK3 and other variants share a row. by_hash maps a unit's
-- resource hash to its group; named holds every hash the name table knows, enemy or not. Rebuilt when
-- the settings file's hash names change.
local G = {}

local function build_groups()
  G.by_key, G.by_game_name, G.by_hash, G.named, G.mapped, G.dangling = {}, {}, {}, {}, 0, {}
  local by_id = {}
  for _, def in ipairs(ENEMIES) do
    by_id[def.id] = def
  end
  local function group_for(name, def, entry)
    local group = G.by_key[name]
    if group == nil then
      group = {
        key = name, name = name, def = def,
        faction = def and def.faction or entry.faction,
        class = def and def.class or entry.class or "light",
        armor = def and def.armor or nil,
        air = entry.air or (def and def.tags and def.tags.air) or false,
        subfaction = entry.subfaction or (def and def.subfaction) or nil,
      }
      G.by_key[name] = group
    end
    return group
  end
  for game_name, spec in pairs(GAME_NAMES) do
    local entry = type(spec) == "string" and { id = spec } or spec
    local def = entry.id and by_id[entry.id] or nil
    if entry.id and not def then
      G.dangling[#G.dangling + 1] = game_name
    else
      G.by_game_name[game_name] = group_for(entry.name or def.name, def, entry)
    end
  end
  for hash, game_name in pairs(HASH_NAMES) do
    local key = hash:lower()
    G.named[key] = game_name
    local group = G.by_game_name[game_name]
    if group then
      G.by_hash[key] = group
      G.mapped = G.mapped + 1
    end
  end
  -- Your names from the settings file win over everything else.
  for hash, spec in pairs(CFG.custom_names) do
    local def = spec.id and by_id[spec.id] or nil
    if spec.id and not def then
      log("settings: hash." .. hash .. " uses unknown enemy id '" .. spec.id .. "'; shown without stats")
    end
    G.by_hash[hash] = group_for(spec.name, def, {})
    G.named[hash] = spec.name
  end
end

--------------------------------------------------------------------------------------------- census

-- live: every enemy unit alive right now -> { group, hash }. A pass adds what it finds and, at its
-- end, drops what it did not find (despawned); prune_dead drops kills between passes. seen_counts is
-- the whole mission's tally, used only to work out the faction. unknown_now holds the last pass's
-- unidentified units whose hash has been seen moving (mobile).
local C = {}

local function new_pass()
  return { units = 0, animated = 0, players = {}, found = {}, unknown = {}, unmapped = {}, unknown_units = {} }
end

local function reset_census()
  C.units, C.cursor, C.credit = nil, 1, 0
  C.pass = new_pass()
  C.players = {}
  C.live = {}
  C.seen, C.seen_counts, C.seen_total = {}, {}, 0
  C.faction, C.subfaction = nil, nil
  C.plan_text_at_start = nil
  C.on_ship = false
  C.mobile, C.first_pos, C.unknown_now = {}, {}, {}
  C.last_pos, C.corpses = {}, {} -- unit -> where it was last seen alive; recently dead or despawned spots
end

local function count_into(counts, key)
  counts[key] = (counts[key] or 0) + 1
end

local function top_counts(counts, limit)
  local list = {}
  for key, value in pairs(counts) do
    list[#list + 1] = { key = key, value = value }
  end
  table.sort(list, function(a, b)
    if a.value ~= b.value then return a.value > b.value end
    return a.key < b.key
  end)
  local parts = {}
  for index = 1, math.min(#list, limit) do
    parts[#parts + 1] = list[index].key .. "=" .. list[index].value
  end
  return #parts > 0 and table.concat(parts, " ") or "none"
end

local function live_counts()
  local counts, total = {}, 0
  for _, entry in pairs(C.live) do
    count_into(counts, entry.group.key)
    total = total + 1
  end
  return counts, total
end

local function unknown_counts()
  local counts, total = {}, 0
  for _, entry in ipairs(C.unknown_now) do
    count_into(counts, entry.hash)
    total = total + 1
  end
  return counts, total
end

-- An unidentified animated unit: counted for the log and, unless ignored or seen on the ship, watched
-- until one unit of its hash moves (then the hash counts as mobile, i.e. not scenery).
local function note_unknown(p, unit, hash)
  count_into(p.unknown, hash)
  if not CFG.show_unidentified or CFG.ignore_hashes[hash] or S.ship_hashes[hash] then
    return
  end
  p.unknown_units[#p.unknown_units + 1] = { unit = unit, hash = hash }
  if C.mobile[hash] then
    return
  end
  local pos = position_of(unit)
  if pos == nil then
    return
  end
  local first = C.first_pos[unit]
  if first == nil or first.hash ~= hash then
    C.first_pos[unit] = { hash = hash, pos = pos }
  elseif distance(first.pos, pos) > CFG.unknown_move_metres then
    C.mobile[hash] = true
    log(string.format("unidentified t=%.1f: %s moves; showing it on the HUD", S.t, hash))
  end
end

local function sample_unit(unit)
  if engine_call("Unit", "alive", unit) ~= true then
    return
  end
  local p = C.pass
  p.units = p.units + 1
  local animated = engine_call("Unit", "has_animation_state_machine", unit) == true
  if animated then
    p.animated = p.animated + 1
  end
  local hash = unit_hash(unit)
  if hash == nil then
    return
  end
  if CFG.player_hashes[hash] then
    p.players[#p.players + 1] = unit
    return
  end
  local group = G.by_hash[hash]
  if group == nil then
    -- Only animated units are worth reporting; the rest of the 17,000 are props and scenery.
    if animated then
      local name = G.named[hash]
      if name then
        count_into(p.unmapped, name)
      else
        note_unknown(p, unit, hash)
      end
    end
    return
  end
  p.found[unit] = true
  local entry = C.live[unit]
  if entry == nil or entry.hash ~= hash then
    C.live[unit] = { group = group, hash = hash }
  else
    entry.group = group -- picks up a rename from the settings file
  end
  if C.seen[unit] ~= hash then
    C.seen[unit] = hash
    count_into(C.seen_counts, group.key)
    C.seen_total = C.seen_total + 1
  end
end

-- Faction: the one most of this mission's enemies belong to, once there are enough of them.
-- Subfaction: the one whose variants have been seen most, among that faction's.
local function infer_faction()
  local by_faction, total = {}, 0
  for key, n in pairs(C.seen_counts) do
    local faction = G.by_key[key].faction
    if faction then
      by_faction[faction] = (by_faction[faction] or 0) + n
      total = total + n
    end
  end
  local best, best_n = nil, 0
  for faction, n in pairs(by_faction) do
    if n > best_n then
      best, best_n = faction, n
    end
  end
  local faction = nil
  if best and SPAWN.factions[best] and best_n >= CFG.min_faction_units and best_n >= total * CFG.faction_share then
    faction = best
  end

  local subfaction = nil
  if faction then
    local by_sub, sub_n = {}, 0
    for key, n in pairs(C.seen_counts) do
      local group = G.by_key[key]
      if group.subfaction and group.faction == faction and SPAWN.factions[faction].subfactions[group.subfaction] then
        by_sub[group.subfaction] = (by_sub[group.subfaction] or 0) + n
      end
    end
    for sub, n in pairs(by_sub) do
      if n >= CFG.min_subfaction_units and n > sub_n then
        subfaction, sub_n = sub, n
      end
    end
  end

  if faction ~= C.faction or subfaction ~= C.subfaction then
    log(string.format("faction t=%.1f %s / %s (from %d seen)", S.t, tostring(faction), tostring(subfaction), total))
  end
  C.faction, C.subfaction = faction, subfaction
end

-- At mission end, the faction just fought becomes the next briefing (operations stay on one planet),
-- unless a new plan arrived while the mission ran (sent from the app, or set with F3).
local function remember_mission()
  if C.faction == nil then
    return
  end
  local current = read_plan_text() or S.plan_text or ""
  if C.plan_text_at_start ~= nil and current ~= C.plan_text_at_start then
    log("plan changed during the mission; keeping it for the next briefing")
    S.plan_text = nil -- re-read it on the ship
    return
  end
  local previous = S.plan or {}
  S.plan = {
    faction = C.faction, subfaction = C.subfaction, type = previous.type or CFG.mission_type,
    planet = previous.faction == C.faction and previous.planet or nil, source = "last",
  }
  save_plan()
end

-- A tracked enemy died or despawned: its last known spot becomes a corpse for corpse_seconds, so a
-- ping there shows nothing instead of whatever is alive behind it. (A dead unit's position can't be
-- read; that call kills the game. prune_dead records positions while units are alive.)
local function bury(unit, name)
  local pos = C.last_pos[unit]
  C.last_pos[unit] = nil
  if pos then
    C.corpses[#C.corpses + 1] = { pos = pos, name = name, at = S.t }
  end
end

local function finish_pass()
  local p = C.pass
  C.pass = new_pass()

  -- No player unit and almost nothing animated is a loading screen between ship and mission: start the
  -- next one clean. (A squad wipe also leaves no player unit, but the enemies are still animated.)
  if #p.players == 0 and p.animated < CFG.loading_max_animated then
    if C.seen_total > 0 then
      log(string.format("loading t=%.1f: mission over, seen=%d faction=%s / %s counts: %s", S.t, C.seen_total,
        tostring(C.faction), tostring(C.subfaction), top_counts(C.seen_counts, 20)))
      remember_mission()
    end
    reset_census()
    return
  end
  C.players = p.players
  if C.seen_total > 0 and C.plan_text_at_start == nil then
    C.plan_text_at_start = S.plan_text or "" -- the first enemies are here: the mission has started
  end

  -- The ship: a small world with players and no enemy seen. Everything animated there is crew or
  -- props, so those hashes never count as unidentified enemies; and it is where the camera is tried.
  C.on_ship = p.units < CFG.ship_max_units and C.seen_total == 0 and #p.players > 0
  if C.on_ship then
    for hash in pairs(p.unknown) do
      S.ship_hashes[hash] = true
    end
    try_camera_on_ship(p.players)
  end

  local unknown_now = {}
  for _, entry in ipairs(p.unknown_units) do
    if C.mobile[entry.hash] and not S.ship_hashes[entry.hash] then
      unknown_now[#unknown_now + 1] = entry
    end
  end
  local still_here = {}
  for _, entry in ipairs(unknown_now) do
    still_here[entry.unit] = true
  end
  for _, entry in ipairs(C.unknown_now) do
    if not still_here[entry.unit] then
      bury(entry.unit, "unidentified " .. entry.hash)
    end
  end
  C.unknown_now = unknown_now

  local despawned = 0
  for unit, entry in pairs(C.live) do
    if not p.found[unit] then
      C.live[unit] = nil
      bury(unit, entry.group.name)
      despawned = despawned + 1
    end
  end

  infer_faction()
  local counts, total = live_counts()
  local unknown, unknown_total = unknown_counts()
  log(string.format("pass t=%.1f units=%d animated=%d players=%d alive=%d unidentified=%d despawned=%d seen=%d faction=%s/%s now: %s",
    S.t, p.units, p.animated, #p.players, total, unknown_total, despawned, C.seen_total,
    tostring(C.faction), tostring(C.subfaction), top_counts(counts, 8)))
  if S.t >= S.next_detail and (next(p.unknown) or next(p.unmapped)) then
    S.next_detail = S.t + CFG.detail_interval
    log("  unknown animated hashes: " .. top_counts(p.unknown, 12))
    log("  unidentified on the HUD (moving, not ship): " .. top_counts(unknown, 12))
    log("  named but unmapped (add to data/game_names.lua if enemies): " .. top_counts(p.unmapped, 12))
  end
end

-- Kills between passes: a unit the engine no longer reports alive leaves the panel within prune_seconds
-- and becomes a corpse. Live units have their position recorded for exactly that moment.
local function prune_dead()
  for unit, entry in pairs(C.live) do
    if engine_call("Unit", "alive", unit) ~= true then
      C.live[unit] = nil
      bury(unit, entry.group.name)
    else
      C.last_pos[unit] = position_of(unit)
    end
  end
  for index = #C.unknown_now, 1, -1 do
    local entry = C.unknown_now[index]
    if engine_call("Unit", "alive", entry.unit) ~= true then
      table.remove(C.unknown_now, index)
      bury(entry.unit, "unidentified " .. entry.hash)
    else
      C.last_pos[entry.unit] = position_of(entry.unit)
    end
  end
  for index = #C.corpses, 1, -1 do
    if S.t - C.corpses[index].at > CFG.ping.corpse_seconds then
      table.remove(C.corpses, index)
    end
  end
end

local function census_tick(dt)
  if C.units == nil then
    local world = engine_call("Application", "main_world")
    local units = world ~= nil and engine_call("World", "units", world) or nil
    if type(units) ~= "table" or #units == 0 then
      C.credit = 0
      -- An empty world is a loading screen too: finish an (empty) pass so the mission can end.
      if type(units) == "table" and S.t >= S.next_empty_pass then
        S.next_empty_pass = S.t + CFG.pass_seconds
        finish_pass()
      end
      return
    end
    C.units, C.cursor = units, 1
  end
  local total = #C.units
  C.credit = math.min(C.credit + total * dt / CFG.pass_seconds, CFG.max_units_per_frame)
  local count = math.floor(C.credit)
  C.credit = C.credit - count
  for _ = 1, count do
    sample_unit(C.units[C.cursor])
    C.cursor = C.cursor + 1
    if C.cursor > total then
      C.units = nil
      finish_pass()
      break
    end
  end
end

----------------------------------------------------------------------------------------- panel text

-- Layout. Every line is one Gui.text in one color, in the debug font, which is treated as monospaced:
-- columns are padded with spaces. Rows read "count  name  [bar]  tag", count first so the number is
-- the first thing you see.
local WIDTH = 46 -- characters per panel line
local CARD_WIDTH = 44
local DIVIDER = string.rep("-", WIDTH)

local function wrap(text, width)
  local lines, line = {}, ""
  for word in text:gmatch("%S+") do
    if line == "" then
      line = word
    elseif #line + 1 + #word <= width then
      line = line .. " " .. word
    else
      lines[#lines + 1] = line
      line = word
    end
  end
  if line ~= "" then
    lines[#lines + 1] = line
  end
  return lines
end

-- "left ........ right" padded to width with spaces.
local function spread(left, right, width)
  return left .. string.rep(" ", math.max(2, width - #left - #right)) .. right
end

-- Rows for the panel: { name, count, share, tier, armor }, most common first.
local function live_rows()
  local counts, total = live_counts()
  local rows = {}
  for key, n in pairs(counts) do
    local group = G.by_key[key]
    local share = n / total
    rows[#rows + 1] = { name = group.name, count = n, share = share, tier = Roster.tierFor(share), armor = group.armor }
  end
  table.sort(rows, function(a, b)
    if a.share ~= b.share then return a.share > b.share end
    return a.name < b.name
  end)
  return rows, total
end

-- The expected roster for a mission ({ faction, subfaction, type }) at the current difficulty, as panel
-- rows, plus the roster itself for the class mix and advice.
local function estimate_rows(mission)
  local roster = Roster.build({ faction = mission.faction, subfaction = mission.subfaction,
    difficulty = S.difficulty, type = mission.type or CFG.mission_type })
  local rows = {}
  for _, r in ipairs(roster) do
    rows[#rows + 1] = { name = r.enemy.name, share = r.share, tier = r.tier, armor = r.enemy.armor }
  end
  return rows, roster
end

local function add_line(lines, text, look)
  lines[#lines + 1] = { text = text, look = look }
end

local function armor_look(armor)
  if armor and armor >= 5 then
    return "danger"
  elseif armor == 4 then
    return "heavy"
  end
  return "row"
end

local function armor_tag(armor)
  if armor and armor >= 5 then
    return "  AT"
  elseif armor == 4 then
    return "  HVY"
  end
  return ""
end

-- One enemy row. The number is how many are alive now, or for the estimate, how many to expect in a
-- group of CFG.estimate_group. The bar is scaled to the most common row. Heavy-pen and anti-tank rows
-- are tagged in text as well as colored.
local function row_text(row, top)
  local filled = math.max(1, math.floor(row.share / top * 10 + 0.5))
  local number
  if row.count then
    number = tostring(row.count)
  else
    local expected = math.floor(row.share * CFG.estimate_group + 0.5)
    number = expected == 0 and "<1" or ("~" .. expected)
  end
  return string.format("%4s  %-20s [%s%s]%s", number, row.name:sub(1, 20),
    string.rep("=", filled), string.rep(".", 10 - filled), armor_tag(row.armor))
end

local function faction_line(faction_key, subfaction_key)
  local faction = faction_key and SPAWN.factions[faction_key]
  if not faction then
    return "FACTION UNKNOWN"
  end
  local text = faction.name:upper()
  if subfaction_key and faction.subfactions[subfaction_key] then
    text = text .. " / " .. faction.subfactions[subfaction_key].name:upper()
  end
  return text
end

-- Title, faction and one status line, then a divider.
local function add_header(lines, title, faction_key, subfaction_key, status)
  add_line(lines, spread(title, "D" .. S.difficulty, WIDTH), "title")
  add_line(lines, faction_line(faction_key, subfaction_key), faction_key and "danger" or "dim")
  if status then
    add_line(lines, status, "dim")
  end
  add_line(lines, DIVIDER, "dim")
end

-- Tier headers and rows (at most CFG.rows); returns up to three anti-tank names for a callout.
local function add_rows(lines, rows)
  local top = rows[1] and rows[1].share or 1
  local last_tier, anti_tank = nil, {}
  for index, row in ipairs(rows) do
    if row.armor and row.armor >= 5 and #anti_tank < 3 then
      anti_tank[#anti_tank + 1] = row.name
    end
    if index <= CFG.rows then
      if row.tier ~= last_tier then
        last_tier = row.tier
        add_line(lines, row.tier:upper(), "tier")
      end
      add_line(lines, row_text(row, top), armor_look(row.armor))
    end
  end
  if #rows > CFG.rows then
    add_line(lines, string.format("      +%d more types", #rows - CFG.rows), "dim")
  end
  return anti_tank
end

local function add_anti_tank(lines, names)
  if #names > 0 then
    add_line(lines, DIVIDER, "dim")
    for index, line in ipairs(wrap("BRING ANTI-TANK: " .. table.concat(names, ", "), WIDTH)) do
      add_line(lines, (index == 1 and "! " or "  ") .. line, "danger")
    end
  end
end

local PLAN_SOURCES = {
  app = "sent from the EnemyData app",
  game = "set on the ship",
  last = "from your last mission",
}

-- Before launch: on the ship and during the drop, until the first enemy is seen. Shows the plan from
-- the plan file: expected enemies per 20, the class mix per 20, and loadout advice.
local function briefing_lines()
  local lines, plan = {}, S.plan
  local keys = string.format("%s/%s to change", CFG.keys.enemy:upper(), CFG.keys.difficulty:upper())
  if plan == nil then
    add_line(lines, spread("MISSION BRIEFING", "D" .. S.difficulty, WIDTH), "title")
    add_line(lines, DIVIDER, "dim")
    add_line(lines, "No mission planned yet. Press " .. CFG.keys.enemy:upper() .. " to pick", "row")
    add_line(lines, "the enemy and " .. CFG.keys.difficulty:upper() .. " the difficulty, or load a", "row")
    add_line(lines, "mission in the EnemyData app.", "row")
    return lines
  end
  add_line(lines, spread("MISSION BRIEFING", "D" .. S.difficulty, WIDTH), "title")
  add_line(lines, faction_line(plan.faction, plan.subfaction), "danger")
  local where = {}
  if plan.name then where[#where + 1] = plan.name end
  if plan.planet then where[#where + 1] = plan.planet end
  if #where > 0 then
    for _, line in ipairs(wrap(table.concat(where, " - "), WIDTH)) do
      add_line(lines, line, "row")
    end
  end
  add_line(lines, SPAWN.mission_types[plan.type] and SPAWN.mission_types[plan.type].name or plan.type, "row")
  for _, line in ipairs(wrap((PLAN_SOURCES[plan.source] or "planned") .. "  (" .. keys .. ")", WIDTH)) do
    add_line(lines, line, "dim")
  end
  add_line(lines, DIVIDER, "dim")
  add_line(lines, string.format("EXPECT PER %d ENEMIES", CFG.estimate_group), "dim")

  local rows, roster = estimate_rows(plan)
  add_rows(lines, rows)
  add_line(lines, DIVIDER, "dim")
  local mix, parts = Roster.classMix(roster), {}
  for _, class in ipairs({ "light", "medium", "heavy", "boss", "air" }) do
    if mix[class] > 0 then
      local n = math.floor(mix[class] * CFG.estimate_group + 0.5)
      parts[#parts + 1] = class .. "_" .. (n == 0 and "<1" or ("~" .. n)) -- "_" keeps each pair on one line
    end
  end
  for index, line in ipairs(wrap(table.concat(parts, " "), WIDTH - 6)) do
    add_line(lines, (index == 1 and "MIX   " or "      ") .. line:gsub("_", " "), "row")
  end
  add_line(lines, DIVIDER, "dim")
  add_line(lines, "LOADOUT", "tier")
  for _, tip in ipairs(Roster.advice(roster)) do
    for index, line in ipairs(wrap(tip, WIDTH - 2)) do
      add_line(lines, (index == 1 and "- " or "  ") .. line, tip:find("^Anti%-tank") and "danger" or "row")
    end
  end
  return lines
end

local function panel_lines()
  local lines = {}
  if not S.panel_visible then
    return lines
  end
  local rows, total = live_rows()
  local unknown, unknown_total = unknown_counts()
  if total > 0 or (unknown_total > 0 and not C.on_ship) then
    local status = string.format("%d alive", total)
    if unknown_total > 0 then
      status = status .. string.format("  +%d unidentified", unknown_total)
    end
    add_header(lines, "ENEMY INTEL", C.faction, C.subfaction, status)
    local anti_tank = add_rows(lines, rows)
    if unknown_total > 0 and CFG.unidentified_rows > 0 then
      -- Every unidentified hash gets a row and its count, like the named enemies above.
      local list = {}
      for hash, n in pairs(unknown) do
        list[#list + 1] = { hash = hash, count = n }
      end
      table.sort(list, function(a, b)
        if a.count ~= b.count then return a.count > b.count end
        return a.hash < b.hash
      end)
      add_line(lines, DIVIDER, "dim")
      add_line(lines, spread("UNIDENTIFIED", "ping one to see its hash", WIDTH), "unknown")
      local top = list[1].count
      for index = 1, math.min(#list, CFG.unidentified_rows) do
        local entry = list[index]
        add_line(lines, row_text({ name = "Unknown " .. entry.hash:sub(1, 8), count = entry.count,
          share = entry.count / top }, 1), "unknown")
      end
      if #list > CFG.unidentified_rows then
        add_line(lines, string.format("      +%d more unidentified types", #list - CFG.unidentified_rows), "dim")
      end
    end
    add_anti_tank(lines, anti_tank)
  elseif C.seen_total == 0 then
    if #C.players > 0 then
      return briefing_lines() -- the ship, or the drop before any enemy has shown up
    end
  elseif C.faction then
    add_header(lines, "ENEMY INTEL", C.faction, C.subfaction,
      string.format("none nearby - expect per %d (%s difficulty)", CFG.estimate_group, CFG.keys.difficulty:upper()))
    add_anti_tank(lines, add_rows(lines, (estimate_rows({ faction = C.faction, subfaction = C.subfaction }))))
  end
  return lines -- empty on a loading screen
end

------------------------------------------------------------------------------------------ ping card

-- Where a ping is aimed from. Best: the game camera (CAM.state "ok"), which also says which player is
-- you. Otherwise each player's facing: yours if exactly one player unit carries a camera, every
-- squadmate's if not (in game, num_cameras is 0 for every player, so in a squad this is the usual
-- fallback). Each origin is { pos, dir, flat, anchor, anchor_pos }.
local function aim_origins(players)
  if CFG.camera_aim and CAM.state == "ok" then
    local cam = camera_pose()
    if cam then
      local unit = player_at_camera(players, cam)
      if unit then
        return { { pos = cam.pos, dir = cam.dir, flat = false, anchor = unit, anchor_pos = position_of(unit) } }, "camera"
      end
    end
  end
  local alive = {}
  for _, unit in ipairs(players) do
    if is_alive(unit) then
      alive[#alive + 1] = unit
    end
  end
  local anchors, basis = alive, "squad"
  if #alive <= 1 then
    basis = "you"
  elseif CFG.use_num_cameras then
    local owners, seen = {}, {}
    for _, unit in ipairs(alive) do
      local cameras = is_alive(unit) and engine_call("Unit", "num_cameras", unit) or nil
      seen[#seen + 1] = tostring(cameras)
      if type(cameras) == "number" and cameras > 0 then
        owners[#owners + 1] = unit
      end
    end
    if #owners == 1 then
      anchors, basis = owners, "you"
    else
      log("ping: cannot tell which player unit is you; num_cameras per player = " .. table.concat(seen, ","))
    end
  end
  local origins = {}
  for _, unit in ipairs(anchors) do
    local pos, facing = position_of(unit), facing_of(unit)
    if pos and facing then
      origins[#origins + 1] = { pos = pos, dir = { facing[1], facing[2], 0 }, flat = true, anchor = unit, anchor_pos = pos }
    end
  end
  return origins, basis
end

-- The unit the ping lands on: the candidate within range of the pinging player and within cone_degrees
-- of the aim, closest to the aim line first, nearer first on a tie. Candidates are live enemies (named
-- or unidentified) and the spots where enemies recently died or despawned. The result is nil (a ping
-- on the ground) or { dead = true, name } when the ping lands on a corpse; either way nothing shows.
-- A tracked unit killed since the last prune is never read (that would crash): its last spot is used.
local function pick_target(origins)
  local cos_limit = math.cos(math.rad(CFG.ping.cone_degrees))
  local best, best_cos, best_dist = nil, -2, math.huge
  local function consider(pos, target)
    if pos == nil then
      return
    end
    for _, origin in ipairs(origins) do
      local dist = origin.anchor_pos and distance(pos, origin.anchor_pos) or math.huge
      local dx, dy, dz = pos[1] - origin.pos[1], pos[2] - origin.pos[2], origin.flat and 0 or (pos[3] - origin.pos[3])
      local length = math.sqrt(dx * dx + dy * dy + dz * dz)
      if dist <= CFG.ping.range and length > 1e-3 then
        local cos = (dx * origin.dir[1] + dy * origin.dir[2] + dz * origin.dir[3]) / length
        if cos >= cos_limit and (cos > best_cos + 1e-3 or (math.abs(cos - best_cos) <= 1e-3 and dist < best_dist)) then
          best, best_cos, best_dist = target, cos, dist
          target.anchor = origin.anchor
        end
      end
    end
  end
  for unit, entry in pairs(C.live) do
    if is_alive(unit) then
      consider(position_of(unit), { unit = unit, group = entry.group, hash = entry.hash })
    else
      consider(C.last_pos[unit], { dead = true, name = entry.group.name })
    end
  end
  for _, entry in ipairs(C.unknown_now) do
    if is_alive(entry.unit) then
      consider(position_of(entry.unit), { unit = entry.unit, hash = entry.hash })
    else
      consider(C.last_pos[entry.unit], { dead = true, name = "unidentified " .. entry.hash })
    end
  end
  for _, corpse in ipairs(C.corpses) do
    consider(corpse.pos, { dead = true, name = corpse.name })
  end
  return best, best_dist
end

-- Live HP experiment (see CFG.health_probe): log which script-data keys the pinged unit carries.
local function probe_health(unit, group)
  if not CFG.health_probe.enabled or S.health_probed[group.key] or not is_alive(unit) then
    return
  end
  S.health_probed[group.key] = true
  local found = {}
  for _, key in ipairs(CFG.health_probe.keys) do
    local has = engine_call("Unit", "has_data", unit, key)
    local entry = key .. "=" .. tostring(has)
    if has == true then
      entry = entry .. "(" .. tostring(engine_call("Unit", "get_data", unit, key)) .. ")"
    end
    found[#found + 1] = entry
  end
  log("health probe " .. group.name .. ": Unit.has_data " .. table.concat(found, " "))
end

-- Every ping replaces the card: with the newly pinged enemy, or with nothing when the ping lands on
-- empty ground or on an enemy that has died or despawned.
local function on_ping()
  if C.players == nil or #C.players == 0 then
    return
  end
  local origins, basis = aim_origins(C.players)
  local target, metres = pick_target(origins)
  local previous = S.card
  if target == nil or target.dead then
    S.card = nil
    if target then
      log(string.format("ping t=%.1f: %s is dead or despawned; card cleared", S.t, target.name))
    else
      log(string.format("ping t=%.1f: no enemy in front (origins=%d basis=%s)%s", S.t, #origins, basis,
        previous and "; card cleared" or ""))
    end
    return
  end
  S.card = { unit = target.unit, group = target.group, hash = target.hash, anchor = target.anchor,
    basis = basis, expires = S.t + CFG.ping.seconds }
  local name = target.group and target.group.name or ("unidentified " .. target.hash)
  log(string.format("ping t=%.1f: %s at %.0f m basis=%s%s", S.t, name, metres, basis,
    previous and (previous.unit == target.unit and " (same target)" or " (new target)") or ""))
  if target.group then
    probe_health(target.unit, target.group)
  end
end

-- "LABEL   value" with continuation lines indented under the value.
local function add_field(lines, label, text, look)
  local indent = string.rep(" ", 8)
  for index, line in ipairs(wrap(text, CARD_WIDTH - 8)) do
    add_line(lines, (index == 1 and string.format("%-8s", label) or indent) .. line, look)
  end
end

local function card_for(card, metres)
  local lines, group = {}, card.group
  local where = metres and string.format("%d m", math.floor(metres + 0.5)) or "? m"
  if card.basis == "squad" then
    where = where .. " (squad)"
  end
  if group == nil then
    -- Unidentified: show the hash and how to name it.
    add_line(lines, spread(">> UNIDENTIFIED", where, CARD_WIDTH), "unknown")
    add_line(lines, string.rep("-", CARD_WIDTH), "dim")
    add_field(lines, "HASH", card.hash, "row")
    add_line(lines, "Name it in EnemyIntelSettings.ini:", "dim")
    add_line(lines, "hash." .. card.hash .. "=Name", "dim")
    return lines
  end
  local def = group.def
  local look = armor_look(group.armor)
  add_line(lines, spread(">> " .. group.name:upper(), where, CARD_WIDTH), look)
  add_line(lines, string.rep("-", CARD_WIDTH), "dim")
  if def == nil then
    add_line(lines, "No stats: add |enemy_id to its hash. line", "dim")
    return lines
  end
  -- "~" marks numbers that are rough guesses (estimate = true in data/enemies.lua).
  local approx = def.estimate and "~" or ""
  add_field(lines, "HP", approx .. def.hp .. (def.estimate and "  (estimate)" or ""), "row")
  add_field(lines, "ARMOR", string.format("%s%s (AV%d)", approx, Roster.armorName(def.armor), def.armor), "row")
  add_field(lines, "NEEDS", (Roster.penetration(def.armor)), look)
  -- The easiest kills first: fatal parts by armor, then health. Wiki tables can list ten or more
  -- parts; the card shows three.
  local kills = {}
  for _, part in ipairs(def.parts or {}) do
    if part.fatal then
      kills[#kills + 1] = part
    end
  end
  table.sort(kills, function(a, b)
    if a.armor ~= b.armor then return a.armor < b.armor end
    return (a.hp or def.hp) < (b.hp or def.hp)
  end)
  for index = 1, math.min(#kills, 3) do
    local part = kills[index]
    add_line(lines, string.format("%-8s%s %s AV%d", index == 1 and "WEAK" or "", part.name:sub(1, 22),
      part.hp and tostring(part.hp) or "main", part.armor), "dim")
  end
  if #kills > 3 then
    add_line(lines, string.format("        +%d more kill spots", #kills - 3), "dim")
  end
  if def.weak then
    add_field(lines, "TIP", def.weak, "tier")
  end
  return lines
end

-- The card lasts as long as its target: it goes when the target dies or despawns, or when the mark
-- would have faded.
local function card_lines()
  local card = S.card
  if card == nil then
    return {}
  end
  local gone = not is_alive(card.unit) or (card.group ~= nil and C.live[card.unit] == nil)
  if gone or S.t >= card.expires then
    log(string.format("ping card closed t=%.1f: %s %s", S.t, card.group and card.group.name or card.hash,
      gone and "died or despawned" or "expired"))
    S.card = nil
    return {}
  end
  local pos, me = position_of(card.unit), position_of(card.anchor)
  return card_for(card, (pos and me) and distance(pos, me) or nil)
end

------------------------------------------------------------------------------------------------ HUD

-- Drawn exactly the way Detection Alert and P2P-Ping draw on this build: a screen gui on the main
-- world, then Gui.resolution, Gui.text, Gui.destroy_text and Gui.set_visible. No other draw call,
-- because a bad native call cannot be caught by pcall. Unchanged lines are left alone.
local HUD = {
  faulted = false, faults = 0, gui = nil, gui_world = nil,
  ids = {}, cache = {}, logged = {}, retry_at = 0,
  next_refresh = 0,
}

local function hud_log_once(key, text)
  if not HUD.logged[key] then
    HUD.logged[key] = true
    log("hud " .. text)
  end
end

local function hud_color(name)
  -- Not cached: Chef says an engine Color lasts only the frame it was made in.
  local make = engine_table("Color")
  local look = CFG.hud.look[name]
  if make == nil or look == nil then
    return nil
  end
  local ok, made = pcall(make, 255, look.r, look.g, look.b)
  if ok and made ~= nil then
    return made
  end
  return nil
end

local function hud_destroy_pair(target_gui, pair, destroy)
  if not destroy or pair == nil then
    return
  end
  if pair.shadow ~= nil then
    pcall(destroy, target_gui, pair.shadow)
  end
  if pair.main ~= nil then
    pcall(destroy, target_gui, pair.main)
  end
end

-- Forget the gui without touching it: used when its world may already be gone.
local function hud_drop()
  HUD.gui, HUD.gui_world = nil, nil
  HUD.ids, HUD.cache = {}, {}
end

local function hud_world_is_live(world)
  local worlds_fn = engine_fn("Application", "worlds")
  if not worlds_fn or world == nil then
    return false
  end
  local ok, worlds = pcall(worlds_fn)
  if not ok or type(worlds) ~= "table" then
    return false
  end
  for index = 1, #worlds do
    if worlds[index] == world then
      return true
    end
  end
  return false
end

local function hud_get_gui(game_world)
  if HUD.gui ~= nil and HUD.gui_world == game_world then
    return HUD.gui
  end
  if HUD.gui ~= nil and hud_world_is_live(HUD.gui_world) then
    local destroy = engine_fn("Gui", "destroy_text")
    for _, pair in pairs(HUD.ids) do
      hud_destroy_pair(HUD.gui, pair, destroy)
    end
    local destroy_gui = engine_fn("World", "destroy_gui")
    if destroy_gui then
      pcall(destroy_gui, HUD.gui_world, HUD.gui)
    end
  end
  hud_drop()
  local create = engine_fn("World", "create_screen_gui")
  if not create then
    hud_log_once("no_screen_gui", "World.create_screen_gui is missing")
    return nil
  end
  local ok, made = pcall(create, game_world, "scale", 1, 1)
  if not ok or made == nil then
    hud_log_once("gui_failed", "screen gui create failed: " .. tostring(made))
    return nil
  end
  HUD.gui, HUD.gui_world = made, game_world
  hud_log_once("gui_created", "screen gui created on the main world")
  return made
end

-- Panel and card lines with screen positions. Lines stack downward from each block's top.
local function hud_layout(width, height)
  local hud, placed = CFG.hud, {}
  local step = hud.font_size + hud.line_gap
  local function place(lines, x_fraction, y_fraction)
    local x = math.floor(width * x_fraction + 0.5)
    local y = math.floor(height * y_fraction + 0.5)
    for index, line in ipairs(lines) do
      placed[#placed + 1] = { text = line.text, look = line.look, x = x, y = y - (index - 1) * step }
    end
  end
  place(panel_lines(), hud.panel_x, hud.panel_y)
  place(card_lines(), hud.card_x, hud.card_y)
  return placed
end

local function hud_draw()
  if S.t < HUD.retry_at then
    return
  end
  local resolution = engine_fn("Gui", "resolution")
  local text_fn = engine_fn("Gui", "text")
  local Vector2 = engine_table("Vector2")
  if not resolution or not text_fn or Vector2 == nil then
    hud_log_once("api_missing", string.format("draw api missing: resolution=%s text=%s vector2=%s",
      tostring(resolution ~= nil), tostring(text_fn ~= nil), tostring(Vector2 ~= nil)))
    return
  end
  if S.t < HUD.next_refresh then
    return
  end
  HUD.next_refresh = S.t + CFG.hud.refresh

  local ok, width, height = pcall(resolution)
  if not ok or type(width) ~= "number" or type(height) ~= "number" or width <= 0 or height <= 0 then
    hud_log_once("resolution_failed", "resolution unavailable")
    return
  end
  hud_log_once("resolution_ok", string.format("resolution=%dx%d", width, height))
  local placed = hud_layout(width, height)
  if #placed == 0 and next(HUD.ids) == nil then
    return -- nothing shown and nothing to clear: no need for a gui at all (e.g. on the ship)
  end

  local game_world = engine_call("Application", "main_world")
  if game_world == nil then
    return
  end
  local target_gui = hud_get_gui(game_world)
  if target_gui == nil then
    HUD.retry_at = S.t + CFG.hud.retry_seconds
    return
  end

  local set_visible = engine_fn("Gui", "set_visible")
  if set_visible then
    pcall(set_visible, target_gui, true)
  end
  local destroy = engine_fn("Gui", "destroy_text")
  local font, size = CFG.hud.font, CFG.hud.font_size
  for index, line in ipairs(placed) do
    local cached = HUD.cache[index]
    local pair = HUD.ids[index] or {}
    if cached == nil or cached.text ~= line.text or cached.look ~= line.look or cached.x ~= line.x
      or cached.y ~= line.y or pair.main == nil then
      hud_destroy_pair(target_gui, pair, destroy)
      pair = {}
      local ok_shadow, shadow_pos = pcall(Vector2, line.x + 1, line.y - 1)
      local ok_main, main_pos = pcall(Vector2, line.x, line.y)
      local shadow_color, main_color = hud_color("shadow"), hud_color(line.look)
      if ok_shadow and shadow_pos ~= nil and shadow_color ~= nil then
        local drawn, id = pcall(text_fn, target_gui, line.text, font, size, font, shadow_pos, shadow_color)
        if drawn then
          pair.shadow = id
        end
      end
      if ok_main and main_pos ~= nil and main_color ~= nil then
        local drawn, id = pcall(text_fn, target_gui, line.text, font, size, font, main_pos, main_color)
        if drawn then
          pair.main = id
          hud_log_once("text_ok", "text call ok")
        else
          hud_log_once("text_failed", "text call failed: " .. tostring(id))
        end
      end
      HUD.ids[index] = pair
      HUD.cache[index] = line
    end
  end
  for index in pairs(HUD.ids) do
    if index > #placed then
      hud_destroy_pair(target_gui, HUD.ids[index], destroy)
      HUD.ids[index], HUD.cache[index] = nil, nil
    end
  end
end

-- A fault drops the gui (it is rebuilt on the next draw); too many in a row disarm the HUD only.
local function hud_guarded_tick()
  local ok, err = pcall(hud_draw)
  if ok then
    HUD.faults = 0
    return
  end
  HUD.faults = HUD.faults + 1
  log_error("hud", err)
  hud_drop()
  if HUD.faults >= CFG.hud.max_faults then
    HUD.faulted = true
    log("hud disarmed after repeated errors; the census and log keep running")
  end
end

----------------------------------------------------------------------------------------------- keys

-- Hotkeys and ping buttons share one press-edge poller. Each entry names its input device table
-- (Keyboard or Mouse); ids are resolved a second after start, and again after a settings change.
local KEYS = { ready = false, list = {} }

local function key_entry(device, name, label, handler)
  KEYS.list[#KEYS.list + 1] = { device = device, name = name, label = label, handler = handler, id = nil, down = false }
end

local function button_id(device, name)
  if engine_fn(device, "button_id") then
    return engine_call(device, "button_id", name)
  end
  if engine_fn(device, "button_index") then
    return engine_call(device, "button_index", name)
  end
  log(device .. " has neither button_id nor button_index")
  return nil
end

local function poll_keys()
  if not KEYS.ready and S.t >= 1 then
    KEYS.ready = true
    for _, key in ipairs(KEYS.list) do
      key.id = button_id(key.device, key.name)
      log(string.format("key %s.%s id=%s (%s)", key.device, key.name, tostring(key.id), key.label))
    end
  end
  for _, key in ipairs(KEYS.list) do
    if key.id ~= nil then
      local pressed = engine_call(key.device, "pressed", key.id) == true
      if pressed and not key.down then
        local ok, err = pcall(key.handler)
        if not ok then
          log_error("key " .. key.name, err)
        end
        HUD.next_refresh = 0 -- show the result now, not on the next refresh
      end
      key.down = pressed
    end
  end
end

local function toggle_panel()
  S.panel_visible = not S.panel_visible
  log("panel visible=" .. tostring(S.panel_visible))
end

local function cycle_difficulty()
  S.difficulty = S.difficulty % 10 + 1
  save_plan()
  log("difficulty=" .. S.difficulty)
end

-- Every faction, then each of its subfactions, in a fixed order: Automatons, Automatons / Incineration
-- Corps, Automatons / Jet Brigade, Illuminate, Terminids, and so on.
local function cycle_briefing_enemy()
  local options = {}
  for _, faction in ipairs(Roster.listFactions()) do
    options[#options + 1] = { faction = faction }
    for _, sub in ipairs(Roster.listSubfactions(faction)) do
      options[#options + 1] = { faction = faction, subfaction = sub }
    end
  end
  local index = 0
  local plan = S.plan
  for i, option in ipairs(options) do
    if plan and option.faction == plan.faction and option.subfaction == plan.subfaction then
      index = i
    end
  end
  local pick = options[index % #options + 1]
  S.plan = { faction = pick.faction, subfaction = pick.subfaction, type = plan and plan.type or CFG.mission_type,
    source = "game" }
  save_plan()
  log(string.format("plan set on the ship: %s / %s", pick.faction, tostring(pick.subfaction)))
end

local function ping_pressed()
  if S.session then
    on_ping()
  end
end

-- (Re)builds the key list from CFG, which the settings file can change at any time. Ids are resolved
-- again on the next poll.
local function build_keys()
  KEYS.list, KEYS.ready = {}, false
  key_entry("Keyboard", CFG.keys.panel, "panel toggle", toggle_panel)
  key_entry("Keyboard", CFG.keys.difficulty, "difficulty", cycle_difficulty)
  key_entry("Keyboard", CFG.keys.enemy, "briefing enemy", cycle_briefing_enemy)
  for _, button in ipairs(CFG.ping.buttons) do
    key_entry(button.device, button.name, "ping", ping_pressed)
  end
end

----------------------------------------------------------------------------------------------- tick

local function tick(dt)
  S.t = S.t + dt
  if S.t >= S.next_user_settings_check then
    S.next_user_settings_check = S.t + CFG.user_settings_check_seconds
    local loaded, load_err = pcall(load_user_settings)
    if not loaded then
      log_error("settings", load_err)
    end
  end
  if S.names_dirty then
    S.names_dirty = false
    build_groups()
  end
  if S.keys_dirty then
    S.keys_dirty = false
    build_keys()
    HUD.next_refresh = 0 -- positions or sizes may have changed too
  end
  local keys_ok, keys_err = pcall(poll_keys)
  if not keys_ok then
    log_error("poll_keys", keys_err)
  end

  if S.t >= S.next_session_check then
    S.next_session_check = S.t + 1
    local was = S.session
    S.session = in_game_session()
    if was and not S.session then
      log(string.format("session ended t=%.1f", S.t))
      reset_census()
      S.card = nil
      hud_drop() -- its world is going away; never touch it again
    elseif S.session and not was then
      log(string.format("session started t=%.1f", S.t))
    end
  end
  if not S.session then
    return
  end

  local ok, err = pcall(census_tick, dt)
  if not ok then
    log_error("census", err)
  end
  if C.seen_total == 0 and S.t >= S.next_plan_check then
    S.next_plan_check = S.t + CFG.plan_check_seconds -- on the ship: pick up a mission sent from the app
    local loaded, load_err = pcall(load_plan)
    if not loaded then
      log_error("plan", load_err)
    end
  end
  if S.t >= S.next_prune then
    S.next_prune = S.t + CFG.prune_seconds
    local pruned, prune_err = pcall(prune_dead)
    if not pruned then
      log_error("prune", prune_err)
    end
  end
  if not HUD.faulted then
    hud_guarded_tick()
  end
end

-- Chef calls update(dt) every frame. Errors stay inside this pcall, so none of them reach the game's tick.
local function update(dt)
  local ok, err = pcall(tick, tonumber(dt) or 0)
  if not ok then
    log_error("update tick", err)
  end
end

-------------------------------------------------------------------------------------------- startup

chef.own_log(CFG.log_name)
reset_census()
load_user_settings()
load_plan()
load_probe_state()
build_groups()
build_keys()
S.names_dirty, S.keys_dirty = false, false

do
  log(string.format("start: %s %s", CFG.version, tostring(_VERSION)))
  log("log file: " .. tostring(chef.log_file))
  local groups = 0
  for _ in pairs(G.by_key) do
    groups = groups + 1
  end
  log(string.format("name table: %d enemy hashes mapped into %d groups; %d game names point at missing enemies.lua ids%s",
    G.mapped, groups, #G.dangling, #G.dangling > 0 and (": " .. table.concat(G.dangling, ", ")) or ""))

  -- Live HP experiment: what the engine's component tables offer. Names and types only, no calls.
  if CFG.health_probe.enabled then
    for _, name in ipairs(CFG.health_probe.tables) do
      local space = engine_table(name)
      if type(space) == "table" then
        local members = {}
        for key, value in pairs(space) do
          members[#members + 1] = tostring(key) .. "=" .. type(value)
        end
        table.sort(members)
        log(string.format("health probe stingray.%s (%d): %s", name, #members, table.concat(members, " ")))
      else
        log("health probe stingray." .. name .. ": " .. type(space))
      end
    end
  end
end

return { update = update }
