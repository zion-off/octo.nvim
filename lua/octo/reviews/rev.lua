-- Heavily derived from `diffview.nvim`:
-- https://github.com/sindrets/diffview.nvim/blob/main/lua/diffview/rev.lua
--
local Job = require("plenary.job")

local M = {}

---@class Rev
---@field type integer
---@field commit string
---@field head boolean
---@field message string?
local Rev = {}
Rev.__index = Rev

---Rev constructor
---@param commit string
---@return Rev
function Rev:new(commit, head)
  local this = {
    commit = commit,
    head = head or false,
  }
  setmetatable(this, self)
  return this
end

function Rev:abbrev()
  return self.commit:sub(1, 7)
end

---Resolve the commit message via GitHub API
---@param repo string repository in "owner/repo" format
---@param cb fun()? optional callback when message is resolved
function Rev:resolve_message_via_api(repo, cb)
  local gh = require "octo.gh"
  gh.api.get {
    "/repos/{repo}/commits/{sha}",
    format = { repo = repo, sha = self.commit },
    opts = {
      cb = gh.create_callback {
        success = function(output)
          local result = vim.json.decode(output)
          if result and result.commit and result.commit.message then
            self.message = result.commit.message:gsub("\n.*", "")
          end
          if cb then
            cb()
          end
        end,
        failure = function()
          if cb then
            cb()
          end
        end,
      },
    },
  }
end

---Resolve the commit message for this rev, trying local git first then GitHub API
---@param cb fun()? optional callback when message is resolved
---@param repo string? repository in "owner/repo" format for API fallback
function Rev:resolve_message(cb, repo)
  if self.message then
    if cb then
      cb()
    end
    return
  end
  ---@diagnostic disable-next-line: missing-fields
  Job:new({
    enable_recording = true,
    command = "git",
    args = { "log", "--format=%s", "-1", self.commit },
    on_exit = vim.schedule_wrap(function(j_self, code, _)
      if code == 0 then
        local result = j_self:result()
        if result and #result > 0 then
          self.message = result[1]
          if cb then
            cb()
          end
          return
        end
      end
      -- Local git failed, fall back to GitHub API
      if repo then
        self:resolve_message_via_api(repo, cb)
      elseif cb then
        cb()
      end
    end),
  }):start()
end

M.Rev = Rev

return M
