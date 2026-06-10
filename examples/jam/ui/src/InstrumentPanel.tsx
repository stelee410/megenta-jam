/**
 * Copyright 2026 Google LLC
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

/**
 * InstrumentPanel — the Instrument tab, laid out faithfully after the Arturia
 * MicroFreak front panel: MATRIX → utility row on top, then
 * GLIDE · DIGITAL OSCILLATOR · ANALOG FILTER · CYCLING ENVELOPE,
 * OCTAVE · ARP/SEQ · LFO · ENVELOPE — with the hardware's visual language
 * (orange oscillator knobs, white encoders, black pots, LED selectors, an
 * OLED preset display) plus an AI patch designer.
 */

import { useState } from 'react';

export interface SynthParams {
  oscType: number;     // 0 analog · 1 supersaw · 2 wavetable · 3 fm · 4 harmonic
  wave: number;
  timbre: number;
  shape: number;
  glide: number;
  attack: number;
  decay: number;
  sustain: number;
  release: number;
  filterType: number;  // 0 lp · 1 bp · 2 hp
  cutoff: number;
  resonance: number;
  envFilter: number;   // 0..1, center 0.5 = none
  lfoShape: number;    // 0 sine · 1 tri · 2 saw · 3 square · 4 s&h
  lfoRate: number;
  lfoSync: number;     // 0/1
  cycMode: number;     // 0 env · 1 run · 2 loop
  cycRise: number;
  cycFall: number;
  cycHold: number;     // env: sustain level · run/loop: hold time
  cycRiseShape: number; // Shift+Rise: 0 log · 0.5 lin · 1 exp
  cycFallShape: number; // Shift+Fall
  cycAmount: number;
  arpMode: number;     // 0 off · 1 up · 2 down · 3 updown · 4 random · 5 order · 6 pattern
  arpOct: number;      // 1..4
  arpDiv: number;      // 0=1/4 · 1=1/8 · 2=1/8T · 3=1/16 · 4=1/16T · 5=1/32
  arpHold: number;     // 0/1
  arpSwing: number;
  arpGate: number;
  arpSpice: number;
  monoMode: number;    // 0/1
  chorus: number;      // stereo ensemble
  space: number;       // plate reverb
  volume: number;
}

export const DEFAULT_SYNTH: SynthParams = {
  oscType: 1, wave: 0.5, timbre: 0.5, shape: 0.3, glide: 0,
  attack: 0.05, decay: 0.4, sustain: 0.6, release: 0.3,
  filterType: 0, cutoff: 0.7, resonance: 0.2, envFilter: 0.5,
  lfoShape: 0, lfoRate: 0.3, lfoSync: 0,
  cycMode: 0, cycRise: 0.2, cycFall: 0.4, cycHold: 0.5,
  cycRiseShape: 0.5, cycFallShape: 0.5, cycAmount: 1,
  arpMode: 0, arpOct: 1, arpDiv: 3, arpHold: 0,
  arpSwing: 0, arpGate: 0.55, arpSpice: 0,
  monoMode: 0, chorus: 0.25, space: 0.2, volume: 0.6,
};

export const OSC_TYPES = ['analog', 'supersaw', 'wavetable', 'fm', 'harmonic'] as const;
export const FILTER_TYPES = ['LPF', 'BPF', 'HPF'] as const;
export const LFO_SHAPES = ['∿ sine', '⋀ tri', '◿ saw', '⊓ sqr', '⁘ s&h'] as const;
export const CYC_MODES = ['env', 'run', 'loop'] as const;
export const ARP_MODES = ['off', 'up', 'down', 'up·dn', 'rand', 'order', 'pattern'] as const;
export const ARP_DIVS = ['1/4', '1/8', '1/8T', '1/16', '1/16T', '1/32'] as const;
export const MATRIX_SRC = ['cycenv', 'env', 'lfo', 'velo', 'key'] as const;
export const MATRIX_DST = ['pitch', 'wave', 'timbre', 'shape', 'cutoff'] as const;

// Per-engine names for the three oscillator macros.
const OSC_MACROS: Record<number, [string, string, string]> = {
  0: ['Sub', 'Saw·Pls', 'PW'],
  1: ['Unison', 'Detune', 'Mix'],
  2: ['Position', 'Fold', 'Bend'],
  3: ['Ratio', 'Index', 'Fdbk'],
  4: ['Partials', 'Rolloff', 'Odd·Ev'],
};

const clamp01 = (v: number) => Math.max(0, Math.min(1, v));
const clampB = (v: number) => Math.max(-1, Math.min(1, v));

/** Hardware-style rotary: pointer-line knob with a tick arc.
 *  variant: 'black' (pots) · 'orange' (oscillator) · 'white' (encoders).
 *  steps: snap to N detents and show stepLabels[i] as the value. */
function FreakKnob({
  label, value, onChange,
  variant = 'black', size = 'md', bipolar = false,
  steps, stepLabels, accent = false,
}: {
  label: string;
  value: number;
  onChange: (v: number) => void;
  variant?: 'black' | 'orange' | 'white';
  size?: 'sm' | 'md' | 'lg';
  bipolar?: boolean;
  steps?: number;
  stepLabels?: readonly string[];
  accent?: boolean;
}) {
  const stepIdx = steps ? Math.min(steps - 1, Math.round(value * (steps - 1))) : 0;
  const shown = steps ? stepIdx / Math.max(1, steps - 1) : value;
  const display = steps && stepLabels
    ? stepLabels[stepIdx]
    : bipolar
      ? `${value >= 0.5 ? '+' : ''}${Math.round((value - 0.5) * 200)}`
      : `${Math.round(value * 100)}`;
  const set = (raw: number) => {
    const v = clamp01(raw);
    onChange(steps ? Math.round(v * (steps - 1)) / Math.max(1, steps - 1) : v);
  };
  return (
    <div
      className={`freak-knob is-${variant} is-${size}`}
      role="slider"
      tabIndex={0}
      aria-label={label}
      aria-valuemin={0}
      aria-valuemax={100}
      aria-valuenow={Math.round(value * 100)}
      title={`${label}: ${display}`}
      onPointerDown={(e) => {
        e.preventDefault();
        const el = e.currentTarget;
        el.setPointerCapture(e.pointerId);
        const startY = e.clientY;
        const startV = value;
        const move = (ev: PointerEvent) => set(startV + (startY - ev.clientY) / 160);
        const up = () => {
          el.removeEventListener('pointermove', move as any);
          el.removeEventListener('pointerup', up as any);
          el.removeEventListener('pointercancel', up as any);
        };
        el.addEventListener('pointermove', move as any);
        el.addEventListener('pointerup', up as any);
        el.addEventListener('pointercancel', up as any);
      }}
      onWheel={(e) => {
        e.preventDefault();
        e.stopPropagation();
        const d = Math.max(-0.04, Math.min(0.04, -e.deltaY * 0.001));
        set(value + (e.shiftKey ? d * 2.5 : d) * (steps ? 3 : 1));
      }}
      onKeyDown={(e) => {
        if (e.key !== 'ArrowUp' && e.key !== 'ArrowDown') return;
        e.preventDefault();
        const d = steps ? 1 / Math.max(1, steps - 1) : (e.shiftKey ? 0.05 : 0.01);
        set(value + (e.key === 'ArrowUp' ? d : -d));
      }}
    >
      <div className="freak-knob-arc" />
      <div
        className="freak-knob-body"
        style={{ transform: `rotate(${-135 + shown * 270}deg)` }}
      >
        <span className="freak-knob-pointer" />
      </div>
      <span className={`freak-knob-label ${accent ? 'is-accent' : ''}`}>{label}</span>
      <span className="freak-knob-value">{display}</span>
    </div>
  );
}

/** Vertical LED selector list (filter type, LFO shape, modes…). */
function LedList({
  options, value, onChange, horizontal = false,
}: {
  options: readonly string[];
  value: number;
  onChange: (i: number) => void;
  horizontal?: boolean;
}) {
  return (
    <div className={`freak-leds ${horizontal ? 'is-horizontal' : ''}`}>
      {options.map((opt, i) => (
        <button
          key={opt}
          className={`freak-led ${i === value ? 'is-on' : ''}`}
          onClick={() => onChange(i)}
        >
          <span className="freak-led-dot" />
          <span className="freak-led-text">{opt}</span>
        </button>
      ))}
    </div>
  );
}

/** Mod matrix in the hardware's LED-grid style. */
function MatrixGrid({
  matrix, onCell,
}: {
  matrix: number[];
  onCell: (index: number, value: number) => void;
}) {
  return (
    <div className="freak-matrix">
      <div className="freak-matrix-row freak-matrix-head">
        <span />
        {MATRIX_DST.map(d => <span key={d} className="freak-matrix-dst">{d}</span>)}
      </div>
      {MATRIX_SRC.map((src, s) => (
        <div className="freak-matrix-row" key={src}>
          <span className="freak-matrix-src">{src}</span>
          {MATRIX_DST.map((_, d) => {
            const idx = s * 5 + d;
            const v = matrix[idx];
            const mag = Math.min(1, Math.abs(v));
            return (
              <button
                key={idx}
                className={`freak-matrix-cell ${v > 0.005 ? 'is-pos' : v < -0.005 ? 'is-neg' : ''}`}
                style={{ '--mag': mag } as React.CSSProperties}
                title={`${src} → ${MATRIX_DST[d]}: ${Math.round(v * 100)}  (drag · dbl-click clears)`}
                onDoubleClick={() => onCell(idx, 0)}
                onPointerDown={(e) => {
                  e.preventDefault();
                  const el = e.currentTarget;
                  el.setPointerCapture(e.pointerId);
                  const startY = e.clientY;
                  const startV = v;
                  const move = (ev: PointerEvent) => onCell(idx, clampB(startV + (startY - ev.clientY) / 110));
                  const up = () => {
                    el.removeEventListener('pointermove', move as any);
                    el.removeEventListener('pointerup', up as any);
                    el.removeEventListener('pointercancel', up as any);
                  };
                  el.addEventListener('pointermove', move as any);
                  el.addEventListener('pointerup', up as any);
                  el.addEventListener('pointercancel', up as any);
                }}
              />
            );
          })}
        </div>
      ))}
    </div>
  );
}

export interface SynthPreset {
  name: string;
  params: SynthParams;
  matrix: number[];
}

export function InstrumentPanel({
  synth,
  matrix,
  onParam,
  onMatrix,
  onDice,
  patchName,
  onPatchName,
  presets,
  factory,
  onSavePreset,
  onLoadPreset,
  onDeletePreset,
  octaveOffset,
  onOctave,
  aiBusy,
  aiError,
  onAiPatch,
}: {
  synth: SynthParams;
  matrix: number[];
  onParam: (key: keyof SynthParams, value: number) => void;
  onMatrix: (index: number, value: number) => void;
  onDice: () => void;
  patchName: string;
  onPatchName: (name: string) => void;
  presets: SynthPreset[];
  factory: Array<SynthPreset & { category: string }>;
  onSavePreset: () => void;
  onLoadPreset: (name: string) => void;
  onDeletePreset: (name: string) => void;
  octaveOffset: number;
  onOctave: (dir: -1 | 1) => void;
  aiBusy: boolean;
  aiError: string | null;
  onAiPatch: (desc: string) => void;
}) {
  const [desc, setDesc] = useState('');
  // Hardware Shift: flips the Rise/Fall knobs to their Shape functions.
  const [shift, setShift] = useState(false);
  const macros = OSC_MACROS[synth.oscType] ?? OSC_MACROS[0];

  const submit = () => {
    const t = desc.trim();
    if (!t || aiBusy) return;
    onAiPatch(t);
  };

  return (
    <div className="freak">
      {/* ═══ Top row: MATRIX · paraphonic · display · master ═══ */}
      <div className="freak-top">
        <section className="freak-block freak-block-matrix">
          <MatrixGrid matrix={matrix} onCell={onMatrix} />
          <div className="freak-rule"><span>MATRIX</span></div>
        </section>

        <div className="freak-top-mid">
          <button
            className={`freak-soft ${synth.monoMode ? '' : 'is-lit'}`}
            onClick={() => onParam('monoMode', synth.monoMode ? 0 : 1)}
            title="Paraphonic (6 voices) / mono (last-note priority)"
          >
            Paraphonic
          </button>

          <div className="freak-oled">
            <div className="freak-oled-title">{`Preset ${presets.findIndex(p => p.name === patchName) + 1 || '·'}`}</div>
            <input
              className="freak-oled-name"
              type="text"
              value={patchName}
              spellCheck={false}
              onChange={(e) => onPatchName(e.target.value)}
              onKeyDown={(e) => e.stopPropagation()}
            />
            <div className="freak-oled-engine">◆ {OSC_TYPES[synth.oscType]}</div>
          </div>

          <div className="freak-preset-keys">
            <select
              className="freak-soft freak-preset-select"
              value=""
              onChange={(e) => { if (e.target.value) onLoadPreset(e.target.value); }}
              title="Browse the 81 factory presets + your saved patches"
            >
              <option value="">Preset ▾</option>
              {[...new Set(factory.map(f => f.category))].map(cat => (
                <optgroup key={cat} label={`◆ ${cat}`}>
                  {factory.filter(f => f.category === cat).map(p => (
                    <option key={p.name} value={p.name}>{p.name}</option>
                  ))}
                </optgroup>
              ))}
              {presets.length > 0 && (
                <optgroup label="◇ User">
                  {presets.map(p => <option key={p.name} value={p.name}>{p.name}</option>)}
                </optgroup>
              )}
            </select>
            <button className="freak-soft" onClick={onSavePreset} title="Save current patch">Save</button>
            {presets.some(p => p.name === patchName) ? (
              <button
                className="freak-soft is-danger"
                onClick={() => onDeletePreset(patchName)}
                title="Delete this preset"
              >
                Delete
              </button>
            ) : (
              <button className="freak-soft" disabled>Utility</button>
            )}
          </div>
        </div>

        <div className="freak-top-right">
          <div className="freak-grain">𝄞 grain de jam</div>
          <div className="freak-knobs">
            <FreakKnob label="Ensemble" value={synth.chorus} onChange={(v) => onParam('chorus', v)} size="sm" />
            <FreakKnob label="Space" value={synth.space} onChange={(v) => onParam('space', v)} size="sm" />
            <FreakKnob label="Master" value={synth.volume} onChange={(v) => onParam('volume', v)} size="lg" />
          </div>
        </div>
      </div>

      {/* ═══ AI patch designer strip ═══ */}
      <div className="freak-ai">
        <span className="freak-ai-tag">AI</span>
        <input
          className="freak-ai-input"
          type="text"
          placeholder="describe a sound… 温暖的复古贝斯 / a glassy fm pluck with slow vibrato"
          value={desc}
          onChange={(e) => setDesc(e.target.value)}
          onKeyDown={(e) => {
            if (
              e.key === 'Enter' &&
              !e.nativeEvent.isComposing &&
              (e.nativeEvent as KeyboardEvent).keyCode !== 229
            ) {
              e.preventDefault();
              submit();
            }
            e.stopPropagation();
          }}
        />
        <button className="freak-soft is-lit" disabled={!desc.trim() || aiBusy} onClick={submit}>
          {aiBusy ? 'designing…' : 'Design'}
        </button>
        {aiError && <span className="freak-ai-error">{aiError}</span>}
      </div>

      {/* ═══ Row 1: GLIDE · DIGITAL OSCILLATOR · ANALOG FILTER · CYCLING ENVELOPE ═══ */}
      <div className="freak-row freak-row-1">
        <section className="freak-block">
          <div className="freak-knobs">
            <FreakKnob label="Glide" value={synth.glide} onChange={(v) => onParam('glide', v)} />
          </div>
          <div className="freak-rule"><span>GLIDE</span></div>
        </section>

        <section className="freak-block">
          <div className="freak-knobs">
            <FreakKnob
              label="Type" value={synth.oscType / 4}
              onChange={(v) => onParam('oscType', Math.round(v * 4))}
              variant="orange" steps={5} stepLabels={OSC_TYPES}
            />
            <FreakKnob label={macros[0]} value={synth.wave} onChange={(v) => onParam('wave', v)} variant="orange" />
            <FreakKnob label={macros[1]} value={synth.timbre} onChange={(v) => onParam('timbre', v)} variant="orange" />
            <FreakKnob label={macros[2]} value={synth.shape} onChange={(v) => onParam('shape', v)} variant="orange" />
          </div>
          <div className="freak-rule"><span>DIGITAL OSCILLATOR</span></div>
        </section>

        <section className="freak-block">
          <div className="freak-knobs">
            <LedList options={FILTER_TYPES} value={synth.filterType} onChange={(i) => onParam('filterType', i)} />
            <FreakKnob label="Cutoff" value={synth.cutoff} onChange={(v) => onParam('cutoff', v)} size="lg" />
            <FreakKnob label="Resonance" value={synth.resonance} onChange={(v) => onParam('resonance', v)} />
          </div>
          <div className="freak-rule"><span>ANALOG FILTER</span></div>
        </section>

        <section className="freak-block">
          <div className="freak-knobs">
            <LedList options={CYC_MODES} value={synth.cycMode} onChange={(i) => onParam('cycMode', i)} />
            {shift ? (
              <FreakKnob label="Shape ↗" value={synth.cycRiseShape} onChange={(v) => onParam('cycRiseShape', v)} accent />
            ) : (
              <FreakKnob label="Rise / Shape" value={synth.cycRise} onChange={(v) => onParam('cycRise', v)} />
            )}
            {shift ? (
              <FreakKnob label="Shape ↘" value={synth.cycFallShape} onChange={(v) => onParam('cycFallShape', v)} accent />
            ) : (
              <FreakKnob label="Fall / Shape" value={synth.cycFall} onChange={(v) => onParam('cycFall', v)} />
            )}
            <FreakKnob
              label={synth.cycMode === 0 ? 'Sustain' : 'Hold'}
              value={synth.cycHold}
              onChange={(v) => onParam('cycHold', v)}
            />
            <FreakKnob label="Amount" value={synth.cycAmount} onChange={(v) => onParam('cycAmount', v)} />
          </div>
          <div className="freak-rule"><span>CYCLING ENVELOPE</span></div>
        </section>
      </div>

      {/* ═══ Row 2: OCTAVE · ARP/SEQ · LFO · ENVELOPE ═══ */}
      <div className="freak-row freak-row-2">
        <section className="freak-block">
          <div className="freak-octave">
            <button className="freak-round" onClick={() => onOctave(-1)} title="Octave down">←</button>
            <span className="freak-oct-read">{octaveOffset > 0 ? `+${octaveOffset}` : octaveOffset}</span>
            <button className="freak-round" onClick={() => onOctave(1)} title="Octave up">→</button>
            <button
              className={`freak-round freak-shift ${shift ? 'is-lit' : ''}`}
              onClick={() => setShift(s => !s)}
              title="Shift — Rise/Fall knobs edit their curve Shapes"
            >
              ⇧
            </button>
          </div>
          <div className="freak-rule"><span>OCTAVE · SHIFT</span></div>
        </section>

        <section className="freak-block freak-block-arp">
          <div className="freak-knobs">
            <LedList options={ARP_MODES} value={synth.arpMode} onChange={(i) => onParam('arpMode', i)} />
            <div className="freak-arp-mid">
              <div className="freak-arp-toggles">
                <button
                  className={`freak-soft ${synth.arpHold ? 'is-lit' : ''}`}
                  onClick={() => onParam('arpHold', synth.arpHold ? 0 : 1)}
                >
                  Hold
                </button>
                <LedList
                  options={['1 oct', '2 oct', '3 oct', '4 oct']}
                  value={synth.arpOct - 1}
                  onChange={(i) => onParam('arpOct', i + 1)}
                />
                <button className="freak-soft" onClick={onDice} title="Re-roll the pattern (Dice)">
                  ⚄ Dice
                </button>
              </div>
            </div>
            <FreakKnob
              label="Rate" value={synth.arpDiv / 5}
              onChange={(v) => onParam('arpDiv', Math.round(v * 5))}
              variant="white" size="lg" steps={6} stepLabels={ARP_DIVS}
            />
            <FreakKnob label="Swing" value={synth.arpSwing} onChange={(v) => onParam('arpSwing', v)} accent />
            <FreakKnob label="Gate" value={synth.arpGate} onChange={(v) => onParam('arpGate', v)} />
            <FreakKnob label="Spice" value={synth.arpSpice} onChange={(v) => onParam('arpSpice', v)} accent />
          </div>
          <div className="freak-rule"><span>ARP / SEQ</span></div>
        </section>

        <section className="freak-block">
          <div className="freak-knobs">
            <LedList options={LFO_SHAPES} value={synth.lfoShape} onChange={(i) => onParam('lfoShape', i)} />
            <FreakKnob label="Rate" value={synth.lfoRate} onChange={(v) => onParam('lfoRate', v)} variant="white" size="lg" />
            <button
              className={`freak-soft freak-sync ${synth.lfoSync ? 'is-lit' : ''}`}
              onClick={() => onParam('lfoSync', synth.lfoSync ? 0 : 1)}
              title="Sync the LFO to the BPM"
            >
              Sync
            </button>
          </div>
          <div className="freak-rule"><span>LFO</span></div>
        </section>

        <section className="freak-block">
          <div className="freak-knobs">
            <FreakKnob label="Attack" value={synth.attack} onChange={(v) => onParam('attack', v)} />
            <FreakKnob label="Decay / Rel" value={synth.decay} onChange={(v) => { onParam('decay', v); onParam('release', v); }} />
            <FreakKnob label="Sustain" value={synth.sustain} onChange={(v) => onParam('sustain', v)} />
            <FreakKnob label="Filter Amt" value={synth.envFilter} onChange={(v) => onParam('envFilter', v)} bipolar />
          </div>
          <div className="freak-rule"><span>ENVELOPE</span></div>
        </section>
      </div>

      {/* ═══ Decorative band + wordmark ═══ */}
      <div className="freak-band">
        <span className="freak-wordmark">MICRO·JAM</span>
        <span className="freak-wordsub">algorithmic performance synthesizer</span>
      </div>
    </div>
  );
}
