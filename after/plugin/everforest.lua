local everforest = require("everforest")
  everforest.setup({
    background = "hard",
    transparent_background_level = 1,
    italics = true,
    disable_italic_comments = false,
    on_highlights = function(hl, _)
      hl["@string.special.symbol.ruby"] = { link = "@field" }
    end,
  })
  everforest.load()
