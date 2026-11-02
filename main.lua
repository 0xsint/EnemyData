-- Helldivers 2 Enemy Intel - companion app (Lua 5.1)
--
-- Usage:
--   lua main.lua missions/example_bots.lua
--   lua main.lua --faction terminids --difficulty 7 --type eradicate [--subfaction predator_strain]
--   lua main.lua                      (asks for the mission interactively)
-- Add --no-color if your terminal shows raw escape codes. Loading a mission also sends it to the
-- in-game Enemy Intel mod (EnemyIntel.ini) as the pre-launch briefing; --no-send skips that.

local scriptDir = (arg and arg[0] or ""):match("^(.*[/\\])") or ""
package.path = scriptDir .. "?.lua;" .. package.path

local Term     = require("src.term")
local Briefing = require("src.briefing")
local HpUi     = require("src.hp_ui")
local PlanFile = require("src.plan_file")

-- Load a mission file. Mission files are plain data, so run them with an
-- empty environment (setfenv is Lua 5.1).
local function loadMission(path)
  local chunk, err = loadfile(path)
  if not chunk then return nil, err end
  if setfenv then setfenv(chunk, {}) end
  local ok, result = pcall(chunk)
  if not ok then return nil, result end
  if type(result) ~= "table" then return nil, path .. " must return a table" end
  return result
end

local function parseArgs(argv)
  local opts, i = { mission = {} }, 1
  while i <= #argv do
    local a = argv[i]
    if a == "--no-color" then
      opts.noColor = true
    elseif a == "--no-send" then
      opts.noSend = true
    elseif a == "--help" or a == "-h" then
      opts.help = true
    elseif a:sub(1, 2) == "--" then
      opts.mission[a:sub(3)] = argv[i + 1]
      i = i + 1
    else
      opts.file = a
    end
    i = i + 1
  end
  return opts
end

local function prompt(label)
  io.write(label)
  io.flush()
  return io.read("*l")
end

local function ask(label, choices, default)
  local hint = choices and (" [" .. table.concat(choices, "/") .. "]") or ""
  local d = default and (" (default " .. default .. ")") or ""
  local answer = prompt(label .. hint .. d .. ": ")
  if answer == nil then os.exit(0) end
  answer = answer:match("^%s*(.-)%s*$")
  if answer == "" then return default end
  return answer
end

local function askMission()
  print(Term.paint("bold", "Enter the mission details from the briefing screen."))
  local m = {}
  m.faction = ask("Faction", Briefing.listFactions(), "terminids")
  local subs = Briefing.listSubfactions(Briefing.key(m.faction))
  if #subs > 0 then
    local choices = { "none" }
    for _, s in ipairs(subs) do choices[#choices + 1] = s end
    m.subfaction = ask("Subfaction", choices, "none")
  end
  m.difficulty = ask("Difficulty", { "1-10" }, "7")
  m.type = ask("Mission type", Briefing.listMissionTypes(), "objective")
  m.planet = ask("Planet", nil, "Unknown")
  return m
end

local HELP = [[
Commands:
  ping <name|#>        open the HP card for an enemy (roster number, name or alias)
  hit <dmg> [part]     log damage on the pinged enemy, e.g. "hit 600 head"
  card                 redraw the current HP card
  reset                restore the pinged enemy to full health
  brief                show the mission roster again
  help                 this list
  quit                 exit]]

local function main()
  local opts = parseArgs(arg or {})
  if opts.noColor then Term.setColor(false) end
  if opts.help then
    print("lua main.lua [mission_file.lua] [--faction F --difficulty N --type T --subfaction S --planet P] [--no-color] [--no-send]")
    print("Loading a mission also sends it to the in-game Enemy Intel mod as your ship's briefing; --no-send skips that.")
    print(HELP)
    return
  end

  local raw
  if opts.file then
    local err
    raw, err = loadMission(opts.file)
    if not raw then
      print(Term.paint("red", "Could not load mission: " .. tostring(err)))
      os.exit(1)
    end
  elseif opts.mission.faction then
    raw = opts.mission
  else
    raw = askMission()
  end

  local mission, err = Briefing.normalize(raw)
  if not mission then
    print(Term.paint("red", "Bad mission: " .. err))
    os.exit(1)
  end

  local roster = Briefing.build(mission)
  Briefing.render(mission, roster)
  -- Hand the mission to the in-game mod, which shows it as the briefing on your ship.
  if not opts.noSend then
    local path, sendErr = PlanFile.write(mission)
    if path then
      print(Term.paint("green", "Sent to Enemy Intel in game: your ship shows this briefing within 2 s."))
    else
      print(Term.paint("gray", "Not sent to the game: " .. sendErr))
    end
  end
  print(Term.paint("gray", "Type 'help' for commands. Try: ping 1"))

  local target
  while true do
    local line = prompt(Term.paint("yellow", "intel> "))
    if line == nil then break end
    local cmd, rest = line:match("^%s*(%S*)%s*(.-)%s*$")
    cmd = cmd:lower()

    if cmd == "" then
      -- nothing
    elseif cmd == "quit" or cmd == "exit" or cmd == "q" then
      break
    elseif cmd == "help" or cmd == "?" then
      print(HELP)
    elseif cmd == "brief" or cmd == "roster" then
      Briefing.render(mission, roster)
    elseif cmd == "ping" or cmd == "p" then
      local enemy, inRosterOrErr = Briefing.find(rest, roster, mission.faction)
      if enemy then
        target = HpUi.newTarget(enemy, inRosterOrErr)
        HpUi.render(target)
      else
        print(Term.paint("red", inRosterOrErr))
      end
    elseif cmd == "hit" or cmd == "h" or cmd == "card" or cmd == "reset" then
      if not target then
        print(Term.paint("red", "No target. Ping an enemy first."))
      elseif cmd == "card" then
        HpUi.render(target)
      elseif cmd == "reset" then
        HpUi.reset(target)
        HpUi.render(target)
      else
        local dmg, part = rest:match("^(%S+)%s*(.-)$")
        local msg, hitErr = HpUi.applyDamage(target, dmg, part)
        if msg then
          HpUi.render(target)
          print(Term.paint(target.dead and "red" or "green", msg))
        else
          print(Term.paint("red", hitErr))
        end
      end
    else
      print(Term.paint("red", "Unknown command '" .. cmd .. "'. Type 'help'."))
    end
  end
  print("Democracy protects.")
end

main()
