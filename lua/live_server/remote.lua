---@mod live_server.remote Working over SSH
---
--- Editing on a remote box is the case where a naive live server plugin quietly
--- fails: the server binds loopback *on the remote machine*, `xdg-open` either
--- is not installed or opens a browser nobody can see, and the URL that gets
--- printed is unreachable from the laptop in front of you.
---
--- So when a session is remote the plugin stops pretending: it gives you the
--- exact `ssh -L` command to run, puts the URL on your local clipboard through
--- OSC 52, and never launches a browser into the void.

local log = require("live_server.log")
local util = require("live_server.util")

local M = {}

---@class live_server.RemoteInfo
---@field remote boolean
---@field user string
---@field host string hostname of the machine Neovim runs on
---@field client_ip string? address the SSH client connected from
---@field port integer? SSH port in use

---@type live_server.RemoteInfo?
local cached = nil

--- Details of the current SSH session, if any.
---@return live_server.RemoteInfo
function M.info()
  if cached then
    return cached
  end

  local cfg = require("live_server.config").get()
  local connection = vim.env.SSH_CONNECTION or vim.env.SSH_CLIENT
  local remote = cfg.remote.detect and (connection ~= nil or vim.env.SSH_TTY ~= nil)

  local client_ip, ssh_port
  if connection then
    -- SSH_CONNECTION is "<client ip> <client port> <server ip> <server port>"
    local parts = vim.split(vim.trim(connection), "%s+")
    client_ip = parts[1]
    ssh_port = tonumber(parts[4])
  end

  cached = {
    remote = remote == true,
    user = vim.env.USER or vim.env.USERNAME or "user",
    host = util.uv.os_gethostname() or "remote-host",
    client_ip = client_ip,
    port = ssh_port,
  }
  return cached
end

---@return boolean
function M.is_remote()
  return M.info().remote
end

--- Re-read the environment, e.g. after `setup()` changes `remote.detect`.
function M.invalidate()
  cached = nil
end

--- The command to run **on the local machine** to reach a remote server.
---@param server live_server.Server
---@return string
function M.forward_command(server)
  local info = M.info()
  local target = info.user .. "@" .. info.host
  local port_flag = (info.port and info.port ~= 22) and (" -p " .. info.port) or ""
  return ("ssh%s -N -L %d:127.0.0.1:%d %s"):format(port_flag, server.port, server.port, target)
end

---@param server live_server.Server
---@return string
function M.local_url(server)
  return ("http://127.0.0.1:%d/%s"):format(server.port, (server.open_path or ""):gsub("^/+", ""))
end

--- Copy text to the user's clipboard, falling back to OSC 52 so it lands on the
--- *local* machine even when the remote box has no clipboard tool.
---@param text string
---@return boolean copied
---@return string method
function M.copy(text)
  -- A configured provider (including a user's own OSC 52 setup) wins.
  local has_provider = vim.fn.has("clipboard") == 1 or vim.g.clipboard ~= nil
  if has_provider then
    local ok = pcall(vim.fn.setreg, "+", text)
    if ok then
      return true, "clipboard"
    end
  end

  local ok, osc52 = pcall(require, "vim.ui.clipboard.osc52")
  if ok and type(osc52) == "table" and type(osc52.copy) == "function" then
    local copier = osc52.copy("+")
    if type(copier) == "function" then
      local sent = pcall(copier, vim.split(text, "\n", { plain = true }))
      if sent then
        return true, "OSC 52"
      end
    end
  end

  -- Last resort: emit the escape sequence ourselves.
  local encoded = vim.base64 and vim.base64.encode(text) or nil
  if encoded then
    local sequence = "\027]52;c;" .. encoded .. "\027\\"
    local sent = pcall(vim.fn.chansend, vim.v.stderr, sequence)
    if sent then
      return true, "OSC 52"
    end
  end

  pcall(vim.fn.setreg, '"', text)
  return false, "unnamed register"
end

--- Tell the user how to actually reach a server that is running remotely.
---@param server live_server.Server
function M.announce(server)
  local cfg = require("live_server.config").get()
  if not M.is_remote() then
    return
  end

  local url = M.local_url(server)
  local lines = { ("Serving %s at %s (on %s)"):format(server.project.name, url, M.info().host) }

  if cfg.remote.forward_hint then
    lines[#lines + 1] = ""
    lines[#lines + 1] = "Forward it from your machine:"
    lines[#lines + 1] = "  " .. M.forward_command(server)
  end

  if cfg.remote.copy_url then
    local copied, method = M.copy(url)
    if copied then
      lines[#lines + 1] = ""
      lines[#lines + 1] = ("URL copied to your clipboard via %s."):format(method)
    end
  end

  log.notify(table.concat(lines, "\n"), "info")
end

return M
