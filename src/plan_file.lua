-- Hands the mission loaded in the desktop app to the in-game Enemy Intel mod, which shows it as the
-- pre-launch briefing on your ship. (Lua 5.1)
--
-- The file is the mod's EnemyIntel.ini: key=value lines, read by load_plan in mod/enemy_intel.lua.
-- Keep the two in step. It lives in the Chef Shared Loader log folder, which Chef lets the mod read.

local M = {}

M.SUFFIX = "\\Arrowhead\\Helldivers2\\EnemyIntel.ini"

function M.path()
  local base = os.getenv("APPDATA")
  return base and (base .. M.SUFFIX) or nil
end

-- One line per field; values may not contain line breaks. The desktop app's placeholder name and
-- planet are left out so the in-game briefing only shows what you actually entered.
function M.format(mission)
  local function clean(value)
    return value and tostring(value):gsub("[\r\n]", " ") or ""
  end
  local name = mission.name ~= "Unnamed Operation" and mission.name or nil
  local planet = mission.planet ~= "Unknown" and mission.planet or nil
  return table.concat({
    "difficulty=" .. clean(mission.difficulty),
    "faction=" .. clean(mission.faction),
    "subfaction=" .. clean(mission.subfaction),
    "type=" .. clean(mission.type),
    "name=" .. clean(name),
    "planet=" .. clean(planet),
    "source=app",
  }, "\n") .. "\n"
end

-- Returns the path written, or nil and why not.
function M.write(mission, path)
  path = path or M.path()
  if not path then
    return nil, "APPDATA is not set"
  end
  local handle, err = io.open(path, "w")
  if not handle then
    return nil, "cannot write " .. path .. " (" .. tostring(err) .. "); is Chef Shared Loader installed?"
  end
  handle:write(M.format(mission))
  handle:close()
  return path
end

return M
