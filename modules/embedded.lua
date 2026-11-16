--- MC Embedded - Load a filter that an extension bundles, unless the project has its own copy
--- @module "embedded"
--- @license MIT
--- @copyright 2026 Mickaël Canouil
--- @author Mickaël Canouil

local M = {}

-- ============================================================================
-- EMBEDDED FILTERS
-- ============================================================================

-- A format extension can bundle other extensions under its own `_extensions/`
-- and name them in its format filters. Quarto adds the filters of a page to
-- the format filters, so a project that keeps its own copy of a bundled
-- extension, and names it, runs both copies. A format names a small wrapper in
-- place of each bundled extension, and the wrapper calls `load`, so only the
-- project copy runs.
--
-- `quarto.utils.resolve_path` answers relative to the script on top of an
-- internal Quarto stack, at load time and when a handler runs. The bundled
-- entry is loaded from the wrapper, so `load` puts the entry on that stack
-- with `_quarto.withScriptFile`, which is internal to Quarto, for the load and
-- for every handler call.
-- Remove when: never.

local MANIFESTS = { '_extension.yml', '_extension.yaml' }

--- Tell whether a directory holds an extension manifest.
--- @param dir string
--- @return boolean
local function has_manifest(dir)
  for _, manifest in ipairs(MANIFESTS) do
    local handle = io.open(pandoc.path.join({ dir, manifest }), 'r')
    if handle ~= nil then
      handle:close()
      return true
    end
  end
  return false
end

--- Find the project's own copy of an extension.
--- Looks for `_extensions/<name>/` and `_extensions/<owner>/<name>/`, with any
--- owner, under the project directory. A copy bundled inside another
--- extension is deeper than that, so it never matches.
--- @param name string The extension name, such as `veil`
--- @return string|nil The directory of the copy, or nil when the project has none or there is no project
local function find_project_copy(name)
  local root = quarto.project and quarto.project.directory
  if root == nil then
    return nil
  end
  local extensions = pandoc.path.join({ root, '_extensions' })
  local candidates = { pandoc.path.join({ extensions, name }) }
  local listed, owners = pcall(pandoc.system.list_directory, extensions)
  if listed then
    table.sort(owners)
    for _, owner in ipairs(owners) do
      candidates[#candidates + 1] = pandoc.path.join({ extensions, owner, name })
    end
  end
  for _, dir in ipairs(candidates) do
    if has_manifest(dir) then
      return dir
    end
  end
  return nil
end

--- Call a function with a file on top of Quarto's script stack.
--- `withScriptFile` keeps only the first value of its callback, so the values
--- are packed and unpacked to keep a second value such as `false`.
--- @param file string
--- @param fn function
--- @param element any The element that Pandoc gives to a handler
--- @return any ...
local function with_script(file, fn, element)
  local results = _quarto.withScriptFile(file, function()
    return table.pack(fn(element))
  end)
  return table.unpack(results, 1, results.n)
end

--- Wrap each handler of a filter so it runs with the entry on the stack.
--- @param file string
--- @param filter table
--- @return table
local function wrap_filter(file, filter)
  local wrapped = {}
  for key, value in pairs(filter) do
    if type(value) == 'function' then
      wrapped[key] = function(element)
        return with_script(file, value, element)
      end
    else
      wrapped[key] = value
    end
  end
  return wrapped
end

--- Load a bundled filter, or skip it when the project has its own copy.
--- The entry runs in its own environment, with `PANDOC_SCRIPT_FILE` set to
--- its path, as Quarto runs a filter. An entry that returns nothing gives the
--- functions it defines as its filter.
--- @param name string The extension name to look for in the project, such as `veil`
--- @param file string The absolute path of the bundled entry, in a folder named `name`
--- @return table The list of filters, empty when skipped
--- @usage return M.load('veil', quarto.utils.resolve_path('../_extensions/mcanouil/veil/veil.lua'))
function M.load(name, file)
  local folder = pandoc.path.filename(pandoc.path.directory(file))
  if folder ~= name then
    error('[embedded] The entry ' .. file .. ' is not in a folder named ' .. name ..
      '. Give the name of the bundled extension that holds the entry.')
  end
  local copy = find_project_copy(name)
  if copy ~= nil then
    quarto.log.debug('[embedded] ' .. name .. ' is skipped: the project has its own copy in ' .. copy .. '.')
    return {}
  end
  local env = setmetatable({ PANDOC_SCRIPT_FILE = file }, { __index = _G })
  local result = with_script(file, function()
    local chunk, err = loadfile(file, 'bt', env)
    if chunk == nil then
      error('[embedded] Could not load ' .. name .. ' from ' .. file .. ': ' .. tostring(err))
    end
    return chunk()
  end)
  if result == nil then
    result = {}
    for key, value in pairs(env) do
      if type(value) == 'function' then
        result[key] = value
      end
    end
  end
  if result[1] == nil then
    result = { result }
  end
  local filters = {}
  for index, filter in ipairs(result) do
    filters[index] = wrap_filter(file, filter)
  end
  return filters
end

return M
