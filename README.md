# ChronoPlayer

ChronoPlayer is a Linux-first Flutter desktop application that keeps a 24-hour audio playout schedule perfectly aligned to the wall clock. Drop in your audio assets and a schedule JSON and the player will always seek to the exact second that should be audible right now.

## Features

- **Wall-clock alignment** – On launch or resume the correct track is opened and sought to the precise offset for the current time of day, looping if necessary.
- **24-hour schedule** – Reads `assets/schedule.json`, validates coverage, and switches at boundaries automatically.
- **Media playback via `media_kit`** – Bundled with `media_kit_libs_linux` for out-of-the-box Linux desktop playback.
- **System tray controls** – Play/Pause, Next Track, Show/Hide, and Quit, with the window hiding to the tray when closed (playback continues).
- **Dark, compact UI** – Shows current time, slot progress, audio position, and upcoming transitions alongside the full schedule list.
- **Robustness** – Missing files or playback failures are surfaced through an error banner and skipped over so the clock stays on schedule.

## Getting started

```bash
flutter config --enable-linux-desktop
flutter pub get
flutter run -d linux
```

To run on Windows or macOS, enable those desktop targets and ensure the equivalent `media_kit` native libraries are available.

## Customisation

1. Place your MP3 files inside `assets/audio/` (replace the placeholders).
2. Edit `assets/schedule.json` with entries like:

```json
{
  "start": "13:30:00",
  "file": "assets/audio/afternoon_show.mp3",
  "loopWithinSlot": true
}
```

   Ensure the first entry starts at `00:00:00` and that start times are strictly increasing to cover the full 24 hours.

3. Run `flutter pub get` after changing assets so Flutter updates its asset manifest.

## Tests

A lightweight unit test (`test/schedule_test.dart`) verifies the schedule lookup helper logic. Run with:

```bash
flutter test
```

## Tray icon

A lightweight tray icon is generated at runtime and stored temporarily for the native system tray APIs.

## Notes

- When the window close button is pressed the app hides to the tray and continues playback. Use the tray’s **Quit** action to fully exit.
- Volume is persisted across launches via `SharedPreferences`.
- The player detects drift greater than ~250 ms and re-seeks automatically, ensuring long-running accuracy.
