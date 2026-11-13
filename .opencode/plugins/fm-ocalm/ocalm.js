// Firstmate Calm for OpenCode: the `/ocalm` toggle shared by the TUI plugin (./tui.js)
// and the portable skill (.opencode/skills/ocalm/SKILL.md), which runs this file as a CLI.
//
// It owns two things and nothing else:
// - the shared per-home `config/calm` preference, resolved, read, and serialized by the
//   one owner the Claude Code mod and Pi share (../lib/fm-calm-presentation.ts, a tracked
//   symlink into .claude/mods/firstmate-calm/lib), and saved before any live change;
// - OpenCode's own quiet transcript settings in the global CLI settings file, applied
//   while Calm is on and restored to the exact prior values when it turns off.
// docs/calm.md owns the captain-facing contract, docs/configuration.md the preference
// schema, and docs/calm-mode-feasibility.md the OpenCode evidence.
//
// Presentation only: nothing here reads or writes sessions, transcripts, exports, or
// model context.
import { randomUUID } from "node:crypto";
import { mkdirSync, readFileSync, realpathSync, renameSync, rmSync, statSync, writeFileSync } from "node:fs";
import { homedir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import {
  calmPreferencePath,
  parseCalmPreference,
  serializeCalmPreference,
} from "../lib/fm-calm-presentation.ts";

const PLUGIN_ROOT = dirname(fileURLToPath(import.meta.url));

/** OpenCode's native quiet transcript: hidden reasoning, summarized tool runs, grouping on. */
export const OCALM_QUIET_SESSION = Object.freeze({ thinking: "hide", verbosity: "low", grouping: "auto" });

/** The record of the CLI settings Calm replaced, kept beside the settings file it restores. */
const RESTORE_RECORD = "fm-ocalm-restore.json";

/** This home's `config/calm`, resolved exactly as Pi and the Claude Code mod resolve it. */
export function ocalmPreferencePath(env = process.env) {
  return calmPreferencePath(env, PLUGIN_ROOT);
}

/** The stored choice: `on` or legacy `max` read as on; absent or unreadable reads as off. */
export function readCalm(env = process.env) {
  try {
    return parseCalmPreference(readFileSync(ocalmPreferencePath(env), "utf8"));
  } catch {
    return false;
  }
}

/** The global OpenCode CLI settings file: `$XDG_CONFIG_HOME/opencode/cli.json`, else `~/.config`. */
export function ocalmCliSettingsPath(env = process.env) {
  return join(env.XDG_CONFIG_HOME || join(env.HOME || homedir(), ".config"), "opencode", "cli.json");
}

function writeAtomically(path, text, mode) {
  mkdirSync(dirname(path), { recursive: true });
  const temporary = `${path}.${process.pid}.${randomUUID()}.tmp`;
  try {
    writeFileSync(temporary, text, { encoding: "utf8", flag: "wx", mode });
    renameSync(temporary, path);
  } finally {
    rmSync(temporary, { force: true });
  }
}

function isObject(value) {
  return value !== null && typeof value === "object" && !Array.isArray(value);
}

/** Missing reads as undefined; anything that is not a JSON object throws, so it is never overwritten. */
function readJsonObject(path) {
  let text;
  try {
    text = readFileSync(path, "utf8");
  } catch (error) {
    if (error?.code === "ENOENT") return undefined;
    throw error;
  }
  const value = JSON.parse(text);
  if (!isObject(value)) throw new Error(`${path} is not a JSON object`);
  return value;
}

function fileMode(path) {
  try {
    return statSync(path).mode & 0o777;
  } catch {
    return 0o600;
  }
}

function writeJson(path, value) {
  writeAtomically(path, `${JSON.stringify(value, null, 2)}\n`, fileMode(path));
}

/**
 * Turn OpenCode's quiet transcript settings on (`active`) or back off for this home.
 *
 * The settings file is global to the OS user while the preference is per home, so the
 * restore record counts every home that currently wants quiet settings: the first one
 * saves the prior values, and only the last one to leave restores them. A key that was
 * absent before is removed again, so restoring leaves exactly what was there.
 */
export function syncOcalmCliSettings(active, env = process.env) {
  const settingsPath = ocalmCliSettingsPath(env);
  const recordPath = join(dirname(settingsPath), RESTORE_RECORD);
  const home = dirname(ocalmPreferencePath(env));
  const record = readJsonObject(recordPath);
  if (!active && !record) return;
  const settings = readJsonObject(settingsPath);
  const session = isObject(settings?.session) ? settings.session : undefined;

  if (active) {
    const next = record ?? {
      file: settings !== undefined,
      session: session !== undefined,
      values: Object.fromEntries(
        Object.keys(OCALM_QUIET_SESSION).filter((key) => Object.hasOwn(session ?? {}, key)).map((key) => [key, session[key]]),
      ),
      homes: [],
    };
    if (!next.homes.includes(home)) next.homes.push(home);
    writeJson(recordPath, next);
    writeJson(settingsPath, { ...settings, session: { ...session, ...OCALM_QUIET_SESSION } });
    return;
  }

  record.homes = record.homes.filter((entry) => entry !== home);
  if (record.homes.length > 0) {
    writeJson(recordPath, record);
    return;
  }
  const restored = { ...session };
  for (const key of Object.keys(OCALM_QUIET_SESSION)) {
    if (Object.hasOwn(record.values, key)) restored[key] = record.values[key];
    else delete restored[key];
  }
  const nextSettings = { ...settings, session: restored };
  if (!record.session && Object.keys(restored).length === 0) delete nextSettings.session;
  if (!record.file && Object.keys(nextSettings).length === 0) rmSync(settingsPath, { force: true });
  else writeJson(settingsPath, nextSettings);
  rmSync(recordPath, { force: true });
}

/**
 * Save the choice, then apply it. A failed save leaves the stored choice and the CLI
 * settings exactly as they were; a failed settings change after a good save is reported
 * separately, because the choice itself did persist.
 */
export function setCalm(active, env = process.env) {
  const path = ocalmPreferencePath(env);
  try {
    writeAtomically(path, serializeCalmPreference(active), 0o600);
  } catch (error) {
    return { saved: false, path, reason: error?.message ?? String(error) };
  }
  try {
    syncOcalmCliSettings(active, env);
  } catch (error) {
    return { saved: true, path, settingsReason: error?.message ?? String(error) };
  }
  return { saved: true, path };
}

/** The one-line notice for a toggle result, matching the Claude Code mod's wording. */
export function ocalmNotice(active, result) {
  if (!result.saved) return `Calm unchanged: could not save ${result.path} (${result.reason})`;
  const notice = active ? "Calm on" : "Calm off";
  return result.settingsReason
    ? `${notice} (OpenCode transcript settings unchanged: ${result.settingsReason})`
    : notice;
}

/**
 * Paint one shared sprite frame as rows of same-colored spans: adjacent runs of one
 * color merge, `plain` padding stays uncolored, and the text is the frame's own text.
 */
export function paintOcalmShip(frame, palette) {
  return frame.map((row) => {
    const spans = [];
    for (const run of row) {
      const fg = run.color === "plain" ? undefined : palette[run.color];
      const last = spans.at(-1);
      if (last && last.fg === fg) last.text += run.text;
      else spans.push({ text: run.text, fg });
    }
    return spans;
  });
}

function isMain() {
  try {
    return realpathSync(process.argv[1] ?? "") === realpathSync(fileURLToPath(import.meta.url));
  } catch {
    return false;
  }
}

// CLI for the portable skill: `node ocalm.js [toggle|on|off|status]`.
// Exit 0 when the choice saved and applied, 1 when it could not be saved (unchanged),
// 2 when it saved but OpenCode's settings could not change, 64 on a usage error.
if (isMain()) {
  const action = process.argv[2] ?? "toggle";
  if (action === "status") {
    console.log(`${readCalm() ? "Calm on" : "Calm off"} (${ocalmPreferencePath()})`);
    process.exit(0);
  }
  if (!["toggle", "on", "off"].includes(action)) {
    console.error("usage: ocalm.js [toggle|on|off|status]");
    process.exit(64);
  }
  const active = action === "toggle" ? !readCalm() : action === "on";
  const result = setCalm(active);
  console.log(ocalmNotice(active, result));
  process.exit(!result.saved ? 1 : result.settingsReason ? 2 : 0);
}
