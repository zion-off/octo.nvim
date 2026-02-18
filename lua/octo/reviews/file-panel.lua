-- Heavily derived from `diffview.nvim`: https://github.com/sindrets/diffview.nvim/blob/main/lua/diffview/file-panel.lua
-- https://github.com/sindrets/diffview.nvim/blob/main/lua/diffview/file-panel.lua

local utils = require "octo.utils"
local config = require "octo.config"
local constants = require "octo.constants"
local renderer = require "octo.reviews.renderer"
local M = {}

local name_counter = 1

---@class FilePanel
---@field files FileEntry[]
---@field size integer
---@field bufid integer
---@field winid integer
---@field render_data RenderData
local FilePanel = {}
FilePanel.__index = FilePanel

FilePanel.winopts = {
  relativenumber = false,
  number = false,
  list = false,
  winfixwidth = true,
  winfixheight = true,
  foldenable = false,
  spell = false,
  wrap = false,
  cursorline = true,
  cursorlineopt = "line",
  signcolumn = "yes",
  foldmethod = "manual",
  foldcolumn = "0",
  scrollbind = false,
  cursorbind = false,
  diff = false,
  winhl = table.concat({
    "EndOfBuffer:OctoEndOfBuffer",
    "Normal:OctoNormal",
    "WinSeparator:OctoWinSeparator",
    "SignColumn:OctoNormal",
    "StatusLine:OctoStatusLine",
    "StatusLineNC:OctoStatuslineNC",
  }, ","),
}

FilePanel.bufopts = {
  swapfile = false,
  buftype = "nofile",
  modifiable = false,
  filetype = "octo_panel",
  bufhidden = "hide",
}

---FilePanel constructor.
---@param files FileEntry[]
---@return FilePanel
function FilePanel:new(files)
  local conf = config.values
  local this = {
    files = files,
    size = conf.file_panel.size,
    line_to_file = {}, -- Instance-level mapping to avoid shared state bugs
    line_to_commit = {}, -- Instance-level mapping for commit navigation
  }

  setmetatable(this, self)
  return this
end

function FilePanel:is_open()
  local valid = self.winid and vim.api.nvim_win_is_valid(self.winid)
  if not valid then
    self.winid = nil
  end
  return valid
end

function FilePanel:is_focused()
  return self:is_open() and vim.api.nvim_get_current_win() == self.winid
end

---@param open_if_closed boolean
function FilePanel:focus(open_if_closed)
  if self:is_open() then
    vim.api.nvim_set_current_win(self.winid)
  elseif open_if_closed then
    self:open()
  end
end

function FilePanel:open()
  if not self:buf_loaded() then
    self:init_buffer()
  end
  if self:is_open() then
    return
  end

  local conf = config.values
  self.size = conf.file_panel.size
  vim.cmd "vsp"
  vim.cmd "wincmd H"
  vim.cmd("vertical resize " .. self.size)
  self.winid = vim.api.nvim_get_current_win()

  for k, v in pairs(FilePanel.winopts) do
    vim.api.nvim_set_option_value(k, v, { win = self.winid })
  end

  vim.cmd("buffer " .. self.bufid)
  vim.cmd ":wincmd ="
end

function FilePanel:close()
  if self:is_open() and #vim.api.nvim_tabpage_list_wins(0) > 1 then
    pcall(vim.api.nvim_win_hide, self.winid)
  end
end

function FilePanel:destroy()
  if self:buf_loaded() then
    self:close()
    pcall(vim.api.nvim_buf_delete, self.bufid, { force = true })
  else
    self:close()
  end
end

function FilePanel:toggle()
  if self:is_open() then
    self:close()
  else
    self:open()
  end
end

function FilePanel:buf_loaded()
  return self.bufid and vim.api.nvim_buf_is_loaded(self.bufid)
end

function FilePanel:init_buffer()
  local bn = vim.api.nvim_create_buf(false, false)

  for k, v in pairs(FilePanel.bufopts) do
    vim.api.nvim_set_option_value(k, v, { buf = bn })
  end

  local bufname = "OctoChangedFiles-" .. name_counter
  name_counter = name_counter + 1
  local ok = pcall(vim.api.nvim_buf_set_name, bn, bufname)
  if not ok then
    utils.wipe_named_buffer(bufname)
    vim.api.nvim_buf_set_name(bn, bufname)
  end
  self.bufid = bn
  self.render_data = renderer.RenderData:new(bufname)
  utils.apply_mappings("file_panel", self.bufid)
  self:render()
  self:redraw()

  return bn
end

function FilePanel:get_file_at_cursor()
  if not (self:is_open() and self:buf_loaded()) then
    return
  end

  local cursor = vim.api.nvim_win_get_cursor(self.winid)
  local line = cursor[1]

  -- Use line_to_file mapping for tree rendering
  -- No fallback needed - tree rendering doesn't have a simple line->file correlation
  return self.line_to_file[line]
end

function FilePanel:highlight_file(file)
  if not (self:is_open() and self:buf_loaded()) then
    return
  end

  -- Find the line corresponding to this file in tree structure
  for line, f in pairs(self.line_to_file) do
    if f == file then
      pcall(vim.api.nvim_win_set_cursor, self.winid, { line, 0 })
      vim.api.nvim_buf_clear_namespace(self.bufid, constants.OCTO_FILE_PANEL_NS, 0, -1)
      vim.api.nvim_buf_set_extmark(self.bufid, constants.OCTO_FILE_PANEL_NS, line - 1, 0, {
        end_line = line,
        hl_group = "OctoFilePanelSelectedFile",
      })
      return
    end
  end
end

function FilePanel:highlight_prev_file()
  if not (self:is_open() and self:buf_loaded()) then
    return
  end

  local cursor = vim.api.nvim_win_get_cursor(self.winid)
  local current_line = cursor[1]

  -- Collect all navigable lines (commits + files)
  local all_lines = {}

  -- Add commit lines
  if self.line_to_commit then
    for line, _ in pairs(self.line_to_commit) do
      table.insert(all_lines, line)
    end
  end

  -- Add file lines
  if self._sorted_file_lines then
    for _, line in ipairs(self._sorted_file_lines) do
      table.insert(all_lines, line)
    end
  end

  if #all_lines == 0 then
    return
  end

  table.sort(all_lines)

  -- Find previous line
  local prev_line = nil
  for i = #all_lines, 1, -1 do
    if all_lines[i] < current_line then
      prev_line = all_lines[i]
      break
    end
  end

  if prev_line then
    pcall(vim.api.nvim_win_set_cursor, self.winid, { prev_line, 0 })
  end
end

function FilePanel:highlight_next_file()
  if not (self:is_open() and self:buf_loaded()) then
    return
  end

  local cursor = vim.api.nvim_win_get_cursor(self.winid)
  local current_line = cursor[1]

  -- Collect all navigable lines (commits + files)
  local all_lines = {}

  -- Add commit lines
  if self.line_to_commit then
    for line, _ in pairs(self.line_to_commit) do
      table.insert(all_lines, line)
    end
  end

  -- Add file lines
  if self._sorted_file_lines then
    for _, line in ipairs(self._sorted_file_lines) do
      table.insert(all_lines, line)
    end
  end

  if #all_lines == 0 then
    return
  end

  table.sort(all_lines)

  -- Find next line
  local next_line = nil
  for _, line in ipairs(all_lines) do
    if line > current_line then
      next_line = line
      break
    end
  end

  if next_line then
    pcall(vim.api.nvim_win_set_cursor, self.winid, { next_line, 0 })
  end
end

---Get the commit at cursor position
---@return table|false|nil commit The commit object, false for "All commits", or nil if not on a commit line
function FilePanel:get_commit_at_cursor()
  if not (self:is_open() and self:buf_loaded()) then
    return
  end

  local cursor = vim.api.nvim_win_get_cursor(self.winid)
  local line = cursor[1]

  -- Check if cursor is on a commit line
  if self.line_to_commit and self.line_to_commit[line] ~= nil then
    return self.line_to_commit[line] -- can be false for "All commits", table for specific commit
  end
  return nil
end

---Select the commit at cursor and switch review level
function FilePanel:select_commit()
  local current_review = require("octo.reviews").get_current_review()
  if not current_review then
    return
  end

  local commit = self:get_commit_at_cursor()

  -- If commit is false, that means "All commits" was selected
  if commit == false then
    -- Switch back to PR level
    local pr = current_review.pull_request
    current_review:focus_commit(pr.right.commit, pr.left.commit)
  elseif commit then
    -- Switch to commit level
    -- Handle edge case: initial commits or orphan commits with no parents
    local parent_sha
    if commit.parents and type(commit.parents) == "table" and #commit.parents > 0 and commit.parents[1].sha then
      parent_sha = commit.parents[1].sha
    else
      -- For initial commits, use the PR's base as parent
      parent_sha = current_review.pull_request.left.commit
    end
    current_review:focus_commit(commit.sha, parent_sha)
  end
end

-- Build a tree structure from file paths
local function build_file_tree(files)
  local tree = {}

  for _, file in ipairs(files) do
    local parts = vim.split(file.path, "/", { plain = true })
    local current = tree

    for i, part in ipairs(parts) do
      if not current[part] then
        current[part] = {
          name = part,
          is_file = i == #parts,
          file_ref = i == #parts and file or nil,
          children = {},
        }
      end
      current = current[part].children
    end
  end

  return tree
end

-- Collapse single-child directory chains (GitHub style)
local function collapse_tree_paths(node)
  local collapsed = {}

  for name, item in pairs(node) do
    if item.is_file then
      -- Files are always added as-is
      collapsed[name] = item
    else
      -- Check if this directory has only one child
      local child_count = 0
      local only_child_name = nil
      local only_child = nil

      for child_name, child_item in pairs(item.children) do
        child_count = child_count + 1
        only_child_name = child_name
        only_child = child_item
        if child_count > 1 then break end
      end

      if child_count == 1 and not only_child.is_file then
        -- Collapse this directory with its only child (if child is also a directory)
        local collapsed_name = name .. "/" .. only_child_name
        local collapsed_child = collapse_tree_paths(only_child.children)
        collapsed[collapsed_name] = {
          name = collapsed_name,
          is_file = false,
          file_ref = nil,
          children = collapsed_child,
        }
      else
        -- Keep as separate node and recursively collapse its children
        collapsed[name] = {
          name = name,
          is_file = false,
          file_ref = nil,
          children = collapse_tree_paths(item.children),
        }
      end
    end
  end

  return collapsed
end

-- Recursively render tree nodes
local function render_tree_node(node, prefix, is_last, lines, line_idx, file_panel, add_hl, conf, depth)
  local items = {}
  for _, child in pairs(node) do
    table.insert(items, child)
  end

  -- Sort: directories first, then files, alphabetically
  table.sort(items, function(a, b)
    if a.is_file ~= b.is_file then
      return not a.is_file
    end
    return a.name < b.name
  end)

  depth = depth or 0

  for i, item in ipairs(items) do
    local is_last_item = i == #items
    local is_root = depth == 0
    local branch = is_root and "" or (is_last_item and "└ " or "├ ")
    local extension = prefix .. branch

    local s = ""
    local offset = 0
    local file = item.file_ref

    if file then
      -- This is a file node - render with full details

      -- tree structure
      s = extension
      if #extension > 0 then
        add_hl("Comment", line_idx, 0, #extension)
      end
      offset = #s

      -- icon
      local icon = require("octo.reviews.renderer").get_file_icon(file.basename, file.extension, file_panel.render_data, line_idx, offset)
      s = s .. icon
      offset = offset + #icon

      -- file name (basename only) - colored by git status
      local filename_hl = "OctoFilePanelFileName"
      if file.status == "A" then
        filename_hl = "OctoDiffstatAdditions"  -- Green for added
      elseif file.status == "D" then
        filename_hl = "OctoDiffstatDeletions"  -- Red for deleted
      end
      add_hl(filename_hl, line_idx, offset, offset + #item.name)
      s = s .. item.name
      offset = offset + #item.name

      -- GitHub-style compact stats: +12 -3
      if file.stats then
        local additions = (file.stats and file.stats.additions) or 0
        local deletions = (file.stats and file.stats.deletions) or 0

        if additions > 0 or deletions > 0 then
          s = s .. " "
          offset = offset + 1

          if additions > 0 then
            local add_str = "+" .. tostring(additions)
            add_hl("OctoDiffstatAdditions", line_idx, offset, offset + #add_str)
            s = s .. add_str
            offset = offset + #add_str
          end

          if additions > 0 and deletions > 0 then
            s = s .. " "
            offset = offset + 1
          end

          if deletions > 0 then
            local del_str = "-" .. tostring(deletions)
            add_hl("OctoDiffstatDeletions", line_idx, offset, offset + #del_str)
            s = s .. del_str
            offset = offset + #del_str
          end
        end
      end

      -- viewer viewed state (after stats)
      if not file.viewed_state or not utils.viewed_state_map[file.viewed_state] then
        file.viewed_state = "UNVIEWED"
      end
      local viewerViewedStateIcon = utils.viewed_state_map[file.viewed_state].icon
      local viewerViewedStateHl = utils.viewed_state_map[file.viewed_state].hl
      s = s .. " "
      offset = offset + 1
      s = s .. viewerViewedStateIcon
      add_hl(viewerViewedStateHl, line_idx, offset, offset + #viewerViewedStateIcon)
      offset = offset + #viewerViewedStateIcon

      -- Store mapping from line to file
      file_panel.line_to_file[line_idx + 1] = file
    else
      -- This is a directory node
      s = extension
      if #extension > 0 then
        add_hl("Comment", line_idx, 0, #extension)
      end
      s = s .. item.name .. "/"
      add_hl("Directory", line_idx, #extension, #s)
    end

    table.insert(lines, s)
    line_idx = line_idx + 1

    -- Render children with updated prefix
    if not item.is_file then
      local child_prefix
      if is_root then
        -- For root items, children get no prefix (they start at base level)
        child_prefix = ""
      else
        child_prefix = prefix .. (is_last_item and "  " or "│ ")
      end
      line_idx = render_tree_node(item.children, child_prefix, is_last_item, lines, line_idx, file_panel, add_hl, conf, depth + 1)
    end
  end

  return line_idx
end

function FilePanel:render()
  local current_review = require("octo.reviews").get_current_review()
  if not current_review then
    return
  end

  if not self.render_data then
    return
  end

  self.render_data:clear()
  local line_idx = 0
  local lines = self.render_data.lines
  local function add_hl(...)
    self.render_data:add_hl(...)
  end

  local conf = config.values
  local strlen = vim.fn.strlen
  local s = "Files changed"
  add_hl("OctoFilePanelTitle", line_idx, 0, #s)
  local change_count = string.format("%s%d%s", conf.left_bubble_delimiter, #self.files, conf.right_bubble_delimiter)
  add_hl("OctoBubbleDelimiterYellow", line_idx, strlen(s) + 1, strlen(s) + 1 + strlen(conf.left_bubble_delimiter))
  add_hl(
    "OctoBubbleYellow",
    line_idx,
    strlen(s) + 1 + strlen(conf.left_bubble_delimiter),
    strlen(s) + 1 + strlen(change_count) - strlen(conf.right_bubble_delimiter)
  )
  add_hl(
    "OctoBubbleDelimiterYellow",
    line_idx,
    strlen(s) + 1 + strlen(change_count) - strlen(conf.right_bubble_delimiter),
    strlen(s) + 1 + strlen(change_count)
  )
  s = s .. " " .. change_count
  table.insert(lines, s)
  line_idx = line_idx + 1

  -- Clear line mappings at the start to avoid stale state
  self.line_to_file = {}
  self.line_to_commit = {}

  -- Build tree, collapse paths, and render
  local tree = build_file_tree(self.files)
  local collapsed_tree = collapse_tree_paths(tree)
  line_idx = render_tree_node(collapsed_tree, "", false, lines, line_idx, self, add_hl, conf, 0)

  -- Cache sorted file lines for efficient navigation
  self._sorted_file_lines = {}
  for line, _ in pairs(self.line_to_file) do
    table.insert(self._sorted_file_lines, line)
  end
  table.sort(self._sorted_file_lines)

  -- Render commit list
  table.insert(lines, "")
  line_idx = line_idx + 1

  -- Determine if we're at PR level or commit level
  local review_level = current_review:get_level()
  local is_pr_level = review_level == "PR"

  -- Render "All commits" option
  s = "All commits"
  if is_pr_level then
    add_hl("OctoFilePanelTitle", line_idx, 0, #s) -- Highlighted
  else
    add_hl("Comment", line_idx, 0, #s) -- Dimmed
  end
  table.insert(lines, s)
  self.line_to_commit[line_idx + 1] = false -- false means "All commits" (using false as sentinel to distinguish from missing key)
  line_idx = line_idx + 1

  -- Show indicator if commits haven't loaded yet or are empty
  if #current_review.commits == 0 then
    s = "  (loading...)"
    add_hl("Comment", line_idx, 0, #s)
    table.insert(lines, s)
    line_idx = line_idx + 1
  end

  -- Helper function to wrap text to a given width
  local function wrap_text(text, width, indent)
    local wrapped_lines = {}

    -- Handle empty or whitespace-only text
    if not text or text:match("^%s*$") then
      return { "" }
    end

    local current_line = ""

    for word in text:gmatch("%S+") do
      local test_line = current_line == "" and word or (current_line .. " " .. word)
      if #test_line > width then
        if current_line ~= "" then
          table.insert(wrapped_lines, current_line)
          current_line = indent .. word
        else
          -- Word is longer than width, truncate with ellipsis
          if #word > width then
            table.insert(wrapped_lines, word:sub(1, width - 1) .. "…")
            current_line = ""
          else
            table.insert(wrapped_lines, word)
            current_line = ""
          end
        end
      else
        current_line = test_line
      end
    end

    if current_line ~= "" then
      table.insert(wrapped_lines, current_line)
    end

    -- Ensure at least one line is returned
    if #wrapped_lines == 0 then
      return { "" }
    end

    return wrapped_lines
  end

  -- Render individual commits
  local max_width = self.size - 4 -- Panel width minus margin (accounting for sign column)
  for _, commit in ipairs(current_review.commits) do
    -- Validate commit structure
    if not commit or not commit.sha or not commit.commit then
      goto continue
    end

    local short_sha = commit.sha:sub(1, 7)

    -- Safely extract commit message
    local message = ""
    if commit.commit.message and type(commit.commit.message) == "string" then
      message = commit.commit.message:match("^([^\n]+)") or commit.commit.message
    else
      message = "(no message)"
    end

    local first_line = short_sha .. " " .. message

    -- Highlight if this is the selected commit
    local is_selected = not is_pr_level and current_review.layout.right.commit == commit.sha
    local hl_group = is_selected and "OctoFilePanelTitle" or "Comment"

    -- Wrap the commit line if needed
    local commit_lines = wrap_text(first_line, max_width, "  ") -- 2 spaces for continuation indent

    for line_num, commit_line in ipairs(commit_lines) do
      add_hl(hl_group, line_idx, 0, #commit_line)
      table.insert(lines, commit_line)

      -- Only map first line as navigable (skip wrapped continuation lines)
      if line_num == 1 then
        self.line_to_commit[line_idx + 1] = commit
      end

      line_idx = line_idx + 1
    end

    ::continue::
  end
end

function FilePanel:redraw()
  if not self.render_data then
    return
  end
  renderer.render(self.bufid, self.render_data)
end

M.FilePanel = FilePanel

---@param path string
---@return octo.ReviewThread[]
function M.threads_for_path(path)
  local current_review = require("octo.reviews").get_current_review()
  if not current_review then
    return {}
  end
  local threads = {}
  for _, thread in pairs(current_review.threads) do
    if path == thread.path then
      table.insert(threads, thread)
    end
  end
  return threads
end

function M.thread_counts(path)
  local threads = M.threads_for_path(path)
  local resolved = 0
  local outdated = 0
  local pending = 0
  local active = 0
  for _, thread in pairs(threads) do
    if not thread.isOutdated and not thread.isResolved and #thread.comments.nodes > 0 then
      active = active + 1
    end
    if thread.isOutdated and #thread.comments.nodes > 0 then
      outdated = outdated + 1
    end
    if thread.isResolved and #thread.comments.nodes > 0 then
      resolved = resolved + 1
    end
    for _, comment in ipairs(thread.comments.nodes) do
      local review = comment.pullRequestReview
      if not utils.is_blank(review) and review.state == "PENDING" and not utils.is_blank(utils.trim(comment.body)) then
        pending = pending + 1
      end
    end
  end
  return active, resolved, outdated, pending
end

function M.next_thread()
  local bufnr = vim.api.nvim_get_current_buf()
  local _, path = utils.get_split_and_path(bufnr)
  local current_line = vim.fn.line "."
  local candidate = math.huge
  if path then
    for _, thread in ipairs(M.threads_for_path(path)) do
      if thread.startLine > current_line and thread.startLine < candidate then
        candidate = thread.startLine
      end
    end
  end
  if candidate < math.huge then
    vim.cmd(":" .. candidate)
  end
end

function M.prev_thread()
  local bufnr = vim.api.nvim_get_current_buf()
  local _, path = utils.get_split_and_path(bufnr)
  local current_line = vim.fn.line "."
  local candidate = -1
  if path then
    for _, thread in ipairs(M.threads_for_path(path)) do
      if thread.originalLine < current_line and thread.originalLine > candidate then
        candidate = thread.originalLine
      end
    end
  end
  if candidate > -1 then
    vim.cmd(":" .. candidate)
  end
end

return M
