# Cooldowns

Documentation site for [cooldowns.dev](https://cooldowns.dev) that
explains what dependency cooldowns are, why they matter, and how to
configure them for various package managers. Includes a helper shell
script (`cooldowns.sh`) that automates checking and configuring cooldowns.

## Conventions

- `README.md` is the single source of truth for documentation content.
  `build.py` renders it into the single-page site in `site/`, using the
  Jinja2 templates in `docs/templates/` and the CSS, JS, and self-hosted
  fonts (Red Hat Text and Red Hat Mono, with their licenses) in `docs/static/`.

- `docs/tools.toml` holds per-tool metadata the README can't express
  (support level, first version, default cooldown, unit, three-day value).
  It drives the sidebar, the per-tool support cards, and the support matrix.
  When adding, renaming, or removing a tool section in `README.md`, update
  `docs/tools.toml` and the README quick reference table together. A new H2
  section must be added to an `[[ecosystem]]` or `[[group]]`. The build fails
  if these disagree, or if a tool's `three_days` value no longer appears in
  its README section.

- `docs/anchors.txt` lists heading ids that inbound links depend on. Renaming
  a heading changes its id and fails the build; only remove an entry if you
  mean to break links to it.

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

- Lint and format `build.py` with ruff after each change to it (settings
  in `ruff.toml`):

  ```sh
  uv run --with ruff ruff check
  uv run --with ruff ruff format
  ```

- Lint markdown after each change to the documentation files:

  ```sh
  uv run --with mdlint mdlint check
  ```

- Build and validate docs after each change to README.md or `docs/`:

  ```sh
  uv run build.py
  ```

  To view the result locally, build and serve it on <http://127.0.0.1:8000/>
  (rerun after each edit):

  ```sh
  uv run build.py --serve
  ```
