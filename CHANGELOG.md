# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/). No version has been
released yet, so everything is listed under **Unreleased**; the first tagged
release will be 0.1.0.

## [Unreleased]

### Added
- Record **a single app** instead of all system audio, chosen from a picker of apps that are currently playing sound. Browser and Electron helper processes are matched to their app. ([#1](https://github.com/kai-thelonious/Audio-Recorder/pull/1), [#13](https://github.com/kai-thelonious/Audio-Recorder/pull/13))
- **Trim editor** with a waveform, draggable start and end handles, preview, and a non-destructive *Save Trim* that writes `<name> (trimmed).wav`; drag the file straight into Finder or a DAW. ([#2](https://github.com/kai-thelonious/Audio-Recorder/pull/2))
- **Menu bar mode**: run from the menu bar with or without a window and Dock icon; the mode, save folder and source are remembered.
- A redesigned window: the logo bars act as a **live level meter**, with an elapsed-time display, a round record button (Liquid Glass on macOS 26) and *Show in Finder*. The bars are white in dark mode and dark in light mode. ([#9](https://github.com/kai-thelonious/Audio-Recorder/pull/9))
- A **"No audio detected" hint** when three seconds into a recording nothing has been heard, which also happens when audio capture permission was denied. ([#10](https://github.com/kai-thelonious/Audio-Recorder/pull/10))
- **Accessibility**: VoiceOver labels, adjustable trim handles, an announced silence hint, and Reduce Motion support. ([#15](https://github.com/kai-thelonious/Audio-Recorder/pull/15))
- An app icon, an MIT licence, a README, a unit test target, and GitHub Actions CI on macOS 26 and macOS 15. ([#6](https://github.com/kai-thelonious/Audio-Recorder/pull/6), [#7](https://github.com/kai-thelonious/Audio-Recorder/pull/7), [#11](https://github.com/kai-thelonious/Audio-Recorder/pull/11))

### Changed
- Recordings are made on the system-audio tap's own clock, so they no longer depend on the output device's sample rate.
- Source code reorganised into App / Models / Services / ViewModels / Views, with one shared `RecorderViewModel`, a single `AppSettings`, and an `AudioWriter` that owns everything the audio thread touches. The project builds in Swift 6 language mode. ([#3](https://github.com/kai-thelonious/Audio-Recorder/pull/3), [#4](https://github.com/kai-thelonious/Audio-Recorder/pull/4), [#5](https://github.com/kai-thelonious/Audio-Recorder/pull/5), [#14](https://github.com/kai-thelonious/Audio-Recorder/pull/14))
- Minimum macOS is now 14.2 and the app is macOS-only.
- Signing settings moved out of the project file into `Config/Local.xcconfig` (git-ignored); a fresh clone builds ad hoc with no setup. ([#12](https://github.com/kai-thelonious/Audio-Recorder/pull/12))

### Fixed
- Recordings were **silent** because the audio-capture usage description was missing from the app's Info.plist.
- Recordings played back **sped up and pitched up** when the output device ran at a lower sample rate (for example Bluetooth at 16 kHz).
- **Quitting during a recording** left a WAV file that reported zero length; the recording is now finished on quit. ([#8](https://github.com/kai-thelonious/Audio-Recorder/pull/8))
- Recording **a single app** now stops, and says so ("Recording stopped: Spotify quit."), when that app quits; before, the recording carried on with nothing but silence. The file is saved as usual.
- A full disk used to stop saving silently while the app still showed "Recording…"; it now stops and says why, keeping what was recorded. ([#8](https://github.com/kai-thelonious/Audio-Recorder/pull/8))
- Starting two recordings in the same second could overwrite one with the other; names now get ` 2`, ` 3`, … ([#8](https://github.com/kai-thelonious/Audio-Recorder/pull/8))
- A failed start no longer leaves an empty file behind. ([#8](https://github.com/kai-thelonious/Audio-Recorder/pull/8))
- **Crash-safe recordings**: the WAV header is refreshed about once a second while recording, so a crash or force-quit keeps the audio instead of leaving a file that reports zero length.
- Launch crash in menu bar mode, **Show Window** closing immediately in menu-bar-only mode, and recording failing when the saved folder had been deleted (it now falls back to `~/Music`).

### Known limitations
- A crash or force-quit during a recording can lose the last second or two of audio.
- macOS 14 is the stated minimum but is not tested: CI covers macOS 15 and 26 only.

[Unreleased]: https://github.com/kai-thelonious/Audio-Recorder/commits/main
