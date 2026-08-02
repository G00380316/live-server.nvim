---@mod live_server.adapters.browser_sync The `browser-sync` npm package
---
--- Heavier than live-server, but it synchronises scroll position, clicks and
--- form input across every connected device — the reason to reach for it when
--- testing a layout on a phone and a laptop at the same time.

---@type live_server.AdapterSpec
return {
  name = "browser_sync",
  display = "browser-sync",
  bin = "browser-sync",
  install = "npm install -g browser-sync",
  live_reload = true,
  supports = {
    host = true,
    entry_file = true,
    ignore = true,
    delay = true,
    device_sync = true,
  },

  ---@param ctx live_server.SpawnContext
  ---@return string[]
  build = function(ctx)
    local argv = {
      "browser-sync",
      "start",
      "--server",
      ctx.serve_dir,
      "--port",
      tostring(ctx.port),
      "--host",
      ctx.host,
      "--no-open",
      "--no-notify",
      -- The web UI silently claims port+1. Disabling it keeps port accounting
      -- honest: one server, one port, exactly what the dashboard reports.
      "--no-ui",
      "--reload-delay",
      tostring(ctx.delay),
    }

    if #ctx.extensions > 0 then
      local globs = {}
      for _, ext in ipairs(ctx.extensions) do
        globs[#globs + 1] = "**/*." .. ext
      end
      argv[#argv + 1] = "--files"
      argv[#argv + 1] = table.concat(globs, ",")
    end

    for _, pattern in ipairs(ctx.ignore) do
      argv[#argv + 1] = "--ignore"
      argv[#argv + 1] = pattern
    end

    if ctx.entry_file then
      argv[#argv + 1] = "--single"
    end

    for _, arg in ipairs(ctx.extra) do
      argv[#argv + 1] = arg
    end

    return argv
  end,
}
