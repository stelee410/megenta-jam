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

import { useState, useEffect, useRef, useCallback } from 'react';
import { PianoKeyboard } from './PianoKeyboard';
import { JamSlider } from './JamSlider';
import { JamSliderElastic } from './JamSliderElastic';
import { MagentaDropdown, MidiSelector, ModelSelector, ResourceOnboardingModal, PROMPT_SUGGESTIONS, INSTRUMENT_SUGGESTIONS, AudioMeter, TimingIndicator, SettingsPanel, GREY_900, ALL_COLORS, DEFAULT_TEMPERATURE, DEFAULT_TOPK, DEFAULT_CFG_NOTES, DEFAULT_CFG_MUSICCOCA, DEFAULT_CFG_DRUMS, DEFAULT_UNMASK_WIDTH, DEFAULT_BUFFER_SIZE, DEFAULT_VOLUME, PromptSurface, calculateWeights } from '@magenta-rt/common';
import type { PromptNode, ListenerNode } from '@magenta-rt/common';
import { Turtle, Rabbit } from 'lucide-react';
import { VisualLayer, VISUAL_PRESETS, FIRST_IMAGE_PRESET } from './VisualLayer';
import type { VisualData } from './VisualLayer';
import { CheatSheet } from './CheatSheet';
import { ChatPanel } from './ChatPanel';
import type { ChatMessage } from './ChatPanel';
import {
  InstrumentPanel, DEFAULT_SYNTH, OSC_TYPES,
  CYC_MODES, ARP_DIVS, MATRIX_SRC, MATRIX_DST,
} from './InstrumentPanel';
import type { SynthParams, SynthPreset } from './InstrumentPanel';
import { FACTORY_PRESETS } from './SynthPresets';
import { StudioPanel, STUDIO_INIT, GM_FAMILIES } from './StudioPanel';
import type { StudioState } from './StudioPanel';

/** Convert an AI patch (string enums, ±1 envFilter, {src,dest,amt} matrix)
 *  into numeric SynthParams + a 25-cell matrix. Shared by the Instrument tab
 *  and the per-stem MIDI lane patch designer. */
function aiPatchToNumeric(p: any): {
  params: Partial<SynthParams>; matrix: number[]; name: string;
} {
  const num = (v: any, lo = 0, hi = 1): number | undefined =>
    typeof v === 'number' && Number.isFinite(v) ? Math.max(lo, Math.min(hi, v)) : undefined;
  const idx = (v: any, list: readonly string[]): number | undefined => {
    if (typeof v !== 'string') return undefined;
    const lv = v.toLowerCase();
    const i = list.findIndex(s => s === lv || lv.startsWith(s) || s.startsWith(lv));
    return i >= 0 ? i : undefined;
  };
  const next: Partial<SynthParams> = {};
  const t = (k: keyof SynthParams, v: number | undefined) => { if (v !== undefined) next[k] = v; };
  t('oscType', idx(p.oscType, OSC_TYPES));
  t('wave', num(p.wave));
  t('timbre', num(p.timbre));
  t('shape', num(p.shape));
  t('glide', num(p.glide));
  t('attack', num(p.attack));
  t('decay', num(p.decay));
  t('sustain', num(p.sustain));
  t('release', num(p.release));
  t('filterType', idx(p.filterType, ['lp', 'bp', 'hp']));
  t('cutoff', num(p.cutoff));
  t('resonance', num(p.resonance));
  const ef = num(p.envFilter, -1, 1);
  if (ef !== undefined) next.envFilter = (ef + 1) / 2;
  t('lfoShape', idx(p.lfoShape, ['sine', 'tri', 'saw', 'square', 'sh']));
  t('lfoRate', num(p.lfoRate));
  if (typeof p.lfoSync === 'boolean') next.lfoSync = p.lfoSync ? 1 : 0;
  t('cycMode', idx(p.cycMode, CYC_MODES));
  t('cycRise', num(p.cycRise));
  t('cycFall', num(p.cycFall));
  t('cycHold', num(p.cycHold));
  t('cycRiseShape', num(p.cycRiseShape));
  t('cycFallShape', num(p.cycFallShape));
  t('cycAmount', num(p.cycAmount));
  t('arpMode', idx(p.arp, ['off', 'up', 'down', 'updown', 'random', 'order', 'pattern']));
  const ao = num(p.arpOct, 1, 4);
  if (ao !== undefined) next.arpOct = Math.round(ao);
  t('arpDiv', idx(p.arpDiv, ARP_DIVS));
  t('arpSwing', num(p.arpSwing));
  t('arpGate', num(p.arpGate));
  t('arpSpice', num(p.arpSpice));
  if (typeof p.mono === 'boolean') next.monoMode = p.mono ? 1 : 0;
  t('chorus', num(p.chorus));
  t('space', num(p.space));
  t('volume', num(p.volume));

  // Matrix routings: [{src, dest, amt}] → 25-cell grid.
  const cells = Array(25).fill(0);
  if (Array.isArray(p.matrix)) {
    for (const r of p.matrix.slice(0, 8)) {
      const s = idx(r?.src, MATRIX_SRC);
      const d = idx(r?.dest, MATRIX_DST);
      const a = num(r?.amt, -1, 1);
      if (s !== undefined && d !== undefined && a !== undefined) cells[s * 5 + d] = a;
    }
  }
  const name = typeof p.name === 'string' && p.name.trim() ? p.name.trim() : 'ai patch';
  return { params: next, matrix: cells, name };
}

/** Shared LLM context for AI compose / AI optimize: song key/tempo, sections
 *  (with energy), chord timeline, the target instrument, AND the rest of the
 *  arrangement (what the other lanes play) so a new/cleaned part fits the
 *  whole song's style instead of being written in a vacuum. */
function buildSongContext(
  st: StudioState, idx: number, beat: number, toBeat: (s: number) => string,
): string {
  const stem = st.stems[idx];
  const instrument = stem?.engine === 'sf2'
    ? GM_FAMILIES[Math.floor(stem.sfProgram / 8)]?.[1][stem.sfProgram % 8] ?? 'synth'
    : (stem?.patch?.name ?? `${stem?.name} synth patch`);
  const sections = st.sections.map(sec =>
    `${sec.label}(energy ${(sec.energy ?? 0).toFixed(2)}) beats ${toBeat(sec.start)}-${toBeat(sec.end)}`)
    .join(', ');
  const chordLine = st.chords.filter(c => !c.none).map(c =>
    `${toBeat(c.start)}:${c.label}`).join(' ');
  const bars = Math.max(1, st.duration / beat / 4);
  const reg = (p: number) => p < 48 ? 'low' : p < 67 ? 'mid' : 'high';
  const arrangement = st.stems
    .map((x, j) => ({ x, j }))
    .filter(({ x, j }) => j !== idx && x.notes > 0)
    .map(({ x }) => {
      const ps = x.ribbon.map(r => r[2]);
      const lo = ps.length ? Math.min(...ps) : 60;
      const hi = ps.length ? Math.max(...ps) : 60;
      const dens = (x.notes / bars).toFixed(1);
      return `${x.name}(${x.notes} notes, ~${dens}/bar, ${reg(lo)}–${reg(hi)})`;
    }).join('; ');
  return (
    `Song: "${st.name}", key ${st.key || 'unknown'}, ${st.bpm || 120} BPM, ` +
    `total ${toBeat(st.duration)} beats (4/4).\n` +
    `Sections: ${sections || 'unknown'}.\n` +
    `Chords (beat:label): ${chordLine || 'none detected'}.\n` +
    `Instrument: ${instrument} (lane "${stem?.name}").\n` +
    `Existing arrangement (match its style/density/register): ${arrangement || '(none yet)'}.\n`
  );
}
import {
  IconButton,
  MenuItem,
  CircularProgress,
  Tooltip,
} from '@mui/material';
import {
  ArrowBack,
  ArrowForward,
  ChevronLeft,
  ChevronRight,
  Tune as TuneIcon,
  Close,
  UploadFile,
  Refresh,
  PlayArrow,
  Pause,
  Mic,
  Stop,
} from '@mui/icons-material';

// ─── WebKit bridge ───────────────────────────────────────────────────────────

declare global {
  interface Window {
    updateState: (state: any) => void;
    webkit?: {
      messageHandlers?: {
        auHost?: { postMessage: (msg: any) => void };
      };
    };
  }
}

const post = (msg: any) => window.webkit?.messageHandlers?.auHost?.postMessage(msg);

// True while an IME (Chinese/Japanese/Korean) is composing — used to suppress
// Enter so confirming a candidate doesn't accidentally submit/commit.
const isComposingKey = (e: React.KeyboardEvent): boolean =>
  e.nativeEvent.isComposing || (e.nativeEvent as KeyboardEvent).keyCode === 229;

// Punch-in FX pads (EP-133 style): hold to engage, drag up/down to modulate.
// Ids match the native DSP switch in JamAppController.h.
const PUNCH_FX_LIST = [
  { id: 0, label: 'stut' },
  { id: 1, label: 'tape' },
  { id: 2, label: 'rev' },
  { id: 3, label: 'pit−' },
  { id: 4, label: 'pit+' },
  { id: 5, label: 'lpf' },
  { id: 6, label: 'hpf' },
  { id: 7, label: 'dly' },
  { id: 8, label: 'verb' },
  { id: 9, label: 'crsh' },
  { id: 10, label: 'gate' },
  { id: 11, label: 'sqsh' },
] as const;

// ─── Computer keyboard → MIDI (Ableton Live layout) ──────────────────────────
// Base row (lower octave): A S D F G H J = C D E F G A B, with W E T Y U as
// black keys (C# D# F# G# A#). Upper octave continues on K O L P ; (C C# D D# E).
// Z / X shift the base octave down/up.

const KEY_TO_SEMITONE: Record<string, number> = {
  a: 0, w: 1, s: 2, e: 3, d: 4, f: 5, t: 6, g: 7, y: 8, h: 9, u: 10, j: 11,
  k: 12, o: 13, l: 14, p: 15, ';': 16,
};
const KEYBOARD_MIDI_BASE_DEFAULT = 60; // C4 in MIDI (Middle C base)

// Inactivity timeout for SOLO mode playback auto-stop (in milliseconds)
const SOLO_INACTIVITY_TIMEOUT_MS = 30_000;




// CFG parameter bounds: range 0–5 (values are native, no remap needed).
const CFG_MIN = 0;
const CFG_MAX = 5;

// Column width constant for the 3-column layout
const CENTER_COL_WIDTH = '560px';

// Deterministically assign a color from ALL_COLORS to any prompt string
const getPromptColor = (prompt: string): string => {
  if (!prompt) return ALL_COLORS[0];
  const hash = prompt.charCodeAt(0);
  const index = Math.abs(hash) % ALL_COLORS.length;
  return ALL_COLORS[index];
};

type PerformanceKey =
  | 'filterX'
  | 'filterY'
  | 'drive'
  | 'delayMix'
  | 'delayFeedback'
  | 'reverbMix'
  | 'limiter'
  | 'stereoWidth'
  | 'tone'
  | 'outGain'
  | 'crush'
  | 'tremolo';

type PerformanceState = Record<PerformanceKey, number>;

type PromptMode = 'single' | 'mix' | 'solo';
type MixLayoutMode = 'standard' | 'circle' | 'surface';

type MixPrompt = {
  id: number;
  text: string;
  weight: number;
  color: string;
  enabled: boolean;
};

const DEFAULT_MIX_PROMPTS: MixPrompt[] = [
  { id: 1, text: 'techno', weight: 0.34, color: '#ff4f7b', enabled: true },
  { id: 2, text: 'glitch', weight: 0.08, color: '#6aa6ff', enabled: true },
  { id: 3, text: 'hard bop', weight: 0.12, color: '#f0aa26', enabled: true },
  { id: 4, text: 'piano arp', weight: 0.26, color: '#49d7a6', enabled: true },
  { id: 5, text: 'vinyl hiss', weight: 0.06, color: '#9f8cff', enabled: true },
  { id: 6, text: 'deep bass', weight: 0.14, color: '#f06a44', enabled: true },
];

const STANDARD_MIX_POSITIONS = [
  { x: 18, y: 24 },
  { x: 76, y: 28 },
  { x: 84, y: 58 },
  { x: 20, y: 66 },
  { x: 44, y: 18 },
  { x: 60, y: 76 },
];

const CIRCLE_MIX_POSITIONS = [
  { x: 50, y: 15 },
  { x: 78, y: 31 },
  { x: 78, y: 68 },
  { x: 50, y: 84 },
  { x: 22, y: 68 },
  { x: 22, y: 31 },
];

const SURFACE_MIX_POSITIONS = [
  { x: 22, y: 22 },
  { x: 72, y: 24 },
  { x: 82, y: 54 },
  { x: 26, y: 64 },
  { x: 47, y: 36 },
  { x: 60, y: 78 },
];

const clamp01 = (value: number) => Math.max(0, Math.min(1, value));

// ─── XY pad (Probability Space / Res-Filter) ────────────────────────────────

type XYPadMode = 'prob' | 'filter';

const PAD_TEMP_MAX = 3;
const PAD_TOPK_MAX = 1024;

// Piecewise-linear mappings chosen so the pad CENTER corresponds exactly to
// the default values (T=DEFAULT_TEMPERATURE, K=DEFAULT_TOPK) — unlatched
// gestures spring back to center = back to the default sound.
const tempFromPadX = (x: number) =>
  x <= 0.5
    ? (x / 0.5) * DEFAULT_TEMPERATURE
    : DEFAULT_TEMPERATURE + ((x - 0.5) / 0.5) * (PAD_TEMP_MAX - DEFAULT_TEMPERATURE);

const padXFromTemp = (t: number) =>
  clamp01(t <= DEFAULT_TEMPERATURE
    ? (t / DEFAULT_TEMPERATURE) * 0.5
    : 0.5 + ((t - DEFAULT_TEMPERATURE) / (PAD_TEMP_MAX - DEFAULT_TEMPERATURE)) * 0.5);

const topkFromPadY = (y: number) =>
  Math.round(y <= 0.5
    ? 1 + (y / 0.5) * (DEFAULT_TOPK - 1)
    : DEFAULT_TOPK + ((y - 0.5) / 0.5) * (PAD_TOPK_MAX - DEFAULT_TOPK));

const padYFromTopk = (k: number) =>
  clamp01(k <= DEFAULT_TOPK
    ? ((k - 1) / (DEFAULT_TOPK - 1)) * 0.5
    : 0.5 + ((k - DEFAULT_TOPK) / (PAD_TOPK_MAX - DEFAULT_TOPK)) * 0.5);

// DJ-style filter mapping: pad center = no effect. Left half sweeps the
// lowpass cutoff down (darker), center and right stay fully open; the top
// half adds resonance, center and below stay neutral.
const filterXFromPad = (x: number) => clamp01(2 * x);
const filterYFromPad = (y: number) => clamp01(2 * y - 1);

// ─── UI themes ───────────────────────────────────────────────────────────────
// Theme = a data-theme attribute on <html> driving CSS override blocks, plus
// per-theme piano key colors. The prompt canvas / XY pad stay dark "display
// screens" in every theme (hardware-synth metaphor).

const UI_THEMES = ['dark', 'light', 'famicom', 'yamaha', 'casio', 'cyberpunk', 'nana'] as const;
type UiTheme = (typeof UI_THEMES)[number];

const THEME_KEYS: Record<UiTheme, { white: string; black: string }> = {
  dark: { white: '#111214', black: '#030405' },
  light: { white: '#fafafa', black: '#1b1c1f' },
  famicom: { white: '#f5e9d6', black: '#8f1111' },
  yamaha: { white: '#f2efe7', black: '#141519' },
  casio: { white: '#fbfbfb', black: '#2a2b2e' },
  cyberpunk: { white: '#1c1133', black: '#06030d' },
  nana: { white: '#f3eef0', black: '#26070f' },
};

const loadSavedTheme = (): UiTheme => {
  try {
    const t = window.localStorage.getItem('jamTheme');
    if (t && (UI_THEMES as readonly string[]).includes(t)) return t as UiTheme;
  } catch { /* private mode etc. */ }
  return 'dark';
};

// ─── Lyria scale selection ───────────────────────────────────────────────────
// In Lyria mode the piano keyboard doubles as a key/scale selector: pressing
// any key locks musicGenerationConfig.scale to that pitch class's
// major / relative-minor pair (the Lyria Scale enum).

const LYRIA_SCALES = [
  'C_MAJOR_A_MINOR',
  'D_FLAT_MAJOR_B_FLAT_MINOR',
  'D_MAJOR_B_MINOR',
  'E_FLAT_MAJOR_C_MINOR',
  'E_MAJOR_D_FLAT_MINOR',
  'F_MAJOR_D_MINOR',
  'G_FLAT_MAJOR_E_FLAT_MINOR',
  'G_MAJOR_E_MINOR',
  'A_FLAT_MAJOR_F_MINOR',
  'A_MAJOR_G_FLAT_MINOR',
  'B_FLAT_MAJOR_G_MINOR',
  'B_MAJOR_A_FLAT_MINOR',
] as const;

const LYRIA_SCALE_LABELS = [
  'C major / A minor',
  'D♭ major / B♭ minor',
  'D major / B minor',
  'E♭ major / C minor',
  'E major / C♯ minor',
  'F major / D minor',
  'G♭ major / E♭ minor',
  'G major / E minor',
  'A♭ major / F minor',
  'A major / F♯ minor',
  'B♭ major / G minor',
  'B major / G♯ minor',
];

// ─── Surface mix layout (Collider-style prompt surface) ─────────────────────
// Free-floating prompt nodes + a draggable/throwable listener puck; weights
// follow inverse-square distance from the listener (see calculateWeights).

const MAX_SURFACE_PROMPTS = 6; // engine prompt slot limit
const SURFACE_DEFAULT_PHYSICS_SPEED = 0.5;
const SURFACE_SPEED_CURVE_EXP = 2; // most of the slider covers slow speeds
const surfaceSliderToSpeed = (t: number) =>
  Math.pow(t, SURFACE_SPEED_CURVE_EXP) * SURFACE_DEFAULT_PHYSICS_SPEED;

/** Spread `labels` evenly on a circle centered in a w×h canvas. */
function buildSurfaceLayout(labels: string[], w: number, h: number, pad = 56): { prompts: PromptNode[]; listener: ListenerNode } {
  const cx = w / 2;
  const cy = h / 2;
  const r = Math.max(40, Math.min(w, h) / 2 - pad);
  const prompts: PromptNode[] = labels.map((label, i) => {
    const angle = -Math.PI / 2 + (i * 2 * Math.PI) / labels.length;
    return {
      id: i,
      x: cx + r * Math.cos(angle),
      y: cy + r * Math.sin(angle),
      label,
      colorIndex: i,
    };
  });
  return { prompts, listener: { x: cx, y: cy } };
}

const getMixPositions = (layout: MixLayoutMode) => {
  if (layout === 'circle') return CIRCLE_MIX_POSITIONS;
  if (layout === 'surface') return SURFACE_MIX_POSITIONS;
  return STANDARD_MIX_POSITIONS;
};

// ─── App ─────────────────────────────────────────────────────────────────────

function App() {
  const [metrics, setMetrics] = useState({ frameMs: 0, bufferAvail: 0, bufferCap: 0, textEncoderStatus: 0, droppedFrames: 0 });
  const [audioLevels, setAudioLevels] = useState({ left: 0, right: 0 });
  const [modelName, setModelName] = useState("No model loaded");
  const [isPlaying, setIsPlaying] = useState(false);
  const [activeNotes, setActiveNotes] = useState<number[]>([]);
  const [noteActivityCounter, setNoteActivityCounter] = useState(0);
  const [localModels, setLocalModels] = useState<string[]>([]);
  const [remoteModels, setRemoteModels] = useState<string[]>([]);
  const [downloadProgress, setDownloadProgress] = useState<any>(null);
  const [downloadPath, setDownloadPath] = useState("~/Documents/Magenta/magenta-rt-v2/models");
  // Onboarding States
  const [resourcesMissing, setResourcesMissing] = useState(false);
  const [resourcesProgress, setResourcesProgress] = useState<any>(null);
  const [isFetchingModels, setIsFetchingModels] = useState(true);


  // Settings Drawer states
  const [isSettingsOpen, setIsSettingsOpen] = useState(false);
  const [paramsState, setParamsState] = useState({
    temperature: DEFAULT_TEMPERATURE,
    topk: DEFAULT_TOPK,
    cfgnotes: DEFAULT_CFG_NOTES,
    cfgnotesuser: DEFAULT_CFG_NOTES,
    cfgmusiccoca: DEFAULT_CFG_MUSICCOCA,
    cfgdrums: DEFAULT_CFG_DRUMS,
    unmaskwidth: DEFAULT_UNMASK_WIDTH,
    buffersize: DEFAULT_BUFFER_SIZE,
    volume: DEFAULT_VOLUME,
    drumless: false,
    onsetmode: false,
  });


  // Prompt state
  const [promptText, setPromptText] = useState('');
  const [promptTextB, setPromptTextB] = useState(() => PROMPT_SUGGESTIONS[1] ?? '');
  const [composerText, setComposerText] = useState('');
  const [deckFader, setDeckFader] = useState(0.5);
  const [promptMode, setPromptMode] = useState<PromptMode>('single');
  const [draftText, setDraftText] = useState('');
  const [isPromptEditing, setIsPromptEditing] = useState(false);
  const [mixLayout, setMixLayout] = useState<MixLayoutMode>('standard');
  const [focusedMixIndex, setFocusedMixIndex] = useState(0);
  const [mixPrompts, setMixPrompts] = useState<MixPrompt[]>(DEFAULT_MIX_PROMPTS);
  const [isPromptEdited, setIsPromptEdited] = useState(false);
  const [isAudioPrompt, setIsAudioPrompt] = useState(false);
  const lastSentText = useRef('');
  const promptSurfaceRef = useRef<HTMLDivElement | null>(null);
  const xyPadRef = useRef<HTMLDivElement | null>(null);
  const [performance, setPerformance] = useState<PerformanceState>({
    filterX: 1.0,
    filterY: 0.02,
    drive: 0.0,
    delayMix: 0.0,
    delayFeedback: 0.25,
    reverbMix: 0.0,
    limiter: 0.35,
    stereoWidth: 0.5,
    tone: 0.5,
    outGain: 0.5,
    crush: 0.0,
    tremolo: 0.0,
  });

  // ─── Main tabs: JAM (mix) · INSTRUMENT (synth) · PGM (show studio) ────────
  const [mainTab, setMainTab] = useState<'jam' | 'instrument' | 'pgm'>('jam');
  const [instrumentFollowJam, setInstrumentFollowJam] = useState(false);
  // Calibration gate: shown when the output device/channels change. Plays a
  // 120 BPM reference click; performance is held until the operator confirms.
  const [calibration, setCalibration] = useState<{
    active: boolean; measuring: boolean;
    comp?: number; effectiveRate?: number; channels?: number;
  }>({ active: false, measuring: false });
  // 现场模式：开启后阻止系统休眠 / 屏幕锁屏（native IOPMAssertion）。
  const [liveMode, setLiveMode] = useState(false);
  // Tell native which tab is active so live MIDI only conditions the
  // generative engine on the jam tab (never starts an AI jam from pgm).
  useEffect(() => { post({ type: 'activeTab', tab: mainTab }); }, [mainTab]);
  // PGM live MIDI-input instrument source.
  const [liveSource, setLiveSource] = useState(0);       // 0 synth · 1 SF2
  const [liveSfProgram, setLiveSfProgram] = useState(0); // GM program
  const [liveGain, setLiveGain] = useState(0.9);
  const [liveReverb, setLiveReverb] = useState(0);
  const [liveEcho, setLiveEcho] = useState(0);
  const mainTabRef = useRef(mainTab);
  mainTabRef.current = mainTab;
  // Gate native note routing: instrument tab → notes play the synth.
  useEffect(() => {
    post({ type: 'instrumentActive', value: mainTab === 'instrument' });
  }, [mainTab]);

  // ─── PGM studio: song → stems → model covers → packaged show program ──────
  const [studio, setStudio] = useState<StudioState>(STUDIO_INIT);
  const studioRef = useRef(studio);
  studioRef.current = studio;
  const studioSongToggle = useCallback((on: boolean) => {
    setStudio(st => ({ ...st, playMode: on ? 'song' : 'none' }));
    post({ type: 'studioPreview', index: -1, source: 'song', on });
  }, []);
  const studioTransport = useCallback((action: 'play' | 'pause' | 'restart') => {
    post({ type: 'studioTransport', action });
  }, []);
  const studioMix = useCallback((idx: number, patch: { mute?: boolean; solo?: boolean; gain?: number }) => {
    setStudio(st => ({
      ...st,
      mixer: st.mixer.map((m, i) => (i === idx ? { ...m, ...patch } : m)),
    }));
    post({ type: 'studioMix', index: idx, ...patch });
  }, []);
  const studioSeek = useCallback((sec: number) => {
    post({ type: 'studioSeek', sec });
  }, []);

  // Performance synth (MicroFreak-style) parameters — UI is the source of truth.
  const [synthParams, setSynthParams] = useState<SynthParams>(DEFAULT_SYNTH);
  const setSynthParam = useCallback((key: keyof SynthParams, value: number) => {
    setSynthParams(s => ({ ...s, [key]: value }));
    post({ type: 'synthParam', key, value });
  }, []);

  // Mod matrix: 25 bipolar amounts [src*5+dest].
  const [synthMatrix, setSynthMatrix] = useState<number[]>(() => Array(25).fill(0));
  const setMatrixCell = useCallback((index: number, value: number) => {
    setSynthMatrix(m => { const next = [...m]; next[index] = value; return next; });
    post({ type: 'synthMatrix', index, value });
  }, []);
  /** Replace the whole matrix (preset load / AI patch). */
  const applyMatrix = (cells: number[]) => {
    setSynthMatrix(cells);
    cells.forEach((value, index) => post({ type: 'synthMatrix', index, value }));
  };
  /** Push a full param set to the engine and the UI. */
  const applySynthParams = (params: SynthParams) => {
    setSynthParams(params);
    Object.entries(params).forEach(([key, value]) => post({ type: 'synthParam', key, value }));
  };

  // Presets (persisted via native NSUserDefaults).
  const [patchName, setPatchName] = useState('init');
  const [synthPresets, setSynthPresets] = useState<SynthPreset[]>([]);
  const saveSynthPreset = useCallback(() => {
    const name = patchName.trim() || 'untitled';
    setSynthPresets(prev => {
      const next = [...prev.filter(p => p.name !== name),
                    { name, params: synthParams, matrix: synthMatrix }];
      post({ type: 'saveSynthPresets', value: next });
      return next;
    });
    setPatchName(name);
  }, [patchName, synthParams, synthMatrix]);
  const loadSynthPreset = useCallback((name: string) => {
    const p = synthPresets.find(x => x.name === name)
           ?? FACTORY_PRESETS.find(x => x.name === name);
    if (!p) return;
    applySynthParams({ ...DEFAULT_SYNTH, ...p.params });
    applyMatrix(Array.isArray(p.matrix) && p.matrix.length === 25 ? p.matrix : Array(25).fill(0));
    setPatchName(p.name);
  }, [synthPresets]);
  const deleteSynthPreset = useCallback((name: string) => {
    setSynthPresets(prev => {
      const next = prev.filter(p => p.name !== name);
      post({ type: 'saveSynthPresets', value: next });
      return next;
    });
  }, []);

  // AI patch designer state
  const [aiPatchBusy, setAiPatchBusy] = useState(false);
  const [aiPatchError, setAiPatchError] = useState<string | null>(null);
  // PGM lane targeted by an in-flight AI patch request (null = instrument tab)
  const [aiLaneBusy, setAiLaneBusy] = useState<number | null>(null);
  const aiLaneBusyRef = useRef<number | null>(null);
  aiLaneBusyRef.current = aiLaneBusy;
  // Open piano-roll clip (MIDI editor); notes arrive via the studioClip push.
  const [studioClip, setStudioClip] =
    useState<{ index: number; notes: [number, number, number, number][] } | null>(null);
  const studioClipRef = useRef(studioClip);
  studioClipRef.current = studioClip;
  // AI MIDI composition (piano-roll ✨ 写MIDI)
  const [composeBusy, setComposeBusy] = useState(false);
  const [composeResult, setComposeResult] = useState<{
    seq: number; mode: 'all' | 'continue' | 'range';
    notes: [number, number, number, number][];
  } | null>(null);
  const composeModeRef = useRef<'all' | 'continue' | 'range'>('all');
  const composeSeqRef = useRef(0);
  // Lane whose clip regeneration is pending (refetch the open editor's clip
  // when its transcription lands; editor-originated edits must NOT refetch).
  const clipRegenPendingRef = useRef<number | null>(null);
  const [composeError, setComposeError] = useState<string | null>(null);
  const requestAiPatch = useCallback((desc: string) => {
    setAiPatchBusy(true);
    setAiPatchError(null);
    post({ type: 'aiPatch', value: desc });
  }, []);

  /** Apply an AI-designed patch: map enum strings → indices, clamp floats,
   *  update the UI state and push everything to the synth engine. */
  const applyAiPatch = useCallback((p: any) => {
    const { params: next, matrix: cells, name } = aiPatchToNumeric(p);
    setSynthParams(s => {
      const merged = { ...s, ...next };
      Object.entries(next).forEach(([k, v]) => post({ type: 'synthParam', key: k, value: v }));
      return merged;
    });
    applyMatrix(cells);
    setPatchName(name);
  }, []);
  const applyAiPatchRef = useRef(applyAiPatch);
  applyAiPatchRef.current = applyAiPatch;

  // Punch-in FX pads: pointer-down engages, vertical drag rides the amount,
  // release disengages. Each pad remembers its last amount.
  const [punchActive, setPunchActive] = useState<number | null>(null);
  const [punchAmt, setPunchAmt] = useState(0.6);
  const punchMemRef = useRef<Record<number, number>>({});
  const punchDragRef = useRef({ y: 0, amt: 0.6 });
  const punchDown = (id: number, e: React.PointerEvent<HTMLDivElement>) => {
    e.preventDefault();
    e.currentTarget.setPointerCapture(e.pointerId);
    const amt = punchMemRef.current[id] ?? 0.6;
    punchDragRef.current = { y: e.clientY, amt };
    setPunchActive(id);
    setPunchAmt(amt);
    post({ type: 'punchFx', id, value: amt });
  };
  const punchMove = (id: number, e: React.PointerEvent<HTMLDivElement>) => {
    if (punchActive !== id || e.buttons !== 1) return;
    const delta = (punchDragRef.current.y - e.clientY) / 140; // up = stronger
    const v = clamp01(punchDragRef.current.amt + delta);
    setPunchAmt(v);
    punchMemRef.current[id] = v;
    post({ type: 'punchFx', id, value: v });
  };
  const punchUp = () => {
    if (punchActive === null) return;
    setPunchActive(null);
    post({ type: 'punchFx', id: -1 });
  };

  // XY pad: 'prob' drives temperature/topK, 'filter' drives cutoff/resonance
  const [padMode, setPadMode] = useState<XYPadMode>('prob');
  // Right panel view: the XY pad, or the Lyria GENERATE controls (cloud only).
  const [rightView, setRightView] = useState<'xy' | 'gen'>('xy');
  const [padLatch, setPadLatch] = useState(true);
  const [isPadDragging, setIsPadDragging] = useState(false);
  const [filterPadPos, setFilterPadPos] = useState({ x: 0.5, y: 0.5 });

  // Color state
  const [activeColor, setActiveColor] = useState(() => ALL_COLORS[Math.floor(Math.random() * ALL_COLORS.length)]);

  // Solo / Accompany state
  const [isSoloMode, setIsSoloMode] = useState(false);
  const lastSentSoloMode = useRef(false);

  // ─── Prompt cheat sheet ───────────────────────────────────────────────────
  const [isCheatOpen, setIsCheatOpen] = useState(false);
  const copyPromptText = useCallback((text: string) => {
    post({ type: 'copyText', value: text });               // native NSPasteboard
    navigator.clipboard?.writeText(text).catch(() => {});  // best-effort web fallback
  }, []);

  // AI prompt chat: free-form idea → engine-tuned prompt (agentllm / c-music-express).
  const [isChatOpen, setIsChatOpen] = useState(false);
  const [aiHistory, setAiHistory] = useState<ChatMessage[]>([]);
  const [aiLoading, setAiLoading] = useState(false);
  const generateAiPrompt = useCallback((idea: string) => {
    const t = idea.trim();
    if (!t || aiLoading) return;
    // Send the recent conversation so follow-ups ("make it darker") have context.
    // The native side appends this new idea itself; cap to limit tokens.
    const ctx = aiHistory.slice(-8).map(m => ({ role: m.role, text: m.text }));
    setAiHistory(h => [...h, { role: 'user', text: t }]);
    setAiLoading(true);
    post({ type: 'aiPrompt', value: t, history: ctx });
  }, [aiLoading, aiHistory]);
  const clearChat = useCallback(() => setAiHistory([]), []);

  // ─── Visual layer (audio-reactive shader) ─────────────────────────────────
  const [visualMode, setVisualMode] = useState<'off' | 'bg' | 'full'>('off');
  const [visualPreset, setVisualPreset] = useState(0);
  const [visualImage, setVisualImage] = useState<string | null>(null);
  const visualDataRef = useRef<VisualData>({
    level: 0,
    kick: 0,
    wave: new Float32Array(96),
  });

  // ─── UI theme ─────────────────────────────────────────────────────────────
  const [uiTheme, setUiTheme] = useState<UiTheme>(loadSavedTheme);
  useEffect(() => {
    document.documentElement.dataset.theme = uiTheme;
    try { window.localStorage.setItem('jamTheme', uiTheme); } catch { /* noop */ }
  }, [uiTheme]);
  const cycleTheme = () => {
    setUiTheme(t => UI_THEMES[(UI_THEMES.indexOf(t) + 1) % UI_THEMES.length]);
  };

  // ─── Engine mode: local MLX model vs Lyria RealTime cloud ────────────────
  // The native side hard-cuts the Lyria websocket on pause/stop/switch/quit,
  // so no session is left open (and billing) while idle.
  const [engineMode, setEngineMode] = useState<'local' | 'lyria'>('local');
  const [lyriaStatus, setLyriaStatus] = useState('idle');
  // The GEN view only exists in cloud mode; fall back to the XY pad otherwise.
  useEffect(() => {
    if (engineMode !== 'lyria') setRightView('xy');
  }, [engineMode]);
  // Per-channel indicator state for the dual cloud streams: 'off'|'warming'|'playing'.
  const [lyriaChannels, setLyriaChannels] = useState<string[]>(['off', 'off']);

  // Lyria live-steering params (cloud mode). Knob values are 0..1 and mapped to
  // the API ranges when sent. Mute toggles arrange the stems on the fly.
  const [lyriaParams, setLyriaParams] = useState({
    density: 0.5, brightness: 0.5, temperature: 0.4, guidance: 0.5,
  });
  const [muteBass, setMuteBass] = useState(false);
  const [muteDrums, setMuteDrums] = useState(false);
  const setLyriaParam = (key: 'density' | 'brightness' | 'temperature' | 'guidance', knob: number) => {
    const v = Math.max(0, Math.min(1, knob));
    setLyriaParams(p => ({ ...p, [key]: v }));
    const mapped = key === 'temperature' ? v * 2.0 : key === 'guidance' ? v * 6.0 : v;
    post({ type: 'lyriaConfig', [key]: mapped });
  };
  const toggleLyriaMute = (which: 'bass' | 'drums') => {
    if (which === 'bass') {
      setMuteBass(v => { const nv = !v; post({ type: 'lyriaConfig', muteBass: nv }); return nv; });
    } else {
      setMuteDrums(v => { const nv = !v; post({ type: 'lyriaConfig', muteDrums: nv }); return nv; });
    }
  };
  const engineModeRef = useRef<'local' | 'lyria'>('local');
  engineModeRef.current = engineMode;

  const switchEngine = (mode: 'local' | 'lyria') => {
    if (mode === engineMode) return;
    setEngineMode(mode);
    post({ type: 'setEngineMode', value: mode }); // native stops playback first
  };

  // Scale lock (Lyria mode): index into LYRIA_SCALES, or null = unset.
  const [lyriaScaleIdx, setLyriaScaleIdx] = useState<number | null>(null);

  /** In Lyria mode a key press selects the scale of its pitch class. */
  const selectLyriaScaleFromNote = useCallback((note: number) => {
    const idx = ((note % 12) + 12) % 12;
    setLyriaScaleIdx(idx);
    post({ type: 'lyriaConfig', scale: LYRIA_SCALES[idx] });
  }, []);
  const selectLyriaScaleRef = useRef(selectLyriaScaleFromNote);
  selectLyriaScaleRef.current = selectLyriaScaleFromNote;

  // ─── BPM lock ─────────────────────────────────────────────────────────────
  // The model has no tempo conditioning input, so "locking" BPM is done by
  // (a) injecting a metronome MIDI pulse each beat (note conditioning is a
  // hard, frame-accurate signal the model entrains to) and (b) appending
  // "<bpm> bpm" to every prompt sent to the engine as a soft style hint.
  const [bpmLock, setBpmLock] = useState(false);
  const [bpmValue, setBpmValue] = useState(120);
  // Free-typing text buffer for the BPM box; parsed/applied on blur or Enter.
  const [bpmText, setBpmText] = useState('120');
  const bpmRef = useRef({ lock: false, value: 120 });
  bpmRef.current = { lock: bpmLock, value: bpmValue };

  // Keep the audio-thread tremolo LFO synced to the displayed BPM.
  useEffect(() => { post({ type: 'fxTempo', value: bpmValue }); }, [bpmValue]);

  // One-click BPM detection from the playing audio (works for both engines).
  // The result feeds the single global BPM, which drives the instrument's
  // arp/LFO sync, the punch tremolo, and the jam page's BPM box alike.
  const [bpmDetecting, setBpmDetecting] = useState(false);
  const [bpmStatus, setBpmStatus] = useState<string | null>(null);
  const bpmStatusTimer = useRef<number | null>(null);
  const flashBpmStatus = (msg: string) => {
    setBpmStatus(msg);
    if (bpmStatusTimer.current) clearTimeout(bpmStatusTimer.current);
    bpmStatusTimer.current = window.setTimeout(() => setBpmStatus(null), 2600);
  };
  const detectBpm = useCallback(() => {
    setBpmDetecting(true);
    post({ type: 'detectBpm' });
  }, []);

  /** Parse the typed BPM and apply it (clamped); reset the box if invalid. */
  const commitBpmText = () => {
    const v = parseInt(bpmText.trim(), 10);
    if (Number.isNaN(v)) {
      setBpmText(String(bpmValue));
      return;
    }
    const clamped = Math.max(40, Math.min(220, v));
    setBpmValue(clamped);
    setBpmText(String(clamped));
  };

  /** Append the locked BPM to a prompt text. Reads refs only, so it stays
   *  correct inside stale closures (e.g. memoized senders). Lyria has native
   *  bpm support via musicGenerationConfig, so no suffix in cloud mode. */
  const withBpm = (text: string) => {
    const t = text.trim();
    if (!bpmRef.current.lock || !t || engineModeRef.current === 'lyria') return t;
    return `${t} ${Math.round(bpmRef.current.value)} bpm`;
  };

  // ─── User preset overrides ───────────────────────────────────────────────
  // Sparse overlay: only indices the user has explicitly saved get entries.
  // `null` means "use factory default" (reserved for future reset support).
  const [userPresetsSolo, setUserPresetsSolo] = useState<Record<number, string>>({});
  const [userPresetsJam, setUserPresetsJam] = useState<Record<number, string>>({});

  const getFactoryList = useCallback((solo: boolean): string[] => {
    return solo ? INSTRUMENT_SUGGESTIONS : PROMPT_SUGGESTIONS;
  }, []);

  const getUserOverrides = useCallback((solo: boolean): Record<number, string> => {
    return solo ? userPresetsSolo : userPresetsJam;
  }, [userPresetsSolo, userPresetsJam]);

  // ─── Prompt Rocker state ─────────────────────────────────────────────────
  const [rockerIndex, setRockerIndex] = useState(0);
  const rockerInitialized = useRef(false);



  // Persist rocker index to native whenever it changes (skip the initial 0)
  useEffect(() => {
    if (rockerInitialized.current) {
      post({ type: 'saveRockerIndex', value: rockerIndex });
    }
  }, [rockerIndex]);

  /** Returns the effective preset list: factory with user overrides applied. */
  const getActivePresetList = useCallback((solo: boolean) => {
    const factory = getFactoryList(solo);
    const overrides = getUserOverrides(solo);
    return factory.map((text, i) => (i in overrides ? overrides[i] : text));
  }, [getFactoryList, getUserOverrides]);

  const applyPresetAtIndex = useCallback((list: string[], index: number) => {
    const preset = list[index];
    if (preset) {
      if (isAudioPrompt) post({ type: 'clearAudioPrompt' });
      setIsAudioPrompt(false);
      setPromptText(preset);
      setActiveColor(getPromptColor(preset));
      sendPrompt(preset, true, isSoloMode);
      setIsPromptEdited(false);
    }
  }, [isAudioPrompt, isSoloMode]);

  /** Navigate to the next/previous preset sequentially. */
  const navigatePreset = useCallback((direction: 1 | -1) => {
    const list = getActivePresetList(isSoloMode);
    if (list.length === 0) return;

    let nextIndex = rockerIndex + direction;
    if (nextIndex < 0) {
      nextIndex = list.length - 1;
    } else if (nextIndex >= list.length) {
      nextIndex = 0;
    }

    applyPresetAtIndex(list, nextIndex);
    setRockerIndex(nextIndex);
  }, [isSoloMode, rockerIndex, getActivePresetList, applyPresetAtIndex]);

  const handleRockerLeft = useCallback(() => navigatePreset(-1), [navigatePreset]);
  const handleRockerRight = useCallback(() => navigatePreset(1), [navigatePreset]);


  /** Persist the full user-overrides map to native side. */
  const persistUserPresets = useCallback((solo: Record<number, string>, jam: Record<number, string>) => {
    post({ type: 'saveUserPresets', solo, jam });
  }, []);

  /** Save the current prompt text as a user override for the active preset slot. */
  const handleSavePreset = useCallback(() => {
    const text = promptText.trim();
    if (!text) return;
    const setter = isSoloMode ? setUserPresetsSolo : setUserPresetsJam;
    setter(prev => {
      const next = { ...prev, [rockerIndex]: text };
      // Persist both maps — grab the latest of the "other" map from current state
      if (isSoloMode) {
        persistUserPresets(next, userPresetsJam);
      } else {
        persistUserPresets(userPresetsSolo, next);
      }
      setIsPromptEdited(false);
      return next;
    });
  }, [promptText, isSoloMode, rockerIndex, userPresetsSolo, userPresetsJam, persistUserPresets]);

  const handleModeChange = (mode: PromptMode) => {
    const solo = mode === 'solo';
    setPromptMode(mode);
    setDraftText('');
    setIsPromptEditing(false);
    setIsSoloMode(solo);
    post({ type: 'setSoloMode', value: solo });
    sendParamChange(7, solo ? 127 : 0); // unmaskwidth
    setParamsState(p => ({ ...p, unmaskwidth: solo ? 127 : 0 }));

    if (mode === 'mix') {
      // Entering mix always lands on the DJ (standard) layout.
      setMixLayout('standard');
      setFocusedMixIndex(i => (i > 1 ? 0 : i));
      sendMixPrompts(layoutSendList(mixPrompts, 'standard'), false);
      return;
    }

    // Single mode inherits the primary mix chip's prompt (chip #1); solo falls
    // back to the first instrument preset. This keeps single ↔ mix coherent.
    let preset: string | undefined;
    if (mode === 'single') {
      preset = (mixPrompts[0]?.text || '').trim() || getActivePresetList(false)[0];
    } else {
      preset = getActivePresetList(solo)[0];
    }
    if (preset) {
      setRockerIndex(0);
      setPromptText(preset);
      setActiveColor(getPromptColor(preset));
      if (isAudioPrompt) post({ type: 'clearAudioPrompt' });
      setIsAudioPrompt(false);
      sendPrompt(preset, true, solo);
    }
    setIsPromptEdited(false);
  };

  // MIDI sources list state
  const [midiSources, setMidiSources] = useState<{ name: string, endpoint: number, connected: boolean }[]>([]);



  // Octave shifting state and handlers
  const [octaveOffset, setOctaveOffset] = useState(0);

  const handleOctaveDown = useCallback(() => {
    setOctaveOffset(prev => {
      const next = Math.max(-4, prev - 1);
      keyboardBaseNote.current = KEYBOARD_MIDI_BASE_DEFAULT + next * 12;
      return next;
    });
  }, []);

  const handleOctaveUp = useCallback(() => {
    setOctaveOffset(prev => {
      const next = Math.min(4, prev + 1);
      keyboardBaseNote.current = KEYBOARD_MIDI_BASE_DEFAULT + next * 12;
      return next;
    });
  }, []);

  // Computer keyboard → MIDI
  const [keyboardMidiEnabled, setKeyboardMidiEnabled] = useState(true);
  const keyboardBaseNote = useRef(KEYBOARD_MIDI_BASE_DEFAULT);
  const pressedKeys = useRef<Map<string, number>>(new Map()); // key → MIDI note currently held

  // Determine which MIDI option is selected (0 represents Computer Keyboard, otherwise exact endpoint ID)
  const selectedMidiValue = keyboardMidiEnabled ? 0 : (midiSources.find(s => s.connected)?.endpoint ?? 0xFFFFFFFF);

  // ─── Engine communication ───────────────────────────────────────────────

  const textUpdateTimeout = useRef<number | null>(null);
  const waitingForEncoder = useRef(false);
  const encoderTimeoutRef = useRef<number | null>(null);

  const startEncoderTimeout = () => {
    if (encoderTimeoutRef.current) {
      clearTimeout(encoderTimeoutRef.current);
    }
    encoderTimeoutRef.current = window.setTimeout(() => {
      if (waitingForEncoder.current) {
        waitingForEncoder.current = false;
        // Force-update metrics to trigger isProgressActive updates
        setMetrics(m => ({ ...m }));
      }
      encoderTimeoutRef.current = null;
    }, 2000);
  };

  const sendPrompt = (
    rawText: string,
    immediate = false,
    soloOverride?: boolean,
  ) => {
    const soloActive = soloOverride !== undefined ? soloOverride : isSoloMode;
    const text = withBpm(rawText);
    const textWithPrefix = soloActive ? `SOLO ${text}` : text;
    const signature = `${soloActive ? 'solo' : 'single'}\u0000${text}`;

    if (signature === lastSentText.current && soloActive === lastSentSoloMode.current) return;

    const prompts = [
      { text: textWithPrefix, weight: 1 },
    ].filter(p => p.text.trim().length > 0 && p.weight > 0);
    if (textUpdateTimeout.current) {
      clearTimeout(textUpdateTimeout.current);
      textUpdateTimeout.current = null;
    }
    if (immediate) {
      lastSentText.current = signature;
      lastSentSoloMode.current = soloActive;
      waitingForEncoder.current = true;
      startEncoderTimeout();
      post({ type: 'textPrompts', value: prompts });
    } else {
      textUpdateTimeout.current = window.setTimeout(() => {
        lastSentText.current = signature;
        lastSentSoloMode.current = soloActive;
        waitingForEncoder.current = true;
        startEncoderTimeout();
        post({ type: 'textPrompts', value: prompts });
        textUpdateTimeout.current = null;
      }, 400);
    }
  };

  /** In the DJ 'standard' layout only the two deck chips (slots 1+2) are audible. */
  const layoutSendList = (items: MixPrompt[], layout: MixLayoutMode) =>
    layout === 'standard'
      ? items.map((item, i) => (i < 2 ? item : { ...item, weight: 0 }))
      : items;

  const sendMixPrompts = (items: MixPrompt[], immediate = true) => {
    const activeItems = items.filter(item => item.enabled && item.text.trim() && item.weight > 0);
    const total = activeItems.reduce((sum, item) => sum + item.weight, 0) || 1;
    const prompts = activeItems.map(item => ({
      text: withBpm(item.text),
      weight: item.weight / total,
    }));
    const signature = `mix\u0000${prompts.map(p => `${p.text}:${p.weight.toFixed(3)}`).join('\u0000')}`;
    if (signature === lastSentText.current && !lastSentSoloMode.current) return;

    if (textUpdateTimeout.current) {
      clearTimeout(textUpdateTimeout.current);
      textUpdateTimeout.current = null;
    }

    const send = () => {
      lastSentText.current = signature;
      lastSentSoloMode.current = false;
      waitingForEncoder.current = true;
      startEncoderTimeout();
      post({ type: 'textPrompts', value: prompts });
    };

    if (immediate) {
      send();
    } else {
      textUpdateTimeout.current = window.setTimeout(() => {
        send();
        textUpdateTimeout.current = null;
      }, 160);
    }
  };

  const handleDeckBFaderChange = (value: number) => {
    const next = Math.max(0, Math.min(1, value));
    setDeckFader(next);
    sendParamChange(10, 1 - next);
    sendParamChange(11, next);
  };

  const sendComposerToDeck = (deck: 'A' | 'B') => {
    const text = composerText.trim();
    if (!text) return;

    if (deck === 'A') {
      if (isAudioPrompt) post({ type: 'clearAudioPrompt' });
      setPromptText(text);
      setActiveColor(getPromptColor(text));
      setIsPromptEdited(false);
      sendPrompt(text, true);
    } else {
      setPromptTextB(text);
      sendPrompt(promptText || text, true);
    }
    setComposerText('');
  };

  const commitDraftText = useCallback(() => {
    const text = draftText.trim();
    if (!text) return;

    if (promptMode === 'mix') {
      setMixPrompts(prev => {
        const next = prev.map((item, index) => (
          index === focusedMixIndex
            // Typing into a disabled chip re-enables it.
            ? { ...item, text, color: getPromptColor(text), enabled: true }
            : item
        ));
        sendMixPrompts(layoutSendList(next, mixLayout), true);
        return next;
      });
      setDraftText('');
      setIsPromptEdited(false);
      return;
    }

    if (isAudioPrompt) post({ type: 'clearAudioPrompt' });
    setPromptText(text);
    setActiveColor(getPromptColor(text));
    setIsAudioPrompt(false);
    setIsPromptEdited(false);
    sendPrompt(text, true, promptMode === 'solo');
    setDraftText('');
    setIsPromptEditing(false);
    promptSurfaceRef.current?.blur();
  }, [draftText, focusedMixIndex, isAudioPrompt, promptMode, mixLayout]);

  const handlePromptSurfaceKeyDown = useCallback((e: React.KeyboardEvent<HTMLDivElement>) => {
    // Single/solo editing now uses a real <textarea> which handles its own keys
    // (incl. native paste/selection); don't let the fake-capture intercept it.
    if (e.target instanceof HTMLTextAreaElement || e.target instanceof HTMLInputElement) return;
    if ((promptMode === 'single' || promptMode === 'solo') && !isPromptEditing) return;
    // The Collider-style surface manages its own editing/keyboard handling.
    if (promptMode === 'mix' && mixLayout === 'surface') return;
    if (e.metaKey || e.ctrlKey || e.altKey) return;
    if (isComposingKey(e)) return; // don't capture keys mid IME composition

    if (e.key === 'Enter') {
      e.preventDefault();
      commitDraftText();
      return;
    }

    if (e.key === 'Escape') {
      e.preventDefault();
      setDraftText('');
      setIsPromptEditing(false);
      promptSurfaceRef.current?.blur();
      return;
    }

    if (e.key === 'Backspace') {
      e.preventDefault();
      setDraftText(prev => prev.slice(0, -1));
      setIsPromptEdited(true);
      return;
    }

    if (e.key === 'Tab') {
      if (promptMode !== 'mix') return;
      e.preventDefault();
      // The DJ 'standard' layout only exposes the two deck slots.
      const slotCount = mixLayout === 'standard' ? 2 : 6;
      setFocusedMixIndex(index => (index + (e.shiftKey ? slotCount - 1 : 1)) % slotCount);
      setDraftText('');
      return;
    }

    if (e.key.length === 1) {
      e.preventDefault();
      setDraftText(prev => prev + e.key);
      setIsPromptEdited(true);
    }
  }, [commitDraftText, isPromptEditing, promptMode, mixLayout]);

  const handlePromptSurfacePaste = useCallback((e: React.ClipboardEvent<HTMLDivElement>) => {
    // The single/solo textarea pastes natively; only the fake mix-capture needs this.
    if (e.target instanceof HTMLTextAreaElement || e.target instanceof HTMLInputElement) return;
    const text = e.clipboardData.getData('text/plain');
    if (!text) return;
    e.preventDefault();
    setDraftText(prev => prev + text.replace(/\s+/g, ' '));
    setIsPromptEdited(true);
  }, []);

  const updateMixWeightsFromPointer = useCallback((e: React.PointerEvent<HTMLDivElement>) => {
    const rect = e.currentTarget.getBoundingClientRect();
    const x = clamp01((e.clientX - rect.left) / rect.width) * 100;
    const y = clamp01((e.clientY - rect.top) / rect.height) * 100;

    if (mixLayout === 'standard') {
      // DJ crossfader: horizontal position blends deck A (slot 1) ↔ deck B (slot 2).
      const f = clamp01((x - 25) / 50); // full sweep across the middle half
      setMixPrompts(prev => {
        const next = prev.map((item, index) => (
          index === 0 ? { ...item, weight: 1 - f }
            : index === 1 ? { ...item, weight: f }
              : item
        ));
        sendMixPrompts(layoutSendList(next, 'standard'), false);
        return next;
      });
      return;
    }

    const positions = getMixPositions(mixLayout);
    const raw = positions.map(pos => {
      const dx = pos.x - x;
      const dy = pos.y - y;
      const distance = Math.sqrt(dx * dx + dy * dy);
      if (mixLayout === 'surface') {
        return Math.exp(-(distance * distance) / (2 * 26 * 26)) + 0.035;
      }
      return 1 / Math.max(mixLayout === 'circle' ? 8 : 12, distance);
    });
    setMixPrompts(prev => {
      // Disabled chips don't attract weight and don't dilute the others.
      const total = raw.reduce((sum, value, index) => sum + (prev[index].enabled ? value : 0), 0) || 1;
      const next = prev.map((item, index) => (
        item.enabled ? { ...item, weight: raw[index] / total } : item
      ));
      sendMixPrompts(next, false);
      return next;
    });
  }, [mixLayout]);

  // ─── Surface layout state (Collider-style) ───────────────────────────────
  const [surfacePrompts, setSurfacePrompts] = useState<PromptNode[]>([]);
  const [surfaceListener, setSurfaceListener] = useState<ListenerNode>({ x: 0, y: 0 });
  const [surfaceSelectedId, setSurfaceSelectedId] = useState<number | null>(null);
  const [surfaceSliderPos, setSurfaceSliderPos] = useState(0.5);
  const surfacePhysicsSpeed = surfaceSliderToSpeed(surfaceSliderPos);
  const surfaceInitialized = useRef(false);
  const surfaceHostRef = useRef<HTMLDivElement | null>(null);
  const surfaceNextIdRef = useRef(0);
  const surfaceNextColorRef = useRef(0);
  // Maps each surface node id → its backing chip index (0..5), so surface edits
  // write back to the right chip even when disabled chips create gaps.
  const surfaceChipMapRef = useRef<Map<number, number>>(new Map());
  const surfacePromptsRef = useRef(surfacePrompts);
  surfacePromptsRef.current = surfacePrompts;
  const surfaceListenerRef = useRef(surfaceListener);
  surfaceListenerRef.current = surfaceListener;

  // Re-seed the surface node layout from the current mix chips every time the
  // surface becomes active. This keeps the surface and circle/standard layouts
  // showing identical prompt content (the chips are the single source of truth).
  const surfaceActiveRef = useRef(false);
  useEffect(() => {
    const active = promptMode === 'mix' && mixLayout === 'surface';
    if (!active) { surfaceActiveRef.current = false; return; }
    if (surfaceActiveRef.current) return; // already seeded for this activation
    requestAnimationFrame(() => {
      const el = surfaceHostRef.current;
      if (!el) return;
      const { width, height } = el.getBoundingClientRect();
      if (width <= 0 || height <= 0) return;
      const seedChips = mixPrompts
        .map((c, i) => ({ c, i }))
        .filter(({ c }) => c.enabled && c.text.trim());
      const labels = seedChips.length > 0 ? seedChips.map(({ c }) => c.text) : [PROMPT_SUGGESTIONS[0]];
      const layout = buildSurfaceLayout(labels, width, height);
      // Pair each node (in label order) with its originating chip index.
      const map = new Map<number, number>();
      layout.prompts.forEach((node, k) => map.set(node.id, seedChips[k]?.i ?? k));
      surfaceChipMapRef.current = map;
      setSurfacePrompts(layout.prompts);
      setSurfaceListener(layout.listener);
      surfaceNextIdRef.current = layout.prompts.length;
      surfaceNextColorRef.current = layout.prompts.length;
      surfaceInitialized.current = true;
      surfaceActiveRef.current = true;
    });
  }, [promptMode, mixLayout, mixPrompts]);

  // Single mode is a view over chip #1: mirror committed single-prompt edits
  // back into chip 1 so switching to mix/circle/dj/surface keeps them in sync.
  useEffect(() => {
    if (promptMode !== 'single' || isAudioPrompt) return;
    const t = promptText;
    if (!t.trim()) return;
    setMixPrompts(prev => {
      if (prev[0]?.text === t) return prev;
      const next = [...prev];
      next[0] = { ...next[0], text: t, color: getPromptColor(t), enabled: true };
      return next;
    });
  }, [promptText, promptMode, isAudioPrompt]);

  // Persist the chips so they survive an app restart. Skip the initial mount
  // (defaults) so we don't clobber saved chips before the restore arrives, and
  // debounce so rapid edits (typing in a surface node) don't spam disk writes.
  const mixPersistInit = useRef(false);
  const mixSaveTimer = useRef<number | null>(null);
  useEffect(() => {
    if (!mixPersistInit.current) { mixPersistInit.current = true; return; }
    if (mixSaveTimer.current) clearTimeout(mixSaveTimer.current);
    mixSaveTimer.current = window.setTimeout(() => {
      post({ type: 'saveMixPrompts', value: mixPrompts });
      mixSaveTimer.current = null;
    }, 500);
  }, [mixPrompts]);

  /** Push the surface nodes' distance-based weights to the engine. */
  const sendSurfacePrompts = useCallback(() => {
    const nodes = surfacePromptsRef.current;
    if (nodes.length === 0) return;
    const weights = calculateWeights(surfaceListenerRef.current, nodes);
    const data: { text: string; weight: number }[] =
      Array.from({ length: MAX_SURFACE_PROMPTS }, () => ({ text: '', weight: 0 }));
    nodes.forEach((p, i) => {
      if (i < MAX_SURFACE_PROMPTS) data[i] = { text: withBpm(p.label), weight: weights[i] ?? 0 };
    });
    // Mark the dedup signature so switching back to other modes re-sends.
    lastSentText.current = `surface\u0000${data.map(d => `${d.text}:${d.weight.toFixed(3)}`).join('\u0000')}`;
    lastSentSoloMode.current = false;
    post({ type: 'textPrompts', value: data });
  }, []);

  // Throttle engine IPC to ~10Hz while nodes/listener move (physics runs at
  // 60fps; the TFLite quantizer doesn't need every frame).
  const surfaceSendThrottleRef = useRef<ReturnType<typeof setTimeout> | null>(null);
  const surfaceLastSendRef = useRef(0);
  useEffect(() => {
    if (promptMode !== 'mix' || mixLayout !== 'surface' || !surfaceInitialized.current) return;
    const THROTTLE_MS = 100;
    const now = Date.now();
    const elapsed = now - surfaceLastSendRef.current;
    if (surfaceSendThrottleRef.current) {
      clearTimeout(surfaceSendThrottleRef.current);
      surfaceSendThrottleRef.current = null;
    }
    if (elapsed >= THROTTLE_MS) {
      sendSurfacePrompts();
      surfaceLastSendRef.current = now;
    } else {
      // Trailing edge — guarantees the final position is always sent
      surfaceSendThrottleRef.current = setTimeout(() => {
        sendSurfacePrompts();
        surfaceLastSendRef.current = Date.now();
        surfaceSendThrottleRef.current = null;
      }, THROTTLE_MS - elapsed);
    }
  }, [surfacePrompts, surfaceListener, promptMode, mixLayout, sendSurfacePrompts]);

  useEffect(() => () => {
    if (surfaceSendThrottleRef.current) clearTimeout(surfaceSendThrottleRef.current);
  }, []);

  // Surface labels are a view over the 6 shared chips: write each node back to
  // its mapped chip (new nodes claim the first free slot) and disable chips
  // with no node, so circle/dj/single always see the same content.
  const syncSurfaceToChips = useCallback((nodes: PromptNode[]) => {
    const map = surfaceChipMapRef.current;
    setMixPrompts(prev => {
      const next = prev.map(c => ({ ...c, enabled: false }));
      const used = new Set<number>();
      nodes.forEach(node => {
        let chipIdx = map.get(node.id);
        if (chipIdx === undefined || used.has(chipIdx)) {
          chipIdx = next.findIndex((_, i) => !used.has(i));
        }
        if (chipIdx < 0) return;
        used.add(chipIdx);
        map.set(node.id, chipIdx);
        const text = node.label;
        next[chipIdx] = { ...next[chipIdx], text, color: getPromptColor(text), enabled: !!text.trim() };
      });
      return next;
    });
  }, []);

  const handleSurfacePromptMove = useCallback((id: number, x: number, y: number) => {
    setSurfacePrompts(prev => prev.map(p => (p.id === id ? { ...p, x, y } : p)));
  }, []);

  const handleSurfaceListenerMove = useCallback((x: number, y: number) => {
    setSurfaceListener({ x, y });
  }, []);

  const handleSurfaceAdd = useCallback((x: number, y: number) => {
    if (surfacePromptsRef.current.length >= MAX_SURFACE_PROMPTS) return;
    const label = PROMPT_SUGGESTIONS[Math.floor(Math.random() * PROMPT_SUGGESTIONS.length)];
    const next = [...surfacePromptsRef.current, {
      id: surfaceNextIdRef.current++,
      x,
      y,
      label,
      colorIndex: surfaceNextColorRef.current++,
    }];
    setSurfacePrompts(next);
    syncSurfaceToChips(next);
  }, [syncSurfaceToChips]);

  const handleSurfaceAddRandom = useCallback(() => {
    const el = surfaceHostRef.current;
    if (!el) return;
    const { width, height } = el.getBoundingClientRect();
    const pad = 56;
    handleSurfaceAdd(
      pad + Math.random() * (width - pad * 2),
      pad + Math.random() * (height - pad * 2),
    );
  }, [handleSurfaceAdd]);

  const handleSurfaceTextChange = useCallback((id: number, text: string) => {
    const next = surfacePromptsRef.current.map(p => (p.id === id ? { ...p, label: text } : p));
    setSurfacePrompts(next);
    syncSurfaceToChips(next);
  }, [syncSurfaceToChips]);

  const handleSurfaceDelete = useCallback((id: number) => {
    if (surfacePromptsRef.current.length <= 1) return;
    const next = surfacePromptsRef.current.filter(p => p.id !== id);
    setSurfacePrompts(next);
    setSurfaceSelectedId(prev => (prev === id ? null : prev));
    syncSurfaceToChips(next);
  }, [syncSurfaceToChips]);

  /** Apply a cheat-sheet prompt into the active mode's target. */
  const applyCheatPrompt = useCallback((text: string) => {
    const t = text.trim();
    if (!t) return;
    if (promptMode === 'single' || promptMode === 'solo') {
      if (isAudioPrompt) post({ type: 'clearAudioPrompt' });
      setIsAudioPrompt(false);
      setPromptText(t);
      setActiveColor(getPromptColor(t));
      setIsPromptEdited(false);
      sendPrompt(t, true, promptMode === 'solo');
    } else if (mixLayout === 'surface') {
      setSurfacePrompts(prev => {
        if (prev.length === 0) return prev;
        const targetId = surfaceSelectedId ?? prev[0].id;
        return prev.map(p => (p.id === targetId ? { ...p, label: t } : p));
      });
    } else {
      // standard (dj) / circle: write into the focused chip
      setMixPrompts(prev => {
        const next = prev.map((item, i) => (
          i === focusedMixIndex ? { ...item, text: t, color: getPromptColor(t), enabled: true } : item
        ));
        sendMixPrompts(layoutSendList(next, mixLayout), true);
        return next;
      });
    }
    setIsCheatOpen(false);
  }, [promptMode, mixLayout, isAudioPrompt, surfaceSelectedId, focusedMixIndex]);

  /** Enable/disable a mix chip. Keeps at least one chip enabled. */
  const toggleMixPrompt = useCallback((index: number) => {
    setMixPrompts(prev => {
      const target = prev[index];
      if (!target) return prev;
      const enabledCount = prev.filter(item => item.enabled).length;
      if (target.enabled && enabledCount <= 1) return prev; // never disable the last one
      const next = prev.map((item, i) => (
        i === index ? { ...item, enabled: !item.enabled } : item
      ));
      sendMixPrompts(layoutSendList(next, mixLayout), true);
      return next;
    });
  }, [mixLayout]);

  const sendParamChange = (index: number, value: number) => {
    post({ type: 'param', index, value });
  };

  const sendPerformanceChange = (key: PerformanceKey, value: number) => {
    const next = clamp01(value);
    setPerformance(p => ({ ...p, [key]: next }));
    post({ type: 'performance', key, value: next });
  };

  const nudgePerformance = (key: PerformanceKey, value: number, delta: number) => {
    sendPerformanceChange(key, value + delta);
  };

  const handleXYPointer = (e: any) => {
    const el = xyPadRef.current;
    if (!el) return;
    const rect = el.getBoundingClientRect();
    const x = clamp01((e.clientX - rect.left) / rect.width);
    const y = clamp01(1 - ((e.clientY - rect.top) / rect.height));
    if (padMode === 'filter') {
      setFilterPadPos({ x, y });
      sendPerformanceChange('filterX', filterXFromPad(x));
      sendPerformanceChange('filterY', filterYFromPad(y));
    } else {
      const t = tempFromPadX(x);
      const k = topkFromPadY(y);
      sendParamChange(0, t);
      sendParamChange(1, k);
      setParamsState(p => ({ ...p, temperature: t, topk: k }));
    }
  };

  /** Unlatched release: spring back to center = the mode's default values. */
  const springPadToDefault = () => {
    if (padMode === 'filter') {
      setFilterPadPos({ x: 0.5, y: 0.5 });
      sendPerformanceChange('filterX', 1.0);
      sendPerformanceChange('filterY', 0.0);
    } else {
      sendParamChange(0, DEFAULT_TEMPERATURE);
      sendParamChange(1, DEFAULT_TOPK);
      setParamsState(p => ({ ...p, temperature: DEFAULT_TEMPERATURE, topk: DEFAULT_TOPK }));
    }
  };

  const handlePadRelease = () => {
    setIsPadDragging(false);
    if (!padLatch) springPadToDefault();
  };

  const handleResetDefaults = () => {
    sendParamChange(0, DEFAULT_TEMPERATURE);       // temperature
    sendParamChange(1, DEFAULT_TOPK);              // topk
    sendParamChange(3, DEFAULT_CFG_MUSICCOCA);     // cfgmusiccoca
    sendParamChange(4, DEFAULT_CFG_NOTES);         // cfgnotes
    sendParamChange(48, DEFAULT_CFG_DRUMS);        // cfgdrums
    sendParamChange(7, DEFAULT_UNMASK_WIDTH);      // unmaskwidth
    sendParamChange(8, DEFAULT_BUFFER_SIZE);       // buffersize
    sendParamChange(39, 0);   // drumless
    sendParamChange(46, 0);   // onsetmode = false (Auto-Strum = true)
    setParamsState(p => ({ ...p, cfgnotesuser: DEFAULT_CFG_NOTES, cfgmusiccoca: DEFAULT_CFG_MUSICCOCA }));
    setFilterPadPos({ x: 0.5, y: 0.5 });
    ([
      ['filterX', 1.0],
      ['filterY', 0.02],
      ['drive', 0.0],
      ['delayMix', 0.0],
      ['delayFeedback', 0.25],
      ['reverbMix', 0.0],
      ['limiter', 0.35],
      ['stereoWidth', 0.5],
      ['tone', 0.5],
      ['outGain', 0.5],
      ['crush', 0.0],
      ['tremolo', 0.0],
    ] as Array<[PerformanceKey, number]>).forEach(([key, value]) => sendPerformanceChange(key, value));
  };

  // ─── Session export / import ──────────────────────────────────────────────
  // A "session" is the full musical + visual state: prompts, BPM, scale, theme,
  // visual, engine params and FX. Saved/loaded as JSON via native file dialogs.
  const [sessionNotice, setSessionNotice] = useState<string | null>(null);
  const sessionNoticeTimer = useRef<number | null>(null);
  const flashSessionNotice = (msg: string) => {
    setSessionNotice(msg);
    if (sessionNoticeTimer.current) clearTimeout(sessionNoticeTimer.current);
    sessionNoticeTimer.current = window.setTimeout(() => setSessionNotice(null), 2400);
  };

  const buildSession = () => ({
    app: 'megenta-jam',
    version: 1,
    prompts: {
      single: promptText,
      mix: mixPrompts,
      promptMode,
      mixLayout,
      deckFader,
    },
    musical: {
      bpmLock,
      bpmValue,
      lyriaScaleIdx,
      engineMode,
    },
    ui: {
      theme: uiTheme,
      visualMode,
      visualPreset,
    },
    params: paramsState,
    performance,
  });

  const exportSession = () => {
    post({ type: 'exportSession', value: JSON.stringify(buildSession(), null, 2) });
  };
  const importSession = () => {
    post({ type: 'importSession' });
  };

  // Engine-param addresses for the continuous params we re-push on import.
  const ENGINE_PARAM_ADDR: Record<string, number> = {
    temperature: 0, topk: 1, cfgmusiccoca: 3, cfgnotes: 4,
    cfgdrums: 48, unmaskwidth: 7, buffersize: 8,
  };

  /** Apply an imported session JSON: restore UI state and re-push to engine. */
  const applyImportedSession = (raw: string) => {
    let s: any;
    try { s = JSON.parse(raw); } catch { flashSessionNotice('Invalid session file'); return; }
    if (!s || typeof s !== 'object') { flashSessionNotice('Invalid session file'); return; }

    const pr = s.prompts ?? {};
    const mu = s.musical ?? {};
    const ui = s.ui ?? {};

    // Mix chips (always 6 slots; pad from defaults if the file has fewer).
    let mix = mixPrompts;
    if (Array.isArray(pr.mix) && pr.mix.length > 0) {
      mix = Array.from({ length: 6 }, (_, i) => {
        const m = pr.mix[i];
        if (m && typeof m === 'object') {
          const text = typeof m.text === 'string' ? m.text : '';
          return {
            id: DEFAULT_MIX_PROMPTS[i]?.id ?? i + 1,
            text,
            weight: typeof m.weight === 'number' ? m.weight : (DEFAULT_MIX_PROMPTS[i]?.weight ?? 0.16),
            color: typeof m.color === 'string' ? m.color : getPromptColor(text),
            enabled: m.enabled !== false,
          };
        }
        return DEFAULT_MIX_PROMPTS[i];
      });
      setMixPrompts(mix);
    }

    // BPM
    if (typeof mu.bpmValue === 'number') {
      const v = Math.max(40, Math.min(220, Math.round(mu.bpmValue)));
      setBpmValue(v); setBpmText(String(v));
    }
    if (typeof mu.bpmLock === 'boolean') setBpmLock(mu.bpmLock);

    // Scale (Lyria)
    if (mu.lyriaScaleIdx === null || typeof mu.lyriaScaleIdx === 'number') {
      setLyriaScaleIdx(mu.lyriaScaleIdx);
      if (typeof mu.lyriaScaleIdx === 'number' && LYRIA_SCALES[mu.lyriaScaleIdx]) {
        post({ type: 'lyriaConfig', scale: LYRIA_SCALES[mu.lyriaScaleIdx] });
      }
    }

    // UI
    if (typeof ui.theme === 'string' && (UI_THEMES as readonly string[]).includes(ui.theme)) {
      setUiTheme(ui.theme as UiTheme);
    }
    if (ui.visualMode === 'off' || ui.visualMode === 'bg' || ui.visualMode === 'full') setVisualMode(ui.visualMode);
    if (typeof ui.visualPreset === 'number') setVisualPreset(((ui.visualPreset % VISUAL_PRESETS.length) + VISUAL_PRESETS.length) % VISUAL_PRESETS.length);

    // Engine params
    if (s.params && typeof s.params === 'object') {
      setParamsState(prev => ({ ...prev, ...s.params }));
      Object.entries(ENGINE_PARAM_ADDR).forEach(([k, addr]) => {
        const val = s.params[k];
        if (typeof val === 'number') sendParamChange(addr, val);
      });
      if (typeof s.params.drumless === 'boolean') sendParamChange(39, s.params.drumless ? 1 : 0);
      if (typeof s.params.onsetmode === 'boolean') sendParamChange(46, s.params.onsetmode ? 1 : 0);
    }

    // Performance FX
    if (s.performance && typeof s.performance === 'object') {
      Object.keys(s.performance).forEach(key => {
        const v = s.performance[key];
        if (typeof v === 'number') sendPerformanceChange(key as PerformanceKey, v);
      });
    }

    // Deck fader + single prompt text
    if (typeof pr.deckFader === 'number') setDeckFader(clamp01(pr.deckFader));
    if (typeof pr.single === 'string') {
      setPromptText(pr.single);
      setActiveColor(getPromptColor(pr.single));
    }

    // Layout + force the surface to re-seed from the imported chips.
    const layout: MixLayoutMode =
      (pr.mixLayout === 'standard' || pr.mixLayout === 'circle' || pr.mixLayout === 'surface') ? pr.mixLayout : mixLayout;
    setMixLayout(layout);
    surfaceActiveRef.current = false;

    // Mode (set after content so the re-send below targets the right path).
    const mode: PromptMode =
      (pr.promptMode === 'mix' || pr.promptMode === 'solo' || pr.promptMode === 'single') ? pr.promptMode : promptMode;
    const solo = mode === 'solo';
    setPromptMode(mode);
    setIsSoloMode(solo);
    post({ type: 'setSoloMode', value: solo });
    setDraftText('');
    setIsPromptEditing(false);
    setIsPromptEdited(false);

    // Engine (local vs Lyria) — switching stops playback natively.
    if ((mu.engineMode === 'local' || mu.engineMode === 'lyria') && mu.engineMode !== engineMode) {
      switchEngine(mu.engineMode);
    }

    // Re-push prompts to the engine for the restored mode.
    if (mode === 'mix') {
      if (layout !== 'surface') sendMixPrompts(layoutSendList(mix, layout), true);
      // surface mode re-seeds via its effect; the throttled sender follows.
    } else {
      const text = (typeof pr.single === 'string' && pr.single.trim())
        ? pr.single
        : (mode === 'single' ? (mix[0]?.text ?? '') : '');
      if (text) sendPrompt(text, true, solo);
    }

    flashSessionNotice('Session imported');
  };
  const applyImportedSessionRef = useRef(applyImportedSession);
  applyImportedSessionRef.current = applyImportedSession;

  const togglePlay = () => {
    const newPlaying = !isPlaying;
    setIsPlaying(newPlaying);
    post({ type: 'togglePlay', value: newPlaying });
  };

  const resetModel = () => {
    sendParamChange(31, 1.0);
    setTimeout(() => sendParamChange(31, 0.0), 100);
  };

  const loadAudioPrompt = () => {
    post({ type: 'loadAudioPrompt', index: 0 });
  };

  const clearAudioPrompt = () => {
    post({ type: 'clearAudioPrompt' });
  };

  // Record up to 10s from the mic and use it as the audio prompt. Native
  // captures, resamples to 16 kHz mono, and feeds the engine; it also
  // auto-stops at the 10s cap and reports state via `recordingState`.
  const [recordingState, setRecordingState] = useState<'idle' | 'recording'>('idle');
  const toggleRecordAudioPrompt = () => {
    if (recordingState === 'recording') {
      post({ type: 'stopRecordAudioPrompt' });
    } else {
      post({ type: 'startRecordAudioPrompt' });
    }
  };



  const openSettings = () => {
    post({ type: 'openSettings' });
  };

  // ─── State updates from native ─────────────────────────────────────────

  // Track whether the user has received initial state yet. Before that,
  // `prompt` updates from native should populate the UI. After, we ignore
  // subsequent `prompt` echoes so they don't stomp in-progress typing.
  const promptInitialized = useRef(false);
  const mixRestored = useRef(false);

  useEffect(() => {
    window.updateState = (state: any) => {
      if (state.metrics) {
        setMetrics(m => {
          const next = { ...m, ...state.metrics };
          if (next.textEncoderStatus === 1) {
            waitingForEncoder.current = false;
            if (encoderTimeoutRef.current) {
              clearTimeout(encoderTimeoutRef.current);
              encoderTimeoutRef.current = null;
            }
          }
          return next;
        });
      }
      if (state.audioLevels) {
        setAudioLevels(state.audioLevels);
        // Envelope + transient detection for the visual layer (refs only —
        // no extra re-renders at 25 Hz).
        const lvl = Math.max(state.audioLevels.left ?? 0, state.audioLevels.right ?? 0);
        const vd = visualDataRef.current;
        const prevLvl = vd.level;
        vd.level = lvl > vd.level
          ? vd.level * 0.55 + lvl * 0.45   // fast attack
          : vd.level * 0.92 + lvl * 0.08;  // slow release
        vd.kick = Math.max(
          vd.kick * 0.82,
          lvl > prevLvl * 1.35 && lvl > 0.12 ? Math.min(1, lvl * 1.4) : 0,
        );
      }
      if (state.waveform) {
        const w = state.waveform as number[];
        const arr = visualDataRef.current.wave;
        const n = Math.min(arr.length, w.length);
        for (let i = 0; i < n; i++) arr[i] = w[i];
      }
      if (state.modelName !== undefined) setModelName(state.modelName);
      if (state.isPlaying !== undefined) setIsPlaying(state.isPlaying);
      if (state.activeNotes) {
        setActiveNotes(state.activeNotes);
        if (state.activeNotes.length > 0) {
          setNoteActivityCounter(n => n + 1);
          setIsPlaying(prev => {
            if (!prev) {
              post({ type: 'togglePlay', value: true });
              return true;
            }
            return prev;
          });
        }
      }

      let solo = isSoloMode;
      if (state.solomode !== undefined) {
        solo = !!state.solomode;
        setIsSoloMode(solo);
      }

      if (state.params !== undefined) {
        setParamsState(p => {
          const next = { ...p };
          if (state.params.temperature !== undefined) next.temperature = state.params.temperature;
          if (state.params.topk !== undefined) next.topk = state.params.topk;
          if (state.params.cfgnotes !== undefined) next.cfgnotes = state.params.cfgnotes;
          if (state.params.cfgmusiccoca !== undefined) next.cfgmusiccoca = state.params.cfgmusiccoca;
          if (state.params.cfgnotesuser !== undefined) next.cfgnotesuser = state.params.cfgnotesuser;
          if (state.params.cfgdrums !== undefined) next.cfgdrums = state.params.cfgdrums;
          if (state.params.unmaskwidth !== undefined) next.unmaskwidth = state.params.unmaskwidth;
          if (state.params.buffersize !== undefined) next.buffersize = state.params.buffersize;
          if (state.params.volume !== undefined) next.volume = state.params.volume;
          if (state.params.drumless !== undefined) next.drumless = state.params.drumless;
          if (state.params.onsetmode !== undefined) next.onsetmode = !!state.params.onsetmode;
          return next;
        });
      }

      if (state.openSettings !== undefined) {
        setIsSettingsOpen(!!state.openSettings);
      }


      // Restore user preset overrides from native if present
      if (state.savedUserPresets !== undefined) {
        if (state.savedUserPresets.solo) setUserPresetsSolo(state.savedUserPresets.solo);
        if (state.savedUserPresets.jam) setUserPresetsJam(state.savedUserPresets.jam);
      }

      // Restore the unified mix chips (the source of truth for every mode).
      let restoredChip0 = '';
      if (Array.isArray(state.savedMixPrompts) && state.savedMixPrompts.length > 0 && !mixRestored.current) {
        const restored = Array.from({ length: 6 }, (_, i) => {
          const m = state.savedMixPrompts[i];
          if (m && typeof m === 'object') {
            const text = typeof m.text === 'string' ? m.text : (DEFAULT_MIX_PROMPTS[i]?.text ?? '');
            return {
              id: DEFAULT_MIX_PROMPTS[i]?.id ?? i + 1,
              text,
              weight: typeof m.weight === 'number' ? m.weight : (DEFAULT_MIX_PROMPTS[i]?.weight ?? 0.16),
              color: typeof m.color === 'string' ? m.color : getPromptColor(text),
              enabled: m.enabled !== false,
            };
          }
          return DEFAULT_MIX_PROMPTS[i];
        });
        setMixPrompts(restored);
        restoredChip0 = restored[0]?.text ?? '';
        mixRestored.current = true;
      }

      if (state.prompt !== undefined && !promptInitialized.current) {
        // Use saved rocker index if available, otherwise try to find a match
        let presetIdx = -1;
        if (state.savedRockerIndex !== undefined) {
          presetIdx = state.savedRockerIndex;
        }

        // Build effective preset list using user overrides that arrived in this same state update
        const userSolo = state.savedUserPresets?.solo ?? {};
        const userJam = state.savedUserPresets?.jam ?? {};
        const factoryList = solo ? INSTRUMENT_SUGGESTIONS : PROMPT_SUGGESTIONS;
        const effectiveList = factoryList.map((text, i) => {
          const overrides = solo ? userSolo : userJam;
          return (i in overrides) ? overrides[i] : text;
        });

        // Single mode is chip #1 — prefer the restored chip over the legacy
        // saved prompt so the unified model is authoritative on launch.
        let promptToUse = (!solo && restoredChip0.trim()) ? restoredChip0 : state.prompt;

        if (!promptToUse) {
          // No saved prompt — use preset at the saved index (or first)
          const idx = presetIdx >= 0 ? presetIdx : 0;
          promptToUse = effectiveList[idx] || '';
          presetIdx = idx;
        } else if (presetIdx < 0) {
          // No saved rocker index — try to find the prompt in the effective list
          presetIdx = effectiveList.findIndex(p => p.toLowerCase() === promptToUse.toLowerCase());
        }

        setPromptText(promptToUse);
        setActiveColor(getPromptColor(promptToUse));
        setIsAudioPrompt(state.isAudioPrompt || false);
        setIsPromptEdited(false);
        if (presetIdx >= 0) {
          setRockerIndex(presetIdx);
        }
        rockerInitialized.current = true;
        // Frontend takes ownership — sync prompt to engine
        sendPrompt(promptToUse, true, solo);
        promptInitialized.current = true;
      } else if (state.isAudioPrompt !== undefined) {
        if (state.isAudioPrompt) {
          // Audio prompt loaded — honor native's value (user explicitly triggered upload)
          setPromptText(state.prompt);
          setActiveColor(getPromptColor(state.prompt));
          setIsPromptEdited(false);
          lastSentText.current = state.prompt;
        }
        setIsAudioPrompt(state.isAudioPrompt);
      }

      if (Array.isArray(state.lyriaChannels)) {
        setLyriaChannels(state.lyriaChannels);
      }
      if (state.lyriaStatus !== undefined) {
        setLyriaStatus(state.lyriaStatus);
      }
      if (state.visualImage !== undefined) {
        setVisualImage(state.visualImage);
        // Reveal the result: turn the visual layer on and jump to particles.
        setVisualMode(m => (m === 'off' ? 'bg' : m));
        setVisualPreset(FIRST_IMAGE_PRESET);
      }
      if (state.computerKeyboardMidi !== undefined) {
        setKeyboardMidiEnabled(!!state.computerKeyboardMidi);
      }
      if (state.localModels !== undefined) {
        setLocalModels(state.localModels);
      }
      if (state.remoteModels !== undefined) {
        setRemoteModels(state.remoteModels);
        setIsFetchingModels(false);
      }
      if (state.remoteModelsError !== undefined) {
        setIsFetchingModels(false);
      }
      if (state.downloadProgress !== undefined) {
        setDownloadProgress(state.downloadProgress);
      }
      if (state.resourcesMissing !== undefined) {
        setResourcesMissing(state.resourcesMissing);
      }
      if (state.resourcesProgress !== undefined) {
        setResourcesProgress(state.resourcesProgress);
      }
      if (state.downloadPath !== undefined) {
        setDownloadPath(state.downloadPath);
      }

      if (state.midiSources !== undefined) {
        setMidiSources(state.midiSources);
      }
      if (state.solomode !== undefined) {
        setIsSoloMode(!!state.solomode);
      }
      if (state.recordingState === 'recording' || state.recordingState === 'idle') {
        setRecordingState(state.recordingState);
      }
      if (typeof state.aiPromptResult === 'string') {
        const text = state.aiPromptResult;
        setAiHistory(h => [...h, { role: 'ai', text }]);
        setAiLoading(false);
      }
      if (typeof state.aiPromptError === 'string') {
        const text = state.aiPromptError;
        setAiHistory(h => [...h, { role: 'error', text }]);
        setAiLoading(false);
      }
      if (state.aiPatchResult && typeof state.aiPatchResult === 'object') {
        const p = state.aiPatchResult;
        if (typeof p._lane === 'number' && p._lane >= 1 && p._lane <= 5) {
          // AI patch for a PGM MIDI lane: convert and ship the full patch to
          // the lane synth (and into the next PGM package).
          const { params, matrix, name } = aiPatchToNumeric(p);
          post({
            type: 'lanePatch', index: p._lane, name, origin: 'ai',
            params: { ...DEFAULT_SYNTH, ...params }, matrix,
          });
          setAiLaneBusy(null);
          setStudio(st => ({ ...st, notice: `✨ ${st.stems[p._lane]?.name}: ${name}` }));
          window.setTimeout(() => setStudio(st => ({ ...st, notice: null })), 2600);
        } else {
          applyAiPatchRef.current(p);
        }
        setAiPatchBusy(false);
        setAiPatchError(null);
      }
      if (typeof state.aiPatchError === 'string') {
        setAiPatchError(state.aiPatchError);
        setAiPatchBusy(false);
        setAiLaneBusy(null);
        if (aiLaneBusyRef.current !== null) {
          const msg = state.aiPatchError;
          setStudio(st => ({ ...st, error: msg }));
          window.setTimeout(() => setStudio(st => ({ ...st, error: null })), 3600);
        }
      }
      if (state.studioClip && typeof state.studioClip === 'object') {
        const c = state.studioClip;
        // Only honor the push if the editor is waiting for this lane.
        if (studioClipRef.current?.index === Number(c.index)) {
          setStudioClip({
            index: Number(c.index),
            notes: Array.isArray(c.notes) ? c.notes : [],
          });
        }
      }
      if (state.aiComposeResult && typeof state.aiComposeResult === 'object') {
        const r = state.aiComposeResult;
        setComposeBusy(false);
        setComposeError(null);
        if (Array.isArray(r.notes)) {
          setComposeResult({
            seq: ++composeSeqRef.current,
            mode: composeModeRef.current,
            notes: r.notes,
          });
        }
      }
      if (typeof state.aiComposeError === 'string') {
        setComposeBusy(false);
        setComposeError(state.aiComposeError);
      }
      if (typeof state.audioMultichannel === 'boolean') {
        const mc = state.audioMultichannel;
        setStudio(st => ({ ...st, multichannel: mc }));
      }
      if (state.calibration && typeof state.calibration === 'object') {
        const c = state.calibration;
        setCalibration(prev => ({
          active: !!c.active,
          measuring: c.measuring ?? (c.active ? prev.measuring : false),
          comp: c.comp ?? prev.comp,
          effectiveRate: c.effectiveRate ?? prev.effectiveRate,
          channels: c.channels ?? prev.channels,
        }));
      }
      if (typeof state.audioOuts === 'number') {
        const ch = Math.max(2, Math.min(16, state.audioOuts));
        setStudio(st => ({
          ...st,
          outChannels: ch,
          // Drop routed bits beyond the new device's channels.
          routeMain: (st.routeMain & ((1 << ch) - 1)) || 0x3,
          routeClick: (st.routeClick & ((1 << ch) - 1)) || 0x3,
        }));
      }
      if (Array.isArray(state.studioLanes)) {
        const ls = state.studioLanes;
        setStudio(st => ({
          ...st,
          stems: st.stems.map((x, i) => {
            const l = ls[i];
            if (!l || typeof l !== 'object') return x;
            return {
              ...x,
              engine: Number(l.engine) === 1 ? 'sf2' as const : 'syn' as const,
              sfProgram: Number(l.program ?? 0),
              fxReverb: Number(l.reverb ?? 0),
              fxEcho: Number(l.echo ?? 0),
            };
          }),
        }));
      }
      if (Array.isArray(state.studioPatches)) {
        const ps = state.studioPatches;
        setStudio(st => ({
          ...st,
          stems: st.stems.map((x, i) => ({
            ...x,
            patch: ps[i] && typeof ps[i] === 'object' && typeof ps[i].name === 'string'
              ? { name: String(ps[i].name), origin: String(ps[i].origin ?? 'user') }
              : null,
          })),
        }));
      }
      if (Array.isArray(state.savedSynthPresets)) {
        setSynthPresets(state.savedSynthPresets.filter(
          (p: any) => p && typeof p.name === 'string' && p.params,
        ));
      }
      if (typeof state.detectedBpm === 'number') {
        setBpmDetecting(false);
        if (state.detectedBpm >= 40) {
          const v = Math.max(40, Math.min(220, Math.round(state.detectedBpm)));
          setBpmValue(v);
          setBpmText(String(v));
          flashBpmStatus(`♪ ${v} bpm`);
        }
      }
      if (typeof state.bpmDetectError === 'string') {
        setBpmDetecting(false);
        flashBpmStatus(state.bpmDetectError);
      }
      if (state.studioSong && typeof state.studioSong === 'object') {
        const sg = state.studioSong;
        setStudio(st => ({
          ...st,
          loaded: true,
          name: String(sg.name ?? 'song'),
          duration: Number(sg.duration ?? 0),
          bpm: Number(sg.bpm ?? 0),
          key: String(sg.key ?? ''),
          memo: String(sg.memo ?? ''),
          sections: Array.isArray(sg.sections) ? sg.sections : [],
          songWave: Array.isArray(sg.wave) ? sg.wave : [],
          stems: st.stems.map(x => ({ ...x, wave: [], source: '', notes: 0, ribbon: [] })),
          error: null,
        }));
      }
      if (Array.isArray(state.studioStems)) {
        const waves = state.studioStems;
        const sources = Array.isArray(state.studioStemSources) ? state.studioStemSources : null;
        setStudio(st => ({
          ...st,
          stems: st.stems.map((x, i) => ({
            ...x,
            wave: waves[i] ?? [],
            source: sources ? String(sources[i] ?? '') : x.source,
            notes: 0,
            ribbon: [],
          })),
        }));
      }
      if (state.studioSepPipeline && typeof state.studioSepPipeline === 'object') {
        const sp = state.studioSepPipeline;
        setStudio(st => ({
          ...st,
          sepPipeline: ['auto', 'hpss', 'demucs', 'rf', 'rf2'].includes(sp.mode)
            ? sp.mode : st.sepPipeline,
          rfPresent: !!sp.rfPresent,
        }));
      }
      if (state.studioStemAlign && typeof state.studioStemAlign === 'object') {
        const a = state.studioStemAlign;
        const i = Number(a.index);
        const ms = Number(a.ms ?? 0);
        setStudio(st => ({
          ...st,
          stems: st.stems.map((x, k) => k === i ? { ...x, alignMs: ms } : x),
        }));
      }
      if (typeof state.liveMode === 'boolean') {
        setLiveMode(state.liveMode);
      }
      if (typeof state.studioClickGain === 'number') {
        const g = state.studioClickGain;
        setStudio(st => ({ ...st, clickGain: g }));
      }
      if (state.studioStemDry && typeof state.studioStemDry === 'object') {
        const a = state.studioStemDry;
        const i = Number(a.index);
        const v = Number(a.value ?? 0);
        setStudio(st => ({
          ...st,
          stems: st.stems.map((x, k) => k === i ? { ...x, dry: v } : x),
        }));
      }
      if (state.studioLive && typeof state.studioLive === 'object') {
        const lv = state.studioLive;
        setLiveSource(Number(lv.source ?? 0));
        setLiveSfProgram(Number(lv.program ?? 0));
        if (typeof lv.gain === 'number') setLiveGain(lv.gain);
        if (typeof lv.reverb === 'number') setLiveReverb(lv.reverb);
        if (typeof lv.echo === 'number') setLiveEcho(lv.echo);
      }
      if (state.studioCue && typeof state.studioCue === 'object') {
        const c = state.studioCue;
        setStudio(st => ({
          ...st,
          cue: c.has ? Number(c.sec) : -1,
          clickAnchor: c.hasAnchor ? Number(c.anchor) : -1,
          timeSig: Number(c.timeSig) === 3 ? 3 : 4,
        }));
      }
      if (typeof state.studioBpm === 'number') {
        const b = state.studioBpm;
        setStudio(st => ({ ...st, bpm: b }));
      }
      if (typeof state.studioSepEngine === 'string') {
        const eng = state.studioSepEngine;
        setStudio(st => ({ ...st, sepEngine: eng }));
      }
      if (state.studioSepModel && typeof state.studioSepModel === 'object') {
        const m = state.studioSepModel;
        setStudio(st => ({
          ...st,
          sepModel: {
            present: !!m.present,
            sources: Number(m.sources ?? 0),
            downloading: !!m.downloading,
            pct: Number(m.pct ?? 0),
            mb: Number(m.mb ?? 0),
          },
        }));
      }
      if (state.studioProgress && typeof state.studioProgress === 'object') {
        const { stage, pct } = state.studioProgress;
        setStudio(st => ({
          ...st,
          stage: String(stage ?? ''),
          pct: Number(pct ?? 0),
          busy: stage !== 'ready',
        }));
      }
      if (Array.isArray(state.studioChords)) {
        const chords = state.studioChords;
        setStudio(st => ({ ...st, chords }));
      }
      if (Array.isArray(state.studioSources)) {
        const src = state.studioSources;
        setStudio(st => ({
          ...st,
          stems: st.stems.map((x, i) => ({
            ...x,
            playSrc: Number(src[i] ?? 0) === 1 ? 'midi' as const : 'audio' as const,
          })),
        }));
      }
      if (state.studioNotes && typeof state.studioNotes === 'object') {
        const { index, count, ribbon } = state.studioNotes;
        if (clipRegenPendingRef.current === Number(index) &&
            studioClipRef.current?.index === Number(index)) {
          clipRegenPendingRef.current = null;
          post({ type: 'laneClipGet', index: Number(index) });
        }
        setStudio(st => ({
          ...st,
          stems: st.stems.map((x, i) =>
            i === index
              ? { ...x, notes: Number(count ?? 0), ribbon: Array.isArray(ribbon) ? ribbon : [] }
              : x),
        }));
      }
      if (state.studioPlayhead && typeof state.studioPlayhead === 'object') {
        const ph = state.studioPlayhead;
        if (ph.active) {
          setStudio(st => ({
            ...st,
            playMode: ph.mode === 'stems' ? 'stems' : 'song',
            playing: !!ph.playing,
            playhead: { pos: Number(ph.pos ?? 0), len: Number(ph.len ?? 0) },
          }));
        } else {
          setStudio(st => ({
            ...st, playMode: 'none', playing: false, playhead: { pos: 0, len: 0 },
          }));
        }
      }
      if (typeof state.studioError === 'string') {
        const msg = state.studioError;
        setStudio(st => ({ ...st, busy: false, error: msg }));
      }
      if (typeof state.studioNotice === 'string') {
        const msg = state.studioNotice;
        setStudio(st => ({ ...st, notice: msg }));
        window.setTimeout(() => setStudio(st => ({ ...st, notice: null })), 2600);
      }
      if (typeof state.importedSession === 'string') {
        applyImportedSessionRef.current(state.importedSession);
      }
      if (typeof state.sessionNotice === 'string') {
        flashSessionNotice(state.sessionNotice);
      }
      if (typeof state.sessionError === 'string') {
        flashSessionNotice(state.sessionError);
      }
    };

    post({ type: 'uiReady' });
    post({ type: 'listRemoteModels' });

    return () => {
      delete (window as any).updateState;
      if (encoderTimeoutRef.current) {
        clearTimeout(encoderTimeoutRef.current);
      }
    };
  }, []);

  // Transport keys
  useEffect(() => {
    const handleKeyDown = (e: KeyboardEvent) => {
      if (e.defaultPrevented) return;
      if (document.activeElement instanceof HTMLInputElement || document.activeElement instanceof HTMLTextAreaElement) return;
      if (promptSurfaceRef.current?.contains(document.activeElement)) return;
      if (e.key === ' ') {
        e.preventDefault();
        if (mainTab === 'pgm') {
          // PGM console: space drives the stem transport, not the jam engine.
          const st = studioRef.current;
          if (st.stems.some(x => x.wave.length > 0) || st.playMode === 'stems') {
            studioTransport(st.playMode === 'stems' && st.playing ? 'pause' : 'play');
          }
        } else {
          togglePlay();
        }
      }
      if (e.key === 'ArrowLeft' || e.key === 'ArrowRight') {
        e.preventDefault();
        if (mainTab === 'pgm') {
          // Nudge the PGM playhead ±2 s (shift = ±10 s).
          const st = studioRef.current;
          if (st.playhead.len > 0) {
            const step = (e.shiftKey ? 10 : 2) * (e.key === 'ArrowRight' ? 1 : -1);
            studioSeek(Math.max(0, Math.min(st.playhead.len, st.playhead.pos + step)));
          }
        } else {
          const step = e.shiftKey ? 0.1 : 0.02;
          handleDeckBFaderChange(deckFader + (e.key === 'ArrowRight' ? step : -step));
        }
      }
      // PGM: ⌘1..⌘8 toggle mute (silence / play) per track.
      if (mainTab === 'pgm' && (e.metaKey || e.ctrlKey) &&
          e.key >= '1' && e.key <= '8') {
        e.preventDefault();
        const idx = Number(e.key) - 1;
        const st = studioRef.current;
        const stem = st.stems[idx];
        if (stem && (stem.wave.length > 0 || stem.notes > 0 || stem.playSrc === 'midi')) {
          studioMix(idx, { mute: !st.mixer[idx].mute });
        }
      }
    };
    window.addEventListener('keydown', handleKeyDown);
    return () => window.removeEventListener('keydown', handleKeyDown);
  }, [isPlaying, deckFader, mainTab, studioTransport, studioSeek, studioMix]);

  // ─── BPM lock: metronome pulse + prompt re-send ───────────────────────────

  // Inject a short MIDI pulse on every beat while playing. Note conditioning
  // is a hard, frame-accurate signal, so the model entrains to the pulse.
  // Disabled in solo mode (pulses would fight the note-gated solo envelope).
  useEffect(() => {
    // Lyria locks tempo natively (musicGenerationConfig.bpm) — no pulses.
    if (!bpmLock || !isPlaying || isSoloMode || engineMode !== 'local') return;
    const METRONOME_NOTE = 36; // C2 — kick register
    const intervalMs = 60000 / Math.max(40, Math.min(220, bpmValue));
    const gateMs = Math.min(110, intervalMs * 0.45);
    let cancelled = false;
    let timer = 0;
    let gateTimer = 0;
    let nextBeat = Date.now();
    const tick = () => {
      if (cancelled) return;
      post({ type: 'kbdNote', note: METRONOME_NOTE, on: true, pulse: true });
      gateTimer = window.setTimeout(() => {
        post({ type: 'kbdNote', note: METRONOME_NOTE, on: false, pulse: true });
      }, gateMs);
      // Self-correcting schedule: accumulate the ideal beat time so timer
      // jitter never drifts the average tempo.
      nextBeat += intervalMs;
      timer = window.setTimeout(tick, Math.max(0, nextBeat - Date.now()));
    };
    tick();
    return () => {
      cancelled = true;
      clearTimeout(timer);
      clearTimeout(gateTimer);
      post({ type: 'kbdNote', note: METRONOME_NOTE, on: false, pulse: true });
    };
  }, [bpmLock, bpmValue, isPlaying, isSoloMode, engineMode]);

  // Lyria native tempo: forward the locked BPM (and live temperature) through
  // musicGenerationConfig whenever they change in cloud mode.
  useEffect(() => {
    if (engineMode !== 'lyria') return;
    const config: Record<string, number> = { temperature: paramsState.temperature };
    if (bpmLock) config.bpm = Math.round(Math.max(60, Math.min(200, bpmValue)));
    const timer = window.setTimeout(() => post({ type: 'lyriaConfig', ...config }), 150);
    return () => clearTimeout(timer);
  }, [engineMode, bpmLock, bpmValue, paramsState.temperature]);

  // Re-push the current prompts whenever the BPM lock/value changes so the
  // "<bpm> bpm" suffix reaches the engine without requiring a manual edit.
  useEffect(() => {
    if (promptMode === 'mix') {
      if (mixLayout === 'surface') {
        if (surfaceInitialized.current) sendSurfacePrompts();
      } else {
        sendMixPrompts(layoutSendList(mixPrompts, mixLayout), false);
      }
    } else if (promptText.trim()) {
      sendPrompt(promptText, false);
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [bpmLock, bpmValue]);

  // Solo mode: auto-stop after timeout of no incoming notes
  useEffect(() => {
    if (!isSoloMode || !isPlaying) return;
    const timer = window.setTimeout(() => {
      setIsPlaying(false);
      post({ type: 'togglePlay', value: false });
    }, SOLO_INACTIVITY_TIMEOUT_MS);
    return () => clearTimeout(timer);
  }, [isSoloMode, isPlaying, noteActivityCounter]);

  const isProgressActive = metrics.textEncoderStatus === 1 || waitingForEncoder.current;

  // Computer keyboard → MIDI. Only intercept when enabled and when no input
  // is focused (so typing prompts still works).
  useEffect(() => {
    if (!keyboardMidiEnabled) {
      // Release any still-held notes
      pressedKeys.current.forEach((note) => {
        post({ type: 'kbdNote', note, on: false });
      });
      pressedKeys.current.clear();
      return;
    }

    const handleDown = (e: KeyboardEvent) => {
      if (e.defaultPrevented) return;
      if (document.activeElement instanceof HTMLInputElement || document.activeElement instanceof HTMLTextAreaElement) return;
      if (promptSurfaceRef.current?.contains(document.activeElement)) return;
      if (e.metaKey || e.ctrlKey || e.altKey) return;
      const key = e.key.toLowerCase();
      if (key === 'z') {
        e.preventDefault();
        if (e.repeat) return;
        handleOctaveDown();
        return;
      }
      if (key === 'x') {
        e.preventDefault();
        if (e.repeat) return;
        handleOctaveUp();
        return;
      }
      const semi = KEY_TO_SEMITONE[key];
      if (semi === undefined) return;
      e.preventDefault();
      if (e.repeat) return;
      if (pressedKeys.current.has(key)) return;
      const note = keyboardBaseNote.current + semi;
      if (note < 0 || note > 127) return;
      pressedKeys.current.set(key, note);
      post({ type: 'kbdNote', note, on: true });
      // In the instrument tab keys PLAY the synth — don't re-steer the Lyria scale.
      if (engineModeRef.current === 'lyria' && mainTabRef.current !== 'instrument') {
        selectLyriaScaleRef.current(note);
      }
    };

    const handleUp = (e: KeyboardEvent) => {
      const key = e.key.toLowerCase();
      const note = pressedKeys.current.get(key);
      if (note === undefined) return;
      pressedKeys.current.delete(key);
      post({ type: 'kbdNote', note, on: false });
    };

    // Release held notes when window loses focus (otherwise stuck notes).
    const handleBlur = () => {
      pressedKeys.current.forEach((note) => {
        post({ type: 'kbdNote', note, on: false });
      });
      pressedKeys.current.clear();
    };

    window.addEventListener('keydown', handleDown);
    window.addEventListener('keyup', handleUp);
    window.addEventListener('blur', handleBlur);
    return () => {
      window.removeEventListener('keydown', handleDown);
      window.removeEventListener('keyup', handleUp);
      window.removeEventListener('blur', handleBlur);
      handleBlur();
    };
  }, [keyboardMidiEnabled]);

  // ─── Render ─────────────────────────────────────────────────────────────

  const keyboardStartNote = keyboardMidiEnabled ? 60 : 48;
  const keyboardEndNote = keyboardMidiEnabled ? 76 : 72;
  const noModel = !modelName || modelName === 'No model loaded';
  const liveFxSliders: Array<{ key: PerformanceKey; label: string; value: number }> = [
    { key: 'drive', label: 'Drive', value: performance.drive },
    { key: 'delayMix', label: 'Delay', value: performance.delayMix },
    { key: 'delayFeedback', label: 'Feedback', value: performance.delayFeedback },
    { key: 'reverbMix', label: 'Reverb', value: performance.reverbMix },
    { key: 'limiter', label: 'Limiter', value: performance.limiter },
    { key: 'crush', label: 'Crush', value: performance.crush },
    { key: 'stereoWidth', label: 'Width', value: performance.stereoWidth },
    { key: 'tone', label: 'Tone', value: performance.tone },
    { key: 'tremolo', label: 'Tremolo', value: performance.tremolo },
    { key: 'outGain', label: 'Gain', value: performance.outGain },
  ];

  // Lyria live-steering content — shown in the right panel's GEN tab (cloud mode).
  const lyriaGenerateContent = (
    <>
      <div className="jam-lyria-knobs">
        {([
          { key: 'density', label: 'Density', value: lyriaParams.density },
          { key: 'brightness', label: 'Bright', value: lyriaParams.brightness },
          { key: 'temperature', label: 'Temp', value: lyriaParams.temperature },
          { key: 'guidance', label: 'Guide', value: lyriaParams.guidance },
        ] as const).map(item => (
          <div
            className="jam-effect-knob"
            key={item.key}
            role="slider"
            tabIndex={0}
            aria-label={item.label}
            aria-valuemin={0}
            aria-valuemax={100}
            aria-valuenow={Math.round(item.value * 100)}
            title={`${item.label}: ${Math.round(item.value * 100)}`}
            onWheel={(e) => {
              e.preventDefault();
              e.stopPropagation();
              const d = Math.max(-0.04, Math.min(0.04, -e.deltaY * 0.001));
              setLyriaParam(item.key, item.value + (e.shiftKey ? d * 2.5 : d));
            }}
            onKeyDown={(e) => {
              if (e.key !== 'ArrowUp' && e.key !== 'ArrowDown') return;
              e.preventDefault();
              setLyriaParam(item.key, item.value + (e.key === 'ArrowUp' ? 1 : -1) * (e.shiftKey ? 0.05 : 0.01));
            }}
          >
            <div
              className="jam-knob-dial"
              style={{
                '--knob-pct': `${item.value * 75}%`,
                '--knob-rotation': `${-135 + item.value * 270}deg`,
              } as React.CSSProperties}
            >
              <span className="jam-knob-pointer" />
            </div>
            <span className="jam-effect-label">{item.label}</span>
            <span className="jam-effect-value">{Math.round(item.value * 100)}</span>
          </div>
        ))}
      </div>
      <div className="jam-lyria-mutes">
        <button className={`jam-mute-btn ${muteBass ? 'is-on' : ''}`} onClick={() => toggleLyriaMute('bass')}>
          mute bass
        </button>
        <button className={`jam-mute-btn ${muteDrums ? 'is-on' : ''}`} onClick={() => toggleLyriaMute('drums')}>
          mute drums
        </button>
      </div>
    </>
  );

  // XY pad dot position + readout for the active mode
  const padPos = padMode === 'filter'
    ? filterPadPos
    : { x: padXFromTemp(paramsState.temperature), y: padYFromTopk(paramsState.topk) };
  const padCutoffHz = 80 * Math.pow(18000 / 80, filterXFromPad(filterPadPos.x));
  const padCutoffLabel = padCutoffHz >= 1000
    ? `${(padCutoffHz / 1000).toFixed(1)}k`
    : `${Math.round(padCutoffHz)}`;
  const padResPct = Math.round(filterYFromPad(filterPadPos.y) * 100);
  const padReadout = padMode === 'prob'
    ? `T: ${paramsState.temperature.toFixed(2)} | K: ${Math.round(paramsState.topk)}`
    : `${padCutoffLabel}Hz | Q: ${padResPct}%`;

  // Current preset list for the rocker display
  const currentPresetList = getActivePresetList(isSoloMode);

  // Determine if the user has modified the prompt relative to the saved preset
  const savedPresetText = currentPresetList[rockerIndex] ?? '';
  const promptIsDirty = isPromptEdited && promptText.trim() !== '' && promptText !== savedPresetText;
  const committedPromptLabel = isAudioPrompt ? 'Audio prompt loaded' : (promptText || 'just type');
  const activeModeLabel = promptMode.toUpperCase();

  // Shrink the big single-prompt text as it gets longer; short text keeps the
  // responsive CSS clamp. undefined = leave the stylesheet's clamp in charge.
  const singleFontSize = (text: string): string | undefined => {
    const len = (text || '').trim().length;
    if (len <= 12) return undefined;
    return `${Math.max(22, Math.min(76, Math.round(880 / len)))}px`;
  };

  /** Enter single/solo edit mode, prefilling the box with the current prompt. */
  const beginSingleEdit = () => {
    setDraftText(isAudioPrompt ? '' : promptText);
    setIsPromptEditing(true);
  };

  /** Grow the single-prompt textarea to fit its content (no inner scrollbar). */
  const autoGrowSingle = (el: HTMLTextAreaElement) => {
    el.style.height = 'auto';
    el.style.height = `${el.scrollHeight}px`;
  };

  // ── Mix chip editing (real <input> per slot: native paste/selection) ──────
  const mixInputRefs = useRef<(HTMLInputElement | null)[]>([]);
  const isMixEditingIndex = (i: number) =>
    isPromptEditing && promptMode === 'mix' && mixLayout !== 'surface' && focusedMixIndex === i;
  /** Focus a chip's text input, prefilled with its current prompt. */
  const beginMixEdit = (index: number) => {
    setPromptMode('mix');
    setFocusedMixIndex(index);
    setDraftText(mixPrompts[index]?.text ?? '');
    setIsPromptEdited(false);
    setIsPromptEditing(true);
  };
  /** Commit the focused chip's draft text and leave edit mode. */
  const commitMixEdit = () => {
    commitDraftText();
    setIsPromptEditing(false);
  };
  // When a chip enters edit mode, focus + select its input so typing/paste replaces.
  useEffect(() => {
    if (!isPromptEditing || promptMode !== 'mix' || mixLayout === 'surface') return;
    const el = mixInputRefs.current[focusedMixIndex];
    if (el) { el.focus(); el.select(); }
  }, [isPromptEditing, focusedMixIndex, promptMode, mixLayout]);
  const totalMixWeight = mixPrompts.reduce((sum, item) => sum + (item.enabled ? item.weight : 0), 0) || 1;
  const mixPositions = getMixPositions(mixLayout);
  const normalizedMixPrompts = mixPrompts.map(item => ({
    ...item,
    displayWeight: item.enabled ? Math.round((item.weight / totalMixWeight) * 100) : 0,
  }));
  const weightedCenter = normalizedMixPrompts.reduce((acc, item, index) => {
    if (!item.enabled) return acc;
    const pos = mixPositions[index];
    const weight = item.weight / totalMixWeight;
    return {
      x: acc.x + pos.x * weight,
      y: acc.y + pos.y * weight,
    };
  }, { x: 0, y: 0 });

  // DJ 'standard' layout: crossfade position between deck A (slot 1) and deck B (slot 2)
  const deckA = mixPrompts[0];
  const deckB = mixPrompts[1];
  const xfadeTotal = (deckA.enabled ? deckA.weight : 0) + (deckB.enabled ? deckB.weight : 0);
  const xfade = xfadeTotal > 0 ? (deckB.enabled ? deckB.weight : 0) / xfadeTotal : 0.5;

  // Tab style helper for the Solo/Jam switcher
  const modeTabStyle = (active: boolean): React.CSSProperties => ({
    height: '100%',
    padding: '0 24px',
    borderRadius: '6px',
    fontSize: '14px',
    fontWeight: 400,
    fontFamily: "'Google Sans', system-ui, sans-serif",
    letterSpacing: '0.5px',
    textTransform: 'none',
    background: active ? '#36373A' : 'transparent',
    color: active ? activeColor : 'rgba(255, 255, 255, 0.45)',
    transition: 'all 0.15s ease',
    border: 'none',
    outline: 'none',
    cursor: 'pointer',
    whiteSpace: 'nowrap',
  });

  // Lyria mode streams from the cloud — no local model required to play.
  const playDisabled = engineMode === 'local' && noModel;

  const playButton = (
    <IconButton
      onClick={playDisabled ? undefined : togglePlay}
      disabled={playDisabled}
      sx={{
        width: 63,
        height: 44,
        borderRadius: '8px',
        backgroundColor: 'var(--play-bg, #FFF)',
        color: 'var(--play-fg, #000)',
        borderBottom: '1.5px solid var(--play-edge, #ddd)',
        transition: 'opacity 0.15s ease',
        '&:hover': {
          backgroundColor: 'var(--play-bg, #FFF)',
          color: 'var(--play-fg, #000)',
          opacity: 0.9,
        },
        '&.Mui-disabled': {
          backgroundColor: 'rgba(255, 255, 255, 0.3)',
          color: 'rgba(0, 0, 0, 0.3)',
        },
      }}
      title={isPlaying ? 'Pause' : 'Play'}
    >
      {isPlaying ? (
        <Pause sx={{ fontSize: 24 }} />
      ) : (
        <PlayArrow sx={{ fontSize: 24 }} />
      )}
    </IconButton>
  );

  return (
    <div
      className="jam-root"
      style={{
        height: '100vh',
        width: '100vw',
        display: 'flex',
        flexDirection: 'column',
        overflow: 'hidden',
        boxSizing: 'border-box',
        fontFamily: "'Google Sans Text', system-ui, sans-serif",
      }}
    >
      {calibration.active && (
        <div className="jam-calib-overlay">
          <div className="jam-calib-card">
            <div className="jam-calib-title">输出校准 · CALIBRATION</div>
            <div className="jam-calib-sub">
              {calibration.channels ? `${calibration.channels} 通道设备` : '输出设备'}已切换 ·
              正在播放 120 BPM 校准 click
            </div>
            {calibration.measuring ? (
              <div className="jam-calib-measuring">
                <span className="jam-calib-spinner" />
                正在测量设备真实速率…（约 2 秒）
              </div>
            ) : (
              <div className="jam-calib-result">
                <div className="jam-calib-row">
                  <span>实测速率</span>
                  <strong>{calibration.effectiveRate ?? '—'} Hz</strong>
                </div>
                <div className="jam-calib-row">
                  <span>速度补偿</span>
                  <strong>×{(calibration.comp ?? 1).toFixed(4)}</strong>
                </div>
                <div className="jam-calib-hint">
                  请用你的设备 / 其他乐器核对:click 是否为稳定的 120 BPM。
                  确认无误后再开始演出。
                </div>
              </div>
            )}
            <div className="jam-calib-actions">
              <button
                className="jam-calib-recal"
                onClick={() => post({ type: 'startCalibration' })}
              >
                重新校准
              </button>
              <button
                className="jam-calib-ok"
                disabled={calibration.measuring}
                onClick={() => post({ type: 'calibrationDone' })}
              >
                {calibration.measuring ? '测量中…' : '校准完成 · 开始演出'}
              </button>
            </div>
          </div>
        </div>
      )}
      <div className="jam-app-shell">
        <div className="jam-topbar">
          <div className="jam-topbar-left">
            <div className="jam-mode-switch jam-main-tabs" aria-label="Main view">
              <button
                className={mainTab === 'jam' ? 'is-active' : ''}
                onClick={() => setMainTab('jam')}
              >
                jam
              </button>
              <button
                className={mainTab === 'instrument' ? 'is-active' : ''}
                onClick={() => setMainTab('instrument')}
              >
                instrument
              </button>
              <button
                className={mainTab === 'pgm' ? 'is-active' : ''}
                onClick={() => setMainTab('pgm')}
              >
                pgm
              </button>
            </div>
            <ModelSelector
              modelName={modelName}
              localModels={localModels}
              remoteModels={remoteModels}
              downloadProgress={downloadProgress}
              onSelectModel={(m) => post({ type: 'selectModel', name: m })}
              onDownloadModel={(m) => post({ type: 'downloadModel', name: m })}
              onDeleteModel={(m) => post({ type: 'deleteModel', name: m })}
              onSelectFolder={() => post({ type: 'selectDownloadFolder' })}
              buttonSx={{
                color: '#FFF',
                border: '1px solid rgba(255, 255, 255, 0.12)',
                background: 'rgba(255, 255, 255, 0.035)',
                '&:hover': { background: 'rgba(255, 255, 255, 0.12)' },
              }}
            />
          </div>
          <div className="jam-engine-switch">
            <div className="jam-mode-switch" aria-label="Engine">
              <button
                className={engineMode === 'local' ? 'is-active' : ''}
                onClick={() => switchEngine('local')}
              >
                local
              </button>
              <button
                className={engineMode === 'lyria' ? 'is-active' : ''}
                onClick={() => switchEngine('lyria')}
              >
                lyria
              </button>
            </div>
            {engineMode === 'lyria' && (
              <span className={`jam-lyria-status ${lyriaStatus.startsWith('error') ? 'is-error' : ''}`}>
                {lyriaStatus}
              </span>
            )}
            {engineMode === 'lyria' && (
              <div
                className="jam-lyria-lights"
                title="Cloud stream channels — steady = playing, fast blink = warming up"
              >
                {lyriaChannels.map((s, i) => (
                  <span key={i} className={`jam-lyria-light is-${s}`} title={`ch${i}: ${s}`} />
                ))}
              </div>
            )}
          </div>
          <div className="jam-topbar-right">
            <button
              className={`jam-chat-button ${liveMode ? 'is-live' : ''}`}
              title="现场模式：阻止电脑休眠与屏幕锁屏（演出时开启）"
              onClick={() => { const on = !liveMode; setLiveMode(on); post({ type: 'liveMode', on }); }}
            >
              {liveMode ? '● 现场' : '现场'}
            </button>
            <TimingIndicator
              frameMs={metrics.frameMs}
              droppedFrames={metrics.droppedFrames}
              buffersize={paramsState.buffersize}
              onBufferChange={(v) => sendParamChange(8, v)}
              buttonSx={{
                color: '#FFF',
                '&:hover': { background: 'rgba(255, 255, 255, 0.12)' },
              }}
              isPlaying={isPlaying}
            />
            <button
              className="jam-chat-button"
              title="Switch UI theme"
              onClick={cycleTheme}
            >
              {uiTheme}
            </button>
            <button
              className={`jam-chat-button ${isCheatOpen ? 'is-active' : ''}`}
              title="Prompt cheat sheet"
              onClick={() => setIsCheatOpen(o => !o)}
            >
              Cheats
            </button>
            <button
              className={`jam-chat-button ${isChatOpen ? 'is-active' : ''}`}
              title="AI prompt chat"
              onClick={() => setIsChatOpen(o => !o)}
            >
              Chat
            </button>
          </div>
        </div>

        {mainTab === 'pgm' && (
          <StudioPanel
            studio={studio}
            onLoadSong={() => post({ type: 'studioLoadSong' })}
            onLoadPgm={() => post({ type: 'studioLoadPgm' })}
            onSeparate={() => post({ type: 'studioSeparate' })}
            onSepPipeline={(mode) => {
              setStudio(st => ({ ...st, sepPipeline: mode }));
              post({ type: 'sepPipeline', mode });
            }}
            onSongToggle={studioSongToggle}
            onTransport={studioTransport}
            onCountIn={(beats) => {
              setStudio(st => ({ ...st, countIn: beats }));
              post({ type: 'studioCountIn', beats });
            }}
            onClick={(on) => {
              setStudio(st => ({ ...st, click: on }));
              post({ type: 'studioClick', on });
            }}
            onClickGain={(value) => {
              setStudio(st => ({ ...st, clickGain: value }));
              post({ type: 'studioClickGain', value });
            }}
            onCue={(action, sec) => post({ type: 'studioCue', action, sec: sec ?? -1 })}
            onBpm={(bpm) => { setStudio(st => ({ ...st, bpm })); post({ type: 'studioBpm', bpm }); }}
            onKey={(key) => { setStudio(st => ({ ...st, key })); post({ type: 'studioKey', key }); }}
            onMemo={(text) => { setStudio(st => ({ ...st, memo: text })); post({ type: 'studioMemo', text }); }}
            onTimeSig={(beats) => { setStudio(st => ({ ...st, timeSig: beats })); post({ type: 'studioTimeSig', beats }); }}
            onRoute={(patch) => {
              setStudio(st => {
                const next = {
                  ...st,
                  routeMain: patch.main ?? st.routeMain,
                  routeClick: patch.click ?? st.routeClick,
                };
                post({ type: 'audioRoute', main: next.routeMain, click: next.routeClick });
                return next;
              });
            }}
            onMultichannel={(on) => {
              setStudio(st => ({ ...st, multichannel: on }));
              post({ type: 'audioMultichannel', on });
            }}
            onMix={studioMix}
            onSeek={studioSeek}
            onImportStem={(i) => post({ type: 'studioImportStem', index: i })}
            onTranscribe={(i) => post({ type: 'studioTranscribe', index: i })}
            onExtractStem={(i) => post({ type: 'studioExtractStem', index: i })}
            onStemAlign={(i, action) => post({ type: 'studioStemAlign', index: i, action })}
            onStemAlignSet={(i, ms) => post({ type: 'studioStemAlignSet', index: i, ms })}
            onStemDry={(i, value) => {
              setStudio(st => ({ ...st, stems: st.stems.map((x, k) => k === i ? { ...x, dry: value } : x) }));
              post({ type: 'studioStemDry', index: i, value });
            }}
            onDetectChords={() => post({ type: 'studioDetectChords' })}
            onLaneSource={(idx, src) => {
              post({ type: 'laneSource', index: idx, source: src === 'midi' ? 1 : 0 });
            }}
            patchOptions={[
              ...synthPresets.map(p => ({ name: p.name, category: '我的音色' })),
              ...FACTORY_PRESETS.map(p => ({ name: p.name, category: p.category })),
            ]}
            onLanePatch={(idx, name) => {
              const p = synthPresets.find(x => x.name === name)
                     ?? FACTORY_PRESETS.find(x => x.name === name);
              if (!p) return;
              post({
                type: 'lanePatch', index: idx, name: p.name, origin: 'factory',
                params: { ...DEFAULT_SYNTH, ...p.params },
                matrix: Array.isArray(p.matrix) && p.matrix.length === 25
                  ? p.matrix : Array(25).fill(0),
              });
            }}
            onLaneAiPatch={(idx, userText) => {
              const role: Record<number, string> = {
                1: 'bass — a mono stage bass that locks tight with the kick',
                2: 'harmonic backing — a wide warm pad that fills the mids without masking vocals',
                3: 'vocal melody substitute — an expressive mono lead with vibrato',
                4: 'guitar — a plucked/strummed character with quick decay',
                5: 'piano/keys — percussive keys with a clean attack',
              };
              let ctx = `Song: "${studio.name}", key ${studio.key || 'unknown'}, ` +
                `${studio.bpm || '?'} BPM. Design a patch for the ` +
                `${studio.stems[idx]?.name} stem of this live show: ${role[idx]}. ` +
                `It must sit in a live mix alongside the original stems.`;
              if (userText) {
                ctx += ` THE USER'S OWN SOUND REQUEST (takes priority over the ` +
                  `role defaults above): ${userText}`;
              }
              setAiLaneBusy(idx);
              post({ type: 'aiPatch', value: ctx, lane: idx });
            }}
            aiLaneBusy={aiLaneBusy}
            onLaneEngine={(idx, engine) => {
              // Optimistic toggle; native confirms via studioLanes.
              setStudio(st => ({
                ...st,
                stems: st.stems.map((x, i) => i === idx ? { ...x, engine } : x),
              }));
              post({ type: 'laneEngine', index: idx, engine: engine === 'sf2' ? 1 : 0 });
            }}
            onLaneSfProgram={(idx, program) => {
              setStudio(st => ({
                ...st,
                stems: st.stems.map((x, i) => i === idx ? { ...x, sfProgram: program } : x),
              }));
              post({ type: 'laneSfProgram', index: idx, program });
            }}
            onLaneFx={(idx, patch) => {
              setStudio(st => ({
                ...st,
                stems: st.stems.map((x, i) => i === idx
                  ? {
                      ...x,
                      fxReverb: patch.reverb ?? x.fxReverb,
                      fxEcho: patch.echo ?? x.fxEcho,
                    }
                  : x),
              }));
              post({ type: 'laneFx', index: idx, ...patch });
            }}
            onLaneClear={(idx) => post({ type: 'laneClear', index: idx })}
            clip={studioClip}
            onClipOpen={(idx) => {
              setStudioClip({ index: idx, notes: [] });   // open; notes arrive async
              post({ type: 'laneClipGet', index: idx });
            }}
            onClipApply={(idx, notes) => {
              post({ type: 'laneClipSet', index: idx, notes });
            }}
            onClipClose={() => setStudioClip(null)}
            onClipRegen={(idx) => {
              clipRegenPendingRef.current = idx;
              post({ type: 'laneRegen', index: idx });
            }}
            onClipAiCompose={(idx, prompt, mode) => {
              const st = studioRef.current;
              const beat = 60 / Math.max(40, st.bpm || 120);
              const toBeat = (sec: number) => (sec / beat).toFixed(1);
              let ctx = buildSongContext(st, idx, beat, toBeat);
              if (mode === 'continue') {
                ctx += `CONTINUE MODE: write only notes with start_beat >= ` +
                  `${toBeat(st.playhead.pos)} (the current playhead).\n`;
              }
              ctx += `User request: ${prompt || '为这条轨写一段合适的乐句'}`;
              composeModeRef.current = mode;
              setComposeBusy(true);
              setComposeError(null);
              post({ type: 'aiCompose', value: ctx, lane: idx });
            }}
            onClipAiOptimize={(idx, notes) => {
              const st = studioRef.current;
              const beat = 60 / Math.max(40, st.bpm || 120);
              const toBeat = (sec: number) => (sec / beat).toFixed(1);
              const stem = st.stems[idx];
              const cap = 500;
              const ser = notes.slice(0, cap).map(([s, d, p, v]) =>
                `[${(s / beat).toFixed(2)},${(d / beat).toFixed(2)},${p},${v.toFixed(2)}]`).join(',');
              let ctx = buildSongContext(st, idx, beat, toBeat);
              ctx += `EXISTING NOTES to IMPROVE (beat,dur_beats,pitch,vel): [${ser}]` +
                (notes.length > cap ? ` (+${notes.length - cap} more omitted)` : '') + '\n';
              ctx += `TASK: clean up this transcribed clip for ${stem?.name}. Quantize timing ` +
                `to the groove, fix dissonant pitches to chord tones, and especially repair ` +
                `BROKEN/STACCATO notes into smooth SUSTAINED LEGATO phrasing idiomatic for this ` +
                `instrument and the song's style — held accompaniment notes should ring until ` +
                `the chord changes. Preserve the original musical intent, register and rhythmic ` +
                `feel; do NOT rewrite it into something new. Return the full improved note list.`;
              composeModeRef.current = 'all';
              setComposeBusy(true);
              setComposeError(null);
              post({ type: 'aiCompose', value: ctx, lane: idx });
            }}
            onClipAiRange={(idx, notes, startSec, endSec) => {
              const st = studioRef.current;
              const beat = 60 / Math.max(40, st.bpm || 120);
              const toBeat = (sec: number) => (sec / beat).toFixed(2);
              const win = 8 * beat;   // 8 beats of context each side
              const ser = (ns: typeof notes) => ns.map(([s0, d, p, v]) =>
                `[${(s0 / beat).toFixed(2)},${(d / beat).toFixed(2)},${p},${v.toFixed(2)}]`).join(',');
              const before = notes.filter(n => n[0] < startSec && n[0] >= startSec - win);
              const after = notes.filter(n => n[0] >= endSec && n[0] < endSec + win);
              const inside = notes.filter(n => n[0] >= startSec - 1e-3 && n[0] < endSec);
              let ctx = buildSongContext(st, idx, beat, toBeat);
              ctx += `REWRITE RANGE: beats ${toBeat(startSec)}..${toBeat(endSec)}.
` +
                `Context BEFORE the range (keep, for continuity): [${ser(before)}]
` +
                `Context AFTER the range (keep, for continuity): [${ser(after)}]
` +
                `Current notes inside the range (replace these): [${ser(inside)}]
` +
                `TASK: rewrite ONLY the notes inside the range. Stay musically ` +
                `consistent with the before/after context (motif, rhythm, register, ` +
                `density) and follow the chord timeline. Make the boundaries flow ` +
                `naturally into the surrounding material. Return notes ONLY within ` +
                `beats ${toBeat(startSec)}..${toBeat(endSec)}.`;
              composeModeRef.current = 'range';
              setComposeBusy(true);
              setComposeError(null);
              post({ type: 'aiCompose', value: ctx, lane: idx });
            }}
            composeBusy={composeBusy}
            composeError={composeError}
            composeResult={composeResult}
            onPackage={() => post({ type: 'studioPackage' })}
            onSepDownload={() => post({ type: 'studioSepDownload' })}
            onSepPick={() => post({ type: 'studioSepPick' })}
          />
        )}

        {mainTab === 'instrument' && (
          <InstrumentPanel
            synth={synthParams}
            matrix={synthMatrix}
            onParam={setSynthParam}
            onMatrix={setMatrixCell}
            onDice={() => post({ type: 'synthDice' })}
            patchName={patchName}
            onPatchName={setPatchName}
            presets={synthPresets}
            factory={FACTORY_PRESETS}
            onSavePreset={saveSynthPreset}
            onLoadPreset={loadSynthPreset}
            onDeletePreset={deleteSynthPreset}
            octaveOffset={octaveOffset}
            onOctave={(dir) => (dir < 0 ? handleOctaveDown() : handleOctaveUp())}
            bpm={bpmValue}
            bpmStatus={bpmStatus}
            bpmDetecting={bpmDetecting}
            onDetectBpm={detectBpm}
            aiBusy={aiPatchBusy}
            aiError={aiPatchError}
            onAiPatch={requestAiPatch}
            followJam={instrumentFollowJam}
            onFollowJam={(on) => {
              setInstrumentFollowJam(on);
              post({ type: 'instrumentFollowJam', value: on });
            }}
          />
        )}

        <div className={`jam-main-grid${mainTab !== 'jam' ? ' is-tab-hidden' : ''}`}>
          <section className="jam-prompt-panel">
            <div className="jam-prompt-head">
              <div className="jam-prompt-titlebar">
                <div className="jam-section-label">Text Prompt</div>
                <div className="jam-prompt-status">
                  <span className="jam-active-dot" />
                  Active
                </div>
                <div className="jam-head-actions">
                  {isProgressActive && <CircularProgress size={15} sx={{ color: 'rgba(255, 255, 255, 0.64)' }} />}
                  {isAudioPrompt ? (
                    <Tooltip title="Remove audio prompt" placement="top">
                      <IconButton variant="jam" onClick={clearAudioPrompt} sx={{ width: 32, height: 32 }}>
                        <Close sx={{ fontSize: 16 }} />
                      </IconButton>
                    </Tooltip>
                  ) : (
                    <>
                      <Tooltip title="Upload audio prompt" placement="top">
                        <IconButton variant="jam" onClick={loadAudioPrompt} sx={{ width: 32, height: 32 }}>
                          <UploadFile sx={{ fontSize: 16 }} />
                        </IconButton>
                      </Tooltip>
                      <Tooltip title={recordingState === 'recording' ? 'Stop recording' : 'Record audio prompt (10s)'} placement="top">
                        <IconButton
                          variant="jam"
                          onClick={toggleRecordAudioPrompt}
                          sx={{
                            width: 32,
                            height: 32,
                            color: recordingState === 'recording' ? '#ff4f6b' : undefined,
                          }}
                        >
                          {recordingState === 'recording'
                            ? <Stop sx={{ fontSize: 16 }} className="jam-rec-pulse" />
                            : <Mic sx={{ fontSize: 16 }} />}
                        </IconButton>
                      </Tooltip>
                    </>
                  )}
                  <IconButton variant="jam" onClick={() => setIsSettingsOpen(true)} sx={{ width: 32, height: 32 }}>
                    <TuneIcon sx={{ fontSize: 16 }} />
                  </IconButton>
                </div>
              </div>
              <div className="jam-prompt-toolbar">
                <div className="jam-prompt-toolset">
                  <button className="jam-mini-button" onClick={resetModel}>Reset</button>
                  <button className="jam-mini-button" title="Export the current jam session to a file" onClick={exportSession}>export</button>
                  <button className="jam-mini-button" title="Import a jam session from a file" onClick={importSession}>import</button>
                  {sessionNotice && <span className="jam-session-notice">{sessionNotice}</span>}
                  <button
                    className={`jam-mini-button ${visualMode !== 'off' ? 'is-active' : ''}`}
                    title="Audio-reactive visual layer"
                    onClick={() => setVisualMode(m => (m === 'off' ? 'bg' : 'off'))}
                  >
                    visual
                  </button>
                  {visualMode !== 'off' && (
                    <>
                      <button
                        className="jam-mini-button"
                        title="Cycle visual preset"
                        onClick={() => setVisualPreset(p => (p + 1) % VISUAL_PRESETS.length)}
                      >
                        {VISUAL_PRESETS[visualPreset]}
                      </button>
                      <button
                        className="jam-mini-button"
                        title="Upload an image for particle / stretch / glitch effects"
                        onClick={() => post({ type: 'loadVisualImage' })}
                      >
                        {visualImage ? 'image ✓' : '+ image'}
                      </button>
                      <button
                        className="jam-mini-button"
                        title="Fullscreen visuals (click or Esc to exit)"
                        onClick={() => setVisualMode('full')}
                      >
                        full
                      </button>
                    </>
                  )}
                  {promptMode === 'mix' && (
                    <>
                      {(['standard', 'circle', 'surface'] as MixLayoutMode[]).map(layout => (
                        <button
                          key={layout}
                          className={`jam-mini-button ${mixLayout === layout ? 'is-active' : ''}`}
                          onClick={() => {
                            setMixLayout(layout);
                            if (layout === 'standard') setFocusedMixIndex(i => (i > 1 ? 0 : i));
                            if (layout === 'surface') {
                              // Initial layout (and its send) happens lazily on
                              // first show; afterwards re-send the node weights.
                              if (surfaceInitialized.current) sendSurfacePrompts();
                            } else {
                              sendMixPrompts(layoutSendList(mixPrompts, layout), true);
                            }
                          }}
                        >
                          {layout === 'standard' ? 'dj' : layout}
                        </button>
                      ))}
                    </>
                  )}
                </div>
                <div className="jam-mode-switch" aria-label="Prompt mode">
                  {(['single', 'mix', 'solo'] as PromptMode[]).map(mode => (
                    <button
                      key={mode}
                      className={promptMode === mode ? 'is-active' : ''}
                      onClick={() => handleModeChange(mode)}
                    >
                      {mode}
                    </button>
                  ))}
                </div>
              </div>
            </div>

            <div
              ref={promptSurfaceRef}
              className={`jam-prompt-canvas is-${promptMode} is-mix-layout-${mixLayout} ${isPromptEditing ? 'is-editing' : ''}`}
              tabIndex={promptMode === 'mix' || isPromptEditing ? 0 : -1}
              role="textbox"
              aria-label={`${activeModeLabel} prompt surface`}
              onKeyDown={handlePromptSurfaceKeyDown}
              onPaste={handlePromptSurfacePaste}
              onBlur={() => {
                if (promptMode === 'single' || promptMode === 'solo') {
                  setIsPromptEditing(false);
                }
              }}
            >
              {visualMode === 'bg' && (
                <VisualLayer
                  mode="bg"
                  accent={activeColor}
                  bpm={bpmValue}
                  beatActive={bpmLock}
                  preset={visualPreset}
                  imageSrc={visualImage}
                  dataRef={visualDataRef}
                  onExitFull={() => setVisualMode('bg')}
                />
              )}
              {(promptMode === 'single' || promptMode === 'solo') && (
                <div className="jam-single-prompt">
                  <div className="jam-single-kicker">{activeModeLabel}</div>
                  {isPromptEditing ? (
                    <textarea
                      className="jam-single-text jam-single-input"
                      style={{ color: activeColor, fontSize: singleFontSize(draftText) }}
                      value={draftText}
                      autoFocus
                      spellCheck={false}
                      rows={1}
                      placeholder="type or paste a prompt"
                      onFocus={(e) => autoGrowSingle(e.currentTarget)}
                      onChange={(e) => { setDraftText(e.target.value); setIsPromptEdited(true); autoGrowSingle(e.currentTarget); }}
                      onKeyDown={(e) => {
                        if (e.key === 'Enter' && !e.shiftKey && !isComposingKey(e)) {
                          e.preventDefault();
                          commitDraftText();
                        } else if (e.key === 'Escape') {
                          e.preventDefault();
                          setDraftText('');
                          setIsPromptEditing(false);
                        }
                      }}
                      onBlur={() => { setDraftText(''); setIsPromptEditing(false); }}
                    />
                  ) : (
                    <button
                      className="jam-single-text"
                      style={{ color: activeColor, fontSize: singleFontSize(committedPromptLabel) }}
                      onMouseDown={(e) => { e.preventDefault(); beginSingleEdit(); }}
                    >
                      {committedPromptLabel}
                    </button>
                  )}
                  <div className="jam-prompt-hint">{isPromptEditing ? 'Enter to apply · Esc to cancel' : 'click to edit · keyboard plays'}</div>
                  <div className="jam-corner jam-corner-tl" />
                  <div className="jam-corner jam-corner-br" />
                </div>
              )}

              {promptMode === 'mix' && mixLayout === 'surface' && (
                <div className="jam-surface-host" ref={surfaceHostRef}>
                  <PromptSurface
                    prompts={surfacePrompts}
                    listener={surfaceListener}
                    selectedBallId={surfaceSelectedId}
                    onPromptMove={handleSurfacePromptMove}
                    onListenerMove={handleSurfaceListenerMove}
                    onBallSelect={setSurfaceSelectedId}
                    onPromptAdd={handleSurfaceAdd}
                    onPromptTextChange={handleSurfaceTextChange}
                    onPromptDelete={handleSurfaceDelete}
                    physicsSpeed={surfacePhysicsSpeed}
                    onFirstThrow={() => {}}
                    isPlaying={isPlaying}
                    audioLevel={(audioLevels.left + audioLevels.right) / 2}
                    collisions
                  />
                  <div className="jam-surface-controls">
                    <Turtle style={{ width: 16, height: 16, flexShrink: 0 }} color="rgba(255,255,255,0.7)" strokeWidth={1.5} />
                    <input
                      type="range"
                      min="0"
                      max="1"
                      step="0.005"
                      value={surfaceSliderPos}
                      onChange={(e) => setSurfaceSliderPos(parseFloat(e.target.value))}
                    />
                    <Rabbit style={{ width: 16, height: 16, flexShrink: 0 }} color="rgba(255,255,255,0.7)" strokeWidth={1.5} />
                    <button
                      className="jam-mini-button"
                      title="Add prompt (or double-click empty space)"
                      onClick={handleSurfaceAddRandom}
                      disabled={surfacePrompts.length >= MAX_SURFACE_PROMPTS}
                    >
                      + add
                    </button>
                  </div>
                </div>
              )}

              {promptMode === 'mix' && mixLayout !== 'surface' && (
                <div
                  className="jam-mix-map"
                  onPointerDown={(e) => {
                    e.currentTarget.setPointerCapture(e.pointerId);
                    updateMixWeightsFromPointer(e);
                  }}
                  onPointerMove={(e) => {
                    if (e.buttons !== 1) return;
                    updateMixWeightsFromPointer(e);
                  }}
                >
                  {mixLayout !== 'standard' && (
                    <>
                      <svg className="jam-mix-lines" viewBox="0 0 100 100" preserveAspectRatio="none" aria-hidden="true">
                        {normalizedMixPrompts.map((item, index) => {
                          if (!item.enabled) return null;
                          const pos = mixPositions[index];
                          return (
                            <line
                              key={item.id}
                              x1={pos.x}
                              y1={pos.y}
                              x2={weightedCenter.x}
                              y2={weightedCenter.y}
                              stroke={item.color}
                            />
                          );
                        })}
                      </svg>
                      <div
                        className="jam-mix-node"
                        style={{
                          left: `${weightedCenter.x}%`,
                          top: `${weightedCenter.y}%`,
                        }}
                      />
                      {normalizedMixPrompts.map((item, index) => {
                        const pos = mixPositions[index];
                        const focused = index === focusedMixIndex;
                        const label = focused && draftText ? draftText : item.text;
                        return (
                          <button
                            key={item.id}
                            className={`jam-prompt-chip ${focused ? 'is-focused' : ''} ${focused && draftText ? 'is-pending' : ''} ${item.enabled ? '' : 'is-disabled'}`}
                            style={{
                              left: `${pos.x}%`,
                              top: `${pos.y}%`,
                              '--chip-color': item.color,
                              '--line-x': `${weightedCenter.x - pos.x}%`,
                              '--line-y': `${weightedCenter.y - pos.y}%`,
                            } as React.CSSProperties}
                            onClick={(e) => {
                              e.stopPropagation();
                              beginMixEdit(index);
                            }}
                          >
                            <span
                              className="jam-chip-index"
                              title={item.enabled ? 'Disable prompt' : 'Enable prompt'}
                              onClick={(e) => {
                                e.stopPropagation();
                                toggleMixPrompt(index);
                              }}
                            >
                              {item.id}
                            </span>
                            <span className="jam-chip-text">{label}{focused && draftText && <span className="jam-caret" />}</span>
                            <span className="jam-chip-weight">{item.enabled ? `${item.displayWeight}%` : 'off'}</span>
                          </button>
                        );
                      })}
                    </>
                  )}

                  {mixLayout === 'standard' && (
                    <>
                      {/* DJ deck view: two chips, crossfader in the middle */}
                      {[0, 1].map(index => {
                        const item = mixPrompts[index];
                        const focused = index === focusedMixIndex;
                        const label = focused && draftText ? draftText : item.text;
                        const pct = Math.round((index === 0 ? 1 - xfade : xfade) * 100);
                        return (
                          <button
                            key={item.id}
                            className={`jam-prompt-chip is-deck ${focused ? 'is-focused' : ''} ${focused && draftText ? 'is-pending' : ''} ${item.enabled ? '' : 'is-disabled'}`}
                            style={{
                              left: index === 0 ? '14%' : '86%',
                              top: '42%',
                              '--chip-color': item.color,
                            } as React.CSSProperties}
                            onClick={(e) => {
                              e.stopPropagation();
                              beginMixEdit(index);
                            }}
                            onPointerDown={(e) => e.stopPropagation()}
                          >
                            <span
                              className="jam-chip-index"
                              title={item.enabled ? 'Disable prompt' : 'Enable prompt'}
                              onClick={(e) => {
                                e.stopPropagation();
                                toggleMixPrompt(index);
                              }}
                            >
                              {item.id}
                            </span>
                            <span className="jam-chip-text">{label}{focused && draftText && <span className="jam-caret" />}</span>
                            <span className="jam-chip-weight">{item.enabled ? `${pct}%` : 'off'}</span>
                          </button>
                        );
                      })}
                      <div className="jam-xfader" aria-hidden="true">
                        <div
                          className="jam-xfader-track"
                          style={{
                            background: `linear-gradient(90deg, ${deckA.color}, ${deckB.color})`,
                          }}
                        />
                        <div className="jam-xfader-handle" style={{ left: `${xfade * 100}%` }} />
                      </div>
                    </>
                  )}

                  <div className="jam-expand-glyph">open</div>
                  <div className="jam-prompt-hint">
                    {draftText
                      ? 'Enter to apply'
                      : mixLayout === 'standard'
                        ? 'drag to crossfade A / B'
                        : `typing edits slot ${focusedMixIndex + 1}`}
                  </div>
                </div>
              )}
            </div>

            {promptMode === 'mix' && mixLayout !== 'surface' && (
              <div className={`jam-slot-row ${mixLayout === 'standard' ? 'is-dj' : ''}`}>
                {(mixLayout === 'standard' ? normalizedMixPrompts.slice(0, 2) : normalizedMixPrompts).map((item, index) => (
                  <div
                    key={item.id}
                    className={`jam-slot-pill ${index === focusedMixIndex ? 'is-focused' : ''} ${item.enabled ? '' : 'is-disabled'} ${isMixEditingIndex(index) ? 'is-editing' : ''}`}
                    style={{ '--chip-color': item.color } as React.CSSProperties}
                    onClick={() => { if (!isMixEditingIndex(index)) beginMixEdit(index); }}
                  >
                    <span
                      title={item.enabled ? 'Disable prompt' : 'Enable prompt'}
                      onClick={(e) => {
                        e.stopPropagation();
                        toggleMixPrompt(index);
                      }}
                    />
                    {isMixEditingIndex(index) ? (
                      <input
                        ref={(el) => { mixInputRefs.current[index] = el; }}
                        className="jam-slot-input"
                        value={draftText}
                        spellCheck={false}
                        placeholder="type or paste"
                        onClick={(e) => e.stopPropagation()}
                        onChange={(e) => { setDraftText(e.target.value); setIsPromptEdited(true); }}
                        onKeyDown={(e) => {
                          if (e.key === 'Enter' && !isComposingKey(e)) { e.preventDefault(); commitMixEdit(); }
                          else if (e.key === 'Escape') { e.preventDefault(); setDraftText(''); setIsPromptEditing(false); }
                          else if (e.key === 'Tab') {
                            e.preventDefault();
                            const slotCount = mixLayout === 'standard' ? 2 : 6;
                            beginMixEdit((index + (e.shiftKey ? slotCount - 1 : 1)) % slotCount);
                          }
                        }}
                        onBlur={() => commitDraftText()}
                      />
                    ) : (
                      <b>{item.text}</b>
                    )}
                    <em>
                      {!item.enabled
                        ? 'off'
                        : mixLayout === 'standard'
                          ? `${Math.round((index === 0 ? 1 - xfade : xfade) * 100)}%`
                          : `${item.displayWeight}%`}
                    </em>
                  </div>
                ))}
              </div>
            )}
          </section>

          <aside className="jam-side-controls">
            <div className="jam-transport-row">
              <IconButton variant="jam" onClick={handleRockerLeft} sx={{ width: 40, height: 40 }} title="Previous preset">
                <ArrowBack sx={{ fontSize: 18, color: '#FFF' }} />
              </IconButton>
              {playDisabled ? (
                <Tooltip title="No model selected" placement="top">
                  <span>{playButton}</span>
                </Tooltip>
              ) : (
                playButton
              )}
              <IconButton variant="jam" onClick={handleRockerRight} sx={{ width: 40, height: 40 }} title="Next preset">
                <ArrowForward sx={{ fontSize: 18, color: '#FFF' }} />
              </IconButton>
            </div>

            <div className="jam-bpm-row">
              <button
                className={`jam-mini-button ${bpmLock ? 'is-active' : ''}`}
                title="Lock tempo: metronome pulse + bpm appended to prompts"
                onClick={() => setBpmLock(v => !v)}
              >
                bpm lock
              </button>
              <input
                type="text"
                inputMode="numeric"
                value={bpmText}
                disabled={!bpmLock}
                onChange={(e) => setBpmText(e.target.value)}
                onBlur={commitBpmText}
                onKeyDown={(e) => {
                  e.stopPropagation();
                  if (e.key === 'Enter' && !isComposingKey(e)) {
                    commitBpmText();
                    (e.target as HTMLInputElement).blur();
                  }
                }}
              />
              <span>bpm</span>
            </div>

            <div className="jam-performance-panel">
              <div className="jam-performance-head">
                <div className="jam-pad-mode-switch" aria-label="Right panel view">
                  {rightView === 'xy' && (
                    <>
                      <button
                        className={padMode === 'prob' ? 'is-active' : ''}
                        onClick={() => setPadMode('prob')}
                      >
                        Prob
                      </button>
                      <button
                        className={padMode === 'filter' ? 'is-active' : ''}
                        onClick={() => setPadMode('filter')}
                      >
                        Filter
                      </button>
                    </>
                  )}
                  {engineMode === 'lyria' && (
                    <button
                      className={`jam-gen-tab ${rightView === 'gen' ? 'is-active' : ''}`}
                      onClick={() => setRightView(v => (v === 'gen' ? 'xy' : 'gen'))}
                      title="Toggle XY pad / Lyria GENERATE controls"
                    >
                      {rightView === 'gen' ? 'XY Pad' : 'Gen'}
                    </button>
                  )}
                </div>
                <span>{rightView === 'gen' ? 'Generate' : ''}</span>
              </div>

              {rightView === 'gen' ? (
                lyriaGenerateContent
              ) : (
                <>
                  <div
                    ref={xyPadRef}
                    className="jam-xy-pad"
                    style={{
                      '--xy-x': `${padPos.x * 100}%`,
                      '--xy-y': `${(1 - padPos.y) * 100}%`,
                    } as React.CSSProperties}
                    onPointerDown={(e) => {
                      e.currentTarget.setPointerCapture(e.pointerId);
                      setIsPadDragging(true);
                      handleXYPointer(e);
                    }}
                    onPointerMove={(e) => {
                      if (e.buttons !== 1) return;
                      handleXYPointer(e);
                    }}
                    onPointerUp={handlePadRelease}
                    onPointerCancel={handlePadRelease}
                  >
                    <div className="jam-probability-crosshair-x" />
                    <div className="jam-probability-crosshair-y" />
                    <div
                      className={`jam-xy-dot${isPadDragging ? '' : ' is-anim'}`}
                      style={{
                        left: `${padPos.x * 100}%`,
                        top: `${(1 - padPos.y) * 100}%`,
                      }}
                    />
                    <div className="jam-xy-readout">{padReadout}</div>
                  </div>
                  <label className="jam-latch-row">
                    <input
                      type="checkbox"
                      checked={padLatch}
                      onChange={(e) => setPadLatch(e.target.checked)}
                    />
                    latch
                  </label>
                </>
              )}
            </div>

            <div className="jam-performance-panel jam-fx-panel">
              <div className="jam-performance-head">
                <span>FX</span>
                <span>Active</span>
              </div>
              <div className="jam-live-knobs">
                {liveFxSliders.map(item => (
                  <div
                    className="jam-effect-knob"
                    key={item.key}
                    role="slider"
                    tabIndex={0}
                    aria-label={item.label}
                    aria-valuemin={0}
                    aria-valuemax={100}
                    aria-valuenow={Math.round(item.value * 100)}
                    title={`${item.label}: ${Math.round(item.value * 100)}`}
                    onWheel={(e) => {
                      e.preventDefault();
                      e.stopPropagation();
                      const rawDelta = -e.deltaY * 0.001;
                      const cappedDelta = Math.max(-0.04, Math.min(0.04, rawDelta));
                      nudgePerformance(item.key, item.value, e.shiftKey ? cappedDelta * 2.5 : cappedDelta);
                    }}
                    onKeyDown={(e) => {
                      if (e.key !== 'ArrowUp' && e.key !== 'ArrowDown') return;
                      e.preventDefault();
                      nudgePerformance(item.key, item.value, (e.key === 'ArrowUp' ? 1 : -1) * (e.shiftKey ? 0.05 : 0.01));
                    }}
                  >
                    <div
                      className="jam-knob-dial"
                      style={{
                        '--knob-pct': `${item.value * 75}%`,
                        '--knob-rotation': `${-135 + item.value * 270}deg`,
                      } as React.CSSProperties}
                    >
                      <span className="jam-knob-pointer" />
                    </div>
                    <span className="jam-effect-label">{item.label}</span>
                    <span className="jam-effect-value">{Math.round(item.value * 100)}</span>
                  </div>
                ))}
              </div>
            </div>

            <div className="jam-performance-panel jam-punch-panel">
              <div className="jam-performance-head">
                <span>PUNCH</span>
                <span className={punchActive !== null ? 'jam-punch-readout' : ''}>
                  {punchActive !== null
                    ? `${PUNCH_FX_LIST[punchActive].label} ${Math.round(punchAmt * 100)}`
                    : 'hold · drag'}
                </span>
              </div>
              <div className="jam-punch-grid">
                {PUNCH_FX_LIST.map(fx => (
                  <div
                    key={fx.id}
                    className={`jam-punch-pad ${punchActive === fx.id ? 'is-active' : ''}`}
                    style={{
                      '--punch-fill': `${Math.round(
                        (punchActive === fx.id ? punchAmt : (punchMemRef.current[fx.id] ?? 0.6)) * 100,
                      )}%`,
                    } as React.CSSProperties}
                    onPointerDown={(e) => punchDown(fx.id, e)}
                    onPointerMove={(e) => punchMove(fx.id, e)}
                    onPointerUp={punchUp}
                    onPointerCancel={punchUp}
                    onContextMenu={(e) => e.preventDefault()}
                  >
                    <span className="jam-punch-fill" />
                    <span className="jam-punch-label">{fx.label}</span>
                  </div>
                ))}
              </div>
            </div>
          </aside>
        </div>
      </div>

      {/* ══════════════════════════════════════════════════════════════════
          PIANO KEYBOARD — full bleed, no padding
          ══════════════════════════════════════════════════════════════════ */}
      <div
        className="jam-keyboard-zone"
        style={{
          display: mainTab === 'pgm' ? 'none' : undefined,
          flexShrink: 0,
          height: '158px',
          paddingTop: '26px',
          paddingLeft: '18px',
          paddingRight: '18px',
          paddingBottom: '10px',
          boxSizing: 'border-box',
          position: 'relative',
        }}
      >
        <div className="jam-keyboard-head">
          {engineMode === 'lyria' ? (
            <>
              <span>Scale Selector</span>
              <span>
                <span className="jam-active-dot" />{' '}
                {lyriaScaleIdx !== null
                  ? LYRIA_SCALE_LABELS[lyriaScaleIdx]
                  : 'press a key to lock the scale'}
              </span>
            </>
          ) : (
            <>
              <span>Instrument Prompt</span>
              <span><span className="jam-active-dot" /> Active <b>Off</b></span>
            </>
          )}
        </div>
        <div className="jam-gate-toggle is-left">Gate Off</div>
        <div className="jam-gate-toggle is-right">Full</div>
        {/* Octave Rocker — floats top-right over the keyboard */}
        <div style={{
          position: 'absolute',
          top: '18px',
          right: '18px',
          zIndex: 10,
          display: 'flex',
          alignItems: 'center',
          gap: '4px',
          padding: '4px 8px',
          borderRadius: '8px',
          backgroundColor: 'var(--bg-footer, #000)',
          visibility: keyboardMidiEnabled ? 'visible' : 'hidden',
        }}>
          <IconButton
            variant="ghost"
            onClick={handleOctaveDown}
            disabled={octaveOffset <= -4}
            sx={{
              width: 32,
              height: 32,
              color: '#FFF',
              '&:hover': { backgroundColor: '#36373A' }
            }}
          >
            <ChevronLeft sx={{ fontSize: 18 }} />
          </IconButton>

          <span style={{
            fontSize: '13px',
            fontWeight: 600,
            minWidth: '36px',
            textAlign: 'center',
            color: '#FFF',
            fontFamily: "'Google Sans', system-ui, sans-serif",
            letterSpacing: '0.5px',
          }}>
            C{Math.floor((KEYBOARD_MIDI_BASE_DEFAULT + octaveOffset * 12) / 12) - 1}
          </span>

          <IconButton
            variant="ghost"
            onClick={handleOctaveUp}
            disabled={octaveOffset >= 4}
            sx={{
              width: 32,
              height: 32,
              color: '#FFF',
              '&:hover': { backgroundColor: '#36373A' }
            }}
          >
            <ChevronRight sx={{ fontSize: 18 }} />
          </IconButton>
        </div>

        <PianoKeyboard
          activeNotes={keyboardMidiEnabled
            ? activeNotes.map(n => 60 + (n - keyboardBaseNote.current))
                .filter(n => n >= 60 && n <= 76)
            : activeNotes
          }
          accentColor={activeColor}
          startNote={keyboardStartNote}
          endNote={keyboardEndNote}
          keyboardMidiEnabled={keyboardMidiEnabled}
          whiteKeyColor={THEME_KEYS[uiTheme].white}
          blackKeyColor={THEME_KEYS[uiTheme].black}
          onNoteOn={(visualNote) => {
            // Remap visual piano note to actual MIDI note
            const note = keyboardMidiEnabled
              ? keyboardBaseNote.current + (visualNote - 60)
              : visualNote;
            if (note >= 0 && note <= 127) {
              post({ type: 'kbdNote', note, on: true });
              if (engineModeRef.current === 'lyria' && mainTab !== 'instrument') {
                selectLyriaScaleFromNote(note);
              }
            }
          }}
          onNoteOff={(visualNote) => {
            const note = keyboardMidiEnabled
              ? keyboardBaseNote.current + (visualNote - 60)
              : visualNote;
            if (note >= 0 && note <= 127) post({ type: 'kbdNote', note, on: false });
          }}
        />
      </div>

      {/* ══════════════════════════════════════════════════════════════════
          BLACK FOOTER — MIDI, spacing, AudioMeter
          ══════════════════════════════════════════════════════════════════ */}
      <div
        className="jam-footer"
        style={{
          flexShrink: 0,
          height: '48px',
          display: 'flex',
          alignItems: 'center',
          justifyContent: 'space-between',
          padding: '6px 16px',
          boxSizing: 'border-box',
        }}
      >
        {/* Left cluster: MIDI Input (+ PGM live-input instrument source) */}
        <div style={{ display: 'flex', alignItems: 'center', gap: '12px' }}>
          <MidiSelector
            midiSources={midiSources}
            keyboardMidiEnabled={keyboardMidiEnabled}
            onSelectSource={(endpoint) => post({ type: 'selectMidiSource', endpoint })}
            midiActive={activeNotes.length > 0}
          />
          {mainTab === 'pgm' && (
            <span className="pgm-livesrc" title="PGM 现场弹奏音源：内置合成器 或 SoundFont 乐器">
              <span className="pgm-livesrc-label">SOURCE</span>
              <select
                value={liveSource === 1 ? `sf2:${liveSfProgram}` : 'syn'}
                onChange={(e) => {
                  const v = e.target.value;
                  if (v === 'syn') { setLiveSource(0); post({ type: 'liveSource', source: 0 }); }
                  else {
                    const prog = Number(v.slice(4));
                    setLiveSource(1); setLiveSfProgram(prog);
                    post({ type: 'liveSource', source: 1, program: prog });
                  }
                }}
              >
                <option value="syn">内置合成器（instrument）</option>
                {GM_FAMILIES.map(([fam, names], fi) => (
                  <optgroup key={fam} label={fam}>
                    {names.map((nm, ni) => (
                      <option key={nm} value={`sf2:${fi * 8 + ni}`}>{nm}</option>
                    ))}
                  </optgroup>
                ))}
              </select>
              <label className="pgm-livesrc-knob" title={`音量 ${Math.round(liveGain * 100)}%`}>
                VOL
                <input type="range" min={0} max={1.2} step={0.01} value={liveGain}
                  onChange={(e) => { const v = Number(e.target.value); setLiveGain(v);
                    post({ type: 'liveSource', gain: v }); }} />
              </label>
              <label className="pgm-livesrc-knob" title={`混响 ${Math.round(liveReverb * 100)}%`}>
                R
                <input type="range" min={0} max={1} step={0.01} value={liveReverb}
                  onChange={(e) => { const v = Number(e.target.value); setLiveReverb(v);
                    post({ type: 'liveSource', reverb: v }); }} />
              </label>
              <label className="pgm-livesrc-knob" title={`回声 ${Math.round(liveEcho * 100)}%（附点八分，BPM 同步）`}>
                E
                <input type="range" min={0} max={1} step={0.01} value={liveEcho}
                  onChange={(e) => { const v = Number(e.target.value); setLiveEcho(v);
                    post({ type: 'liveSource', echo: v }); }} />
              </label>
            </span>
          )}
        </div>

        {/* Spacer */}
        <div style={{ flex: '1 1 auto' }} />

        {/* Right cluster: AudioMeter */}
        <div style={{ display: 'flex', alignItems: 'center', gap: '16px' }}>
          <AudioMeter leftLevel={audioLevels.left} rightLevel={audioLevels.right} width="45px" height="14px" />
        </div>
      </div>

      {/* ── Fullscreen audio-reactive visuals ── */}
      {visualMode === 'full' && (
        <VisualLayer
          mode="full"
          accent={activeColor}
          bpm={bpmValue}
          beatActive={bpmLock}
          preset={visualPreset}
          imageSrc={visualImage}
          dataRef={visualDataRef}
          onExitFull={() => setVisualMode('bg')}
        />
      )}

      {/* ── Prompt cheat sheet (drawer overlay) ── */}
      <CheatSheet
        open={isCheatOpen}
        onClose={() => setIsCheatOpen(false)}
        onCopy={copyPromptText}
        onApply={applyCheatPrompt}
      />

      {/* ── AI prompt chat (drawer overlay) ── */}
      <ChatPanel
        open={isChatOpen}
        onClose={() => setIsChatOpen(false)}
        history={aiHistory}
        loading={aiLoading}
        onGenerate={generateAiPrompt}
        onClear={clearChat}
        onCopy={copyPromptText}
        onApply={applyCheatPrompt}
      />

      {/* ── Settings Panel (drawer overlay) ── */}
      <SettingsPanel
        open={isSettingsOpen}
        onClose={() => setIsSettingsOpen(false)}
        temperature={paramsState.temperature}
        topk={paramsState.topk}
        cfgnotes={paramsState.cfgnotesuser}
        cfgmusiccoca={paramsState.cfgmusiccoca}
        cfgdrums={paramsState.cfgdrums}
        unmaskwidth={paramsState.unmaskwidth}
        onParamChange={sendParamChange}
        onResetDefaults={handleResetDefaults}
        showNoteCfg={false}
        showPromptCfg={false}
        showDrumsCfg={false}
        showUnmaskWidth={false}
        showOnsetMode={true}
        onsetmode={paramsState.onsetmode}
        showDrumless={true}
        columns={1}
        drumless={paramsState.drumless}
      />

      {resourcesMissing && (
        <ResourceOnboardingModal
          progress={resourcesProgress}
          remoteModels={remoteModels}
          downloadPath={downloadPath}
          isFetchingModels={isFetchingModels}

          onSelectFolder={() => post({ type: 'selectDownloadFolder' })}
          onStartDownload={(modelName) => post({ type: 'initResources', modelName })}
        />
      )}
    </div>
  );
}

export default App;
