#!/usr/bin/env node
// sample_rig.mjs — sample the website's GSAP figure rig at 1/8-beat ticks.
//
// Loads ~/taiso's rig.js against a DOM-free shim (plain objects instead of
// SVG elements), scrubs every movement timeline by progress exactly the way
// main.js does (tl.progress(min(k/64, 0.9999)) for k = 0..63), composes the
// SVG transform chain by hand to get world joint coordinates, and reduces
// them to absolute segment angles (0 = down, 90 = screen-left, 180 = up),
// length ratios, head facing and the right-foot flip.
//
// Output: tools/out/poses.json (consumed by tools/puppet.py).
// Usage:   node tools/sample_rig.mjs [path/to/taiso]
import { writeFileSync, mkdirSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const TAISO = process.argv[2] ?? "/Users/welcome/taiso";
const here = dirname(fileURLToPath(import.meta.url));
const OUT_DIR = join(here, "out");
const TICKS = 64;

// ---- DOM shim -------------------------------------------------------------
const IDS = ["figure", "upper", "head", "arm-l", "arm-r", "forearm-l", "forearm-r",
  "leg-l", "leg-r", "shin-l", "shin-r", "nose", "nose-r", "foot-r"];
const objs = {};
// svgOrigin is a CSSPlugin feature (rig.js pins pivots with it); giving the
// shim objects the property makes GSAP just store it instead of warning —
// the pivots are applied by hand below (PIVOT).
const rest = (id) => ({ rotation: 0, x: 0, y: 0, scaleX: 1, scaleY: 1,
  opacity: id.startsWith("nose") ? 0 : 1, svgOrigin: "" });
for (const id of IDS) objs[id] = rest(id);
const resetAll = () => { for (const id of IDS) Object.assign(objs[id], rest(id)); };
globalThis.document = { getElementById: (id) => objs[id] };

const { gsap } = await import(join(TAISO, "node_modules/gsap/gsap-core.js"));
globalThis.gsap = gsap;
const { buildMovements } = await import(join(TAISO, "src/js/experience/rig.js"));
const rig = buildMovements();

// ---- transform chain ------------------------------------------------------
// Pivots (svgOrigin) from rig.js, in each element's own (rest) coordinates.
const PIVOT = {
  figure: [0, 0], upper: [100, 150], head: [100, 61],
  "arm-l": [100, 78], "arm-r": [100, 78], "forearm-l": [90, 112], "forearm-r": [110, 112],
  "leg-l": [100, 150], "leg-r": [100, 150], "shin-l": [91, 215], "shin-r": [109, 215],
  "foot-r": [113, 257],
};
const PARENT = {
  figure: null, upper: "figure", head: "upper",
  "arm-l": "upper", "arm-r": "upper", "forearm-l": "arm-l", "forearm-r": "arm-r",
  "leg-l": "figure", "leg-r": "figure", "shin-l": "leg-l", "shin-r": "leg-r",
  "foot-r": "shin-r",
};
// p' = o + R(rot) * S(sx, sy) * (p - o) + t   (SVG y grows downwards; positive
// rotation is clockwise on screen — GSAP/CSS semantics)
function local(id, p) {
  const e = objs[id], [ox, oy] = PIVOT[id];
  const r = (e.rotation * Math.PI) / 180, c = Math.cos(r), s = Math.sin(r);
  const dx = (p[0] - ox) * e.scaleX, dy = (p[1] - oy) * e.scaleY;
  return [ox + c * dx - s * dy + e.x, oy + s * dx + c * dy + e.y];
}
function world(id, p) {
  let q = p;
  for (let n = id; n; n = PARENT[n]) q = local(n, q);
  return q;
}

// ---- reduction ------------------------------------------------------------
// absolute segment angle: 0 = down, 90 = screen-left, 180 = up, 270 = right
const ang = (from, to) => {
  const a = (Math.atan2(-(to[0] - from[0]), to[1] - from[1]) * 180) / Math.PI;
  return ((a % 360) + 360) % 360;
};
const len = (a, b) => Math.hypot(b[0] - a[0], b[1] - a[1]);
const r2 = (v) => Math.round(v * 100) / 100;

function sample() {
  const waist = world("upper", [100, 150]);
  const neck = world("upper", [100, 61]);
  const shoulder = world("upper", [100, 78]);
  const headc = world("head", [100, 42]);
  const elbowL = world("arm-l", [90, 112]), elbowR = world("arm-r", [110, 112]);
  const handL = world("forearm-l", [82, 144]), handR = world("forearm-r", [118, 144]);
  const kneeL = world("leg-l", [91, 215]), kneeR = world("leg-r", [109, 215]);
  const ankleL = world("shin-l", [87, 257]), ankleR = world("shin-r", [113, 257]);
  const toeL = world("shin-l", [78, 258]), toeR = world("foot-r", [122, 258]);
  const noseL = objs.nose.opacity, noseR = objs["nose-r"].opacity;
  const facing = noseL >= 0.5 ? "L" : noseR >= 0.5 ? "R" : "F";
  const torsoA = ang(waist, neck);
  const headA = ang(neck, headc);
  return {
    y: r2(objs.figure.y),                       // figure offset (SVG units, +down)
    torso: r2(torsoA),                          // absolute torso angle (180 = upright)
    torso_len: r2(len(waist, neck) / 89),       // length ratio (scaleY squash)
    shoulder_frac: r2(len(waist, shoulder) / len(waist, neck)),
    head: r2(headA),                            // absolute head "up" direction
    head_tilt: r2(((headA - torsoA + 540) % 360) - 180),
    facing,
    upL: r2(ang(shoulder, elbowL)), upR: r2(ang(shoulder, elbowR)),
    upL_len: r2(len(shoulder, elbowL) / 35.44), upR_len: r2(len(shoulder, elbowR) / 35.44),
    foreL: r2(ang(elbowL, handL)), foreR: r2(ang(elbowR, handR)),
    thighL: r2(ang(waist, kneeL)), thighR: r2(ang(waist, kneeR)),
    shinL: r2(ang(kneeL, ankleL)), shinR: r2(ang(kneeR, ankleR)),
    footL: r2(ang(ankleL, toeL)), footR: r2(ang(ankleR, toeR)),
    footR_flip: toeR[0] < ankleR[0],            // right toe points screen-left
    joints: {                                   // world coords for reference/debug
      waist: waist.map(r2), neck: neck.map(r2), shoulder: shoulder.map(r2), head: headc.map(r2),
      elbowL: elbowL.map(r2), elbowR: elbowR.map(r2), handL: handL.map(r2), handR: handR.map(r2),
      kneeL: kneeL.map(r2), kneeR: kneeR.map(r2), ankleL: ankleL.map(r2), ankleR: ankleR.map(r2),
      toeL: toeL.map(r2), toeR: toeR.map(r2),
    },
  };
}

// ---- timelines in movements.asm id order ---------------------------------
const ORDER = ["stretch-up", "arm-swings-leg-bends", "arm-circles", "chest-stretch",
  "side-bends", "forward-back-bends", "body-twists", "up-down-stretch",
  "diagonal-bend-chest", "body-rotation", "jumping", "cool-down-swings", "deep-breathing",
  "whole-body-shake", "hop-steps", "curl-squats", "deep-folds"];
const timelines = ORDER.map((name, id) => ({ id, name, tl: rig.movements[name] }));
timelines.push({ id: 17, name: "warmup", tl: rig.warmup });
timelines.push({ id: 18, name: "idle", tl: rig.idle });
for (const t of timelines) if (!t.tl) throw new Error(`missing timeline ${t.name}`);

const out = { ticks: TICKS, scale_hint: "SVG units; figure viewBox 0 0 200 270", timelines: [] };
for (const { id, name, tl } of timelines) {
  resetAll();
  tl.progress(0, false);
  const ticks = [];
  for (let k = 0; k < TICKS; k++) {
    tl.progress(Math.min(k / TICKS, 0.9999), false);
    ticks.push(sample());
  }
  tl.progress(0, false);
  out.timelines.push({ id, name, duration: r2(tl.duration()), ticks });
  const ys = ticks.map((t) => t.y);
  console.log(`${String(id).padStart(2)} ${name.padEnd(22)} dur ${tl.duration().toFixed(2)}  ` +
    `y ${Math.min(...ys)}..${Math.max(...ys)}  torso ${Math.min(...ticks.map((t) => t.torso))}..` +
    `${Math.max(...ticks.map((t) => t.torso))}  len ${Math.min(...ticks.map((t) => t.torso_len))}..` +
    `${Math.max(...ticks.map((t) => t.torso_len))}  facing ${[...new Set(ticks.map((t) => t.facing))].join("")}`);
}
mkdirSync(OUT_DIR, { recursive: true });
writeFileSync(join(OUT_DIR, "poses.json"), JSON.stringify(out));
console.log(`wrote ${join(OUT_DIR, "poses.json")} (${out.timelines.length} timelines x ${TICKS} ticks)`);
gsap.ticker.sleep();
