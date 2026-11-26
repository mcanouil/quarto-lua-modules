# Quarto Lua Modules

Shared Lua modules for Quarto extensions: colour conversion, string escaping, metadata access, path resolution, schema checks, and values that Quarto 1 and Quarto 2 expose differently.

Quarto has no package manager for Lua.
An extension therefore copies the modules it uses into its own repository, and commits them.
The modules are not loaded from this repository at render time.

Full documentation is at <https://m.canouil.dev/quarto-lua-modules/>:

- [Reference](https://m.canouil.dev/quarto-lua-modules/reference.html) for every module and function.
- [Vendoring](https://m.canouil.dev/quarto-lua-modules/vendoring.html) for how to copy the modules in, declare them in `_dependencies.yml`, and update them, by hand or with `scripts/vendor.sh` from the release.
- [Examples](https://m.canouil.dev/quarto-lua-modules/examples.html) for short working snippets.

## Quick start

Copy `string.lua` into `_vendor/quarto-lua-modules/` in your extension, then load it from a filter:

```lua
local str = require(quarto.utils.resolve_path('_vendor/quarto-lua-modules/string.lua'):gsub('%.lua$', ''))
print(str.escape_html('Hello <World>'))
```

The output is `Hello &lt;World&gt;`.

## Development

The modules run inside Quarto's Lua, and several of them call `pandoc.*`, so the tests run there too:

```bash
quarto pandoc lua tests/run.lua
```

## Licence

[MIT](https://github.com/mcanouil/quarto-lua-modules?tab=MIT-1-ov-file#readme).
