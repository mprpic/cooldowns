# Cooldowns

Documentation site for [cooldowns.dev](https://cooldowns.dev) that
explains what dependency cooldowns are, why they matter, and how to
configure them for various package managers. Includes a helper shell
script (`cooldowns.sh`) that automates checking and configuring cooldowns.

## Conventions

- `README.md` is the single source of truth for documentation content.
  `docs/index.md` includes it via `pymdownx.snippets` (`--8<-- "README.md"`)
  and only adds frontmatter. Edit `README.md`, not `docs/index.md`.

- `cooldowns.sh` must work on both Linux and macOS. Use portable constructs
  (e.g. `awk` instead of `grep -oP`, pure-bash version comparison instead
  of `sort -V`).

- There are two separate changelogs:
  - The changelog in `cooldowns.sh` records script functionality changes
    (new tool support, behavior changes). Keep entries to a single line.
  - The changelog in `README.md` records larger documentation additions
    only (new tool docs, new sections, new configuration options). Do not
    add entries for corrections, wording tweaks, small clarifications, new
    citations, or script-level changes.

- Run `shellcheck cooldowns.sh` after each change to the script.

- Lint markdown after each change to the documentation files:

  ```sh
  uv run --with mdlint mdlint check
  ```

- Build and validate docs after each change to README.md:

  ```sh
  uv run --with zensical zensical build
  ```
