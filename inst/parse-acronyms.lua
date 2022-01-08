--[[
    Lua Filter to parse acronyms in a Markdown document.

    Acronyms must be in the form `\acr{key}` where key is the acronym key.
    The first occurrence of an acronym is replaced by its long name, as
    defined by a list of acronyms in the document's metadata.
    Other occurrences are simply replaced by the acronym's short name.

    A List of Acronym is also generated (similar to a Glossary in LaTeX),
    and all occurrences contain a link to the acronym's definition in this
    List.
]]

-- We want to require the Lua files which are in the same folder.
-- However, as we are invoking this file through Pandoc (and potentially
-- RMarkdown), we do not have control over the `LUA_PATH` environment variable,
-- nor the current working directory.
-- It seems to me that we need to add this current file's directory
-- to the list of searched directories, i.e., `package.path`.
local current_dir = debug.getinfo(1).source:match("@?(.*/)")
package.path = package.path .. ";" .. current_dir .. "/?.lua"

-- The Acronyms database
require("acronyms")

-- Sorting function
local sortAcronyms = require("sort_acronyms")

-- Replacement function (handling styles)
local replaceExistingAcronymWithStyle = require("acronyms_styles")

-- The options for the List Of Acronyms, as defined in the document's metadata.
local options = {}

--[[
The current "usage order" value.
We increment this value each time we find a new acronym, and we use it
to register the order in which acronyms appear.
--]]
local current_order = 0


-- A helper function to print warnings
function warn(msg)
   io.stderr:write("[WARNING][acronymsdown] " .. msg .. "\n")
end


-- Helper function to generate the ID (identifier) from an acronym key.
-- The ID can be used for, e.g., links.
function key_to_id(key)
    return options["id_prefix"] .. key
end
-- Similar helper but for the link itself (based on the ID).
function key_to_link(key)
    return "#" .. key_to_id(key)
end


function Meta(m)
    parseOptionsFromMetadata(m)

    -- Parse acronyms directly from the metadata (`acronyms.keys`)
    Acronyms:parseFromMetadata(m, options["on_duplicate"])

    -- Parse acronyms from external files
    if (m and m.acronyms and m.acronyms.fromfile) then
        if m.acronyms.fromfile.t == "MetaList" then
            -- We have several files to read
            for _, filepath in ipairs(m.acronyms.fromfile) do
                filepath = pandoc.utils.stringify(filepath)
                Acronyms:parseFromYamlFile(filepath, options["on_duplicate"])
            end
        else
            -- We have a single file
            local filepath = pandoc.utils.stringify(m.acronyms.fromfile)
            Acronyms:parseFromYamlFile(filepath, options["on_duplicate"])
        end
    end

    return nil
end


--[[
Parse the options from the Metadata (i.e., the YAML fields).
Absent options are replaced by a default value.
--]]
function parseOptionsFromMetadata(m)
    options = m.acronyms or {}

    if options["id_prefix"] == nil then
        options["id_prefix"] = "acronyms_"
    else
        options["id_prefix"] = pandoc.utils.stringify(options["id_prefix"])
    end

    if options["sorting"] == nil then
        options["sorting"] = "alphabetical"
    else
        options["sorting"] = pandoc.utils.stringify(options["sorting"])
    end

    if options["loa_title"] == nil then
        options["loa_title"] = pandoc.MetaInlines(pandoc.Str("List Of Acronyms"))
    elseif pandoc.utils.stringify(options["loa_title"]) == "" then
        -- It seems that writing `loa_title: ""` in the YAML returns `{}`
        -- (an empty table). `pandoc.utils.stringify({})` returns `""` as well.
        -- This value indicates that the user does not want a Header.
        options["loa_title"] = ""
    end

    if options["include_unused"] == nil then
        options["include_unused"] = true
    end

    if options["insert_beginning"] == nil then
        options["insert_beginning"] = true
    end

    if options["inexisting_keys"] == nil then
        options["inexisting_keys"] = "warn"
    end

    if options["on_duplicate"] == nil then
        options["on_duplicate"] = "warn"
    else
        options["on_duplicate"] = pandoc.utils.stringify(options["on_duplicate"])
    end

    if options["style"] == nil then
        options["style"] = "long-short"
    else
        options["style"] = pandoc.utils.stringify(options["style"])
    end

    if options["insert_links"] == nil then
        options["insert_links"] = true
    end

end


--[[
Generate the List Of Acronyms.
Returns 2 values: the Header, and the DefinitionList.
--]]
function generateLoA()
    -- Original idea from https://gist.github.com/RLesur/e81358c11031d06e40b8fef9fdfb2682

    -- We first get the list of sorted acronyms, according to the defined criteria.
    local sorted = sortAcronyms(Acronyms.acronyms, options["sorting"])

    -- Create the table that represents the DefinitionList
    local definition_list = {}
    for _, acronym in ipairs(sorted) do
        -- The definition's name. A Span with an ID so we can create a link.
        local name = pandoc.Span(acronym.shortname,
            pandoc.Attr(key_to_id(acronym.key), {}, {}))
        -- The definition's value.
        local definition = pandoc.Plain(acronym.longname)
        table.insert(definition_list, { name, definition })
    end

    -- Create the Header (only if the title is not empty)
    local header = nil
    if options["loa_title"] ~= "" then
        local loa_classes = {"loa"}
        header = pandoc.Header(1,
            { table.unpack(options["loa_title"]) },
            pandoc.Attr(key_to_id("HEADER_LOA"), loa_classes, {})
        )
    end

    return header, pandoc.DefinitionList(definition_list)
end


--[[
Append the List Of Acronyms to the document (at the beginning).
--]]
function appendLoA(doc)
    -- If disabled, do nothing
    if not options["insert_beginning"] then
        return nil
    end

    local header, definition_list = generateLoA()

    -- Insert the DefinitionList
    table.insert(doc.blocks, 1, definition_list)

    -- Insert the Header
    if header ~= nil then
        table.insert(doc.blocks, 1, header)
    end

    return pandoc.Pandoc(doc.blocks, doc.meta)
end


--[[
Place the List Of Acronyms in the document (in place of a `\printacronyms` block).
Since Header and DefinitionList are Blocks, we need to replace a Block
(Pandoc does not allow to create Blocks from Inlines).
Thus, `\printacronyms` needs to be in its own Block (no other text!).
--]]
function RawBlock(el)
    -- The block's content must be exactly "\printacronyms"
    if not (el and el.text == "\\printacronyms") then
        return nil
    end

    local header, definition_list = generateLoA()

    if header ~= nil then
        return { header, definition_list }
    else
        return definition_list
    end
end

--[[
Replace an acronym `\acr{KEY}`, where KEY is not in the `acronyms` table.
According to the options, we can either:
- ignore, and return simply the KEY as text
- print a warning, and return simply the KEY as text
- raise an error
--]]
function replaceInexistingAcronym(acr_key)
    if options["inexisting_keys"] == "ignore" then
        return pandoc.Str(acr_key)
    elseif options["inexisting_keys"] == "warn" then
        warn("Acronym key " .. acr_key .. " not recognized, ignoring...")
        return pandoc.Str(acr_key)
    elseif options["inexisting_keys"] == "error" then
        error("Acronym key " .. acr_key .. " not recognized, stopping!")
    else
        error("Unrecognized option inexisting_keys=" .. options["inexisting_keys"])
    end
end

--[[
Replace an acronym `\acr{KEY}`, where KEY is recognized in the `acronyms` table.
--]]
function replaceExistingAcronym(acr_key)
    local acronym = Acronyms:get(acr_key)
    acronym:incrementOccurrences()
    if acronym:isFirstUse() then
        -- This acronym never appeared! We first set its usage order.
        current_order = current_order + 1
        acronym.usage_order = current_order
    end

    -- Replace the acronym with the desired style
    return replaceExistingAcronymWithStyle(
        acronym,
        options["style"],
        options["insert_links"]
    )
end

--[[
Replace each `\acr{KEY}` with the correct text and link to the list of acronyms.
--]]
function replaceAcronym(el)
    local acr_key = string.match(el.text, "\\acr{(.+)}")
    if acr_key then
        -- This is an acronym, we need to parse it.
        if Acronyms:contains(acr_key) then
            -- The acronym exists (and is recognized)
            return replaceExistingAcronym(acr_key)
        else
            -- The acronym does not exists
            return replaceInexistingAcronym(acr_key)
        end
    else
        -- This is not an acronym, return nil to leave it unchanged.
        return nil
    end
end

-- Force the execution of the Meta filter before the RawInline
-- (we need to load the acronyms first!)
-- RawBlock and Doc happen after RawInline so that the actual usage order
-- of acronyms is known (and we can sort the List of Acronyms accordingly)
return {
    { Meta = Meta },
    { RawInline = replaceAcronym },
    { RawBlock = RawBlock },
    { Doc = appendLoA },
}
