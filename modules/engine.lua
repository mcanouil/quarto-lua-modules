--- MC Engine - Values that Quarto 1 and Quarto 2 give through different routes
--- @module "engine"
--- @license MIT
--- @copyright 2026 Mickaël Canouil
--- @author Mickaël Canouil
---
--- Each function returns the same value in Quarto 1 and in Quarto 2 for the
--- same document. It reads the data that is present, never the name or the
--- version of the engine, so it keeps working when Quarto 2 adds a route.

local M = {}

--- Load a sibling module from the same directory as this file.
--- @param filename string The sibling module filename (e.g., 'string.lua')
--- @return table The loaded module
local function load_sibling(filename)
  local name = filename:gsub('%.lua$', '')
  if not (debug and debug.getinfo) then
    -- q2 has no `debug` library, and its `require` looks in the directory of
    -- the module being loaded first.
    return require(name)
  end
  local source = debug.getinfo(1, 'S').source:sub(2)
  local dir = source:match('(.*[/\\])') or ''
  return require(dir .. name)
end

local metadata = load_sibling('metadata.lua')
local str = load_sibling('string.lua')

-- ============================================================================
-- PROJECT VALUES
-- ============================================================================

--- Turn a metadata value into a plain string, or nil when it is empty.
--- @param value any A value from the JSON file (a string) or from pandoc.Meta
--- @return string|nil
local function plain_string(value)
  if value == nil then
    return nil
  end
  local text = type(value) == 'string' and value or pandoc.utils.stringify(value)
  if str.is_empty(text) then
    return nil
  end
  return text
end

--- Read the `website` and `book` maps of the project.
--- Quarto 1 writes them to the file that `QUARTO_EXECUTE_INFO` names.
--- Quarto 2 does not set the variable, and gives them in the document metadata.
--- @param meta table|nil The document metadata
--- @return table|nil website, table|nil book, string|nil reason
local function project_maps(meta)
  local format_meta, reason = metadata.get_project_metadata()
  if format_meta ~= nil then
    return format_meta['website'], format_meta['book'], nil
  end
  if reason ~= nil then
    return nil, nil, reason
  end
  if meta == nil then
    return nil, nil, nil
  end
  return meta['website'], meta['book'], nil
end

--- Read one key from `website`, then from `book`.
--- @param meta table|nil The document metadata
--- @param key string The key, for example 'repo-url'
--- @return string|nil value, string|nil reason
local function project_value(meta, key)
  local website, book, reason = project_maps(meta)
  if reason ~= nil then
    return nil, reason
  end
  -- Not ipairs: it would stop at a missing website and never read the book.
  local maps = { website, book }
  for index = 1, 2 do
    local map = maps[index]
    if type(map) == 'table' then
      local value = plain_string(map[key])
      if value ~= nil then
        return value, nil
      end
    end
  end
  return nil, nil
end

--- Get the repository URL of the project: `website.repo-url`, else `book.repo-url`.
--- @param meta table|nil The document metadata, used when Quarto gives no `QUARTO_EXECUTE_INFO`
--- @return string|nil url The URL, or nil when the project sets none
--- @return string|nil reason Why `QUARTO_EXECUTE_INFO` could not be read, as in `metadata.get_project_metadata`
--- @usage local repo_url = engine.project_repo_url(doc.meta)
function M.project_repo_url(meta)
  return project_value(meta, 'repo-url')
end

--- Get the site URL of the project: `website.site-url`, else `book.site-url`.
--- @param meta table|nil The document metadata, used when Quarto gives no `QUARTO_EXECUTE_INFO`
--- @return string|nil url The URL, or nil when the project sets none
--- @return string|nil reason Why `QUARTO_EXECUTE_INFO` could not be read, as in `metadata.get_project_metadata`
--- @usage local site_url = engine.project_site_url(doc.meta)
function M.project_site_url(meta)
  return project_value(meta, 'site-url')
end

--- Get the kind of the project: 'book' when it has a `book` map, else 'website' when it has a `website` map.
--- @param meta table|nil The document metadata, used when Quarto gives no `QUARTO_EXECUTE_INFO`
--- @return string|nil kind 'book', 'website', or nil for any other project or a single file
--- @return string|nil reason Why `QUARTO_EXECUTE_INFO` could not be read, as in `metadata.get_project_metadata`
--- @usage local kind = engine.project_kind(doc.meta) or 'default'
function M.project_kind(meta)
  local website, book, reason = project_maps(meta)
  if reason ~= nil then
    return nil, reason
  end
  if book ~= nil then
    return 'book', nil
  end
  if website ~= nil then
    return 'website', nil
  end
  return nil, nil
end

return M
