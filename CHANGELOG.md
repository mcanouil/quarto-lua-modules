# Changelog

## Unreleased

- refactor: Remove the `@version` line from the header of every module. The release no longer stamps a version into a module, so the bytes of a module now change only when its code changes.

## 2.2.0 (2026-09-06)

- fix: The `schema-check` module could not find the schema of an extension whose entry points are in a subdirectory. `new` now takes the schema path as an optional third argument, and it still reads `_schema.yml` when the argument is absent.

## 2.1.0 (2026-09-06)

- feat: Add the `schema-check` module. It checks a document and a shortcode call against the extension's `_schema.yml`, and it reports what it finds.

## 2.0.0 (2026-09-05)

- refactor: Move `has_extension` and `is_markdown` from the `lookup` module into the `paths` module. Both functions ask a question about a path, so `paths` is where they belong. A consumer that called `lookup.has_extension` or `lookup.is_markdown` must call the same function on `paths`.

## 1.0.0 (2026-08-26)

- feat: Initial release.
