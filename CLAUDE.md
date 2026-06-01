# Cooldowns

Documentation site for [cooldowns.dev](https://cooldowns.dev) that
explains what dependency cooldowns are, why they matter, and how to
configure them for various package managers. Includes a helper shell
script (`cooldowns.sh`) that automates checking and configuring cooldowns.

## Conventions

- `docs/index.md` and `README.md` must be kept in sync — they have the same
  content except for frontmatter in `docs/index.md`. Verify with:
  ```sh
  diff <(sed '1,/^---$/d' docs/index.md) README.md
  ```

- `cooldowns.sh` must work on both Linux and macOS. Use portable constructs
  (e.g. `awk` instead of `grep -oP`, pure-bash version comparison instead
  of `sort -V`).

- There are two separate changelogs:
  - The changelog in `cooldowns.sh` records script functionality changes
    (new tool support, behavior changes). Keep entries to a single line.
  - The changelog in `docs/index.md` (and `README.md`) records
    documentation changes only (new tool docs, changes in configuration).
    Do not duplicate script-level changes here.

- Run `shellcheck cooldowns.sh` after each change to the script.

- Build and validate docs after each change to docs/index.md:
  ```sh
  uv run --with zensical zensical build
  ```
