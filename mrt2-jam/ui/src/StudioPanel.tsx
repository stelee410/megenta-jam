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
 * StudioPanel — the PGM tab: upload a song, auto-analyze (BPM/key/sections),
 * separate it into stems, cover each stem with the local model one by one,
 * A/B each cover against the original, and package everything as a live PGM.
 */

import React, { useState, useRef } from 'react';
import { MidiEditor } from './MidiEditor';
import type { ClipNote } from './MidiEditor';

export interface StudioSection {
  start: number;
  end: number;
  label: string;
  energy: number;
}

export interface StudioStem {
  name: string;
  wave: number[];
  source: string;   // '' | 'neural' | 'hpss' | 'imported'
  notes: number;                       // transcription note count (0 = none)
  ribbon: Array<[number, number, number]>;   // [startSec, endSec, pitch]
  playSrc: 'audio' | 'midi';           // playback source for this lane
  patch: { name: string; origin: string } | null;  // lane synth patch
  engine: 'syn' | 'sf2';               // instrument engine
  sfProgram: number;                   // GM program (SF2 engine)
  fxReverb: number;                    // lane insert FX 0..1
  fxEcho: number;
  alignMs?: number;                    // playback alignment offset (ms; imported tracks)
  dry?: number;                        // dry-blend amount 0..0.5 (fold mix back in)
}

export interface StudioState {
  loaded: boolean;
  name: string;
  duration: number;
  bpm: number;
  key: string;
  memo: string;               // free-text notes panel (per song)
  sections: StudioSection[];
  songWave: number[];
  stems: StudioStem[];
  stage: string;
  pct: number;
  busy: boolean;
  playMode: 'none' | 'song' | 'stems';
  playing: boolean;
  chords: Array<{ start: number; end: number; label: string; none?: boolean }>;
  mixer: { mute: boolean; solo: boolean; gain: number }[];
  playhead: { pos: number; len: number };
  sepPipeline: 'auto' | 'hpss' | 'demucs' | 'rf' | 'rf2';   // separation pipeline
  rfPresent: boolean;         // BS-RoFormer model on disk
  cue: number;                // cue (playback start) seconds (-1 = none)
  clickAnchor: number;        // click beat-grid anchor seconds (-1 = follow cue)
  timeSig: 3 | 4;             // metronome time signature
  countIn: 0 | 4 | 8;         // 预备拍 beats before playback
  click: boolean;             // metronome during playback
  clickGain: number;          // metronome volume 0..2 (1 = default)
  outChannels: number;        // device output channel count
  multichannel: boolean;      // opt-in multichannel output routing
  routeMain: number;          // bitmask of channels carrying the main mix
  routeClick: number;         // bitmask of channels carrying the click
  sepEngine: string;          // 'htdemucs' | 'hpss' | ''
  sepModel: { present: boolean; sources: number; downloading: boolean; pct: number; mb: number };
  error: string | null;
  notice: string | null;
}

export const STUDIO_INIT: StudioState = {
  loaded: false, name: '', duration: 0, bpm: 0, key: '', memo: '',
  sections: [], songWave: [],
  stems: [
    { name: 'drums', wave: [], source: '', notes: 0, ribbon: [], playSrc: 'audio', patch: null, engine: 'syn', sfProgram: 0, fxReverb: 0, fxEcho: 0 },
    { name: 'bass', wave: [], source: '', notes: 0, ribbon: [], playSrc: 'audio', patch: null, engine: 'syn', sfProgram: 0, fxReverb: 0, fxEcho: 0 },
    { name: 'other', wave: [], source: '', notes: 0, ribbon: [], playSrc: 'audio', patch: null, engine: 'syn', sfProgram: 0, fxReverb: 0, fxEcho: 0 },
    { name: 'vocals', wave: [], source: '', notes: 0, ribbon: [], playSrc: 'audio', patch: null, engine: 'syn', sfProgram: 0, fxReverb: 0, fxEcho: 0 },
    { name: 'guitar', wave: [], source: '', notes: 0, ribbon: [], playSrc: 'audio', patch: null, engine: 'syn', sfProgram: 0, fxReverb: 0, fxEcho: 0 },
    { name: 'piano', wave: [], source: '', notes: 0, ribbon: [], playSrc: 'audio', patch: null, engine: 'syn', sfProgram: 0, fxReverb: 0, fxEcho: 0 },
    { name: 'aux1', wave: [], source: '', notes: 0, ribbon: [], playSrc: 'audio', patch: null, engine: 'syn', sfProgram: 40, fxReverb: 0, fxEcho: 0 },
    { name: 'aux2', wave: [], source: '', notes: 0, ribbon: [], playSrc: 'audio', patch: null, engine: 'syn', sfProgram: 40, fxReverb: 0, fxEcho: 0 },
  ],
  stage: '', pct: 0, busy: false, playMode: 'none', playing: false,
  chords: [],
  mixer: Array.from({ length: 8 }, () => ({ mute: false, solo: false, gain: 1 })),
  playhead: { pos: 0, len: 0 },
  sepPipeline: 'auto', rfPresent: false, cue: -1, clickAnchor: -1, timeSig: 4,
  countIn: 0, click: false, clickGain: 1,
  outChannels: 2, multichannel: false, routeMain: 0x3, routeClick: 0x3,
  sepEngine: '', sepModel: { present: false, sources: 0, downloading: false, pct: 0, mb: 0 },
  error: null, notice: null,
};

/** GM program names, grouped by family (index = program 0..127). */
export const GM_FAMILIES: Array<[string, string[]]> = [
  ['钢琴', ['Grand Piano', 'Bright Piano', 'Electric Grand', 'Honky-Tonk', 'E.Piano 1', 'E.Piano 2', 'Harpsichord', 'Clavinet']],
  ['色彩打击', ['Celesta', 'Glockenspiel', 'Music Box', 'Vibraphone', 'Marimba', 'Xylophone', 'Tubular Bells', 'Dulcimer']],
  ['风琴', ['Drawbar Organ', 'Percussive Organ', 'Rock Organ', 'Church Organ', 'Reed Organ', 'Accordion', 'Harmonica', 'Tango Accordion']],
  ['吉他', ['Nylon Guitar', 'Steel Guitar', 'Jazz Guitar', 'Clean Guitar', 'Muted Guitar', 'Overdrive Guitar', 'Distortion Guitar', 'Guitar Harmonics']],
  ['贝斯', ['Acoustic Bass', 'Finger Bass', 'Pick Bass', 'Fretless Bass', 'Slap Bass 1', 'Slap Bass 2', 'Synth Bass 1', 'Synth Bass 2']],
  ['弦乐', ['Violin', 'Viola', 'Cello', 'Contrabass', 'Tremolo Strings', 'Pizzicato', 'Harp', 'Timpani']],
  ['合奏', ['String Ens 1', 'String Ens 2', 'Synth Strings 1', 'Synth Strings 2', 'Choir Aahs', 'Voice Oohs', 'Synth Voice', 'Orchestra Hit']],
  ['铜管', ['Trumpet', 'Trombone', 'Tuba', 'Muted Trumpet', 'French Horn', 'Brass Section', 'Synth Brass 1', 'Synth Brass 2']],
  ['簧管', ['Soprano Sax', 'Alto Sax', 'Tenor Sax', 'Baritone Sax', 'Oboe', 'English Horn', 'Bassoon', 'Clarinet']],
  ['笛', ['Piccolo', 'Flute', 'Recorder', 'Pan Flute', 'Blown Bottle', 'Shakuhachi', 'Whistle', 'Ocarina']],
  ['合成主音', ['Lead Square', 'Lead Saw', 'Lead Calliope', 'Lead Chiff', 'Lead Charang', 'Lead Voice', 'Lead Fifths', 'Lead Bass+Lead']],
  ['合成铺底', ['Pad New Age', 'Pad Warm', 'Pad Polysynth', 'Pad Choir', 'Pad Bowed', 'Pad Metallic', 'Pad Halo', 'Pad Sweep']],
  ['合成效果', ['FX Rain', 'FX Soundtrack', 'FX Crystal', 'FX Atmosphere', 'FX Brightness', 'FX Goblins', 'FX Echoes', 'FX Sci-Fi']],
  ['民族', ['Sitar', 'Banjo', 'Shamisen', 'Koto', 'Kalimba', 'Bagpipe', 'Fiddle', 'Shanai']],
  ['打击', ['Tinkle Bell', 'Agogo', 'Steel Drums', 'Woodblock', 'Taiko', 'Melodic Tom', 'Synth Drum', 'Reverse Cymbal']],
  ['音效', ['Fret Noise', 'Breath Noise', 'Seashore', 'Bird Tweet', 'Telephone', 'Helicopter', 'Applause', 'Gunshot']],
];

const SECTION_COLORS: Record<string, string> = {
  break: 'rgba(111, 179, 255, 0.45)',
  verse: 'rgba(73, 215, 166, 0.45)',
  build: 'rgba(248, 211, 92, 0.5)',
  drop: 'rgba(255, 95, 120, 0.5)',
};

function Wave({ data, color }: { data: number[]; color: string }) {
  if (!data.length) return <div className="pgm-wave is-empty" />;
  const W = 480, H = 44;
  const pts = data.map((v, i) =>
    `${(i / (data.length - 1)) * W},${H / 2 - v * (H / 2 - 2)}`).join(' ');
  const ptsLo = data.map((v, i) =>
    `${(i / (data.length - 1)) * W},${H / 2 + v * (H / 2 - 2)}`).join(' ');
  return (
    <svg className="pgm-wave" viewBox={`0 0 ${W} ${H}`} preserveAspectRatio="none">
      <polyline points={pts} fill="none" stroke={color} strokeWidth="1" />
      <polyline points={ptsLo} fill="none" stroke={color} strokeWidth="1" opacity="0.7" />
      <line x1="0" y1={H / 2} x2={W} y2={H / 2} stroke={color} strokeWidth="0.5" opacity="0.4" />
    </svg>
  );
}

/** Mini piano-roll: transcribed notes as pitch-positioned blocks. */
function NoteRibbon({ ribbon, duration, main }: {
  ribbon: Array<[number, number, number]>;
  duration: number;
  main?: boolean;   // render as the lane's primary visual (waveform slot)
}) {
  if (!ribbon.length || duration <= 0) return null;
  const lo = Math.min(...ribbon.map(r => r[2]));
  const hi = Math.max(...ribbon.map(r => r[2]));
  const span = Math.max(1, hi - lo);
  return (
    <svg className={`pgm-ribbon ${main ? 'is-main' : ''}`}
         viewBox="0 0 480 26" preserveAspectRatio="none">
      {ribbon.map(([t0, t1, p], i) => (
        <rect
          key={i}
          x={(t0 / duration) * 480}
          width={Math.max(0.6, ((t1 - t0) / duration) * 480)}
          y={24 - ((p - lo) / span) * 22}
          height={2}
          fill="#f8d35c"
          opacity={0.85}
        />
      ))}
    </svg>
  );
}

export function StudioPanel({
  studio,
  onLoadSong,
  onLoadPgm,
  onSeparate,
  onSepPipeline,
  onSongToggle,
  onTransport,
  onCountIn,
  onClick,
  onCue,
  onBpm,
  onKey,
  onMemo,
  onClickGain,
  onTimeSig,
  onRoute,
  onMultichannel,
  onMix,
  onSeek,
  onImportStem,
  onTranscribe,
  onExtractStem,
  onStemAlign,
  onStemDry,
  onDetectChords,
  onLaneSource,
  patchOptions,
  onLanePatch,
  onLaneAiPatch,
  aiLaneBusy,
  onLaneEngine,
  onLaneSfProgram,
  onLaneFx,
  onLaneClear,
  clip,
  onClipOpen,
  onClipApply,
  onClipClose,
  onClipAiCompose,
  composeBusy,
  composeError,
  composeResult,
  onClipRegen,
  onClipAiOptimize,
  onClipAiRange,
  onPackage,
  onSepDownload,
  onSepPick,
}: {
  studio: StudioState;
  onLoadSong: () => void;
  onLoadPgm: () => void;
  onSeparate: () => void;
  onSepPipeline: (mode: 'auto' | 'hpss' | 'demucs' | 'rf' | 'rf2') => void;
  onSongToggle: (on: boolean) => void;
  onTransport: (action: 'play' | 'pause' | 'restart') => void;
  onCountIn: (beats: 0 | 4 | 8) => void;
  onClick: (on: boolean) => void;
  onClickGain: (value: number) => void;
  onCue: (action: 'auto' | 'set' | 'clear' | 'anchor' | 'anchorReset', sec?: number) => void;
  onBpm: (bpm: number) => void;
  onKey: (key: string) => void;
  onMemo: (text: string) => void;
  onTimeSig: (beats: 3 | 4) => void;
  onRoute: (patch: { main?: number; click?: number }) => void;
  onMultichannel: (on: boolean) => void;
  onMix: (idx: number, patch: { mute?: boolean; solo?: boolean; gain?: number }) => void;
  onSeek: (sec: number) => void;
  onImportStem: (idx: number) => void;
  onTranscribe: (idx: number) => void;
  onExtractStem: (idx: number) => void;
  onStemAlign: (idx: number, action: 'left' | 'right' | 'auto' | 'reset') => void;
  onStemDry: (idx: number, value: number) => void;
  onDetectChords: () => void;
  onLaneSource: (idx: number, src: 'audio' | 'midi') => void;
  patchOptions: { name: string; category: string }[];
  onLanePatch: (idx: number, name: string) => void;
  onLaneAiPatch: (idx: number, userText: string) => void;
  aiLaneBusy: number | null;
  onLaneEngine: (idx: number, engine: 'syn' | 'sf2') => void;
  onLaneSfProgram: (idx: number, program: number) => void;
  onLaneFx: (idx: number, patch: { reverb?: number; echo?: number }) => void;
  onLaneClear: (idx: number) => void;
  clip: { index: number; notes: ClipNote[] } | null;   // open piano-roll clip
  onClipOpen: (idx: number) => void;
  onClipApply: (idx: number, notes: ClipNote[]) => void;
  onClipClose: () => void;
  onClipAiCompose: (idx: number, prompt: string, mode: 'all' | 'continue') => void;
  composeBusy: boolean;
  composeError: string | null;
  composeResult: { seq: number; mode: 'all' | 'continue' | 'range'; notes: ClipNote[] } | null;
  onClipRegen: (idx: number) => void;
  onClipAiOptimize: (idx: number, notes: ClipNote[]) => void;
  onClipAiRange: (idx: number, notes: ClipNote[], startSec: number, endSec: number) => void;
  onPackage: () => void;
  onSepDownload: () => void;
  onSepPick: () => void;
}) {
  const s = studio;
  // ✨ AI patch prompt dialog: which lane is being asked, + the user's text.
  const [aiAsk, setAiAsk] = useState<number | null>(null);
  const [aiText, setAiText] = useState('');
  // Manual key edit (null = not editing). The key chip is just a record.
  const [keyDraft, setKeyDraft] = useState<string | null>(null);
  // Notes panel: a floating dialog the operator can park anywhere on screen.
  const [notesOpen, setNotesOpen] = useState(false);
  const [notesPos, setNotesPos] = useState<{ x: number; y: number }>(() => {
    try {
      const v = JSON.parse(localStorage.getItem('jamNotesPos') || 'null');
      if (v && typeof v.x === 'number' && typeof v.y === 'number') return v;
    } catch { /* ignore */ }
    return { x: 180, y: 130 };
  });
  const notesDrag = useRef<{ dx: number; dy: number } | null>(null);
  const startNotesDrag = (e: React.PointerEvent) => {
    (e.currentTarget as HTMLElement).setPointerCapture(e.pointerId);
    notesDrag.current = { dx: e.clientX - notesPos.x, dy: e.clientY - notesPos.y };
  };
  const moveNotesDrag = (e: React.PointerEvent) => {
    if (!notesDrag.current) return;
    const x = Math.max(0, Math.min(window.innerWidth - 220, e.clientX - notesDrag.current.dx));
    const y = Math.max(0, Math.min(window.innerHeight - 48, e.clientY - notesDrag.current.dy));
    setNotesPos({ x, y });
  };
  const endNotesDrag = () => {
    if (!notesDrag.current) return;
    notesDrag.current = null;
    setNotesPos(p => { try { localStorage.setItem('jamNotesPos', JSON.stringify(p)); } catch { /* ignore */ } return p; });
  };
  // Tap tempo: average the recent inter-tap intervals → BPM.
  const tapTimes = useRef<number[]>([]);
  const [tapHint, setTapHint] = useState(0);   // taps counted in the current burst
  const onTap = () => {
    const now = performance.now();
    const t = tapTimes.current;
    if (t.length && now - t[t.length - 1] > 2000) t.length = 0;   // gap → new burst
    t.push(now);
    if (t.length > 8) t.shift();
    if (t.length >= 2) {
      const intervals = t.slice(1).map((x, i) => x - t[i]);
      const avg = intervals.reduce((a, b) => a + b, 0) / intervals.length;
      const bpm = 60000 / avg;
      if (bpm >= 40 && bpm <= 300) onBpm(Math.round(bpm));
    }
    setTapHint(t.length);
  };
  const [routeOpen, setRouteOpen] = useState(false);

  const songOn = s.playMode === 'song';
  const stemsLoaded = s.stems.some(x => x.wave.length > 0 || x.notes > 0 || x.playSrc === 'midi');
  const transportOn = s.playMode === 'stems';
  const mmss = (t: number) =>
    `${Math.floor(t / 60)}:${String(Math.floor(t % 60)).padStart(2, '0')}`;
  // Playhead overlay (draggable: the wave handles seeking via pointer events).
  const phPct = s.playhead.len > 0 ? Math.min(1, s.playhead.pos / s.playhead.len) : 0;
  const playhead = (visible: boolean, showTime: boolean) =>
    visible && s.playhead.len > 0 ? (
      <>
        <span className="pgm-playhead" style={{ left: `${phPct * 100}%` }} />
        {showTime && <span className="pgm-playhead-time">{mmss(s.playhead.pos)}</span>}
      </>
    ) : null;
  // Click / drag anywhere on a wave to seek (when something is playing).
  const seekHandlers = {
    onPointerDown: (e: React.PointerEvent<HTMLDivElement>) => {
      e.preventDefault();
      const el = e.currentTarget;
      el.setPointerCapture(e.pointerId);
      const fr = (ev: { clientX: number }) => {
        const r = el.getBoundingClientRect();
        return Math.max(0, Math.min(1, (ev.clientX - r.left) / r.width));
      };
      onSeek(fr(e) * s.duration);
      const move = (ev: PointerEvent) => onSeek(fr(ev) * s.duration);
      const up = () => {
        el.removeEventListener('pointermove', move as any);
        el.removeEventListener('pointerup', up as any);
        el.removeEventListener('pointercancel', up as any);
      };
      el.addEventListener('pointermove', move as any);
      el.addEventListener('pointerup', up as any);
      el.addEventListener('pointercancel', up as any);
    },
  };

  return (
    <div className="pgm">
      {/* ── Header ── */}
      <div className="pgm-head">
        <div>
          <div className="pgm-title">PGM STUDIO</div>
          <div className="pgm-sub">song → stems → model covers → live program</div>
        </div>
        <div className="pgm-head-info">
          {s.loaded && (
            <>
              <span className="pgm-chip">{s.name}</span>
              <span className="pgm-bpmcal" title="手动校准 BPM（±1，或 ÷2 / ×2 修正倍速误判）">
                <button onClick={() => onBpm(Math.max(40, Math.round(s.bpm / 2)))} title="减半">÷2</button>
                <button onClick={() => onBpm(Math.max(40, Math.round(s.bpm) - 1))}>−</button>
                <input
                  type="number" min={40} max={300} value={Math.round(s.bpm)}
                  onChange={(e) => { const v = Number(e.target.value); if (v >= 40 && v <= 300) onBpm(v); }}
                  onKeyDown={(e) => e.stopPropagation()}
                />
                <small>bpm</small>
                <button onClick={() => onBpm(Math.min(300, Math.round(s.bpm) + 1))}>＋</button>
                <button onClick={() => onBpm(Math.min(300, Math.round(s.bpm * 2)))} title="加倍">×2</button>
                <button className="pgm-tap" onClick={onTap}
                  title="点击跟拍：连续按节奏点 2 次以上即可测出 BPM">
                  {tapHint >= 2 ? `TAP·${tapHint}` : 'TAP'}
                </button>
              </span>
              {keyDraft === null ? (
                <span
                  className="pgm-chip is-blue is-editable"
                  title="点击编辑调性（仅作记录）"
                  onClick={() => setKeyDraft(s.key)}
                >
                  {s.key || '＋ 调性'}
                </span>
              ) : (
                <input
                  className="pgm-chip is-blue pgm-keyedit"
                  autoFocus
                  value={keyDraft}
                  placeholder="e.g. C major"
                  onChange={(e) => setKeyDraft(e.target.value)}
                  onKeyDown={(e) => {
                    e.stopPropagation();
                    if (e.key === 'Enter') { onKey(keyDraft.trim()); setKeyDraft(null); }
                    else if (e.key === 'Escape') { setKeyDraft(null); }
                  }}
                  onBlur={() => { onKey(keyDraft.trim()); setKeyDraft(null); }}
                />
              )}
              <span className="pgm-chip">{mmss(s.duration)}</span>
              <button
                className={`pgm-chip pgm-notes-btn${s.memo ? ' has-notes' : ''}`}
                title="速记 / 演出备注"
                onClick={() => setNotesOpen(o => !o)}
              >
                📝 备注{s.memo ? ' ●' : ''}
              </button>
            </>
          )}
        </div>
        <div className="pgm-head-actions">
          {s.sepModel.downloading ? (
            <span className="pgm-chip is-blue">
              ⬇ {Math.round(s.sepModel.pct * 100)}% · {s.sepModel.mb.toFixed(1)}MB / 52MB
            </span>
          ) : s.sepModel.present ? (
            <>
              <span
                className="pgm-chip is-neural"
                title={`htdemucs neural separation — ${s.sepModel.sources} stems`}
              >
                ◆ neural ·{s.sepModel.sources}轨
              </span>
              {s.sepModel.sources === 4 && (
                <button
                  className="freak-soft"
                  onClick={onSepDownload}
                  title="Upgrade to the 6-stem model (drums/bass/other/vocals/guitar/piano, ~52 MB)"
                >
                  ⬆ 6轨 (52MB)
                </button>
              )}
            </>
          ) : (
            <button
              className="freak-soft"
              onClick={onSepDownload}
              onContextMenu={(e) => { e.preventDefault(); onSepPick(); }}
              title="Download the htdemucs 6-stem separation model (~52 MB) — right-click to pick a local ggml file"
            >
              ⬇ 分离模型 (52MB)
            </button>
          )}
          <button className="freak-soft" onClick={onLoadSong} disabled={s.busy}>
            {s.loaded ? 'Replace Song' : '⬆ Load Song'}
          </button>
          <button
            className="freak-soft"
            onClick={onLoadPgm}
            disabled={s.busy}
            title="导入已打包的 .pgm 文件夹（program.json + stems）"
          >
            ⬇ Load PGM
          </button>
          {s.loaded && (
            <select
              className="pgm-pipeline"
              value={s.sepPipeline}
              disabled={s.busy}
              onChange={(e) => onSepPipeline(e.target.value as any)}
              title={'分轨管线：\n自动 = 装了什么用什么（RF 模型在则启用 HQ）\n快速 = HPSS（秒级，3 轨）\nhtdemucs = 神经网络 6 轨\n+RF人声HQ = BS-RoFormer 先提人声再 htdemucs（最干净，约 1.5× 歌曲时长' + (s.rfPresent ? '' : '；首次选择自动下载 201MB') + '）'}
            >
              <option value="auto">管线: 自动</option>
              <option value="hpss">管线: 快速 HPSS</option>
              <option value="demucs">管线: htdemucs</option>
              <option value="rf">管线: +RF人声 HQ{s.rfPresent ? '' : ' ⬇'}</option>
              <option value="rf2">管线: RF 纯2轨{s.rfPresent ? '' : ' ⬇'}</option>
            </select>
          )}
          {s.loaded && (
            <button
              className="freak-soft is-lit"
              onClick={onSeparate}
              disabled={s.busy}
              title={s.sepModel.present
                ? 'Separate the loaded song into stems (htdemucs neural)'
                : 'Separate with fast HPSS — download the model for neural quality'}
            >
              ✂ Separate
            </button>
          )}
          {s.loaded && (
            <button
              className="freak-soft"
              onClick={onDetectChords}
              disabled={s.busy}
              title="识别和弦进行（无鼓分轨混音上的 chroma + HMM）"
            >
              ♪ Chords
            </button>
          )}
          <button
            className="freak-soft is-lit"
            onClick={onPackage}
            disabled={!s.loaded || s.busy}
            title="Save the show program as a .pgm.json"
          >
            ◈ Package PGM
          </button>
        </div>
      </div>

      {/* ── Notes: floating dialog the operator can drag/park anywhere ── */}
      {notesOpen && (
        <div className="pgm-notes-panel" style={{ left: notesPos.x, top: notesPos.y }}>
          <div
            className="pgm-notes-head"
            onPointerDown={startNotesDrag}
            onPointerMove={moveNotesDrag}
            onPointerUp={endNotesDrag}
            onPointerCancel={endNotesDrag}
            title="拖动标题栏可移动到任意位置"
          >
            <span>📝 备注 · NOTES{s.name ? ` — ${s.name}` : ''}</span>
            <button
              onPointerDown={(e) => e.stopPropagation()}
              onClick={() => setNotesOpen(false)}
              title="收起"
            >✕</button>
          </div>
          <textarea
            key={s.name}
            className="pgm-notes-area"
            placeholder="速记演出备注：起始段落、踏板、转调、设备路由、提醒事项…（自动随歌曲保存）"
            defaultValue={s.memo}
            ref={(el) => { if (el) { el.style.height = 'auto'; el.style.height = `${el.scrollHeight}px`; } }}
            onInput={(e) => {
              const el = e.currentTarget;
              el.style.height = 'auto';
              el.style.height = `${el.scrollHeight}px`;
            }}
            onKeyDown={(e) => e.stopPropagation()}
            onBlur={(e) => onMemo(e.target.value)}
          />
        </div>
      )}

      {/* ── Progress / errors ── */}
      {s.busy && (
        <div className="pgm-progress">
          <div className="pgm-progress-bar"><span style={{ width: `${Math.round(s.pct * 100)}%` }} /></div>
          <span className="pgm-progress-label">{s.stage}…</span>
        </div>
      )}
      {s.error && <div className="pgm-error">{s.error}</div>}
      {s.notice && <div className="pgm-notice">{s.notice}</div>}

      {/* ── Master transport ── */}
      {stemsLoaded && (
        <div className="pgm-transport">
          <button
            className="pgm-tp-btn is-main"
            onClick={() => onTransport(transportOn && s.playing ? 'pause' : 'play')}
            title={transportOn && s.playing ? '暂停' : '播放'}
          >
            {transportOn && s.playing ? '⏸' : '▶'}
          </button>
          <button
            className="pgm-tp-btn"
            onClick={() => onTransport('restart')}
            title="从头重新播放"
          >
            ⟲
          </button>
          <span className="pgm-tp-time">
            {mmss(transportOn ? s.playhead.pos : 0)}
            <small> / {mmss(transportOn ? s.playhead.len : s.duration)}</small>
          </span>
          <span className="pgm-srcswitch" title="预备拍：播放前先打 N 拍 click 再进歌">
            {([0, 4, 8] as const).map(b => (
              <button
                key={b}
                className={s.countIn === b ? 'is-on' : ''}
                onClick={() => onCountIn(b)}
              >
                {b === 0 ? '无预备' : `${b}拍`}
              </button>
            ))}
          </span>
          <button
            className={`pgm-mini ${s.click ? 'is-active is-midi' : ''}`}
            onClick={() => onClick(!s.click)}
            title="节拍器：播放中按歌曲 BPM 出 click（每小节首拍重音）"
          >
            ♩ click
          </button>
          <label className="pgm-clickvol" title={`click 音量 ${Math.round((s.clickGain ?? 1) * 100)}%`}>
            <input type="range" min={0} max={2} step={0.05}
              value={s.clickGain ?? 1}
              onChange={(e) => onClickGain(Number(e.target.value))} />
            <small>{Math.round((s.clickGain ?? 1) * 100)}%</small>
          </label>
          <span className="pgm-srcswitch" title="节拍器拍号">
            <button className={s.timeSig === 4 ? 'is-on' : ''} onClick={() => onTimeSig(4)}>4/4</button>
            <button className={s.timeSig === 3 ? 'is-on' : ''} onClick={() => onTimeSig(3)}>3/4</button>
          </span>
          <span className="pgm-cue" title="Cue：标记歌曲真正的起拍“1”，跳过不定长的前奏；click/预备拍以此对齐">
            <button
              className={`pgm-mini ${s.cue >= 0 ? 'is-active' : ''}`}
              onClick={() => onCue('auto')}
              title="自动 Cue：检测音乐起点并对齐到最近正拍"
            >
              ◎ Auto Cue
            </button>
            <button
              className="pgm-mini"
              onClick={() => onCue('set', s.playhead.len > 0 ? s.playhead.pos : 0)}
              title="手动 Cue：把当前播放头设为起拍点（吸附最近正拍）"
            >
              ⊕ 设 Cue
            </button>
            {s.cue >= 0 && (
              <>
                <span className="pgm-chip is-blue">Cue {mmss(s.cue)}</span>
                <button className="pgm-mini is-del" onClick={() => onCue('clear')}
                  title="清除 Cue">✕</button>
              </>
            )}
            <button
              className={`pgm-mini ${s.clickAnchor >= 0 ? 'is-active' : ''}`}
              onClick={() => onCue('anchor', s.playhead.len > 0 ? s.playhead.pos : 0)}
              title="click 计算点：在你听到的某个正拍上标注，click 的第一拍/重音由它倒推（默认与 Cue 同位置，可独立设置）"
            >
              ⊙ 计算点
            </button>
            {s.clickAnchor >= 0 && (
              <>
                <span className="pgm-chip">⊙ {mmss(s.clickAnchor)}</span>
                <button className="pgm-mini is-del" onClick={() => onCue('anchorReset')}
                  title="计算点恢复跟随 Cue">✕</button>
              </>
            )}
          </span>
          <span className="pgm-route">
            <button
              className={`pgm-mini ${(s.routeMain !== 0x3 || s.routeClick !== 0x3) ? 'is-active' : ''}`}
              onClick={() => setRouteOpen(o => !o)}
              title="输出路由：主混音和 click 可分别选择设备输出通道（如 click 单独走耳返）"
            >
              🔈 路由
            </button>
            {routeOpen && (
              <div className="pgm-route-pop">
                <label className="pgm-route-mc" title="多通道输出：开启后才能把 click 送到独立通道。仅适用于真正的 48kHz 多通道设备/聚合设备；普通声卡开启可能降速。">
                  <input
                    type="checkbox"
                    checked={s.multichannel}
                    onChange={(e) => onMultichannel(e.target.checked)}
                  />
                  多通道输出（48kHz 设备 / 聚合设备）
                </label>
                {!s.multichannel && (
                  <div className="pgm-route-hint">
                    默认立体声(到处都正确)。要把 click 送到独立通道:在「音频 MIDI 设置」
                    建一个 48kHz 聚合设备包住你的声卡并选为输出 → 勾上此项。
                  </div>
                )}
                {s.multichannel && (<>
                <div className="pgm-route-head">
                  <span>输出通道</span>
                  <span>主输出</span>
                  <span>CLICK</span>
                </div>
                {Array.from({ length: s.outChannels }, (_, c) => (
                  <div className="pgm-route-row" key={c}>
                    <span>Output {c + 1}</span>
                    <input
                      type="checkbox"
                      checked={(s.routeMain & (1 << c)) !== 0}
                      onChange={(e) => {
                        const next = e.target.checked
                          ? s.routeMain | (1 << c)
                          : s.routeMain & ~(1 << c);
                        if (next !== 0) onRoute({ main: next });
                      }}
                    />
                    <input
                      type="checkbox"
                      checked={(s.routeClick & (1 << c)) !== 0}
                      onChange={(e) => {
                        const next = e.target.checked
                          ? s.routeClick | (1 << c)
                          : s.routeClick & ~(1 << c);
                        if (next !== 0) onRoute({ click: next });
                      }}
                    />
                  </div>
                ))}
                <div className="pgm-route-hint">
                  主输出按勾选顺序交替 L/R（只选一个 = 单声道）；
                  click 为单声道，发往所有勾选通道。
                  {s.outChannels <= 2 ? ' 当前设备只有 2 个输出通道。' : ''}
                </div>
                </>)}
              </div>
            )}
          </span>
        </div>
      )}

      {!s.loaded && !s.busy && (
        <div className="pgm-empty">
          <p>Load a song to begin.</p>
          <p className="pgm-empty-sub">
            ⬆ Load Song 加载歌曲（自动分析 BPM / 调性 / 段落）→
            ✂ Separate 神经网络精确分轨（htdemucs 6轨：drums · bass · other ·
            vocals · guitar · piano）→ 试听各分轨 → ◈ Package PGM
          </p>
        </div>
      )}

      {s.loaded && (
        <>
          {/* ── Song lane + section strip ── */}
          <div className="pgm-song">
            <div className="pgm-lane-head">
              <span className="pgm-lane-name">SONG</span>
              <button
                className={`pgm-mini ${songOn ? 'is-active' : ''}`}
                onClick={() => onSongToggle(!songOn)}
              >
                {songOn ? '■ stop' : '▶ play'}
              </button>
            </div>
            <div className="pgm-song-stack" {...seekHandlers}>
              <Wave data={s.songWave} color="rgba(232, 232, 234, 0.75)" />
              {playhead(songOn, true)}
              {s.cue >= 0 && s.duration > 0 && (
                <span className="pgm-cue-marker" style={{ left: `${(s.cue / s.duration) * 100}%` }}
                      title={`Cue ${mmss(s.cue)}`} />
              )}
              {s.clickAnchor >= 0 && s.duration > 0 && (
                <span className="pgm-anchor-marker"
                      style={{ left: `${(s.clickAnchor / s.duration) * 100}%` }}
                      title={`click 计算点 ${mmss(s.clickAnchor)}`} />
              )}
              <div className="pgm-sections">
                {s.sections.map((sec, i) => (
                  <div
                    key={i}
                    className="pgm-section"
                    style={{
                      left: `${(sec.start / s.duration) * 100}%`,
                      width: `${((sec.end - sec.start) / s.duration) * 100}%`,
                      background: SECTION_COLORS[sec.label] ?? 'rgba(255,255,255,0.2)',
                    }}
                    title={`${sec.label} ${mmss(sec.start)}–${mmss(sec.end)}`}
                  >
                    {sec.label}
                  </div>
                ))}
              </div>
            </div>
          </div>

          {/* ── Chord chart lane ── */}
          {s.chords.length > 0 && (() => {
            const chordDur =
              s.duration > 0 ? s.duration : Math.max(1, s.chords[s.chords.length - 1].end);
            const named = s.chords.filter(c => !c.none);
            return (
              <div className="pgm-lane pgm-chordlane">
                <div className="pgm-lane-head">
                  <span className="pgm-lane-name">CHORDS</span>
                  <span className="pgm-chip is-neural">
                    {named.length} 段{s.key ? ` · ${s.key}` : ''}
                  </span>
                </div>
                <div className="pgm-chordbar">
                  {s.chords.map((c, i) => (
                    <div
                      key={i}
                      className={`pgm-chord ${c.none ? 'is-none' : ''}`}
                      style={{
                        left: `${(c.start / chordDur) * 100}%`,
                        width: `${((c.end - c.start) / chordDur) * 100}%`,
                      }}
                      title={`${c.label} ${mmss(c.start)}–${mmss(c.end)}`}
                    >
                      {c.label}
                    </div>
                  ))}
                </div>
              </div>
            );
          })()}

          {/* ── Stem lanes (always visible — import third-party stems anywhere) ── */}
          {s.stems.map((stem, i) => (
            <div
              className={`pgm-lane ${!stem.wave.length && !stem.notes && stem.playSrc !== 'midi' ? 'is-empty' : ''} ${stem.playSrc === 'midi' ? 'is-midi-src' : ''}`}
              key={stem.name}
            >
              <div className="pgm-lane-head">
                <span className="pgm-lane-name">{stem.name.toUpperCase()}</span>
                {stem.source === 'imported' && <span className="pgm-chip is-neural">ext</span>}
                {i > 0 && (stem.wave.length > 0 || stem.notes > 0 || s.chords.length > 0 || i >= 6) && (
                  <span className="pgm-srcswitch" title="该轨播放源：原始音频 / MIDI 合成器（同一推子控制音量）">
                    <button
                      className={stem.playSrc === 'audio' ? 'is-on' : ''}
                      onClick={() => onLaneSource(i, 'audio')}
                    >
                      WAV
                    </button>
                    <button
                      className={stem.playSrc === 'midi' ? 'is-on is-midi' : ''}
                      onClick={() => onLaneSource(i, 'midi')}
                      title={stem.notes > 0
                        ? 'MIDI 转录由该轨专属合成器演奏'
                        : '无转录时自动用和弦生成本轨风格乐句'}
                    >
                      MIDI
                    </button>
                  </span>
                )}
                {i > 0 && stem.playSrc === 'midi' && (
                  <span className="pgm-patchpick">
                    <span className="pgm-srcswitch" title="乐器引擎：MicroFreak 合成器 / GM 采样音色库">
                      <button
                        className={stem.engine === 'syn' ? 'is-on' : ''}
                        onClick={() => onLaneEngine(i, 'syn')}
                      >
                        SYN
                      </button>
                      <button
                        className={stem.engine === 'sf2' ? 'is-on is-midi' : ''}
                        onClick={() => onLaneEngine(i, 'sf2')}
                        title="GM 音色库（首次切换自动下载 ~31MB）"
                      >
                        SF2
                      </button>
                    </span>
                    {stem.engine === 'sf2' ? (
                      <select
                        value={stem.sfProgram}
                        onChange={(e) => onLaneSfProgram(i, Number(e.target.value))}
                        title="GM 音色（128 个乐器）"
                      >
                        {GM_FAMILIES.map(([fam, names], fi) => (
                          <optgroup key={fam} label={fam}>
                            {names.map((nm, ni) => (
                              <option key={nm} value={fi * 8 + ni}>{nm}</option>
                            ))}
                          </optgroup>
                        ))}
                      </select>
                    ) : (
                      <>
                        <select
                          value={stem.patch?.name ?? ''}
                          onChange={(e) => { if (e.target.value) onLanePatch(i, e.target.value); }}
                          title="该轨 MIDI 合成器音色（与 instrument 页同一套 patch）"
                        >
                          <option value="" disabled>
                            {stem.patch ? stem.patch.name : '默认音色'}
                          </option>
                          {[...new Set(patchOptions.map(p => p.category))].map(cat => (
                            <optgroup key={cat} label={cat}>
                              {patchOptions.filter(p => p.category === cat).map(p => (
                                <option key={p.name} value={p.name}>{p.name}</option>
                              ))}
                            </optgroup>
                          ))}
                        </select>
                        {stem.patch?.origin === 'ai' && (
                          <span className="pgm-chip is-ai" title="AI 设计的音色（随 PGM 打包）">ai</span>
                        )}
                        <button
                          className={`pgm-mini is-ai ${aiLaneBusy === i ? 'is-busy' : ''}`}
                          onClick={() => { setAiAsk(i); setAiText(''); }}
                          disabled={aiLaneBusy !== null}
                          title="让 AI 按本轨角色 + 歌曲调性/BPM 设计音色（可自己描述，patch 值会打包进 PGM）"
                        >
                          {aiLaneBusy === i ? '…' : '✨ AI'}
                        </button>
                      </>
                    )}
                    <span className="pgm-lanefx" title="本轨效果">
                      <label title={`混响 ${Math.round(stem.fxReverb * 100)}%`}>
                        R
                        <input
                          type="range" min={0} max={1} step={0.01}
                          value={stem.fxReverb}
                          onChange={(e) => onLaneFx(i, { reverb: Number(e.target.value) })}
                        />
                      </label>
                      <label title={`回声 ${Math.round(stem.fxEcho * 100)}%（附点八分，BPM 同步）`}>
                        E
                        <input
                          type="range" min={0} max={1} step={0.01}
                          value={stem.fxEcho}
                          onChange={(e) => onLaneFx(i, { echo: Number(e.target.value) })}
                        />
                      </label>
                    </span>
                  </span>
                )}
                <div className="pgm-lane-actions">
                  {(stem.wave.length > 0 || stem.notes > 0 || stem.playSrc === 'midi') && (
                    <>
                      <button
                        className={`pgm-ms ${s.mixer[i].mute ? 'is-mute' : ''}`}
                        onClick={() => onMix(i, { mute: !s.mixer[i].mute })}
                        title={`静音 / 播放（⌘${i + 1}）`}
                      >
                        M
                      </button>
                      <button
                        className={`pgm-ms ${s.mixer[i].solo ? 'is-solo' : ''}`}
                        onClick={() => onMix(i, { solo: !s.mixer[i].solo })}
                        title="Solo"
                      >
                        S
                      </button>
                      <input
                        className="pgm-fader"
                        type="range"
                        min={0}
                        max={1.2}
                        step={0.01}
                        value={s.mixer[i].gain}
                        onChange={(e) => onMix(i, { gain: Number(e.target.value) })}
                        title={`音量 ${Math.round(s.mixer[i].gain * 100)}%`}
                      />
                    </>
                  )}
                  {stem.wave.length > 0 && (
                    <button
                      className="pgm-mini is-midi"
                      onClick={() => onTranscribe(i)}
                      disabled={s.busy}
                      title="音频→MIDI 转录（Basic Pitch / ONNX，CoreML 加速）"
                    >
                      ♪ MIDI
                    </button>
                  )}
                  {stem.notes > 0 && (
                    <span className="pgm-chip is-midi">{stem.notes}♪</span>
                  )}
                  {i > 0 && (stem.notes > 0 || stem.playSrc === 'midi' || i >= 6) && (
                    <button
                      className="pgm-mini is-midi"
                      onClick={() => onClipOpen(i)}
                      disabled={s.busy}
                      title={i >= 6 && !stem.notes
                        ? '打开钢琴卷写 MIDI（手写或 ✨ AI 生成）'
                        : '打开钢琴卷 MIDI 编辑器（也可双击轨道）'}
                    >
                      ✎
                    </button>
                  )}
                  {(i === 0 || i === 1 || i === 2 || i === 4 || i === 5) && (
                    <button
                      className="pgm-mini is-neural"
                      onClick={() => onExtractStem(i)}
                      disabled={s.busy}
                      title={`${stem.name} HQ 重分离：用 BS-Roformer-SW 模型单独重做这条轨（对 htdemucs 不满意时用；首次约下载 336MB，约 1× 歌曲时长）`}
                    >
                      ♫ HQ
                    </button>
                  )}
                  <button
                    className="pgm-mini"
                    onClick={() => onImportStem(i)}
                    disabled={s.busy}
                    title="用第三方分轨文件替换/导入这条轨（自动对齐长度）"
                  >
                    ⬆ {stem.wave.length ? 'replace' : 'import'}
                  </button>
                  {stem.source === 'imported' && (
                    <span className="pgm-align" title="对齐导入轨：左右微调 10ms / 按音频自动对齐 / 复位">
                      <button className="pgm-mini" onClick={() => onStemAlign(i, 'left')}
                        disabled={s.busy} title="左移 10ms（提前）">◀</button>
                      <button className="pgm-mini" onClick={() => onStemAlign(i, 'right')}
                        disabled={s.busy} title="右移 10ms（延后）">▶</button>
                      <button className="pgm-mini is-neural" onClick={() => onStemAlign(i, 'auto')}
                        disabled={s.busy} title="自动对齐（按音频互相关分析）">⊙ 自动</button>
                      <button className="pgm-mini" onClick={() => onStemAlign(i, 'reset')}
                        disabled={s.busy} title="复位到 0">↺</button>
                      <small className="pgm-align-ms">
                        {(stem.alignMs ?? 0) > 0 ? '+' : ''}{stem.alignMs ?? 0}ms
                      </small>
                    </span>
                  )}
                  {stem.wave.length > 0 && stem.playSrc !== 'midi' && (
                    <label className="pgm-dry" title="干混：把一点原混折回该轨，填平分离硬门限的空隙、盖住 musical-noise 伪影（代价是少量串扰）。0 = 纯分离">
                      干
                      <input type="range" min={0} max={0.3} step={0.01}
                        value={stem.dry ?? 0}
                        onChange={(e) => onStemDry(i, Number(e.target.value))} />
                      <small>{Math.round((stem.dry ?? 0) * 100)}%</small>
                    </label>
                  )}
                  {i >= 6 && (
                    <button
                      className="pgm-mini is-del"
                      onClick={() => onLaneClear(i)}
                      disabled={s.busy}
                      title="清空这条 AUX 轨（音频/MIDI/音色/FX 全部移除）"
                    >
                      ✕
                    </button>
                  )}
                </div>
              </div>
              <div
                className="pgm-wave-wrap"
                {...seekHandlers}
                onDoubleClick={() => {
                  if (i > 0 && (stem.notes > 0 || stem.playSrc === 'midi' || i >= 6)) onClipOpen(i);
                }}
                title={stem.wave.length === 0 && stem.ribbon.length > 0
                  ? '双击打开钢琴卷 MIDI 编辑器' : undefined}
              >
                {stem.wave.length > 0 ? (
                  <Wave data={stem.wave} color="rgba(111, 179, 255, 0.8)" />
                ) : stem.ribbon.length > 0 ? (
                  <NoteRibbon ribbon={stem.ribbon} duration={s.duration} main />
                ) : (
                  <Wave data={stem.wave} color="rgba(111, 179, 255, 0.8)" />
                )}
                {playhead(transportOn && (stem.wave.length > 0 || stem.ribbon.length > 0),
                          i === 0)}
              </div>
              {stem.wave.length > 0 && stem.ribbon.length > 0 && (
                <div
                  onDoubleClick={() => { if (i > 0) onClipOpen(i); }}
                  title="双击打开钢琴卷 MIDI 编辑器"
                >
                  <NoteRibbon ribbon={stem.ribbon} duration={s.duration} />
                </div>
              )}
            </div>
          ))}
          {s.loaded && !s.busy && !s.stems.some(x => x.wave.length) && (
            <div className="pgm-empty-sub" style={{ textAlign: 'center' }}>
              ✂ Separate 自动分轨，或在各轨道 ⬆ import 导入第三方分轨
            </div>
          )}

          <p className="pgm-hint">
            顶部 ▶/⏸/⟲ 总控播放，各轨 M=静音 S=独奏 + 音量推子，
            点击/拖动波形跳转进度；WAV/MIDI 切换该轨播放源（MIDI 由该轨
            专属合成器演奏：bass=贝斯 / other=铺底 / vocals=lead /
            guitar=拨弦 / piano=键盘，无转录时按和弦自动生成乐句）；
            双击 MIDI 轨或 ✎ 打开钢琴卷精修（和弦参考 + 不协调音标红 +
            ✨ 一键优化）；♪ MIDI 在本机转录该轨（Basic Pitch），
            ⬆ replace 可换第三方分轨 → ◈ Package PGM 导出
            （program.json + song.wav + stems/*.wav + midi/*.mid）。
          </p>
        </>
      )}

      {/* ✨ AI patch prompt dialog */}
      {aiAsk !== null && (
        <div className="pgm-aiask-overlay" onPointerDown={(e) => {
          if (e.target === e.currentTarget) setAiAsk(null);
        }}>
          <div className="pgm-aiask">
            <div className="pgm-aiask-title">
              ✨ 为 {s.stems[aiAsk]?.name.toUpperCase()} 轨设计音色
            </div>
            <textarea
              autoFocus
              value={aiText}
              onChange={(e) => setAiText(e.target.value)}
              placeholder="描述想要的音色（可留空，自动按轨道角色 + 歌曲调性/BPM 设计）&#10;例：温暖的模拟贝斯，带一点滑音和轻微失真"
              rows={3}
              onKeyDown={(e) => {
                if (e.key === 'Enter' && (e.metaKey || e.ctrlKey)) {
                  onLaneAiPatch(aiAsk, aiText.trim());
                  setAiAsk(null);
                } else if (e.key === 'Escape') { setAiAsk(null); }
                e.stopPropagation();
              }}
            />
            <div className="pgm-aiask-actions">
              <button onClick={() => setAiAsk(null)}>取消</button>
              <button
                className="is-go"
                onClick={() => { onLaneAiPatch(aiAsk, aiText.trim()); setAiAsk(null); }}
              >
                ✨ 生成（⌘↵）
              </button>
            </div>
          </div>
        </div>
      )}

      {clip && (
        <MidiEditor
          laneName={s.stems[clip.index]?.name ?? 'lane'}
          patchName={s.stems[clip.index]?.patch?.name ?? null}
          notes={clip.notes}
          chords={s.chords}
          keyStr={s.key}
          bpm={s.bpm}
          duration={s.duration}
          playPos={transportOn ? s.playhead.pos : 0}
          playing={transportOn && s.playing}
          onApply={(notes) => onClipApply(clip.index, notes)}
          onClose={onClipClose}
          onSeek={onSeek}
          onToggle={() => onTransport(transportOn && s.playing ? 'pause' : 'play')}
          onAiCompose={(prompt, mode) => onClipAiCompose(clip.index, prompt, mode)}
          composeBusy={composeBusy}
          composeError={composeError}
          composeResult={composeResult}
          onRegenerate={() => onClipRegen(clip.index)}
          onAiOptimize={(notes) => onClipAiOptimize(clip.index, notes)}
          onAiRange={(notes, s0, e0) => onClipAiRange(clip.index, notes, s0, e0)}
        />
      )}
    </div>
  );
}
