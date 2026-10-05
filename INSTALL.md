# Installing Pladder

## Requirements

- macOS 27 or later.
- An Apple Silicon Mac (M1 or newer). The speech model runs on the Neural Engine.
- Xcode 27 (Swift 6.3 or later) to build. There is no binary release yet.
- About 700 MB of disk for the speech model, downloaded once.

## Build and install

```sh
git clone --branch codex/coreai-dictation https://github.com/maxffarrell/pladder.git
cd pladder
./scripts/bundle.sh --install --run
```

This compiles a release build, wraps it into `Pladder.app`, signs it, copies it to `/Applications` and launches it. Pladder lives in the menu bar; there is no Dock icon.

## First launch

1. **Grant Microphone** when macOS asks. That is what records your voice.
2. **Grant Accessibility** when prompted. System Settings opens on the Accessibility list; switch Pladder on. That is what lets Pladder see the push-to-talk key in other apps, paste the result, and notice when you correct a word it got wrong. It does not need Input Monitoring.

   On a standard (non-administrator) account, ticking that box asks for an administrator password, so ask an admin to do it once — the grant is keyed to the app's code signature and survives updates. Without it Pladder still works in a reduced form: Option+Space works the same, any combination with a regular key can be recorded in Settings (a modifier-only key such as Right Command needs Accessibility, and Option+Space stands in for it until then), and the transcript is left on the clipboard for you to paste with ⌘V. Managed Macs can pre-approve Accessibility for Pladder with an MDM Privacy Preferences Policy Control (PPPC) profile, which needs no prompt at all.

   Apple Intelligence, if it is on, powers learned corrections and, if you pick it, the experimental polish; nothing else needs it.
3. **Wait for the model.** The first run downloads the selected Parakeet Core AI bundle from Hugging Face into `~/Library/Application Support/Pladder/CoreAI` and compiles them. The menu bar icon shows progress, and the push-to-talk key is disabled until the engine is ready. This happens once; later launches reuse the verified local files.

Then click into any text field, hold **Option+Space**, say something, and let go.

If a permission was missed, the menu bar menu offers **Grant Accessibility…** and **Grant Microphone…**, and the General tab of Settings shows both with a one-click fix.

## Updating

Pull and run the same command again:

```sh
git pull
./scripts/bundle.sh --install --run
```

The install step quits the running copy and replaces it. Because the app is signed with your development certificate, macOS keeps the Microphone and Accessibility grants across updates. See [Signing](#signing) if it asks again.

## Uninstalling

1. Quit Pladder from the menu bar.
2. Delete `/Applications/Pladder.app`.
3. Optionally delete the settings in `~/Library/Application Support/Pladder` and the models in `~/Library/Application Support/Pladder/CoreAI`.
4. Optionally remove Pladder from Privacy & Security > Accessibility and > Microphone in System Settings.

## Building for development

The project is a Swift package with no Xcode project file; open `Package.swift` in Xcode if you prefer an IDE.

```sh
swift build                      # debug build of everything
swift test                       # unit tests, run in well under a second
./scripts/bundle.sh              # release build → dist/Pladder.app, signed
./scripts/bundle.sh --run        # …and launch it
./scripts/bundle.sh --install    # …and copy to /Applications
swift run pladder-cli audio.wav  # transcribe a file from the terminal
```

### Signing

macOS ties the Microphone and Accessibility grants to the app's code signature. The bundle script looks for an **Apple Development** or **Developer ID Application** certificate in your keychain and signs with the first one it finds, which gives the app a stable identity across rebuilds. Without a certificate it falls back to an ad-hoc signature, which changes on every build and makes macOS ask for both permissions again.

```sh
CODESIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" ./scripts/bundle.sh
CODESIGN_IDENTITY=- ./scripts/bundle.sh     # force ad-hoc
```

A free Apple ID is enough for an Apple Development certificate: sign in to Xcode under Settings > Accounts and click Manage Certificates.

### Command-line transcriber

`pladder-cli` loads the same engine and prints the transcript for any audio file, and nothing else, so a script can read it. It is the quickest way to check the model without the GUI. `--verbose` adds timing, so you can see the real-time factor on your machine, and `--process` runs the app's processors over the text with your dictionary.

```sh
swift run -c release pladder-cli recording.wav
swift run -c release pladder-cli recording.wav --process --verbose
```

It reads WAV, M4A, MP3, FLAC, CAF and Ogg Opus. To use it as the speech-to-text of another program, see [docs/HERMES.md](docs/HERMES.md).

`pladder-cli bench <dir>` runs the benchmark over synthetic fixtures. See [docs/BENCHMARKS.md](docs/BENCHMARKS.md) for the procedure and the M1 baseline.

### Icon and screenshots

The app icon is rendered from code so it can be regenerated at any size, and the README pictures are rendered from the app's own views:

```sh
swift scripts/make-icon.swift Assets     # writes Assets/icon_1024.png
./scripts/make-screenshots.sh            # writes docs/images/*.png
```

`Assets/AppIcon.icns` is built from the icon with `iconutil` and copied into the bundle. The screenshot script needs Screen Recording for the terminal that runs it, and shows a few windows for a second or two.

## Troubleshooting

**The key does nothing.**
Check the menu bar menu. If it says the model is loading or downloading, wait. If it offers **Grant Accessibility…**, the grant is missing; it is keyed to the code signature, so a rebuild with an ad-hoc signature resets it.

**macOS asks for permissions after every build.**
The app was signed ad-hoc. Install a development certificate so the signature stays stable; see [Signing](#signing).

**The model download failed.**
The menu offers **Retry Model Download**. The files come from Hugging Face; a proxy or firewall that blocks it will stop the download. Once the models are in `~/Library/Application Support/Pladder/CoreAI`, no network is needed again.

**Text is pasted into the wrong app.**
Pladder pastes into whatever has keyboard focus when the key is released. Click into the target field before holding the key.

**A plain key stops working in other apps.**
A push-to-talk key without a modifier is swallowed system wide while Pladder runs, so a bare letter or Space would become untypeable. Settings warns about this; use a modifier or a chord.

**Where are the settings?**
`~/Library/Application Support/Pladder/settings.json`, plain JSON. The dictionary can also be imported and exported from the Dictionary tab. Corrections you answered Dismiss to are kept beside it in `dismissed-corrections.json`; delete that file to be asked about them again.

**A word I corrected is never proposed.**
Proposals need Accessibility and Apple Intelligence, and appear in the menu bar menu up to a minute after the dictation, or as soon as you click away from the field. Only a word or two changed into something that sounds alike is proposed; a change of case, a rewording or an edit next to the dictation is not. Terminals, and apps such as Claude Code that run in one, show a screen rather than a text field, so nothing is learned there.

**How do I see the release-to-paste time?**
Every dictation logs one line:

```sh
/usr/bin/log show --last 1h --style compact --predicate 'subsystem == "de.dinooo13.pladder"'
```
