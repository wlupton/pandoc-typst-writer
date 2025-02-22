-- A custom Pandoc Typst writer.
-- Louis Vignoli
-- https://github.com/lvignoli/typst-pandoc

-- Modified by William Lupton (intended only for testing)

-- Imports
-- This module is provided in Pandoc embedded Lua runtime.

local pandoc = require "pandoc"

local script_dir = require("pandoc.path").directory(PANDOC_SCRIPT_FILE)
package.path = string.format("%s/?.lua;%s/../?.lua;%s/../scripts/?.lua;%s",
                             script_dir, script_dir, script_dir, package.path)

local logging = require "logging"
local warning = logging.warning
local temp = logging.temp

-- Known classes. These classes will be wrapped as function calls by inline_wrap()
-- and block_wrap(), and must be defined in typst-template.typ (otherwise Typst
-- compilation will fail)
local known_classes = pandoc.List{
    "bbf-acknowledgments",
    "bbf-annex1",
    "bbf-annex2",
    "bbf-annex3",
    "bbf-annex4",
    "bbf-annex5",
    "bbf-annex6",
    "bbf-annex",
    "bbf-appendix1",
    "bbf-appendix2",
    "bbf-appendix3",
    "bbf-appendix4",
    "bbf-appendix5",
    "bbf-appendix6",
    "bbf-appendix",
    "bbf-boldfirst",
    "bbf-borderless",
    "bbf-bug",
    "bbf-clear",
    "bbf-code",
    "bbf-csl-bib-body",
    "bbf-csl-entry",
    "bbf-csl-left-margin",
    "bbf-csl-right-inline",
    "bbf-ebnf",
    "bbf-editors",
    "bbf-emphasis",
    "bbf-gray",
    "bbf-hidden",
    "bbf-issue-history",
    "bbf-left",
    "bbf-new-file",
    "bbf-new-page",
    "bbf-nobreak",
    "bbf-nocase",
    "bbf-nosidelines",
    "bbf-note",
    "bbf-psls",
    "bbf-release",
    "bbf-references",
    "bbf-requirements-table",
    "bbf-revision-history",
    "bbf-right",
    "bbf-same-file",
    "bbf-same-section",
    "bbf-see-also",
    "bbf-spacer",
    "bbf-table-blue",
    "bbf-table-command",
    "bbf-table-object",
    "bbf-table-red",
    "bbf-table-right",
    "bbf-tip",
    "bbf-wads"
}

-- Writer options: extensions
Extensions = {
    citations = false
}

-- Default template
Template = function()
    return pandoc.template.default("typst")
end

-- For better performance we put these functions in local variables:

local layout = pandoc.layout

local blankline = layout.blankline
local brackets = layout.brackets
local chomp = layout.chomp
local concat = layout.concat
local cr = layout.cr
local double_quotes = layout.double_quotes
local empty = layout.empty
local hang = layout.hang
local inside = layout.inside
local literal = layout.literal
local nest = layout.nest
local nowrap = layout.nowrap
local parens = layout.parens
local prefixed = layout.prefixed
local space = layout.space
local to_roman = pandoc.utils.to_roman_numeral
local stringify = pandoc.utils.stringify

-- Other constants
-- XXX should allow some of these to be overridden by metadata
local ESCAPE_EXTRA_CHARS = "/=%[%]-" -- if this includes "-", it must come last
local ESCAPE_PATTERN = "[" .. "#$\\'\"`_*@<~" .. ESCAPE_EXTRA_CHARS .. "]"
local TAB_SIZE = 2 -- Default indent size for generated Typst code
local BLOCKQUOTE_BOX_RELATIVE_WIDTH = "97%"
local IMAGE_DEFAULT_SCALE = 1.0
local TABLE_HEADER_FILL = "white.darken(10%)"
local TABLE_EVEN_FILL = "red.lighten(98%)"

-- Default header block.
-- XXX need to review naming and location
local HEADERS_DEFAULT = string.format([[
// This header block can be overridden by the typst-headers metadata variable.

#let bbf-table-fill(columns: none, header-rows: 1, x, y) = {
  if header-rows > 0 and y == 0 {%s}
  // XXX have disabled fill for even rows
  // else if calc.even(x) {%s}
}

// scale = 1 will size the image at 1px = 1pt
#let bbf-image-scale = 1
#let bbf-image(scale: bbf-image-scale, ..args) = context {
  let named = args.named()
  if "width" in named or "height" in named {
    image(..args)
  } else {
    let (width, height) = measure(image(..args))
    layout(page => {
      // XXX should allow control over this hard-coded (1.0, 0.9)
      let (max_width, max_height) = (1.0 * page.width, 0.9 * page.height)
      let (new_width, new_height) = (scale * width, scale * height)
      if new_width > max_width {
        let width_scale = max_width / new_width
        new_width *= width_scale // so it's now max_width
        new_height *= width_scale
      }
      if new_height > max_height {
        let height_scale = max_height / new_height
        new_width *= height_scale
        new_height *= height_scale // so it's now max_height
      }
      image(..args, width: new_width, height: new_height)
    })
  }
}
]], TABLE_HEADER_FILL, TABLE_EVEN_FILL)

-- Writer is the custom writer that Pandoc will use.
-- We scaffold it from Pandoc.
Writer = pandoc.scaffolding.Writer

local inlines = Writer.Inlines
-- local blocks = Writer.Blocks

local blocks = function(blks)
    local function render_blk(blk)
        -- return concat { '{{', blk.tag, '|', Writer.Block(blk), '}}', cr }
        return concat { Writer.Block(blk), cr }
    end
    return concat(blks:map(render_blk))
end

-- escape escapes reserved Typst markup character with a backslash.
-- XXX some of these need to be context-dependent, e.g. "/" and "-",
--     which can end up at the beginning of a line after wrapping
--     (better not to allow wrapping to result in this than to escape)
-- XXX this is currently only called for single characters; see the .Str()
--     function for escaping of comments
local escape = function(s)
    return (s:gsub(ESCAPE_PATTERN, function(x) return "\\" .. x end))
end

-- array converts a list into a Typst array literal
local array = function(list)
    list = list or {}
    return "(" .. table.concat(list, ", ") .. ")"
end

-- command returns a doc of the form "cmd" "("? cr "a: b", cr "c:d" ")"?
-- opts is a list of (name, value) pairs
-- noterm indicates whether not to add the terminating ")"
local command = function(cmd, opts, sep, noterm)
    opts = opts or {}
    sep = sep or cr
    local comps = pandoc.List()
    local first = true
    for i, nv in ipairs(opts) do
        local name, value = table.unpack(nv)
        if value ~= nil then
            if first then
                comps:insert("(")
            end
            if not first then
                comps:insert(",")
            end
            if not first or sep == cr then
                comps:insert(sep)
            end
            if not name then
                comps:insert(value)
            else
                comps:insert(hang(value, TAB_SIZE, concat {name, ":", space}))
            end
            first = false
        end
    end
    if not first and not noterm then
        comps:insert(")")
    end
    return hang(concat(comps), TAB_SIZE, cmd)
end

-- labels parses attrs to return labels
-- XXX temporarily returns {identifier, classes, attributes} table, roughly
--     like the original pandoc Attr object
local labels = function(attr, filter_names, element_name, prefix)
    filter_names = filter_names or {}
    element_name = element_name or "element"
    prefix = prefix or "bbf-"

    -- this can be called with labs from a previous call, in
    -- which case just return them
    if pandoc.utils.type(attr) ~= "Attr" then
        return (attr or {identifier=nil, classes=pandoc.List(),
                         attributes={}}), pandoc.List()
    end

    -- helper to check whether a name matches the filter
    local matches_filter = function(name, quiet)
        for _, filter_name in ipairs(filter_names) do
            if filter_name == name then
                return true
            end
        end
        if not quiet then
            warning("unsupported", element_name, "attribute", name)
        end
        return false
    end

    local labs = {identifier=nil, classes=pandoc.List(), attributes={}}
    local filtered = {}
    if attr then
        if #attr.identifier > 0 then
            labs.identifier = attr.identifier
        end
        for _, class in ipairs(attr.classes) do
            -- allow the class already to have the prefix
            local pref = class:sub(1, #prefix) == prefix and "" or prefix
            if matches_filter(class, true) then
                -- note that this is a string
                filtered[class] = "true"
            elseif not known_classes:includes(pref .. class) then
                warning("unsupported", element_name, "class", class)
            else
                labs.classes:insert(pref .. class)
            end
        end
        for name, value in pairs(attr.attributes) do
            if matches_filter(name) then
                filtered[name] = value
            else
                labs.attributes[prefix .. name] = value
            end
        end
    end
    return labs, filtered
end

-- XXX should combine the two wrap functions, with optional args or styles

-- inline_wrap wraps a doc in a call to cmd using Typst content inlines syntax.
-- Namely
-- cmd[doc]
-- Any additional # in cmd is the caller responsibility.
local inline_wrap = function(doc, cmd, attr_or_labs)
    local labs = labels(attr_or_labs)

    local cmd_is_class = not cmd and labs.classes and labs.classes[1]

    cmd = cmd_is_class and "#" .. labs.classes[1] or cmd or "#"
    doc = doc and concat { cmd, "[", doc, "]" } or cmd

    if labs.identifier then
        doc = concat { doc, "<", labs.identifier, ">"}
    end

    for i, class in ipairs(labs.classes) do
        if not (i == 1 and cmd_is_class) then
            doc = concat { "#", class, "[", doc, "]" }
        end
    end

    for name, value in pairs(labs.attributes) do
        -- XXX value might already contain double quotes
        doc = concat { "#", name, "(", "[", doc, "]", ', "', value, '")' }
    end

    return doc
end

-- block_wrap wraps a doc in a call to cmd using Typst content blocks syntax.
-- Namely
-- cmd[
--   doc
-- ]
-- Any additional # in cmd is the caller responsibility.
local block_wrap = function(doc, cmd, attr_or_labs, indent)
    indent = indent or TAB_SIZE
    local labs = labels(attr_or_labs)

    local cmd_is_class = not cmd and labs.classes and labs.classes[1]

    cmd = cmd_is_class and "#" .. labs.classes[1] or cmd or "#"
    doc = doc and concat { cmd, "[", cr, nest(doc, indent), cr, "]" } or cmd

    if labs.identifier then
        doc = concat { doc, space, "<", labs.identifier, ">"}
    end

    for i, class in ipairs(labs.classes) do
        if not (i == 1 and cmd_is_class) then
            doc = concat { "#", class, "[", cr, doc, "]" }
        end
    end

    for name, value in pairs(labs.attributes) do
        -- XXX value might already contain double quotes
        doc = concat { "#", name, "[", cr, doc, ', "', value, '"]' }
    end

    return doc
end

-- whether a div contains any raw blocks
local anyraw = false

-- notes (populated by Writer.Inline.Note)
local notes = pandoc.List()

-- XXX this is probably temporary; header-includes (apparently) can't be
--     used in a defaults file (even when presented as a raw block)
Writer.Pandoc = function(doc, opts)
    -- convert the metadata to a pandoc context object
    local vars = pandoc.template.meta_to_context(doc.meta, blocks, inlines)

    for name, value in pairs(vars) do
        local mval = doc.meta[name]

        -- XXX meta_to_context() appears to replace Lists with tables, which
        --     confuses template expansion (e.g. author gets expanded even if
        --     not defined), so set empty lists to nil
        if pandoc.utils.type(mval) == "List" and #mval == 0 then
            -- temp("nilled", name, value)
            vars[name] = nil
        end

        -- XXX if escaping hyphens, all metadata strings will have been
        --     escaped, which can break the "template" variable (and others?)
        if name == "template" then
            -- temp("unescaped", name, value)
            vars[name] = tostring(value):gsub("\\", "")
        end
    end

    -- the ToC is currently hard-coded via the typst-reorder.lua filter, so
    -- explicitly set it to false here (rather than setting it to
    -- opts.table_of_contents)
    vars.toc = false

    -- copy all "simple" (non-table) variables to an "info" variable (which
    -- the pandoc template can make available to the Typst template)
    if vars["info"] then
        warning("info variable already exists, so won't overwrite it")
    else
        vars.info = {}
        for name, value in pairs(vars) do
            if name ~= "info" then
                local mval = doc.meta[name]
                local mtyp = pandoc.utils.type(mval)
                local vtyp = pandoc.utils.type(value)
                if mtyp == "table" or vtyp == "table" then
                    -- temp("ignored", name, mtyp, mval, vtyp, value)
                else
                    -- temp("added", name, mtyp, mval, vtyp, value)
                    vars.info[name] = value
                end
            end
        end
    end

    -- collect the "typst-headers" metadata value as raw blocks
    -- (these are inserted at the beginning of the document)
    local headers = doc.meta["typst-headers"] or HEADERS_DEFAULT
    local raw_blocks = pandoc.List()
    if type(headers) == "table" then
        for _, header in ipairs(headers) do
            raw_blocks:insert(pandoc.RawBlock("typst", stringify(header)))
        end
    elseif headers then
        raw_blocks:insert(1, pandoc.RawBlock("typst", stringify(headers)))
    end

    -- generate the output document
    local document = blocks(raw_blocks .. doc.blocks)

    -- collect endnotes
    -- XXX oops; I forgot about #footnote()! see Writer.Inline.Note
    local endnotes = empty
    if #notes > 0 then
        local comps = pandoc.List()
        comps:insert(concat { blankline, Writer.Block.HorizontalRule() })
        for num, note in ipairs(notes) do
            local cmd_opts = {
                {nil, num},
                {nil, block_wrap(blocks(note.content), "")}}
            local note_cmd = command("#endnote", cmd_opts, space)
            comps:insert(concat { cr, note_cmd })
        end
        endnotes = concat(comps)
    end

    -- note that the possibly-modified vars are returned
    return concat { document, endnotes }, vars
end

-- XXX is this needed?
Writer.Block.Null = function(e)
    warning("unexpected (and undocumented) null element")
    return empty
end

Writer.Block.Plain = function(el)
    return inlines(el.content)
end

Writer.Block.Para = function(para)
    return concat { inlines(para.content), blankline }
end

Writer.Block.Header = function(hdr)
    local labs, opts = labels(hdr.attr, {"unlisted", "unnumbered"}, "header")

    local content = inlines(hdr.content)
    local heading
    if not next(opts) then
        local hdg_cmd = concat { ("="):rep(hdr.level), space, content }
        heading = block_wrap(nil, hdg_cmd, labs)
    else
        local cmd_opts = {
            {"level", hdr.level},
            {"outlined", opts.unlisted and "false" or "true"}}
        local hdg_cmd = command("#heading", cmd_opts, space)
        heading = block_wrap(content, hdg_cmd, labs)
    end
    heading = nowrap(heading)
    return concat { blankline, heading, blankline }
end

Writer.Block.BulletList = function(e)
    local function render_item(item)
        return concat { hang(blocks(item), TAB_SIZE, "- "), cr } -- hang allows to indent nested list properly
    end
    return e.content:map(render_item)
end

Writer.Block.OrderedList = function(e)
    local function render_item(item)
        return hang(blocks(item, blankline), TAB_SIZE, "+ ")
    end

    local sep = cr
    return concat(e.content:map(render_item), sep)
end

Writer.Block.DefinitionList = function(e)
    local function render_term(term)
        return concat { concat { "/", space, inlines(term), ":" } }
    end
    local function render_definition(def)
        -- XXX if def starts with (or contains) a Plain then should attempt
        --     to create a compact list?
        return concat { space, nest(blocks(def), TAB_SIZE), blankline }
    end
    local function render_item(item)
        local term, definitions = table.unpack(item)
        local inner = concat(definitions:map(render_definition))
        return concat { render_term(term), inner }
    end

    return concat(e.content:map(render_item), cr)
end

Writer.Block.CodeBlock = function(code)
    -- this might be passed a RawBlock
    local lang = code.classes and #code.classes > 0 and code.classes[1] or
        code.format or nil
    if not code.text:match("``") then
        return { "```", lang or "", cr, code.text, cr, "```" }
    else
        -- don't use command() because it would indent the second and
        -- subsequent lines of text
        local comps = pandoc.List()
        comps:insert(concat { "#raw(", cr })
        comps:insert(concat { "  block: true,", cr })
        if lang then
            comps:insert(concat { "  lang: ", double_quotes(lang), "," })
        end
        -- double_quotes() doesn't escape double quotes
        local text = code.text:gsub('"', function(x) return "\\" .. x end)
        comps:insert(concat { "  ", double_quotes(text), ")" })
        return comps
    end
end

Writer.Block.BlockQuote = function(e)
    -- Since there is no dedicated Typst markup, we retain the popular
    -- blockquote rendering of having an indented block in dimmed font with a
    -- light vertical ruler on the left.

    local indent = "#h(1fr)" -- filler space that pushes the box to the right
    local style = '#set text(style: "italic", fill: gray.darken(10%))'
    local citation = concat { style, cr, blocks(e.content), blankline }

    -- The choice of having a relative indent rather than an absolute one is debatable.
    -- It works well with current Typst default page layout.
    local box_cmd = string.format("#box(width: %s)", BLOCKQUOTE_BOX_RELATIVE_WIDTH)
    local box = concat { indent, cr, block_wrap(citation, box_cmd) }

    local stacked_content = block_wrap(box, "#stack(dir: ltr)")

    local rect_cmd = "#rect(stroke: (left:2pt+silver))"
    local result = block_wrap(stacked_content, rect_cmd)

    return result
end

Writer.Block.Div = function(div)
    -- XXX entry-spacing is ignored
    local labs = labels(div.attr, {"entry-spacing"}, "div")

    -- can't indent divs;  might introduce unwanted leading space into literals
    -- XXX this is a pity (it makes the Typst code harder to read);
    --     should keep track of whether the div contains any literal content
    return concat { blankline,
                    block_wrap(blocks(div.content), nil, labs, 0),
                    blankline }
end

Writer.Block.HorizontalRule = function(e)
    return concat { blankline, "#line(length: 100%)", blankline }
end

-- if columns are too narrow, try reducing --columns (the default is 72)
-- XXX TBD all attrs, row and cell aligns, multiple bodies (not possible)
Writer.Block.Table = function(tab, opts)
    local labs, opts = labels(tab.attr,
                              {"typst-use-tablex", "valign-top",
                               "valign-middle", "valign-bottom"}, "table")

    -- Typst v0.11 includes all tablex features natively, so typst-use-tablex
    -- now just enables the behavior that it used to enable
    if opts["typst-use-tablex"] then
        labs.classes:insert("bbf-nosidelines")
    end

    -- vertical alignment
    local valign = nil
    if opts["valign-top"] then valign = "top" end
    if opts["valign-middle"] then valign = "horizon" end
    if opts["valign-bottom"] then valign = "bottom" end

    -- column specs (also calculate the total width)
    local columns = pandoc.List()
    local aligns = pandoc.List()
    local total_width = 0.0
    for _, colspec in ipairs(tab.colspecs) do
        local align, width = table.unpack(colspec)
        align = ({AlignLeft="left",
                  AlignRight="right", AlignCenter="center"})[align] or "auto"
        if valign then
            if align == "auto" then
                align = valign
            else
                align = align .. "+" .. valign
            end
        end
        if not width then
            width = "auto"
        else
            local width_percent = 100 * width
            total_width = total_width + width_percent
            width = string.format("%.2ffr", width_percent)
            -- XXX calculated column widths don't seem to work very well
            width = "auto"
        end
        columns:insert(width)
        aligns:insert(align)
    end

    -- create the table command (bbf-table-fill() must be defined somewhere)
    local header_rows = #tab.head.rows
    local fill = string.format("bbf-table-fill.with(columns: %d, " ..
                                   "header-rows: %s)", #columns, header_rows)
    local cmd_opts = pandoc.List({{"columns", array(columns)},
                                  {"align", array(aligns)},
                                  {"fill", fill}})
    -- additional options
    -- local repeat_header = header_rows > 0 and "true" or "false"
    -- cmd_opts:extend({{"header-rows", header_rows},
    --                  {"repeat-header", repeat_header},
    --                  {"header-hlines-have-priority", "false"},
    --                  {"auto-hlines", "true"},
    --                  {"auto-vlines", "false"}})
    local table_cmd = command("#table", cmd_opts, cr, true)

    -- cell layout components
    local comps = pandoc.List()

    -- helper for adding the cells from a list of rows
    -- XXX could/should make more use of helper functions
    local function add_cells(rows, func)
        local prefix = "bbf-table-"
        local func_open = false
        if rows and #rows > 0 then
            for i, row in ipairs(rows) do
                for j, cell in ipairs(row.cells) do
                    -- row and cell attributes are combined
                    -- XXX only the classes are currently used
                    local labs = labels(row.attr, nil, nil, prefix)
                    for _, class in ipairs(labels(cell.attr, nil, nil,
                                                  prefix).classes) do
                        if not labs.classes.class then
                            labs.classes:insert(class)
                        end
                    end

                    -- put each row on a new line
                    comps:insert ","
                    comps:insert(j == 1 and cr or space)


                    -- wrapper func
                    if i == 1 and j == 1 and func then
                        comps:insert(func)
                        comps:insert("(")
                        func_open = true
                    end

                    -- contents
                    local contents = brackets(blocks(cell.contents))
                    local is_content = true

                    -- use an explicit table.cell for colspan and rowspan
                    local colspan = cell.col_span > 1 and cell.col_span or nil
                    local rowspan = cell.row_span > 1 and cell.row_span or nil
                    if colspan or rowspan  then
                        local cell = command("table.cell", {
                                                  {"colspan", colspan},
                                                  {"rowspan", rowspan}}, " ")
                        contents = concat { cell, contents }
                        is_content = false
                    end

                    -- row / cell classes
                    for _, class in ipairs(labs.classes) do
                        local lp = is_content and empty or "("
                        local rp = is_content and empty or ")"
                        contents = concat { class, lp, contents, rp }
                        is_content = false
                    end

                    -- XXX should review wrap/hang
                    if tostring(contents):match("\n") then
                        contents = concat { cr, contents }
                    end

                    comps:insert(contents)
                end
            end

            -- if opened wrapper func, close it
            if func_open then
                comps:insert(")")
            end
        end
    end

    -- head
    -- XXX see below for a hack to embolden the header rows
    add_cells(tab.head.rows, "table.header")

    -- bodies
    for _, body in ipairs(tab.bodies) do
        add_cells(body.body)
    end

    -- foot
    add_cells(tab.foot.rows, "table.footer")

    -- add the concatenated cell components
    local result = concat { hang(concat(comps), TAB_SIZE, table_cmd), cr, ")" }

    -- if the total width is specified and less than 100%,
    -- wrap the table in a block of that width
    if total_width > 0.0 and total_width < 100.0 then
        local cmd_opts = {
            {"width", string.format("%.2f%%", total_width)}}
        local block_cmd = command("#block", cmd_opts)
        result = block_wrap(result, block_cmd)
    end

    -- if there's a caption, wrap the table in a figure
    -- XXX labs are ignored if there's no caption
    -- XXX should lay it out better
    local caption = nil
    if tab.caption.long and #tab.caption.long > 0 then
        caption = blocks(tab.caption.long)
    elseif tab.caption.short and #tab.caption.short > 0 then
        caption = inlines(tab.caption.short)
    end

    -- XXX hack to disable justification and enable hyphenation
    -- XXX also, starting with Typst 0.12.0, need to allow break after
    --     ',' and '.' (maybe shouldn't do this unconditionally)
    local justify_cmd = '#set par(justify: false)\n'
    local hyphenate_cmd = '#set text(hyphenate: true)\n'
    local break_on_comma_cmd = '#show regex("\\>,"): "," + sym.zws\n'
    local break_on_period_cmd = '#show regex("\\>\\."): "." + sym.zws\n'
    result = justify_cmd .. hyphenate_cmd .. break_on_comma_cmd ..
        break_on_period_cmd .. result

    -- XXX hack to force the header rows to be bold (only used when
    --     there's a single header row)
    local strong_cmd = '#show table.cell.where(y: 0): strong\n'

    if not caption then
        if #tab.head.rows == 1 then
            result = strong_cmd .. result
        end
        result = block_wrap(result, nil, labs)
    else
        local align_cmd = command("#align(left)")
        if #tab.head.rows == 1 then
            align_cmd = strong_cmd .. align_cmd
        end
        result = inline_wrap(result, align_cmd)
        local cmd_opts = {
            {"kind", "table"},
            {"caption", brackets(caption)}}
        local figure_cmd = command("#figure", cmd_opts)
        result = block_wrap(result, figure_cmd, labs)
    end

    return { blankline, result, blankline }
end

Writer.Block.Figure = function(fig)
    local caption = nil
    if fig.caption.long and #fig.caption.long > 0 then
        caption = blocks(fig.caption.long)
    elseif fig.caption.short and #fig.caption.short > 0 then
        caption = inlines(fig.caption.short)
    end
    local cmd_opts = {
        {"caption", brackets(caption)}}
    local figure_cmd = command("#figure", cmd_opts)
    return block_wrap(blocks(fig.content), figure_cmd, fig.attr)
end

Writer.Block.LineBlock = function(blk)
    local comps = pandoc.List()
    for i, line in ipairs(blk.content) do
        if i > 1 then
            comps:insert(" \\")
            comps:insert(cr)
        end
        comps:insert(inlines(line))
    end
    return concat { blankline, concat(comps), blankline }
end

Writer.Block.RawBlock = function(raw)
    return raw.format == "typst" and
        concat { blankline, raw.text, blankline } or empty
    -- XXX did have this as the "or" case: Writer.Block.CodeBlock(raw)
end

Writer.Inline.Str = function(str)
    local text = str.text

    local chars = pandoc.List()
    for pos, cp in utf8.codes(text) do
        if cp < 128 then
            -- only need to escape ASCII characters
            -- (can't escape everything; don't want to escape "#h()")
            chars:insert(escape(string.char(cp)))
        elseif cp == 160 then
            -- non-breaking space
            chars:insert("~")
        else
            -- copy other non-ASCII characters
            -- XXX this is horrific; could we use pandoc.text?
            local next_pos = utf8.offset(text, 2, pos)
            local bytes = text:sub(pos, next_pos - 1)
            local array = table.pack(bytes:byte(1, #bytes))
            chars:insert(string.char(table.unpack(array)))
        end
    end

    -- XXX the above only escapes single characters, so misses things like
    --     comments (/* and */ will be somewhat handled by typst itself)
    local result = table.concat(chars)
    if result:match("//") and not result:match("https?://") then
        result = result:gsub("//", "\\//")
    end

    return result
end

Writer.Inline.Space = space

Writer.Inline.SoftBreak = function(_, opts)
    return opts.wrap_text == "wrap-preserve" and cr or space
end

Writer.Inline.LineBreak = { space, "\\", cr }

Writer.Inline.Emph = function(el)
    -- don't use '_' because it causes problems with some input
    -- XXX should handle ';' in inline_wrap(); should it be unconditional?
    return { inline_wrap(inlines(el.content), "#emph") .. ';' }
end

Writer.Inline.Strong = function(el)
    -- don't use '*' because it causes problems with some input
    return { inline_wrap(inlines(el.content), "#strong") .. ';' }
end

Writer.Inline.Strikeout = function(el)
    return { inline_wrap(inlines(el.content), "#strike") .. ';' }
end

Writer.Inline.Subscript = function(el)
    return { inline_wrap(inlines(el.content), "#sub") .. ';' }
end

Writer.Inline.Superscript = function(el)
    return { inline_wrap(inlines(el.content), "#super") .. ';' }
end

Writer.Inline.Underline = function(el)
    return { inline_wrap(inlines(el.content), "#underline") .. ';' }
end

Writer.Inline.SmallCaps = function(el)
    return { inline_wrap(inlines(el.content), "#smallcaps") .. ';' }
end

Writer.Inline.Link = function(link)
    -- if the content ends with '?' assume that citeproc has failed to find it
    local invalid = stringify(link.content):match('%?$')
    local target = link.target
    if target:sub(1, 1) == "#" then
        target = "<" .. target:sub(2) .. ">"
    else
        target = double_quotes(target)
    end
    local inlines = inlines(link.content)
    if invalid then
        return inlines
    else
        local cmd = "#link" .. parens(target)
        return inline_wrap(inlines, cmd)
    end
end

Writer.Inline.Span = function(el)
    return inline_wrap(inlines(el.content), nil, el.attr)
end

Writer.Inline.Quoted = function(el)
    if el.quotetype == "DoubleQuote" then
        return concat { '"', inlines(el.content), '"' }
    else
        return concat { "'", inlines(el.content), "'" }
    end
end

Writer.Inline.Code = function(code)
    -- this might be passed a RawInline, but its format is ignored
    -- (typst doesn't support a format/lang for raw inlines)
    if not code.text:match("`") then
        return { "`", code.text, "`" }
    else
        -- double_quotes() doesn't escape double quotes
        local text = code.text:gsub('"', function(x) return "\\" .. x end)
        return {"#raw(", double_quotes(text), ")" }
    end
end

Writer.Inline.Math = function(math)
    -- use the default Typst writer to render the math
    return pandoc.write(pandoc.Pandoc(math), "typst",
                        pandoc.PANDOC_WRITER_OPTIONS)
end

Writer.Inline.Image = function(img)
    -- XXX width and height units are passed straight through, so must be
    --     valid for Typst, e.g., percentages are OK but pixels aren't
    local labs, opts = labels(img.attr,
                              {"width", "height", "typst-scale"}, "image")

    -- XXX could try to derive the scale from width/height in pixels?
    -- XXX would it be useful to support independent width and height scales?
    local cmd_opts = {
        {nil, double_quotes(img.src)},
        {"alt", #img.title > 0 and double_quotes(img.title) or nil},
        {"width", opts.width},
        {"height", opts.height},
        {"scale", opts["typst-scale"]}
    }
    local img_cmd = command("#bbf-image", cmd_opts, space)
    return inline_wrap(nil, img_cmd, labs)
end

Writer.Inline.Cite = function(cite, opts)
    if opts.extensions:includes "citations" then
        -- XXX this needs further processing
        return inline_wrap(inlines(cite.content), "#cite")
    else
        return inlines(cite.content)
    end
end

Writer.Inline.Note = function(note)
    -- XXX this originally handled notes manually (see Writer.Pandoc)
    -- notes:insert(note)
    -- return inline_wrap(#notes, "#super")

    return block_wrap(chomp(blocks(note.content)), "#footnote")
end

Writer.Inline.RawInline = function(raw)
    return raw.format == "typst" and raw.text or empty
    -- XXX did have this as the "or" case: Writer.Inline.Code(raw)
end
