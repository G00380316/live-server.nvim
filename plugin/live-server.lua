-- live-server.nvim command stubs.
--
-- This file runs at startup, so it deliberately requires nothing. It registers
-- placeholder commands that pull the plugin in on first use, which keeps the
-- startup cost at "read one small file" whether or not the user ever touches a
-- dev server. Calling `require("live_server").setup()` replaces these with the
-- real definitions.

if vim.g.loaded_live_server == 1 then
  return
end
vim.g.loaded_live_server = 1

if vim.fn.has("nvim-0.9") == 0 then
  vim.notify_once("live-server.nvim requires Neovim 0.9 or newer", vim.log.levels.ERROR)
  return
end

---@type boolean
local bootstrapped = false

--- Load and configure the plugin exactly once.
local function bootstrap()
  if bootstrapped then
    return
  end
  bootstrapped = true
  require("live_server").setup(vim.g.live_server or {})
end

vim.api.nvim_create_user_command("LiveServer", function(cmd)
  bootstrap()
  require("live_server.commands").dispatch(cmd.fargs)
end, {
  nargs = "*",
  desc = "Manage development servers",
  complete = function(lead, line, pos)
    bootstrap()
    return require("live_server.commands").complete(lead, line, pos)
  end,
})

-- Pre-1.0 command names. Registered as stubs so existing muscle memory and
-- keymaps keep working; `setup()` swaps in the real implementations.
for name, subcommand in pairs({
  LiveServerToggle = "toggle live_server",
  LiveServerStart = "start live_server",
  LiveServerStop = "stop all",
  BrowserSyncToggle = "toggle browser_sync",
  LiveServerList = "dashboard",
  LiveServerPrompt = "start live_server",
  BrowserSyncPrompt = "start browser_sync",
  LiveServerOpen = "open",
  BrowserSyncOpen = "open",
}) do
  vim.api.nvim_create_user_command(name, function(cmd)
    bootstrap()
    local fargs = vim.split(subcommand, " ", { plain = true })
    vim.list_extend(fargs, cmd.fargs)
    require("live_server.commands").dispatch(fargs)
  end, { nargs = "?", desc = ("Deprecated: use `:LiveServer %s`"):format(subcommand) })
end
