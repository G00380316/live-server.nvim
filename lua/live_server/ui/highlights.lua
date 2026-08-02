---@mod live_server.ui.highlights Themeable highlight groups
---
--- Every group links to a standard group with `default = true`, so the plugin
--- inherits any colorscheme (light or dark, true colour or 16-colour) without
--- shipping a palette of its own, and a user override always wins.

local M = {}

---@type table<string, string|table>
local links = {
  LiveServerNormal = "NormalFloat",
  LiveServerBorder = "FloatBorder",
  LiveServerTitle = "FloatTitle",
  LiveServerHeader = "Title",
  LiveServerProject = "Directory",
  LiveServerAdapter = "Identifier",
  LiveServerPort = "Number",
  LiveServerUrl = "@markup.link.url",
  LiveServerRunning = "DiagnosticOk",
  LiveServerStarting = "DiagnosticWarn",
  LiveServerStopping = "DiagnosticWarn",
  LiveServerStopped = "Comment",
  LiveServerCrashed = "DiagnosticError",
  LiveServerUnhealthy = "DiagnosticWarn",
  LiveServerKey = "Special",
  LiveServerHint = "Comment",
  LiveServerBadge = "DiagnosticInfo",
  LiveServerWarnBadge = "DiagnosticWarn",
  LiveServerSeparator = "WinSeparator",
  LiveServerCursorLine = "CursorLine",
  LiveServerLogOut = "Normal",
  LiveServerLogErr = "DiagnosticError",
  LiveServerLogMeta = "Comment",
  LiveServerLogTime = "Comment",
}

--- Fallbacks for groups a colorscheme may not define.
---@type table<string, string[]>
local fallbacks = {
  FloatTitle = { "Title" },
  ["@markup.link.url"] = { "Underlined" },
  DiagnosticOk = { "String" },
}

---@param name string
---@return boolean
local function group_exists(name)
  local ok, hl = pcall(vim.api.nvim_get_hl, 0, { name = name, link = false })
  return ok and hl ~= nil and next(hl) ~= nil
end

---@param name string
---@return string
local function resolve_target(name)
  if group_exists(name) then
    return name
  end
  for _, candidate in ipairs(fallbacks[name] or {}) do
    if group_exists(candidate) then
      return candidate
    end
  end
  return name
end

--- (Re)define every group. Safe to call repeatedly.
function M.apply()
  local overrides = require("live_server.config").get().ui.highlights or {}

  for group, target in pairs(links) do
    if overrides[group] == nil then
      vim.api.nvim_set_hl(0, group, { link = resolve_target(target), default = true })
    end
  end

  for group, spec in pairs(overrides) do
    if type(spec) == "string" then
      vim.api.nvim_set_hl(0, group, { link = spec })
    elseif type(spec) == "table" then
      vim.api.nvim_set_hl(0, group, spec)
    end
  end
end

--- Highlight group for a server status.
---@param status live_server.Status
---@return string
function M.for_status(status)
  local map = {
    running = "LiveServerRunning",
    starting = "LiveServerStarting",
    stopping = "LiveServerStopping",
    stopped = "LiveServerStopped",
    crashed = "LiveServerCrashed",
    unhealthy = "LiveServerUnhealthy",
  }
  return map[status] or "LiveServerStopped"
end

--- Install the groups and keep them correct across `:colorscheme`.
function M.setup()
  M.apply()
  vim.api.nvim_create_autocmd("ColorScheme", {
    group = vim.api.nvim_create_augroup("LiveServerHighlights", { clear = true }),
    callback = M.apply,
    desc = "Reapply live-server.nvim highlight groups",
  })
end

return M
