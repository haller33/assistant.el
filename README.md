# Assistant.el

**LFM 2.5 Audio TTS for Emacs**  
Speak selected text, paragraphs, or whole buffers using a local LFM audio server.

---

## Overview

`assistant.el` is a lightweight Emacs minor mode that sends text to a running
[llama-liquid-audio-server](https://github.com/ggerganov/llama.cpp) instance
and plays back the generated speech. It works asynchronously via Server‑Sent
Events (SSE) and produces standard WAV files.

- **Streaming TTS** – audio is played as soon as generation finishes.
- **Zero‑click workflow** – speak a region, line, or buffer with a single keybinding.
- **Local only** – everything runs on your machine; no cloud dependency.
- **Hackable** – plain Emacs Lisp, easy to customise or extend.

---

## Requirements

- Emacs 28.1 or newer.
- [llama.cpp](https://github.com/ggerganov/llama.cpp) built with LFM audio support.
- The LFM 2.5 Audio model files (`LFM2.5-Audio-1.5B-Q4_0.gguf`, projector, vocoder, tokenizer).
- One of: `ffplay`, `aplay`, `play` (sox), or Emacs' built‑in sound support.

---

## Installation

### Manual

```bash
git clone https://github.com/your/assistant.el ~/.emacs.d/lisp/assistant
```

Add to your `init.el`:

```elisp
(add-to-list 'load-path "~/.emacs.d/lisp/assistant")
(require 'assistant)
(assistant-mode 1)
```

### Doom Emacs

```elisp
(package! assistant
  :recipe (:local-repo "~/path/to/assistant"))
```

### Straight.el

```elisp
(straight-use-package
 '(assistant :type git :host github :repo "your/assistant.el"))
```

---

## Configuration

Customise the following variables to match your setup:

| Variable                        | Default                                   | Description                                   |
|---------------------------------|-------------------------------------------|-----------------------------------------------|
| `assistant-api-url`             | `"http://localhost:8080"`                 | Server endpoint.                              |
| `assistant-server-binary`       | `"/home/synbian/rbin/llama-liquid-audio-server"` | Path to server executable.              |
| `assistant-ckpt-dir`            | `"/home/synbian/git/wget/AI/Models/LFM"`  | Directory containing model files.             |
| `assistant-model-file`          | `"LFM2.5-Audio-1.5B-Q4_0.gguf"`           | Main model file.                              |
| `assistant-system-prompt`       | `"Perform TTS. Use the US female voice."` | Voice / style instruction.                    |
| `assistant-output-dir`          | `"~/assistant-output/"`                   | Where WAV and debug files are saved.          |
| `assistant-keep-output`         | `t`                                       | Keep files after playback.                    |
| `assistant-playback-command`    | `nil` (auto‑detect)                       | Custom player command (e.g. `"mpv --no-video"`). |

Set them in your config, e.g.:

```elisp
(setq assistant-server-binary "/usr/local/bin/llama-liquid-audio-server")
(setq assistant-ckpt-dir "~/models/lfm")
```

---

## Usage

1. **Start the server**  
   `M-x assistant-server-start` or run it manually in a terminal:
   ```bash
   llama-liquid-audio-server -m … -mm … -mv … --tts-speaker-file …
   ```

2. **Enable the minor mode**  
   `M-x assistant-mode` (or enable it globally in your config).

3. **Speak text**  
   - Select a region and press `C-c t s`.  
   - Speak the current paragraph: `C-c t p`.  
   - Speak the current line: `C-c t l`.  
   - Speak the whole buffer: `C-c t b`.

4. **Playback & control**  
   - `C-c t a` – play the last generated audio.  
   - `C-c t c` – cancel an ongoing generation.  
   - `C-c t m` – open the transient menu.

---

## Keybindings

| Key       | Command                     |
|-----------|-----------------------------|
| `C-c t s` | `assistant-speak-region`    |
| `C-c t p` | `assistant-speak-paragraph` |
| `C-c t l` | `assistant-speak-line`      |
| `C-c t b` | `assistant-speak-buffer`    |
| `C-c t a` | `assistant-play-last`       |
| `C-c t c` | `assistant-cancel`          |
| `C-c t m` | `assistant-menu`            |
| `C-c t S` | `assistant-server-start`    |
| `C-c t h` | `assistant-check-health`    |

All bindings are under the `C-c t` prefix when `assistant-mode` is active.

---

## Debugging

If no audio is produced, check the `*assistant-debug*` buffer.  
Generated files are stored in `assistant-output-dir`:
- `tts-*.pcm` – raw 16‑bit PCM (24000 Hz, mono).
- `tts-*.wav` – playable WAV.
- `tts-*-response.txt` – full HTTP response from the server.

You can open the PCM file in Audacity (Import → Raw Data) with:
- Signed 16‑bit PCM, Little‑endian, 1 channel, 24000 Hz.

---

## Integration with whisper-client

If [whisper-client.el](https://github.com/your/whisper-client) is installed,
`assistant.el` will automatically log TTS generations to its SQLite history.

---

## License

Copyright (C) 2026 Your Name

MIT LICENSE
