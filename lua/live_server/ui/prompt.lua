---@mod live_server.ui.prompt Input helpers built on vim.ui
---
--- Everything goes through `vim.ui.input`/`vim.ui.select`, so users of
--- telescope, fzf-lua, snacks or dressing get their own picker for free and
--- nobody has to learn a bespoke widget.

local adapters = require("live_server.adapters")
local icons = require("live_server.ui.icons")
local log = require("live_server.log")
local net = require("live_server.net")

local M = {}

--- Ask for a port, re-prompting on invalid or occupied input.
---@param opts { default?: integer, host?: string, prompt?: string, allow_busy?: boolean }
---@param callback fun(port: integer?)
function M.port(opts, callback)
  opts = opts or {}
  local host = opts.host or require("live_server.config").get().host

  vim.ui.input({
    prompt = opts.prompt or "Port: ",
    default = opts.default and tostring(opts.default) or nil,
  }, function(input)
    if input == nil or vim.trim(input) == "" then
      return callback(nil)
    end

    local value = vim.trim(input)
    local valid, err = net.valid_port(value)
    if not valid then
      log.notify(err or "invalid port", "warn")
      return M.port(vim.tbl_extend("force", opts, { default = value }), callback)
    end

    local port = tonumber(value)
    if not opts.allow_busy and not net.is_free(host, port) then
      net.port_owner(port, function(owner)
        log.notify(
          owner and ("Port %d is in use by %s."):format(port, owner) or ("Port %d is already in use."):format(port),
          "warn"
        )
        M.port(vim.tbl_extend("force", opts, { default = value }), callback)
      end)
      return
    end

    callback(port)
  end)
end

--- Pick a server backend. Unavailable ones are listed but clearly marked, so
--- the answer to "why isn't browser-sync here?" is on screen.
---@param opts? { prompt?: string, include_unavailable?: boolean }
---@param callback fun(name: string?)
function M.adapter(opts, callback)
  opts = opts or {}
  local entries = {}
  for _, spec in ipairs(adapters.all()) do
    local available = adapters.available(spec.name)
    if available or opts.include_unavailable ~= false then
      entries[#entries + 1] = {
        name = spec.name,
        spec = spec,
        available = available,
      }
    end
  end

  table.sort(entries, function(a, b)
    if a.available ~= b.available then
      return a.available
    end
    return a.name < b.name
  end)

  if #entries == 0 then
    log.notify("No server backends are registered.", "error")
    return callback(nil)
  end
  if #entries == 1 and entries[1].available then
    return callback(entries[1].name)
  end

  vim.ui.select(entries, {
    prompt = opts.prompt or "Server:",
    format_item = function(entry)
      local parts = { entry.spec.display }
      if entry.spec.live_reload then
        parts[#parts + 1] = icons.prefix("reload") .. "live reload"
      else
        parts[#parts + 1] = "no live reload"
      end
      if not entry.available then
        parts[#parts + 1] = "NOT INSTALLED — " .. entry.spec.install
      end
      return table.concat(parts, "  ·  ")
    end,
  }, function(choice)
    if not choice then
      return callback(nil)
    end
    if not choice.available then
      log.notify(("%s is not installed. %s"):format(choice.spec.display, choice.spec.install), "warn")
      return callback(nil)
    end
    callback(choice.name)
  end)
end

--- Pick one of the known servers.
---@param servers live_server.Server[]
---@param opts? { prompt?: string }
---@param callback fun(server: live_server.Server?)
function M.server(servers, opts, callback)
  opts = opts or {}
  if #servers == 0 then
    log.notify("No servers to choose from.", "warn")
    return callback(nil)
  end
  if #servers == 1 then
    return callback(servers[1])
  end
  vim.ui.select(servers, {
    prompt = opts.prompt or "Server:",
    format_item = function(server)
      return ("%s  %s  :%d  %s"):format(server.project.name, server.adapter.display, server.port, server.status)
    end,
  }, callback)
end

--- Yes/no confirmation.
---@param message string
---@param opts? { yes?: string, no?: string, default_no?: boolean }
---@param callback fun(confirmed: boolean)
function M.confirm(message, opts, callback)
  opts = opts or {}
  local yes = opts.yes or "Yes"
  local no = opts.no or "No"
  local choices = opts.default_no == false and { yes, no } or { no, yes }
  vim.ui.select(choices, { prompt = message }, function(choice)
    callback(choice == yes)
  end)
end

--- Ask for a directory inside the project, with completion.
---@param opts { default?: string, prompt?: string }
---@param callback fun(dir: string?)
function M.directory(opts, callback)
  vim.ui.input({
    prompt = opts.prompt or "Directory: ",
    default = opts.default,
    completion = "dir",
  }, function(input)
    if input == nil or vim.trim(input) == "" then
      return callback(nil)
    end
    callback(vim.trim(input))
  end)
end

return M
