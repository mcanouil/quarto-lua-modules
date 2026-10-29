# Changelog

## Unreleased

## 2.8.0 (2026-10-29)

- feat: `get_project_metadata` returns the `QUARTO_EXECUTE_INFO` path as a third value with each reason, so a caller can name the file without reading the variable again. Its four reasons are now a stable API that callers can compare against. (#21)

## 2.7.0 (2026-10-29)

- feat: Add `get_project_metadata`, which returns the project's `format.metadata` table from the `QUARTO_EXECUTE_INFO` file. When the file is set but can't be used, it returns `nil` and a short reason, so each extension can stay silent or warn in its own words. (#19)
- feat: `get_project_repo_url` takes an optional `format_meta` table. An extension that has already read the project metadata no longer reads the file a second time. (#19)
- fix: `get_project_repo_url` returns `nil` when `QUARTO_EXECUTE_INFO` holds JSON that isn't an object. It used to raise an error and stop the filter. (#19)

## 2.6.0 (2026-10-26)

- feat: Add `Checker:cells`, which checks the comment-pipe options of one code cell against the `cells` section and returns what they resolve to. It needs Quarto Wizard schema 2.3.0 or newer, whose validator provides `validate_cells`. (#16)

## 2.5.1 (2026-10-18)

- fix: Load sibling modules on q2, which has no `debug` library. An extension that vendors the modules no longer stops there with a shortcode script error. (#12)

## 2.5.0 (2026-09-12)

- feat: Add `Checker:format`, which checks one output format's options against the `formats` section and returns what they resolve to. It needs Quarto Wizard 3.6.0 or newer, whose `validate_format` reads the top level of the metadata where Quarto puts them.

## 2.4.0 (2026-09-09)

- feat: Add `Checker:option`, which returns the value the schema resolves an option to. An extension no longer decides for itself what counts as true, so `enabled: no` means the same thing in every extension.
- feat: Add `Checker:attributes`, which checks one element's attributes against the `attributes` section and returns what they resolve to. Both the element's own group and `_any` apply, the named group last.
- docs: State that `Checker:options` reads the metadata of its first call only. A later call returns what the first call resolved, so a caller that needs a second document checked builds a second checker.

## 2.3.0 (2026-09-07)

- refactor: Remove the `@version` line from the header of every module. The release no longer stamps a version into a module, so the bytes of a module now change only when its code changes.

## 2.2.0 (2026-09-06)

- fix: The `schema-check` module could not find the schema of an extension whose entry points are in a subdirectory. `new` now takes the schema path as an optional third argument, and it still reads `_schema.yml` when the argument is absent.

## 2.1.0 (2026-09-06)

- feat: Add the `schema-check` module. It checks a document and a shortcode call against the extension's `_schema.yml`, and it reports what it finds.

## 2.0.0 (2026-09-05)

- refactor: Move `has_extension` and `is_markdown` from the `lookup` module into the `paths` module. Both functions ask a question about a path, so `paths` is where they belong. A consumer that called `lookup.has_extension` or `lookup.is_markdown` must call the same function on `paths`.

## 1.0.0 (2026-08-26)

- feat: Initial release.
