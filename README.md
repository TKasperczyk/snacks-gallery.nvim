# snacks-gallery.nvim

Image and video gallery browser for Neovim. Uses [snacks.nvim](https://github.com/folke/snacks.nvim) for rendering thumbnails via the Kitty Graphics Protocol.

<!-- TODO: screenshot -->

## Requirements

- Neovim >= 0.10
- [snacks.nvim](https://github.com/folke/snacks.nvim) with `image` enabled
- [ImageMagick](https://imagemagick.org/) (`magick` command) for thumbnail generation
- A terminal supporting the Kitty Graphics Protocol (kitty, ghostty, wezterm)

## Installation

### lazy.nvim

```lua
{
  "TKasperczyk/snacks-gallery.nvim",
  dependencies = { "folke/snacks.nvim" },
  opts = {},
  keys = {
    { "<leader>gi", function() require("snacks-gallery").open() end, desc = "Gallery" },
  },
}
```

## Usage

```
:Gallery [dir]
```

Opens a floating gallery window for the given directory. If no directory is provided, the plugin tries to infer one from:
1. The current terminal buffer's working directory
2. The current snacks explorer selection
3. Falls back to `vim.fn.getcwd()`

You can also call it from Lua:

```lua
require("snacks-gallery").open("~/Pictures")
```

## Configuration

```lua
require("snacks-gallery").setup({
  -- File extensions to show in the gallery
  extensions = {
    jpg = true, jpeg = true, png = true, gif = true, bmp = true, webp = true,
    tiff = true, heic = true, avif = true,
    mp4 = true, mkv = true, webm = true, avi = true, mov = true,
  },
  -- Where to store generated thumbnails
  thumb_cache = vim.fn.stdpath("cache") .. "/snacks-gallery-thumbs",
  -- Thumbnail size passed to ImageMagick
  thumb_size = "400x400",
  -- Max concurrent thumbnail generation jobs
  max_workers = 4,
  -- Command to open files externally (Enter key)
  open_cmd = vim.fn.has("mac") == 1 and { "open" } or { "xdg-open" },
  -- Gallery window size as fraction of screen
  win_scale = 0.9,
  -- Preview window size as fraction of screen
  preview_scale = 0.8,
})
```

All options are optional — the defaults work out of the box.

## Directory Browsing

Directories appear as cells in the gallery grid alongside media files. Directory cells show thumbnail previews of the first few images inside them (once cached), or a folder icon placeholder otherwise.

| Key | Action |
|---|---|
| `Enter` | Enter directory |
| `-` / `Backspace` | Go to parent directory |

When navigating back to a parent directory, the cursor is restored to the directory you came from.

## Keybindings

Inside the gallery window:

| Key | Action |
|---|---|
| `h` `j` `k` `l` / arrows | Navigate between thumbnails |
| `Enter` | Open file with system viewer / enter directory |
| `p` | Full-size preview in a floating window |
| `-` / `Backspace` | Go to parent directory |
| `r` | Rename file or directory |
| `d` | Delete file (with confirmation) |
| `q` / `Esc` | Close gallery |

## Highlight Groups

All highlight groups use `default = true` so your colorscheme takes precedence:

| Group | Default link | Purpose |
|---|---|---|
| `GalleryBorder` | `FloatBorder` | Unselected thumbnail border |
| `GalleryBorderSel` | `Special` | Selected thumbnail border |
| `GalleryFilename` | `Comment` | Unselected filename |
| `GalleryFilenameSel` | `Title` | Selected filename |
| `GalleryFooter` | `Comment` | Footer hint text |
| `GalleryFooterKey` | `Special` | Footer keybind letters |
| `GalleryFooterSep` | `FloatBorder` | Footer separator |
| `GalleryFooterVal` | `Normal` | Footer values |
| `GalleryDir` | `Directory` | Directory name label |

## License

MIT
