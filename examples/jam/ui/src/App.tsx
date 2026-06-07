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
import { MagentaDropdown, MidiSelector, ModelSelector, ResourceOnboardingModal, PROMPT_SUGGESTIONS, INSTRUMENT_SUGGESTIONS, AudioMeter, TimingIndicator, SettingsPanel, GREY_900, ALL_COLORS, DEFAULT_TEMPERATURE, DEFAULT_TOPK, DEFAULT_CFG_NOTES, DEFAULT_CFG_MUSICCOCA, DEFAULT_CFG_DRUMS, DEFAULT_UNMASK_WIDTH, DEFAULT_BUFFER_SIZE, DEFAULT_VOLUME } from '@magenta-rt/common';
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
  | 'limiter';

type PerformanceState = Record<PerformanceKey, number>;

type PromptMode = 'single' | 'mix' | 'solo';
type MixLayoutMode = 'standard' | 'circle' | 'surface';

type MixPrompt = {
  id: number;
  text: string;
  weight: number;
  color: string;
};

const DEFAULT_MIX_PROMPTS: MixPrompt[] = [
  { id: 1, text: 'techno', weight: 0.34, color: '#ff4f7b' },
  { id: 2, text: 'glitch', weight: 0.08, color: '#6aa6ff' },
  { id: 3, text: 'hard bop', weight: 0.12, color: '#f0aa26' },
  { id: 4, text: 'piano arp', weight: 0.26, color: '#49d7a6' },
  { id: 5, text: 'vinyl hiss', weight: 0.06, color: '#9f8cff' },
  { id: 6, text: 'deep bass', weight: 0.14, color: '#f06a44' },
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
  const [mixLayout, setMixLayout] = useState<MixLayoutMode>('surface');
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
  });

  // Color state
  const [activeColor, setActiveColor] = useState(() => ALL_COLORS[Math.floor(Math.random() * ALL_COLORS.length)]);

  // Solo / Accompany state
  const [isSoloMode, setIsSoloMode] = useState(false);
  const lastSentSoloMode = useRef(false);

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
      setComposerText(preset);
      setActiveColor(getPromptColor(preset));
      setIsPromptEdited(false);
    }
  }, []);

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
      sendMixPrompts(mixPrompts, false);
      return;
    }

    // Pick the first preset from the new mode's preset list (top to bottom)
    const list = getActivePresetList(solo);
    if (list.length > 0) {
      const preset = list[0];
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
    text: string,
    immediate = false,
    soloOverride?: boolean,
  ) => {
    const soloActive = soloOverride !== undefined ? soloOverride : isSoloMode;
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

  const sendMixPrompts = (items: MixPrompt[], immediate = true) => {
    const activeItems = items.filter(item => item.text.trim() && item.weight > 0);
    const total = activeItems.reduce((sum, item) => sum + item.weight, 0) || 1;
    const prompts = activeItems.map(item => ({
      text: item.text,
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
            ? { ...item, text, color: getPromptColor(text) }
            : item
        ));
        sendMixPrompts(next, true);
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
  }, [draftText, focusedMixIndex, isAudioPrompt, promptMode]);

  const handlePromptSurfaceKeyDown = useCallback((e: React.KeyboardEvent<HTMLDivElement>) => {
    if ((promptMode === 'single' || promptMode === 'solo') && !isPromptEditing) return;
    if (e.metaKey || e.ctrlKey || e.altKey) return;

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
      setFocusedMixIndex(index => (index + (e.shiftKey ? 5 : 1)) % 6);
      setDraftText('');
      return;
    }

    if (e.key.length === 1) {
      e.preventDefault();
      setDraftText(prev => prev + e.key);
      setIsPromptEdited(true);
    }
  }, [commitDraftText, isPromptEditing, promptMode]);

  const handlePromptSurfacePaste = useCallback((e: React.ClipboardEvent<HTMLDivElement>) => {
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
    const total = raw.reduce((sum, value) => sum + value, 0) || 1;
    setMixPrompts(prev => {
      const next = prev.map((item, index) => ({
        ...item,
        weight: raw[index] / total,
      }));
      sendMixPrompts(next, false);
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
    sendPerformanceChange('filterX', x);
    sendPerformanceChange('filterY', y);
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
    ([
      ['filterX', 1.0],
      ['filterY', 0.02],
      ['drive', 0.0],
      ['delayMix', 0.0],
      ['delayFeedback', 0.25],
      ['reverbMix', 0.0],
      ['limiter', 0.35],
    ] as Array<[PerformanceKey, number]>).forEach(([key, value]) => sendPerformanceChange(key, value));
  };

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



  const openSettings = () => {
    post({ type: 'openSettings' });
  };

  // ─── State updates from native ─────────────────────────────────────────

  // Track whether the user has received initial state yet. Before that,
  // `prompt` updates from native should populate the UI. After, we ignore
  // subsequent `prompt` echoes so they don't stomp in-progress typing.
  const promptInitialized = useRef(false);

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
      if (state.audioLevels) setAudioLevels(state.audioLevels);
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

        let promptToUse = state.prompt;

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
      if (e.key === ' ') { e.preventDefault(); togglePlay(); }
      if (e.key === 'ArrowLeft' || e.key === 'ArrowRight') {
        e.preventDefault();
        const step = e.shiftKey ? 0.1 : 0.02;
        handleDeckBFaderChange(deckFader + (e.key === 'ArrowRight' ? step : -step));
      }
    };
    window.addEventListener('keydown', handleKeyDown);
    return () => window.removeEventListener('keydown', handleKeyDown);
  }, [isPlaying, deckFader]);

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
  ];

  // Current preset list for the rocker display
  const currentPresetList = getActivePresetList(isSoloMode);

  // Determine if the user has modified the prompt relative to the saved preset
  const savedPresetText = currentPresetList[rockerIndex] ?? '';
  const promptIsDirty = isPromptEdited && promptText.trim() !== '' && promptText !== savedPresetText;
  const committedPromptLabel = isAudioPrompt ? 'Audio prompt loaded' : (promptText || 'just type');
  const activeModeLabel = promptMode.toUpperCase();
  const totalMixWeight = mixPrompts.reduce((sum, item) => sum + item.weight, 0) || 1;
  const mixPositions = getMixPositions(mixLayout);
  const normalizedMixPrompts = mixPrompts.map(item => ({
    ...item,
    displayWeight: Math.round((item.weight / totalMixWeight) * 100),
  }));
  const weightedCenter = normalizedMixPrompts.reduce((acc, item, index) => {
    const pos = mixPositions[index];
    const weight = item.weight / totalMixWeight;
    return {
      x: acc.x + pos.x * weight,
      y: acc.y + pos.y * weight,
    };
  }, { x: 0, y: 0 });

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

  const playButton = (
    <IconButton
      onClick={noModel ? undefined : togglePlay}
      disabled={noModel}
      sx={{
        width: 63,
        height: 44,
        borderRadius: '8px',
        backgroundColor: '#FFF',
        color: '#000',
        borderBottom: '1.5px solid #ddd',
        transition: 'opacity 0.15s ease',
        '&:hover': {
          backgroundColor: '#FFF',
          color: '#000',
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
      style={{
        height: '100vh',
        width: '100vw',
        display: 'flex',
        flexDirection: 'column',
        overflow: 'hidden',
        boxSizing: 'border-box',
        color: '#FFF',
        fontFamily: "'Google Sans Text', system-ui, sans-serif",
      }}
    >
      <div className="jam-app-shell">
        <div className="jam-topbar">
          <div className="jam-topbar-left">
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
          <div className="jam-memory-indicator">MEMORY <span /></div>
          <div className="jam-topbar-right">
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
            <button className="jam-chat-button">Chat</button>
          </div>
        </div>

        <div className="jam-main-grid">
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
                    <Tooltip title="Upload audio prompt" placement="top">
                      <IconButton variant="jam" onClick={loadAudioPrompt} sx={{ width: 32, height: 32 }}>
                        <UploadFile sx={{ fontSize: 16 }} />
                      </IconButton>
                    </Tooltip>
                  )}
                  <IconButton variant="jam" onClick={() => setIsSettingsOpen(true)} sx={{ width: 32, height: 32 }}>
                    <TuneIcon sx={{ fontSize: 16 }} />
                  </IconButton>
                </div>
              </div>
              <div className="jam-prompt-toolbar">
                <div className="jam-prompt-toolset">
                  <button className="jam-mini-button" onClick={resetModel}>Reset</button>
                  {promptMode === 'mix' && (
                    <>
                      {(['standard', 'circle', 'surface'] as MixLayoutMode[]).map(layout => (
                        <button
                          key={layout}
                          className={`jam-mini-button ${mixLayout === layout ? 'is-active' : ''}`}
                          onClick={() => setMixLayout(layout)}
                        >
                          {layout}
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
              {(promptMode === 'single' || promptMode === 'solo') && (
                <div className="jam-single-prompt">
                  <div className="jam-single-kicker">{activeModeLabel}</div>
                  <button
                    className="jam-single-text"
                    style={{ color: activeColor }}
                    onMouseDown={(e) => {
                      e.preventDefault();
                      setIsPromptEditing(true);
                      window.setTimeout(() => promptSurfaceRef.current?.focus(), 0);
                    }}
                  >
                    {draftText ? (
                      <span className="jam-draft-text">{draftText}<span className="jam-caret" /></span>
                    ) : (
                      committedPromptLabel
                    )}
                  </button>
                  <div className="jam-prompt-hint">{isPromptEditing ? (draftText ? 'Enter to apply' : 'type prompt') : 'keyboard plays'}</div>
                  <div className="jam-corner jam-corner-tl" />
                  <div className="jam-corner jam-corner-br" />
                </div>
              )}

              {promptMode === 'mix' && (
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
                  <svg className="jam-mix-lines" viewBox="0 0 100 100" preserveAspectRatio="none" aria-hidden="true">
                    {normalizedMixPrompts.map((item, index) => {
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
                        className={`jam-prompt-chip ${focused ? 'is-focused' : ''} ${focused && draftText ? 'is-pending' : ''}`}
                        style={{
                          left: `${pos.x}%`,
                          top: `${pos.y}%`,
                          '--chip-color': item.color,
                          '--line-x': `${weightedCenter.x - pos.x}%`,
                          '--line-y': `${weightedCenter.y - pos.y}%`,
                        } as React.CSSProperties}
                        onClick={(e) => {
                          e.stopPropagation();
                          setFocusedMixIndex(index);
                          setDraftText('');
                          setIsPromptEditing(true);
                          promptSurfaceRef.current?.focus();
                        }}
                      >
                        <span className="jam-chip-index">{item.id}</span>
                        <span className="jam-chip-text">{label}{focused && draftText && <span className="jam-caret" />}</span>
                        <span className="jam-chip-weight">{item.displayWeight}%</span>
                      </button>
                    );
                  })}
                  <button className="jam-trash-button" title="Clear draft" onClick={(e) => { e.stopPropagation(); setDraftText(''); }}>x</button>
                  <div className="jam-expand-glyph">open</div>
                  <div className="jam-prompt-hint">{draftText ? 'Enter to apply' : `typing edits slot ${focusedMixIndex + 1}`}</div>
                </div>
              )}
            </div>

            {promptMode === 'mix' && (
              <div className="jam-slot-row">
                {normalizedMixPrompts.map((item, index) => (
                  <button
                    key={item.id}
                    className={`jam-slot-pill ${index === focusedMixIndex ? 'is-focused' : ''}`}
                    style={{ '--chip-color': item.color } as React.CSSProperties}
                    onClick={() => {
                    setFocusedMixIndex(index);
                    setDraftText('');
                    setPromptMode('mix');
                    setIsPromptEditing(true);
                    promptSurfaceRef.current?.focus();
                  }}
                >
                    <span />
                    <b>{item.text}</b>
                    <em>{item.displayWeight}%</em>
                    {index === focusedMixIndex && draftText && <i>pending</i>}
                  </button>
                ))}
              </div>
            )}
          </section>

          <aside className="jam-side-controls">
            <div className="jam-transport-row">
              <IconButton variant="jam" onClick={handleRockerLeft} sx={{ width: 40, height: 40 }} title="Previous preset">
                <ArrowBack sx={{ fontSize: 18, color: '#FFF' }} />
              </IconButton>
              {noModel ? (
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

            <div className="jam-performance-panel">
              <div className="jam-performance-head">
                <span>Probability Space</span>
                <span>T: {paramsState.temperature.toFixed(2)} | K: {Math.round(paramsState.topk)}</span>
              </div>
              <div
                ref={xyPadRef}
                className="jam-xy-pad"
                style={{
                  '--xy-x': `${performance.filterX * 100}%`,
                  '--xy-y': `${(1 - performance.filterY) * 100}%`,
                } as React.CSSProperties}
                onPointerDown={(e) => {
                  e.currentTarget.setPointerCapture(e.pointerId);
                  handleXYPointer(e);
                }}
                onPointerMove={(e) => {
                  if (e.buttons !== 1) return;
                  handleXYPointer(e);
                }}
              >
                <div className="jam-probability-crosshair-x" />
                <div className="jam-probability-crosshair-y" />
                <div
                  className="jam-xy-dot"
                  style={{
                    left: `${performance.filterX * 100}%`,
                    top: `${(1 - performance.filterY) * 100}%`,
                  }}
                />
              </div>
              <label className="jam-latch-row">
                <input type="checkbox" checked readOnly />
                latch
              </label>
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
          </aside>
        </div>
      </div>

      {/* ══════════════════════════════════════════════════════════════════
          PIANO KEYBOARD — full bleed, no padding
          ══════════════════════════════════════════════════════════════════ */}
      <div
        style={{
          flexShrink: 0,
          height: '158px',
          backgroundColor: '#070708',
          paddingTop: '26px',
          paddingLeft: '18px',
          paddingRight: '18px',
          paddingBottom: '10px',
          boxSizing: 'border-box',
          position: 'relative',
        }}
      >
        <div className="jam-keyboard-head">
          <span>Instrument Prompt</span>
          <span><span className="jam-active-dot" /> Active <b>Off</b></span>
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
          backgroundColor: '#000',
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
          whiteKeyColor="#111214"
          blackKeyColor="#030405"
          onNoteOn={(visualNote) => {
            // Remap visual piano note to actual MIDI note
            const note = keyboardMidiEnabled
              ? keyboardBaseNote.current + (visualNote - 60)
              : visualNote;
            if (note >= 0 && note <= 127) post({ type: 'kbdNote', note, on: true });
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
        style={{
          flexShrink: 0,
          height: '48px',
          background: '#000',
          color: '#FFF',
          display: 'flex',
          alignItems: 'center',
          justifyContent: 'space-between',
          padding: '6px 16px',
          boxSizing: 'border-box',
        }}
      >
        {/* Left cluster: MIDI Input */}
        <div style={{ display: 'flex', alignItems: 'center', gap: '12px' }}>
          <MidiSelector
            midiSources={midiSources}
            keyboardMidiEnabled={keyboardMidiEnabled}
            onSelectSource={(endpoint) => post({ type: 'selectMidiSource', endpoint })}
            midiActive={activeNotes.length > 0}
          />
        </div>

        {/* Spacer */}
        <div style={{ flex: '1 1 auto' }} />

        {/* Right cluster: AudioMeter */}
        <div style={{ display: 'flex', alignItems: 'center', gap: '16px' }}>
          <AudioMeter leftLevel={audioLevels.left} rightLevel={audioLevels.right} width="45px" height="14px" />
        </div>
      </div>

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
