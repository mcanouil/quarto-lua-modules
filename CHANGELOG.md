# Changelog

## Unreleased

- refactor: Move `has_extension` and `is_markdown` from the `lookup` module into the `paths` module. Both functions ask a question about a path, so `paths` is where they belong. A consumer that called `lookup.has_extension` or `lookup.is_markdown` must call the same function on `paths`.

## 1.0.0 (2026-08-26)

- feat: Initial release.
