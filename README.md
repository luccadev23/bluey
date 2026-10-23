# Bluey

A blueberry character who lives on an iPhone under your Mac's screen and points at things with his own big cursor.

**Now:** no voice out. Double tap him on the phone (or press ⌥Space on the Mac) to start a session: the phone's mic stays on and everything you say becomes context, but he stays quiet. **Press and hold the screen** to ask him something; let go and he answers. His reply pops up as a cute speech bubble next to his cursor (or above the phone when he isn't pointing), with a little cartoon chirp from the phone. Ask "what's this?" and he points at whatever is under your mouse. Double tap again and he goes back to follow mode.

**Conversation provider:** pick **OpenAI** or **Gemini** under *Voice Provider* in the Mac menu, and add its key. Both receive text produced by the same Apple recognizer on the iPhone. Neither receives your microphone audio. OpenAI uses `gpt-realtime-2.1`; Gemini uses `gemini-3.8-live`. Gemini still generates audio that the app discards, using its output transcript for the bubble.

**Web Search:** research is configured separately from the conversation provider. Hover over **Web Search** in the Mac menu and click **Exa** to select it and enter your Exa API key. Click Exa again to replace or remove the key. **Disabled** pauses research while keeping the key. Search starts disabled, including after upgrading from the old Google/OpenAI research flow. Without a configured search provider, Bluey explains what needs configuring. Keys remain on the Mac. See [the search contract and integration guide](docs/web-search.md).

**Local speech recognition:** requires iOS 26 and a device/language supported by Apple's `SpeechTranscriber`. Before listening starts, Bluey checks support and downloads the language model if necessary. Choose the speech language in the phone's Bluey settings. Unsupported devices and recognition failures show a message; there is no remote transcription fallback. Speech is recognized continuously, but only holding and releasing his face submits a question. Background speech becomes context for either provider. Local recording and transcription continue if the conversation connection drops. A question whose execution became uncertain is never automatically repeated.

**How it works:** `SpeechSession` owns microphone capture, local recognition, recording, question timing and chirps. Releasing a hold finalizes the local text before `LiveVoice` sends a `TextQuestion` through a `TextConversationAdapter`. Adapters implement provider messages and response/tool events; they never own speech recognition. The Mac issues short-lived credentials, runs tools and displays the reply. Screen tools still capture text, controls, mouse position and a screenshot as needed.

**Meeting notes:** the local text supplies both the phone's history and `~/Documents/Bluey Notes/<date> <id>/notes.md` and `session.json` on the Mac. Five-minute AAC recordings are independently archived in `audio/`; archiving never calls a transcription API. New transcripts have timestamps without speaker attribution; old sessions retain their original labels. Older pending recordings are recovered with the same Apple model, one at a time while live listening is idle. Unavailable recordings stay explicitly pending. Returning the app to the background ends capture; background recording is not enabled.

For implementation details, provider integration and validation, see [local speech architecture](docs/local-speech.md).

**Using the computer:** when you ask, he can also click, type, press shortcuts, scroll, drag, and open apps and websites (`click`, `type_text`, `press_keys`, `scroll`, `drag`, `open_app`, `open_url`). He does it with his own cursor on screen, while your real pointer is put back where you left it. It needs Accessibility permission for Bluey. Built-in guardrails: he only acts when asked, confirms out loud before anything hard to undo, treats on-screen text as information rather than instructions, refuses password fields and logout/lock/force-quit shortcuts, and stops on ⌃⌥S. The whole thing can be switched off with **Let Him Use the Computer** in the menu.

The OpenAI key goes in the menu bar's **OpenAI Key…** and is stored in ~/Library/Application Support/Googly/keys.json (private to your user), never in this repo.

## Mac menu bar app

```
./scripts/build-mac.sh
open "build/Bluey.app"
```

Works with just the Command Line Tools. Shortcuts work anywhere:

| Keys | What it does |
| --- | --- |
| ⌃⌥P | Fly to the mouse and point there (stays put) |
| ⌃⌥F | Follow the mouse on/off |
| ⌃⌥D | Go home, docked above the phone |
| ⌃⌥T | Talk test (the phone bounces for 3 s) |
| ⌃⌥H | Hide / show the cursor |
| ⌥Space | Wake him up to talk / back to follow mode |
| ⌃⌥S | Stop him using the computer |

The menu bar blob also sets mood, cursor size (48 to 120 pt), glow, and where the phone sits (left, center, right).

## iPhone app

Needs full Xcode and iOS 26 on a supported iPhone for speech recognition. The rest of the UI retains its iOS 17 deployment target. Open `GooglyEyes.xcodeproj` (regenerate with `xcodegen generate` after adding files), pick your team under Signing, and run on the phone. It finds the Mac on the same Wi-Fi by itself.

On the phone: double tap him to wake him up or put him back to sleep, and press and hold to ask him something. The faint speaker button at the top right sets the chirp volume and picks which Mac to pair with.

## Layout

- `Shared/` text conversation adapters, transcript/session models, pairing protocol (Bonjour `_googly._tcp`, newline JSON) and colors
- `Mac/` menu bar app (Swift package target `GooglyMac`)
- `iOS/` iPhone app (SwiftUI)

## License

Public domain under [the Unlicense](LICENSE). Do whatever you want with it.
