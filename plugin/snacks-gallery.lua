vim.api.nvim_create_user_command("Gallery", function(opts)
  require("snacks-gallery").open(opts.fargs[1])
end, {
  nargs = "?",
  complete = "dir",
  desc = "Open image/video gallery",
})
