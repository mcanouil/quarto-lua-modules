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
  lookup = { 'is_valid_value', 'in_array', 'keyword_to_value', 'size_to_css' },
  metadata = { 'get_extension_config', 'get_metadata_value', 'check_deprecated_config',
    'get_option_with_fallbacks', 'get_options', 'get_project_repo_url' },
  ['pandoc-helpers'] = { 'create_link', 'attr', 'has_class', 'add_class', 'get_quarto_format',
    'is_object_empty', 'is_type_simple', 'is_function_userdata', 'get_value',
    'attributes_to_table' },
  paths = { 'resolve_project_path', 'has_extension', 'is_markdown' },
  ['schema-check'] = { 'new' },
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
end

io.stdout:write('# paths\n')

do
  local paths = modules['paths']
  equal(paths.is_markdown('notes.qmd'), true, 'a .qmd path is markdown')
  equal(paths.is_markdown('image.png'), false, 'a .png path is not markdown')
  equal(paths.has_extension('a/b/c.PNG', { '.png' }, false), true,
    'has_extension ignores case when asked to')
  equal(paths.has_extension('a/b/c.PNG', { '.png' }, true), false,
    'has_extension respects case when asked to')
  equal(paths.has_extension('notes.md', { 'md' }), true,
    'an extension given without its dot still matches')
  equal(paths.has_extension(nil, { '.md' }), false, 'a nil path has no extension')
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

io.stdout:write('# schema-check\n')

do
  -- The module reports through `logging`, reads `_schema.yml` through
  -- `quarto.utils.resolve_path`, and takes its validator as an argument. The
  -- first two are stood in for here, and the third is a stub, so the checks
  -- below need neither a render nor a schema file on disk.
  local check_mod = modules['schema-check']

  --- Messages the module reported, in order, with the level it chose.
  local recorded = {}

  local previous_quarto = _G.quarto
  local previous_exit = os.exit

  --- Records an `os.exit` call rather than ending the run, so that a module
  --- which stops a render is a failed check instead of a truncated report.
  local exits = 0

  local function install_stubs()
    recorded = {}
    _G.quarto = {
      log = {
        error = function(m) recorded[#recorded + 1] = { level = 'error', message = m } end,
        warning = function(m) recorded[#recorded + 1] = { level = 'warning', message = m } end,
        output = function(m) recorded[#recorded + 1] = { level = 'output', message = m } end,
        debug = function(m) recorded[#recorded + 1] = { level = 'debug', message = m } end,
      },
      utils = {
        resolve_path = function(path) return path end,
      },
    }
  end

  --- A validator with the three functions the module calls, plus the option
  --- extraction it needs to read a document. `spec` decides what each returns.
  --- @param spec table {err, schema, provided, valid, errors, warnings, defaults, call}
  local function stub_validator(spec)
    return {
      load_schema = function() return spec.schema, spec.err end,
      extract_meta_options = function() return spec.provided or {} end,
      validate = function(values, _, options)
        -- The module resolves the defaults with a second pass over an empty
        -- table, which the real validator answers with the declared defaults
        -- alone. The two passes are told apart by that empty table.
        if next(values) == nil and options ~= nil and options.unknown == 'ignore' then
          return true, {}, {}, spec.defaults or {}
        end
        return spec.valid ~= false, spec.errors or {}, spec.warnings or {}, spec.merged or {}
      end,
      validate_shortcode = function()
        local call = spec.call or {}
        return call.valid ~= false, call.errors or {}, call.warnings or {},
          { arguments = {}, attributes = {} }
      end,
    }
  end

  --- The one shortcode entry every call check below is made against.
  local ICONIFY_ENTRY = {
    arguments = {
      { name = 'icon', required = true, examples = { 'fa6-brands:github' } },
    },
    attributes = {
      size = { type = 'string' },
    },
  }

  local function schema_with(options, shortcodes)
    return { options = options or {}, shortcodes = shortcodes or {} }
  end

  os.exit = function() exits = exits + 1 end

  -- An unreadable schema is reported once, and the checker then does nothing.
  do
    install_stubs()
    local ok, checker = pcall(check_mod.new,
      stub_validator({ err = 'Could not open schema file: _schema.yml' }), 'demo')
    check(ok, 'an unreadable schema does not raise', not ok and tostring(checker) or nil)
    if ok then
      equal(#recorded, 1, 'an unreadable schema is reported once')
      equal(recorded[1] and recorded[1].level, 'error', 'an unreadable schema is an error')
      equal(recorded[1] and recorded[1].message,
        '[demo] Could not open schema file: _schema.yml',
        'the validator message is reported unchanged, with the extension name')

      local defaults_ok, defaults = pcall(checker.options, checker, {})
      check(defaults_ok and type(defaults) == 'table' and next(defaults) == nil,
        'without a schema `options` returns an empty table',
        defaults_ok and tostring(defaults) or ('raised: ' .. tostring(defaults)))

      local call_ok, err = pcall(checker.call, checker, 'iconify', {}, {})
      check(call_ok, 'without a schema `call` does not raise',
        not call_ok and tostring(err) or nil)
      equal(#recorded, 1, 'without a schema nothing further is reported')
    end
  end

  -- `options` hands back what the schema declares as its defaults.
  do
    install_stubs()
    local checker = check_mod.new(stub_validator({
      schema = schema_with({ set = { type = 'string', default = 'octicon' } }),
      defaults = { set = 'octicon' },
    }), 'demo')
    local defaults = checker:options({})
    equal(defaults.set, 'octicon', '`options` returns the resolved defaults')
    equal(#recorded, 0, 'a valid configuration reports nothing')

    -- The second call must not repeat the checks, so an extension may ask for
    -- the defaults on every shortcode without filling the log.
    local again = checker:options({})
    equal(again.set, 'octicon', '`options` returns the same defaults when asked again')
    equal(#recorded, 0, '`options` checks the configuration once per render')
  end

  -- An unknown option is advice, not a failure.
  do
    install_stubs()
    local checker = check_mod.new(stub_validator({
      schema = schema_with({ set = { type = 'string' } }),
      warnings = { 'bogus: is not a recognised key and was ignored.' },
      defaults = {},
    }), 'demo')
    local ok, err = pcall(checker.options, checker, {})
    check(ok, '`options` does not raise on an unknown option', not ok and tostring(err) or nil)
    equal(#recorded, 1, 'an unknown option is reported once')
    equal(recorded[1] and recorded[1].level, 'warning', 'an unknown option is a warning')
    equal(recorded[1] and recorded[1].message,
      '[demo] bogus: is not a recognised key and was ignored.',
      'the unknown option message is reported unchanged')
  end

  -- An unknown shortcode attribute is advice too.
  do
    install_stubs()
    local checker = check_mod.new(stub_validator({
      schema = schema_with({}, { iconify = ICONIFY_ENTRY }),
      call = { warnings = { 'iconify.bogus: is not a recognised key and was ignored.' } },
    }), 'demo')
    checker:call('iconify', { 'fa6-brands:github' }, { bogus = 'x' })
    equal(#recorded, 1, 'an unknown attribute is reported once')
    equal(recorded[1] and recorded[1].level, 'warning', 'an unknown attribute is a warning')
    equal(recorded[1] and recorded[1].message,
      '[demo] iconify.bogus: is not a recognised key and was ignored.',
      'the unknown attribute message is reported unchanged')
  end

  -- A missing required argument is the one call finding that is an error,
  -- because without it the shortcode renders nothing.
  do
    install_stubs()
    local checker = check_mod.new(stub_validator({
      schema = schema_with({}, { iconify = ICONIFY_ENTRY }),
      call = { valid = false, errors = { 'iconify argument 1 ("icon") is required but was not provided.' } },
    }), 'demo')
    checker:call('iconify', {}, {})
    equal(#recorded, 1, 'a missing required argument is reported once')
    equal(recorded[1] and recorded[1].level, 'error', 'a missing required argument is an error')
    equal(recorded[1] and recorded[1].message,
      '[demo] The "iconify" shortcode needs its "icon" argument. ' ..
      'For example: {{< iconify fa6-brands:github >}}.',
      'the missing argument message names the shortcode, the argument and an example')
  end

  -- A shortcode the schema does not declare is not this extension's business.
  do
    install_stubs()
    local checker = check_mod.new(stub_validator({
      schema = schema_with({}, { iconify = ICONIFY_ENTRY }),
      call = { warnings = { 'should not be reached' } },
    }), 'demo')
    checker:call('elsewhere', {}, {})
    equal(#recorded, 0, 'a shortcode absent from the schema is not checked')
  end

  -- Nothing on any path ends the render.
  equal(exits, 0, 'no path calls `os.exit`')

  os.exit = previous_exit
  _G.quarto = previous_quarto
end

io.stdout:write(string.format('\n%d checks, %d failed\n', passed + failed, failed))
io.stdout:flush()
os.exit(failed == 0 and 0 or 1, true)
