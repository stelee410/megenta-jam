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
}

export interface StudioState {
  loaded: boolean;
  name: string;
  duration: number;
  bpm: number;
  key: string;
  sections: StudioSection[];
  songWave: number[];
  stems: StudioStem[];
  stage: string;
  pct: number;
  busy: boolean;
  playMode: 'none' | 'song' | 'stems';
  playing: boolean;
  mixer: { mute: boolean; solo: boolean; gain: number }[];
  playhead: { pos: number; len: number };
  sepEngine: string;          // 'htdemucs' | 'hpss' | ''
  sepModel: { present: boolean; sources: number; downloading: boolean; pct: number; mb: number };
  error: string | null;
  notice: string | null;
}

export const STUDIO_INIT: StudioState = {
  loaded: false, name: '', duration: 0, bpm: 0, key: '',
  sections: [], songWave: [],
  stems: [
    { name: 'drums', wave: [], source: '' },
    { name: 'bass', wave: [], source: '' },
    { name: 'other', wave: [], source: '' },
    { name: 'vocals', wave: [], source: '' },
    { name: 'guitar', wave: [], source: '' },
    { name: 'piano', wave: [], source: '' },
  ],
  stage: '', pct: 0, busy: false, playMode: 'none', playing: false,
  mixer: Array.from({ length: 6 }, () => ({ mute: false, solo: false, gain: 1 })),
  playhead: { pos: 0, len: 0 },
  sepEngine: '', sepModel: { present: false, sources: 0, downloading: false, pct: 0, mb: 0 },
  error: null, notice: null,
};

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

export function StudioPanel({
  studio,
  onLoadSong,
  onLoadPgm,
  onSeparate,
  onSongToggle,
  onTransport,
  onMix,
  onSeek,
  onImportStem,
  onPackage,
  onSepDownload,
  onSepPick,
}: {
  studio: StudioState;
  onLoadSong: () => void;
  onLoadPgm: () => void;
  onSeparate: () => void;
  onSongToggle: (on: boolean) => void;
  onTransport: (action: 'play' | 'pause' | 'restart') => void;
  onMix: (idx: number, patch: { mute?: boolean; solo?: boolean; gain?: number }) => void;
  onSeek: (sec: number) => void;
  onImportStem: (idx: number) => void;
  onPackage: () => void;
  onSepDownload: () => void;
  onSepPick: () => void;
}) {
  const s = studio;
  const songOn = s.playMode === 'song';
  const stemsLoaded = s.stems.some(x => x.wave.length > 0);
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
              <span className="pgm-chip is-blue">{s.bpm} bpm</span>
              <span className="pgm-chip is-blue">{s.key}</span>
              <span className="pgm-chip">{mmss(s.duration)}</span>
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

          {/* ── Stem lanes (always visible — import third-party stems anywhere) ── */}
          {s.stems.map((stem, i) => (
            <div className={`pgm-lane ${!stem.wave.length ? 'is-empty' : ''}`} key={stem.name}>
              <div className="pgm-lane-head">
                <span className="pgm-lane-name">{stem.name.toUpperCase()}</span>
                {stem.source === 'imported' && <span className="pgm-chip is-neural">ext</span>}
                <div className="pgm-lane-actions">
                  {stem.wave.length > 0 && (
                    <>
                      <button
                        className={`pgm-ms ${s.mixer[i].mute ? 'is-mute' : ''}`}
                        onClick={() => onMix(i, { mute: !s.mixer[i].mute })}
                        title="Mute"
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
                  <button
                    className="pgm-mini"
                    onClick={() => onImportStem(i)}
                    disabled={s.busy}
                    title="用第三方分轨文件替换/导入这条轨（自动对齐长度）"
                  >
                    ⬆ {stem.wave.length ? 'replace' : 'import'}
                  </button>
                </div>
              </div>
              <div className="pgm-wave-wrap" {...seekHandlers}>
                <Wave data={stem.wave} color="rgba(111, 179, 255, 0.8)" />
                {playhead(transportOn && stem.wave.length > 0, i === 0)}
              </div>
            </div>
          ))}
          {s.loaded && !s.busy && !s.stems.some(x => x.wave.length) && (
            <div className="pgm-empty-sub" style={{ textAlign: 'center' }}>
              ✂ Separate 自动分轨，或在各轨道 ⬆ import 导入第三方分轨
            </div>
          )}

          <p className="pgm-hint">
            顶部 ▶/⏸/⟲ 总控播放，各轨 M=静音 S=独奏 + 音量推子，
            点击/拖动波形跳转进度；⬆ replace 可换第三方分轨 →
            ◈ Package PGM 导出（program.json + song.wav + stems/*.wav）。
          </p>
        </>
      )}
    </div>
  );
}
