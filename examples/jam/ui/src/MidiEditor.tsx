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
 * MidiEditor — piano-roll clip editor for a PGM MIDI lane.
 *
 *  - Chord progression rendered as a reference band + per-chord shading;
 *    notes are colored by harmony: chord tone (yellow), in-key (dim),
 *    dissonant (red).
 *  - Live editing during playback: drag to move, drag right edge to resize,
 *    double-click empty space to add, double-click a note (or ⌫) to delete.
 *    Edits are debounced back to the lane synth, audible immediately.
 *  - SPACE toggles the stem transport, the ruler seeks, ⌘Z undoes.
 *  - ✨ 优化: quantize to 1/16, drop ultra-short notes, snap dissonant
 *    pitches to the nearest chord tone, merge same-pitch overlaps.
 */

import React, { useEffect, useMemo, useRef, useState } from 'react';

export type ClipNote = [start: number, dur: number, pitch: number, vel: number];

export interface MidiChord { start: number; end: number; label: string; none?: boolean }

const PC_NAMES = ['C', 'C#', 'D', 'D#', 'E', 'F', 'F#', 'G', 'G#', 'A', 'A#', 'B'];
const BLACK = new Set([1, 3, 6, 8, 10]);

/** "C#m" → {root, minor} (matches the native chord label writer). */
function parseChordLabel(label: string): { root: number; minor: boolean } | null {
  for (let pc = 11; pc >= 0; pc--) {
    const nm = PC_NAMES[pc];
    if (label === nm) return { root: pc, minor: false };
    if (label === nm + 'm') return { root: pc, minor: true };
  }
  return null;
}

/** "C# minor" → scale pitch-class set (natural minor incl. raised 7th / major). */
function keyScale(keyStr: string): Set<number> | null {
  const m = keyStr.match(/^([A-G]#?)\s+(major|minor)/i);
  if (!m) return null;
  const tonic = PC_NAMES.indexOf(m[1]);
  if (tonic < 0) return null;
  const iv = /minor/i.test(m[2]) ? [0, 2, 3, 5, 7, 8, 10, 11] : [0, 2, 4, 5, 7, 9, 11];
  return new Set(iv.map(x => (tonic + x) % 12));
}

type Harmony = 'chord' | 'scale' | 'off';

function makeHarmonyFn(chords: MidiChord[], keyStr: string) {
  const segs = chords
    .filter(c => !c.none)
    .map(c => ({ ...c, parsed: parseChordLabel(c.label) }))
    .filter(c => c.parsed);
  const scale = keyScale(keyStr);
  return (start: number, dur: number, pitch: number): Harmony => {
    const pc = ((pitch % 12) + 12) % 12;
    // Chord with the largest overlap against this note.
    let best: typeof segs[number] | null = null;
    let bestOv = 0;
    for (const c of segs) {
      const ov = Math.min(c.end, start + dur) - Math.max(c.start, start);
      if (ov > bestOv) { bestOv = ov; best = c; }
    }
    if (best) {
      const { root, minor } = best.parsed!;
      const tones = [root, (root + (minor ? 3 : 4)) % 12, (root + 7) % 12];
      if (tones.includes(pc)) return 'chord';
    }
    if (scale?.has(pc)) return best ? 'scale' : 'chord';
    return 'off';
  };
}

/** Nearest pitch whose pitch class is in `pcs`, within ±1 octave. */
function snapToPcs(pcs: number[], pitch: number): number {
  let out = pitch, dist = 99;
  for (const t of pcs) {
    for (let oct = -1; oct <= 1; oct++) {
      const cand = pitch - (((pitch % 12) + 12) % 12) + t + oct * 12;
      const d = Math.abs(cand - pitch);
      if (cand >= 0 && cand <= 127 && d < dist) { dist = d; out = cand; }
    }
  }
  return out;
}

/** Nearest consonant pitch under [start, start+dur): chord tone of the
 *  overlapping chord when there is one, else nearest key-scale tone. */
function snapToChord(
  chords: MidiChord[], keyStr: string,
  start: number, dur: number, pitch: number,
): number {
  let best: { root: number; minor: boolean } | null = null;
  let bestOv = 0;
  for (const c of chords) {
    if (c.none) continue;
    const p = parseChordLabel(c.label);
    if (!p) continue;
    const ov = Math.min(c.end, start + dur) - Math.max(c.start, start);
    if (ov > bestOv) { bestOv = ov; best = p; }
  }
  if (best) {
    return snapToPcs(
      [best.root, (best.root + (best.minor ? 3 : 4)) % 12, (best.root + 7) % 12], pitch);
  }
  const scale = keyScale(keyStr);
  if (scale) return snapToPcs([...scale], pitch);
  return pitch;
}

export function MidiEditor({
  laneName, patchName, notes, chords, keyStr, bpm, duration,
  playPos, playing, onApply, onClose, onSeek, onToggle,
  onAiCompose, composeBusy, composeError, composeResult,
}: {
  laneName: string;
  patchName: string | null;
  notes: ClipNote[];
  chords: MidiChord[];
  keyStr: string;
  bpm: number;
  duration: number;
  playPos: number;          // seconds (stem transport)
  playing: boolean;
  onApply: (notes: ClipNote[]) => void;
  onClose: () => void;
  onSeek: (sec: number) => void;
  onToggle: () => void;
  onAiCompose: (prompt: string, mode: 'all' | 'continue') => void;
  composeBusy: boolean;
  composeError: string | null;
  composeResult: { seq: number; mode: 'all' | 'continue'; notes: ClipNote[] } | null;
}) {
  const [clip, setClip] = useState<ClipNote[]>(notes);
  const [sel, setSel] = useState<number | null>(null);
  const [pps, setPps] = useState(48);            // pixels per second (zoom)
  const undoRef = useRef<ClipNote[][]>([]);
  const scrollRef = useRef<HTMLDivElement>(null);
  const applyTimer = useRef<number | null>(null);

  // Initial clip arrives async (laneClipGet round-trip).
  useEffect(() => { setClip(notes); undoRef.current = []; }, [notes]);

  const beat = 60 / Math.max(40, bpm || 120);
  const grid = beat / 4;                          // 1/16
  const harmony = useMemo(() => makeHarmonyFn(chords, keyStr), [chords, keyStr]);

  // Pitch range (padded, min two octaves).
  const [loP, hiP] = useMemo(() => {
    let lo = 127, hi = 0;
    for (const [, , p] of clip) { lo = Math.min(lo, p); hi = Math.max(hi, p); }
    if (lo > hi) { lo = 48; hi = 72; }
    lo = Math.max(0, lo - 3); hi = Math.min(127, hi + 3);
    while (hi - lo < 24) { if (lo > 0) lo--; if (hi < 127) hi++; }
    return [lo, hi];
  }, [clip.length === 0]);   // eslint-disable-line react-hooks/exhaustive-deps

  const rowH = 10, rulerH = 16, chordH = 18, topH = rulerH + chordH;
  const rows = hiP - loP + 1;
  const W = Math.max(600, Math.ceil(duration * pps));
  const svgH = chordH + rows * rowH;            // ruler lives outside the SVG
  const noteY = (pitch: number) => chordH + (hiP - pitch) * rowH;
  const pitchOf = (svgY: number) =>
    Math.max(0, Math.min(127, hiP - Math.floor((svgY - chordH) / rowH)));

  const scheduleApply = (next: ClipNote[]) => {
    if (applyTimer.current) window.clearTimeout(applyTimer.current);
    applyTimer.current = window.setTimeout(() => onApply(next), 250);
  };
  const pushUndo = () => {
    undoRef.current.push(clip.map(n => [...n] as ClipNote));
    if (undoRef.current.length > 64) undoRef.current.shift();
  };
  const commit = (next: ClipNote[]) => { setClip(next); scheduleApply(next); };

  // Keyboard: space = transport, ⌫ = delete, ⌘Z = undo, esc = close.
  // Captured on window so the app's global transport keys never see them
  // while the editor is open.
  useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      // Never hijack typing in text fields (e.g. the AI compose prompt).
      const t = e.target;
      if (t instanceof HTMLInputElement || t instanceof HTMLTextAreaElement) return;
      if (e.code === 'Space') {
        e.preventDefault(); e.stopPropagation();
        onToggle();
      } else if ((e.key === 'Backspace' || e.key === 'Delete') && sel !== null) {
        e.preventDefault(); e.stopPropagation();
        pushUndo();
        commit(clip.filter((_, i) => i !== sel));
        setSel(null);
      } else if (e.key === 'z' && (e.metaKey || e.ctrlKey)) {
        e.preventDefault(); e.stopPropagation();
        const prev = undoRef.current.pop();
        if (prev) commit(prev);
      } else if (e.key === 'Escape') {
        e.stopPropagation();
        onClose();
      }
    };
    window.addEventListener('keydown', onKey, true);
    return () => window.removeEventListener('keydown', onKey, true);
  });

  // Follow the playhead while playing (suspended while the user drags it).
  const seekDragRef = useRef(false);
  useEffect(() => {
    if (!playing || seekDragRef.current || !scrollRef.current) return;
    const x = playPos * pps;
    const el = scrollRef.current;
    if (x < el.scrollLeft + 40 || x > el.scrollLeft + el.clientWidth - 80) {
      el.scrollLeft = Math.max(0, x - el.clientWidth * 0.3);
    }
  }, [playPos, playing, pps]);

  // Shared seek-drag: ruler or the playhead handle — drag anywhere to scrub.
  const startSeekDrag = (clientX0: number) => {
    const el = scrollRef.current;
    if (!el) return;
    seekDragRef.current = true;
    const seekAt = (cx: number) => {
      const r = el.getBoundingClientRect();
      onSeek(Math.max(0, Math.min(duration, (cx - r.left + el.scrollLeft) / pps)));
    };
    seekAt(clientX0);
    const move = (ev: PointerEvent) => { ev.preventDefault(); seekAt(ev.clientX); };
    const up = () => {
      seekDragRef.current = false;
      window.removeEventListener('pointermove', move);
      window.removeEventListener('pointerup', up);
      window.removeEventListener('pointercancel', up);
    };
    window.addEventListener('pointermove', move);
    window.addEventListener('pointerup', up);
    window.addEventListener('pointercancel', up);
  };

  // ── Note dragging ──
  const dragRef = useRef<{
    idx: number; mode: 'move' | 'resize';
    x0: number; y0: number; orig: ClipNote;
  } | null>(null);

  const onNoteDown = (e: React.PointerEvent, idx: number) => {
    e.stopPropagation();
    (e.currentTarget as Element).setPointerCapture(e.pointerId);
    const rect = (e.currentTarget as Element).getBoundingClientRect();
    const nearRight = e.clientX > rect.right - 6;
    pushUndo();
    dragRef.current = {
      idx, mode: nearRight ? 'resize' : 'move',
      x0: e.clientX, y0: e.clientY, orig: [...clip[idx]] as ClipNote,
    };
    setSel(idx);
  };
  const onNoteMove = (e: React.PointerEvent) => {
    const d = dragRef.current;
    if (!d) return;
    const dx = (e.clientX - d.x0) / pps;
    const next = clip.map(n => [...n] as ClipNote);
    const n = next[d.idx];
    if (d.mode === 'move') {
      const dp = Math.round((d.y0 - e.clientY) / rowH);
      n[0] = Math.max(0, Math.round((d.orig[0] + dx) / grid) * grid);
      n[2] = Math.max(0, Math.min(127, d.orig[2] + dp));
    } else {
      n[1] = Math.max(grid * 0.5, Math.round((d.orig[1] + dx) / grid) * grid);
    }
    setClip(next);
  };
  const onNoteUp = () => {
    if (!dragRef.current) return;
    dragRef.current = null;
    scheduleApply(clip);
  };

  const onGridDouble = (e: React.MouseEvent<SVGSVGElement>) => {
    const svg = e.currentTarget.getBoundingClientRect();
    const x = e.clientX - svg.left, y = e.clientY - svg.top;
    if (y < chordH) return;
    // Double-click on an existing note deletes it (handled there); empty adds.
    pushUndo();
    const start = Math.max(0, Math.round(x / pps / grid) * grid);
    commit([...clip, [start, beat / 2, pitchOf(y), 0.8]]);
  };

  // ── One-click cleanup ("AI 优化") ──
  const [optReport, setOptReport] = useState<string | null>(null);
  const optimize = () => {
    pushUndo();
    let dropped = 0, snapped = 0, quantized = 0;
    let next: ClipNote[] = clip
      .filter(([, dur]) => { const ok = dur >= 0.06; if (!ok) dropped++; return ok; })
      .map(([s, d, p, v]) => {
        const qs = Math.round(s / grid) * grid;
        const qd = Math.max(grid * 0.5, Math.round(d / grid) * grid);
        if (Math.abs(qs - s) > 1e-4 || Math.abs(qd - d) > 1e-4) quantized++;
        let np = p;
        if (harmony(qs, qd, p) === 'off') {
          np = snapToChord(chords, keyStr, qs, qd, p);
          if (np !== p) snapped++;
        }
        return [qs, qd, np, v] as ClipNote;
      })
      .sort((a, b) => a[0] - b[0] || a[2] - b[2]);
    // Merge same-pitch overlaps created by quantize/snap.
    const merged: ClipNote[] = [];
    for (const n of next) {
      const last = merged[merged.length - 1];
      if (last && last[2] === n[2] && n[0] < last[0] + last[1] + 1e-6) {
        last[1] = Math.max(last[1], n[0] + n[1] - last[0]);
        last[3] = Math.max(last[3], n[3]);
      } else {
        merged.push([...n] as ClipNote);
      }
    }
    const mergedCount = next.length - merged.length;
    commit(merged);
    setOptReport(
      `✓ 量化 ${quantized} · 吸附 ${snapped} · 删短音 ${dropped} · 合并 ${mergedCount}` +
      (chords.filter(c => !c.none).length === 0 ? '（无和弦表，按调内音吸附 — 建议先 ♪ Chords）' : ''));
    window.setTimeout(() => setOptReport(null), 4000);
  };

  // ── AI compose (✨ 写MIDI) ──
  const [aiOpen, setAiOpen] = useState(false);
  const [aiPrompt, setAiPrompt] = useState('');
  const composeFromRef = useRef(0);            // playhead at request time (sec)
  const composeSeqSeen = useRef(0);
  useEffect(() => {
    if (!composeResult || composeResult.seq === composeSeqSeen.current) return;
    composeSeqSeen.current = composeResult.seq;
    // Model output is in beats from song start → seconds.
    const fresh: ClipNote[] = [];
    for (const n of composeResult.notes) {
      if (!Array.isArray(n) || n.length < 3) continue;
      const start = Number(n[0]) * beat;
      const dur = Math.max(0.04, Number(n[1]) * beat);
      const pitch = Math.round(Number(n[2]));
      const vel = n.length > 3 ? Math.max(0.05, Math.min(1, Number(n[3]))) : 0.8;
      if (!Number.isFinite(start) || start < 0 || start > duration) continue;
      if (pitch < 0 || pitch > 127) continue;
      fresh.push([start, dur, pitch, vel]);
    }
    if (!fresh.length) return;
    pushUndo();
    if (composeResult.mode === 'continue') {
      const from = composeFromRef.current;
      commit([
        ...clip.filter(n => n[0] < from),
        ...fresh.filter(n => n[0] >= from - 1e-3),
      ]);
    } else {
      commit(fresh);
    }
    setOptReport(`✨ AI 写入 ${fresh.length} 个音符（⌘Z 可撤销）`);
    window.setTimeout(() => setOptReport(null), 4000);
  });   // eslint-disable-line react-hooks/exhaustive-deps

  // Ruler seek (click + drag).
  const onRulerDown = (e: React.PointerEvent<HTMLDivElement>) => {
    e.preventDefault();
    startSeekDrag(e.clientX);
  };

  const offCount = clip.filter(([s, d, p]) => harmony(s, d, p) === 'off').length;
  const mmss = (t: number) =>
    `${Math.floor(t / 60)}:${String(Math.floor(t % 60)).padStart(2, '0')}`;

  const FILL: Record<Harmony, string> = {
    chord: '#f8d35c', scale: 'rgba(248, 211, 92, 0.45)', off: '#ff5f78',
  };

  // Bars for the grid.
  const bars: number[] = [];
  for (let t = 0; t < duration; t += beat * 4) bars.push(t);

  return (
    <div className="midiedit-overlay" onPointerDown={(e) => {
      if (e.target === e.currentTarget) onClose();
    }}>
      <div className="midiedit">
        <div className="midiedit-head">
          <span className="midiedit-title">
            ♪ {laneName.toUpperCase()}
            {patchName && <small> · {patchName}</small>}
            <small> · {keyStr || '?'} · {Math.round(bpm)} bpm</small>
          </span>
          {composeBusy ? (
            <span className="midiedit-legend is-busy">
              ✨ AI 作曲中…（通常 10~30 秒，请勿关闭；失败会在此提示）
            </span>
          ) : composeError ? (
            <span className="midiedit-legend is-error">
              ✕ AI 作曲失败：{composeError} — 可重试
            </span>
          ) : optReport ? (
            <span className="midiedit-legend is-report">{optReport}</span>
          ) : (
            <span className="midiedit-legend">
              <i style={{ background: FILL.chord }} /> 和弦音
              <i style={{ background: FILL.scale }} /> 调内
              <i style={{ background: FILL.off }} /> 不协调{offCount > 0 ? ` ×${offCount}` : ''}
            </span>
          )}
          <div className="midiedit-actions">
            <button onClick={onToggle} title="播放 / 暂停（空格）">
              {playing ? '⏸' : '▶'}
            </button>
            <span className="midiedit-time">{mmss(playPos)}</span>
            <button onClick={() => setPps(p => Math.max(12, p / 1.4))} title="缩小">−</button>
            <button onClick={() => setPps(p => Math.min(240, p * 1.4))} title="放大">＋</button>
            <button
              onClick={() => { const prev = undoRef.current.pop(); if (prev) commit(prev); }}
              title="撤销（⌘Z）"
            >
              ↩
            </button>
            <button
              className="is-ai"
              onClick={() => setAiOpen(o => !o)}
              disabled={composeBusy}
              title="AI 写 MIDI：描述想要的乐句（全新生成 / 从播放头续写）"
            >
              {composeBusy ? '✨ …' : '✨ 写MIDI'}
            </button>
            <button className="is-ai" onClick={optimize}
              title="一键优化：量化到 1/16、删除超短音、不协调音吸附到最近和弦音">
              ✨ 优化
            </button>
            <button onClick={onClose} title="关闭（Esc）">✕</button>
          </div>
        </div>

        <div className="midiedit-body">
          {/* Piano keys */}
          <div className="midiedit-keys" style={{ paddingTop: topH }}>
            {Array.from({ length: rows }, (_, r) => {
              const p = hiP - r;
              const pc = p % 12;
              return (
                <div
                  key={p}
                  className={`midiedit-key ${BLACK.has(pc) ? 'is-black' : ''}`}
                  style={{ height: rowH }}
                >
                  {pc === 0 ? `C${Math.floor(p / 12) - 1}` : ''}
                </div>
              );
            })}
          </div>

          {/* Scrollable roll */}
          <div className="midiedit-scroll" ref={scrollRef}>
            <div className="midiedit-ruler" style={{ width: W, height: rulerH }}
                 onPointerDown={onRulerDown}>
              {bars.map((t, i) => (
                <span key={i} style={{ left: t * pps }}>{i + 1}</span>
              ))}
            </div>
            <svg
              width={W} height={svgH}
              className="midiedit-svg"
              onDoubleClick={onGridDouble}
              onPointerMove={onNoteMove}
              onPointerUp={onNoteUp}
            >
              {/* Chord reference band */}
              {chords.map((c, i) => !c.none && (
                <g key={`c${i}`}>
                  <rect x={c.start * pps} y={0} width={(c.end - c.start) * pps}
                        height={chordH - 2} rx={3} className="midiedit-chordseg" />
                  <text x={c.start * pps + 4} y={chordH - 7}>{c.label}</text>
                </g>
              ))}
              {/* Row shading (black keys) + beat grid */}
              {Array.from({ length: rows }, (_, r) => {
                const p = hiP - r;
                return BLACK.has(p % 12) ? (
                  <rect key={`r${p}`} x={0} y={chordH + r * rowH} width={W} height={rowH}
                        fill="rgba(255,255,255,0.03)" />
                ) : null;
              })}
              {bars.map((t, i) => (
                <g key={`b${i}`}>
                  <line x1={t * pps} y1={chordH} x2={t * pps} y2={svgH}
                        stroke="rgba(255,255,255,0.14)" />
                  {[1, 2, 3].map(k => (
                    <line key={k} x1={(t + k * beat) * pps} y1={chordH}
                          x2={(t + k * beat) * pps} y2={svgH}
                          stroke="rgba(255,255,255,0.05)" />
                  ))}
                </g>
              ))}
              {/* Notes */}
              {clip.map(([s, d, p, v], i) => {
                const h = harmony(s, d, p);
                return (
                  <rect
                    key={i}
                    x={s * pps} y={noteY(p) + 0.5}
                    width={Math.max(2, d * pps)} height={rowH - 1.5}
                    rx={2}
                    fill={FILL[h]}
                    fillOpacity={0.35 + v * 0.6}
                    stroke={sel === i ? '#fff' : (h === 'off' ? FILL.off : 'transparent')}
                    strokeWidth={sel === i ? 1.5 : 1}
                    className="midiedit-note"
                    onPointerDown={(e) => onNoteDown(e, i)}
                    onDoubleClick={(e) => {
                      e.stopPropagation();
                      pushUndo();
                      commit(clip.filter((_, k) => k !== i));
                      setSel(null);
                    }}
                  />
                );
              })}
              {/* Playhead: draggable scrubber (wide invisible grab strip) */}
              <g
                className="midiedit-ph"
                onPointerDown={(e) => {
                  e.stopPropagation();
                  e.preventDefault();
                  startSeekDrag(e.clientX);
                }}
                onDoubleClick={(e) => e.stopPropagation()}
              >
                <rect x={playPos * pps - 6} y={0} width={12} height={svgH}
                      fill="transparent" />
                <line x1={playPos * pps} y1={0} x2={playPos * pps} y2={svgH}
                      stroke="#ff5f78" strokeWidth={1.5} />
                <polygon
                  points={`${playPos * pps - 5},0 ${playPos * pps + 5},0 ${playPos * pps},8`}
                  fill="#ff5f78"
                />
              </g>
            </svg>
          </div>
        </div>

        {aiOpen && (
          <div className="midiedit-ai">
            <textarea
              autoFocus
              value={aiPrompt}
              onChange={(e) => setAiPrompt(e.target.value)}
              rows={2}
              placeholder="描述要写的乐句，例：前奏写一段小提琴旋律，抒情、长音为主&#10;（模型会拿到调性/BPM/段落表/和弦表）"
              onKeyDown={(e) => e.stopPropagation()}
            />
            <div className="midiedit-ai-actions">
              <button onClick={() => setAiOpen(false)}>取消</button>
              <button
                className="is-go"
                disabled={composeBusy}
                onClick={() => {
                  composeFromRef.current = playPos;
                  onAiCompose(aiPrompt.trim(), 'continue');
                  setAiOpen(false);
                }}
                title={`保留 ${mmss(playPos)} 之前的音符，从播放头往后写`}
              >
                ✨ 从播放头续写
              </button>
              <button
                className="is-go"
                disabled={composeBusy}
                onClick={() => {
                  composeFromRef.current = 0;
                  onAiCompose(aiPrompt.trim(), 'all');
                  setAiOpen(false);
                }}
                title="整段重写（现有音符被替换，⌘Z 可撤销）"
              >
                ✨ 全新生成
              </button>
            </div>
          </div>
        )}
        <div className="midiedit-hint">
          拖动=移动 · 拖右缘=改时值 · 双击空白=加音 · 双击音符/⌫=删除 ·
          空格=播放/暂停 · 拖红色播放头或标尺=进度 · ⌘Z=撤销 · 修改实时生效
        </div>
      </div>
    </div>
  );
}
