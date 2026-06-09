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
 * CheatSheet — a slide-over reference of prompt-writing guidance for the
 * music model, grouped by category, with one-click copy (and optional apply).
 */

import { useState } from 'react';

export interface CheatItem {
  text: string;
  note?: string;
}

export interface CheatSection {
  title: string;
  blurb?: string;
  items: CheatItem[];
}

// A genre/instrument/mood/production reference. Prompts are the kind that
// steer the MusicCoCa style conditioning well: concrete genre + texture +
// production descriptors rather than abstract adjectives.
export const CHEAT_SECTIONS: CheatSection[] = [
  {
    title: 'How to write a prompt',
    blurb: 'Stack a few concrete descriptors. A reliable recipe is: genre + instrument/texture + production/mood. Lock tempo and key with the BPM box and the keyboard scale selector instead of writing them.',
    items: [
      { text: 'lo-fi hip hop, dusty rhodes, vinyl crackle' },
      { text: 'driving techno, analog bassline, warehouse reverb' },
      { text: 'cinematic strings, slow build, emotional swell' },
    ],
  },
  {
    title: 'Electronic',
    items: [
      { text: 'minimal techno', note: 'tight, hypnotic four-on-the-floor' },
      { text: 'detroit techno, warm pads, swung hats' },
      { text: 'deep house, soulful chords, rolling bass' },
      { text: 'melodic house, arpeggiated synths, euphoric' },
      { text: 'drum and bass, amen break, sub bass' },
      { text: 'liquid dnb, lush pads, rolling breaks' },
      { text: 'dubstep, wobble bass, half-time' },
      { text: 'ambient techno, granular textures, hypnotic' },
      { text: 'synthwave, retro arps, neon lead' },
      { text: 'idm, glitchy percussion, complex rhythms' },
      { text: 'trance, supersaw lead, uplifting' },
      { text: 'breakbeat, chopped funk drums, acid line' },
    ],
  },
  {
    title: 'Hip-hop / Beats',
    items: [
      { text: 'boom bap, dusty drums, jazzy sample' },
      { text: 'lo-fi hip hop, mellow rhodes, vinyl hiss' },
      { text: 'trap beat, 808 slides, crisp hi-hats' },
      { text: 'drill, sliding 808s, dark piano' },
      { text: 'west coast g-funk, talkbox lead, smooth bass' },
      { text: 'phonk, cowbell melody, distorted 808' },
      { text: 'cloud rap, ethereal pads, reverbed vocals' },
    ],
  },
  {
    title: 'Band / Acoustic',
    items: [
      { text: 'fingerpicked acoustic guitar, intimate, warm' },
      { text: 'indie rock, jangly guitars, driving drums' },
      { text: 'funk band, slap bass, tight horn section' },
      { text: 'jazz trio, brushed drums, walking bass, piano' },
      { text: 'bossa nova, nylon guitar, soft shaker' },
      { text: 'soul, hammond organ, gospel chords' },
      { text: 'reggae, off-beat skank, deep dub bass' },
      { text: 'afrobeat, polyrhythmic percussion, horn stabs' },
      { text: 'post-rock, reverb guitars, slow crescendo' },
      { text: 'blues, slide guitar, shuffle groove' },
    ],
  },
  {
    title: 'Cinematic / Ambient',
    items: [
      { text: 'cinematic strings, swelling, emotional' },
      { text: 'dark ambient drone, evolving textures' },
      { text: 'ethereal ambient pads, weightless, airy' },
      { text: 'epic orchestral, brass, timpani, heroic' },
      { text: 'lo-fi ambient, tape saturation, gentle' },
      { text: 'horror score, dissonant strings, tension' },
      { text: 'meditative, singing bowls, soft drones' },
    ],
  },
  {
    title: 'World / Traditional',
    items: [
      { text: 'flamenco guitar, rapid rasgueado, palmas' },
      { text: 'indian classical, sitar, tabla, drone' },
      { text: 'gamelan, metallic percussion, interlocking' },
      { text: 'celtic, fiddle, tin whistle, bodhran' },
      { text: 'middle eastern, oud, hand percussion' },
      { text: 'japanese, koto, shakuhachi, sparse' },
      { text: 'andean, pan flute, charango, light percussion' },
    ],
  },
  {
    title: 'Texture & production',
    blurb: 'Append these to a genre to shape the sound rather than the style.',
    items: [
      { text: 'vinyl crackle, tape hiss, lo-fi' },
      { text: 'heavy sidechain, pumping' },
      { text: 'wide reverb, spacious, cavernous' },
      { text: 'gritty, distorted, overdriven' },
      { text: 'clean, polished, hi-fi production' },
      { text: 'granular, glitchy, processed' },
      { text: 'warm analog, saturated, vintage' },
      { text: 'sparse, minimal, lots of space' },
    ],
  },
  {
    title: 'Mood',
    items: [
      { text: 'euphoric, uplifting, bright' },
      { text: 'dark, brooding, ominous' },
      { text: 'melancholic, wistful, tender' },
      { text: 'energetic, driving, relentless' },
      { text: 'dreamy, hazy, nostalgic' },
      { text: 'playful, quirky, bouncy' },
      { text: 'tense, suspenseful, urgent' },
    ],
  },
];

export function CheatSheet({
  open,
  onClose,
  onCopy,
  onApply,
  onAiGenerate,
  aiResult,
  aiError,
  aiLoading,
}: {
  open: boolean;
  onClose: () => void;
  onCopy: (text: string) => void;
  onApply?: (text: string) => void;
  onAiGenerate?: (idea: string) => void;
  aiResult?: string | null;
  aiError?: string | null;
  aiLoading?: boolean;
}) {
  const [copied, setCopied] = useState<string | null>(null);
  const [query, setQuery] = useState('');
  const [idea, setIdea] = useState('');

  const copy = (text: string) => {
    onCopy(text);
    setCopied(text);
    window.setTimeout(() => setCopied(c => (c === text ? null : c)), 1100);
  };

  const q = query.trim().toLowerCase();
  const sections = q
    ? CHEAT_SECTIONS.map(s => ({
        ...s,
        items: s.items.filter(
          it => it.text.toLowerCase().includes(q) || it.note?.toLowerCase().includes(q),
        ),
      })).filter(s => s.items.length > 0)
    : CHEAT_SECTIONS;

  return (
    <>
      <div
        className={`jam-cheat-backdrop${open ? ' open' : ''}`}
        onClick={onClose}
      />
      <div className={`jam-cheat-panel${open ? ' open' : ''}`}>
        <div className="jam-cheat-head">
          <span className="jam-cheat-title">Prompt cheat sheet</span>
          <button className="jam-cheat-close" onClick={onClose} aria-label="Close">×</button>
        </div>

        <input
          className="jam-cheat-search"
          type="text"
          placeholder="filter prompts…"
          value={query}
          onChange={e => setQuery(e.target.value)}
        />

        <div className="jam-cheat-body">
          {onAiGenerate && (
            <div className="jam-cheat-ai">
              <div className="jam-cheat-section-title">AI assist</div>
              <p className="jam-cheat-blurb">
                Describe what you want in any language — AI turns it into an engine-tuned prompt.
              </p>
              <textarea
                className="jam-cheat-ai-input"
                placeholder="e.g. 下雨天咖啡馆里的慵懒爵士 / a tense chase scene at night"
                value={idea}
                rows={2}
                onChange={e => setIdea(e.target.value)}
                onKeyDown={e => {
                  if (e.key === 'Enter' && !e.shiftKey) {
                    e.preventDefault();
                    if (idea.trim() && !aiLoading) onAiGenerate(idea);
                  }
                }}
              />
              <div className="jam-cheat-ai-row">
                <button
                  className="jam-cheat-ai-go"
                  disabled={!idea.trim() || !!aiLoading}
                  onClick={() => onAiGenerate(idea)}
                >
                  {aiLoading ? 'generating…' : 'generate'}
                </button>
              </div>
              {aiError && <div className="jam-cheat-ai-error">{aiError}</div>}
              {aiResult && (
                <div className="jam-cheat-ai-result">
                  <button
                    className="jam-cheat-text"
                    title="Copy prompt"
                    onClick={() => copy(aiResult)}
                  >
                    {aiResult}
                  </button>
                  <div className="jam-cheat-actions">
                    {onApply && (
                      <button
                        className="jam-cheat-mini"
                        title="Use this prompt now"
                        onClick={() => onApply(aiResult)}
                      >
                        use
                      </button>
                    )}
                    <button
                      className="jam-cheat-mini"
                      title="Copy to clipboard"
                      onClick={() => copy(aiResult)}
                    >
                      {copied === aiResult ? 'copied' : 'copy'}
                    </button>
                  </div>
                </div>
              )}
            </div>
          )}
          {sections.map(section => (
            <div className="jam-cheat-section" key={section.title}>
              <div className="jam-cheat-section-title">{section.title}</div>
              {section.blurb && <p className="jam-cheat-blurb">{section.blurb}</p>}
              <div className="jam-cheat-items">
                {section.items.map(item => (
                  <div
                    className={`jam-cheat-item${copied === item.text ? ' is-copied' : ''}`}
                    key={item.text}
                  >
                    <div className="jam-cheat-item-main">
                      <button
                        className="jam-cheat-text"
                        title="Copy prompt"
                        onClick={() => copy(item.text)}
                      >
                        {item.text}
                      </button>
                      {item.note && <span className="jam-cheat-note">{item.note}</span>}
                    </div>
                    <div className="jam-cheat-actions">
                      {onApply && (
                        <button
                          className="jam-cheat-mini"
                          title="Use this prompt now"
                          onClick={() => onApply(item.text)}
                        >
                          use
                        </button>
                      )}
                      <button
                        className="jam-cheat-mini"
                        title="Copy to clipboard"
                        onClick={() => copy(item.text)}
                      >
                        {copied === item.text ? 'copied' : 'copy'}
                      </button>
                    </div>
                  </div>
                ))}
              </div>
            </div>
          ))}
          {sections.length === 0 && (
            <div className="jam-cheat-empty">no prompts match “{query}”</div>
          )}
        </div>
      </div>
    </>
  );
}
