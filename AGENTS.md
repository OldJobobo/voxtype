# Repository Guidelines

## Project Structure & Module Organization

Voxtype is a Rust workspace centered on the main crate in `src/`. CLI entrypoints live in `src/bin/`, app command handling in `src/app/`, configuration in `src/config/`, audio and transcription logic in `src/audio/` and `src/transcribe/`, output drivers in `src/output/`, setup flows in `src/setup/`, and TUI code in `src/tui/`. Integration tests live in `tests/` with fixtures under `tests/fixtures/`. Quickshell QML lives in `quickshell/`, examples in `examples/`, packaging files in `packaging/`, docs in `docs/`, and website assets in `website/`.

## Build, Test, and Development Commands

- `cargo check` compiles the Rust crate quickly without producing release binaries.
- `cargo test` runs unit and integration tests.
- `cargo fmt --check` verifies Rust formatting.
- `cargo run -- daemon` starts a local daemon from the checkout.
- `cargo run --bin voxtype-osd-quickshell -- --qml-path quickshell` tests the Quickshell OSD launcher from the repo tree.
- `cargo build --features osd-gtk4` or `cargo build --features osd-native` builds optional OSD frontends.

## Coding Style & Naming Conventions

Use standard Rust formatting through `rustfmt`; keep imports and module boundaries consistent with nearby code. Rust modules and functions use `snake_case`, types use `CamelCase`, and constants use `SCREAMING_SNAKE_CASE`. Prefer typed config structs and serde attributes over ad hoc parsing. QML files use component-style `CamelCase.qml` names and shared modules registered in `quickshell/voxtype-shared/qmldir`.

## Testing Guidelines

Add focused unit tests near the module being changed and integration tests under `tests/` when behavior crosses module boundaries. Test names should describe behavior, such as `parse_style_strips_own_flag` or `energy_vad_rejects_pure_silence`. Run `cargo test` before PRs; also run targeted commands such as `cargo test osd::style` while iterating.

## Commit & Pull Request Guidelines

Recent commits use short imperative summaries, for example `Add Quickshell OSD theming support` or `TUI: support xfce4-terminal`. Keep commits scoped and avoid mixing generated/package updates with unrelated feature work. PRs should describe user-facing behavior, implementation highlights, compatibility notes, and validation commands. Include screenshots or recordings for visible UI/QML changes when practical.

## Security & Configuration Tips

Do not commit local secrets, model files, runtime state, or personal config. Treat custom QML packages and hook commands as trusted code; document this clearly when adding examples. Keep untracked local helpers, experiments, and machine-specific scripts out of PRs unless they are intentionally part of the feature.
