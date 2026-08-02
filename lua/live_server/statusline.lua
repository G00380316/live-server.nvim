---@mod live_server.statusline Statusline integration
---
--- A statusline function is called on nearly every redraw, so this one does no
--- work: the string is rebuilt only when a server actually changes state,
--- tracked through the event bus's version counter.

local event = require("live_server.event")
local icons = require("live_server.ui.icons")

local M = {}

---@type { key: string?, value: string }
local cache = { key = nil, value = "" }

---@return live_server.Config
local function config()
  return require("live_server.config").get()
end

--- Statusline text for the current project, e.g. `● 5500`. Empty when nothing
--- is running here, so it takes no space in the statusline.
---@param opts? { global?: boolean } count every project, not just this one
---@return string
function M.component(opts)
  opts = opts or {}
  local project_root = opts.global and "*" or require("live_server.project").get().root
  local key = ("%d|%s|%s"):format(event.version, project_root, tostring(opts.global))
  if cache.key == key then
    return cache.value
  end

  local manager = require("live_server.manager")
  local servers = opts.global and manager.servers({ active_only = true })
    or manager.for_project(project_root, { active_only = true })

  local cfg = config()
  local parts = {}
  for _, server in ipairs(servers) do
    local glyph = icons.get(server.status)
    local label = tostring(server.port)
    if cfg.statusline.show_adapter then
      label = server.adapter.display .. " " .. label
    end
    if server.status ~= "running" then
      label = label .. " (" .. server.status .. ")"
    end
    parts[#parts + 1] = glyph ~= "" and (glyph .. " " .. label) or label
  end

  local value = ""
  if #parts > 0 then
    value = cfg.statusline.prefix .. table.concat(parts, " ")
  end

  cache = { key = key, value = value }
  return value
end

--- True when this project has at least one active server. Useful as a lualine
--- `cond`.
---@return boolean
function M.active()
  local project = require("live_server.project").get()
  return require("live_server.manager").find_active(project.root) ~= nil
end

--- Ready-made lualine component.
---
--- ```lua
--- sections = { lualine_x = { require("live_server.statusline").lualine() } }
--- ```
---@param opts? { global?: boolean, color?: table }
---@return table
function M.lualine(opts)
  opts = opts or {}
  return {
    function()
      return M.component(opts)
    end,
    cond = function()
      return M.component(opts) ~= ""
    end,
    color = opts.color,
    on_click = function()
      require("live_server.ui.dashboard").toggle()
    end,
  }
end

return M
