# Repository Guidelines

## Project Structure & Module Organization
`lua/quicktest.lua` is the public entry point. Core execution logic lives in `lua/quicktest/module.lua`, UI behavior in `lua/quicktest/ui.lua`, and shared helpers in files such as `fs_utils.lua`, `ts.lua`, `notify.lua`, and `colored_printer.lua`. Runtime commands are registered from `plugin/quicktest.lua`.

Adapters live under `lua/quicktest/adapters/<name>/`. Keep adapter-specific parsing and helpers close to the adapter, for example `query.lua`, `helpers.lua`, or `diagnostics.lua`. Tests live in `tests/`; sample fixture projects for supported ecosystems live in `tests/support/`.

## Architecture

```mermaid
flowchart TD
  U[User / keymap / :QuicktestRun*] --> P[plugin/quicktest.lua\nCreate user commands]
  P --> Q[lua/quicktest.lua\nPublic API + config]
  Q --> M[lua/quicktest/module.lua\nDispatch, job lifecycle, previous-run persistence]

  M --> A{Adapter selection}
  A -->|auto/manual| GO[adapters/*/init.lua]

  GO --> BP[build_line/file/dir/all_run_params]
  BP --> TS[quicktest.ts\nTree-sitter helpers]
  BP --> FS[quicktest.fs_utils\nProject root/path detection]
  BP --> AQ[adapter query/helpers/diagnostics]

  GO --> RUN[adapter.run(params, send)]
  RUN --> JOB[plenary.job / vim.system / meson]
  JOB --> CH[Async channel]
  CH --> M

  M --> UI[quicktest.ui\nsplit/popup buffers]
  M --> CP[quicktest.colored_printer\nANSI highlight rendering]
  M --> N[quicktest.notify\nWarnings/info]
  M --> D[vim.diagnostic\nadapter after_run]

  M --> PR[stdpath(data)/quicktest_previous_runs.json]
  PR --> RP[run_previous()]

  T[tests/*_spec.lua] --> MINI[tests/minimal_init.lua]
  MINI --> FIX[tests/support/* fixtures]
```

### Runtime flow
1. Commands in `plugin/quicktest.lua` parse CLI args and call `require("quicktest").run_line/file/dir/all`.
2. `lua/quicktest.lua` stores global config and forwards all work to `lua/quicktest/module.lua`.
3. `module.lua` picks an adapter from `config.adapters`, asks it to build run params for the current buffer/cursor, and persists enough context to support `run_previous()`.
4. The selected adapter resolves project context and test target, usually with `quicktest.ts` for Tree-sitter extraction and `quicktest.fs_utils` for root detection.
5. `adapter.run()` starts the real test process and streams `stdout` / `stderr` / `exit` events back through the callback channel.
6. `module.lua` owns the live job state, pushes output into the split/popup buffers, updates timer/status lines, applies ANSI colors through `colored_printer.lua`, and stops auto-scroll if the user has scrolled away.
7. Optional `adapter.after_run()` hooks translate results into diagnostics or adapter-specific post-processing.

### Module responsibilities
- `lua/quicktest.lua`: public API, default config, thin forwarding layer.
- `lua/quicktest/module.lua`: central orchestrator; adapter selection, run preparation, async event loop, UI refresh, cancel/retry, and previous-run persistence.
- `lua/quicktest/ui.lua`: owns the two output surfaces (`quicktest://quicktest-split` and `quicktest://quicktest-popup`) and window open/close/scroll behavior.
- `lua/quicktest/colored_printer.lua`: strips/parses ANSI escape sequences and maps them to Neovim highlight groups.
- `lua/quicktest/ts.lua`: shared Tree-sitter helpers used by adapters that need “current test under cursor” semantics.
- `lua/quicktest/fs_utils.lua`: root finding and path helpers used by adapters to discover project boundaries and config files.
- `lua/quicktest/notify.lua`: thin wrapper around `vim.notify`.

### Adapter contract
Each adapter under `lua/quicktest/adapters/*/init.lua` follows the same shape:

- `name`: adapter id used for manual selection and previous-run replay.
- `is_enabled(bufnr, type)`: decides whether the adapter can handle the current buffer/run type.
- `build_line_run_params`, `build_file_run_params`, `build_dir_run_params`, `build_all_run_params`: map editor context to concrete command parameters.
- `run(params, send)`: execute the test command and stream events back to the core.
- `title(params)`: render the header shown in the output window.
- `after_run(params, results)`: optional diagnostics or result post-processing.

Concrete adapters differ mainly in target discovery:

- `golang`, `vitest`, `playwright`, `pytest`, `elixir` rely on Tree-sitter and project-root/config detection.
- `criterion` adds a build step and structured JSON result parsing before diagnostics.
- `rspec` delegates more logic into local `helpers.lua` and `diagnostics.lua`.
- `dart` mixes line scanning with Tree-sitter to find the nearest `test()` / `group()`.

## Build, Test, and Development Commands
Use `make test` to run the Neovim test suite through Plenary with `tests/minimal_init.lua`. Use `make stylua` to check Lua formatting before pushing. To auto-format, run `stylua --glob '**/*.lua' -- lua`.

Examples:

```sh
make test
make stylua
stylua --glob '**/*.lua' -- lua
```

## Coding Style & Naming Conventions
Lua formatting is enforced by StyLua: 2-space indentation, 120-column width, Unix line endings, and function-call parentheses always present. Prefer double quotes when StyLua selects them automatically.

Match existing naming patterns: snake_case for module files and locals, `init.lua` for adapter entry points, and focused helper files such as `query.lua` for Tree-sitter queries. Keep new code inside `lua/quicktest/` unless it is a plugin command or test fixture.

## Testing Guidelines
Write tests with Plenary/Busted style in `tests/*_spec.lua`. Keep unit-like coverage near the behavior under test and add or extend fixtures in `tests/support/` when adapter behavior depends on real project layouts. If you add a new adapter, include at least one representative fixture and a spec that exercises line/file/dir/all behavior where applicable.

## Commit & Pull Request Guidelines
Recent history favors short conventional messages such as `fix: ...`, `fix(scope): ...`, `refactor(scope): ...`, and `chore: ...`. Follow that style and keep each commit narrowly scoped.

Pull requests should describe the user-visible change, note affected adapters or commands, and list verification steps such as `make test` and `make stylua`. Include screenshots or terminal output only when UI behavior in split/popup views changes.
