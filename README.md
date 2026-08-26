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
| `lookup.lua` | Membership tests, keyword mapping, and file type checks. |
| `metadata.lua` | Reads extension configuration out of document metadata. |
| `pandoc-helpers.lua` | Builds Pandoc elements and detects the output format. |
| `paths.lua` | Resolves a path relative to the project. |
| `string.lua` | Splits, trims, and escapes for HTML, LaTeX, Typst, JavaScript, and Lua. |

## Usage

Copy the modules you need into your extension, then load them the way Quarto resolves paths inside a filter:

```lua
local str = require(quarto.utils.resolve_path('_modules/string.lua'):gsub('%.lua$', ''))
```

A module that needs another one finds it in the same directory, so copy them together.

## Development

The modules run inside Quarto's Lua, and several of them call `pandoc.*`, so the tests run there too:

```bash
quarto pandoc lua tests/run.lua
```

Every module is loaded, every exported function is checked to exist, and the pure functions are called with known inputs.

## Licence

[MIT](https://github.com/mcanouil/quarto-lua-modules?tab=MIT-1-ov-file#readme).
