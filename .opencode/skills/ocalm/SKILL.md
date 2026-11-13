---
name: ocalm
description: >-
  Toggle Firstmate's Calm transcript presentation on OpenCode, the OpenCode port of /calm.
  Use when the captain invokes /ocalm, asks for Calm or calm mode on OpenCode, or asks to turn OpenCode's quiet transcript on or off, including from a headless `opencode run`.
user-invocable: true
---

# /ocalm

`/ocalm` is the OpenCode port of Firstmate's `/calm` toggle.
It flips the same per-home Calm preference Pi and Claude Code use, so one choice applies on all three harnesses.
[`docs/calm.md`](../../../docs/calm.md#opencode) owns the full contract.

## Toggle it

Run the toggle from the Firstmate repository root that owns this skill:

```sh
node .opencode/plugins/fm-ocalm/ocalm.js toggle
```

Use `on` or `off` instead of `toggle` to set a choice outright, and `status` to read it without changing anything.
Bun runs the same file.
Keep `FM_HOME` as the session has it, so the choice lands in the effective Firstmate home.

Relay the printed line as the outcome:

- `Calm on` or `Calm off` means the choice is saved and OpenCode's transcript settings follow it (exit 0).
- `Calm unchanged: could not save ...` means nothing changed (exit 1).
- `Calm on (OpenCode transcript settings unchanged: ...)` or the `off` equivalent means the choice saved but OpenCode's settings file could not change (exit 2).

In the OpenCode TUI, the `/ocalm` slash command and the "Toggle Calm" palette entry do the same thing and show the result as a short notice.

## What it does on OpenCode

- Saves the choice in the home's `config/calm` before anything else changes.
- While Calm is on, sets OpenCode's own quiet transcript settings in the global CLI settings file: reasoning hidden, each run of tools and thoughts summarized, and related items grouped.
  Open TUI sessions redraw at once, including rows already on screen.
- When Calm turns off, puts back exactly the settings that were there before.
- While Calm is on and a run is active, the TUI shows the Firstmate sailboat in place of OpenCode's footer progress indicator.

## What it does not do

- It hides nothing row by row: short working notes and the summary rows stay visible, because OpenCode's plugin surface cannot hide individual transcript rows.
- It never changes stored sessions, transcripts, exports, or model context.
- A headless `opencode run` has no TUI, so there is no live transcript or sailboat to change there; the toggle still saves the choice and the settings for the next TUI session.
