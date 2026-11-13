#!/usr/bin/env bash
# Portable checks for the OpenCode Calm port (.opencode/plugins/fm-ocalm and the
# .opencode/skills/ocalm skill), with no OpenCode binary and no model tokens:
#   - the toggle reads and writes the shared config/calm preference in both directions,
#     honoring the documented home resolution, value format, and failed-write rule;
#   - OpenCode's quiet CLI settings are applied while Calm is on and restored to the
#     exact prior values when the last home turns it off;
#   - the TUI plugin, driven through a stand-in context under Bun, registers /ocalm,
#     toggles with a notice, and draws the shared sprite core while a run is active;
#   - the boundary holds: a full cycle changes only the preference, the CLI settings,
#     and the restore record, never session data, transcripts, exports, or model context.
# docs/calm.md owns the contract and docs/calm-mode-feasibility.md the live evidence.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

PLUGIN="$ROOT/.opencode/plugins/fm-ocalm"
OCALM="$PLUGIN/ocalm.js"
SPRITE="$ROOT/.opencode/plugins/lib/fm-calm-working-ship-sprite.ts"
TMP_ROOT=$(fm_test_tmproot fm-ocalm-opencode)

command -v node >/dev/null 2>&1 || { echo "skip: node not found for the OpenCode Calm checks"; exit 0; }

# sandbox <name>: a private HOME, XDG config, and Firstmate home; prints its directory.
sandbox() {
  local dir="$TMP_ROOT/$1"
  mkdir -p "$dir/home" "$dir/xdg/opencode" "$dir/fmhome/config" "$dir/fmhome/state"
  printf '%s\n' "$dir"
}

# ocalm <sandbox> <args...>: run the skill's CLI inside a sandbox.
ocalm() {
  local dir=$1
  shift
  env -u FM_ROOT_OVERRIDE -u FM_CONFIG_OVERRIDE HOME="$dir/home" XDG_CONFIG_HOME="$dir/xdg" FM_HOME="$dir/fmhome" \
    node "$OCALM" "$@"
}

json_equal() {  # <file-a> <file-b>
  node -e '
    const fs = require("node:fs");
    const [a, b] = process.argv.slice(1).map((path) => JSON.parse(fs.readFileSync(path, "utf8")));
    process.exit(JSON.stringify(a) === JSON.stringify(b) ? 0 : 1);
  ' "$1" "$2"
}

json_get() {  # <file> <dotted-path>
  node -e '
    const value = process.argv[2].split(".").reduce((node, key) => node?.[key], JSON.parse(require("node:fs").readFileSync(process.argv[1], "utf8")));
    process.stdout.write(value === undefined ? "<absent>" : String(value));
  ' "$1" "$2"
}

file_mode() {  # <file>
  node -e 'process.stdout.write((require("node:fs").statSync(process.argv[1]).mode & 0o777).toString(8))' "$1"
}

test_preference_toggle() {
  local dir out pref
  dir=$(sandbox preference)
  pref="$dir/fmhome/config/calm"
  out=$(ocalm "$dir" status) || fail "status failed: $out"
  assert_contains "$out" "Calm off" "an absent preference did not read as off"
  out=$(ocalm "$dir" toggle) || fail "toggle on failed: $out"
  [ "$out" = "Calm on" ] || fail "toggle on printed '$out'"
  [ "$(od -An -c "$pref" | tr -d ' ')" = 'on\n' ] || fail "toggle on did not write exactly 'on' and one newline"
  out=$(ocalm "$dir" toggle) || fail "toggle off failed: $out"
  [ "$out" = "Calm off" ] || fail "toggle off printed '$out'"
  [ "$(od -An -c "$pref" | tr -d ' ')" = 'off\n' ] || fail "toggle off did not write exactly 'off' and one newline"
  printf 'max\n' >"$pref"
  out=$(ocalm "$dir" toggle) || fail "toggle from legacy max failed: $out"
  [ "$out" = "Calm off" ] || fail "legacy max did not read as on, so toggling it printed '$out'"
  printf 'garbage\n' >"$pref"
  out=$(ocalm "$dir" status)
  assert_contains "$out" "Calm off" "an unrecognized value did not read as off"

  # Resolution order: FM_HOME, then FM_ROOT_OVERRIDE, then the tracked code root.
  mkdir -p "$dir/rootoverride/config"
  out=$(env -u FM_HOME -u FM_CONFIG_OVERRIDE HOME="$dir/home" XDG_CONFIG_HOME="$dir/xdg" FM_ROOT_OVERRIDE="$dir/rootoverride" node "$OCALM" on) \
    || fail "FM_ROOT_OVERRIDE toggle failed: $out"
  [ "$(cat "$dir/rootoverride/config/calm")" = on ] || fail "FM_ROOT_OVERRIDE did not select the preference home"
  out=$(env -u FM_CONFIG_OVERRIDE HOME="$dir/home" XDG_CONFIG_HOME="$dir/xdg" FM_HOME="$dir/fmhome" FM_ROOT_OVERRIDE="$dir/rootoverride" node "$OCALM" status)
  assert_contains "$out" "$dir/fmhome/config/calm" "FM_HOME did not win over FM_ROOT_OVERRIDE"
  out=$(node --input-type=module -e "
    import { ocalmPreferencePath } from $(node -e 'process.stdout.write(JSON.stringify(process.argv[1]))' "$OCALM");
    process.stdout.write(ocalmPreferencePath({}));
  ") || fail "the code-root resolution failed: $out"
  [ "$out" = "$ROOT/config/calm" ] || fail "with no home variables the preference resolved to $out, not the tracked code root"
  ocalm "$dir" off >/dev/null
  pass "the toggle writes and reads the shared config/calm preference in both directions, with legacy max as on and the documented resolution order"
}

test_failed_write_changes_nothing() {
  local dir out status before
  dir=$(sandbox failed-write)
  printf '{\n  "session": {"thinking": "show"}\n}\n' >"$dir/xdg/opencode/cli.json"
  before=$(cat "$dir/xdg/opencode/cli.json")
  printf 'not a directory\n' >"$dir/blocker"
  out=$(env -u FM_HOME -u FM_ROOT_OVERRIDE HOME="$dir/home" XDG_CONFIG_HOME="$dir/xdg" FM_CONFIG_OVERRIDE="$dir/blocker/config" node "$OCALM" on)
  status=$?
  [ "$status" -eq 1 ] || fail "an unwritable preference exited $status, not 1"
  assert_contains "$out" "Calm unchanged: could not save $dir/blocker/config/calm" "the failed save was not reported as unchanged"
  [ "$(cat "$dir/xdg/opencode/cli.json")" = "$before" ] || fail "a failed save still changed OpenCode's settings"
  [ ! -e "$dir/xdg/opencode/fm-ocalm-restore.json" ] || fail "a failed save still wrote a restore record"

  printf '{ not json\n' >"$dir/xdg/opencode/cli.json"
  out=$(ocalm "$dir" on)
  status=$?
  [ "$status" -eq 2 ] || fail "an unreadable settings file exited $status, not 2"
  assert_contains "$out" "Calm on (OpenCode transcript settings unchanged:" "an unreadable settings file was not reported"
  [ "$(cat "$dir/xdg/opencode/cli.json")" = '{ not json' ] || fail "an unreadable settings file was overwritten"
  [ "$(cat "$dir/fmhome/config/calm")" = on ] || fail "the choice did not persist when only the settings file failed"
  pass "a failed preference write changes nothing, and an unreadable settings file is reported and left alone"
}

test_cli_settings_apply_and_restore() {
  local dir cli out
  dir=$(sandbox settings)
  cli="$dir/xdg/opencode/cli.json"
  printf '{\n  "theme": {"name": "carbonfox"},\n  "session": {"thinking": "show", "sidebar": "auto"}\n}\n' >"$cli"
  chmod 600 "$cli"
  cp "$cli" "$dir/original.json"
  out=$(ocalm "$dir" on) || fail "toggle on failed: $out"
  [ "$(json_get "$cli" session.thinking)" = hide ] || fail "Calm on did not hide reasoning"
  [ "$(json_get "$cli" session.verbosity)" = low ] || fail "Calm on did not set low verbosity"
  [ "$(json_get "$cli" session.grouping)" = auto ] || fail "Calm on did not set automatic grouping"
  [ "$(json_get "$cli" session.sidebar)" = auto ] || fail "Calm on dropped an unrelated session setting"
  [ "$(json_get "$cli" theme.name)" = carbonfox ] || fail "Calm on dropped an unrelated top-level setting"
  [ "$(file_mode "$cli")" = 600 ] || fail "Calm on changed the settings file's mode"
  out=$(ocalm "$dir" on) || fail "a second on failed: $out"
  out=$(ocalm "$dir" off) || fail "toggle off failed: $out"
  json_equal "$cli" "$dir/original.json" || fail "Calm off did not restore the exact prior settings: $(cat "$cli")"
  [ "$(json_get "$cli" session.verbosity)" = "<absent>" ] || fail "a key absent before Calm was not removed again"
  [ ! -e "$dir/xdg/opencode/fm-ocalm-restore.json" ] || fail "the restore record outlived the restore"

  rm -f "$cli"
  ocalm "$dir" on >/dev/null || fail "toggle on with no settings file failed"
  [ "$(json_get "$cli" session.verbosity)" = low ] || fail "Calm on did not create the settings it needs"
  ocalm "$dir" off >/dev/null || fail "toggle off with no prior settings file failed"
  [ ! -e "$cli" ] || fail "Calm off left a settings file that did not exist before: $(cat "$cli")"

  # The settings file is global; only the last home holding quiet settings restores them.
  printf '{\n  "session": {"verbosity": "high"}\n}\n' >"$cli"
  mkdir -p "$dir/second/config"
  ocalm "$dir" on >/dev/null
  env -u FM_ROOT_OVERRIDE -u FM_CONFIG_OVERRIDE HOME="$dir/home" XDG_CONFIG_HOME="$dir/xdg" FM_HOME="$dir/second" node "$OCALM" on >/dev/null
  ocalm "$dir" off >/dev/null
  [ "$(json_get "$cli" session.verbosity)" = low ] || fail "one home turning Calm off restored settings another home still holds"
  env -u FM_ROOT_OVERRIDE -u FM_CONFIG_OVERRIDE HOME="$dir/home" XDG_CONFIG_HOME="$dir/xdg" FM_HOME="$dir/second" node "$OCALM" off >/dev/null
  [ "$(json_get "$cli" session.verbosity)" = high ] || fail "the last home turning Calm off did not restore the prior settings"
  pass "OpenCode's quiet CLI settings apply while Calm is on and restore exactly, including absent keys and files, once the last home turns it off"
}

test_ship_matches_shared_core() {
  local out
  cat >"$TMP_ROOT/ship.mjs" <<JS
import { createCalmWorkingShipSprite } from $(node -e 'process.stdout.write(JSON.stringify(process.argv[1]))' "$SPRITE");
import { paintOcalmShip } from $(node -e 'process.stdout.write(JSON.stringify(process.argv[1]))' "$OCALM");
const palette = { water: "W", boat: "B" };
const core = createCalmWorkingShipSprite();
const painted = createCalmWorkingShipSprite();
let frames = 0;
for (const width of [0, 2, 4, 6, 40, 96]) {
  for (let tick = 0; tick < 40; tick += 1) {
    const expected = core.frame(width);
    const rows = paintOcalmShip(painted.frame(width), palette);
    if (rows.length !== expected.length) throw new Error(\`width \${width}: \${rows.length} rows, core has \${expected.length}\`);
    rows.forEach((spans, index) => {
      const text = spans.map((span) => span.text).join("");
      const coreText = expected[index].map((run) => run.text).join("");
      if (text !== coreText) throw new Error(\`width \${width} row \${index}: drew \${text}, core has \${coreText}\`);
      const colored = spans.flatMap((span) => Array.from(span.text, () => span.fg ?? "plain")).join(",");
      const coreColored = expected[index].flatMap((run) => Array.from(run.text, () => ({ water: "W", boat: "B", plain: "plain" })[run.color])).join(",");
      if (colored !== coreColored) throw new Error(\`width \${width} row \${index}: colors diverge from the core\`);
      if (spans.some((span, at) => at > 0 && spans[at - 1].fg === span.fg)) throw new Error("adjacent spans share a color");
    });
    core.tick();
    painted.tick();
    frames += 1;
  }
}
const boat = paintOcalmShip(createCalmWorkingShipSprite().frame(40), palette);
if (!boat[0].some((span) => span.text.includes("◿│◣") && span.fg === "B")) throw new Error("the sail is not one boat-colored span");
if (!boat[1].some((span) => span.text === "╲▁▁▁╱" && span.fg === "B")) throw new Error("the hull is not one boat-colored span");
console.log(\`frames \${frames}\`);
JS
  out=$(node "$TMP_ROOT/ship.mjs" 2>&1) || fail "the drawn boat diverged from the shared sprite core: $out"
  assert_contains "$out" "frames 240" "the sprite comparison did not cover every frame"
  pass "the drawn boat is the shared sprite core's own text and colors, frame by frame across widths and ticks"
}

# The TUI plugin needs OpenTUI only for its renderables; Bun lets this check stand in for
# them and for OpenCode's plugin context, so the wiring runs without an OpenCode binary.
test_tui_plugin_wiring() {
  local dir out
  if ! command -v bun >/dev/null 2>&1; then
    pass "the TUI plugin wiring check needs Bun, which is not installed here (skipped)"
    return
  fi
  dir=$(sandbox tui)
  printf 'on\n' >"$dir/fmhome/config/calm"
  cat >"$TMP_ROOT/tui.mjs" <<JS
import { plugin } from "bun";
const signal = (initial) => { let value = initial; return [() => value, (next) => { value = typeof next === "function" ? next(value) : next; }]; };
const element = (type) => ({ type, props: {}, children: [] });
plugin({
  name: "ocalm-stand-ins",
  setup(build) {
    build.module("solid-js", () => ({ loader: "object", exports: { createSignal: signal } }));
    build.module("@opentui/solid", () => ({ loader: "object", exports: {
      createElement: element,
      setProp: (node, name, value) => { node.props[name] = value; },
      insert: (node, child) => { node.children.push(child); },
    } }));
  },
});
const { default: tui } = await import($(node -e 'process.stdout.write(JSON.stringify(process.argv[1]))' "$PLUGIN/tui.js"));
const toasts = [];
const claims = [];
let layers = [];
let status = "idle";
const ctx = {
  themeMode: "dark",
  theme: { hue: { blue: { 200: "BLUE" }, yellow: { 200: "YELLOW" } } },
  keymap: { layer: (factory) => layers.push(factory()) },
  ui: {
    toast: { show: (options) => toasts.push(options.message) },
    router: { current: () => ({ type: "session", sessionID: "child" }) },
    slot: (claim) => { const entry = { ...claim, live: true }; claims.push(entry); return () => { entry.live = false; }; },
  },
  data: { session: { root: (id) => (id === "child" ? "root" : id), status: (id) => (id === "root" ? status : "idle") } },
};
const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));
const fail = (message) => { console.error(message); process.exit(1); };
const cleanup = await tui.setup(ctx);
const command = layers.flatMap((layer) => layer.commands ?? []).find((entry) => entry.slash?.name === "ocalm");
if (!command) fail("no /ocalm slash command was registered");
if (command.palette !== true) fail("/ocalm has no palette entry");
if (layers.find((layer) => layer.commands?.includes(command))?.mode !== "global") fail("the /ocalm layer is not global, so the palette cannot reach it");
if (toasts.length) fail(\`setup showed a notice: \${toasts}\`);
await sleep(300);
if (claims.length) fail("the boat drew while no run was active");
status = "running";
await sleep(300);
const live = claims.filter((claim) => claim.live);
if (live.length !== 1 || live[0].replace !== "prompt.footer.status") fail(\`expected one live claim replacing prompt.footer.status, got \${JSON.stringify(claims)}\`);
const box = live[0].render({ sessionID: "child", mode: "normal", showDetails: true });
box.props.onSizeChange.call({ width: 40 });
const rows = box.children[0]();
const text = rows.map((row) => row.children.map((span) => span.children.join("")).join(""));
if (text.length !== 2 || !text[0].includes("◿│◣") || !text[1].includes("╲▁▁▁╱") || Array.from(text[1]).length !== 40) fail(\`the boat did not draw two full rows: \${JSON.stringify(text)}\`);
const colors = new Set(rows.flatMap((row) => row.children.map((span) => span.props.style?.fg)));
if (!colors.has("BLUE") || !colors.has("YELLOW")) fail(\`the boat is not painted in the theme's blue and yellow: \${[...colors]}\`);
status = "idle";
await sleep(300);
if (claims.some((claim) => claim.live)) fail("the boat stayed after the run ended");
await command.run();
if (toasts.at(-1) !== "Calm off") fail(\`toggling off showed \${toasts.at(-1)}\`);
status = "running";
await sleep(300);
if (claims.some((claim) => claim.live)) fail("the boat drew while Calm was off");
await command.run();
if (toasts.at(-1) !== "Calm on") fail(\`toggling on showed \${toasts.at(-1)}\`);
await sleep(300);
if (!claims.some((claim) => claim.live)) fail("the boat did not return when Calm turned back on during a run");
await cleanup();
if (claims.some((claim) => claim.live)) fail("cleanup left the boat claimed");
console.log("wired");
JS
  out=$(env -u FM_ROOT_OVERRIDE -u FM_CONFIG_OVERRIDE HOME="$dir/home" XDG_CONFIG_HOME="$dir/xdg" FM_HOME="$dir/fmhome" bun "$TMP_ROOT/tui.mjs" 2>&1) \
    || fail "TUI plugin wiring: $out"
  assert_contains "$out" "wired" "the TUI plugin check did not finish"
  [ "$(json_get "$dir/xdg/opencode/cli.json" session.verbosity)" = low ] || fail "a home already on did not start with quiet settings"
  [ "$(cat "$dir/fmhome/config/calm")" = on ] || fail "the TUI toggle did not persist its last choice"
  pass "the TUI plugin registers /ocalm in slash and palette, toggles with a notice, starts quiet when already on, and draws the shared boat only while Calm is on and a run is active"
}

test_boundary_presentation_only() {
  local dir out before after changed
  dir=$(sandbox boundary)
  mkdir -p "$dir/home/.local/share/opencode/storage/session" "$dir/xdg/opencode" "$dir/exports"
  printf '{"id":"ses_fixture","messages":[{"role":"assistant","text":"short note"}]}\n' >"$dir/home/.local/share/opencode/storage/session/ses_fixture.json"
  printf 'SQLite format 3 fixture\n' >"$dir/home/.local/share/opencode/opencode.db"
  printf '# exported transcript\nshort note\n' >"$dir/exports/session.md"
  printf 'model context fixture\n' >"$dir/fmhome/state/context.txt"
  printf '{\n  "session": {"thinking": "show"}\n}\n' >"$dir/xdg/opencode/cli.json"
  snapshot() {
    ( cd "$dir" && find . -type f ! -path './snapshot-*' -print | LC_ALL=C sort | while IFS= read -r file; do
      printf '%s %s\n' "$(cksum <"$file" | tr -s ' ' '-')" "$file"
    done )
  }
  before=$(snapshot)
  out=$(ocalm "$dir" on) || fail "toggle on failed: $out"
  after=$(snapshot)
  changed=$(diff <(printf '%s\n' "$before") <(printf '%s\n' "$after") | sed -n 's/^[<>] [^ ]* //p' | LC_ALL=C sort -u | tr '\n' ' ')
  [ "$changed" = "./fmhome/config/calm ./xdg/opencode/cli.json ./xdg/opencode/fm-ocalm-restore.json " ] \
    || fail "Calm on touched more than its preference and OpenCode's settings: $changed"
  out=$(ocalm "$dir" off) || fail "toggle off failed: $out"
  after=$(snapshot)
  changed=$(diff <(printf '%s\n' "$before") <(printf '%s\n' "$after") | sed -n 's/^[<>] [^ ]* //p' | LC_ALL=C sort -u | tr '\n' ' ')
  [ "$changed" = "./fmhome/config/calm ./xdg/opencode/cli.json " ] \
    || fail "a full Calm cycle left changes beyond the preference and a reformatted settings file: $changed"
  pass "a full Calm cycle changes only the preference, OpenCode's CLI settings, and the restore record, never session data, transcripts, exports, or model context"
}

fm_test_run \
  test_preference_toggle \
  test_failed_write_changes_nothing \
  test_cli_settings_apply_and_restore \
  test_ship_matches_shared_core \
  test_tui_plugin_wiring \
  test_boundary_presentation_only
