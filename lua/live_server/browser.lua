---@mod live_server.browser Opening URLs, on whatever machine the user is on
---
--- Ordinary local session: hand the URL to the desktop. Remote session: don't
--- pretend — `remote.announce()` gives the user something they can act on.

local log = require("live_server.log")
local remote = require("live_server.remote")
local util = require("live_server.util")

local M = {}

--- Platform command for opening a URL, when `vim.ui.open` is unavailable.
---@return string[]?
local function fallback_opener()
  if util.is_mac then
    return { "open" }
  end
  if util.is_windows then
    return { "cmd.exe", "/c", "start", "" }
  end
  if util.is_wsl then
    for _, candidate in ipairs({ "wslview", "explorer.exe" }) do
      if util.executable(candidate) then
        return { candidate }
      end
    end
  end
  for _, candidate in ipairs({ "xdg-open", "gio", "gnome-open", "kde-open" }) do
    if util.executable(candidate) then
      return candidate == "gio" and { "gio", "open" } or { candidate }
    end
  end
  return nil
end

--- Reject anything that is not an http(s) URL we built ourselves. Cheap
--- insurance against a project file or a crafted path turning "open the
--- preview" into "open this".
---@param url string
---@return boolean
local function is_safe_url(url)
  return url:match("^https?://[%w%.%-%[%]]+:%d+/") ~= nil or url:match("^https?://[%w%.%-%[%]]+/") ~= nil
end

--- Open a URL with the platform's default handler.
---@param url string
---@return boolean ok
---@return string? err
function M.open_url(url)
  if not is_safe_url(url) then
    return false, "refusing to open a URL that is not a local http address: " .. url
  end

  local cfg = require("live_server.config").get()

  ---@type string[]?
  local argv
  if cfg.browser.cmd then
    argv = type(cfg.browser.cmd) == "table" and vim.deepcopy(cfg.browser.cmd) or { cfg.browser.cmd }
  end

  if not argv and vim.ui.open then
    local ok, result = pcall(vim.ui.open, url)
    if ok and result ~= nil then
      return true, nil
    end
    -- `vim.ui.open` reports "no handler" by returning nil plus a message; fall
    -- through to our own detection rather than failing outright.
  end

  argv = argv or fallback_opener()
  if not argv then
    return false, "no way to open a browser was found (set `browser.cmd`)"
  end

  argv = vim.deepcopy(argv)
  argv[#argv + 1] = url

  local ok, job = pcall(vim.fn.jobstart, argv, {
    detach = true,
    on_stderr = function(_, data)
      local text = vim.trim(table.concat(data or {}, " "))
      if text ~= "" then
        log.debug("browser opener stderr", { text = text })
      end
    end,
  })
  if not ok or type(job) ~= "number" or job <= 0 then
    return false, ("could not run %s"):format(argv[1])
  end
  return true, nil
end

--- Open the page for a server: the current buffer's page when it maps to one,
--- otherwise the site root.
---@param server live_server.Server
---@param path? string
function M.open(server, path)
  if not server:is_active() then
    log.notify(("%s is not running."):format(server.adapter.display), "warn")
    return
  end

  if remote.is_remote() then
    remote.announce(server)
    return
  end

  local url = server:url(path)
  local ok, err = M.open_url(url)
  if ok then
    log.info("opened browser", { url = url })
  else
    -- Still useful: show the URL so the user can copy it by hand.
    log.notify(("%s\n%s"):format(err or "could not open a browser", url), "warn")
  end
end

return M
