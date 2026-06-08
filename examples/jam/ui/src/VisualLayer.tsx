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
 * VisualLayer — a Hydra-flavored, audio-reactive WebGL visual:
 * a feedback loop (previous frame re-sampled with zoom/rotate) plus three
 * pattern presets (osc / tunnel / scope), all driven by live audio level,
 * transient "kick" detection, the engine waveform, the active prompt color
 * and the locked BPM. Self-contained: raw WebGL1, no dependencies.
 */

import { useEffect, useRef } from 'react';

export interface VisualData {
  level: number;        // smoothed peak 0..~1
  kick: number;         // transient detector, decays toward 0
  wave: Float32Array;   // 96-point waveform, -1..1
}

export const VISUAL_PRESETS = ['osc', 'tunnel', 'scope'] as const;

const SIM_MAX_WIDTH = 840; // feedback sim resolution cap (perf)

const VERT = `
attribute vec2 aPos;
void main() { gl_Position = vec4(aPos, 0.0, 1.0); }
`;

const FRAG_SIM = `
precision highp float;
uniform vec2 uRes;
uniform float uTime;
uniform float uLevel;
uniform float uKick;
uniform float uBeat;    // beat phase 0..1
uniform float uPreset;
uniform vec3 uColor;
uniform sampler2D uPrev;
uniform sampler2D uWave;

float waveAt(float x) {
  return texture2D(uWave, vec2(fract(x), 0.5)).r * 2.0 - 1.0;
}

mat2 rot(float a) { return mat2(cos(a), -sin(a), sin(a), cos(a)); }

void main() {
  vec2 uv = gl_FragCoord.xy / uRes;
  float aspect = uRes.x / uRes.y;
  vec2 p = (uv - 0.5) * vec2(aspect, 1.0);

  // ── Feedback: re-sample the previous frame, slowly zooming + rotating.
  float zoom = 0.986 - uKick * 0.025;
  float ang = 0.004 + uKick * 0.012;
  vec2 q = rot(ang) * p * zoom;
  vec3 prev = texture2D(uPrev, q / vec2(aspect, 1.0) + 0.5).rgb;
  vec3 col = prev * (0.955 - 0.02 * uLevel);

  float r = length(p);
  float a = atan(p.y, p.x);

  if (uPreset < 0.5) {
    // ── OSC: interfering travelling waves, warped by the audio level.
    float warp = sin(p.x * 7.0 + uTime) * (0.4 + uLevel);
    float v = sin((p.x * 4.0 + uTime * 0.7) * 3.14159)
            + sin((p.y * 3.0 - uTime * 0.5) * 3.14159 + warp)
            + sin((r * 9.0 - uTime * 1.1) * 2.0) * uLevel * 1.6;
    vec3 c = uColor * smoothstep(0.25, 1.6, abs(v));
    c = mix(c, c.brg, 0.5 + 0.5 * sin(uTime * 0.17));
    col += c * (0.10 + 0.22 * uLevel);
  } else if (uPreset < 1.5) {
    // ── TUNNEL: beat-synced rings + spokes feeding the zoom trail.
    float ring = smoothstep(0.025, 0.0, abs(r - (0.16 + 0.55 * uBeat)))
               * (0.35 + uKick * 2.4);
    float spokes = pow(abs(sin(a * 6.0 + uTime * 0.6)), 10.0)
                 * (0.15 + 0.8 * uLevel);
    float core = smoothstep(0.10, 0.0, r) * uKick * 1.6;
    vec3 c = uColor * ring + uColor.brg * spokes + vec3(1.0) * core;
    col += c * 0.85;
  } else {
    // ── SCOPE: polar oscilloscope of the real engine waveform.
    float w = waveAt(a / 6.28318 + 0.5 + uTime * 0.015);
    float rad = 0.34 + 0.20 * w * (0.5 + 1.7 * uLevel);
    float d = abs(r - rad);
    col += uColor * smoothstep(0.022, 0.0, d) * 1.2;
    col += uColor.brg * smoothstep(0.10, 0.0, d) * (0.12 + 0.5 * uLevel);
    // faint cartesian scope along the bottom
    float y = waveAt(uv.x + uTime * 0.01) * 0.12 * (0.4 + uLevel);
    col += uColor * smoothstep(0.012, 0.0, abs(p.y + 0.36 - y)) * 0.35;
  }

  col = min(col, vec3(1.5));
  gl_FragColor = vec4(col, 1.0);
}
`;

const FRAG_COPY = `
precision highp float;
uniform vec2 uRes;
uniform sampler2D uTex;
void main() {
  vec2 uv = gl_FragCoord.xy / uRes;
  vec3 c = texture2D(uTex, uv).rgb;
  // gentle vignette
  vec2 d = uv - 0.5;
  c *= 1.0 - dot(d, d) * 0.55;
  gl_FragColor = vec4(c, 1.0);
}
`;

function compile(gl: WebGLRenderingContext, type: number, src: string): WebGLShader {
  const sh = gl.createShader(type)!;
  gl.shaderSource(sh, src);
  gl.compileShader(sh);
  if (!gl.getShaderParameter(sh, gl.COMPILE_STATUS)) {
    throw new Error(gl.getShaderInfoLog(sh) ?? 'shader compile failed');
  }
  return sh;
}

function program(gl: WebGLRenderingContext, vs: string, fs: string): WebGLProgram {
  const prg = gl.createProgram()!;
  gl.attachShader(prg, compile(gl, gl.VERTEX_SHADER, vs));
  gl.attachShader(prg, compile(gl, gl.FRAGMENT_SHADER, fs));
  gl.linkProgram(prg);
  if (!gl.getProgramParameter(prg, gl.LINK_STATUS)) {
    throw new Error(gl.getProgramInfoLog(prg) ?? 'link failed');
  }
  return prg;
}

function hexToRgb(hex: string): [number, number, number] {
  const m = /^#?([0-9a-f]{6})$/i.exec(hex.trim());
  if (!m) return [0.44, 0.96, 0.84];
  const v = parseInt(m[1], 16);
  return [((v >> 16) & 255) / 255, ((v >> 8) & 255) / 255, (v & 255) / 255];
}

export function VisualLayer({
  mode,
  accent,
  bpm,
  beatActive,
  preset,
  dataRef,
  onExitFull,
}: {
  mode: 'bg' | 'full';
  accent: string;
  bpm: number;
  beatActive: boolean;
  preset: number;
  dataRef: React.MutableRefObject<VisualData>;
  onExitFull: () => void;
}) {
  const canvasRef = useRef<HTMLCanvasElement | null>(null);
  const accentRef = useRef(accent);
  accentRef.current = accent;
  const presetRef = useRef(preset);
  presetRef.current = preset;
  const beatRef = useRef({ bpm, active: beatActive });
  beatRef.current = { bpm, active: beatActive };

  useEffect(() => {
    const canvas = canvasRef.current;
    if (!canvas) return;
    const gl = canvas.getContext('webgl', { antialias: false, alpha: false });
    if (!gl) return;

    const simPrg = program(gl, VERT, FRAG_SIM);
    const copyPrg = program(gl, VERT, FRAG_COPY);

    // Fullscreen triangle
    const vbo = gl.createBuffer();
    gl.bindBuffer(gl.ARRAY_BUFFER, vbo);
    gl.bufferData(gl.ARRAY_BUFFER, new Float32Array([-1, -1, 3, -1, -1, 3]), gl.STATIC_DRAW);
    const bindGeometry = (prg: WebGLProgram) => {
      const loc = gl.getAttribLocation(prg, 'aPos');
      gl.enableVertexAttribArray(loc);
      gl.vertexAttribPointer(loc, 2, gl.FLOAT, false, 0, 0);
    };

    // Ping-pong feedback targets
    let simW = 0;
    let simH = 0;
    const textures: WebGLTexture[] = [];
    const fbos: WebGLFramebuffer[] = [];
    const allocTargets = (w: number, h: number) => {
      simW = w;
      simH = h;
      for (let i = 0; i < 2; i++) {
        if (!textures[i]) {
          textures[i] = gl.createTexture()!;
          fbos[i] = gl.createFramebuffer()!;
        }
        gl.bindTexture(gl.TEXTURE_2D, textures[i]);
        gl.texImage2D(gl.TEXTURE_2D, 0, gl.RGBA, w, h, 0, gl.RGBA, gl.UNSIGNED_BYTE, null);
        gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.LINEAR);
        gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.LINEAR);
        gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE);
        gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE);
        gl.bindFramebuffer(gl.FRAMEBUFFER, fbos[i]);
        gl.framebufferTexture2D(gl.FRAMEBUFFER, gl.COLOR_ATTACHMENT0, gl.TEXTURE_2D, textures[i], 0);
      }
      gl.bindFramebuffer(gl.FRAMEBUFFER, null);
    };

    // Waveform texture (96×1, bytes)
    const waveTex = gl.createTexture()!;
    const waveBytes = new Uint8Array(96);
    gl.bindTexture(gl.TEXTURE_2D, waveTex);
    gl.texImage2D(gl.TEXTURE_2D, 0, gl.LUMINANCE, 96, 1, 0, gl.LUMINANCE, gl.UNSIGNED_BYTE, waveBytes);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.LINEAR);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.LINEAR);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.REPEAT);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE);

    const resize = () => {
      const dpr = Math.min(window.devicePixelRatio || 1, 1.5);
      const w = Math.max(2, Math.floor(canvas.clientWidth * dpr));
      const h = Math.max(2, Math.floor(canvas.clientHeight * dpr));
      if (canvas.width !== w || canvas.height !== h) {
        canvas.width = w;
        canvas.height = h;
        const scale = Math.min(1, SIM_MAX_WIDTH / w);
        allocTargets(Math.max(2, Math.floor(w * scale)), Math.max(2, Math.floor(h * scale)));
      }
    };
    resize();
    const ro = new ResizeObserver(resize);
    ro.observe(canvas);

    let src = 0;
    let raf = 0;
    const t0 = performance.now();
    const render = () => {
      raf = requestAnimationFrame(render);
      if (canvas.clientWidth === 0) return;
      const data = dataRef.current;
      const t = (performance.now() - t0) / 1000;
      const { bpm: liveBpm, active } = beatRef.current;
      const beat = active ? ((t * liveBpm) / 60) % 1 : (t * 0.12) % 1;

      // Upload waveform
      for (let i = 0; i < 96; i++) {
        const v = data.wave[i] ?? 0;
        waveBytes[i] = Math.max(0, Math.min(255, Math.round((v * 0.5 + 0.5) * 255)));
      }
      gl.bindTexture(gl.TEXTURE_2D, waveTex);
      gl.texSubImage2D(gl.TEXTURE_2D, 0, 0, 0, 96, 1, gl.LUMINANCE, gl.UNSIGNED_BYTE, waveBytes);

      const dst = 1 - src;
      const [cr, cg, cb] = hexToRgb(accentRef.current);

      // Sim pass → dst fbo
      gl.bindFramebuffer(gl.FRAMEBUFFER, fbos[dst]);
      gl.viewport(0, 0, simW, simH);
      gl.useProgram(simPrg);
      bindGeometry(simPrg);
      gl.uniform2f(gl.getUniformLocation(simPrg, 'uRes'), simW, simH);
      gl.uniform1f(gl.getUniformLocation(simPrg, 'uTime'), t);
      gl.uniform1f(gl.getUniformLocation(simPrg, 'uLevel'), data.level);
      gl.uniform1f(gl.getUniformLocation(simPrg, 'uKick'), data.kick);
      gl.uniform1f(gl.getUniformLocation(simPrg, 'uBeat'), beat);
      gl.uniform1f(gl.getUniformLocation(simPrg, 'uPreset'), presetRef.current);
      gl.uniform3f(gl.getUniformLocation(simPrg, 'uColor'), cr, cg, cb);
      gl.activeTexture(gl.TEXTURE0);
      gl.bindTexture(gl.TEXTURE_2D, textures[src]);
      gl.uniform1i(gl.getUniformLocation(simPrg, 'uPrev'), 0);
      gl.activeTexture(gl.TEXTURE1);
      gl.bindTexture(gl.TEXTURE_2D, waveTex);
      gl.uniform1i(gl.getUniformLocation(simPrg, 'uWave'), 1);
      gl.drawArrays(gl.TRIANGLES, 0, 3);

      // Copy pass → screen
      gl.bindFramebuffer(gl.FRAMEBUFFER, null);
      gl.viewport(0, 0, canvas.width, canvas.height);
      gl.useProgram(copyPrg);
      bindGeometry(copyPrg);
      gl.uniform2f(gl.getUniformLocation(copyPrg, 'uRes'), canvas.width, canvas.height);
      gl.activeTexture(gl.TEXTURE0);
      gl.bindTexture(gl.TEXTURE_2D, textures[dst]);
      gl.uniform1i(gl.getUniformLocation(copyPrg, 'uTex'), 0);
      gl.drawArrays(gl.TRIANGLES, 0, 3);

      src = dst;
    };
    raf = requestAnimationFrame(render);

    return () => {
      cancelAnimationFrame(raf);
      ro.disconnect();
      gl.getExtension('WEBGL_lose_context')?.loseContext();
    };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  // ESC exits fullscreen
  useEffect(() => {
    if (mode !== 'full') return;
    const onKey = (e: KeyboardEvent) => {
      if (e.key === 'Escape') onExitFull();
    };
    window.addEventListener('keydown', onKey);
    return () => window.removeEventListener('keydown', onKey);
  }, [mode, onExitFull]);

  return (
    <div
      className={`jam-visual-layer ${mode === 'full' ? 'is-full' : 'is-bg'}`}
      onClick={mode === 'full' ? onExitFull : undefined}
    >
      <canvas ref={canvasRef} />
      {mode === 'full' && <div className="jam-visual-hint">click or esc to exit</div>}
    </div>
  );
}
