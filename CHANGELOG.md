# Changelog

## Unreleased

## 2.1.0 (2026-09-06)

- feat: Add the `schema-check` module. It checks a document and a shortcode call against the extension's `_schema.yml`, and it reports what it finds.

## 2.0.0 (2026-09-05)

- refactor: Move `has_extension` and `is_markdown` from the `lookup` module into the `paths` module. Both functions ask a question about a path, so `paths` is where they belong. A consumer that called `lookup.has_extension` or `lookup.is_markdown` must call the same function on `paths`.

## 1.0.0 (2026-08-26)

- feat: Initial release.
