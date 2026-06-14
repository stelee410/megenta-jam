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
 * ChatPanel — a slide-over AI chat that turns a free-form idea (any language)
 * into an engine-tuned music prompt, with one-click copy / apply. Backed by the
 * agentllm c-music-express model via the native bridge.
 */

import { useRef, useState, useEffect } from 'react';

export interface ChatMessage {
  role: 'user' | 'ai' | 'error';
  text: string;
}

export function ChatPanel({
  open,
  onClose,
  history,
  loading,
  onGenerate,
  onClear,
  onCopy,
  onApply,
}: {
  open: boolean;
  onClose: () => void;
  history: ChatMessage[];
  loading: boolean;
  onGenerate: (idea: string) => void;
  onClear: () => void;
  onCopy: (text: string) => void;
  onApply?: (text: string) => void;
}) {
  const [idea, setIdea] = useState('');
  const [copied, setCopied] = useState<string | null>(null);
  const logRef = useRef<HTMLDivElement | null>(null);

  // Keep the newest message in view.
  useEffect(() => {
    if (logRef.current) logRef.current.scrollTop = logRef.current.scrollHeight;
  }, [history, loading, open]);

  const submit = () => {
    const t = idea.trim();
    if (!t || loading) return;
    onGenerate(t);
    setIdea('');
  };

  const copy = (text: string) => {
    onCopy(text);
    setCopied(text);
    window.setTimeout(() => setCopied(c => (c === text ? null : c)), 1100);
  };

  return (
    <>
      <div className={`jam-cheat-backdrop${open ? ' open' : ''}`} onClick={onClose} />
      <div className={`jam-cheat-panel jam-chat-panel${open ? ' open' : ''}`}>
        <div className="jam-cheat-head">
          <span className="jam-cheat-title">AI prompt chat</span>
          <div className="jam-chat-head-actions">
            <button
              className="jam-chat-new"
              onClick={() => { onClear(); setIdea(''); }}
              disabled={loading || history.length === 0}
              title="Start a new chat"
            >
              + new
            </button>
            <button className="jam-cheat-close" onClick={onClose} aria-label="Close">×</button>
          </div>
        </div>
        <p className="jam-chat-intro">
          Describe what you want in any language — AI turns it into an engine-tuned prompt.
        </p>

        <div className="jam-chat-log" ref={logRef}>
          {history.length === 0 && (
            <div className="jam-chat-empty">
              e.g. 下雨天咖啡馆里的慵懒爵士 / a tense chase scene at night
            </div>
          )}
          {history.map((m, i) => {
            if (m.role === 'user') {
              return <div className="jam-chat-msg is-user" key={i}>{m.text}</div>;
            }
            if (m.role === 'error') {
              return <div className="jam-chat-msg is-error" key={i}>{m.text}</div>;
            }
            return (
              <div className="jam-chat-msg is-ai" key={i}>
                <div className="jam-chat-ai-text">{m.text}</div>
                <div className="jam-chat-actions">
                  {onApply && (
                    <button className="jam-cheat-mini" title="Use this prompt now" onClick={() => onApply(m.text)}>
                      use
                    </button>
                  )}
                  <button className="jam-cheat-mini" title="Copy to clipboard" onClick={() => copy(m.text)}>
                    {copied === m.text ? 'copied' : 'copy'}
                  </button>
                </div>
              </div>
            );
          })}
          {loading && <div className="jam-chat-msg is-ai jam-chat-loading">generating…</div>}
        </div>

        <div className="jam-chat-input-row">
          <textarea
            className="jam-chat-input"
            placeholder="describe a vibe… (Enter to send, Shift+Enter for a newline)"
            value={idea}
            rows={2}
            onChange={e => setIdea(e.target.value)}
            onKeyDown={e => {
              // Ignore Enter while an IME is composing (Chinese/Japanese/Korean),
              // so confirming a candidate doesn't accidentally send.
              if (
                e.key === 'Enter' &&
                !e.shiftKey &&
                !e.nativeEvent.isComposing &&
                (e.nativeEvent as KeyboardEvent).keyCode !== 229
              ) {
                e.preventDefault();
                submit();
              }
            }}
          />
          <button className="jam-chat-send" disabled={!idea.trim() || loading} onClick={submit}>
            {loading ? '…' : 'send'}
          </button>
        </div>
      </div>
    </>
  );
}
