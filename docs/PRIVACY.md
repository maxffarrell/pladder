# Privacy

Privacy here is not a policy, it is how the thing is built. Audio and text never leave your Mac.

- **Audio never leaves the Mac.** The microphone is open only while the key is held, and macOS shows the orange indicator only then. Audio goes from the microphone to the Neural Engine and is discarded.
- **Text never leaves the Mac.** The transcript exists long enough to be pasted. Your previous clipboard is put back afterwards.
- **Learning a correction reads only what was pasted.** After a paste, Pladder watches the field it pasted into for up to a minute through Accessibility, to notice when you fix a word. It reads only the pasted words and a little context, keeps nothing, and asks before adding anything to the dictionary. The check that a correction is plausible runs on Apple's on-device model.
- **Polish runs on the Mac too.** Apple's model is part of macOS; S1-mini by Superwhisper runs on your Mac's GPU through llama.cpp.
- **No network.** The only requests Pladder ever makes are one-time downloads from Hugging Face: the speech model, about 700 MB, on first launch, and, only if you pick S1-mini for the experimental polish, that model too, pinned to a commit and checked against its SHA-256. After that it works with Wi-Fi off. There is no update check, no crash reporter, no analytics.
- **No account.** Nothing to sign up for, nothing to log in to, nothing to cancel.
- **Auditable.** The app is open source under the MIT license, and the downloads are its only network code: [`CoreAIBundleStore.swift`](../Sources/PladderEngines/CoreAIBundleStore.swift) for the speech model (pinned revision and SHA-256 verified archive), and [`ModelFiles.swift`](../Sources/PladderRefine/ModelFiles.swift) for S1-mini.
