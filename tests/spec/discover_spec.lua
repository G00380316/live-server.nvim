local t = require("harness")
local config = require("live_server.config")
local discover = require("live_server.discover")
local framework = require("live_server.framework")
local project_mod = require("live_server.project")
local util = require("live_server.util")

--- Build a repository tree. Keys are paths, values are file contents; a value
--- of `true` makes a directory.
---@param tree table<string, string|boolean>
---@return string root
local function repo(tree)
  local root = util.normalize(vim.fn.tempname())
  vim.fn.mkdir(root .. "/.git", "p")
  util.write_file(root .. "/.git/HEAD", "ref: refs/heads/main")
  for path, contents in pairs(tree) do
    local full = root .. "/" .. path
    if contents == true then
      vim.fn.mkdir(full, "p")
    else
      vim.fn.mkdir(vim.fs.dirname(full), "p")
      util.write_file(full, contents)
    end
  end
  discover.invalidate()
  framework.invalidate()
  project_mod.invalidate()
  return root
end

local NEXT = '{"name":"app","dependencies":{"next":"14"},"scripts":{"dev":"next dev"}}'
local VITE = '{"name":"web","devDependencies":{"vite":"5"},"scripts":{"dev":"vite"}}'
local EXPRESS = '{"name":"api","dependencies":{"express":"4"},"scripts":{"dev":"node index.js"}}'

---@param root string
---@return string[] relative paths of candidates
local function relatives(root)
  local out = {}
  for _, candidate in ipairs(discover.candidates(root, { refresh = true })) do
    out[#out + 1] = candidate.relative == "" and "." or candidate.relative
  end
  return out
end

local function reset()
  config.did_setup = false
  config.setup({})
  discover.invalidate()
  framework.invalidate()
  project_mod.invalidate()
end

t.describe("discovery", function()
  t.it("finds an app one level below the repository root", function()
    -- The layout this exists for: the editor pins the root to the git
    -- directory, and the actual project sits inside it.
    reset()
    local root = repo({ ["README.md"] = "# repo", ["my-app/package.json"] = NEXT })
    t.eq(relatives(root), { "my-app" })
    t.eq(discover.candidates(root)[1].label, "Next.js")
  end)

  t.it("finds several apps", function()
    reset()
    local root = repo({ ["frontend/package.json"] = VITE, ["api/package.json"] = EXPRESS })
    local found = relatives(root)
    t.eq(#found, 2)
    t.includes(found, "frontend")
    t.includes(found, "api")
  end)

  t.it("finds a static site below the root", function()
    reset()
    local root = repo({ ["site/index.html"] = "<h1>hi</h1>" })
    t.eq(relatives(root), { "site" })
    t.eq(discover.candidates(root)[1].kind, "static")
  end)

  t.it("stops at the root when the root itself is runnable", function()
    -- A monorepo root with `dev: turbo run dev` means what it says; walking
    -- past it to a member package would ignore the author's intent.
    reset()
    local root = repo({
      ["package.json"] = '{"name":"mono","workspaces":["apps/*"],"scripts":{"dev":"turbo run dev"}}',
      ["apps/web/package.json"] = NEXT,
    })
    t.eq(relatives(root), { "." })
  end)

  t.it("prefers declared workspaces over walking the tree", function()
    reset()
    local root = repo({
      ["package.json"] = '{"name":"mono","private":true,"workspaces":["packages/*"]}',
      ["packages/web/package.json"] = VITE,
      ["packages/api/package.json"] = EXPRESS,
      -- Not a workspace member: must not appear.
      ["scratch/throwaway/package.json"] = NEXT,
    })
    local found = relatives(root)
    t.eq(#found, 2)
    t.includes(found, "packages/web")
    t.includes(found, "packages/api")
    t.falsy(vim.tbl_contains(found, "scratch/throwaway"))
  end)

  t.it("reads pnpm-workspace.yaml", function()
    reset()
    local root = repo({
      ["package.json"] = '{"name":"mono","private":true}',
      ["pnpm-workspace.yaml"] = "packages:\n  - 'packages/*'\n  - \"tools/*\"\n",
      ["packages/web/package.json"] = VITE,
      ["tools/cli/package.json"] = EXPRESS,
    })
    local found = relatives(root)
    t.includes(found, "packages/web")
    t.includes(found, "tools/cli")
  end)

  t.it("stops reading the pnpm list at the next top-level key", function()
    reset()
    local root = repo({
      ["package.json"] = '{"name":"mono","private":true}',
      ["pnpm-workspace.yaml"] = "packages:\n  - 'packages/*'\nonlyBuiltDependencies:\n  - esbuild\n",
      ["packages/web/package.json"] = VITE,
    })
    t.eq(relatives(root), { "packages/web" })
  end)

  t.it("never descends into node_modules", function()
    reset()
    local root = repo({
      ["app/package.json"] = VITE,
      ["node_modules/react/package.json"] = '{"name":"react","scripts":{"dev":"x"}}',
      ["node_modules/next/index.html"] = "<h1>no</h1>",
    })
    local found = relatives(root)
    t.eq(found, { "app" })
  end)

  t.it("skips hidden and build directories", function()
    reset()
    local root = repo({
      ["app/package.json"] = VITE,
      [".next/index.html"] = "<h1>build output</h1>",
      [".venv/lib/index.html"] = "<h1>no</h1>",
      ["coverage/index.html"] = "<h1>report</h1>",
    })
    t.eq(relatives(root), { "app" })
  end)

  t.it("respects the depth limit", function()
    reset()
    config.did_setup = false
    config.setup({ discover = { depth = 1 } })
    local root = repo({ ["a/b/c/package.json"] = VITE })
    t.eq(relatives(root), {})

    config.did_setup = false
    config.setup({ discover = { depth = 3 } })
    discover.invalidate()
    t.eq(relatives(root), { "a/b/c" })
    reset()
  end)

  t.it("can be turned off", function()
    reset()
    config.did_setup = false
    config.setup({ discover = { enabled = false } })
    local root = repo({ ["app/package.json"] = VITE })
    t.eq(relatives(root), {})
    reset()
  end)

  t.it("orders shallow apps before deep ones and apps before static", function()
    reset()
    local root = repo({
      ["deep/nested/app/package.json"] = VITE,
      ["site/index.html"] = "<h1>hi</h1>",
      ["api/package.json"] = EXPRESS,
    })
    local found = relatives(root)
    t.eq(found[1], "api", "a runnable app at depth 1 should come first")
    t.includes(found, "site")
    t.includes(found, "deep/nested/app")
  end)

  t.it("returns nothing for an empty repository", function()
    reset()
    t.eq(relatives(repo({ ["README.md"] = "# nothing here" })), {})
  end)
end)

t.describe("discovery target resolution", function()
  ---@param root string
  ---@param opts table
  ---@return string?
  local function resolve(root, opts)
    local project = project_mod.get(root)
    local result = nil
    local done = false
    discover.resolve(project, opts or {}, function(dir)
      result, done = dir, true
    end)
    vim.wait(2000, function()
      return done
    end, 10)
    return result
  end

  t.it("targets the single app automatically", function()
    reset()
    local root = repo({ ["my-app/package.json"] = NEXT })
    t.eq(resolve(root, {}), root .. "/my-app")
  end)

  t.it("uses the root when nothing is found", function()
    reset()
    local root = repo({ ["README.md"] = "# nothing" })
    t.eq(resolve(root, {}), root)
  end)

  t.it("honours an explicit directory over everything", function()
    reset()
    local root = repo({ ["frontend/package.json"] = VITE, ["api/package.json"] = EXPRESS })
    t.eq(resolve(root, { dir = root .. "/api" }), root .. "/api")
  end)

  t.it("picks the app containing the current buffer", function()
    reset()
    local root =
      repo({ ["frontend/src/main.js"] = "", ["frontend/package.json"] = VITE, ["api/package.json"] = EXPRESS })

    local bufnr = vim.fn.bufadd(root .. "/frontend/src/main.js")
    vim.fn.bufload(bufnr)
    local previous = vim.api.nvim_get_current_buf()
    vim.api.nvim_set_current_buf(bufnr)

    local chosen = resolve(root, {})

    vim.api.nvim_set_current_buf(previous)
    vim.api.nvim_buf_delete(bufnr, { force = true })

    t.eq(chosen, root .. "/frontend", "the buffer you are in is the strongest available signal")
  end)

  t.it("takes the shallowest when prompting is disabled", function()
    reset()
    config.did_setup = false
    config.setup({ discover = { prompt = false } })
    local root = repo({ ["api/package.json"] = EXPRESS, ["deep/nested/web/package.json"] = VITE })
    t.eq(resolve(root, {}), root .. "/api")
    reset()
  end)

  t.it("reuses a remembered choice", function()
    reset()
    config.did_setup = false
    config.setup({ discover = { prompt = false } })
    local root = repo({ ["frontend/package.json"] = VITE, ["api/package.json"] = EXPRESS })
    discover.remember(root, root .. "/frontend")
    t.eq(resolve(root, {}), root .. "/frontend")
    t.truthy(discover.forget(root))
    reset()
  end)
end)

t.describe("derived projects", function()
  t.it("keeps the repository root and moves the working directory", function()
    reset()
    local root = repo({ ["my-app/package.json"] = NEXT, ["my-app/public/index.html"] = "<h1>hi</h1>" })
    local base = project_mod.get(root)
    local derived = project_mod.derive(base, root .. "/my-app")

    t.eq(derived.root, root, "the repository is still the repository")
    t.eq(derived.workdir, root .. "/my-app")
    t.eq(derived.serve_dir, root .. "/my-app/public", "serve dir is resolved inside the app")
    t.contains(derived.name, "my-app")
  end)

  t.it("refuses a directory outside the project", function()
    reset()
    local root = repo({ ["app/package.json"] = VITE })
    local other = repo({ ["app/package.json"] = VITE })
    local base = project_mod.get(root)
    t.eq(project_mod.derive(base, other).workdir, root, "escaping the root must be ignored")
  end)

  t.it("is a no-op for the root itself", function()
    reset()
    local root = repo({ ["index.html"] = "<h1>hi</h1>" })
    local base = project_mod.get(root)
    t.truthy(rawequal(project_mod.derive(base, root), base))
  end)
end)

t.describe("discovery cost", function()
  t.it("stays bounded on a wide tree", function()
    reset()
    local root = util.normalize(vim.fn.tempname())
    vim.fn.mkdir(root .. "/.git", "p")
    -- 300 sibling directories, each with a nested child: far more than any
    -- sane repository, and the caps must still hold.
    for index = 1, 300 do
      vim.fn.mkdir(("%s/dir%03d/inner"):format(root, index), "p")
    end
    util.write_file(root .. "/dir150/package.json", VITE)
    discover.invalidate()
    framework.invalidate()

    local started = util.uv.hrtime()
    local found = discover.candidates(root, { refresh = true })
    local elapsed_ms = (util.uv.hrtime() - started) / 1e6

    t.truthy(#found <= config.get().discover.max_results, "result cap not honoured")
    t.truthy(elapsed_ms < 3000, ("discovery took %.0fms, which is too slow"):format(elapsed_ms))
  end)

  t.it("caches repeated lookups", function()
    reset()
    local root = repo({ ["app/package.json"] = VITE })
    local first = discover.candidates(root, { refresh = true })
    local second = discover.candidates(root)
    t.truthy(rawequal(first, second), "a second call within the window should reuse the scan")
  end)
end)

t.describe("a repository of several services", function()
  --- The shape of MyFaithPal-FYP: a Next.js frontend, two Express servers, and
  --- a socket server nested inside each of them.
  ---@return string root
  local function services_repo()
    return repo({
      ["my-faithpal/package.json"] = '{"dependencies":{"next":"14","ws":"8"},"scripts":{"dev":"next dev"}}',
      ["my-faithpal_server/package.json"] = '{"dependencies":{"express":"4"},"scripts":{"start":"nodemon server.js"}}',
      ["my-faithpal_server/socket/package.json"] = '{"dependencies":{"socket.io":"4"},"scripts":{"start":"nodemon socket.js"}}',
      ["my-faithpal_ai_server/package.json"] = '{"dependencies":{"express":"4"},"scripts":{"start":"nodemon server.js"}}',
      ["my-faithpal_ai_server/socket/package.json"] = '{"dependencies":{"socket.io":"4"},"scripts":{"start":"nodemon socketAI.js"}}',
    })
  end

  t.it("finds every service, including ones nested inside another", function()
    reset()
    local found = relatives(services_repo())
    t.eq(#found, 5)
    for _, expected in ipairs({
      "my-faithpal",
      "my-faithpal_server",
      "my-faithpal_ai_server",
      "my-faithpal_server/socket",
      "my-faithpal_ai_server/socket",
    }) do
      t.includes(found, expected)
    end
  end)

  t.it("labels each one by what it is", function()
    reset()
    local labels = {}
    for _, candidate in ipairs(discover.candidates(services_repo(), { refresh = true })) do
      labels[candidate.relative] = candidate.label
    end
    t.eq(labels["my-faithpal"], "Next.js")
    t.eq(labels["my-faithpal_server"], "Node server")
    t.eq(labels["my-faithpal_server/socket"], "Socket server")
    t.eq(labels["my-faithpal_ai_server/socket"], "Socket server")
  end)

  t.it("offers every service to `auto`", function()
    reset()
    local adapters = require("live_server.adapters")
    local root = services_repo()
    local base = project_mod.get(root)
    for _, candidate in ipairs(discover.candidates(root, { refresh = true })) do
      local derived = project_mod.derive(base, candidate.dir)
      t.truthy(
        adapters.suits_project("node", derived),
        candidate.relative .. " should be startable without naming the adapter"
      )
    end
  end)

  t.it("gives each service its own identity", function()
    reset()
    local root = services_repo()
    local base = project_mod.get(root)
    local seen = {}
    for _, candidate in ipairs(discover.candidates(root, { refresh = true })) do
      local derived = project_mod.derive(base, candidate.dir)
      t.falsy(seen[derived.workdir], "two services must not share a working directory")
      seen[derived.workdir] = true
      t.eq(derived.root, root, "they all still belong to one repository")
    end
  end)
end)
