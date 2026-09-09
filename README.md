# Quarto Lua Modules

Shared Lua modules for Quarto extensions: colour conversion, string escaping, metadata access, path resolution, and the other utilities that every extension ends up needing.

They are meant to be vendored. Quarto ships no package manager for Lua, so an extension copies the modules it uses into its own `_extensions/<name>/_modules/` directory and commits them, rather than depending on this repository at render time.

## Modules

| Module | What it does |
| --- | --- |
| `colour.lua` | Converts between CSS colour notations and HTML hex. |
| `content-extraction.lua` | Pulls sections, divs, and code metadata out of a document. |
| `git.lua` | Reads the current Git repository. |
| `html.lua` | Builds raw HTML and registers HTML dependencies. |
| `logging.lua` | Writes messages prefixed with the extension name. |
| `lookup.lua` | Membership tests and keyword mapping. |
| `metadata.lua` | Reads extension configuration out of document metadata. |
| `pandoc-helpers.lua` | Builds Pandoc elements and detects the output format. |
| `paths.lua` | Resolves a path relative to the project and checks a URI's file type. |
| `schema-check.lua` | Checks a document and a shortcode call against the extension's `_schema.yml`. |
| `string.lua` | Splits, trims, and escapes for HTML, LaTeX, Typst, JavaScript, and Lua. |

## Usage

Copy the modules you need into your extension, then load them the way Quarto resolves paths inside a filter:

```lua
local str = require(quarto.utils.resolve_path('_modules/string.lua'):gsub('%.lua$', ''))
```

A module that needs another one finds it in the same directory, so copy them together.

`schema-check.lua` takes its validator as an argument rather than loading one, so an extension can vendor the two from different sources:

```lua
local checker = check.new(validator, 'iconify')
local defaults, resolved = checker:options(meta)
local inline = checker:option('inline')
local attributes = checker:attributes(el.attributes, 'CodeBlock')
checker:call('iconify', args, kwargs)
```

`options` returns the schema defaults first.
It returns `provided`, `merged` and `defaults` second, for an extension that has to tell a value the document wrote from a key it never set.

`option` returns what the schema resolves one option to, after `options` has run.
Read it rather than the document, so that the schema decides what counts as true and a key the document never set gives its declared default.

`attributes` checks one element against the `attributes` section and returns what its attributes resolve to.
Both the element's own group and `_any` apply, the named group last.

`new` reads `_schema.yml` beside the entry point that runs.
An extension whose entry points live in a subdirectory gives the path as a third argument:

```lua
local checker = check.new(validator, 'iconify', '../_schema.yml')
```

Build the checker at file scope, and not inside a shortcode handler.
The schema is then read once for the render, and not once for each call.

## Development

The modules run inside Quarto's Lua, and several of them call `pandoc.*`, so the tests run there too:

```bash
quarto pandoc lua tests/run.lua
```

Every module is loaded, every exported function is checked to exist, and the pure functions are called with known inputs.

## Licence

[MIT](https://github.com/mcanouil/quarto-lua-modules?tab=MIT-1-ov-file#readme).
