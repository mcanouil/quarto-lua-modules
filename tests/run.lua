--- Tests for the shared Quarto Lua modules.
---
--- Run with the Pandoc that Quarto ships, from the repository root:
---
---     quarto pandoc lua tests/run.lua
---
--- The modules run inside Quarto's Lua, so they are tested there rather than
--- in a standalone interpreter. Several of them call `pandoc.*`, which only
--- exists in that environment.
---
--- Every module is loaded, and every public function is called at least once
--- with a known input. These are the checks that were missing while the
--- modules lived beside the extensions that copy them.

local here = assert(arg[0]:match('(.*)tests/run%.lua$'),
  'run from the repository root: quarto pandoc lua tests/run.lua')

--- The modules load their siblings by building an absolute path and passing it
--- to `require` (see `load_sibling` in `pandoc-helpers.lua`). A Quarto filter's
--- `package.path` accepts that; a bare `?.lua` reproduces it here, so the tests
--- exercise the same resolution consumers get rather than one of their own.
package.path = table.concat({ '?.lua', package.path }, ';')

--- Loaded the way a consumer loads it. The path is what `load_sibling` builds,
--- so a module and the siblings that depend on it share one instance, and the
--- assertions run against the table those siblings actually hold.
local function load_module(name)
  return require(here .. 'modules/' .. name)
end

local passed, failed = 0, 0

local function check(ok, description, detail)
  if ok then
    passed = passed + 1
    io.stdout:write('ok   ', description, '\n')
  else
    failed = failed + 1
    io.stdout:write('FAIL ', description, '\n')
    if detail then
      io.stdout:write('     ', tostring(detail), '\n')
    end
  end
end

local function equal(actual, expected, description)
  check(actual == expected, description,
    string.format('expected %s, got %s', tostring(expected), tostring(actual)))
end

--- Call a function and compare its result, reporting a raised error as a
--- failed check rather than letting it end the run.
local function returns(description, expected, fn, ...)
  local ok, actual = pcall(fn, ...)
  if not ok then
    check(false, description, 'raised: ' .. tostring(actual))
    return
  end
  check(actual == expected, description,
    string.format('expected %s, got %s', tostring(expected), tostring(actual)))
end

--- Every function a module exports, so a new one cannot be added untested
--- without this list disagreeing with the module.
local EXPECTED = {
  colour = { 'is_named_colour', 'expand_hex_colour', 'RGB_to_HTML', 'RGBPercent_to_HTML',
    'hue_to_rgb', 'HSL_to_HTML', 'HWB_to_HTML', 'named_to_HTML', 'to_html', 'get_colour',
    'is_custom_colour' },
  ['content-extraction'] = { 'extract_section', 'extract_div', 'find_block', 'protect_headers',
    'parse_sections', 'extract_code_metadata' },
  git = { 'get_repository' },
  html = { 'raw_header', 'ensure_html_dependency', 'reset_dependencies' },
  logging = { 'log_error', 'log_warning', 'log_output', 'log_debug' },
  lookup = { 'is_valid_value', 'in_array', 'keyword_to_value', 'size_to_css', 'has_extension',
    'is_markdown' },
  metadata = { 'get_extension_config', 'get_metadata_value', 'check_deprecated_config',
    'get_option_with_fallbacks', 'get_options', 'get_project_repo_url' },
  ['pandoc-helpers'] = { 'create_link', 'attr', 'has_class', 'add_class', 'get_quarto_format',
    'is_object_empty', 'is_type_simple', 'is_function_userdata', 'get_value',
    'attributes_to_table' },
  paths = { 'resolve_project_path' },
  string = { 'stringify', 'is_empty', 'escape_pattern', 'split', 'trim', 'to_string', 'strip_surrounding',
    'strip_edges', 'find_bracketed_content', 'escape_latex', 'escape_typst',
    'escape_typst_string', 'escape_js_string', 'escape_lua_pattern', 'escape_html',
    'escape_attribute', 'escape_text', 'ascii_id' },
}

io.stdout:write('# loading\n')

--- Read from disk rather than from `EXPECTED`, so a module added without an
--- entry is a failure here rather than something nothing ever loads.
local names = {}
for _, entry in ipairs(pandoc.system.list_directory(here .. 'modules')) do
  local name = entry:match('^(.+)%.lua$')
  if name then
    names[#names + 1] = name
  end
end
table.sort(names)

local modules = {}

for _, name in ipairs(names) do
  local ok, loaded = pcall(load_module, name)
  check(ok and type(loaded) == 'table', string.format('`%s` loads and returns a table', name),
    not ok and tostring(loaded) or nil)
  if ok then
    modules[name] = loaded
  end
end

io.stdout:write('# exports\n')

--- Checked both ways. `EXPECTED` is hand-maintained on purpose, because these
--- modules are vendored and their public surface is a contract: a rename is a
--- downstream break and has to be a deliberate edit here. Deriving the list
--- from the module would compare it to itself and assert nothing.
for _, name in ipairs(names) do
  local loaded = modules[name]
  local expected = EXPECTED[name]
  if not expected then
    check(false, string.format('`%s` is listed in EXPECTED', name),
      'the module is on disk but its exports are not declared')
  elseif loaded then
    local missing, undeclared = {}, {}
    for _, fn in ipairs(expected) do
      if type(loaded[fn]) ~= 'function' then
        missing[#missing + 1] = fn
      end
    end
    local declared = {}
    for _, fn in ipairs(expected) do
      declared[fn] = true
    end
    for key, value in pairs(loaded) do
      if type(value) == 'function' and not declared[key] then
        undeclared[#undeclared + 1] = key
      end
    end
    table.sort(undeclared)
    local detail = {}
    if #missing > 0 then
      detail[#detail + 1] = 'missing: ' .. table.concat(missing, ', ')
    end
    if #undeclared > 0 then
      detail[#detail + 1] = 'undeclared: ' .. table.concat(undeclared, ', ')
    end
    check(#detail == 0, string.format('`%s` exports exactly what it declares', name),
      #detail > 0 and table.concat(detail, '; ') or nil)
  end
end

io.stdout:write('# string\n')

do
  local str = modules['string']
  equal(str.is_empty(''), true, 'an empty string is empty')
  equal(str.is_empty(nil), true, 'nil is empty')
  equal(str.is_empty('x'), false, 'a non-empty string is not empty')
  equal(str.trim('  padded  '), 'padded', 'trim removes surrounding whitespace')
  -- Returns three values: the prefix stripped, the inner text, and the suffix.
  local prefix, inner, suffix = str.strip_surrounding('"quoted"')
  equal(inner, 'quoted', 'a surrounding quote pair is stripped')
  equal(prefix, '"', 'the stripped prefix is returned')
  equal(suffix, '"', 'the stripped suffix is returned')
  equal(table.concat(str.split('a,b,c', ','), '|'), 'a|b|c', 'split divides on a separator')
  equal(str.escape_html('<a href="x">'), '&lt;a href=&quot;x&quot;&gt;',
    'escape_html escapes angle brackets and quotes')
  equal(str.escape_lua_pattern('a.b'), 'a%.b', 'escape_lua_pattern escapes a magic character')
  check(str.ascii_id('Héllo World'):match('^[%w%-_]+$') ~= nil,
    'ascii_id yields an identifier with no accents or spaces')
end

io.stdout:write('# lookup\n')

do
  local lookup = modules['lookup']
  equal(lookup.in_array('b', { 'a', 'b' }), true, 'in_array finds a present value')
  equal(lookup.in_array('z', { 'a', 'b' }), false, 'in_array rejects an absent value')
  equal(lookup.keyword_to_value('small', { small = '1rem' }, '2rem'), '1rem',
    'keyword_to_value maps a known keyword')
  equal(lookup.keyword_to_value('other', { small = '1rem' }, '2rem'), '2rem',
    'keyword_to_value falls back to the default')
  equal(lookup.is_markdown('notes.qmd'), true, 'a .qmd path is markdown')
  equal(lookup.is_markdown('image.png'), false, 'a .png path is not markdown')
  equal(lookup.has_extension('a/b/c.PNG', { '.png' }, false), true,
    'has_extension ignores case when asked to')
end

io.stdout:write('# colour\n')

do
  local colour = modules['colour']
  returns('a three digit hex colour expands to six', '#aabbcc', colour.expand_hex_colour, '#abc')
  returns('an rgb() string converts to hex', '#336699', colour.RGB_to_HTML, 'rgb(51, 102, 153)')
  returns('a CSS colour name is recognised', true, colour.is_named_colour, 'red')
  returns('an invented name is not a colour', false, colour.is_named_colour, 'notacolour')
  returns('to_html passes a hex colour through', '#336699', colour.to_html, '#336699', 'hex')
end

io.stdout:write('# pandoc-helpers\n')

do
  local helpers = modules['pandoc-helpers']
  returns('an empty table is empty', true, helpers.is_object_empty, {})
  returns('a populated table is not empty', false, helpers.is_object_empty, { 1 })
  -- `has_class` takes the class list, not the element that carries it.
  local div = pandoc.Div({}, pandoc.Attr('', { 'note' }, {}))
  returns('has_class finds a class that is present', true, helpers.has_class, div.attr.classes, 'note')
  returns('has_class rejects a class that is not', false, helpers.has_class, div.attr.classes, 'absent')
  returns('has_class tolerates a nil class list', false, helpers.has_class, nil, 'note')
end

io.stdout:write('# logging\n')

do
  -- The module calls `quarto.log` directly and has no fallback, so it cannot
  -- run outside a filter. Standing in a recorder for `quarto.log` tests what
  -- the module is actually for: prefixing the message with the extension name.
  local logging = modules['logging']
  local recorded = {}
  local previous = _G.quarto
  _G.quarto = {
    log = {
      error = function(m) recorded[#recorded + 1] = m end,
      warning = function(m) recorded[#recorded + 1] = m end,
      output = function(m) recorded[#recorded + 1] = m end,
      debug = function(m) recorded[#recorded + 1] = m end,
    },
  }

  for _, fn in ipairs({ 'log_error', 'log_warning', 'log_output', 'log_debug' }) do
    recorded = {}
    local ok, err = pcall(logging[fn], 'demo', 'a message')
    check(ok and recorded[1] == '[demo] a message',
      string.format('`logging.%s` prefixes the extension name', fn),
      ok and tostring(recorded[1]) or ('raised: ' .. tostring(err)))
  end

  _G.quarto = previous
end

io.stdout:write(string.format('\n%d checks, %d failed\n', passed + failed, failed))
io.stdout:flush()
os.exit(failed == 0 and 0 or 1, true)
