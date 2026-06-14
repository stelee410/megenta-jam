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
 * VisualLayer — a Hydra-flavored, audio-reactive WebGL visual.
 *
 * Two families of presets share one canvas:
 *   - Abstract (osc / tunnel / scope): a feedback loop plus generative
 *     patterns driven by audio level, a transient "kick", the engine
 *     waveform, the active prompt color, and the locked BPM.
 *   - Image (particles / stretch / glitch): an uploaded image, particle-ized
 *     (GL_POINTS scattered from the pixels), liquified (UV displacement), or
 *     glitched (RGB split + scanlines), all reacting to the same audio data.
 *
 * Raw WebGL1, no dependencies.
 */

import { useEffect, useRef } from 'react';

export interface VisualData {
  level: number;        // smoothed peak 0..~1
  kick: number;         // transient detector, decays toward 0
  wave: Float32Array;   // 96-point waveform, -1..1
}

export const VISUAL_PRESETS = ['osc', 'tunnel', 'scope', 'particles', 'stretch', 'glitch'] as const;
export const FIRST_IMAGE_PRESET = 3; // index of 'particles'

const SIM_MAX_WIDTH = 840;     // feedback sim resolution cap (perf)
const PARTICLE_GRID_W = 200;   // particle columns; rows scale to image aspect
const PARTICLE_MAX = 36000;    // total particle cap

const VERT = `
attribute vec2 aPos;
void main() { gl_Position = vec4(aPos, 0.0, 1.0); }
`;

const FRAG_SIM = `
precision highp float;
uniform vec2 uRes;
uniform float uTime, uLevel, uKick, uBeat, uPreset;
uniform vec3 uColor;
uniform sampler2D uPrev, uWave;
float waveAt(float x){ return texture2D(uWave, vec2(fract(x),0.5)).r*2.0-1.0; }
mat2 rot(float a){ return mat2(cos(a),-sin(a),sin(a),cos(a)); }
void main(){
  vec2 uv = gl_FragCoord.xy / uRes;
  float aspect = uRes.x/uRes.y;
  vec2 p = (uv-0.5)*vec2(aspect,1.0);
  float zoom = 0.986 - uKick*0.025;
  float ang = 0.004 + uKick*0.012;
  vec2 q = rot(ang)*p*zoom;
  vec3 prev = texture2D(uPrev, q/vec2(aspect,1.0)+0.5).rgb;
  vec3 col = prev*(0.955 - 0.02*uLevel);
  float r = length(p), a = atan(p.y,p.x);
  if(uPreset<0.5){
    float warp = sin(p.x*7.0+uTime)*(0.4+uLevel);
    float v = sin((p.x*4.0+uTime*0.7)*3.14159)
            + sin((p.y*3.0-uTime*0.5)*3.14159+warp)
            + sin((r*9.0-uTime*1.1)*2.0)*uLevel*1.6;
    vec3 c = uColor*smoothstep(0.25,1.6,abs(v));
    c = mix(c, c.brg, 0.5+0.5*sin(uTime*0.17));
    col += c*(0.10+0.22*uLevel);
  } else if(uPreset<1.5){
    float ring = smoothstep(0.025,0.0,abs(r-(0.16+0.55*uBeat)))*(0.35+uKick*2.4);
    float spokes = pow(abs(sin(a*6.0+uTime*0.6)),10.0)*(0.15+0.8*uLevel);
    float core = smoothstep(0.10,0.0,r)*uKick*1.6;
    col += (uColor*ring + uColor.brg*spokes + vec3(1.0)*core)*0.85;
  } else {
    float w = waveAt(a/6.28318+0.5+uTime*0.015);
    float rad = 0.34+0.20*w*(0.5+1.7*uLevel);
    float d = abs(r-rad);
    col += uColor*smoothstep(0.022,0.0,d)*1.2;
    col += uColor.brg*smoothstep(0.10,0.0,d)*(0.12+0.5*uLevel);
    float y = waveAt(uv.x+uTime*0.01)*0.12*(0.4+uLevel);
    col += uColor*smoothstep(0.012,0.0,abs(p.y+0.36-y))*0.35;
  }
  gl_FragColor = vec4(min(col,vec3(1.5)),1.0);
}
`;

const FRAG_COPY = `
precision highp float;
uniform vec2 uRes;
uniform sampler2D uTex;
uniform float uFade;       // 1.0 = full, <1 = dim for trails
void main(){
  vec2 uv = gl_FragCoord.xy/uRes;
  vec3 c = texture2D(uTex, uv).rgb * uFade;
  vec2 d = uv-0.5;
  c *= 1.0 - dot(d,d)*0.55;
  gl_FragColor = vec4(c,1.0);
}
`;

// ─── Image: liquify / glitch (fullscreen fragment) ──────────────────────────
const FRAG_IMAGE = `
precision highp float;
uniform vec2 uRes;
uniform float uTime, uLevel, uKick, uPreset;
uniform vec3 uColor;
uniform sampler2D uImage, uWave;
uniform vec2 uImgScale;    // fit factor (letterbox)
float waveAt(float x){ return texture2D(uWave, vec2(fract(x),0.5)).r*2.0-1.0; }
float hash(float n){ return fract(sin(n)*43758.5453); }
void main(){
  vec2 uv = gl_FragCoord.xy/uRes;
  vec2 p = (uv-0.5)/uImgScale + 0.5;   // fit image into screen
  vec3 col;
  if(uPreset<4.5){
    // STRETCH / liquify: per-row horizontal stretch by the waveform + ripple.
    float disp = waveAt(p.y + uTime*0.02)*(0.04+0.20*uLevel);
    p.x += disp + sin(p.y*10.0+uTime)*0.012*uLevel;
    p.y += sin(p.x*8.0-uTime*0.7)*0.02*uLevel;
    p.x += uKick*0.06*sin(p.y*40.0);
    col = texture2D(uImage, p).rgb;
    col += uColor*uLevel*0.10;
  } else {
    // GLITCH: chromatic aberration + block shear + scanlines + bloom.
    float row = floor(p.y*40.0);
    float shear = (hash(row+floor(uTime*8.0))>0.93) ? uKick*0.12 : 0.0;
    p.x += shear;
    float sh = 0.006 + 0.045*uKick + 0.01*uLevel;
    float rC = texture2D(uImage, p+vec2(sh,0.0)).r;
    float gC = texture2D(uImage, p).g;
    float bC = texture2D(uImage, p-vec2(sh,0.0)).b;
    col = vec3(rC,gC,bC);
    col *= 0.82 + 0.18*sin(uv.y*uRes.y*1.2);     // scanlines
    float luma = dot(col, vec3(0.299,0.587,0.114));
    col += smoothstep(0.7,1.0,luma)*(0.3+uLevel)*uColor.brg; // bloom tint
  }
  vec2 d = uv-0.5;
  col *= 1.0 - dot(d,d)*0.5;
  gl_FragColor = vec4(min(col,vec3(1.6)),1.0);
}
`;

// ─── Image: particles (GL_POINTS) ───────────────────────────────────────────
const VERT_PARTICLE = `
precision highp float;
attribute vec2 aSrc;       // base position, -1..1 image square
attribute vec3 aColor;     // sampled pixel color
uniform float uTime, uLevel, uKick, uAspectFix;
uniform vec2 uImgScale;
varying vec3 vColor;
void main(){
  vec2 base = aSrc*uImgScale;
  vec2 turb = vec2(
    sin(aSrc.y*4.0+uTime*1.2+aSrc.x*3.0),
    cos(aSrc.x*4.0+uTime*1.0-aSrc.y*2.0)
  )*(0.015+0.10*uLevel);
  vec2 burst = aSrc*uKick*0.28;
  vec2 pos = base + turb + burst;
  gl_Position = vec4(pos, 0.0, 1.0);
  gl_PointSize = (1.5 + 3.5*uLevel + 5.0*uKick);
  vColor = aColor;
}
`;
const FRAG_PARTICLE = `
precision highp float;
varying vec3 vColor;
uniform float uLevel;
void main(){
  vec2 d = gl_PointCoord - 0.5;
  float r = dot(d,d);
  if(r>0.25) discard;
  float a = smoothstep(0.25,0.0,r);
  gl_FragColor = vec4(vColor*(0.8+0.6*uLevel)*a, 1.0);
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

interface ImageGL {
  tex: WebGLTexture;
  particleVBO: WebGLBuffer;
  particleCount: number;
  scaleX: number;  // letterbox fit, relative to a unit square
  scaleY: number;
  aspect: number;  // image w/h
}

export function VisualLayer({
  mode,
  accent,
  bpm,
  beatActive,
  preset,
  imageSrc,
  dataRef,
  onExitFull,
}: {
  mode: 'bg' | 'full';
  accent: string;
  bpm: number;
  beatActive: boolean;
  preset: number;
  imageSrc: string | null;
  dataRef: React.MutableRefObject<VisualData>;
  onExitFull: () => void;
}) {
  const canvasRef = useRef<HTMLCanvasElement | null>(null);
  const accentRef = useRef(accent); accentRef.current = accent;
  const presetRef = useRef(preset); presetRef.current = preset;
  const beatRef = useRef({ bpm, active: beatActive }); beatRef.current = { bpm, active: beatActive };

  const glRef = useRef<WebGLRenderingContext | null>(null);
  const imageGLRef = useRef<ImageGL | null>(null);
  const canvasAspectRef = useRef(1);

  // ── GL setup (once) ──────────────────────────────────────────────────────
  useEffect(() => {
    const canvas = canvasRef.current;
    if (!canvas) return;
    const gl = canvas.getContext('webgl', { antialias: false, alpha: false });
    if (!gl) return;
    glRef.current = gl;

    const simPrg = program(gl, VERT, FRAG_SIM);
    const copyPrg = program(gl, VERT, FRAG_COPY);
    const imgPrg = program(gl, VERT, FRAG_IMAGE);
    const partPrg = program(gl, VERT_PARTICLE, FRAG_PARTICLE);

    const vbo = gl.createBuffer();
    gl.bindBuffer(gl.ARRAY_BUFFER, vbo);
    gl.bufferData(gl.ARRAY_BUFFER, new Float32Array([-1, -1, 3, -1, -1, 3]), gl.STATIC_DRAW);
    const bindQuad = (prg: WebGLProgram) => {
      gl.bindBuffer(gl.ARRAY_BUFFER, vbo);
      const loc = gl.getAttribLocation(prg, 'aPos');
      gl.enableVertexAttribArray(loc);
      gl.vertexAttribPointer(loc, 2, gl.FLOAT, false, 0, 0);
    };

    let simW = 0, simH = 0;
    const textures: WebGLTexture[] = [];
    const fbos: WebGLFramebuffer[] = [];
    const allocTargets = (w: number, h: number) => {
      simW = w; simH = h;
      for (let i = 0; i < 2; i++) {
        if (!textures[i]) { textures[i] = gl.createTexture()!; fbos[i] = gl.createFramebuffer()!; }
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
        canvas.width = w; canvas.height = h;
        canvasAspectRef.current = w / h;
        const scale = Math.min(1, SIM_MAX_WIDTH / w);
        allocTargets(Math.max(2, Math.floor(w * scale)), Math.max(2, Math.floor(h * scale)));
      }
    };
    resize();
    const ro = new ResizeObserver(resize); ro.observe(canvas);

    let src = 0, raf = 0;
    const t0 = performance.now();
    const render = () => {
      raf = requestAnimationFrame(render);
      if (canvas.clientWidth === 0) return;
      const data = dataRef.current;
      const t = (performance.now() - t0) / 1000;
      const { bpm: liveBpm, active } = beatRef.current;
      const beat = active ? ((t * liveBpm) / 60) % 1 : (t * 0.12) % 1;
      const [cr, cg, cb] = hexToRgb(accentRef.current);
      const pr = presetRef.current;
      const img = imageGLRef.current;
      const isImage = pr >= FIRST_IMAGE_PRESET;

      for (let i = 0; i < 96; i++) {
        const v = data.wave[i] ?? 0;
        waveBytes[i] = Math.max(0, Math.min(255, Math.round((v * 0.5 + 0.5) * 255)));
      }
      gl.activeTexture(gl.TEXTURE1);
      gl.bindTexture(gl.TEXTURE_2D, waveTex);
      gl.texSubImage2D(gl.TEXTURE_2D, 0, 0, 0, 96, 1, gl.LUMINANCE, gl.UNSIGNED_BYTE, waveBytes);

      if (isImage && img && pr === FIRST_IMAGE_PRESET) {
        // ── PARTICLES → feedback target (trails), then to screen ──
        const dst = 1 - src;
        // fade previous frame into dst
        gl.bindFramebuffer(gl.FRAMEBUFFER, fbos[dst]);
        gl.viewport(0, 0, simW, simH);
        gl.useProgram(copyPrg); bindQuad(copyPrg);
        gl.uniform2f(gl.getUniformLocation(copyPrg, 'uRes'), simW, simH);
        gl.uniform1f(gl.getUniformLocation(copyPrg, 'uFade'), 0.86);
        gl.activeTexture(gl.TEXTURE0); gl.bindTexture(gl.TEXTURE_2D, textures[src]);
        gl.uniform1i(gl.getUniformLocation(copyPrg, 'uTex'), 0);
        gl.disable(gl.BLEND);
        gl.drawArrays(gl.TRIANGLES, 0, 3);
        // draw particles additively on top
        gl.useProgram(partPrg);
        gl.bindBuffer(gl.ARRAY_BUFFER, img.particleVBO);
        const aSrc = gl.getAttribLocation(partPrg, 'aSrc');
        const aColor = gl.getAttribLocation(partPrg, 'aColor');
        gl.enableVertexAttribArray(aSrc);
        gl.vertexAttribPointer(aSrc, 2, gl.FLOAT, false, 20, 0);
        gl.enableVertexAttribArray(aColor);
        gl.vertexAttribPointer(aColor, 3, gl.FLOAT, false, 20, 8);
        gl.uniform1f(gl.getUniformLocation(partPrg, 'uTime'), t);
        gl.uniform1f(gl.getUniformLocation(partPrg, 'uLevel'), data.level);
        gl.uniform1f(gl.getUniformLocation(partPrg, 'uKick'), data.kick);
        gl.uniform2f(gl.getUniformLocation(partPrg, 'uImgScale'), img.scaleX, img.scaleY);
        gl.enable(gl.BLEND); gl.blendFunc(gl.ONE, gl.ONE);
        gl.drawArrays(gl.POINTS, 0, img.particleCount);
        gl.disable(gl.BLEND);
        // copy dst → screen
        gl.bindFramebuffer(gl.FRAMEBUFFER, null);
        gl.viewport(0, 0, canvas.width, canvas.height);
        gl.useProgram(copyPrg); bindQuad(copyPrg);
        gl.uniform2f(gl.getUniformLocation(copyPrg, 'uRes'), canvas.width, canvas.height);
        gl.uniform1f(gl.getUniformLocation(copyPrg, 'uFade'), 1.0);
        gl.activeTexture(gl.TEXTURE0); gl.bindTexture(gl.TEXTURE_2D, textures[dst]);
        gl.uniform1i(gl.getUniformLocation(copyPrg, 'uTex'), 0);
        gl.drawArrays(gl.TRIANGLES, 0, 3);
        src = dst;
      } else if (isImage && img) {
        // ── STRETCH / GLITCH → fullscreen fragment direct to screen ──
        const cw = canvas.width, ch = canvas.height;
        // cover: scale image to fill the canvas, cropping as needed (no black bars)
        const canvasAspect = cw / ch;
        let sx = 1, sy = 1;
        if (img.aspect > canvasAspect) sx = img.aspect / canvasAspect;
        else sy = canvasAspect / img.aspect;
        gl.bindFramebuffer(gl.FRAMEBUFFER, null);
        gl.viewport(0, 0, cw, ch);
        gl.useProgram(imgPrg); bindQuad(imgPrg);
        gl.uniform2f(gl.getUniformLocation(imgPrg, 'uRes'), cw, ch);
        gl.uniform1f(gl.getUniformLocation(imgPrg, 'uTime'), t);
        gl.uniform1f(gl.getUniformLocation(imgPrg, 'uLevel'), data.level);
        gl.uniform1f(gl.getUniformLocation(imgPrg, 'uKick'), data.kick);
        gl.uniform1f(gl.getUniformLocation(imgPrg, 'uPreset'), pr);
        gl.uniform3f(gl.getUniformLocation(imgPrg, 'uColor'), cr, cg, cb);
        gl.uniform2f(gl.getUniformLocation(imgPrg, 'uImgScale'), sx, sy);
        gl.activeTexture(gl.TEXTURE0); gl.bindTexture(gl.TEXTURE_2D, img.tex);
        gl.uniform1i(gl.getUniformLocation(imgPrg, 'uImage'), 0);
        gl.activeTexture(gl.TEXTURE1); gl.bindTexture(gl.TEXTURE_2D, waveTex);
        gl.uniform1i(gl.getUniformLocation(imgPrg, 'uWave'), 1);
        gl.disable(gl.BLEND);
        gl.drawArrays(gl.TRIANGLES, 0, 3);
      } else {
        // ── ABSTRACT (osc/tunnel/scope), or image preset w/o image yet ──
        const abstractPreset = isImage ? pr % 3 : pr;
        const dst = 1 - src;
        gl.bindFramebuffer(gl.FRAMEBUFFER, fbos[dst]);
        gl.viewport(0, 0, simW, simH);
        gl.useProgram(simPrg); bindQuad(simPrg);
        gl.uniform2f(gl.getUniformLocation(simPrg, 'uRes'), simW, simH);
        gl.uniform1f(gl.getUniformLocation(simPrg, 'uTime'), t);
        gl.uniform1f(gl.getUniformLocation(simPrg, 'uLevel'), data.level);
        gl.uniform1f(gl.getUniformLocation(simPrg, 'uKick'), data.kick);
        gl.uniform1f(gl.getUniformLocation(simPrg, 'uBeat'), beat);
        gl.uniform1f(gl.getUniformLocation(simPrg, 'uPreset'), abstractPreset);
        gl.uniform3f(gl.getUniformLocation(simPrg, 'uColor'), cr, cg, cb);
        gl.activeTexture(gl.TEXTURE0); gl.bindTexture(gl.TEXTURE_2D, textures[src]);
        gl.uniform1i(gl.getUniformLocation(simPrg, 'uPrev'), 0);
        gl.activeTexture(gl.TEXTURE1); gl.bindTexture(gl.TEXTURE_2D, waveTex);
        gl.uniform1i(gl.getUniformLocation(simPrg, 'uWave'), 1);
        gl.disable(gl.BLEND);
        gl.drawArrays(gl.TRIANGLES, 0, 3);

        gl.bindFramebuffer(gl.FRAMEBUFFER, null);
        gl.viewport(0, 0, canvas.width, canvas.height);
        gl.useProgram(copyPrg); bindQuad(copyPrg);
        gl.uniform2f(gl.getUniformLocation(copyPrg, 'uRes'), canvas.width, canvas.height);
        gl.uniform1f(gl.getUniformLocation(copyPrg, 'uFade'), 1.0);
        gl.activeTexture(gl.TEXTURE0); gl.bindTexture(gl.TEXTURE_2D, textures[dst]);
        gl.uniform1i(gl.getUniformLocation(copyPrg, 'uTex'), 0);
        gl.drawArrays(gl.TRIANGLES, 0, 3);
        src = dst;
      }
    };
    raf = requestAnimationFrame(render);

    return () => {
      cancelAnimationFrame(raf);
      ro.disconnect();
      gl.getExtension('WEBGL_lose_context')?.loseContext();
      glRef.current = null;
    };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  // ── Load image → texture + particle buffer ───────────────────────────────
  useEffect(() => {
    const gl = glRef.current;
    if (!gl || !imageSrc) { imageGLRef.current = null; return; }
    let cancelled = false;
    const image = new Image();
    image.onload = () => {
      if (cancelled || !glRef.current) return;
      const g = glRef.current;
      // Texture
      const tex = g.createTexture()!;
      g.bindTexture(g.TEXTURE_2D, tex);
      g.pixelStorei(g.UNPACK_FLIP_Y_WEBGL, 1);
      g.texImage2D(g.TEXTURE_2D, 0, g.RGBA, g.RGBA, g.UNSIGNED_BYTE, image);
      g.texParameteri(g.TEXTURE_2D, g.TEXTURE_MIN_FILTER, g.LINEAR);
      g.texParameteri(g.TEXTURE_2D, g.TEXTURE_MAG_FILTER, g.LINEAR);
      g.texParameteri(g.TEXTURE_2D, g.TEXTURE_WRAP_S, g.CLAMP_TO_EDGE);
      g.texParameteri(g.TEXTURE_2D, g.TEXTURE_WRAP_T, g.CLAMP_TO_EDGE);

      // Particle grid: sample the image at grid resolution via a 2D canvas.
      const aspect = image.width / image.height;
      let gw = PARTICLE_GRID_W;
      let gh = Math.round(gw / aspect);
      while (gw * gh > PARTICLE_MAX) { gw = Math.floor(gw * 0.92); gh = Math.round(gw / aspect); }
      const off = document.createElement('canvas');
      off.width = gw; off.height = gh;
      const ctx = off.getContext('2d')!;
      ctx.drawImage(image, 0, 0, gw, gh);
      const pix = ctx.getImageData(0, 0, gw, gh).data;
      // letterbox: image square mapped to -1..1, scaled to fit screen later
      const data = new Float32Array(gw * gh * 5);
      let o = 0;
      for (let y = 0; y < gh; y++) {
        for (let x = 0; x < gw; x++) {
          const u = (x + 0.5) / gw, v = (y + 0.5) / gh;
          data[o++] = u * 2 - 1;        // aSrc.x  (-1..1)
          data[o++] = (1 - v) * 2 - 1;  // aSrc.y  (flip)
          const pi = (y * gw + x) * 4;
          data[o++] = pix[pi] / 255;
          data[o++] = pix[pi + 1] / 255;
          data[o++] = pix[pi + 2] / 255;
        }
      }
      const vbo = g.createBuffer()!;
      g.bindBuffer(g.ARRAY_BUFFER, vbo);
      g.bufferData(g.ARRAY_BUFFER, data, g.STATIC_DRAW);

      // Fit the unit square into the canvas aspect for particles.
      const ca = canvasAspectRef.current;
      let scaleX = 1, scaleY = 1;
      if (aspect > ca) scaleY = ca / aspect; else scaleX = aspect / ca;

      imageGLRef.current = {
        tex, particleVBO: vbo, particleCount: gw * gh,
        scaleX, scaleY, aspect,
      };
    };
    image.src = imageSrc;
    return () => { cancelled = true; };
  }, [imageSrc]);

  // ESC exits fullscreen
  useEffect(() => {
    if (mode !== 'full') return;
    const onKey = (e: KeyboardEvent) => { if (e.key === 'Escape') onExitFull(); };
    window.addEventListener('keydown', onKey);
    return () => window.removeEventListener('keydown', onKey);
  }, [mode, onExitFull]);

  const needsImage = preset >= FIRST_IMAGE_PRESET && !imageSrc;

  return (
    <div
      className={`jam-visual-layer ${mode === 'full' ? 'is-full' : 'is-bg'}`}
      onClick={mode === 'full' ? onExitFull : undefined}
    >
      <canvas ref={canvasRef} />
      {needsImage && <div className="jam-visual-needimg">upload an image for this effect</div>}
      {mode === 'full' && <div className="jam-visual-hint">click or esc to exit</div>}
    </div>
  );
}
