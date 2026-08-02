---@mod live_server.adapters.serve Vercel's `serve`, run through npx
---
--- No live reload, but it is the closest local approximation of static hosting
--- (clean URLs, correct MIME types, SPA rewrites), which makes it the right
--- choice for checking a build output before it ships.

local util = require("live_server.util")

---@type live_server.AdapterSpec
return {
  name = "serve",
  display = "serve",
  bin = "serve",
  install = "npm install -g serve  (or rely on npx)",
  live_reload = false,
  supports = {
    host = true,
    entry_file = true,
    ignore = false,
    delay = false,
    production_like = true,
  },

  --- Usable either as a global binary or via npx, so treat npx as sufficient.
  detect = function()
    return util.executable("serve") or util.executable("npx")
  end,

  version_args = { "--version" },

  ---@param ctx live_server.SpawnContext
  ---@return string[]
  build = function(ctx)
    local argv
    if util.executable("serve") then
      argv = { "serve" }
    else
      -- `--yes` so a first run never blocks on an install prompt that nobody
      -- can see: the job has no tty attached.
      argv = { "npx", "--yes", "serve" }
    end

    vim.list_extend(argv, {
      "--listen",
      ("tcp://%s:%d"):format(ctx.host, ctx.port),
      "--no-clipboard",
    })

    if ctx.entry_file then
      argv[#argv + 1] = "--single"
    end

    for _, arg in ipairs(ctx.extra) do
      argv[#argv + 1] = arg
    end

    argv[#argv + 1] = ctx.serve_dir
    return argv
  end,
}
