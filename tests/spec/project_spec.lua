local t = require("harness")
local project_mod = require("live_server.project")
local config = require("live_server.config")
local util = require("live_server.util")

---@param tree table<string, string|boolean> path -> contents (true = directory)
---@return string root
local function scaffold(tree)
  local root = util.normalize(vim.fn.tempname())
  vim.fn.mkdir(root, "p")
  for path, contents in pairs(tree) do
    local full = root .. "/" .. path
    if contents == true then
      vim.fn.mkdir(full, "p")
    else
      vim.fn.mkdir(vim.fs.dirname(full), "p")
      util.write_file(full, contents)
    end
  end
  return root
end

local function reset()
  project_mod.invalidate()
  config.did_setup = false
  config.setup({})
end

t.describe("project root detection", function()
  t.it("finds the directory holding a marker", function()
    reset()
    local root = scaffold({ [".git/HEAD"] = "ref: refs/heads/main", ["src/app.js"] = "" })
    local project = project_mod.get(root .. "/src/app.js")
    t.eq(project.root, root)
    t.eq(project.name, vim.fn.fnamemodify(root, ":t"))
  end)

  t.it("walks up several levels", function()
    reset()
    local root = scaffold({ ["package.json"] = "{}", ["a/b/c/deep.html"] = "" })
    t.eq(project_mod.get(root .. "/a/b/c/deep.html").root, root)
  end)

  t.it("accepts a directory as well as a file", function()
    reset()
    local root = scaffold({ ["package.json"] = "{}", ["sub"] = true })
    t.eq(project_mod.get(root .. "/sub").root, root)
  end)

  t.it("caches repeated lookups", function()
    reset()
    local root = scaffold({ ["package.json"] = "{}" })
    local first = project_mod.get(root)
    local second = project_mod.get(root)
    t.truthy(rawequal(first, second), "a second lookup should return the cached project")
  end)
end)

t.describe("serve directory detection", function()
  t.it("serves the root when it has an index.html", function()
    reset()
    local root = scaffold({ [".git/HEAD"] = "", ["index.html"] = "<h1>hi</h1>" })
    t.eq(project_mod.get(root).serve_dir, root)
  end)

  t.it("finds a conventional sub-directory", function()
    reset()
    local root = scaffold({ [".git/HEAD"] = "", ["public/index.html"] = "<h1>hi</h1>" })
    t.eq(project_mod.get(root).serve_dir, root .. "/public")
  end)

  t.it("prefers the earlier candidate when several match", function()
    reset()
    local root = scaffold({
      [".git/HEAD"] = "",
      ["public/index.html"] = "",
      ["dist/index.html"] = "",
    })
    t.eq(project_mod.get(root).serve_dir, root .. "/public")
  end)

  t.it("falls back to the root when nothing matches", function()
    reset()
    local root = scaffold({ [".git/HEAD"] = "", ["notes.md"] = "" })
    t.eq(project_mod.get(root).serve_dir, root)
  end)

  t.it("honours an explicit serve_dir", function()
    reset()
    config.did_setup = false
    config.setup({ root = { serve_dir = "site" } })
    local root = scaffold({ [".git/HEAD"] = "", ["site/index.html"] = "" })
    t.eq(project_mod.get(root).serve_dir, root .. "/site")
    reset()
  end)
end)

t.describe("project configuration files", function()
  t.it("reads safe fields", function()
    reset()
    local root = scaffold({
      [".liveserverrc.json"] = '{"server":"live_server","port":4321,"root":"public","open":"about.html"}',
      ["public/index.html"] = "",
    })
    local project = project_mod.get(root)
    t.eq(project.config.server, "live_server")
    t.eq(project.config.port, 4321)
    t.eq(project.config.open, "about.html")
    t.eq(project.serve_dir, root .. "/public")
  end)

  t.it("holds execution-affecting fields back for a trust decision", function()
    reset()
    local root = scaffold({
      [".liveserverrc.json"] = '{"port":4321,"command":["npx","vite"],"env":{"X":"1"}}',
    })
    local project = project_mod.get(root)
    t.eq(project.config.port, 4321)
    t.eq(project.privileged.command, { "npx", "vite" })
    t.eq(project.privileged.env, { X = "1" })
    t.eq(project.config.command, nil, "command must never reach the safe config")
  end)

  t.it("refuses a serve root outside the project", function()
    reset()
    local root = scaffold({ [".liveserverrc.json"] = '{"root":"../../../etc"}' })
    local project = project_mod.get(root)
    t.eq(project.config.root, nil, "an escaping root must be dropped")
    t.eq(project.serve_dir, root)
  end)

  t.it("refuses an absolute serve root outside the project", function()
    reset()
    local root = scaffold({ [".liveserverrc.json"] = '{"root":"/etc"}' })
    t.eq(project_mod.get(root).serve_dir, root)
  end)

  t.it("allows a nested absolute serve root inside the project", function()
    reset()
    local root = scaffold({ ["site/index.html"] = "" })
    util.write_file(root .. "/.liveserverrc.json", ('{"root":%q}'):format(root .. "/site"))
    project_mod.invalidate()
    t.eq(project_mod.get(root).serve_dir, root .. "/site")
  end)

  t.it("drops fields of the wrong type", function()
    reset()
    local root = scaffold({ [".liveserverrc.json"] = '{"port":"not a number","host":"127.0.0.1"}' })
    local project = project_mod.get(root)
    t.eq(project.config.port, nil)
    t.eq(project.config.host, "127.0.0.1")
  end)

  t.it("survives malformed JSON", function()
    reset()
    local root = scaffold({ [".liveserverrc.json"] = "{ not json" })
    local project = project_mod.get(root)
    t.eq(project.config, {})
    t.eq(project.root, root, "detection still works")
  end)

  t.it("ignores project files when disabled", function()
    reset()
    config.did_setup = false
    config.setup({ project = { enabled = false } })
    local root = scaffold({ [".liveserverrc.json"] = '{"port":4321}' })
    t.eq(project_mod.get(root).config.port, nil)
    reset()
  end)
end)

t.describe("project.relative_page", function()
  t.it("maps an html buffer to its url path", function()
    local root = scaffold({ ["about/index.html"] = "" })
    local bufnr = vim.fn.bufadd(root .. "/about/index.html")
    vim.fn.bufload(bufnr)
    t.eq(project_mod.relative_page(root, bufnr), "about/index.html")
    vim.api.nvim_buf_delete(bufnr, { force = true })
  end)

  t.it("returns nil for a file outside the served directory", function()
    local root = scaffold({ ["index.html"] = "" })
    local other = scaffold({ ["index.html"] = "" })
    local bufnr = vim.fn.bufadd(other .. "/index.html")
    vim.fn.bufload(bufnr)
    t.eq(project_mod.relative_page(root, bufnr), nil)
    vim.api.nvim_buf_delete(bufnr, { force = true })
  end)

  t.it("returns nil for non-markup buffers", function()
    local root = scaffold({ ["app.js"] = "" })
    local bufnr = vim.fn.bufadd(root .. "/app.js")
    vim.fn.bufload(bufnr)
    t.eq(project_mod.relative_page(root, bufnr), nil, "a js buffer should open the site root, not itself")
    vim.api.nvim_buf_delete(bufnr, { force = true })
  end)
end)
