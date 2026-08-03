---@mod live_server.framework Detecting Node projects and how to run them
---
--- A static site is served by a tool you install once. A Next.js, Vite or
--- Express app is started by the project itself — through its own script, its
--- own package manager, and its own idea of how a port is chosen. This module
--- works out those three things so the `node` adapter can build a command that
--- matches what the team actually set up.
---
--- Nothing here executes anything; it only reads `package.json` and looks for
--- lockfiles. Deciding whether to *run* what it finds is
--- `live_server.trust`'s job.

local log = require("live_server.log")
local util = require("live_server.util")

local M = {}

---@class live_server.Framework
---@field name string stable identifier
---@field display string human label
---@field script string package.json script to run
---@field script_body string what that script actually runs
---@field port_style "flag"|"env" how the port reaches the process
---@field port_flag string? e.g. `--port`
---@field host_flag string? e.g. `--host`
---@field extra_args string[] flags we always add (e.g. `--strictPort`)
---@field live_reload boolean does it push changes to the browser
---@field ready_timeout integer how long a cold start may take, in ms
---@field package_manager live_server.PackageManager
---@field recognised boolean true when a known framework was identified, false
---       when we only found a script we do not understand

---@class live_server.PackageManager
---@field name string
---@field bin string
---@field run string[] argv prefix, e.g. { "npm", "run" }
---@field separator boolean does it need `--` before script arguments

--- Ordered signatures. The first dependency that matches wins, so anything
--- built *on top of* Vite has to be listed before Vite itself — otherwise a
--- SvelteKit app is misreported as a plain Vite app and gets the wrong flags.
---@type table[]
local SIGNATURES = {
  {
    deps = { "next" },
    name = "nextjs",
    display = "Next.js",
    port_flag = "--port",
    host_flag = "--hostname",
    live_reload = true,
    -- A cold Next.js compile on a large app routinely passes 30 seconds.
    ready_timeout = 120000,
  },
  {
    deps = { "nuxt", "nuxt3" },
    name = "nuxt",
    display = "Nuxt",
    port_flag = "--port",
    host_flag = "--host",
    live_reload = true,
    ready_timeout = 90000,
  },
  {
    deps = { "@remix-run/dev" },
    name = "remix",
    display = "Remix",
    port_flag = "--port",
    host_flag = "--host",
    live_reload = true,
    ready_timeout = 90000,
  },
  {
    deps = { "astro" },
    name = "astro",
    display = "Astro",
    port_flag = "--port",
    host_flag = "--host",
    live_reload = true,
    ready_timeout = 60000,
  },
  {
    deps = { "@sveltejs/kit" },
    name = "sveltekit",
    display = "SvelteKit",
    port_flag = "--port",
    host_flag = "--host",
    extra_args = { "--strictPort" },
    live_reload = true,
    ready_timeout = 60000,
  },
  {
    deps = { "@angular/cli", "@angular-devkit/build-angular" },
    name = "angular",
    display = "Angular",
    script_preference = { "start", "serve", "dev" },
    port_flag = "--port",
    host_flag = "--host",
    live_reload = true,
    ready_timeout = 120000,
  },
  {
    deps = { "gatsby" },
    name = "gatsby",
    display = "Gatsby",
    script_preference = { "develop", "dev", "start" },
    port_flag = "--port",
    host_flag = "--host",
    live_reload = true,
    ready_timeout = 120000,
  },
  {
    deps = { "react-scripts" },
    name = "cra",
    display = "Create React App",
    script_preference = { "start", "dev" },
    -- react-scripts has no port flag; it reads PORT/HOST from the environment.
    port_style = "env",
    live_reload = true,
    ready_timeout = 90000,
  },
  {
    deps = { "@nestjs/core", "@nestjs/cli" },
    name = "nestjs",
    display = "NestJS",
    script_preference = { "start:dev", "dev", "start" },
    port_style = "env",
    live_reload = false,
    ready_timeout = 90000,
  },
  {
    deps = { "@11ty/eleventy" },
    name = "eleventy",
    display = "Eleventy",
    port_flag = "--port",
    live_reload = true,
    ready_timeout = 45000,
  },
  {
    deps = { "parcel" },
    name = "parcel",
    display = "Parcel",
    port_flag = "--port",
    host_flag = "--host",
    live_reload = true,
    ready_timeout = 60000,
  },
  {
    deps = { "webpack-dev-server" },
    name = "webpack",
    display = "webpack-dev-server",
    port_flag = "--port",
    host_flag = "--host",
    live_reload = true,
    ready_timeout = 90000,
  },
  {
    deps = { "vite" },
    name = "vite",
    display = "Vite",
    port_flag = "--port",
    host_flag = "--host",
    -- Without this Vite silently walks to the next free port and our reported
    -- URL becomes a lie.
    extra_args = { "--strictPort" },
    live_reload = true,
    ready_timeout = 45000,
  },
  {
    deps = { "express", "fastify", "koa", "@hapi/hapi", "hapi", "restify", "polka" },
    name = "node_server",
    display = "Node server",
    script_preference = { "dev", "start", "serve" },
    -- No convention beyond `process.env.PORT`.
    port_style = "env",
    live_reload = false,
    ready_timeout = 45000,
  },
}

---@type string[]
local DEFAULT_SCRIPT_PREFERENCE = { "dev", "develop", "serve", "start" }

--- Lockfile to package manager. Checked in order, so a repo with both a
--- `package-lock.json` and a `pnpm-lock.yaml` resolves the same way every time.
---@type table[]
local PACKAGE_MANAGERS = {
  { lockfile = "bun.lockb", name = "bun", bin = "bun", run = { "bun", "run" }, separator = false },
  { lockfile = "bun.lock", name = "bun", bin = "bun", run = { "bun", "run" }, separator = false },
  { lockfile = "pnpm-lock.yaml", name = "pnpm", bin = "pnpm", run = { "pnpm", "run" }, separator = false },
  { lockfile = "yarn.lock", name = "yarn", bin = "yarn", run = { "yarn", "run" }, separator = false },
  { lockfile = "package-lock.json", name = "npm", bin = "npm", run = { "npm", "run" }, separator = true },
}

---@type live_server.PackageManager
local NPM = { name = "npm", bin = "npm", run = { "npm", "run" }, separator = true }

---@type table<string, { data: table?, mtime: integer }>
local package_cache = {}

--- Read and parse `package.json`, cached against its mtime.
---@param root string
---@return table? data
---@return string? path
function M.package_json(root)
  local path = root .. "/package.json"
  local stat = util.uv.fs_stat(path)
  if not stat then
    package_cache[root] = nil
    return nil, nil
  end

  local cached = package_cache[root]
  if cached and cached.mtime == stat.mtime.sec then
    return cached.data, path
  end

  local raw = util.read_file(path)
  local decoded = raw and select(1, util.json_decode(raw)) or nil
  if raw and type(decoded) ~= "table" then
    log.warn("package.json is not valid JSON", { path = path })
    decoded = nil
  end

  package_cache[root] = { data = decoded, mtime = stat.mtime.sec }
  return decoded, path
end

--- Which package manager this project uses, from its lockfile.
---@param root string
---@return live_server.PackageManager
function M.package_manager(root)
  for _, candidate in ipairs(PACKAGE_MANAGERS) do
    if util.is_file(root .. "/" .. candidate.lockfile) then
      -- A lockfile for a manager that is not installed is worse than useless;
      -- npm is the safe fallback since it ships with Node.
      if util.executable(candidate.bin) then
        return candidate
      end
      log.warn("lockfile names a package manager that is not installed", {
        lockfile = candidate.lockfile,
        bin = candidate.bin,
      })
    end
  end

  -- `packageManager: "pnpm@9"` (corepack) when there is no lockfile yet.
  local data = M.package_json(root)
  local declared = type(data) == "table" and type(data.packageManager) == "string" and data.packageManager or nil
  if declared then
    local name = declared:match("^([%w@/%-]+)@") or declared
    for _, candidate in ipairs(PACKAGE_MANAGERS) do
      if candidate.name == name and util.executable(candidate.bin) then
        return candidate
      end
    end
  end

  return NPM
end

---@param data table
---@return table<string, string>
local function all_dependencies(data)
  local out = {}
  for _, field in ipairs({ "dependencies", "devDependencies", "peerDependencies", "optionalDependencies" }) do
    if type(data[field]) == "table" then
      for name, version in pairs(data[field]) do
        out[name] = type(version) == "string" and version or ""
      end
    end
  end
  return out
end

---@param scripts table<string, string>
---@param preference string[]
---@return string? name
---@return string? body
local function pick_script(scripts, preference)
  for _, name in ipairs(preference) do
    if type(scripts[name]) == "string" and vim.trim(scripts[name]) ~= "" then
      return name, scripts[name]
    end
  end
  return nil, nil
end

--- Work out what kind of Node project this is and how to start it.
---@param root string project root
---@return live_server.Framework? framework
---@return string? reason why nothing was detected
function M.detect(root)
  local data, path = M.package_json(root)
  if not data then
    return nil, "no package.json"
  end

  local scripts = type(data.scripts) == "table" and data.scripts or {}
  local dependencies = all_dependencies(data)

  ---@type table?
  local signature
  for _, candidate in ipairs(SIGNATURES) do
    for _, dep in ipairs(candidate.deps) do
      if dependencies[dep] ~= nil then
        signature = candidate
        break
      end
    end
    if signature then
      break
    end
  end

  local preference = signature and signature.script_preference or DEFAULT_SCRIPT_PREFERENCE
  local script, body = pick_script(scripts, preference)
  if not script then
    script, body = pick_script(scripts, DEFAULT_SCRIPT_PREFERENCE)
  end

  if not script then
    return nil, "package.json has no dev/start script"
  end

  if not signature then
    -- A Node project we do not recognise still deserves to run. `PORT` is the
    -- one convention nearly everything honours, and passing an unknown flag to
    -- an unknown script would be worse than passing none.
    return {
      name = "node",
      display = "npm script",
      script = script,
      script_body = body or "",
      port_style = "env",
      extra_args = {},
      live_reload = false,
      ready_timeout = 45000,
      package_manager = M.package_manager(root),
      package_json = path,
      recognised = false,
    }
  end

  return {
    name = signature.name,
    display = signature.display,
    script = script,
    script_body = body or "",
    port_style = signature.port_style or "flag",
    port_flag = signature.port_flag,
    host_flag = signature.host_flag,
    extra_args = vim.deepcopy(signature.extra_args or {}),
    live_reload = signature.live_reload == true,
    ready_timeout = signature.ready_timeout or 60000,
    package_manager = M.package_manager(root),
    package_json = path,
    recognised = true,
  }
end

--- Build the argv and environment for a framework's dev server.
---@param framework live_server.Framework
---@param opts { host: string, port: integer, extra: string[] }
---@return string[] argv
---@return table<string, string> env
function M.command(framework, opts)
  local manager = framework.package_manager
  local argv = vim.deepcopy(manager.run)
  argv[#argv + 1] = framework.script

  ---@type string[]
  local args = {}
  if framework.port_style == "flag" and framework.port_flag then
    args[#args + 1] = framework.port_flag
    args[#args + 1] = tostring(opts.port)
    if framework.host_flag then
      args[#args + 1] = framework.host_flag
      args[#args + 1] = opts.host
    end
    vim.list_extend(args, framework.extra_args)
  end
  vim.list_extend(args, opts.extra or {})

  if #args > 0 then
    -- npm swallows everything after the script name unless separated.
    if manager.separator then
      argv[#argv + 1] = "--"
    end
    vim.list_extend(argv, args)
  end

  ---@type table<string, string>
  local env = {
    -- Set unconditionally: even flag-driven frameworks read PORT in their
    -- config files, and an Express app that ignores our flags still honours it.
    PORT = tostring(opts.port),
    HOST = opts.host,
    HOSTNAME = opts.host,
    -- Stop the framework opening its own browser tab before the port answers.
    BROWSER = "none",
  }

  return argv, env
end

--- Human summary of what starting this project would run, for the consent
--- prompt. The user should be able to read this and know exactly what happens.
---@param framework live_server.Framework
---@return string[]
function M.describe(framework)
  return {
    ("  script:  %s = %s"):format(framework.script, framework.script_body),
    ("  via:     %s"):format(framework.package_manager.name),
  }
end

--- Drop cached `package.json` reads.
function M.invalidate()
  package_cache = {}
end

return M
