# pdf-reader-voice

A self-contained PDF reader that reads aloud and **highlights each word on the original PDF page** as the voice speaks it. Drop in any PDF, pick a voice, hit play, follow along.

Runs entirely on your machine. No accounts, no API keys, no installs beyond a one-time auto-download of the Piper binary + a voice model.

## Features

- **Word-by-word highlight overlaid on the actual PDF** — not a stripped-down text view. The original layout, images, and formatting stay intact; only the current word lights up.
- **Click any word to start reading from there.**
- **Four TTS engines** with different speed/quality/setup trade-offs:

  | Engine | Quality | Setup | Internet | Notes |
  | --- | --- | --- | --- | --- |
  | **System voice** | Basic | None | No | Whatever voices Windows has installed. Robotic SAPI by default. |
  | **Piper (local server)** | Good | Auto on first run (~80 MB) | Only for first download | Fast, offline, ships with `en_US-lessac-medium`. Add more voices by dropping `.onnx` + `.onnx.json` into `voices/`. |
  | **Kokoro (browser)** | Very good | Auto on first use (~80 MB) | Only for first download | Neural TTS that runs in the browser tab via WebGPU/WASM. ~30 voices included. |
  | **Edge Natural voices** | Studio-quality | None | Yes (Edge browser only) | Microsoft's Azure neural voices (Ava, Andrew, Aria, etc.). Real word-timestamp highlighting. Requires Microsoft Edge — Chrome doesn't expose these. |

- **Keyboard:** Space pauses/resumes, Esc stops, click any word to seek.
- **Rate slider** from 0.5× to 2×.

## Quick start

1. Clone or download this repo.
2. Right-click `start.cmd` → **Run** (or double-click).
3. On the first run the script auto-downloads Piper + the default voice (~80 MB total) into `piper/` and `voices/`. Subsequent runs skip straight to serving.
4. Your browser opens to `http://localhost:8910/`. Pick a PDF, choose an engine, hit Play.
5. To stop the server: press Ctrl+C in the PowerShell window that opened, or close it.

## Architecture

- `pdf-reader.html` — the entire UI in one file. Uses PDF.js (CDN) to render pages and extract word positions, overlays transparent `<span>`s per word, and drives the highlight from `onboundary` events (Web Speech / Edge) or proportional audio timing (Piper / Kokoro).
- `start.ps1` — minimal HTTP server in PowerShell (.NET HttpListener). Endpoints:
  - `GET /` → serves the HTML
  - `GET /voices` → lists available Piper voices on disk
  - `POST /tts {text, voice}` → runs `piper.exe` and returns a WAV blob
- `start.cmd` — one-line launcher that runs the PowerShell script with `-ExecutionPolicy Bypass`.

The HTML talks to the server when Piper is selected; everything else (System, Kokoro, Edge) is pure client-side.

## Adding more Piper voices

Grab any `*.onnx` + matching `*.onnx.json` from [huggingface.co/rhasspy/piper-voices](https://huggingface.co/rhasspy/piper-voices/) and drop both files into the `voices/` folder. Reload the page and they appear in the Voice dropdown.

Popular choices:
- `en_US-amy-medium` — warm American female
- `en_US-ryan-high` — clearer American male, larger file
- `en_GB-alan-medium` — British male

## Known limitations

- **PDFs without embedded text** (scanned image PDFs) won't work — there's nothing for the reader to extract or speak. OCR isn't built in yet.
- **Word-highlight positions are estimated proportionally** within each PDF text run. They're pixel-accurate on most text but can drift slightly on heavily kerned or justified lines.
- **Edge Natural voices keep a few seconds of pre-buffered audio** that JavaScript can't flush; pressing Stop prevents any new sentence from starting but the currently buffered chunk may finish playing.
- **Edge engine works only in Microsoft Edge.** Chrome / Firefox don't expose Microsoft's online neural voices via the Web Speech API. Use Kokoro on those browsers instead.

## Requirements

- Windows 10/11 (PowerShell 5.1 or later)
- A modern browser (Edge or Chrome recommended)
- Internet for the first-run download (~80 MB) and for Edge Natural voices / Kokoro model fetch

## License

No license declared yet — defaults to "all rights reserved." Open an issue if you want to use this and need a different arrangement.
