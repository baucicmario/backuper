# Contributing

## Guardrails — rules for every new file

1. **New public commands go in `bin/` only.**
   If a user is meant to run it, it gets a `bin/` entry. Do not add more
   root-level `*.sh` entrypoints beyond `setup.sh` and `backup.sh`.

2. **New shared functions go in `lib/common.sh`.**
   If the same logic appears in two scripts, it belongs in `lib/`.
   Never duplicate logging, pkg-manager detection, or Docker helpers
   inside a step script.

3. **New pipeline steps go in `modules/<module>/steps/` with a number prefix.**
   The number controls execution order. Leave gaps (01, 03, 05) so new
   steps can be inserted without renumbering existing ones. Steps must
   accept explicit positional arguments — not rely on unset globals.

4. **Data files go in `modules/<module>/data/`.**
   `.txt`, `.yaml`, `.json` lookup or config files must not live alongside
   executable `.sh` files.

5. **New backup domains get their own module under `modules/`.**
   Don't add "phase N" — add `modules/database/`, `modules/volumes/`, etc.
   Each module gets `run.sh` + `steps/` + `data/`.

6. **Deprecated code goes in `deprecated/<name>/` with a `README.md`**
   explaining why it is deprecated and what supersedes it. Never delete
   deprecated code without a release note.

7. **Never put spaces in directory or file names.**
   The shell quoting cost is never worth it.

8. **Misspellings in directory names are bugs, not style.**
   Check spelling before committing any new path.

9. **Every `source` path uses `SCRIPT_DIR` resolution.**
   Always resolve: `SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"`
   Never hardcode relative paths like `source ../../lib/common.sh`.

10. **`lib/` files are sourced, never executed directly.**
    Files in `lib/` have no standalone execution path. They are always
    loaded via `source`.

## Code style

- `set -euo pipefail` at the top of every script
- Use `info`, `ok`, `warn`, `die` from `lib/common.sh` for all output
- Use `require_cmd <name>` to assert a dependency exists
- Prefer `[[ ]]` over `[ ]` for conditionals
- Quote every variable: `"$VAR"`, not `$VAR`
