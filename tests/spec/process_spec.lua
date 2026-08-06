local t = require("harness")
local process = require("live_server.process")
local util = require("live_server.util")

if util.is_windows then
  t.describe("liveness", function()
    t.it("reports a dead pid as dead", function()
      -- Regression: `uv.kill` returns its error rather than raising, so
      -- `pcall(uv.kill, pid, 0)` succeeds for any pid and every process looked
      -- alive forever.
      local job = vim.fn.jobstart({ "sh", "-c", "exit 0" })
      local pid = vim.fn.jobpid(job)
      vim.fn.jobwait({ job }, 3000)
      t.truthy(
        vim.wait(3000, function()
          return not process.alive(pid)
        end, 50),
        "a process that has exited must not be reported as alive"
      )
    end)

    t.it("reports an unused pid as dead", function()
      t.falsy(process.alive(4194303), "an implausible pid cannot be alive")
    end)
  end)

  t.describe("process trees", function()
    t.skip("process tree", "the Unix process table is not available here")
  end)
  return
end

---@param script string shell to run
---@return integer job
---@return integer pid
local function spawn(script)
  local job = vim.fn.jobstart({ "sh", "-c", script }, { detach = false })
  assert(job > 0, "could not spawn the fixture")
  return job, vim.fn.jobpid(job)
end

t.describe("process trees", function()
  t.it("finds a child", function()
    local job, pid = spawn("sleep 30 & wait")
    t.truthy(
      vim.wait(3000, function()
        return #process.descendants_sync(pid) > 0
      end, 50),
      "no descendant was ever observed"
    )

    local found = process.descendants_sync(pid)
    t.truthy(#found >= 1)
    for _, child in ipairs(found) do
      t.neq(child, pid)
      t.neq(child, vim.uv.getpid(), "our own process must never appear")
    end
    process.kill_tree_sync(pid, 9)
    pcall(vim.fn.jobstop, job)
  end)

  t.it("finds a grandchild, deepest first", function()
    -- The shape that matters: npm -> nodemon -> node.
    local job, pid = spawn("sh -c 'sleep 30 & wait' & wait")
    t.truthy(
      vim.wait(3000, function()
        return #process.descendants_sync(pid) >= 2
      end, 50),
      "the grandchild was never observed"
    )

    local found = process.descendants_sync(pid)
    t.truthy(#found >= 2, "expected a child and a grandchild, got " .. #found)
    process.kill_tree_sync(pid, 9)
    pcall(vim.fn.jobstop, job)
  end)

  t.it("kills the whole tree", function()
    local job, pid = spawn("sh -c 'sleep 30 & wait' & wait")
    t.truthy(vim.wait(3000, function()
      return #process.descendants_sync(pid) >= 2
    end, 50))

    local before = process.descendants_sync(pid)
    process.kill_tree_sync(pid, 9)

    t.truthy(
      vim.wait(5000, function()
        for _, child in ipairs(before) do
          if process.alive(child) then
            return false
          end
        end
        return not process.alive(pid)
      end, 100),
      "something in the tree survived a kill"
    )
    pcall(vim.fn.jobstop, job)
  end)

  t.it("refuses to signal anything it should not", function()
    -- A bug here would kill the editor, so the guards are asserted directly.
    t.eq(process.descendants_sync(0), {})
    t.eq(process.descendants_sync(1), {})
    -- `alive` reports the truth; refusing to signal is a separate guard.
    t.truthy(process.alive(vim.uv.getpid()), "we are, in fact, alive")
    t.falsy(process.alive(0))
    t.falsy(process.alive(-1))
    -- Must be a no-op, not an error, and above all not fatal.
    t.truthy(pcall(process.kill_tree_sync, vim.uv.getpid(), 9))
    t.truthy(pcall(process.kill_tree_sync, 1, 9))
    t.truthy(vim.uv.getpid() > 0, "still here")
  end)

  t.it("never lists the editor as a descendant of itself", function()
    local found = process.descendants_sync(vim.uv.getpid())
    for _, child in ipairs(found) do
      t.neq(child, vim.uv.getpid())
    end
  end)
end)
