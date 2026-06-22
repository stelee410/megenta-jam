// Copyright 2026 Google LLC
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

/*
 * 32 factory templates for the Modular tab. Each archetype (pluck, bass,
 * drone, bell, percussion, generative, acid, pad) yields four variations,
 * built deterministically from a seed so they are reproducible — params +
 * a patch matrix + an in-scale motion sequence.
 */

import { DEFAULT_MODULAR } from './ModularPanel';
import type { ModularParams, ModularSeq } from './ModularPanel';

export interface ModularPreset {
  name: string;
  params: ModularParams;
  patch: number[];   // 7×8, [src*8 + dst]
  seq: ModularSeq;
}

// Source / destination indices (mirror JamModular / ModularPanel).
const S = { FUNC1: 0, FUNC2: 1, RND1: 2, RND2: 3, VELO: 4, KEY: 5, GATE: 6 };
const D = { PITCH: 0, WAVE: 1, FOLD: 2, CUTOFF: 3, LEVEL: 4, FN1R: 5, RNDR: 6, SIZE: 7 };

type Conn = [number, number, number];
function mkPatch(conns: Conn[]): number[] {
  const a = Array(56).fill(0);
  for (const [s, d, v] of conns) a[s * 8 + d] = v;
  return a;
}

// Deterministic small PRNG so presets are stable across reloads.
function mulberry32(seed: number) {
  let t = seed >>> 0;
  return () => {
    t += 0x6d2b79f5;
    let x = Math.imul(t ^ (t >>> 15), 1 | t);
    x ^= x + Math.imul(x ^ (x >>> 7), 61 | x);
    return ((x ^ (x >>> 14)) >>> 0) / 4294967296;
  };
}

const SCALES: Record<string, number[]> = {
  major: [0, 2, 4, 5, 7, 9, 11],
  minor: [0, 2, 3, 5, 7, 8, 10],
  dorian: [0, 2, 3, 5, 7, 9, 10],
  penta: [0, 3, 5, 7, 10],
};
const SCALE_IDX: Record<string, number> = { major: 0, minor: 1, dorian: 2, penta: 3 };

/** Map a scale degree to a chromatic semitone offset (0..24). */
function degToSemi(scale: string, degree: number): number {
  const tbl = SCALES[scale] ?? SCALES.minor;
  const oct = Math.floor(degree / tbl.length);
  return Math.min(24, tbl[degree % tbl.length] + 12 * oct);
}

interface Archetype {
  name: string;
  variants: string[];
  scale: string;
  density: number;          // gate probability
  span: number;             // melodic range (degrees)
  params: Partial<ModularParams>;
  patch: Conn[];
}

const ARCHETYPES: Archetype[] = [
  {
    name: 'Pluck', variants: ['Bongo', 'Kalimba', 'Droplet', 'Mallet'],
    scale: 'penta', density: 0.62, span: 8,
    params: { lpgDecay: 0.3, lpgCutoff: 0.6, foldAmt: 0.3, fn1Fall: 0.35, vcoWaveSel: 1, voiceMode: 0 },
    patch: [[S.FUNC1, D.CUTOFF, 0.4], [S.VELO, D.LEVEL, 0.3]],
  },
  {
    name: 'Bass', variants: ['Sub', 'Reese', 'Growl', 'Round'],
    scale: 'minor', density: 0.7, span: 5,
    params: { vcoWaveSel: 2, vcoScale: 0.7, lpgCutoff: 0.4, lpgDecay: 0.5, lpgDrive: 0.5, seqOctave: -1, voiceMode: 0 },
    patch: [[S.FUNC1, D.CUTOFF, 0.5], [S.GATE, D.LEVEL, 0.2]],
  },
  {
    name: 'Drone', variants: ['Cavern', 'Choir', 'Glacier', 'Hymn'],
    scale: 'dorian', density: 0.25, span: 7,
    params: { fn1Cycle: 1, lpgDecay: 0.85, lpgCutoff: 0.55, spaceSize: 0.7, spaceType: 3, voiceMode: 2, glide: 0.3 },
    patch: [[S.FUNC2, D.PITCH, 0.06], [S.FUNC2, D.FOLD, 0.4], [S.RND1, D.SIZE, 0.3]],
  },
  {
    name: 'Bell', variants: ['Temple', 'Glass', 'Carillon', 'Chime'],
    scale: 'major', density: 0.5, span: 10,
    params: { vcoWaveSel: 0, vcoWave: 0.5, foldAmt: 0.5, lpgDecay: 0.55, lpgReso: 0.3, spaceSize: 0.6, voiceMode: 2 },
    patch: [[S.FUNC1, D.CUTOFF, 0.45], [S.KEY, D.FOLD, 0.3], [S.FUNC1, D.LEVEL, 0.2]],
  },
  {
    name: 'Perc', variants: ['Clave', 'Tom', 'Rim', 'Block'],
    scale: 'penta', density: 0.55, span: 4,
    params: { lpgDecay: 0.18, lpgCutoff: 0.7, lpgDrive: 0.4, fn1Fall: 0.2, foldAmt: 0.4, vcoWaveSel: 1, voiceMode: 0 },
    patch: [[S.RND2, D.PITCH, 0.2], [S.FUNC1, D.CUTOFF, 0.5]],
  },
  {
    name: 'Gen', variants: ['Burst', 'Drift', 'Scatter', 'Bloom'],
    scale: 'dorian', density: 0.45, span: 12,
    params: { rndMode: 3, rndRate: 0.5, fn2Cycle: 1, lpgDecay: 0.4, spaceSize: 0.5, voiceMode: 2 },
    patch: [[S.RND1, D.PITCH, 0.12], [S.RND1, D.CUTOFF, 0.35], [S.FUNC2, D.FOLD, 0.4], [S.RND2, D.WAVE, 0.3]],
  },
  {
    name: 'Acid', variants: ['Squelch', '303', 'Slither', 'Worm'],
    scale: 'minor', density: 0.72, span: 7,
    params: { vcoWaveSel: 2, lpgCutoff: 0.45, lpgReso: 0.55, lpgDecay: 0.3, lpgDrive: 0.5, glide: 0.25, voiceMode: 0 },
    patch: [[S.FUNC1, D.CUTOFF, 0.6], [S.FUNC2, D.CUTOFF, 0.25]],
  },
  {
    name: 'Pad', variants: ['Aurora', 'Velvet', 'Mist', 'Halo'],
    scale: 'major', density: 0.35, span: 9,
    params: { fn1Rise: 0.4, fn1Fall: 0.6, lpgDecay: 0.8, lpgCutoff: 0.6, spaceSize: 0.75, spaceType: 2, voiceMode: 2, glide: 0.2 },
    patch: [[S.FUNC2, D.WAVE, 0.3], [S.FUNC2, D.SIZE, 0.4], [S.RND1, D.FOLD, 0.2]],
  },
];

function buildSeq(a: Archetype, rnd: () => number): ModularSeq {
  const gate: boolean[] = [];
  const note: number[] = [];
  const fn1: boolean[] = [];
  const fn2: boolean[] = [];
  const lpg: boolean[] = [];
  const space: boolean[] = [];
  for (let i = 0; i < 16; i++) {
    const downbeat = i % 4 === 0;
    const g = downbeat || rnd() < a.density;
    gate.push(g);
    note.push(degToSemi(a.scale, Math.floor(rnd() * a.span)));
    fn1.push(g && rnd() < 0.25);
    fn2.push(rnd() < 0.12);
    lpg.push(g && (downbeat || rnd() < 0.3));     // accents
    space.push(rnd() < 0.14);
  }
  return { gate, note, fn1, fn2, lpg, space };
}

function buildPresets(): ModularPreset[] {
  const out: ModularPreset[] = [];
  ARCHETYPES.forEach((a, ai) => {
    a.variants.forEach((variant, vi) => {
      const rnd = mulberry32((ai + 1) * 1000 + vi * 37 + 7);
      // Per-variant timbral nudge so the four siblings differ audibly.
      const nudge: Partial<ModularParams> = {
        vcoWave: Math.min(1, 0.2 + vi * 0.18 + rnd() * 0.1),
        foldAmt: Math.min(1, (a.params.foldAmt ?? 0.25) + (vi - 1.5) * 0.08),
        lpgCutoff: Math.min(1, Math.max(0.2, (a.params.lpgCutoff ?? 0.55) + (rnd() - 0.5) * 0.2)),
        spaceType: vi % 5,
        seqScale: SCALE_IDX[a.scale] ?? 1,
      };
      const params: ModularParams = { ...DEFAULT_MODULAR, ...a.params, ...nudge };
      out.push({
        name: `${a.name} ${variant}`,
        params,
        patch: mkPatch(a.patch),
        seq: buildSeq(a, rnd),
      });
    });
  });
  return out;
}

export const MODULAR_PRESETS: ModularPreset[] = buildPresets();
export const MODULAR_PRESET_NAMES: string[] = MODULAR_PRESETS.map((p) => p.name);
