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
  { "GalleryBg",          "Normal" },
  { "GalleryFilename",    "Comment" },
  { "GalleryFilenameSel", "Title" },
  { "GalleryFooter",      "Comment" },
  { "GalleryFooterKey",   "Special" },
  { "GalleryFooterSep",   "FloatBorder" },
  { "GalleryFooterVal",   "Normal" },
}) do
  vim.api.nvim_set_hl(0, def[1], { link = def[2], default = true })
end

-- Border highlights: fg-only (no bg) so border cells inherit GalleryBg
-- from the window's winhighlight. Resolved dynamically from FloatBorder/Special.
local function setup_border_highlights()
  local fb = vim.api.nvim_get_hl(0, { name = "FloatBorder", link = false })
  local sp = vim.api.nvim_get_hl(0, { name = "Special", link = false })
  vim.api.nvim_set_hl(0, "GalleryBorder", { fg = fb.fg, default = true })
  vim.api.nvim_set_hl(0, "GalleryBorderSel", { fg = sp.fg, bold = true, default = true })
end

local thumb_queue = {} ---@type table[]
local thumb_active = 0
local rerender_timer = nil ---@type uv.uv_timer_t?
local reflow_timer = nil ---@type uv.uv_timer_t?

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

local function thumb_cache_path(src)
  ensure_config()
  local stat = vim.uv.fs_stat(src)
  local mtime_sec = stat and stat.mtime.sec or 0
  local mtime_nsec = stat and stat.mtime.nsec or 0
  return config.thumb_cache .. "/" .. vim.fn.sha256(src .. ":" .. mtime_sec .. ":" .. mtime_nsec) .. ".png"
end

---@param thumb_w number
---@param aspect_ratio number
---@return number
local function item_height(thumb_w, aspect_ratio)
  local inner_w = math.max(1, thumb_w - 2)
  if not aspect_ratio or aspect_ratio <= 0 then
    aspect_ratio = 1
  end
  -- Terminal cells are not square (typically ~2:1 height:width).
  -- Convert pixel aspect ratio to cell aspect ratio.
  local terminal = Snacks.image.terminal.size()
  local cell_ratio = terminal.cell_width / terminal.cell_height
  local h = math.floor(inner_w * cell_ratio / aspect_ratio + 0.5)
  return math.max(3, math.min(h, 30)) + 2
end

---@param g table
---@param offset number
---@return number
local function clamp_scroll_offset(g, offset)
  local max_scroll = math.max(0, g.total_h - g.win_h)
  return math.max(0, math.min(offset or 0, max_scroll))
end

---@param g table
---@param scroll_offset number
---@param file_count number
---@return integer[]
local function find_visible_items(g, scroll_offset, file_count)
  local visible = {}
  local view_top = scroll_offset
  local view_bottom = view_top + g.win_h
  for idx = 1, file_count do
    local item = g.items[idx]
    if item then
      local top = item.y
      local bottom = item.y + item.h + 1
      if bottom > view_top and top < view_bottom then
        visible[#visible + 1] = idx
      end
    end
  end
  return visible
end

---@param s table
---@param idx integer
---@return boolean
local function ensure_item_visible(s, idx)
  local g = s.grid
  if not g then return false end
  local item = g.items[idx]
  if not item then return false end
  local view_top = s.scroll_offset
  local view_bottom = view_top + g.win_h
  local top = item.y
  local bottom = item.y + item.h + 1
  local new_offset = view_top
  if (bottom - top) > g.win_h then
    new_offset = top
  elseif top < view_top then
    new_offset = top
  elseif bottom > view_bottom then
    new_offset = bottom - g.win_h
  end
  new_offset = clamp_scroll_offset(g, new_offset)
  if new_offset ~= s.scroll_offset then
    s.scroll_offset = new_offset
    return true
  end
  return false
end

---@param s table
---@param idx integer
---@return integer, integer
local function cursor_pos_for_idx(s, idx)
  local g = s.grid
  local item = g and g.items[idx]
  if not g or not item then return 1, 0 end
  local row = item.y + item.h - s.scroll_offset + 1
  local col = item.col * (g.thumb_w + g.pad) + math.floor(g.thumb_w / 2)
  return row, col
end

---@param file_count number
---@param win_w number
---@param win_h number
---@param files? {path: string, name: string}[]
function M._layout(file_count, win_w, win_h, files)
  local pad = 2
  local thumb_w = math.max(15, math.min(30, math.floor((win_w - pad) / 3) - pad))
  local cols = math.max(1, math.floor((win_w + pad) / (thumb_w + pad)))
  thumb_w = math.max(7, math.floor((win_w - pad * (cols - 1)) / cols))
  local win_h_cells = math.max(1, win_h)

  files = files or (state and state.files) or {}
  local count = math.min(file_count or #files, #files)

  local items = {}
  local col_heights = {}
  local col_items = {}
  local item_pos = {}
  local total_h = 0
  for col = 0, cols - 1 do
    col_heights[col] = 0
    col_items[col] = {}
  end

  for idx = 1, count do
    local file = files[idx]
    local aspect_ratio = 1
    local estimated = true
    if file and file.path then
      local cached = thumb_cache_path(file.path)
      if vim.uv.fs_stat(cached) then
        local ok, dim = pcall(Snacks.image.util.dim, cached)
        if ok and type(dim) == "table" then
          local w = tonumber(dim.width)
          local h = tonumber(dim.height)
          if w and h and w > 0 and h > 0 then
            aspect_ratio = w / h
            estimated = false
          end
        end
      end
    end

    local best_col = 0
    local best_h = col_heights[0] or 0
    for col = 1, cols - 1 do
      local h = col_heights[col]
      if h < best_h then
        best_h = h
        best_col = col
      end
    end

    local h = item_height(thumb_w, aspect_ratio)
    local y = col_heights[best_col]
    items[idx] = {
      col = best_col,
      y = y,
      h = h,
      estimated = estimated,
    }

    col_heights[best_col] = y + h + 1
    total_h = math.max(total_h, col_heights[best_col])
    local col_list = col_items[best_col]
    col_list[#col_list + 1] = idx
    item_pos[idx] = #col_list
  end

  return {
    thumb_w = thumb_w,
    cols = cols,
    pad = pad,
    items = items,
    col_heights = col_heights,
    col_items = col_items,
    item_pos = item_pos,
    total_h = math.max(total_h, 1),
    win_h = win_h_cells,
  }
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

  local sel_idx = math.max(1, math.min(s.cur_idx or 1, #s.files))
  s.cur_idx = sel_idx

  -- 1. Update winhighlight on each thumbnail window
  for _, tw in ipairs(s.thumb_wins or {}) do
    if tw and vim.api.nvim_win_is_valid(tw.win) then
      local border_hl = tw.idx == sel_idx and "GalleryBorderSel" or "GalleryBorder"
      vim.wo[tw.win].winhighlight = "Normal:GalleryBg,NormalFloat:GalleryBg,FloatBorder:" .. border_hl
    end
  end

  -- 2. Clear namespace and re-add filename extmarks
  vim.api.nvim_buf_clear_namespace(s.buf, ns, 0, -1)
  local visible = s.visible_items or find_visible_items(g, s.scroll_offset, #s.files)
  for _, idx in ipairs(visible) do
    local item = g.items[idx]
    local file = s.files[idx]
    if item and file then
      local fname_line = item.y + item.h - s.scroll_offset
      if fname_line >= 0 and fname_line < g.win_h then
        local line = vim.api.nvim_buf_get_lines(s.buf, fname_line, fname_line + 1, false)[1]
        if line then
          local name = file.name
          while vim.api.nvim_strwidth(name) > g.thumb_w and vim.fn.strchars(name) > 0 do
            name = vim.fn.strcharpart(name, 0, vim.fn.strchars(name) - 1)
          end
          if name ~= file.name and g.thumb_w > 0 then
            if vim.api.nvim_strwidth(name) >= g.thumb_w then
              name = vim.fn.strcharpart(name, 0, math.max(0, vim.fn.strchars(name) - 1))
            end
            name = name .. "…"
          end

          local col_start = item.col * (g.thumb_w + g.pad)
          local total_pad = g.thumb_w - vim.api.nvim_strwidth(name)
          local left_pad = math.floor(math.max(0, total_pad) / 2)
          local name_start = col_start + left_pad
          local name_end = math.min(name_start + #name, #line)
          if name_end > name_start then
            local hl = idx == sel_idx and "GalleryFilenameSel" or "GalleryFilename"
            vim.api.nvim_buf_set_extmark(s.buf, ns, fname_line, name_start, {
              end_col = name_end,
              hl_group = hl,
            })
          end
        end
      end
    end
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
  if not grid then return end
  if not vim.api.nvim_win_is_valid(s.win) then return end
  if not vim.api.nvim_buf_is_valid(s.buf) then return end

  grid.win_h = vim.api.nvim_win_get_height(s.win)
  s.scroll_offset = clamp_scroll_offset(grid, s.scroll_offset)
  local files = s.files
  local cell_w = grid.thumb_w + grid.pad

  -- Cancel pending thumbnail jobs and tear down old thumbnails
  cancel_thumb_jobs(s.thumb_jobs)
  thumb_queue = {}
  close_thumb_wins(s.thumb_wins)
  s.thumb_wins = {}
  s.thumb_jobs = {}

  local visible = find_visible_items(grid, s.scroll_offset, #files)
  s.visible_items = visible

  -- Build a viewport-sized backing buffer and place filenames at item-specific rows.
  local total_w = math.max(1, grid.cols * cell_w - grid.pad)
  local blank = string.rep(" ", total_w)
  local lines = {}
  for _ = 1, grid.win_h do
    lines[#lines + 1] = blank
  end

  for _, idx in ipairs(visible) do
    local item = grid.items[idx]
    local file = files[idx]
    if item and file then
      local line_idx = item.y + item.h - s.scroll_offset
      if line_idx >= 0 and line_idx < grid.win_h then
        local name = file.name
        while vim.api.nvim_strwidth(name) > grid.thumb_w and vim.fn.strchars(name) > 0 do
          name = vim.fn.strcharpart(name, 0, vim.fn.strchars(name) - 1)
        end
        if name ~= file.name and grid.thumb_w > 0 then
          if vim.api.nvim_strwidth(name) >= grid.thumb_w then
            name = vim.fn.strcharpart(name, 0, math.max(0, vim.fn.strchars(name) - 1))
          end
          name = name .. "…"
        end

        local total_pad = grid.thumb_w - vim.api.nvim_strwidth(name)
        local left_pad = math.floor(math.max(0, total_pad) / 2)
        local col_start = item.col * cell_w + left_pad
        local line = lines[line_idx + 1]
        if line and col_start < #line then
          local text = name
          local max_len = #line - col_start
          if max_len > 0 then
            if #text > max_len then
              text = text:sub(1, max_len)
            end
            lines[line_idx + 1] = line:sub(1, col_start) .. text .. line:sub(col_start + #text + 1)
          end
        end
      end
    end
  end

  vim.bo[s.buf].modifiable = true
  vim.api.nvim_buf_set_lines(s.buf, 0, -1, false, lines)
  vim.bo[s.buf].modifiable = false

  -- Create thumbnail windows for visible items, clipped to viewport.
  for _, idx in ipairs(visible) do
    local item = grid.items[idx]
    local file = files[idx]
    if item and file then
      local win_row = item.y - s.scroll_offset

      -- Skip items that start above the viewport (can't crop from top)
      if win_row < 0 then goto next_thumb end

      -- Clip items that extend past the bottom of the viewport
      local avail_h = grid.win_h - win_row
      local display_h = math.min(item.h, avail_h)
      local inner_h = display_h - 2 -- subtract border
      if inner_h < 1 then goto next_thumb end

      do
        local thumb_buf = vim.api.nvim_create_buf(false, true)
        local ok, thumb_win = pcall(vim.api.nvim_open_win, thumb_buf, false, {
          relative = "win",
          win = s.win,
          row = win_row,
          col = item.col * cell_w,
          width = grid.thumb_w - 2,
          height = inner_h,
          style = "minimal",
          border = "rounded",
          focusable = false,
          zindex = 51,
        })
        if ok then
          vim.bo[thumb_buf].filetype = "image"
          vim.bo[thumb_buf].modifiable = false
          vim.bo[thumb_buf].swapfile = false
          vim.wo[thumb_win].winhighlight = "Normal:GalleryBg,NormalFloat:GalleryBg"

          local tw = { buf = thumb_buf, win = thumb_win, placement = nil, idx = idx }
          s.thumb_wins[#s.thumb_wins + 1] = tw

          local function attach_thumb(thumb_path)
            if state ~= s then return end
            if not vim.api.nvim_buf_is_valid(thumb_buf) then return end
            if not vim.api.nvim_win_is_valid(thumb_win) then return end
            tw.placement = Snacks.image.placement.new(thumb_buf, thumb_path, {
              conceal = true,
              auto_resize = true,
            })

            -- Mark item for reflow if actual dimensions differ from estimate
            local current_grid = s.grid
            local current_item = current_grid and current_grid.items[idx]
            if not current_item or not current_item.estimated then return end
            local ok_dim, dim = pcall(Snacks.image.util.dim, thumb_path)
            if not ok_dim or type(dim) ~= "table" then return end
            local w = tonumber(dim.width)
            local h = tonumber(dim.height)
            if not w or not h or w <= 0 or h <= 0 then return end
            local new_h = item_height(current_grid.thumb_w, w / h)
            if new_h ~= current_item.h then
              s.needs_reflow = true
              -- Debounce: wait for more thumbnails to arrive before reflowing
              if reflow_timer and not reflow_timer:is_closing() then
                reflow_timer:stop()
                reflow_timer:close()
              end
              reflow_timer = assert(vim.uv.new_timer())
              reflow_timer:start(1000, 0, vim.schedule_wrap(function()
                if reflow_timer and not reflow_timer:is_closing() then
                  reflow_timer:stop()
                  reflow_timer:close()
                end
                reflow_timer = nil
                if state ~= s or not s.needs_reflow then return end
                if not vim.api.nvim_win_is_valid(s.win) then return end
                s.needs_reflow = false
                local win_w = vim.api.nvim_win_get_width(s.win)
                local win_h = vim.api.nvim_win_get_height(s.win)
                s.grid = M._layout(#s.files, win_w, win_h, s.files)
                s.scroll_offset = clamp_scroll_offset(s.grid, s.scroll_offset)
                ensure_item_visible(s, s.cur_idx)
                M._render_visible()
                if state == s then
                  M._restore_cursor()
                end
              end))
            end
          end

          local cached = thumb_cache_path(file.path)
          if vim.uv.fs_stat(cached) then
            attach_thumb(cached)
          else
            local job = { src = file.path, callback = attach_thumb, cancelled = false, proc = nil }
            s.thumb_jobs[#s.thumb_jobs + 1] = job
            thumb_queue[#thumb_queue + 1] = job
          end
        else
          if vim.api.nvim_buf_is_valid(thumb_buf) then
            vim.api.nvim_buf_delete(thumb_buf, { force = true })
          end
        end
      end -- do
    end
    ::next_thumb::
  end

  -- Start processing queued thumbnail jobs
  process_thumb_queue()

  -- Pin the view to top — buffer only contains visible content
  vim.api.nvim_win_call(s.win, function()
    vim.fn.winrestview({ topline = 1, leftcol = 0 })
  end)

  M._update_visual()
end

function M._setup_keys(buf, win, files, _grid)
  local function move_to_idx(idx)
    local s = state
    if not s then return end
    local g = s.grid
    if not g or #files == 0 then return end
    idx = math.max(1, math.min(idx, #files))
    if not g.items[idx] then return end
    s.cur_idx = idx

    if ensure_item_visible(s, idx) then
      M._render_visible()
      if state ~= s then return end
      g = s.grid
      if not g then return end
    end

    local target_row, target_col = cursor_pos_for_idx(s, idx)
    local line_count = vim.api.nvim_buf_line_count(s.buf)
    target_row = math.max(1, math.min(target_row, line_count))
    local line = vim.api.nvim_buf_get_lines(s.buf, target_row - 1, target_row, false)[1] or ""
    target_col = math.max(0, math.min(target_col, math.max(0, #line - 1)))
    if vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_set_cursor(win, { target_row, target_col })
    end

    M._update_visual()
  end

  local function move_vertical(step)
    local s = state
    if not s then return end
    local g = s.grid
    if not g then return end
    local item = g.items[s.cur_idx]
    if not item then return end
    local col_list = g.col_items[item.col] or {}
    local pos = g.item_pos[s.cur_idx]
    if not pos then return end
    local target = col_list[pos + step]
    if target then
      move_to_idx(target)
    end
  end

  local function move_horizontal(delta)
    local s = state
    if not s then return end
    local g = s.grid
    if not g then return end
    local item = g.items[s.cur_idx]
    if not item then return end
    local target_col = item.col + delta
    if target_col < 0 or target_col >= g.cols then return end
    local col_list = g.col_items[target_col] or {}
    if #col_list == 0 then return end

    local center = item.y + item.h / 2
    local best_idx = nil
    local best_dist = math.huge
    for _, idx in ipairs(col_list) do
      local other = g.items[idx]
      if other then
        local dist = math.abs((other.y + other.h / 2) - center)
        if dist < best_dist then
          best_dist = dist
          best_idx = idx
        end
      end
    end
    if best_idx then
      move_to_idx(best_idx)
    end
  end

  local kopts = { buffer = buf, nowait = true }

  vim.keymap.set("n", "h", function() move_horizontal(-1) end, kopts)
  vim.keymap.set("n", "l", function() move_horizontal(1) end, kopts)
  vim.keymap.set("n", "j", function() move_vertical(1) end, kopts)
  vim.keymap.set("n", "k", function() move_vertical(-1) end, kopts)
  vim.keymap.set("n", "<Left>", function() move_horizontal(-1) end, kopts)
  vim.keymap.set("n", "<Right>", function() move_horizontal(1) end, kopts)
  vim.keymap.set("n", "<Down>", function() move_vertical(1) end, kopts)
  vim.keymap.set("n", "<Up>", function() move_vertical(-1) end, kopts)

  vim.keymap.set("n", "<CR>", function()
    ensure_config()
    local s = state
    if not s then return end
    local idx = s.cur_idx
    if not idx or idx > #files then return end
    local cmd = vim.deepcopy(config.open_cmd)
    cmd[#cmd + 1] = files[idx].path
    vim.fn.jobstart(cmd, { detach = true })
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
    local idx = s.cur_idx
    if not idx or idx > #files then return end
    M._preview(files[idx].path)
  end, kopts)

  vim.keymap.set("n", "r", function()
    local s = state
    if not s then return end
    local idx = s.cur_idx
    if not idx or idx > #files then return end
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
      for i, f in ipairs(files) do
        if f == file then
          s.cur_idx = i
          break
        end
      end
      if not vim.api.nvim_win_is_valid(s.win) then return end
      local win_w = vim.api.nvim_win_get_width(s.win)
      local win_h = vim.api.nvim_win_get_height(s.win)
      s.grid = M._layout(#files, win_w, win_h, files)
      s.scroll_offset = clamp_scroll_offset(s.grid, s.scroll_offset)
      ensure_item_visible(s, s.cur_idx)
      M._render_visible()
      if state == s then
        move_to_idx(s.cur_idx)
      end
    end)
  end, kopts)

  vim.keymap.set("n", "d", function()
    local s = state
    if not s then return end
    local idx = s.cur_idx
    if not idx or idx > #files then return end
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
      s.cur_idx = math.min(idx, #files)
      if not vim.api.nvim_win_is_valid(s.win) then return end
      local win_w = vim.api.nvim_win_get_width(s.win)
      local win_h = vim.api.nvim_win_get_height(s.win)
      s.grid = M._layout(#files, win_w, win_h, files)
      s.scroll_offset = clamp_scroll_offset(s.grid, s.scroll_offset)
      ensure_item_visible(s, s.cur_idx)
      M._render_visible()
      if state == s then
        move_to_idx(s.cur_idx)
      end
    end)
  end, kopts)

  vim.keymap.set("n", "q", function() M.close() end, kopts)
  vim.keymap.set("n", "<Esc>", function() M.close() end, kopts)

  move_to_idx((state and state.cur_idx) or 1)
end

--- Restore cursor to the current cell after re-render
function M._restore_cursor()
  local s = state
  if not s or not s.grid then return end
  if not vim.api.nvim_win_is_valid(s.win) then return end
  if not vim.api.nvim_buf_is_valid(s.buf) then return end
  local g = s.grid
  local idx = math.max(1, math.min(s.cur_idx or 1, #s.files))
  s.cur_idx = idx
  if ensure_item_visible(s, idx) then
    M._render_visible()
    if state ~= s then return end
    g = s.grid
    if not g then return end
  end
  local target_row, target_col = cursor_pos_for_idx(s, idx)
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
  setup_border_highlights()
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
  vim.wo[win].winhighlight = "Normal:GalleryBg,NormalFloat:GalleryBg"

  local grid = M._layout(#files, width, height, files)

  local augroup = vim.api.nvim_create_augroup("snacks-gallery", { clear = true })

  state = {
    buf = buf,
    win = win,
    thumb_wins = {},
    files = files,
    grid = grid,
    dir = dir,
    scroll_offset = 0,
    cur_idx = 1,
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
      vim.api.nvim_win_set_config(s.win, {
        relative = "editor",
        width = new_w,
        height = new_h,
        row = math.floor((vim.o.lines - new_h) / 2),
        col = math.floor((vim.o.columns - new_w) / 2),
      })

      s.grid = M._layout(#s.files, new_w, new_h, s.files)
      s.cur_idx = math.max(1, math.min(s.cur_idx or 1, #s.files))
      s.scroll_offset = clamp_scroll_offset(s.grid, s.scroll_offset)
      ensure_item_visible(s, s.cur_idx)

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
  if reflow_timer and not reflow_timer:is_closing() then
    reflow_timer:stop()
    reflow_timer:close()
  end
  reflow_timer = nil

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
