local M = {}

local defaults = {
  extensions = {
    jpg = true, jpeg = true, png = true, gif = true, bmp = true, webp = true,
    tiff = true, heic = true, avif = true,
    mp4 = true, mkv = true, webm = true, avi = true, mov = true,
  },
  thumb_cache = vim.fn.stdpath("cache") .. "/snacks-gallery-thumbs",
  thumb_size = "400x400",
  max_workers = 4,
  open_cmd = vim.fn.has("mac") == 1 and { "open" } or { "xdg-open" },
  win_scale = 0.9,
  preview_scale = 0.8,
}

local config = nil ---@type table?
local state = nil ---@type table?

local ns = vim.api.nvim_create_namespace("snacks-gallery")

-- Highlight groups (colorscheme-compatible, user overrides take precedence)
for _, def in ipairs({
  { "GalleryBorder",      "FloatBorder" },
  { "GalleryBorderSel",   "Special" },
  { "GalleryFilename",    "Comment" },
  { "GalleryFilenameSel", "Title" },
  { "GalleryFooter",      "Comment" },
  { "GalleryFooterKey",   "Special" },
  { "GalleryFooterSep",   "FloatBorder" },
  { "GalleryFooterVal",   "Normal" },
}) do
  vim.api.nvim_set_hl(0, def[1], { link = def[2], default = true })
end

local thumb_queue = {} ---@type table[]
local thumb_active = 0
local rerender_timer = nil ---@type uv.uv_timer_t?

local function ensure_config()
  if not config then
    config = vim.deepcopy(defaults)
  end
end

---@param opts? table
function M.setup(opts)
  config = vim.tbl_deep_extend("force", vim.deepcopy(defaults), opts or {})
end

--- Clean up thumbnail windows, properly resetting snacks image state
---@param thumb_wins {buf: number, win: number, placement: snacks.image.Placement}[]
local function close_thumb_wins(thumb_wins)
  if not thumb_wins then return end

  -- Collect unique image objects before cleanup destroys references
  local imgs = {}
  for _, tw in ipairs(thumb_wins) do
    if tw.placement and tw.placement.img then
      imgs[tw.placement.img] = true
    end
  end

  -- Clean placements (sends kitty delete commands)
  for _, tw in ipairs(thumb_wins) do
    pcall(Snacks.image.placement.clean, tw.buf)
    if vim.api.nvim_win_is_valid(tw.win) then
      vim.api.nvim_win_close(tw.win, true)
    end
    if vim.api.nvim_buf_is_valid(tw.buf) then
      vim.api.nvim_buf_delete(tw.buf, { force = true })
    end
  end

  -- Reset sent flag: placement.clean deleted image data from kitty,
  -- but snacks' cached image objects still think sent=true.
  -- Without this, next open reuses the stale object and never re-sends.
  for img in pairs(imgs) do
    img.sent = false
  end
end

---@param dir string
---@return {path: string, name: string}[]
function M._scan(dir)
  ensure_config()
  local files = {}
  local handle = vim.uv.fs_scandir(dir)
  if not handle then return files end
  while true do
    local name, typ = vim.uv.fs_scandir_next(handle)
    if not name then break end
    if typ == "file" then
      local ext = name:match("%.([^%.]+)$")
      if ext and config.extensions[ext:lower()] then
        files[#files + 1] = { path = dir .. "/" .. name, name = name }
      end
    end
  end
  table.sort(files, function(a, b) return a.name:lower() < b.name:lower() end)
  return files
end

---@param file_count number
---@param win_w number
---@param win_h number
function M._layout(file_count, win_w, win_h)
  local pad = 2
  local thumb_w = math.max(15, math.min(30, math.floor((win_w - pad) / 3) - pad))
  local cols = math.max(1, math.floor((win_w + pad) / (thumb_w + pad)))
  thumb_w = math.floor((win_w - pad * (cols - 1)) / cols)
  local thumb_h = math.max(8, math.floor(thumb_w * 0.6))
  local cell_h = thumb_h + 1
  if cell_h > win_h then
    thumb_h = math.max(6, win_h - 1)
    cell_h = thumb_h + 1
  end
  local visible_rows = math.max(1, math.floor(win_h / cell_h))
  local rows = math.max(1, math.ceil(file_count / cols))
  return {
    thumb_w = thumb_w, thumb_h = thumb_h,
    cols = cols, rows = rows, pad = pad,
    visible_rows = visible_rows,
  }
end

local function thumb_cache_path(src)
  ensure_config()
  local stat = vim.uv.fs_stat(src)
  local mtime_sec = stat and stat.mtime.sec or 0
  local mtime_nsec = stat and stat.mtime.nsec or 0
  return config.thumb_cache .. "/" .. vim.fn.sha256(src .. ":" .. mtime_sec .. ":" .. mtime_nsec) .. ".png"
end

local function process_thumb_queue()
  ensure_config()
  if thumb_active < 0 then thumb_active = 0 end
  while #thumb_queue > 0 and thumb_active < config.max_workers do
    local job = table.remove(thumb_queue, 1)
    if job.cancelled then goto continue end
    thumb_active = thumb_active + 1
    local cached = thumb_cache_path(job.src)
    if vim.uv.fs_stat(cached) then
      thumb_active = thumb_active - 1
      if thumb_active < 0 then thumb_active = 0 end
      vim.schedule(function()
        if not job.cancelled then job.callback(cached) end
        process_thumb_queue()
      end)
    else
      local tmp = cached .. ".tmp." .. vim.fn.getpid() .. "." .. vim.uv.hrtime() .. ".png"
      job.proc = vim.system(
        { "magick", job.src .. "[0]", "-thumbnail", config.thumb_size, "-strip", tmp },
        {},
        function(result)
          thumb_active = thumb_active - 1
          if thumb_active < 0 then thumb_active = 0 end
          vim.schedule(function()
            if not job.cancelled and result.code == 0 and vim.uv.fs_stat(tmp) then
              vim.uv.fs_rename(tmp, cached)
              if vim.uv.fs_stat(cached) then
                job.callback(cached)
              end
            else
              pcall(vim.uv.fs_unlink, tmp)
            end
            process_thumb_queue()
          end)
        end
      )
    end
    ::continue::
  end
end

local function cancel_thumb_jobs(jobs)
  if not jobs then return end
  for _, job in ipairs(jobs) do
    job.cancelled = true
    if job.proc then
      local proc = job.proc
      pcall(function() proc:kill("sigterm") end)
      vim.defer_fn(function()
        pcall(function() proc:kill("sigkill") end)
      end, 2000)
    end
  end
end

---@param bytes number
---@return string
local function format_size(bytes)
  if bytes < 1024 then return bytes .. " B" end
  if bytes < 1024 * 1024 then return string.format("%.1f KB", bytes / 1024) end
  if bytes < 1024 * 1024 * 1024 then return string.format("%.1f MB", bytes / (1024 * 1024)) end
  return string.format("%.1f GB", bytes / (1024 * 1024 * 1024))
end

--- Update thumbnail borders, filename extmarks, and footer for current selection
function M._update_visual()
  local s = state
  if not s then return end
  local g = s.grid
  if not g then return end
  if not vim.api.nvim_win_is_valid(s.win) then return end
  if not vim.api.nvim_buf_is_valid(s.buf) then return end

  local sel_idx = s.cur_row * g.cols + s.cur_col + 1

  -- 1. Update winhighlight on each thumbnail window
  local cell_w = g.thumb_w + g.pad
  local start_row = s.scroll_offset
  local tw_i = 0
  for vis_row = 0, math.min(g.visible_rows - 1, g.rows - 1 - start_row) do
    local grid_row = start_row + vis_row
    for col = 0, g.cols - 1 do
      local idx = grid_row * g.cols + col + 1
      if idx <= #s.files then
        tw_i = tw_i + 1
        local tw = s.thumb_wins[tw_i]
        if tw and vim.api.nvim_win_is_valid(tw.win) then
          local hl = idx == sel_idx
            and "FloatBorder:GalleryBorderSel"
            or "FloatBorder:GalleryBorder"
          vim.wo[tw.win].winhighlight = hl
        end
      end
    end
  end

  -- 2. Clear namespace and re-add filename extmarks
  vim.api.nvim_buf_clear_namespace(s.buf, ns, 0, -1)
  local cell_h = g.thumb_h + 1
  for vis_row = 0, math.min(g.visible_rows - 1, g.rows - 1 - start_row) do
    local grid_row = start_row + vis_row
    local fname_line = vis_row * cell_h + g.thumb_h -- 0-indexed
    local line = vim.api.nvim_buf_get_lines(s.buf, fname_line, fname_line + 1, false)[1]
    if not line then goto next_row end
    for col = 0, g.cols - 1 do
      local idx = grid_row * g.cols + col + 1
      if idx > #s.files then break end
      local name = s.files[idx].name
      if #name > g.thumb_w then
        name = name:sub(1, g.thumb_w - 1) .. "…"
      end
      local col_start = col * cell_w
      local total_pad = cell_w - vim.api.nvim_strwidth(name)
      local left_pad = math.floor(total_pad / 2)
      local name_start = col_start + left_pad
      local name_end = name_start + #name
      if name_end > #line then name_end = #line end
      local hl = idx == sel_idx and "GalleryFilenameSel" or "GalleryFilename"
      vim.api.nvim_buf_set_extmark(s.buf, ns, fname_line, name_start, {
        end_col = name_end,
        hl_group = hl,
      })
    end
    ::next_row::
  end

  -- 3. Update footer on main window
  local file = s.files[sel_idx]
  if not file then return end
  local fstat = vim.uv.fs_stat(file.path)
  local size_str = fstat and format_size(fstat.size) or "?"
  local ext = (file.name:match("%.([^%.]+)$") or ""):upper()

  local sep = { " │ ", "GalleryFooterSep" }
  local footer = {
    { " " .. sel_idx .. "/" .. #s.files .. " ", "GalleryFooterVal" },
    sep,
    { file.name .. " ", "GalleryFooterVal" },
    sep,
    { size_str .. " ", "GalleryFooterVal" },
    sep,
    { ext .. " ", "GalleryFooterVal" },
    sep,
    { "hjkl", "GalleryFooterKey" }, { ":Nav ", "GalleryFooter" },
    { "⏎", "GalleryFooterKey" }, { ":Open ", "GalleryFooter" },
    { "p", "GalleryFooterKey" }, { ":View ", "GalleryFooter" },
    { "r", "GalleryFooterKey" }, { ":Rename ", "GalleryFooter" },
    { "d", "GalleryFooterKey" }, { ":Del ", "GalleryFooter" },
    { "q", "GalleryFooterKey" }, { ":Quit ", "GalleryFooter" },
  }
  pcall(vim.api.nvim_win_set_config, s.win, {
    footer = footer,
    footer_pos = "center",
  })
end

--- Rewrite the buffer and recreate thumbnail windows for the visible range
function M._render_visible()
  local s = state
  if not s then return end
  local grid = s.grid
  local files = s.files
  local cell_h = grid.thumb_h + 1
  local cell_w = grid.thumb_w + grid.pad

  -- Cancel pending thumbnail jobs and tear down old thumbnails
  cancel_thumb_jobs(s.thumb_jobs)
  thumb_queue = {}
  close_thumb_wins(s.thumb_wins)
  s.thumb_wins = {}
  s.thumb_jobs = {}

  local start_row = s.scroll_offset
  local end_row = math.min(start_row + grid.visible_rows - 1, grid.rows - 1)

  -- Build buffer content for visible rows only
  local lines = {}
  for row = start_row, end_row do
    for _ = 1, grid.thumb_h do
      lines[#lines + 1] = ""
    end
    local fname_parts = {}
    for col = 0, grid.cols - 1 do
      local idx = row * grid.cols + col + 1
      if idx <= #files then
        local name = files[idx].name
        if #name > grid.thumb_w then
          name = name:sub(1, grid.thumb_w - 1) .. "…"
        end
        local total_pad = cell_w - vim.api.nvim_strwidth(name)
        local left_pad = math.floor(total_pad / 2)
        local right_pad = total_pad - left_pad
        fname_parts[#fname_parts + 1] = string.rep(" ", left_pad) .. name .. string.rep(" ", right_pad)
      end
    end
    lines[#lines + 1] = table.concat(fname_parts)
  end

  vim.bo[s.buf].modifiable = true
  vim.api.nvim_buf_set_lines(s.buf, 0, -1, false, lines)
  vim.bo[s.buf].modifiable = false

  -- Create thumbnail windows at fixed positions relative to main window
  for vis_row = 0, end_row - start_row do
    local grid_row = start_row + vis_row
    for col = 0, grid.cols - 1 do
      local idx = grid_row * grid.cols + col + 1
      if idx <= #files then
        local thumb_buf = vim.api.nvim_create_buf(false, true)
        local thumb_win = vim.api.nvim_open_win(thumb_buf, false, {
          relative = "win",
          win = s.win,
          row = vis_row * cell_h,
          col = col * cell_w,
          width = grid.thumb_w - 2,
          height = grid.thumb_h - 2,
          style = "minimal",
          border = "rounded",
          focusable = false,
          zindex = 51,
        })

        vim.bo[thumb_buf].filetype = "image"
        vim.bo[thumb_buf].modifiable = false
        vim.bo[thumb_buf].swapfile = false

        local tw = { buf = thumb_buf, win = thumb_win, placement = nil }
        s.thumb_wins[#s.thumb_wins + 1] = tw

        local function attach_thumb(thumb_path)
          if state ~= s then return end
          if not vim.api.nvim_buf_is_valid(thumb_buf) then return end
          if not vim.api.nvim_win_is_valid(thumb_win) then return end
          tw.placement = Snacks.image.placement.new(thumb_buf, thumb_path, {
            conceal = true,
            auto_resize = true,
          })
        end

        -- Use cached thumbnail if available, otherwise queue generation
        local cached = thumb_cache_path(files[idx].path)
        if vim.uv.fs_stat(cached) then
          attach_thumb(cached)
        else
          local job = { src = files[idx].path, callback = attach_thumb, cancelled = false, proc = nil }
          s.thumb_jobs[#s.thumb_jobs + 1] = job
          thumb_queue[#thumb_queue + 1] = job
        end
      end
    end
  end

  -- Start processing queued thumbnail jobs
  process_thumb_queue()

  -- Pin the view to top — buffer only contains visible content
  vim.api.nvim_win_call(s.win, function()
    vim.fn.winrestview({ topline = 1, leftcol = 0 })
  end)

  M._update_visual()
end

function M._setup_keys(buf, win, files, grid)
  local function move_to_cell(r, c)
    local s = state
    if not s then return end
    local g = s.grid
    if not g then return end
    r = math.max(0, math.min(r, g.rows - 1))
    c = math.max(0, math.min(c, g.cols - 1))
    local idx = r * g.cols + c + 1
    if idx > #files then return end

    s.cur_row, s.cur_col = r, c

    -- Scroll if target cell is outside visible range
    local need_scroll = false
    if r < s.scroll_offset then
      s.scroll_offset = r
      need_scroll = true
    elseif r >= s.scroll_offset + g.visible_rows then
      s.scroll_offset = r - g.visible_rows + 1
      need_scroll = true
    end

    if need_scroll then
      M._render_visible()
      if state ~= s then return end
      g = s.grid
      if not g then return end
    end

    -- Place cursor on filename line within the visible buffer
    local cell_h = g.thumb_h + 1
    local cell_w = g.thumb_w + g.pad
    local vis_row = r - s.scroll_offset
    local target_row = vis_row * cell_h + g.thumb_h + 1 -- 1-indexed
    local target_col = c * cell_w + math.floor(cell_w / 2)
    if vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_set_cursor(win, { target_row, target_col })
    end

    M._update_visual()
  end

  local function move(dr, dc)
    local s = state
    if not s then return end
    local g = s.grid
    if not g then return end
    local nr, nc = s.cur_row + dr, s.cur_col + dc
    if nc < 0 then
      nc = g.cols - 1
      nr = nr - 1
    elseif nc >= g.cols then
      nc = 0
      nr = nr + 1
    end
    if nr < 0 or nr >= g.rows then return end
    local idx = nr * g.cols + nc + 1
    if idx > #files then return end
    move_to_cell(nr, nc)
  end

  local kopts = { buffer = buf, nowait = true }

  vim.keymap.set("n", "h", function() move(0, -1) end, kopts)
  vim.keymap.set("n", "l", function() move(0, 1) end, kopts)
  vim.keymap.set("n", "j", function() move(1, 0) end, kopts)
  vim.keymap.set("n", "k", function() move(-1, 0) end, kopts)
  vim.keymap.set("n", "<Left>", function() move(0, -1) end, kopts)
  vim.keymap.set("n", "<Right>", function() move(0, 1) end, kopts)
  vim.keymap.set("n", "<Down>", function() move(1, 0) end, kopts)
  vim.keymap.set("n", "<Up>", function() move(-1, 0) end, kopts)

  vim.keymap.set("n", "<CR>", function()
    ensure_config()
    local s = state
    if not s then return end
    local g = s.grid
    if not g then return end
    local idx = s.cur_row * g.cols + s.cur_col + 1
    if idx > #files then return end
    local cmd = vim.deepcopy(config.open_cmd)
    cmd[#cmd + 1] = files[idx].path
    vim.fn.jobstart(cmd, { detach = true })
    -- Re-render after neovim's screen redraw settles
    vim.defer_fn(function()
      if state == s and vim.api.nvim_win_is_valid(s.win) then
        M._render_visible()
        M._restore_cursor()
      end
    end, 100)
  end, kopts)

  vim.keymap.set("n", "p", function()
    local s = state
    if not s then return end
    local g = s.grid
    if not g then return end
    local idx = s.cur_row * g.cols + s.cur_col + 1
    if idx > #files then return end
    M._preview(files[idx].path)
  end, kopts)

  vim.keymap.set("n", "r", function()
    local s = state
    if not s then return end
    local g = s.grid
    if not g then return end
    local idx = s.cur_row * g.cols + s.cur_col + 1
    if idx > #files then return end
    local file = files[idx]
    local dir = vim.fn.fnamemodify(file.path, ":h")
    vim.ui.input({ prompt = "Rename: ", default = file.name }, function(new_name)
      if state ~= s then return end
      if not new_name or new_name == "" or new_name == file.name then return end
      local new_path = dir .. "/" .. new_name
      if vim.uv.fs_stat(new_path) then
        vim.notify("File already exists: " .. new_name, vim.log.levels.ERROR)
        return
      end
      local ok, err = vim.uv.fs_rename(file.path, new_path)
      if not ok then
        vim.notify("Rename failed: " .. (err or "unknown error"), vim.log.levels.ERROR)
        return
      end
      file.path = new_path
      file.name = new_name
      table.sort(files, function(a, b) return a.name:lower() < b.name:lower() end)
      g = s.grid
      if g then
        for i, f in ipairs(files) do
          if f == file then
            local zero = i - 1
            s.cur_row = math.floor(zero / g.cols)
            s.cur_col = zero % g.cols
            break
          end
        end
      end
      M._render_visible()
      if state == s then
        move_to_cell(s.cur_row, s.cur_col)
      end
    end)
  end, kopts)

  vim.keymap.set("n", "d", function()
    local s = state
    if not s then return end
    local g = s.grid
    if not g then return end
    local idx = s.cur_row * g.cols + s.cur_col + 1
    if idx > #files then return end
    local file = files[idx]
    vim.ui.input({ prompt = "Delete " .. file.name .. "? (y/N): " }, function(answer)
      if state ~= s then return end
      if answer ~= "y" and answer ~= "Y" then return end
      local ok, err = os.remove(file.path)
      if not ok then
        vim.notify("Delete failed: " .. (err or "unknown error"), vim.log.levels.ERROR)
        return
      end
      table.remove(files, idx)
      if #files == 0 then
        M.close()
        vim.notify("Gallery: directory is now empty", vim.log.levels.INFO)
        return
      end
      -- Adjust grid rows and cursor
      g = s.grid
      if not g then return end
      s.grid.rows = math.ceil(#files / g.cols)
      if s.cur_row >= s.grid.rows then
        s.cur_row = s.grid.rows - 1
      end
      if s.cur_row * g.cols + s.cur_col + 1 > #files then
        s.cur_col = (#files - 1) % g.cols
      end
      if s.scroll_offset > 0 and s.scroll_offset + g.visible_rows > s.grid.rows then
        s.scroll_offset = math.max(0, s.grid.rows - g.visible_rows)
      end
      M._render_visible()
      if state == s then
        move_to_cell(s.cur_row, s.cur_col)
      end
    end)
  end, kopts)

  vim.keymap.set("n", "q", function() M.close() end, kopts)
  vim.keymap.set("n", "<Esc>", function() M.close() end, kopts)

  move_to_cell(0, 0)
end

--- Restore cursor to the current cell after re-render
function M._restore_cursor()
  local s = state
  if not s or not s.grid then return end
  if not vim.api.nvim_win_is_valid(s.win) then return end
  if not vim.api.nvim_buf_is_valid(s.buf) then return end
  local g = s.grid
  local cell_h = g.thumb_h + 1
  local cell_w = g.thumb_w + g.pad
  local vis_row = s.cur_row - s.scroll_offset
  local target_row = vis_row * cell_h + g.thumb_h + 1
  local target_col = s.cur_col * cell_w + math.floor(cell_w / 2)
  local line_count = vim.api.nvim_buf_line_count(s.buf)
  target_row = math.max(1, math.min(target_row, line_count))
  local line_len = #(vim.api.nvim_buf_get_lines(s.buf, target_row - 1, target_row, false)[1] or "")
  target_col = math.min(target_col, math.max(0, line_len - 1))
  vim.api.nvim_win_set_cursor(s.win, { target_row, target_col })
end

---@param src string
function M._preview(src)
  ensure_config()
  local preview_buf = vim.api.nvim_create_buf(false, true)
  local width = math.floor(vim.o.columns * config.preview_scale)
  local height = math.floor(vim.o.lines * config.preview_scale)
  local row = math.floor((vim.o.lines - height) / 2)
  local col = math.floor((vim.o.columns - width) / 2)

  local preview_win = vim.api.nvim_open_win(preview_buf, true, {
    relative = "editor",
    width = width,
    height = height,
    row = row,
    col = col,
    style = "minimal",
    border = "rounded",
    title = " " .. vim.fn.fnamemodify(src, ":t") .. " ",
    title_pos = "center",
    zindex = 60,
  })

  vim.bo[preview_buf].filetype = "image"
  vim.bo[preview_buf].modifiable = false
  vim.bo[preview_buf].swapfile = false

  local placement = Snacks.image.placement.new(preview_buf, src, {
    conceal = true,
    auto_resize = true,
  })
  local preview_augroup = vim.api.nvim_create_augroup("snacks-gallery.preview." .. preview_buf, { clear = true })
  local preview_closed = false

  local function close_preview()
    if preview_closed then return end
    preview_closed = true
    local img = placement and placement.img
    pcall(vim.api.nvim_del_augroup_by_id, preview_augroup)
    pcall(Snacks.image.placement.clean, preview_buf)
    if img then img.sent = false end
    if vim.api.nvim_win_is_valid(preview_win) then
      vim.api.nvim_win_close(preview_win, true)
    end
    if vim.api.nvim_buf_is_valid(preview_buf) then
      vim.api.nvim_buf_delete(preview_buf, { force = true })
    end
  end

  vim.api.nvim_create_autocmd("WinClosed", {
    group = preview_augroup,
    pattern = tostring(preview_win),
    once = true,
    callback = close_preview,
  })
  vim.api.nvim_create_autocmd("BufWipeout", {
    group = preview_augroup,
    buffer = preview_buf,
    once = true,
    callback = close_preview,
  })

  vim.keymap.set("n", "q", close_preview, { buffer = preview_buf, nowait = true })
  vim.keymap.set("n", "<Esc>", close_preview, { buffer = preview_buf, nowait = true })
  vim.keymap.set("n", "<CR>", close_preview, { buffer = preview_buf, nowait = true })
end

---@param dir? string
function M.open(dir)
  ensure_config()
  if state then M.close() end

  if not dir then
    if vim.bo.buftype == "terminal" then
      local pid = vim.b.terminal_job_pid
      if pid then
        dir = vim.uv.fs_readlink("/proc/" .. pid .. "/cwd")
      end
    elseif vim.bo.filetype == "snacks_picker_list" then
      local ok, explorers = pcall(function()
        return Snacks.picker.get({ source = "explorer" })
      end)
      if ok and explorers then
        local cur_win = vim.api.nvim_get_current_win()
        local cur_buf = vim.api.nvim_get_current_buf()
        local explorer = nil
        for _, picker in ipairs(explorers) do
          if not picker.closed then
            local list = picker.list and picker.list.win
            local list_win = list and list.win or nil
            local list_buf = list and list.buf or nil
            if list_win == cur_win or list_buf == cur_buf then
              explorer = picker
              break
            end
          end
        end
        if not explorer then
          explorer = explorers[1]
        end
        if explorer and not explorer.closed then
          local item = explorer:current()
          if item and item.file then
            dir = item.dir and item.file or vim.fn.fnamemodify(item.file, ":h")
          end
        end
      end
    end
  end
  dir = dir or vim.fn.getcwd()
  dir = vim.fn.fnamemodify(dir, ":p"):gsub("/$", "")
  if dir == "" then dir = "/" end

  vim.fn.mkdir(config.thumb_cache, "p")

  local files = M._scan(dir)
  if #files == 0 then
    vim.notify("Gallery: no image/video files in " .. dir, vim.log.levels.WARN)
    return
  end

  local buf = vim.api.nvim_create_buf(false, true)
  local width = math.floor(vim.o.columns * config.win_scale)
  local height = math.floor(vim.o.lines * config.win_scale)
  local row = math.floor((vim.o.lines - height) / 2)
  local col = math.floor((vim.o.columns - width) / 2)

  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    width = width,
    height = height,
    row = row,
    col = col,
    style = "minimal",
    border = "rounded",
    title = " Gallery: " .. vim.fn.fnamemodify(dir, ":~") .. " (" .. #files .. ") ",
    title_pos = "center",
    zindex = 50,
  })

  vim.wo[win].wrap = false

  local grid = M._layout(#files, width, height)

  local augroup = vim.api.nvim_create_augroup("snacks-gallery", { clear = true })

  state = {
    buf = buf,
    win = win,
    thumb_wins = {},
    files = files,
    grid = grid,
    dir = dir,
    scroll_offset = 0,
    cur_row = 0,
    cur_col = 0,
    augroup = augroup,
  }

  local function schedule_rerender(s)
    if rerender_timer and not rerender_timer:is_closing() then
      rerender_timer:stop()
      rerender_timer:close()
    end
    rerender_timer = assert(vim.uv.new_timer())
    rerender_timer:start(50, 0, vim.schedule_wrap(function()
      if rerender_timer and not rerender_timer:is_closing() then
        rerender_timer:stop()
        rerender_timer:close()
      end
      rerender_timer = nil
      if state ~= s or not vim.api.nvim_win_is_valid(s.win) then return end
      M._render_visible()
      M._restore_cursor()
    end))
  end

  vim.api.nvim_create_autocmd("VimResized", {
    group = augroup,
    callback = function()
      local s = state
      if not s or not vim.api.nvim_win_is_valid(s.win) then return end

      local new_w = math.floor(vim.o.columns * config.win_scale)
      local new_h = math.floor(vim.o.lines * config.win_scale)
      local old_grid = s.grid
      local old_idx = s.cur_row * old_grid.cols + s.cur_col
      vim.api.nvim_win_set_config(s.win, {
        relative = "editor",
        width = new_w,
        height = new_h,
        row = math.floor((vim.o.lines - new_h) / 2),
        col = math.floor((vim.o.columns - new_w) / 2),
      })

      s.grid = M._layout(#s.files, new_w, new_h)
      -- Remap cursor from old grid to new grid using flat index
      s.cur_row = math.floor(old_idx / s.grid.cols)
      s.cur_col = old_idx % s.grid.cols
      -- Clamp scroll/cursor to new grid dimensions
      if s.cur_row >= s.grid.rows then
        s.cur_row = s.grid.rows - 1
      end
      if s.cur_row * s.grid.cols + s.cur_col + 1 > #s.files then
        s.cur_col = math.max(0, (#s.files - 1) % s.grid.cols)
      end
      if s.scroll_offset + s.grid.visible_rows > s.grid.rows then
        s.scroll_offset = math.max(0, s.grid.rows - s.grid.visible_rows)
      end

      schedule_rerender(s)
    end,
  })
  vim.api.nvim_create_autocmd("FocusGained", {
    group = augroup,
    callback = function()
      local s = state
      if not s or not vim.api.nvim_win_is_valid(s.win) then return end
      schedule_rerender(s)
    end,
  })
  vim.api.nvim_create_autocmd("WinClosed", {
    group = augroup,
    pattern = tostring(win),
    callback = function()
      local s = state
      if s and s.win == win then
        M.close()
      end
    end,
  })
  vim.api.nvim_create_autocmd("BufWipeout", {
    group = augroup,
    buffer = buf,
    callback = function()
      local s = state
      if s and s.buf == buf then
        M.close()
      end
    end,
  })

  M._render_visible()
  M._setup_keys(buf, win, files, grid)
end

function M.close()
  if not state then return end
  local s = state
  state = nil

  if rerender_timer and not rerender_timer:is_closing() then
    rerender_timer:stop()
    rerender_timer:close()
  end
  rerender_timer = nil

  cancel_thumb_jobs(s.thumb_jobs)
  thumb_queue = {}
  pcall(vim.api.nvim_del_augroup_by_id, s.augroup)
  close_thumb_wins(s.thumb_wins)

  if vim.api.nvim_win_is_valid(s.win) then
    vim.api.nvim_win_close(s.win, true)
  end
  if vim.api.nvim_buf_is_valid(s.buf) then
    vim.api.nvim_buf_delete(s.buf, { force = true })
  end
end

return M
