local api = vim.api
local luv = vim.loop

local renderer = require'nvim-tree.renderer'
local config = require'nvim-tree.config'
local git = require'nvim-tree.git'
local diagnostics = require'nvim-tree.diagnostics'
local pops = require'nvim-tree.populate'
local utils = require'nvim-tree.utils'
local view = require'nvim-tree.view'
local events = require'nvim-tree.events'
local populate = pops.populate
local refresh_entries = pops.refresh_entries

local first_init_done = false
local window_opts = config.window_options()

local M = {}

M.Tree = {
  entries = {},
  cwd = nil,
  loaded = false,
  target_winid = nil,
}

function M.init(with_open, with_reload)
  M.Tree.cwd = luv.cwd()
  git.git_root(M.Tree.cwd)
  populate(M.Tree.entries, M.Tree.cwd)

  local stat = luv.fs_stat(M.Tree.cwd)
  M.Tree.last_modified = stat.mtime.sec

  if with_open then
    M.open()
  end

  if with_reload then
    renderer.draw(M.Tree, true)
    M.Tree.loaded = true
  end

  if not first_init_done then
    events._dispatch_ready()
    first_init_done = true
  end
end

local function get_node_at_line(line)
  local index = 2
  local function iter(entries)
    for _, node in ipairs(entries) do
      if index == line then
        return node
      end
      index = index + 1
      if node.open == true then
        local child = iter(node.entries)
        if child ~= nil then return child end
      end
    end
  end
  return iter
end

local function get_line_from_node(node, find_parent)
  local node_path = node.absolute_path

  if find_parent then
    node_path = node.absolute_path:match("(.*)"..utils.path_separator)
  end

  local line = 2
  local function iter(entries, recursive)
    for _, entry in ipairs(entries) do
      if node_path:match('^'..entry.match_path..'$') ~= nil then
        return line, entry
      end

      line = line + 1
      if entry.open == true and recursive then
        local _, child = iter(entry.entries, recursive)
        if child ~= nil then return line, child end
      end
    end
  end
  return iter
end

function M.get_node_at_cursor()
  local cursor = api.nvim_win_get_cursor(view.get_winnr())
  local line = cursor[1]
  if line == 1 and M.Tree.cwd ~= "/" then
    return { name = ".." }
  end

  if M.Tree.cwd == "/" then
    line = line + 1
  end
  return get_node_at_line(line)(M.Tree.entries)
end

-- If node is grouped, return the last node in the group. Otherwise, return the given node.
function M.get_last_group_node(node)
  local next = node
  while next.group_next do
    next = next.group_next
  end
  return next
end

function M.unroll_dir(node)
  node.open = not node.open
  if node.has_children then node.has_children = false end
  if #node.entries > 0 then
    renderer.draw(M.Tree, true)
  else
    git.git_root(node.absolute_path)
    populate(node.entries, node.link_to or node.absolute_path, node)

    renderer.draw(M.Tree, true)
  end

  if vim.g.nvim_tree_lsp_diagnostics == 1 then
    diagnostics.update()
  end
end

local function refresh_git(node)
  if not node then node = M.Tree end
  git.update_status(node.entries, node.absolute_path or node.cwd, node)
  for _, entry in pairs(node.entries) do
    if entry.entries and #entry.entries > 0 then
      refresh_git(entry)
    end
  end
end

-- TODO update only entries where directory has changed
local function refresh_nodes(node)
  refresh_entries(node.entries, node.absolute_path or node.cwd, node)
  for _, entry in ipairs(node.entries) do
    if entry.entries and entry.open then
      refresh_nodes(entry)
    end
  end
end

function M.refresh_tree()
  if vim.v.exiting ~= nil then return end

  refresh_nodes(M.Tree)

  if config.get_icon_state().show_git_icon or vim.g.nvim_tree_git_hl == 1 then
    git.reload_roots()
    refresh_git(M.Tree)
  end

  if vim.g.nvim_tree_lsp_diagnostics == 1 then
    diagnostics.update()
  end

  if view.win_open() then
    renderer.draw(M.Tree, true)
  else
    M.Tree.loaded = false
  end
end

function M.set_index_and_redraw(fname)
  local i
  if M.Tree.cwd == '/' then
    i = 0
  else
    i = 1
  end
  local reload = false

  local function iter(entries)
    for _, entry in ipairs(entries) do
      i = i + 1
      if entry.absolute_path == fname then
        return i
      end

      if fname:match(entry.match_path..utils.path_separator) ~= nil then
        if #entry.entries == 0 then
          reload = true
          populate(entry.entries, entry.absolute_path, entry)
        end
        if entry.open == false then
          reload = true
          entry.open = true
        end
        if iter(entry.entries) ~= nil then
          return i
        end
      elseif entry.open == true then
        iter(entry.entries)
      end
    end
  end

  local index = iter(M.Tree.entries)
  if not view.win_open() then
    M.Tree.loaded = false
    return
  end
  renderer.draw(M.Tree, reload)
  if index then
    view.set_cursor({index, 0})
  end
end

function M.open_file(mode, filename)
  local tabpage = api.nvim_get_current_tabpage()
  local win_ids = api.nvim_tabpage_list_wins(tabpage)
  local target_winid = M.Tree.target_winid
  local do_split = mode == "split" or mode == "vsplit"
  local vertical = mode == "vsplit" or (window_opts.split_command == "splitright" and mode ~= "split")

  -- Check if filename is already open in a window
  local found = false
  for _, id in ipairs(win_ids) do
    if filename == api.nvim_buf_get_name(api.nvim_win_get_buf(id)) then
      if mode == "preview" then return end
      found = true
      api.nvim_set_current_win(id)
      break
    end
  end

  if not found then
    if not target_winid or not vim.tbl_contains(win_ids, target_winid) then
      -- Target is invalid, or window does not exist in current tabpage: create
      -- new window
      api.nvim_command("belowright vsp")
      target_winid = api.nvim_get_current_win()
      M.Tree.target_winid = target_winid

      -- No need to split, as we created a new window.
      do_split = false
    elseif not vim.o.hidden then
      -- If `hidden` is not enabled, check if buffer in target window is
      -- modified, and create new split if it is.
      local target_bufid = api.nvim_win_get_buf(target_winid)
      if api.nvim_buf_get_option(target_bufid, "modified") then
        do_split = true
      end
    end

    local cmd
    if do_split then
      cmd = string.format("%ssplit ", vertical and "vertical " or "")
    else
      cmd = "edit "
    end

    cmd = cmd .. vim.fn.fnameescape(filename)
    api.nvim_set_current_win(target_winid)
    api.nvim_command(cmd)
    view.resize()
  end

  if mode == "preview" then
    view.focus()
    return
  end

  if vim.g.nvim_tree_quit_on_open == 1 then
    view.close()
  end

  renderer.draw(M.Tree, true)
end

function M.change_dir(foldername)
  if vim.fn.expand(foldername) == M.Tree.cwd then
    return
  end

  api.nvim_command('cd '..foldername)
  M.Tree.entries = {}
  M.init(false, true)
end

function M.set_target_win()
  local id = api.nvim_get_current_win()
  local tree_id = view.View.tabpages[api.nvim_get_current_tabpage()]
  if tree_id and id == tree_id then
    M.Tree.target_winid = 0
    return
  end

  M.Tree.target_winid = id
end

function M.open()
  M.set_target_win()

  view.open()

  if M.Tree.loaded then
    M.change_dir(vim.fn.getcwd())
  end
  renderer.draw(M.Tree, not M.Tree.loaded)
  M.Tree.loaded = true
end

function M.sibling(node, direction)
  if not direction then return end

  local iter = get_line_from_node(node, true)
  local node_path = node.absolute_path

  local line, parent = 0, nil

  -- Check if current node is already at root entries
  for index, entry in ipairs(M.Tree.entries) do
    if node_path:match('^'..entry.match_path..'$') ~= nil then
      line = index
    end
  end

  if line > 0 then
    parent = M.Tree
  else
    _, parent = iter(M.Tree.entries, true)
    if parent ~= nil and #parent.entries > 1 then
      line, _ = get_line_from_node(node)(parent.entries)
    end

    -- Ignore parent line count
    line = line - 1
  end

  local index = line + direction
  if index < 1 then
    index = 1
  elseif index > #parent.entries then
    index = #parent.entries
  end
  local target_node = parent.entries[index]

  line, _ = get_line_from_node(target_node)(M.Tree.entries, true)
  view.set_cursor({line, 0})
  renderer.draw(M.Tree, true)
end

function M.close_node(node)
  M.parent_node(node, true)
end

function M.parent_node(node, should_close)
  if node.name == '..' then return end
  should_close = should_close or false

  local iter = get_line_from_node(node, true)
  if node.open == true and should_close then
    node.open = false
  else
    local line, parent = iter(M.Tree.entries, true)
    if parent == nil then
      line = 1
    elseif should_close then
      parent.open = false
    end
    api.nvim_win_set_cursor(view.get_winnr(), {line, 0})
  end
  renderer.draw(M.Tree, true)
end

function M.toggle_ignored()
  pops.show_ignored = not pops.show_ignored
  return M.refresh_tree()
end

function M.toggle_dotfiles()
  pops.show_dotfiles = not pops.show_dotfiles
  return M.refresh_tree()
end

function M.dir_up(node)
  if not node then
    return M.change_dir('..')
  else
    local newdir = vim.fn.fnamemodify(M.Tree.cwd, ':h')
    M.change_dir(newdir)
    return M.set_index_and_redraw(node.absolute_path)
  end
end

return M
