-- Behaviour tests for the assembled in-game mod (Lua 5.1):
--   lua5.1 build/assemble.lua && lua5.1 tests/mod_test.lua [--show]
--
-- Loads dist/enemy_intel.lua in a sandbox with a fake Helldivers 2 engine that records what the mod
-- draws, then drives update(dt) through scripted scenarios. The fake copies the real engine's quirks
-- that matter: Unit.world_position and Quaternion.forward return ONE shared scratch vector that every
-- call overwrites (in game this made every stored distance 0 m), the ship has hundreds of animated
-- units and no enemies, and a loading screen has no player unit. Only the calls the mod is allowed to
-- make are faked, so a new engine call shows up as "unavailable" in the captured log.

local root = ((arg and arg[0] or ""):match("^(.*[/\\])tests[/\\]") or "./")
local MOD_PATH = root .. "dist/enemy_intel.lua"
local SHOW = arg and arg[1] == "--show" -- print what the HUD draws in the main scenarios
package.path = root .. "?.lua;" .. package.path
local PlanFile = require("src.plan_file") -- the desktop app's writer, so both sides agree on the format
local Roster = require("src.roster")
local LOG_DIR = "<appdata>\\Arrowhead\\Helldivers2"
local CFG_PATH = LOG_DIR .. "\\EnemyIntel.ini"
local SETTINGS_PATH = LOG_DIR .. "\\EnemyIntelSettings.ini"
local PROBE_PATH = LOG_DIR .. "\\EnemyIntelProbe.txt"

local failures, checks = 0, 0
local function check(ok, msg)
  checks = checks + 1
  if not ok then
    failures = failures + 1
    print("FAIL: " .. msg)
  end
end

local function read(path)
  local handle = assert(io.open(path, "rb"))
  local body = handle:read("*a")
  handle:close()
  return body
end

local SOURCE = read(MOD_PATH)

-- Hashes by name, from the bundled table, so tests use the same data the mod does.
local HASH = {}
for hash, name in SOURCE:gmatch('%[%s*"(%x+)"%s*%]%s*=%s*"([^"\n]*)"') do
  if #hash == 16 and HASH[name] == nil then HASH[name] = hash end
end
local PLAYER = "4d1c334d294dfa97"
local PING = "q" -- the default ping key (the game's, and the user's)

------------------------------------------------------------------------------------- fake engine

local function new_world()
  return { units = {}, session = true, pressed = nil, camera_api = true, vector_fns = true, mouse = true,
    gui_count = 0, gui = nil, gui_calls_after_session = 0, files = {}, fail = {} }
end

-- yaw: the direction the unit faces, in radians from +x toward +y.
local function unit(hash, x, y, z, opts)
  opts = opts or {}
  return { hash = hash, pos = { x or 0, y or 0, z or 0 }, alive = true, yaw = opts.yaw or 0,
    animated = opts.animated ~= false, cameras = opts.cameras or 0 }
end

local function add_units(world, count, hash, x, y, opts)
  local made = {}
  for i = 1, count do
    local u = unit(hash, (x or 0) + i * 0.01, y or 0, 0, opts)
    world.units[#world.units + 1] = u
    made[#made + 1] = u
  end
  return made
end

-- Calls that would kill the real game. On a destroyed unit, every Unit function except alive is a
-- native assert there (1.3 crashed reading a just-destroyed gunship's position). The mod's pcall
-- would hide that here, so the fake records it and the run fails at the end if anything is recorded.
local FATAL = {}

local function make_engine(world)
  local function guard(name)
    if world.fail[name] then error("fake engine: " .. name .. " failed", 0) end
  end
  local function gui_call()
    if not world.session then world.gui_calls_after_session = world.gui_calls_after_session + 1 end
  end
  local function must_be_alive(u, name)
    if type(u) ~= "table" or u.alive ~= true then
      FATAL[#FATAL + 1] = "Unit." .. name .. " on a destroyed " .. tostring(type(u) == "table" and u.hash or u)
      error("fake engine: Unit." .. name .. " on a destroyed unit would crash the game", 0)
    end
  end
  -- One scratch vector for every Vector3 the engine hands out, like the real temporaries.
  local scratch = { x = 0, y = 0, z = 0 }
  local function temp(x, y, z)
    scratch.x, scratch.y, scratch.z = x, y, z
    return scratch
  end
  local quat_scratch = { yaw = 0 }
  return {
    Application = {
      main_world = function() return world end,
      worlds = function() return { world } end,
    },
    World = {
      units = function(w) return w.units end,
      create_screen_gui = function(w)
        gui_call()
        world.gui_count = world.gui_count + 1
        world.gui = { texts = {}, next_id = 1, visible = true }
        return world.gui
      end,
      destroy_gui = function(w, g) gui_call(); if world.gui == g then world.gui = nil end end,
      debug_camera_pose = function(w)
        world.camera_calls = (world.camera_calls or 0) + 1
        return world.camera and { pos = world.camera.pos, fwd = world.camera.fwd } or nil
      end,
    },
    Unit = {
      alive = function(u) return type(u) == "table" and u.alive == true end,
      resource_name = function(u) must_be_alive(u, "resource_name"); return { id = u.hash } end,
      has_animation_state_machine = function(u) must_be_alive(u, "has_animation_state_machine"); return u.animated end,
      world_position = function(u)
        must_be_alive(u, "world_position")
        guard("world_position")
        return temp(u.pos[1], u.pos[2], u.pos[3])
      end,
      world_rotation = function(u) must_be_alive(u, "world_rotation"); quat_scratch.yaw = u.yaw; return quat_scratch end,
      num_cameras = world.camera_api and function(u) must_be_alive(u, "num_cameras"); return u.cameras end or nil,
      has_data = function(u, key) must_be_alive(u, "has_data"); return u.data ~= nil and u.data[key] ~= nil end,
      get_data = function(u, key) must_be_alive(u, "get_data"); return u.data and u.data[key] end,
    },
    IdString64 = { to_string = function(v) return "#ID[" .. v.id .. "]" end },
    Vector3 = world.vector_fns and {
      x = function(v) return v.x end,
      y = function(v) return v.y end,
      z = function(v) return v.z end,
    } or {},
    Quaternion = {
      forward = function(q) return temp(math.cos(q.yaw), math.sin(q.yaw), 0) end,
    },
    -- world.camera = { pos = {x,y,z}, fwd = {x,y,z} } stands in for the game camera; nil = no pose.
    Matrix4x4 = {
      translation = function(m) return temp(m.pos[1], m.pos[2], m.pos[3]) end,
      forward = function(m) return temp(m.fwd[1], m.fwd[2], m.fwd[3]) end,
    },
    Vector2 = function(x, y) return { x = x, y = y } end,
    Color = function(a, r, g, b) return { a = a, r = r, g = g, b = b } end,
    Gui = {
      resolution = function() guard("resolution"); return 2560, 1440 end,
      text = function(g, text, font, size, material, pos, color)
        gui_call()
        guard("text")
        local id = g.next_id
        g.next_id = id + 1
        g.texts[id] = { text = text, x = pos.x, y = pos.y, color = color, size = size, font = font }
        return id
      end,
      destroy_text = function(g, id) gui_call(); g.texts[id] = nil end,
      set_visible = function(g, visible) gui_call(); g.visible = visible end,
    },
    Network = { game_session = function() return world.session and "session" or nil end },
    Keyboard = {
      button_id = function(name) return name end,
      pressed = function(id) return world.pressed == id end,
    },
    Mouse = world.mouse and {
      button_id = function(name) return "mouse_" .. name end,
      pressed = function(id) return world.pressed == id end,
    } or nil,
  }
end

local function make_io(files)
  return {
    open = function(path, mode)
      mode = mode or "r"
      if mode:find("r", 1, true) then
        if files[path] == nil then return nil, "no such file" end
        return { read = function() return files[path] end, close = function() end }
      end
      if not mode:find("a", 1, true) or files[path] == nil then
        files[path] = ""
      end
      return {
        write = function(self, ...) files[path] = files[path] .. table.concat({ ... }) end,
        flush = function() end,
        close = function() end,
      }
    end,
  }
end

-- Loads the mod the way Chef does: the chunk gets Chef's helper table as its argument, and the hooks it
-- returns are what the loader calls. Records every global it writes (there should be none). The fake
-- F9 menu keeps rows and values; chef.set changes a row and runs its handlers, as the menu does.
local function load_mod(world, no_menu)
  local log_lines, loader_lines, written = {}, {}, {}
  local env = {}
  env._G = env
  rawset(env, "stingray", make_engine(world))
  rawset(env, "io", make_io(world.files))
  rawset(env, "print", function() end)
  setmetatable(env, {
    __index = _G,
    __newindex = function(_, key, value) written[key] = true; rawset(env, key, value) end,
  })
  local chef = { log_directory = LOG_DIR, log_file = LOG_DIR .. "\\chef_loader.log" }
  local menu = { rows = {}, values = {}, handlers = {}, title = nil }
  -- As Chef does it: before own_log, chef.log writes to chef_loader.log; after it, to the mod's own file.
  function chef.log(text)
    loader_lines[#loader_lines + 1] = text
  end
  function chef.own_log(name)
    chef.log = function(text)
      log_lines[#log_lines + 1] = text
    end
    chef.log_file = LOG_DIR .. "\\" .. name .. ".log"
    return true
  end
  function chef.has(name)
    return name == "menu" and not no_menu
  end
  function chef.title(text)
    menu.title = text
  end
  function chef.option(id, spec)
    menu.rows[id] = spec
    if menu.values[id] == nil then
      menu.values[id] = spec.default
    end
    return menu.values[id]
  end
  function chef.get(id)
    return menu.values[id]
  end
  function chef.set(id, value)
    menu.values[id] = value
    for _, handler in ipairs(menu.handlers[id] or {}) do
      handler(value)
    end
  end
  function chef.on_change(id, handler)
    menu.handlers[id] = menu.handlers[id] or {}
    table.insert(menu.handlers[id], handler)
  end
  local chunk = assert(loadstring(SOURCE, "@enemy_intel.lua"))
  setfenv(chunk, env)
  local hooks = chunk(chef)
  return { env = env, log = log_lines, loader = loader_lines, written = written, world = world,
    update = hooks and hooks.update, menu = menu, chef = chef }
end

local function run(mod, seconds, dt)
  dt = dt or 1 / 30
  for _ = 1, math.floor(seconds / dt + 0.5) do
    local ok, err = pcall(mod.update, dt)
    if not ok then return false, err end
  end
  return true
end

local function press(mod, key)
  mod.world.pressed = key
  run(mod, 0.1)
  mod.world.pressed = nil
  run(mod, 0.6) -- one HUD refresh
end

-- Visible HUD text (shadows skipped), top line first, as { text, x, y, color }.
local function screen(world)
  local lines = {}
  if world.gui == nil then return lines end
  for _, t in pairs(world.gui.texts) do
    if t.color.r ~= 12 then lines[#lines + 1] = t end
  end
  table.sort(lines, function(a, b)
    if a.x ~= b.x then return a.x < b.x end
    return a.y > b.y
  end)
  return lines
end

local function screen_text(world)
  local out = {}
  for _, t in ipairs(screen(world)) do out[#out + 1] = t.text end
  return #out > 0 and (table.concat(out, "\n") .. "\n") or ""
end

local function show(title, world)
  if not SHOW then return end
  print("=== " .. title .. " ===")
  for _, t in ipairs(screen(world)) do
    print(string.format("  [x=%4d y=%4d %3d,%3d,%3d] %s", t.x, t.y, t.color.r, t.color.g, t.color.b, t.text))
  end
end

local function has(haystack, needle)
  return haystack:find(needle, 1, true) ~= nil
end

local function grep(mod, needle)
  for _, line in ipairs(mod.log) do
    if has(line, needle) then return line end
  end
  return nil
end

-- Layout-tolerant readers for the HUD, so the checks below test meaning rather than spacing.
local function esc(text)
  return (text:gsub("%p", "%%%0"))
end

-- The number column ("40", "~3", "<1") of the row named `name`, or nil.
local function count_of(world, name)
  for _, t in ipairs(screen(world)) do
    local n = t.text:match("^%s*(%S+)%s%s" .. esc(name) .. "%s+%[")
    if n then return n end
  end
  return nil
end

-- The ping card's title, ">> NAME      20 m", as ("NAME", "20 m"); nil when no card is up.
local function card(world)
  for _, t in ipairs(screen(world)) do
    local name, where = t.text:match("^>> (.-)%s%s+(%S.*)$")
    if name then return name, where end
  end
  return nil
end

-- True when the panel's title line is `title` with the difficulty `difficulty` at its right.
local function title_is(world, title, difficulty)
  for _, t in ipairs(screen(world)) do
    if t.text:find("^" .. esc(title) .. "%s+" .. esc(difficulty) .. "$") then return true end
  end
  return false
end

local function count_lines(mod, needle)
  local n = 0
  for _, line in ipairs(mod.log) do
    if has(line, needle) then n = n + 1 end
  end
  return n
end

------------------------------------------------------------------------------------- scenarios

-- The ship, as the in-game log saw it: one player unit and ~350 animated crew and props, no enemies.
-- With no mission planned yet, the briefing says how to plan one.
do
  local world = new_world()
  add_units(world, 1, PLAYER)
  add_units(world, 350, "0c6567f9e37920e1", 0, 0)
  local mod = load_mod(world)
  check(run(mod, 12), "ship: update errored")
  local text = screen_text(world)
  check(title_is(world, "MISSION BRIEFING", "D7"), "ship: no briefing prompt:\n" .. text)
  check(has(text, "Press F3 to pick"), "ship: prompt should explain F3:\n" .. text)
  check(not has(text, "ENEMY INTEL"), "ship: the ship's crew was treated as enemies")
  check(grep(mod, "session started") ~= nil, "ship: no session start logged")
  check(next(mod.written) == nil, "ship: the mod wrote a global: " .. tostring(next(mod.written)))
end

-- A mission loaded in the desktop app is briefed on the ship, and a new one sent while you wait
-- replaces it within the re-read interval.
do
  local world = new_world()
  local mission = assert(Roster.normalize(dofile(root .. "missions/example_bots.lua")))
  world.files[CFG_PATH] = PlanFile.format(mission)
  add_units(world, 1, PLAYER)
  add_units(world, 350, "0c6567f9e37920e1", 0, 0)
  local mod = load_mod(world)
  run(mod, 12)
  local text = screen_text(world)
  show("ship briefing sent from the desktop app (" .. mission.faction .. " D" .. mission.difficulty .. ")", world)
  check(title_is(world, "MISSION BRIEFING", "D" .. mission.difficulty), "app plan: wrong title or difficulty:\n" .. text)
  check(has(text, "\n" .. mission.faction:upper()), "app plan: faction missing:\n" .. text)
  check(has(text, mission.name .. " - " .. mission.planet), "app plan: name and planet missing:\n" .. text)
  check(text:find("Search%s+and Destroy") ~= nil, "app plan: mission type cut off:\n" .. text)
  check(has(text, "sent from the EnemyData app"), "app plan: source not shown")
  check(has(text, "EXPECT PER 20 ENEMIES"), "app plan: expectation header missing")
  check(text:find("\n%s+~%d+%s%s%u[%w ]+%[=") ~= nil, "app plan: no expected-count rows:\n" .. text)
  check(has(text, "MIX   light ~"), "app plan: class mix missing:\n" .. text)
  check(has(text, "Anti-tank required"), "app plan: loadout advice missing:\n" .. text)
  check(not has(text, "%"), "app plan: should show numbers, not percentages")
  for _, t in ipairs(screen(world)) do
    check(#t.text <= 46, "briefing: line too long for the column: " .. t.text)
  end

  world.files[CFG_PATH] = PlanFile.format(assert(Roster.normalize({
    faction = "terminids", subfaction = "predator_strain", difficulty = 4, type = "eradicate", planet = "Hellmire" })))
  run(mod, 2.5)
  text = screen_text(world)
  check(title_is(world, "MISSION BRIEFING", "D4") and has(text, "\nTERMINIDS / PREDATOR STRAIN\n"), "app plan: new plan not picked up:\n" .. text)
  check(has(text, "\nHellmire\nEradicate\n"), "app plan: placeholder name should be left out:\n" .. text)

  -- Garbage in the file: logged, the prompt shows, nothing breaks.
  world.files[CFG_PATH] = "faction=cyborgs\ndifficulty=5\n"
  check(run(mod, 2.5), "bad plan: update errored")
  check(grep(mod, "plan file ignored: unknown faction 'cyborgs'") ~= nil, "bad plan: not logged")
  check(has(screen_text(world), "Press F3 to pick"), "bad plan: prompt not shown")
end

-- F3 cycles the briefing's enemy on the ship and saves it; the briefing shows during the drop until the
-- first enemy appears; the faction actually fought becomes the next briefing.
do
  local world = new_world()
  add_units(world, 1, PLAYER)
  add_units(world, 350, "0c6567f9e37920e1", 0, 0)
  local mod = load_mod(world)
  run(mod, 6)
  press(mod, "f3")
  check(title_is(world, "MISSION BRIEFING", "D7") and has(screen_text(world), "\nAUTOMATONS\n"), "f3: first press should pick Automatons:\n" .. screen_text(world))
  press(mod, "f3")
  check(has(screen_text(world), "AUTOMATONS / CYBORG LEGION"), "f3: second press should pick the first subfaction (alphabetical)")
  check(has(screen_text(world), "set on the ship"), "f3: source not shown")
  check(has(world.files[CFG_PATH], "faction=automatons\nsubfaction=cyborg_legion"), "f3: plan not saved")

  -- Drop: players and props, no enemies yet. Still briefing.
  world.units = {}
  run(mod, 6) -- loading screen
  add_units(world, 4, PLAYER)
  add_units(world, 200, "7777777777777777", 0, 0)
  run(mod, 6)
  check(title_is(world, "MISSION BRIEFING", "D7") and has(screen_text(world), "\nAUTOMATONS"), "drop: briefing gone before any enemy showed up")

  -- They turn out to be bugs.
  local bugs = add_units(world, 15, HASH["Warrior"], 30, 0)
  run(mod, 6)
  check(title_is(world, "ENEMY INTEL", "D7") and has(screen_text(world), "\nTERMINIDS\n"), "mission: live panel did not take over:\n" .. screen_text(world))
  for _, b in ipairs(bugs) do b.alive = false end
  world.units = {}
  run(mod, 11) -- extraction, loading screen
  local loading = grep(mod, "loading t=")
  check(loading and has(loading, "faction=terminids"), "after mission: detected faction not remembered")
  add_units(world, 1, PLAYER)
  add_units(world, 350, "0c6567f9e37920e1", 0, 0)
  run(mod, 6)
  local text = screen_text(world)
  show("back on the ship after a terminid mission", world)
  check(title_is(world, "MISSION BRIEFING", "D7") and has(text, "\nTERMINIDS\n"), "after mission: briefing not updated to the faction fought:\n" .. text)
  check(has(text, "from your last mission"), "after mission: source not shown")
  check(has(world.files[CFG_PATH], "faction=terminids") and has(world.files[CFG_PATH], "source=last"), "after mission: not saved")
end

-- A plan sent from the app during a mission wins over what that mission detected.
do
  local world = new_world()
  world.files[CFG_PATH] = PlanFile.format(assert(Roster.normalize({ faction = "terminids", difficulty = 6 })))
  local mod = load_mod(world)
  add_units(world, 4, PLAYER)
  add_units(world, 15, HASH["Warrior"], 30, 0)
  run(mod, 12)
  world.files[CFG_PATH] = PlanFile.format(assert(Roster.normalize({ faction = "illuminate", difficulty = 8 })))
  world.units = {}
  run(mod, 11)
  check(grep(mod, "plan changed during the mission") ~= nil, "mid-mission plan: not detected")
  add_units(world, 1, PLAYER)
  run(mod, 6)
  check(title_is(world, "MISSION BRIEFING", "D8") and has(screen_text(world), "\nILLUMINATE\n"), "mid-mission plan: overwritten by the old mission:\n" .. screen_text(world))
end

-- Automaton mission: live counts, tiers, tags, anti-tank callout, unknown-hash logging.
local bots, B = nil, {}
do
  local world = new_world()
  B.me = add_units(world, 1, PLAYER, 0, 0, { cameras = 1 })[1]
  B.mate = add_units(world, 1, PLAYER, 0, 0)[1]
  B.mate2 = add_units(world, 1, PLAYER, 0, 0)[1]
  B.troopers = add_units(world, 40, HASH["Trooper"], 60, 40)
  B.devastators = add_units(world, 12, HASH["Devastator"], 70, 0)
  B.hulks = add_units(world, 3, HASH["Hulk Bruiser"], 20, 0)
  B.tanks = add_units(world, 2, HASH["Annihilator Tank"], 90, -60)
  add_units(world, 10, HASH["Supplies (Hellpod)"], 5, 5)
  add_units(world, 5, "00000000deadbeef", 5, 5)
  add_units(world, 3000, "1111111111111111", 0, 0, { animated = false })
  local mod = load_mod(world)
  check(run(mod, 12), "bots: update errored")
  local text = screen_text(world)
  show("automaton mission, panel", world)
  check(title_is(world, "ENEMY INTEL", "D7") and has(text, "\nAUTOMATONS\n"), "bots: title wrong:\n" .. text)
  check(has(text, "\n57 alive\n"), "bots: live count wrong:\n" .. text)
  local lines = screen(world)
  check(lines[5] and lines[5].text == "COMMON", "bots: first tier header should be COMMON:\n" .. text)
  check(lines[6] and lines[6].text:find("^%s+40  Trooper%s+%[==========%]$") ~= nil, "bots: Trooper row wrong: " .. tostring(lines[6] and lines[6].text))
  check(not has(text, "%"), "bots: the panel should show numbers, not percentages:\n" .. text)
  check(text:find("Annihilator Tank[^\n]*%]  AT\n") ~= nil, "bots: tank not tagged AT")
  check(text:find("Hulk Bruiser[^\n]*%]  HVY\n") ~= nil, "bots: hulk not tagged HVY")
  check(has(text, "BRING ANTI-TANK: Annihilator Tank"), "bots: no anti-tank callout")
  check(not has(text, "Supplies"), "bots: a hellpod was counted as an enemy")
  check(card(world) == nil, "bots: a card showed without a ping")
  check(grep(mod, "Supplies (Hellpod)=10") ~= nil, "bots: named-but-unmapped hellpod not logged")
  check(grep(mod, "00000000deadbeef=5") ~= nil, "bots: unknown animated hash not logged")
  check(grep(mod, "1111111111111111") == nil, "bots: static props should not be reported")
  check(grep(mod, "unavailable") == nil, "bots: mod called an engine function the fake lacks: " .. tostring(grep(mod, "unavailable")))
  for _, t in ipairs(screen(world)) do
    check(t.x == math.floor(2560 * 0.76 + 0.5), "bots: line drawn off the panel column")
  end
  bots = mod
end

-- Kills leave the panel within half a second; despawns (gone from the unit list) by the next pass.
do
  local world = bots.world
  for i = 1, 20 do B.troopers[i].alive = false end
  run(bots, 0.7)
  local text = screen_text(world)
  check(has(text, "\n37 alive\n"), "kills: dead troopers still counted:\n" .. text)
  check(count_of(world, "Trooper") == "20", "kills: Trooper count not 20:\n" .. text)

  local keep = {}
  for _, u in ipairs(world.units) do
    if u.hash ~= HASH["Devastator"] then keep[#keep + 1] = u end
  end
  world.units = keep
  run(bots, 11)
  text = screen_text(world)
  show("after 20 kills and 12 despawns", world)
  check(has(text, "\n25 alive\n"), "despawn: despawned devastators still counted:\n" .. text)
  check(not has(text, "Devastator"), "despawn: Devastator row still shown")
  check(grep(bots, "despawned=12") ~= nil, "despawn: not logged")
  for i = 1, 20 do B.troopers[i].alive = true end -- revive for the ping tests below; picked up next pass
end

-- Ping: the card is for the enemy you face, not the nearest one, and follows it until it dies.
do
  local world = bots.world
  B.me.pos = { 0, 0, 0 }
  B.me.yaw = 0 -- facing +x: hulks at ~20 m ahead, tanks off to the side, troopers off to the side
  B.mate.pos = { 70, 0, 0 } -- a squadmate standing in the devastators' old spot
  B.mate.yaw = math.pi
  local behind = add_units(world, 1, HASH["Raider"], -5, 0)[1] -- closer than the hulks, but behind you
  run(bots, 6)
  press(bots, "f5")
  check(card(world) == nil, "ping: F5 should no longer open a card")
  press(bots, PING)
  local text = screen_text(world)
  show("ping on the hulk ahead", world)
  check(select(1, card(world)) == "HULK BRUISER" and select(2, card(world)) == "20 m", "ping: wrong target or distance (0 m = stale temporary):\n" .. text)
  check(not has(text, "(squad)"), "ping: should know which unit is you")
  -- Wiki numbers: 1800 main, Heavy armor; the softest kill spot (heatsink, AV1) is listed first.
  check(has(text, "\nHP      1800\n") and has(text, "\nARMOR   Heavy (AV4)\n"), "ping: stats lines missing:\n" .. text)
  check(has(text, "\nNEEDS   Heavy pen (AP4+)\n"), "ping: penetration line missing")
  check(has(text, "\nWEAK    Heatsink 900 AV1\n") and has(text, "\n        Head 250 AV4\n"), "ping: weak parts missing:\n" .. text)
  check(not has(text, "(estimate)"), "ping: hulk stats are not estimates")
  check(grep(bots, "first call of Unit.has_data") == nil, "probe: the live-HP probe is finished and should not run")
  for _, t in ipairs(screen(world)) do
    check(#t.text <= 46, "card/panel: line too long for the column: " .. t.text)
  end

  -- It follows the enemy: move it and the distance updates.
  local target
  for _, h in ipairs(B.hulks) do if h.pos[1] < 21 and h.alive then target = target or h end end
  for _, h in ipairs(B.hulks) do h.pos = { h.pos[1] + 10, h.pos[2], h.pos[3] } end
  run(bots, 0.6)
  check(select(2, card(world)) == "30 m", "ping: distance does not follow the enemy:\n" .. screen_text(world))

  -- Killing the pinged enemy closes the card at once.
  for _, h in ipairs(B.hulks) do h.alive = false end
  run(bots, 0.6)
  check(card(world) == nil, "ping: card stayed after its enemy died")
  check(grep(bots, "died or despawned") ~= nil, "ping: card close not logged")

  -- Pinging empty ground (nothing within the cone) shows nothing.
  B.me.yaw = -math.pi / 2 -- facing -y: nothing there
  press(bots, PING)
  check(card(world) == nil, "ping: a card opened with nothing in front")
  check(grep(bots, "no enemy in front") ~= nil, "ping: empty ping not logged")

  -- The card fades after 8 s like the game's mark. Pinging a different type shows that type's stats.
  B.me.yaw = math.pi -- facing -x: the raider behind you
  press(bots, PING)
  text = screen_text(world)
  show("ping on a raider (estimated stats)", world)
  check(select(1, card(world)) == "RAIDER" and select(2, card(world)) == "5 m", "ping: raider not picked:\n" .. text)
  check(has(text, "\nHP      ~125 (estimate)\n") and has(text, "\nARMOR   ~Unarmored (AV0)\n"), "ping: raider stats should be marked as estimates:\n" .. text)
  check(not has(text, ">> HULK"), "ping: card still shows the previous target")
  run(bots, 8)
  check(card(world) == nil, "ping: card did not expire after 8 s")
  behind.alive = false

  -- F4 hides the panel; pings still work.
  press(bots, "f4")
  check(not has(screen_text(world), "ENEMY INTEL"), "f4: panel still visible")
  B.me.yaw = math.atan2(-60, 90) -- facing the tanks, on their own bearing away from the troopers
  press(bots, PING)
  check(card(world) == "ANNIHILATOR TANK", "f4: ping should work with the panel hidden:\n" .. screen_text(world))
  press(bots, "f4")
  check(has(screen_text(world), "ENEMY INTEL"), "f4: panel did not come back")
end

-- Squad fallback when no single unit can be identified as you.
do
  local world = new_world()
  world.camera_api = false
  local p1 = add_units(world, 1, PLAYER)[1]
  local p2 = add_units(world, 1, PLAYER)[1]
  p2.pos = { 500, 0, 0 }
  add_units(world, 15, HASH["Raider"], 503, 0)
  add_units(world, 10, "2222222222222222", 0, 0)
  local mod = load_mod(world)
  run(mod, 12)
  press(mod, PING)
  local text = screen_text(world)
  check(select(1, card(world)) == "RAIDER" and select(2, card(world)) == "3 m (squad)", "squad: card wrong:\n" .. text)
  check(grep(mod, "cannot tell which player unit is you") ~= nil, "squad: ambiguity not logged")
  p1.yaw, p2.yaw = math.pi / 2, math.pi / 2
  run(mod, 9)
  press(mod, PING)
  check(card(world) == nil, "squad: nobody faces an enemy, no card expected")
end

-- No enemies alive but the faction is known: the estimate for the next fight; F6 changes and saves the
-- difficulty.
do
  local world = new_world()
  add_units(world, 4, PLAYER)
  local warriors = add_units(world, 8, HASH["Warrior"], 30, 0)
  add_units(world, 20, "3333333333333333", 0, 0)
  local mod = load_mod(world)
  run(mod, 12)
  check(has(screen_text(world), "\n8 alive\n"), "estimate: live warriors not shown first")
  for _, w in ipairs(warriors) do w.alive = false end
  run(mod, 1)
  local text = screen_text(world)
  show("terminid mission, all enemies dead: estimate", world)
  check(title_is(world, "ENEMY INTEL", "D7") and has(text, "\nTERMINIDS\n"), "estimate: faction lost when the enemies died:\n" .. text)
  check(has(text, "\nnone nearby - expect per 20 (F6 difficulty)\n"), "estimate: estimate label missing:\n" .. text)
  check(count_of(world, "Scavenger") == "~3", "estimate: expected count per 20 missing:\n" .. text)
  check(not has(text, "%"), "estimate: should show numbers, not percentages")
  check(text:find("Charger[^\n]*%]  HVY\n") ~= nil, "estimate: D7 bug estimate should tag the Charger as heavy armor:\n" .. text)
  press(mod, "f6")
  text = screen_text(world)
  check(title_is(world, "ENEMY INTEL", "D8"), "f6: difficulty not updated:\n" .. text)
  check(has(world.files[CFG_PATH] or "", "difficulty=8\n"), "f6: difficulty not saved")
  for _ = 1, 3 do press(mod, "f6") end
  check(title_is(world, "ENEMY INTEL", "D1"), "f6: difficulty should wrap 10 -> 1")

  local world2 = new_world()
  world2.files = world.files
  add_units(world2, 1, PLAYER)
  add_units(world2, 350, "0c6567f9e37920e1", 0, 0)
  local mod2 = load_mod(world2)
  run(mod2, 12)
  check(title_is(world2, "MISSION BRIEFING", "D1"), "settings: saved difficulty not loaded:\n" .. screen_text(world2))
end

-- Subfaction detection, Illuminate, and a map where no faction has a clear majority.
do
  local world = new_world()
  add_units(world, 4, PLAYER)
  add_units(world, 20, HASH["Jet Brigade Trooper"], 30, 0)
  add_units(world, 10, HASH["Trooper"], 30, 0)
  local mod = load_mod(world)
  run(mod, 12)
  check(has(screen_text(world), "AUTOMATONS / JET BRIGADE"), "subfaction: Jet Brigade not detected:\n" .. screen_text(world))

  local ill = new_world()
  add_units(ill, 4, PLAYER)
  add_units(ill, 30, HASH["Voteless Light"], 30, 0)
  add_units(ill, 6, HASH["Overseer"], 30, 0)
  run(load_mod(ill), 12)
  check(has(screen_text(ill), "ILLUMINATE"), "illuminate: not detected")

  local mixed = new_world()
  add_units(mixed, 4, PLAYER)
  add_units(mixed, 10, HASH["Warrior"], 30, 0)
  add_units(mixed, 10, HASH["Trooper"], 30, 0)
  add_units(mixed, 10, "4444444444444444", 0, 0)
  run(load_mod(mixed), 12)
  check(has(screen_text(mixed), "\nFACTION UNKNOWN\n"), "mixed: should not claim a faction:\n" .. screen_text(mixed))
end

-- A squad wipe (no player units, enemies still animated) keeps the mission; a loading screen (no
-- player units, nothing animated) ends it and clears the HUD. Session end drops the gui untouched.
do
  local world = bots.world
  local enemies_only = {}
  for _, u in ipairs(world.units) do
    if u.hash ~= PLAYER then enemies_only[#enemies_only + 1] = u end
  end
  world.units = enemies_only
  run(bots, 11)
  check(grep(bots, "loading t=") == nil, "wipe: a squad wipe was treated as a loading screen")
  check(title_is(world, "ENEMY INTEL", "D7") and has(screen_text(world), "\nAUTOMATONS\n"), "wipe: panel lost during a squad wipe")

  world.units = { unit("ffffffffffffffff", 0, 0, 0, { animated = false }) }
  run(bots, 11)
  check(grep(bots, "loading t=") ~= nil, "loading: mission end not logged")
  check(screen_text(world) == "", "loading: HUD not cleared:\n" .. screen_text(world))

  world.session = false
  run(bots, 3)
  check(world.gui_calls_after_session == 0, "session end: touched the gui after the session ended")
  check(grep(bots, "session ended") ~= nil, "session end: not logged")
end

-- Engine variations and failures.
do
  -- No Vector3.x/y/z: components are read as fields instead, and pings still work.
  local world = new_world()
  world.vector_fns = false
  add_units(world, 1, PLAYER)
  add_units(world, 25, HASH["Trooper"], 40, 0)
  local mod = load_mod(world)
  run(mod, 12)
  press(mod, PING)
  check(select(1, card(world)) == "TROOPER" and select(2, card(world)) == "40 m", "fields: ping failed without Vector3.x:\n" .. screen_text(world))
  check(grep(mod, "reading components as fields") ~= nil, "fields: fallback not logged")

  -- No Mouse table: pings are off, nothing breaks, and the log says why.
  local nomouse = new_world()
  nomouse.mouse = false
  nomouse.files[SETTINGS_PATH] = "ping=mouse:middle\n"
  add_units(nomouse, 1, PLAYER)
  add_units(nomouse, 25, HASH["Trooper"], 40, 0)
  local mod2 = load_mod(nomouse)
  check(run(mod2, 12), "no mouse: update errored")
  check(grep(mod2, "Mouse has neither button_id nor button_index") ~= nil, "no mouse: not logged")

  -- Throwing engine calls never escape into the game's tick; the census keeps running.
  local bad = new_world()
  add_units(bad, 2, PLAYER)
  add_units(bad, 30, HASH["Trooper"], 10, 0)
  add_units(bad, 20, "5555555555555555", 0, 0)
  local mod3 = load_mod(bad)
  run(mod3, 12)
  bad.fail.world_position = true
  press(mod3, PING)
  check(card(bad) == nil, "fail: card opened without positions")
  bad.fail.resolution = true
  check(run(mod3, 8), "fail: an engine error escaped into update()")
  check(grep(mod3, "resolution unavailable") ~= nil, "fail: resolution failure not logged")
  local before = count_lines(mod3, "pass t=")
  run(mod3, 10)
  check(count_lines(mod3, "pass t=") > before, "fail: the census stopped after HUD errors")

  -- First calls of functions not yet seen working are announced before they run.
  check(grep(bots, "first call of Unit.world_rotation") ~= nil, "announce: world_rotation not announced")
  check(grep(bots, "first call of Matrix4x4.translation") == nil, "announce: camera used without a successful ship try")
end

-- Your settings file: written with defaults (ping on Q, HUD lower than 1.3), and edits apply live.
do
  local world = new_world()
  add_units(world, 1, PLAYER)
  add_units(world, 25, HASH["Trooper"], 40, 0)
  local mod = load_mod(world)
  run(mod, 12)
  local file = world.files[SETTINGS_PATH] or ""
  check(has(file, "\nping=keyboard:q\n"), "settings: default ping should be Q:\n" .. file)
  check(has(file, "panel_y=0.78") and has(file, "card_x=0.53"), "settings: layout defaults missing")
  local title = screen(world)[1]
  check(title and title.y == math.floor(1440 * 0.78 + 0.5), "settings: panel not at the new lower default: " .. tostring(title and title.y))
  press(mod, "q")
  local card_line
  for _, t in ipairs(screen(world)) do if t.text:find("^>> ") then card_line = t end end
  check(card_line and card_line.x == math.floor(2560 * 0.53 + 0.5) and card_line.y == math.floor(1440 * 0.46 + 0.5),
    "settings: card not next to the crosshair")
  run(mod, 9)

  -- Move the panel, rebind ping to E, add a bad line: applied within a few seconds, no restart.
  world.files[SETTINGS_PATH] = file:gsub("panel_y=0.78", "panel_y=0.50"):gsub("ping=keyboard:q", "ping=keyboard:e")
    .. "font_size=999\nnonsense line\n"
  run(mod, 3.5)
  title = screen(world)[1]
  check(title and title.y == 720, "settings: panel_y edit not applied: " .. tostring(title and title.y))
  press(mod, "q")
  check(card(world) == nil, "settings: Q should no longer ping")
  press(mod, "e")
  check(card(world) == "TROOPER", "settings: E should ping now:\n" .. screen_text(world))
  check(grep(mod, "ignored line: font_size=999 (allowed 10-60)") ~= nil, "settings: out-of-range value not reported")
  check(grep(mod, "ignored line: nonsense line") ~= nil, "settings: bad line not reported")
end

-- F9 menu (Chef): the rows and the settings file agree in both directions, and a font change redraws.
do
  local world = new_world()
  add_units(world, 1, PLAYER)
  add_units(world, 25, HASH["Trooper"], 40, 0)
  local mod = load_mod(world)
  run(mod, 12)
  local menu = mod.menu
  check(menu.title == "Enemy Intel", "menu: title missing")
  check(menu.rows.panel_y and menu.rows.panel_y.type == "slider" and menu.rows.panel_y.max == 1, "menu: panel_y slider missing")
  check(menu.rows.font_size and menu.rows.font_size.step == 1 and menu.rows.font_size.max == 60, "menu: font_size range wrong")
  check(menu.rows.camera_aim and menu.rows.camera_aim.type == "toggle", "menu: camera_aim toggle missing")
  check(menu.rows.panel_key == nil and menu.rows.ping_key == nil, "menu: key bindings should stay in the file")
  check(menu.values.panel_y == 0.78, "menu: panel_y not at the file's value")

  -- Menu -> file, and the panel moves.
  mod.chef.set("panel_y", 0.5)
  run(mod, 0.6)
  check(has(world.files[SETTINGS_PATH], "panel_y=0.5\n"), "menu: change not written to the file")
  check(has(world.files[SETTINGS_PATH], "ping=keyboard:q\n"), "menu: an unrelated line was changed")
  local title = screen(world)[1]
  check(title and title.y == 720, "menu: panel did not move: " .. tostring(title and title.y))

  -- File -> menu: an edit to the file reaches the row within a few seconds.
  world.files[SETTINGS_PATH] = world.files[SETTINGS_PATH]:gsub("rows=8", "rows=3")
  run(mod, 3.5)
  check(menu.values.rows == 3, "menu: file edit did not reach the menu row")

  -- A font size change redraws every line at the new size.
  mod.chef.set("font_size", 30)
  run(mod, 0.6)
  check(has(world.files[SETTINGS_PATH], "font_size=30\n"), "menu: font size not written")
  local sizes = {}
  for _, t in ipairs(screen(world)) do sizes[t.size] = true end
  check(sizes[30] and not sizes[22], "menu: font size change not redrawn")

  -- A toggle through the menu.
  mod.chef.set("show_unidentified", false)
  run(mod, 0.2)
  check(has(world.files[SETTINGS_PATH], "show_unidentified=false\n"), "menu: toggle not written")
end

-- No F9 menu in this Chef build: nothing is registered, the log says where to set the values.
do
  local world = new_world()
  add_units(world, 1, PLAYER)
  local mod = load_mod(world, true)
  check(run(mod, 12), "no menu: update errored")
  check(next(mod.menu.rows) == nil, "no menu: rows registered anyway")
  check(grep(mod, "has no F9 menu") ~= nil, "no menu: not logged")
end

-- Unidentified enemies: hashes in no table get rows and counts once they move; scenery (never moves)
-- and anything seen on the ship stay off. Ping one to see its hash, then name it in the settings file.
do
  local NEW = "2ed3696e12a14d4c" -- a moving hash from the 1.3 log, rising and falling with the fight
  local PROP = "31fe436fbf7ba57f" -- constant 63 all mission: scenery
  local CREW = "0c6567f9e37920e1" -- on the ship and in missions
  local OTHER = "4d61156dd350a82b"
  local world = new_world()
  local me = add_units(world, 1, PLAYER)[1]
  local crew = add_units(world, 20, CREW, 0, 0)
  local mod = load_mod(world)
  run(mod, 6) -- ship: CREW is learned as ship hash
  for _, u in ipairs(crew) do u.pos = { u.pos[1] + 10, 0, 0 } end
  run(mod, 6)
  world.units = {}
  run(mod, 6) -- loading
  world.units = { me }
  add_units(world, 10, HASH["Trooper"], 30, 30)
  local new = add_units(world, 6, NEW, 40, 0)
  add_units(world, 63, PROP, 0, 50)
  local others = add_units(world, 4, OTHER, 0, -40)
  for _, u in ipairs(crew) do world.units[#world.units + 1] = u end
  run(mod, 6)
  for _, u in ipairs(new) do u.pos = { u.pos[1] + 5, u.pos[2], 0 } end
  for _, u in ipairs(others) do u.pos = { u.pos[1], u.pos[2] - 5, 0 } end
  for _, u in ipairs(crew) do u.pos = { u.pos[1] + 5, 0, 0 } end
  run(mod, 11)
  local text = screen_text(world)
  show("unidentified enemies", world)
  check(has(text, "\n10 alive  +10 unidentified\n"), "unidentified: totals line wrong:\n" .. text)
  check(has(text, "UNIDENTIFIED"), "unidentified: section missing")
  check(count_of(world, "Unknown 2ed3696e") == "6", "unidentified: moving hash not listed with its count:\n" .. text)
  check(not has(text, "31fe436f"), "unidentified: scenery that never moves was listed")
  check(not has(text, "0c6567f9"), "unidentified: a hash seen on the ship was listed")

  -- Kills leave the unidentified rows within half a second too.
  local before_kill = count_of(world, "Unknown 4d61156d")
  others[1].alive = false
  run(mod, 0.7)
  check(before_kill == "4" and count_of(world, "Unknown 4d61156d") == "3",
    "unidentified: a kill did not lower the count:\nBEFORE\n" .. text .. "AFTER\n" .. screen_text(world))

  -- Ping one: the card shows its hash and the line that names it.
  me.pos, me.yaw = { 0, 0, 0 }, 0 -- facing +x, at the NEW group ~45 m away
  press(mod, PING)
  text = screen_text(world)
  show("ping on an unidentified enemy", world)
  check(select(1, card(world)) == "UNIDENTIFIED" and select(2, card(world)) == "45 m", "unidentified ping: wrong card:\n" .. text)
  check(has(text, "\nHASH    " .. NEW .. "\n"), "unidentified ping: full hash missing")
  check(has(text, "hash." .. NEW .. "=Name"), "unidentified ping: naming hint missing")
  check(grep(mod, "ping t=") and has(grep(mod, "unidentified " .. NEW) or "", NEW), "unidentified ping: not logged with the hash")
  run(mod, 9)

  -- Name it (borrowing Raider stats) and hide OTHER: both apply within a few seconds.
  world.files[SETTINGS_PATH] = world.files[SETTINGS_PATH] .. "hash." .. NEW .. "=Raider Captain|raider\nignore=" .. OTHER .. "\n"
  run(mod, 9)
  text = screen_text(world)
  check(count_of(world, "Raider Captain") == "6", "naming: named hash not counted as an enemy:\n" .. text)
  check(not has(text, "Unknown 2ed3696e"), "naming: still listed as unidentified")
  check(not has(text, "Unknown 4d61156d"), "ignore: ignored hash still listed")
  check(has(text, "\n16 alive"), "naming: total should include the named hash:\n" .. text)
  press(mod, PING)
  text = screen_text(world)
  check(card(world) == "RAIDER CAPTAIN" and has(text, "\nHP      ~125"), "naming: card should use the borrowed stats:\n" .. text)
end

-- Camera aim: tried once on the ship; when usable, it decides who you are and where you aim, which
-- facing alone cannot do in a squad (in game every player had num_cameras = 0).
do
  local world = new_world()
  local me = add_units(world, 1, PLAYER)[1]
  add_units(world, 30, "0c6567f9e37920e1", 0, 0)
  world.camera = { pos = { -3, 0, 2 }, fwd = { 1, 0, 0 } } -- 3 m behind you, looking +x
  local mod = load_mod(world)
  run(mod, 6)
  check(has(world.files[PROBE_PATH] or "", "try camera\nok camera: 3.6 m from your character\n"),
    "camera: ship try not recorded: " .. tostring(world.files[PROBE_PATH]))
  check(grep(mod, "camera aim: ok after one try on the ship") ~= nil, "camera: result not logged")
  local calls = world.camera_calls
  run(mod, 12)
  check(world.camera_calls == calls, "camera: tried again on the ship after the first try")

  -- In a squad. Your character faces +y (away from the hulk), squadmates face raiders near them; the
  -- camera (behind you, looking +x) is what you actually aim with.
  world.units = {}
  run(mod, 6)
  me.yaw = math.pi / 2
  world.units = { me }
  local mate = add_units(world, 1, PLAYER)[1]
  mate.pos, mate.yaw = { 200, 0, 0 }, 0
  add_units(world, 3, HASH["Hulk Bruiser"], 20, 0)
  add_units(world, 15, HASH["Raider"], 205, 0)
  run(mod, 6)
  press(mod, PING)
  local text = screen_text(world)
  check(select(1, card(world)) == "HULK BRUISER" and select(2, card(world)) == "20 m", "camera: ping should follow the camera, not facing:\n" .. text)
  check(not has(text, "(squad)"), "camera: should know which player is you")
  check(grep(mod, "basis=camera") ~= nil, "camera: basis not logged")

  -- A camera that is not near any player (a debug camera) is unusable; pings fall back to facing.
  local far = new_world()
  add_units(far, 1, PLAYER)
  far.camera = { pos = { 900, 0, 0 }, fwd = { 1, 0, 0 } }
  run(load_mod(far), 6)
  check(has(far.files[PROBE_PATH] or "", "unusable camera: 900 m from the nearest player"), "camera: far camera not rejected")

  -- The game died during the last try: never call it again.
  local crashed = new_world()
  crashed.files[PROBE_PATH] = "try camera\n"
  crashed.camera = { pos = { 0, 0, 0 }, fwd = { 1, 0, 0 } }
  add_units(crashed, 1, PLAYER)
  local crashed_mod = load_mod(crashed)
  run(crashed_mod, 12)
  check((crashed.camera_calls or 0) == 0, "camera: called again after a crash")
  check(grep(crashed_mod, "never tried again") ~= nil, "camera: crash not reported")

  -- camera_aim=false in the settings: never called.
  local off = new_world()
  off.files[SETTINGS_PATH] = "camera_aim=false\n"
  off.camera = { pos = { 0, 0, 0 }, fwd = { 1, 0, 0 } }
  add_units(off, 1, PLAYER)
  run(load_mod(off), 12)
  check((off.camera_calls or 0) == 0, "camera: called with camera_aim=false")
end

-- Retargeting. Every ping replaces the card: a new enemy switches it, empty ground clears it, and an
-- enemy that just died or despawned clears it too, even with a live enemy standing right behind it.
do
  local world = new_world()
  local me = add_units(world, 1, PLAYER)[1]
  me.pos = { 0, 0, 0 }
  local raider = add_units(world, 1, HASH["Raider"], 10, 0)[1] -- ahead, 10 m
  add_units(world, 1, HASH["Hulk Bruiser"], 20, 0) -- ahead, behind the raider
  local dev = add_units(world, 1, HASH["Devastator"], 0, 30)[1] -- to the left
  add_units(world, 20, HASH["Trooper"], -60, -60) -- elsewhere, so the mission has enough enemies
  local mod = load_mod(world)
  run(mod, 12)

  me.yaw = 0
  press(mod, PING)
  check(card(world) == "RAIDER", "retarget: first ping should take the nearest enemy ahead:\n" .. screen_text(world))
  me.yaw = math.pi / 2
  press(mod, PING)
  check(card(world) == "DEVASTATOR", "retarget: a new ping should switch to the new enemy:\n" .. screen_text(world))
  check(grep(mod, "(new target)") ~= nil, "retarget: switch not logged")
  me.yaw = -math.pi / 2 -- nothing over there
  press(mod, PING)
  check(card(world) == nil, "retarget: a ping on empty ground should clear the card:\n" .. screen_text(world))
  check(grep(mod, "no enemy in front (origins=1 basis=you); card cleared") ~= nil, "retarget: clear not logged")

  -- The raider dies; pinging its spot shows nothing, not the hulk standing behind it.
  raider.alive = false
  run(mod, 1)
  me.yaw = 0
  press(mod, PING)
  check(card(world) == nil, "dead: a ping on a fresh corpse should show nothing:\n" .. screen_text(world))
  check(grep(mod, "Raider is dead or despawned; card cleared") ~= nil, "dead: corpse ping not logged")
  run(mod, 16) -- the corpse fades: the same ping now reaches the hulk
  press(mod, PING)
  check(card(world) == "HULK BRUISER", "dead: once the corpse fades the ping should reach the hulk:\n" .. screen_text(world))

  -- The devastator despawns (leaves the unit list without dying): its spot shows nothing too.
  local keep = {}
  for _, u in ipairs(world.units) do
    if u ~= dev then keep[#keep + 1] = u end
  end
  world.units = keep
  run(mod, 11)
  me.yaw = math.pi / 2
  press(mod, PING)
  check(card(world) == nil, "despawn: a ping where an enemy despawned should show nothing:\n" .. screen_text(world))
  check(grep(mod, "Devastator is dead or despawned") ~= nil, "despawn: not logged")
end

-- Chef: the mod returns its hooks and writes no global; the previous-update chain is gone with the
-- Bingus loader, and Chef calls the mod's update(dt) itself.
do
  local world = new_world()
  local mod = load_mod(world)
  check(type(mod.update) == "function", "hooks: no update hook returned")
  check(next(mod.written) == nil, "hooks: a global was written")
  check(grep(mod, "start: enemy-intel") ~= nil, "hooks: start line not in the mod's own log")
  check(#mod.loader == 0, "hooks: mod lines went to chef_loader.log after own_log: " .. tostring(mod.loader[1]))
  check(run(mod, 1), "hooks: update errored")
end

-- Cost: a full 17,000-unit world, as on a real map, at 60 fps, with 400 live enemies to prune.
do
  local world = new_world()
  add_units(world, 4, PLAYER)
  add_units(world, 400, HASH["Trooper"], 50, 0)
  add_units(world, 16600, "6666666666666666", 0, 0, { animated = false })
  local mod = load_mod(world)
  local started = os.clock()
  run(mod, 10, 1 / 60)
  local per_frame_ms = (os.clock() - started) / 600 * 1000
  print(string.format("cost: %.3f ms per frame with 17,004 units (fake engine, plain Lua 5.1)", per_frame_ms))
  check(per_frame_ms < 2, "cost: too slow per frame")
end

-- The 1.3 crash: a gunship is destroyed a moment before you ping it (before the half-second prune drops
-- it), and later your own character dies while a card is up. Nothing may touch either dead unit.
do
  local world = new_world()
  local me = add_units(world, 1, PLAYER)[1]
  local mate = add_units(world, 1, PLAYER)[1]
  mate.pos = { 0, 30, 0 }
  local gunships = add_units(world, 2, HASH["Gunship"], 25, 0)
  add_units(world, 20, HASH["Raider"], 60, 0)
  local mod = load_mod(world)
  run(mod, 12)
  local before = #FATAL
  gunships[1].alive, gunships[2].alive = false, false
  press(mod, PING) -- same frame as the kill: the prune has not run yet
  check(#FATAL == before, "crash: the ping touched a destroyed gunship: " .. tostring(FATAL[#FATAL]))
  check(card(world) == nil, "crash: a ping on a just-destroyed gunship should show nothing:\n" .. screen_text(world))
  check(grep(mod, "Gunship is dead or despawned; card cleared") ~= nil, "crash: corpse ping not logged")
  run(mod, 16) -- the gunship corpses fade; now the ping reaches the raiders behind them
  press(mod, PING)
  check(card(world) == "RAIDER", "crash: after the corpses fade the ping should reach the raiders:\n" .. screen_text(world))
  me.alive = false -- you die with the card up; then the squadmate pings
  run(mod, 1)
  check(#FATAL == before, "crash: the card read a dead player's position: " .. tostring(FATAL[#FATAL]))
  press(mod, PING)
  check(#FATAL == before, "crash: a ping touched a dead player: " .. tostring(FATAL[#FATAL]))
end

check(#FATAL == 0, "game-killing calls on destroyed units: " .. table.concat(FATAL, "; "))
print(string.format("%d checks, %d failures", checks, failures))
os.exit(failures == 0 and 0 or 1)
