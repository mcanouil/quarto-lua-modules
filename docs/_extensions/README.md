# Documentation website extensions

`mcanouil/atelier` is the dependency of the website itself: the project type and theme.
It arrives with the scaffold, which carries its own copy, and is checked in like any other Quarto extension.
Beyond that it is managed for you: [Quarto Wizard](https://m.canouil.dev/quarto-wizard) installs it, and the Quarto Extensions Updates workflow keeps it current by scanning this directory.

Atelier includes the iconify, gitlink, code-window, toc-depth, and collapse-output extensions, under `mcanouil/atelier/_extensions/`.
Do not add a separate copy of one of these extensions here, because both copies then run.

> [!IMPORTANT]
> Do not add or update them by hand with the Quarto CLI.
>
> `quarto add` and `quarto update` rewrite the manifest and drop the `source` and `source-type` fields, which are the only record of where each extension came from and at which version. An extension without them is invisible to the updater, and stays at whatever version it was left on.
>
> `quarto add` also fails here outright: `../_quarto.yml` declares `project: type: atelier`, and it builds a project context before installing anything, so it reports `Unsupported project type atelier` whenever atelier is missing or is the extension being replaced.

Anything this site needs beyond atelier is installed here the same way, through Quarto Wizard, and committed.
