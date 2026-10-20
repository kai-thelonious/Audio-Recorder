# AudioRecorder

A small macOS app that records everything your Mac is playing — music, videos, calls — to a WAV file.

It uses Core Audio process taps, so it captures system audio directly: no virtual audio driver, no loopback device, and it works the same whether you're listening on speakers, headphones or Bluetooth.

## Requirements

- macOS 14.2 or later

## Usage

1. Open AudioRecorder.
2. Optionally click **Choose Folder…** to pick where recordings are saved (defaults to `~/Music`).
3. Click **Record**. The first time, macOS asks for permission to capture system audio — click **Allow**.
4. Click **Stop**. The recording is saved as `Recording <date> <time>.wav` (16-bit PCM, stereo).

If you denied the permission by accident, enable AudioRecorder under
**System Settings → Privacy & Security → Screen & System Audio Recording → System Audio Recording Only**.

## Building from source

1. Open `AudioRecorder.xcodeproj` in Xcode.
2. Under the AudioRecorder target's **Signing & Capabilities**, choose your own team.
3. Build and run (⌘R).

## How it works

The recorder creates a global `CATapDescription` tap of all system audio, wraps it in a private aggregate device with no sub-devices (so it runs on the tap's own clock and sample rate), and writes the buffers it receives to disk with `AVAudioFile`. See `AudioRecorder/MyApp.swift`.

## License

[MIT](LICENSE)
