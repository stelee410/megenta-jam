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
 * ModularPanel — the Modular tab, a West-Coast semi-modular synth laid out
 * after the "FLOW MODULAR": cream module panels (VCO, two function
 * generators, wave folder, random source, low-pass gate, space, output), a
 * patch matrix, and a motion step sequencer. Drives the native JamModular
 * voice via post({type:'modularParam'|'modularPatch'|'modularSeq'}).
 */

import { useState } from 'react';
import type React from 'react';

const clamp01 = (v: number) => Math.max(0, Math.min(1, v));
const clampB = (v: number) => Math.max(-1, Math.min(1, v));

// ── Parameter schema (mirrors JamModular atomics) ──
export interface ModularParams {
  voiceMode: number;   // 0 mono · 1 duo · 2 poly
  glide: number;
  vcoWaveSel: number;  // 0 sine · 1 tri · 2 saw
  vcoPitch: number;    // bipolar
  vcoWave: number;
  vcoScale: number;
  vcoFold: number;
  foldAmt: number;
  foldBias: number;    // bipolar
  fn1Rise: number; fn1Fall: number; fn1Shape: number; fn1Cycle: number;
  fn2Rise: number; fn2Fall: number; fn2Shape: number; fn2Cycle: number;
  rndMode: number; rndRate: number; rndProb: number;
  lpgCutoff: number; lpgReso: number; lpgDecay: number; lpgDrive: number;
  spaceType: number; spaceSize: number;
  outVol: number; outWidth: number;
  seqRun: number; seqDiv: number; seqLen: number;
  seqScale: number; seqOctave: number; seqSwing: number;
}

export const DEFAULT_MODULAR: ModularParams = {
  voiceMode: 0, glide: 0,
  vcoWaveSel: 1, vcoPitch: 0.5, vcoWave: 0.3, vcoScale: 0.5, vcoFold: 0,
  foldAmt: 0.25, foldBias: 0.5,
  fn1Rise: 0.15, fn1Fall: 0.45, fn1Shape: 0.5, fn1Cycle: 0,
  fn2Rise: 0.3, fn2Fall: 0.5, fn2Shape: 0.5, fn2Cycle: 1,
  rndMode: 0, rndRate: 0.4, rndProb: 0.7,
  lpgCutoff: 0.55, lpgReso: 0.15, lpgDecay: 0.4, lpgDrive: 0.3,
  spaceType: 1, spaceSize: 0.4,
  outVol: 0.7, outWidth: 0.6,
  seqRun: 0, seqDiv: 3, seqLen: 16, seqScale: 1, seqOctave: 0, seqSwing: 0,
};

export const MOD_SRC = ['FUNC1', 'FUNC2', 'RND1', 'RND2', 'VELO', 'KEY', 'GATE'] as const;
export const MOD_DST = ['PITCH', 'WAVE', 'FOLD', 'CUTOFF', 'LEVEL', 'FN1·R', 'RND·R', 'SIZE'] as const;
export const RND_MODES = ['smooth', 'stepped', 's&h', 'burst'] as const;
export const SPACE_TYPES = ['spring', 'plate', 'hall', 'cloud', 'infinite'] as const;
export const VOICE_MODES = ['mono', 'duo', 'poly'] as const;
export const SEQ_DIVS = ['1/4', '1/8', '1/8T', '1/16', '1/16T', '1/32'] as const;
export const SEQ_SCALES = ['major', 'minor', 'dorian', 'penta', 'chromatic'] as const;
export const WAVE_SELS = ['∿', '⋀', '◣'] as const;

export interface ModularSeq {
  gate: boolean[];
  note: number[];
  fn1: boolean[];
  fn2: boolean[];
  lpg: boolean[];
  space: boolean[];
}

export const DEFAULT_SEQ: ModularSeq = {
  gate: Array.from({ length: 16 }, (_, i) => i % 4 === 0),
  note: Array(16).fill(0),
  fn1: Array(16).fill(false),
  fn2: Array(16).fill(false),
  lpg: Array.from({ length: 16 }, (_, i) => i % 8 === 0),
  space: Array(16).fill(false),
};

/** Eurorack-style knob: drag vertically; bipolar shows ± value. */
function Knob({
  label, value, onChange, bipolar = false, accent = 'cream', size = 'md',
}: {
  label: string;
  value: number;
  onChange: (v: number) => void;
  bipolar?: boolean;
  accent?: 'cream' | 'black' | 'orange' | 'blue' | 'purple';
  size?: 'sm' | 'md';
}) {
  const display = bipolar
    ? `${value >= 0.5 ? '+' : ''}${Math.round((value - 0.5) * 200)}`
    : `${Math.round(value * 100)}`;
  const set = (raw: number) => onChange(clamp01(raw));
  return (
    <div className={`mod-knob is-${accent} is-${size}`}>
      <div
        className="mod-knob-dial"
        role="slider"
        tabIndex={0}
        aria-label={label}
        aria-valuenow={Math.round(value * 100)}
        title={`${label}: ${display}`}
        style={{ ['--ang' as string]: `${-135 + value * 270}deg` }}
        onPointerDown={(e) => {
          e.preventDefault();
          const el = e.currentTarget;
          el.setPointerCapture(e.pointerId);
          const startY = e.clientY;
          const startV = value;
          const move = (ev: PointerEvent) => set(startV + (startY - ev.clientY) / 170);
          const up = () => {
            el.removeEventListener('pointermove', move as any);
            el.removeEventListener('pointerup', up as any);
            el.removeEventListener('pointercancel', up as any);
          };
          el.addEventListener('pointermove', move as any);
          el.addEventListener('pointerup', up as any);
          el.addEventListener('pointercancel', up as any);
        }}
        onDoubleClick={() => set(bipolar ? 0.5 : value)}
        onWheel={(e) => {
          e.preventDefault(); e.stopPropagation();
          set(value + Math.max(-0.05, Math.min(0.05, -e.deltaY * 0.0012)));
        }}
        onKeyDown={(e) => {
          if (e.key !== 'ArrowUp' && e.key !== 'ArrowDown') return;
          e.preventDefault();
          set(value + (e.key === 'ArrowUp' ? 1 : -1) * (e.shiftKey ? 0.05 : 0.01));
        }}
      >
        <span className="mod-knob-pointer" />
      </div>
      <span className="mod-knob-label">{label}</span>
    </div>
  );
}

/** Small LED selector (toggle through options). */
function Selector({
  options, value, onChange,
}: {
  options: readonly string[];
  value: number;
  onChange: (i: number) => void;
}) {
  return (
    <div className="mod-sel">
      {options.map((opt, i) => (
        <button
          key={opt}
          className={`mod-sel-led ${i === value ? 'is-on' : ''}`}
          onClick={() => onChange(i)}
        >
          <span className="mod-sel-dot" />
          {opt}
        </button>
      ))}
    </div>
  );
}

export function ModularPanel({
  params, onParam, patch, onPatch, seq, onSeq, step, onDice,
}: {
  params: ModularParams;
  onParam: (key: keyof ModularParams, value: number) => void;
  patch: number[];
  onPatch: (src: number, dst: number, value: number) => void;
  seq: ModularSeq;
  onSeq: (lane: keyof ModularSeq, stepIdx: number, value: number) => void;
  step: number;
  onDice: () => void;
}) {
  const [activeLane, setActiveLane] = useState<keyof ModularSeq>('gate');
  const running = params.seqRun > 0.5;

  return (
    <div className="modular">
      {/* ═══ Header ═══ */}
      <div className="mod-header">
        <div className="mod-title">
          <span className="mod-title-main">FLOW MODULAR</span>
          <span className="mod-title-sub">Semi-Modular Synthesizer</span>
        </div>
        <div className="mod-transport">
          <div className="mod-voicemode">
            {VOICE_MODES.map((m, i) => (
              <button
                key={m}
                className={params.voiceMode === i ? 'is-active' : ''}
                onClick={() => onParam('voiceMode', i)}
              >{m}</button>
            ))}
          </div>
          <button
            className={`mod-run ${running ? 'is-on' : ''}`}
            onClick={() => onParam('seqRun', running ? 0 : 1)}
          >
            {running ? '■ STOP' : '▶ RUN'}
          </button>
          <button className="mod-dice" onClick={onDice} title="Randomize sequence">⚄ DICE</button>
        </div>
      </div>

      {/* ═══ Module rack ═══ */}
      <div className="mod-rack">
        <section className="mod-module is-vco">
          <div className="mod-module-head">VCO 1</div>
          <div className="mod-knobs">
            <div className="mod-wavesel">
              <Selector options={WAVE_SELS} value={params.vcoWaveSel} onChange={(i) => onParam('vcoWaveSel', i)} />
            </div>
            <Knob label="PITCH" value={params.vcoPitch} onChange={(v) => onParam('vcoPitch', v)} bipolar accent="orange" />
            <Knob label="WAVE" value={params.vcoWave} onChange={(v) => onParam('vcoWave', v)} accent="orange" />
            <Knob label="SCALE" value={params.vcoScale} onChange={(v) => onParam('vcoScale', v)} accent="black" />
            <Knob label="FOLD" value={params.vcoFold} onChange={(v) => onParam('vcoFold', v)} accent="black" />
            <Knob label="GLIDE" value={params.glide} onChange={(v) => onParam('glide', v)} accent="black" size="sm" />
          </div>
        </section>

        <section className="mod-module">
          <div className="mod-module-head">FUNCTION 1</div>
          <div className="mod-knobs">
            <Knob label="RISE" value={params.fn1Rise} onChange={(v) => onParam('fn1Rise', v)} accent="black" />
            <Knob label="FALL" value={params.fn1Fall} onChange={(v) => onParam('fn1Fall', v)} accent="black" />
            <Knob label="SHAPE" value={params.fn1Shape} onChange={(v) => onParam('fn1Shape', v)} accent="black" />
            <div className="mod-cycle">
              <button className={params.fn1Cycle ? '' : 'is-active'} onClick={() => onParam('fn1Cycle', 0)}>ONCE</button>
              <button className={params.fn1Cycle ? 'is-active' : ''} onClick={() => onParam('fn1Cycle', 1)}>LOOP</button>
            </div>
          </div>
        </section>

        <section className="mod-module">
          <div className="mod-module-head">FUNCTION 2</div>
          <div className="mod-knobs">
            <Knob label="RISE" value={params.fn2Rise} onChange={(v) => onParam('fn2Rise', v)} accent="black" />
            <Knob label="FALL" value={params.fn2Fall} onChange={(v) => onParam('fn2Fall', v)} accent="black" />
            <Knob label="SHAPE" value={params.fn2Shape} onChange={(v) => onParam('fn2Shape', v)} accent="black" />
            <div className="mod-cycle">
              <button className={params.fn2Cycle ? '' : 'is-active'} onClick={() => onParam('fn2Cycle', 0)}>ONCE</button>
              <button className={params.fn2Cycle ? 'is-active' : ''} onClick={() => onParam('fn2Cycle', 1)}>LOOP</button>
            </div>
          </div>
        </section>

        <section className="mod-module is-blue">
          <div className="mod-module-head">WAVE FOLDER</div>
          <div className="mod-knobs">
            <Knob label="FOLD" value={params.foldAmt} onChange={(v) => onParam('foldAmt', v)} accent="blue" />
            <Knob label="BIAS" value={params.foldBias} onChange={(v) => onParam('foldBias', v)} bipolar accent="black" />
          </div>
        </section>

        <section className="mod-module">
          <div className="mod-module-head">RANDOM SOURCE</div>
          <div className="mod-knobs">
            <div className="mod-modesel">
              <Selector options={RND_MODES} value={params.rndMode} onChange={(i) => onParam('rndMode', i)} />
            </div>
            <Knob label="RATE" value={params.rndRate} onChange={(v) => onParam('rndRate', v)} accent="black" />
            <Knob label="PROB" value={params.rndProb} onChange={(v) => onParam('rndProb', v)} accent="black" />
          </div>
        </section>

        <section className="mod-module is-purple">
          <div className="mod-module-head">LPG · LOW PASS GATE</div>
          <div className="mod-knobs">
            <Knob label="CUTOFF" value={params.lpgCutoff} onChange={(v) => onParam('lpgCutoff', v)} accent="purple" />
            <Knob label="RESO" value={params.lpgReso} onChange={(v) => onParam('lpgReso', v)} accent="black" />
            <Knob label="DECAY" value={params.lpgDecay} onChange={(v) => onParam('lpgDecay', v)} accent="purple" />
            <Knob label="DRIVE" value={params.lpgDrive} onChange={(v) => onParam('lpgDrive', v)} accent="black" />
          </div>
        </section>

        <section className="mod-module is-blue">
          <div className="mod-module-head">SPACE OUT</div>
          <div className="mod-knobs">
            <div className="mod-modesel">
              <Selector options={SPACE_TYPES} value={params.spaceType} onChange={(i) => onParam('spaceType', i)} />
            </div>
            <Knob label="SIZE" value={params.spaceSize} onChange={(v) => onParam('spaceSize', v)} accent="blue" />
          </div>
        </section>

        <section className="mod-module is-out">
          <div className="mod-module-head">OUTPUT</div>
          <div className="mod-knobs">
            <Knob label="VOLUME" value={params.outVol} onChange={(v) => onParam('outVol', v)} accent="orange" />
            <Knob label="WIDTH" value={params.outWidth} onChange={(v) => onParam('outWidth', v)} accent="black" />
          </div>
        </section>
      </div>

      {/* ═══ Patch matrix ═══ */}
      <section className="mod-patch">
        <div className="mod-section-label">PATCH MATRIX</div>
        <div className="mod-matrix">
          <div className="mod-matrix-row mod-matrix-head">
            <span className="mod-matrix-corner" />
            {MOD_DST.map((d) => <span key={d} className="mod-matrix-dst">{d}</span>)}
          </div>
          {MOD_SRC.map((src, s) => (
            <div className="mod-matrix-row" key={src}>
              <span className="mod-matrix-src">{src}</span>
              {MOD_DST.map((_, d) => {
                const idx = s * MOD_DST.length + d;
                const v = patch[idx] ?? 0;
                const mag = Math.min(1, Math.abs(v));
                return (
                  <button
                    key={idx}
                    className={`mod-matrix-cell ${v > 0.005 ? 'is-pos' : v < -0.005 ? 'is-neg' : ''}`}
                    style={{ ['--mag' as string]: mag } as React.CSSProperties}
                    title={`${src} → ${MOD_DST[d]}: ${Math.round(v * 100)} (drag · dbl-click clears)`}
                    onDoubleClick={() => onPatch(s, d, 0)}
                    onPointerDown={(e) => {
                      e.preventDefault();
                      const el = e.currentTarget;
                      el.setPointerCapture(e.pointerId);
                      const startY = e.clientY;
                      const startV = v;
                      const move = (ev: PointerEvent) => onPatch(s, d, clampB(startV + (startY - ev.clientY) / 110));
                      const up = () => {
                        el.removeEventListener('pointermove', move as any);
                        el.removeEventListener('pointerup', up as any);
                        el.removeEventListener('pointercancel', up as any);
                      };
                      el.addEventListener('pointermove', move as any);
                      el.addEventListener('pointerup', up as any);
                      el.addEventListener('pointercancel', up as any);
                    }}
                  >
                    <span className="mod-matrix-fill" />
                  </button>
                );
              })}
            </div>
          ))}
        </div>
      </section>

      {/* ═══ Motion sequencer ═══ */}
      <section className="mod-seq">
        <div className="mod-seq-top">
          <div className="mod-section-label">MOTION SEQUENCER</div>
          <div className="mod-seq-cfg">
            <label>SCALE
              <select value={params.seqScale} onChange={(e) => onParam('seqScale', +e.target.value)}>
                {SEQ_SCALES.map((s, i) => <option key={s} value={i}>{s}</option>)}
              </select>
            </label>
            <label>DIV
              <select value={params.seqDiv} onChange={(e) => onParam('seqDiv', +e.target.value)}>
                {SEQ_DIVS.map((s, i) => <option key={s} value={i}>{s}</option>)}
              </select>
            </label>
            <label>OCT
              <select value={params.seqOctave} onChange={(e) => onParam('seqOctave', +e.target.value)}>
                {[-2, -1, 0, 1, 2].map((o) => <option key={o} value={o}>{o > 0 ? `+${o}` : o}</option>)}
              </select>
            </label>
            <label>LEN
              <select value={params.seqLen} onChange={(e) => onParam('seqLen', +e.target.value)}>
                {[4, 8, 12, 16].map((l) => <option key={l} value={l}>{l}</option>)}
              </select>
            </label>
            <Knob label="SWING" value={params.seqSwing} onChange={(v) => onParam('seqSwing', v)} accent="black" size="sm" />
          </div>
        </div>

        <div className="mod-seq-lanes">
          {(['gate', 'note', 'fn1', 'fn2', 'lpg', 'space'] as Array<keyof ModularSeq>).map((lane) => (
            <button
              key={lane}
              className={`mod-lane-btn ${activeLane === lane ? 'is-active' : ''} is-${lane}`}
              onClick={() => setActiveLane(lane)}
            >{lane.toUpperCase()}</button>
          ))}
        </div>

        <div className="mod-seq-grid">
          {Array.from({ length: 16 }, (_, i) => {
            const isCur = i === step;
            const beat = Math.floor(i / 4);
            if (activeLane === 'note') {
              const deg = seq.note[i] ?? 0;
              return (
                <div key={i} className={`mod-step-col ${isCur ? 'is-cur' : ''} beat-${beat % 2}`}>
                  <button
                    className="mod-step-note"
                    title={`Step ${i + 1}: degree ${deg} (drag up/down)`}
                    onPointerDown={(e) => {
                      e.preventDefault();
                      const el = e.currentTarget;
                      el.setPointerCapture(e.pointerId);
                      const startY = e.clientY;
                      const startV = deg;
                      const move = (ev: PointerEvent) => {
                        const nv = Math.max(0, Math.min(13, Math.round(startV + (startY - ev.clientY) / 16)));
                        if (nv !== (seq.note[i] ?? 0)) onSeq('note', i, nv);
                      };
                      const up = () => {
                        el.removeEventListener('pointermove', move as any);
                        el.removeEventListener('pointerup', up as any);
                      };
                      el.addEventListener('pointermove', move as any);
                      el.addEventListener('pointerup', up as any);
                    }}
                  >
                    <span className="mod-step-note-bar" style={{ height: `${10 + deg * 6}%` }} />
                    <span className="mod-step-note-val">{deg}</span>
                  </button>
                  <span className="mod-step-num">{i + 1}</span>
                </div>
              );
            }
            const on = (seq[activeLane] as boolean[])[i] ?? false;
            return (
              <div key={i} className={`mod-step-col ${isCur ? 'is-cur' : ''} beat-${beat % 2}`}>
                <button
                  className={`mod-step-cell is-${activeLane} ${on ? 'is-on' : ''}`}
                  onClick={() => onSeq(activeLane, i, on ? 0 : 1)}
                  title={`Step ${i + 1}`}
                />
                <span className="mod-step-num">{i + 1}</span>
              </div>
            );
          })}
        </div>
      </section>
    </div>
  );
}
