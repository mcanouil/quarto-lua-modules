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
      -- The path is kept so a check can read where the module went looking,
      -- which is the whole of what the schema path argument decides.
      load_schema = function(path)
        spec.schema_path = path
        return spec.schema, spec.err
      end,
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
      -- The module discards the first return here, unlike on the options pass,
      -- where `valid` gates whether the errors are reported at all. A finding
      -- about a call is reported whatever the verdict, and the level it gets
      -- comes from the kind of finding rather than from the validator. So
      -- `spec.call` carries no `valid`: setting one would say nothing.
      validate_shortcode = function(name, args, kwargs, entry)
        -- Kept so a check can read what the module handed over, not only what
        -- it did with the answer.
        spec.seen = { name = name, args = args, kwargs = kwargs, entry = entry }
        local call = spec.call or {}
        return true, call.errors or {}, call.warnings or {},
          { arguments = {}, attributes = {} }
      end,
      -- Stands in for the real function closely enough for the module's own
      -- job, which is deciding what to call and in what order. `spec.groups`
      -- names the groups the schema declares; a group absent from it hands the
      -- input straight back, which is what the real one does with no
      -- descriptors. Each declared group applies its own map of replacements,
      -- so a check can read whether the second pass saw the first pass's work.
      validate_attributes = function(attributes, group, _)
        spec.attr_calls = spec.attr_calls or {}
        spec.attr_calls[#spec.attr_calls + 1] = { group = group, input = attributes }
        local declared = (spec.groups or {})[group]
        if declared == nil then
          return true, {}, {}, attributes
        end
        local merged = {}
        for key, value in pairs(attributes or {}) do merged[key] = value end
        -- One map stands in for both of the real function's effects, since a
        -- coerced value and an applied default are the same thing here: a key
        -- the group decides the value of.
        for key, value in pairs(declared.resolve or {}) do merged[key] = value end
        return #(declared.errors or {}) == 0, declared.errors or {}, declared.warnings or {}, merged
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

      local defaults_ok, defaults, resolved = pcall(checker.options, checker, {})
      check(defaults_ok and type(defaults) == 'table' and next(defaults) == nil,
        'without a schema `options` returns an empty table',
        defaults_ok and tostring(defaults) or ('raised: ' .. tostring(defaults)))
      equal(resolved, nil, 'without a schema `options` resolves nothing')

      local call_ok, err = pcall(checker.call, checker, 'iconify', {}, {})
      check(call_ok, 'without a schema `call` does not raise',
        not call_ok and tostring(err) or nil)
      equal(#recorded, 1, 'without a schema nothing further is reported')
    end
  end

  -- Where the schema is read from. `resolve_path` answers relative to the
  -- entry point that is running, so an extension whose entry points sit in a
  -- subdirectory never finds a schema named `_schema.yml`. The third argument
  -- names the file instead, and its absence has to leave every existing two
  -- argument caller reading exactly what it read before.
  do
    install_stubs()
    local spec = { schema = schema_with({}) }
    check_mod.new(stub_validator(spec), 'demo')
    equal(spec.schema_path, '_schema.yml', 'two arguments still read `_schema.yml`')
    equal(#recorded, 0, 'two arguments report nothing')
  end

  do
    install_stubs()
    local spec = { schema = schema_with({}) }
    check_mod.new(stub_validator(spec), 'demo', '../_schema.yml')
    equal(spec.schema_path, '../_schema.yml', 'a third argument names the schema to read')
    equal(#recorded, 0, 'a third argument reports nothing')
  end

  -- The given path is resolved the same way the default is, so a caller writes
  -- a path relative to its own entry point rather than an absolute one. The
  -- stub above answers `resolve_path` with the path unchanged, which cannot
  -- tell a resolved path from one passed straight through.
  do
    install_stubs()
    _G.quarto.utils.resolve_path = function(path)
      return '/project/_extensions/demo/filters/' .. path
    end
    local spec = { schema = schema_with({}) }
    check_mod.new(stub_validator(spec), 'demo', '../_schema.yml')
    equal(spec.schema_path, '/project/_extensions/demo/filters/../_schema.yml',
      'the given path is resolved before it is read')
  end

  -- A path that names nothing is the finding an unreadable `_schema.yml`
  -- already is: reported once, and the checker then does nothing.
  do
    install_stubs()
    local spec = { err = 'Could not open schema file: ../_schema.yml' }
    local checker = check_mod.new(stub_validator(spec), 'demo', '../_schema.yml')
    equal(spec.schema_path, '../_schema.yml',
      'a schema that cannot be read was looked for at the given path')
    equal(#recorded, 1, 'a schema absent from the given path is reported once')
    equal(recorded[1] and recorded[1].level, 'error',
      'a schema absent from the given path is an error')
    equal(recorded[1] and recorded[1].message,
      '[demo] Could not open schema file: ../_schema.yml',
      'the validator message names the path it was given')

    local defaults, resolved = checker:options({})
    check(type(defaults) == 'table' and next(defaults) == nil,
      'a checker built on a missing path returns an empty defaults table', tostring(defaults))
    equal(resolved, nil, 'a checker built on a missing path resolves nothing')
    checker:call('iconify', {}, {})
    equal(#recorded, 1, 'a checker built on a missing path reports nothing further')
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
  end

  -- The configuration is checked once per render, so an extension may ask for
  -- the defaults on every shortcode without filling the log. The stub reports
  -- a finding on every pass, so a second check would show as a second message.
  do
    install_stubs()
    local checker = check_mod.new(stub_validator({
      schema = schema_with({ set = { type = 'string', default = 'octicon' } }),
      provided = { bogus = 'x' },
      warnings = { 'bogus: is not a recognised key and was ignored.' },
      defaults = { set = 'octicon' },
    }), 'demo')

    local first = checker:options({})
    equal(first.set, 'octicon', '`options` returns the defaults on the first call')
    equal(#recorded, 1, 'the first call reports what it finds')

    local again = checker:options({})
    equal(again.set, 'octicon', '`options` returns the same defaults when asked again')
    equal(#recorded, 1, '`options` checks the configuration once per render')
  end

  -- The single check is what the `meta` of a later call is traded for, and the
  -- trade has to be visible rather than assumed. Quarto hands a shortcode a new
  -- metadata table on every call holding the same content, so a checker that
  -- honoured the later argument would repeat every finding once per shortcode.
  -- The validator here records what it was handed and answers from it, so a
  -- checker that read the second metadata would come back with `fontawesome`
  -- rather than with a table the stub would have returned either way.
  do
    install_stubs()
    local spec = {
      schema = schema_with({ set = { type = 'string', default = 'octicon' } }),
      provided = { bogus = 'x' },
      warnings = { 'bogus: is not a recognised key and was ignored.' },
    }
    local validator = stub_validator(spec)
    local handed = {}
    validator.extract_meta_options = function(meta)
      handed[#handed + 1] = meta
      spec.defaults = { set = meta.extensions.demo.set }
      return spec.provided
    end
    local checker = check_mod.new(validator, 'demo')

    local first_meta = { extensions = { demo = { set = 'octicon' } } }
    local second_meta = { extensions = { demo = { set = 'fontawesome' } } }

    local first = checker:options(first_meta)
    equal(#handed, 1, 'the first call reads the metadata it is given')
    check(handed[1] == first_meta, 'the first call hands the validator its own metadata',
      tostring(handed[1]))
    equal(first.set, 'octicon', 'the first call answers from the metadata it read')

    local later = checker:options(second_meta)
    equal(#handed, 1, 'a later call never reads the metadata it is given')
    equal(later.set, 'octicon', 'a later call returns what the first call resolved')
    equal(#recorded, 1, 'a later call reports nothing about the metadata it is given')
  end

  -- The defaults are handed over as a copy. This module is vendored into many
  -- extensions, and it publishes the defaults on a convenient path, so a
  -- caller writing a computed fallback into what it received is an easy and
  -- quiet mistake. The write must stay with the caller that made it.
  do
    install_stubs()
    local checker = check_mod.new(stub_validator({
      schema = schema_with({ set = { type = 'string', default = 'octicon' } }),
      defaults = { set = 'octicon' },
    }), 'demo')

    local first = checker:options({})
    first.set = 'poisoned'
    first.added = 'poisoned'

    local second, resolved = checker:options({})
    check(second ~= first, 'each call returns its own defaults table',
      'the same table came back twice')
    equal(second.set, 'octicon', 'writing to the returned defaults leaves the checker unchanged')
    equal(second.added, nil, 'a key added to the returned defaults does not reach the checker')
    equal(resolved.defaults.set, 'octicon', 'the resolved defaults are unchanged as well')
  end

  -- A default is not always a scalar. One extension in the fleet declares
  -- `default: []` for an array option, and another a mapping default, so the
  -- copy has to go all the way down. A caller inserting into the array it
  -- received must not change what the checker holds.
  do
    install_stubs()
    local checker = check_mod.new(stub_validator({
      schema = schema_with({
        ['page-exclude'] = { type = 'array', default = {} },
        ['slide-change-cue'] = { type = 'object', default = { visual = true } },
      }),
      defaults = {
        ['page-exclude'] = { '/drafts/*' },
        ['slide-change-cue'] = { visual = true, audio = false },
      },
    }), 'demo')

    local first = checker:options({})
    table.insert(first['page-exclude'], 'poisoned')
    first['slide-change-cue'].visual = 'poisoned'

    local second, resolved = checker:options({})
    check(second['page-exclude'] ~= first['page-exclude'],
      'each call returns its own array default', 'the same array came back twice')
    equal(#second['page-exclude'], 1,
      'inserting into a returned array leaves the checker unchanged')
    equal(second['page-exclude'][1], '/drafts/*', 'the array default keeps its own entry')
    equal(second['slide-change-cue'].visual, true,
      'writing into a returned mapping default leaves the checker unchanged')
    equal(resolved.defaults['page-exclude'][1], '/drafts/*',
      "the checker's own array default is unchanged")
    equal(#resolved.defaults['page-exclude'], 1,
      "the checker's own array default gained no entry")
  end

  -- The recursion is unbounded, not one level below the top container. The
  -- two defaults above both sit one level down and hold scalars, so they
  -- cannot tell "recurse once more" from "recurse all the way".
  --
  -- Nothing in the fleet nests a default three deep today, so this covers the
  -- format rather than a schema in play. That is deliberate, and it is the
  -- same argument that settled the depth: the vocabulary allows an array of
  -- objects whose properties are objects, so the shape is reachable by a
  -- schema nobody has written yet.
  do
    install_stubs()
    local checker = check_mod.new(stub_validator({
      schema = schema_with({ entries = { type = 'array' } }),
      defaults = {
        entries = { { name = 'first', options = { colour = 'blue' } } },
      },
    }), 'demo')

    local first = checker:options({})
    first.entries[1].name = 'poisoned'
    first.entries[1].options.colour = 'poisoned'

    local second, resolved = checker:options({})
    check(second.entries[1] ~= first.entries[1],
      'each call returns its own array element', 'the same element came back twice')
    check(second.entries[1].options ~= first.entries[1].options,
      'each call returns its own nested mapping', 'the same mapping came back twice')
    equal(second.entries[1].name, 'first',
      'a write two levels down leaves the checker unchanged')
    equal(second.entries[1].options.colour, 'blue',
      'a write three levels down leaves the checker unchanged')
    equal(resolved.defaults.entries[1].options.colour, 'blue',
      "the checker's own value three levels down is unchanged")
  end

  -- The validator is injected from an independent source, so a schema without
  -- every section this module reads must not end the render.
  do
    install_stubs()
    local ok, err = pcall(function()
      local checker = check_mod.new(stub_validator({ schema = {} }), 'demo')
      checker:options({})
      checker:call('iconify', {}, {})
    end)
    check(ok, 'a schema with no sections does not raise', not ok and tostring(err) or nil)
  end

  -- An option the schema rejects is an error: it names a value the extension
  -- cannot use, and the author has to correct it.
  do
    install_stubs()
    local checker = check_mod.new(stub_validator({
      schema = schema_with({ inline = { type = 'boolean' } }),
      provided = { inline = 'sometimes' },
      valid = false,
      errors = { 'inline: must be of type "boolean", got "string".' },
      defaults = {},
    }), 'demo')
    checker:options({})
    equal(#recorded, 1, 'a rejected option is reported once')
    equal(recorded[1] and recorded[1].level, 'error', 'a rejected option is an error')
    equal(recorded[1] and recorded[1].message,
      '[demo] inline: must be of type "boolean", got "string".',
      'the rejected option message is reported unchanged')
  end

  -- The second return carries what the document set as well as what it
  -- resolved to. An extension needs `provided` to tell a value the author
  -- wrote from a key they never set, which no default can answer: a default is
  -- always present once declared, so `merged` alone cannot tell the two apart.
  do
    install_stubs()
    local checker = check_mod.new(stub_validator({
      schema = schema_with({
        inline = { type = 'boolean', default = true },
        set = { type = 'string', default = 'octicon' },
      }),
      provided = { inline = false },
      merged = { inline = false, set = 'octicon' },
      defaults = { inline = true, set = 'octicon' },
    }), 'demo')

    local defaults, resolved = checker:options({})
    equal(defaults.inline, true, '`options` still returns the defaults first')
    check(type(resolved) == 'table', '`options` returns a resolved table second',
      tostring(resolved))
    equal(resolved.defaults.inline, true, 'the resolved table carries the defaults')
    equal(resolved.merged.inline, false, 'the resolved table carries the merged values')
    equal(resolved.provided.inline, false, '`provided` holds a value the document wrote')
    equal(resolved.provided.set, nil, '`provided` omits a key the document never set')

    -- Without `provided` these two cases are the same table entry, which is
    -- the fault this return exists to prevent.
    check(resolved.provided.inline ~= nil and resolved.provided.set == nil,
      '`provided` tells a written value from an absent key',
      string.format('inline=%s set=%s', tostring(resolved.provided.inline),
        tostring(resolved.provided.set)))
    equal(resolved.merged.set, 'octicon',
      'an absent key still resolves to its default in `merged`')

    local again_defaults, again_resolved = checker:options({})
    equal(again_defaults.inline, true, 'the cached call returns the same defaults')
    check(again_resolved == resolved, 'the cached call returns the same resolved table',
      tostring(again_resolved))
  end

  -- Reading one option. Every extension needs the value of a single key, and
  -- before this each one read the document itself and decided what counted as
  -- true. Six different answers reached the fleet, none of them the schema's,
  -- so `enabled: no` turned a filter off in one extension and left it on in
  -- another. This reads what the validator resolved, so the schema is the only
  -- answer, and a key the document never set resolves to its declared default.
  do
    install_stubs()
    local checker = check_mod.new(stub_validator({
      schema = schema_with({
        enabled = { type = 'boolean', default = true },
        set = { type = 'string', default = 'octicon' },
      }),
      provided = { enabled = 'no' },
      merged = { enabled = false, set = 'octicon' },
      defaults = { enabled = true, set = 'octicon' },
    }), 'demo')

    checker:options({})
    equal(checker:option('enabled'), false,
      '`option` returns what the validator resolved, not what the document wrote')
    equal(checker:option('set'), 'octicon',
      '`option` returns the declared default for a key the document never set')
    equal(checker:option('absent'), nil, '`option` returns nil for a key no schema declares')
    equal(#recorded, 0, '`option` reports nothing about a key it can answer')
  end

  -- `option` before `options` is a fault in the extension, not in the document.
  -- It cannot answer, and answering nil in silence is the same quiet wrong
  -- value this whole path exists to stop, so it says so once.
  do
    install_stubs()
    local checker = check_mod.new(stub_validator({
      schema = schema_with({ enabled = { type = 'boolean', default = true } }),
      merged = { enabled = false },
      defaults = { enabled = true },
    }), 'demo')

    equal(checker:option('enabled'), nil, '`option` before `options` answers nothing')
    equal(#recorded, 1, '`option` before `options` is reported once')
    equal(recorded[1] and recorded[1].level, 'error',
      '`option` before `options` is an error, because the caller gets no value')
    equal(recorded[1] and recorded[1].message,
      '[demo] schema-check: `option("enabled")` was called before `options`',
      'the message names the key and the call that was missed')
  end

  -- A key that is not a string is the typo `option(meta)` makes, next to
  -- `options(meta)` one letter away. It is reported rather than indexed, so the
  -- mistake shows up instead of resolving to nil.
  do
    install_stubs()
    local checker = check_mod.new(stub_validator({
      schema = schema_with({ enabled = { type = 'boolean', default = true } }),
      merged = { enabled = false },
      defaults = { enabled = true },
    }), 'demo')
    checker:options({})

    equal(checker:option({}), nil, '`option` given a table answers nothing')
    equal(#recorded, 1, '`option` given a table is reported once')
    equal(recorded[1] and recorded[1].level, 'error', 'a key that is not a string is an error')
    check(recorded[1] and recorded[1].message:find('must be a string', 1, true) ~= nil,
      'the message says a key must be a string',
      recorded[1] and recorded[1].message or 'nothing was reported')
  end

  -- Without a schema there is nothing to resolve against, and the checker has
  -- already said so once. A second message per key read would bury it.
  do
    install_stubs()
    local checker = check_mod.new(
      stub_validator({ err = 'Could not open schema file: _schema.yml' }), 'demo')
    checker:options({})
    equal(checker:option('enabled'), nil, 'without a schema `option` answers nothing')
    equal(#recorded, 1, 'without a schema `option` reports nothing further')
  end

  -- Checking one element's attributes. The `attributes` section declares a map
  -- of groups, and a schema may use both a group named after the element and
  -- `_any`, which quarto-revealjs-tabset does: `panel-tabset` carries the
  -- tabset's own attributes and `_any` carries one a slide can take. So both
  -- apply, and the specific group runs last, over the result of `_any`. The
  -- real function hands an undeclared key straight back, so chaining the two
  -- passes is the whole of the merge.
  do
    install_stubs()
    local spec = {
      schema = { options = {}, shortcodes = {}, attributes = { ['_any'] = {}, tabset = {} } },
      groups = {
        ['_any'] = { resolve = { ['skip-clone'] = false } },
        ['panel-tabset'] = { resolve = { ['tab-active'] = 0 } },
      },
    }
    local checker = check_mod.new(stub_validator(spec), 'demo')

    local merged = checker:attributes({ ['skip-clone'] = 'no', other = 'kept' }, 'panel-tabset')
    equal(merged['skip-clone'], false, '`attributes` returns what `_any` resolved')
    equal(merged['tab-active'], 0, '`attributes` applies the named group over that result')
    equal(merged.other, 'kept', '`attributes` hands an undeclared attribute back unchanged')
    equal(#recorded, 0, '`attributes` reports nothing when every value is accepted')

    equal(#spec.attr_calls, 2, '`attributes` checks both `_any` and the named group')
    equal(spec.attr_calls[1].group, '_any', '`_any` is checked first, being the least specific')
    equal(spec.attr_calls[2].group, 'panel-tabset', 'the named group is checked second')
    equal(spec.attr_calls[2].input['skip-clone'], false,
      'the named group sees what `_any` resolved, not the original input')
  end

  -- A finding about an element's attribute is a warning. The attribute stays on
  -- the element whatever the schema says, so the rendered output does not
  -- change because of the finding, which is the reason a shortcode attribute is
  -- a warning too.
  do
    install_stubs()
    local spec = {
      schema = { options = {}, shortcodes = {}, attributes = { tabset = {} } },
      groups = {
        ['panel-tabset'] = {
          resolve = {},
          errors = { 'panel-tabset.tab-active: must be of type "integer", got "x".' },
          warnings = { 'panel-tabset.tab-actve: is not a recognised key and was ignored.' },
        },
      },
    }
    local checker = check_mod.new(stub_validator(spec), 'demo')
    checker:attributes({ ['tab-active'] = 'x' }, 'panel-tabset')

    equal(#recorded, 2, 'both the error and the warning are reported')
    equal(recorded[1].level, 'warning', 'a rejected attribute value is a warning')
    equal(recorded[2].level, 'warning', 'an unrecognised attribute is a warning')
    equal(recorded[1].message,
      '[demo] panel-tabset.tab-active: must be of type "integer", got "x".',
      'the validator message is reported unchanged, with the extension name')
  end

  -- Without a schema, or without an `attributes` section, there is nothing to
  -- check against and the attributes come back as they went in.
  do
    install_stubs()
    local checker = check_mod.new(
      stub_validator({ err = 'Could not open schema file: _schema.yml' }), 'demo')
    local given = { size = 'lg' }
    check(checker:attributes(given, 'modal') == given,
      'without a schema `attributes` hands back the table it was given', 'a different table')
    equal(#recorded, 1, 'without a schema `attributes` reports nothing further')

    install_stubs()
    local plain = check_mod.new(stub_validator({ schema = schema_with({}) }), 'demo')
    local held = { size = 'lg' }
    check(plain:attributes(held, 'modal') == held,
      'with no `attributes` section the table is handed back', 'a different table')
    equal(#recorded, 0, 'with no `attributes` section nothing is reported')
  end

  -- A group that is not a string is the same caller fault `option` guards, and
  -- it is reported rather than looked up. `nil` is not that fault: an element
  -- with no group of its own still takes whatever `_any` declares.
  do
    install_stubs()
    local spec = {
      schema = { options = {}, shortcodes = {}, attributes = { ['_any'] = {} } },
      groups = { ['_any'] = { resolve = { flag = true } } },
    }
    local checker = check_mod.new(stub_validator(spec), 'demo')

    local merged = checker:attributes({ flag = 'yes' }, nil)
    equal(merged.flag, true, 'without a group `attributes` still applies `_any`')
    equal(#spec.attr_calls, 1, 'without a group only `_any` is checked')
    equal(#recorded, 0, 'without a group nothing is reported')

    install_stubs()
    spec.attr_calls = nil
    local other = check_mod.new(stub_validator(spec), 'demo')
    equal(other:attributes({ flag = 'yes' }, {}), nil, '`attributes` given a table group answers nothing')
    equal(#recorded, 1, 'a group that is not a string is reported once')
    equal(recorded[1].level, 'error', 'a group that is not a string is an error')
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

  -- An attribute the schema rejects is a warning, not an error, because the
  -- rendered output does not change because of it. The call gives its required
  -- argument, so the missing argument path does not take over the reporting.
  do
    install_stubs()
    local checker = check_mod.new(stub_validator({
      schema = schema_with({}, { iconify = ICONIFY_ENTRY }),
      call = { errors = { 'iconify.size: must be one of: 1x, 2x, got 3z.' } },
    }), 'demo')
    checker:call('iconify', { 'fa6-brands:github' }, { size = '3z' })
    equal(#recorded, 1, 'a rejected attribute is reported once')
    equal(recorded[1] and recorded[1].level, 'warning',
      'a rejected attribute is a warning, because the output does not change')
    equal(recorded[1] and recorded[1].message,
      '[demo] iconify.size: must be one of: 1x, 2x, got 3z.',
      'the rejected attribute message is reported unchanged')
  end

  -- A quoted value checks as the same thing as an unquoted one. Quarto's
  -- metadata parser hands `aria-hidden='true'` over with its quotes attached,
  -- and without the strip the value is checked with them.
  do
    install_stubs()
    local spec = {
      schema = schema_with({}, { iconify = ICONIFY_ENTRY }),
      call = {},
    }
    local checker = check_mod.new(stub_validator(spec), 'demo')
    checker:call('iconify', { 'fa6-brands:github' },
      { ['aria-hidden'] = "'true'", size = '2x' })

    equal(spec.seen and spec.seen.kwargs['aria-hidden'], 'true',
      'a surrounding quote pair is stripped before the check')
    equal(spec.seen and spec.seen.kwargs.size, '2x',
      'an unquoted value reaches the validator unchanged')
    equal(spec.seen and spec.seen.args[1], 'fa6-brands:github',
      'a positional argument reaches the validator as a string')
    equal(#recorded, 0, 'a call the schema accepts reports nothing')
  end

  -- A kind with no severity is a fault in the module, and it says so rather
  -- than passing the finding off at a level nobody chose.
  do
    install_stubs()
    local checker = check_mod.new(stub_validator({ schema = schema_with({}) }), 'demo')
    local ok, err = pcall(checker._report, checker, 'not-a-kind', 'a finding')
    check(ok, 'an unmapped severity does not raise', not ok and tostring(err) or nil)
    equal(recorded[1] and recorded[1].level, 'error', 'an unmapped severity is an error')
    equal(recorded[1] and recorded[1].message,
      '[demo] schema-check has no severity for "not-a-kind": a finding',
      'an unmapped severity names the kind it could not report')
  end

  -- A missing required argument is the one call finding that is an error,
  -- because without it the shortcode renders nothing.
  do
    install_stubs()
    local checker = check_mod.new(stub_validator({
      schema = schema_with({}, { iconify = ICONIFY_ENTRY }),
      call = { errors = { 'iconify argument 1 ("icon") is required but was not provided.' } },
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
