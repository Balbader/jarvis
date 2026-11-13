// Firstmate Calm for the OpenCode TUI: the `/ocalm` command, its transient notice, and
// the shared working sailboat. OpenCode loads this file as the TUI part of the local
// plugin directory `.opencode/plugins/fm-ocalm`.
//
// The toggle and OpenCode's quiet transcript settings live in ./ocalm.js; the sailboat
// geometry is the shared core in ../lib/fm-calm-working-ship-sprite.ts (a tracked symlink
// into .claude/mods/firstmate-calm/lib). docs/calm.md owns the captain-facing contract
// and docs/calm-mode-feasibility.md the OpenCode 2.2.7 evidence.
//
// This file is plain JavaScript, so OpenTUI's Solid transform does not run on it; it
// builds its few renderables with the universal-renderer calls that JSX compiles to.
import { createElement, insert, setProp } from "@opentui/solid";
import { createSignal } from "solid-js";
import {
  CALM_WORKING_SHIP_TICK_MS,
  createCalmWorkingShipSprite,
} from "../lib/fm-calm-working-ship-sprite.ts";
import { ocalmNotice, paintOcalmShip, readCalm, setCalm, syncOcalmCliSettings } from "./ocalm.js";

/** OpenCode's stock progress indicator; the sailboat takes its place only while a run is active. */
const WORKING_SLOT = "prompt.footer.status";
const NOTICE_MS = 2000;

/**
 * Water in the theme's blue and the whole boat in its yellow, as Pi paints them, with
 * lighter shades on dark themes. Themes publish different hue scales (one has yellow and
 * no orange, another the reverse), so each part takes the first scale its theme has.
 */
function shipPalette(ctx) {
  const shade = ctx.themeMode === "light" ? "400" : "200";
  const hue = (names) => names.map((name) => ctx.theme?.hue?.[name]?.[shade]).find(Boolean);
  return { water: hue(["blue", "cyan", "accent"]), boat: hue(["yellow", "orange", "interactive"]) };
}

function textRow(spans) {
  const row = createElement("text");
  for (const span of spans) {
    const node = createElement("span");
    // A span takes its color through `style`, as a theme RGBA value.
    if (span.fg !== undefined) setProp(node, "style", { fg: span.fg });
    insert(node, span.text);
    insert(row, node);
  }
  return row;
}

export default {
  id: "fm-ocalm",
  setup(ctx) {
    // One sprite per plugin lifetime keeps the boat's column and direction between runs.
    const sprite = createCalmWorkingShipSprite();
    const [tick, setTick] = createSignal(0);
    let calm = readCalm();
    let claim;
    let ticker;

    const notice = (message, variant = "info") => ctx.ui.toast.show({ message, variant, duration: NOTICE_MS });

    const running = () => {
      const route = ctx.ui.router.current();
      if (route?.type !== "session") return false;
      return ctx.data.session.status(ctx.data.session.root(route.sessionID)) === "running";
    };

    const renderShip = () => {
      const [width, setWidth] = createSignal(0);
      const box = createElement("box");
      setProp(box, "flexDirection", "column");
      setProp(box, "flexGrow", 1);
      setProp(box, "onSizeChange", function onSizeChange() {
        setWidth(this.width);
      });
      insert(box, () => {
        tick();
        return paintOcalmShip(sprite.frame(width()), shipPalette(ctx)).map(textRow);
      });
      return box;
    };

    // Claim the working slot only while Calm is on and a run is active, so the stock
    // footer stays exactly as OpenCode draws it at every other moment.
    const step = () => {
      const show = calm && running();
      if (show && !claim) {
        claim = ctx.ui.slot({ replace: WORKING_SLOT, render: renderShip });
      } else if (!show && claim) {
        claim();
        claim = undefined;
        sprite.restoreLastRendered();
      }
      if (claim) {
        sprite.tick();
        setTick((value) => value + 1);
      }
    };

    const apply = () => {
      if (calm && !ticker) ticker = setInterval(step, CALM_WORKING_SHIP_TICK_MS);
      if (!calm && ticker) {
        clearInterval(ticker);
        ticker = undefined;
      }
      step();
    };

    const toggle = () => {
      const active = !readCalm();
      const result = setCalm(active);
      notice(ocalmNotice(active, result), result.saved && !result.settingsReason ? "info" : "warning");
      if (!result.saved) return;
      calm = active;
      apply();
    };

    // The default base-mode layer reaches slash completion but not the command palette,
    // which runs in its own input mode, so the layer opts out to global.
    ctx.keymap.layer(() => ({
      mode: "global",
      commands: [
        {
          id: "fm.ocalm.toggle",
          title: "Toggle Calm",
          description: "Toggle Firstmate's Calm transcript presentation and working sailboat.",
          group: "Firstmate",
          palette: true,
          slash: { name: "ocalm" },
          run: toggle,
        },
      ],
    }));

    // A home whose stored choice is already on starts quiet, and one that is off releases
    // any quiet settings it still holds, as Pi and Claude Code reload the choice at start.
    try {
      syncOcalmCliSettings(calm);
    } catch (error) {
      notice(`Calm ${calm ? "on" : "off"}: OpenCode transcript settings unchanged (${error?.message ?? error})`, "warning");
    }
    apply();

    return () => {
      if (ticker) clearInterval(ticker);
      ticker = undefined;
      claim?.();
      claim = undefined;
    };
  },
};
