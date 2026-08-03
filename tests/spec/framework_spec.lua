local t = require("harness")
local framework = require("live_server.framework")
local util = require("live_server.util")

---@param package_json string
---@param files? string[] extra empty files to create (lockfiles)
---@return string root
local function project(package_json, files)
  local root = util.normalize(vim.fn.tempname())
  vim.fn.mkdir(root, "p")
  util.write_file(root .. "/package.json", package_json)
  for _, name in ipairs(files or {}) do
    util.write_file(root .. "/" .. name, "")
  end
  framework.invalidate()
  return root
end

---@param argv string[]
---@param flag string
---@return string?
local function value_of(argv, flag)
  for index, arg in ipairs(argv) do
    if arg == flag then
      return argv[index + 1]
    end
  end
  return nil
end

---@param root string
---@param opts? table
---@return string[] argv
---@return table env
local function command_for(root, opts)
  local detected = assert(framework.detect(root), "expected a framework in " .. root)
  return framework.command(
    detected,
    vim.tbl_extend("force", { host = "127.0.0.1", port = 3000, extra = {} }, opts or {})
  )
end

t.describe("framework detection", function()
  t.it("recognises Next.js and uses its flag names", function()
    local root = project('{"dependencies":{"next":"14"},"scripts":{"dev":"next dev"}}')
    local detected = framework.detect(root)
    t.eq(detected.name, "nextjs")
    t.eq(detected.script, "dev")
    t.eq(detected.port_style, "flag")
    t.truthy(detected.live_reload)

    local argv = command_for(root)
    t.eq(value_of(argv, "--port"), "3000")
    t.eq(value_of(argv, "--hostname"), "127.0.0.1", "Next.js spells it --hostname, not --host")
  end)

  t.it("recognises Vite and pins the port", function()
    local root = project('{"devDependencies":{"vite":"5"},"scripts":{"dev":"vite"}}')
    t.eq(framework.detect(root).name, "vite")
    local argv = command_for(root)
    t.eq(value_of(argv, "--port"), "3000")
    t.eq(value_of(argv, "--host"), "127.0.0.1")
    t.includes(argv, "--strictPort", "without this Vite silently moves and our URL becomes wrong")
  end)

  t.it("prefers the meta-framework over the bundler it is built on", function()
    -- SvelteKit and Astro both depend on Vite. Matching Vite first would give
    -- the right flags by luck and the wrong name always.
    local kit = project('{"devDependencies":{"@sveltejs/kit":"2","vite":"5"},"scripts":{"dev":"vite dev"}}')
    t.eq(framework.detect(kit).name, "sveltekit")

    local astro = project('{"dependencies":{"astro":"4","vite":"5"},"scripts":{"dev":"astro dev"}}')
    t.eq(framework.detect(astro).name, "astro")
  end)

  t.it("uses the environment for servers with no port flag", function()
    local root = project('{"dependencies":{"express":"4"},"scripts":{"dev":"node server.js"}}')
    local detected = framework.detect(root)
    t.eq(detected.port_style, "env")
    t.falsy(detected.live_reload, "a bare Express app has no HMR and must not claim to")

    local argv, env = command_for(root)
    t.eq(env.PORT, "3000")
    t.eq(env.HOST, "127.0.0.1")
    t.falsy(vim.tbl_contains(argv, "--port"), "an unknown flag would just crash the script")
  end)

  t.it("always sets PORT, even for flag-driven frameworks", function()
    -- Frameworks read PORT from config files too, and it costs nothing.
    local _, env = command_for(project('{"dependencies":{"next":"14"},"scripts":{"dev":"next dev"}}'))
    t.eq(env.PORT, "3000")
  end)

  t.it("stops the framework opening its own browser tab", function()
    local _, env = command_for(project('{"devDependencies":{"vite":"5"},"scripts":{"dev":"vite"}}'))
    t.eq(env.BROWSER, "none")
  end)

  t.it("picks the framework's own script name", function()
    local gatsby = project('{"dependencies":{"gatsby":"5"},"scripts":{"develop":"gatsby develop","start":"x"}}')
    t.eq(framework.detect(gatsby).script, "develop")

    local nest =
      project('{"dependencies":{"@nestjs/core":"10"},"scripts":{"start:dev":"nest start --watch","start":"x"}}')
    t.eq(framework.detect(nest).script, "start:dev")

    local cra = project('{"dependencies":{"react-scripts":"5"},"scripts":{"start":"react-scripts start"}}')
    t.eq(framework.detect(cra).script, "start")
  end)

  t.it("falls back to a generic npm script", function()
    local root = project('{"scripts":{"dev":"node index.js"}}')
    local detected = framework.detect(root)
    t.eq(detected.name, "node")
    t.eq(detected.port_style, "env", "we cannot guess flags for an unknown script")
  end)

  t.it("declines a package.json with nothing to run", function()
    local detected, reason = framework.detect(project('{"name":"lib","version":"1.0.0"}'))
    t.eq(detected, nil)
    t.contains(reason, "script")
  end)

  t.it("declines a directory with no package.json", function()
    local root = util.normalize(vim.fn.tempname())
    vim.fn.mkdir(root, "p")
    framework.invalidate()
    local detected, reason = framework.detect(root)
    t.eq(detected, nil)
    t.contains(reason, "package.json")
  end)

  t.it("survives a malformed package.json", function()
    local root = util.normalize(vim.fn.tempname())
    vim.fn.mkdir(root, "p")
    util.write_file(root .. "/package.json", "{ not json")
    framework.invalidate()
    t.eq(framework.detect(root), nil)
  end)
end)

t.describe("package manager detection", function()
  --- Lockfile detection only accepts an installed manager, so the assertions
  --- have to be independent of what happens to be on this machine.
  ---@param fn fun()
  local function with_all_installed(fn)
    local saved = util.executable
    util.executable = function()
      return true
    end
    local ok, err = pcall(fn)
    util.executable = saved
    if not ok then
      error(err, 0)
    end
  end

  t.it("reads the lockfile", function()
    with_all_installed(function()
      local cases = {
        { "pnpm-lock.yaml", "pnpm" },
        { "yarn.lock", "yarn" },
        { "package-lock.json", "npm" },
        { "bun.lockb", "bun" },
      }
      for _, case in ipairs(cases) do
        local root = project('{"scripts":{"dev":"vite"}}', { case[1] })
        t.eq(framework.package_manager(root).name, case[2], case[1] .. " should mean " .. case[2])
      end
    end)
  end)

  t.it("separates script arguments only where the manager needs it", function()
    with_all_installed(function()
      local npm = project('{"devDependencies":{"vite":"5"},"scripts":{"dev":"vite"}}', { "package-lock.json" })
      t.includes(command_for(npm), "--", "npm swallows arguments without a separator")

      local pnpm = project('{"devDependencies":{"vite":"5"},"scripts":{"dev":"vite"}}', { "pnpm-lock.yaml" })
      t.falsy(vim.tbl_contains(command_for(pnpm), "--"), "pnpm passes arguments through directly")
    end)
  end)

  t.it("honours the packageManager field when there is no lockfile", function()
    with_all_installed(function()
      local root = project('{"packageManager":"pnpm@9.0.0","scripts":{"dev":"vite"}}')
      t.eq(framework.package_manager(root).name, "pnpm")
    end)
  end)

  t.it("falls back to npm when the named manager is missing", function()
    -- `npm run` executes the script whatever installed node_modules, so this
    -- degrades usefully instead of failing.
    local saved = util.executable
    util.executable = function(name)
      return name == "npm"
    end
    local root = project('{"scripts":{"dev":"vite"}}', { "pnpm-lock.yaml" })
    t.eq(framework.package_manager(root).name, "npm")
    util.executable = saved
  end)

  t.it("defaults to npm with no signal at all", function()
    t.eq(framework.package_manager(project('{"scripts":{"dev":"x"}}')).name, "npm")
  end)
end)

t.describe("framework caching", function()
  t.it("re-reads package.json after it changes", function()
    local root = project('{"devDependencies":{"vite":"5"},"scripts":{"dev":"vite"}}')
    t.eq(framework.detect(root).name, "vite")

    -- Same mtime second would mask the change; make the difference explicit.
    util.write_file(root .. "/package.json", '{"dependencies":{"next":"14"},"scripts":{"dev":"next dev"}}')
    framework.invalidate()
    t.eq(framework.detect(root).name, "nextjs")
  end)
end)

t.describe("auto-selection scope", function()
  local adapters = require("live_server.adapters")
  local project_mod = require("live_server.project")

  ---@param package_json string
  ---@return live_server.Project
  local function node_project(package_json)
    local root = project(package_json)
    util.write_file(root .. "/.git/HEAD", "ref: refs/heads/main")
    project_mod.invalidate()
    return project_mod.get(root)
  end

  t.it("volunteers for a recognised framework", function()
    local p = node_project('{"dependencies":{"next":"14"},"scripts":{"dev":"next dev"}}')
    t.truthy(adapters.suits_project("node", p))
  end)

  t.it("stays out of a project with only an unrecognised script", function()
    -- `"start": "node build.js"` is a build step, not a web server. Running it
    -- because `auto` guessed would be an unpleasant surprise.
    local p = node_project('{"scripts":{"start":"node build.js"}}')
    local suits, reason = adapters.suits_project("node", p)
    t.falsy(suits)
    t.contains(reason, "recognised")
  end)

  t.it("runs the unrecognised script when asked explicitly", function()
    local p = node_project('{"scripts":{"start":"node build.js"}}')
    t.truthy(adapters.suits_project("node", p, { explicit = true }))
  end)

  t.it("stays out of a project with no package.json", function()
    local root = util.normalize(vim.fn.tempname())
    vim.fn.mkdir(root, "p")
    util.write_file(root .. "/index.html", "<h1>hi</h1>")
    util.write_file(root .. "/.git/HEAD", "ref: refs/heads/main")
    framework.invalidate()
    project_mod.invalidate()
    t.falsy(adapters.suits_project("node", project_mod.get(root)))
  end)
end)

t.describe("realtime servers", function()
  t.it("recognises a socket-only server", function()
    local root = project('{"dependencies":{"socket.io":"4"},"scripts":{"start":"node socket.js"}}')
    local detected = framework.detect(root)
    t.eq(detected.name, "socket_server")
    t.truthy(detected.realtime, "there is no page to open at a socket endpoint")
    t.falsy(detected.live_reload)
    t.eq(detected.port_style, "env")
  end)

  t.it("recognises a bare ws server", function()
    t.eq(framework.detect(project('{"dependencies":{"ws":"8"},"scripts":{"start":"node s.js"}}')).name, "socket_server")
  end)

  t.it("calls an Express app with sockets an HTTP server", function()
    -- It serves routes as well as sockets, so it does have pages.
    local root = project('{"dependencies":{"express":"4","socket.io":"4"},"scripts":{"start":"node server.js"}}')
    local detected = framework.detect(root)
    t.eq(detected.name, "node_server")
    t.falsy(detected.realtime)
  end)

  t.it("does not mistake a Next.js frontend that depends on ws", function()
    -- MyFaithPal's frontend has both; `next` must win.
    local root = project('{"dependencies":{"next":"14","ws":"8"},"scripts":{"dev":"next dev"}}')
    t.eq(framework.detect(root).name, "nextjs")
    t.falsy(framework.detect(root).realtime)
  end)
end)
