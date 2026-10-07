# Listen native<->web protocol v1

The Listen app (standalone, bundle com.oliverullman.listen) hosts a plain WKWebView loading
`http://GL_BAKED_HOST:8315/`. Playback is NATIVE (AVQueuePlayer) because a
WKWebView cannot reliably start audio while the screen is locked. The page
owns all data (library, sections, cards, settings via the :8315 API); native
owns the audio engine, Now Playing, pocket mode and voice commands.

Transport: the Listen view controller registers its OWN WKScriptMessageHandler
named `listen` on the web view's user content controller. Wire shape:

- page -> native: `window.webkit.messageHandlers.listen.postMessage({id, method, params})`
- native -> page reply: `window.__listenReply(id, result, error)` exactly once per request, main queue; `error` is a string or null.
- native -> page events: `window.__listenEvent(name, payload)` (guarded with typeof === 'function').
- Page detects native with `!!window.webkit?.messageHandlers?.listen`; absent (desktop browser, tests) it uses its own JS `<audio>` engine with identical semantics.

## Types

```
Section = {idx:int, start:number, end:number, text:string, translation:string,
           difficulty:int, vocab:[{term,lemma,gloss}],
           audio:{original:url, clear:url, translation:url, vocab:url|null}}
  // `original` is the FULL episode mp3 URL (supports Range); native plays only [start,end].
Settings = {steps:["vocab","clear","translation","original"] (ordered subset),
            autoAdvance:bool, rate:number (0.5-1.5, applies to `original` only),
            englishRate:number (0.5-1.5, applies to `translation` only),
            clearRate?:number (0.5-1.5, applies to `clear` only; absent = 1),
            repeatOriginal:int (1-3), pocketDoublePress:"voice"|"next",
            pocketReplaySlowdown:int (0-50, percent),
            revisitSteps?:"original"|"all" (absent = "original"; see step loop semantics),
            rewinds?:[{steps:[kind...], slow:int 0-50}] (1-4 presets; kind in vocab|clear|translation|original; absent = [{steps:["translation","original"], slow:0}])}
State = {itemId:string|null, idx:int, step:"vocab"|"clear"|"translation"|"original"|null,
         stepIndex:int, stepCount:int, playing:bool, position:number, duration:number,
         pocket:bool, listening:bool, loop:bool, loopRange:{start,end}|null, error:string|null}
```

## Methods (page -> native)

- `load {itemId, title, sections:[Section], settings:Settings, startIdx:int}` -> `{}`; replaces the queue, does not start playing.
- `play {}` / `pause {}` / `toggle {}` -> `{}`
- `next {}` / `prev {}` / `goto {idx}` -> `{}`; moves to that section, restarts its step loop at step 0.
- `replay {kind}` kind in original|clear|translation|vocab -> `{}`; plays that clip for the current section once, then resumes the loop where it was (if it was playing).
- `rewind {steps:[kind...], slow:int 0-50, after?:"resume"|"advance"}` -> `{}`; interrupts, plays the current section's clips in `steps` order (`vocab` skipped when the section has none; empty/unknown steps or no playable step -> error), `original` clips at `rate * (1 - slow/100)`, others at their normal rate, then, with `after` "resume" (the default; pocket gestures, remote commands and voice always use it), resumes the interrupted step from its beginning (if it was playing). With `after` "advance" it instead continues as if the current section's last step had just finished (if it was playing): autoAdvance moves to the next section at step 0, otherwise it pauses with step null; with loop on it returns to looping the current section. A paused player stays paused either way. Any other `after` value is an error. `replay {kind}` is `rewind {steps:[kind], slow:0}` (resume).
- `loop {on:bool, start?:number, end?:number}` -> `{}`; session-only (State.loop and State.loopRange, reset by `load`). `start`/`end` (absolute episode seconds, both or neither, finite, start < end, `on:true` only) restrict the loop to that slice of the section. See step loop semantics.
- `setSettings {settings}` -> `{}`; applies to the current and later sections.
- `getState {}` -> State
- `pocketMode {on:bool}` -> `{}`; native shows/hides its pocket overlay (see below).
- `voice {on:bool}` -> `{}`; starts/stops the in-app voice command listener for ~4 s (`on:true`) or cancels it.

## Events (native -> page)

- `state` State — on every change and at 4 Hz while playing.
- `command {name, idx}` — an action the PAGE must execute because it owns the data: `save` (save current section as a card), `reveal` (show transcript). Raised by voice or pocket gestures.
- `heard {transcript, matched:string|null}` — what the voice listener recognised (for the page to show briefly).
- `error {message}` — playback/audio-session failures, with the real underlying message.

## Step loop semantics (identical in native and the JS fallback)

For section i, for each step in settings.steps in order: play that clip (skip `vocab` when `audio.vocab` is null); `original` is played `repeatOriginal` times at `rate`. After the last step: if autoAdvance, go to i+1 and continue; else pause with idx = i, step = null. `replay` interrupts, plays the clip, then resumes the interrupted step from its beginning. Gaps between clips are ~0.4 s. Position/duration in State describe the CURRENT clip.

Loop (`loop {on:true}`): the current section plays only its `original` clip at `rate`, repeatedly with the normal gap, and never advances; next/prev/goto keep looping the new section. `on:true` while playing interrupts and starts the original from its start; while paused it only sets the flag (play then loops). `on:false` while playing does not interrupt: the clip in flight (and its gap) finishes, then the section counts as finished (advance or pause per autoAdvance). A `rewind` with `after:"advance"` while loop is on returns to looping instead of advancing. State.stepCount is 1 while looping. With a range (`loop {on:true, start, end}`, used by the word popup) only `[max(start, section.start), min(end, section.end)]` of the original repeats at `rate`, with the normal gap, and State.position/duration are relative to that slice; State.loopRange carries the clamped range (null when none). A range outside the section is an error. Calling `loop {on:true}` again while on with a different range, or none, applies it immediately (interrupting a playing clip). The range is cleared by `loop {on:false}`, `load` and any section index change (next/prev/goto/advance), while the loop flag itself keeps the semantics above. `rewind`/`replay` clips ignore the range.

Revisit: the engine tracks `furthest`, the highest section idx entered this session (startIdx on load, updated on every idx change). With `settings.revisitSteps` "original" (also when absent), a section with idx < furthest plays only `["original"]`, exactly once (repeatOriginal ignored); "all" plays the normal steps. State.stepCount reflects loop and revisit. Note the JS fallback (listen/public/engine.js) treats an absent revisitSteps as "all"; the page always sends it.

## Now Playing / remote commands (native)

Title = "<step label> · <section idx+1>/<count>" (labels: Vocab, Clear, English, Original); artist = item title; album = "Listen". Enabled commands: play, pause, togglePlayPause (AirPods send play/pause, not toggle), nextTrack (= next), previousTrack (= replay original), skipForward 15 (= next), skipBackward 15 (= replay original). No others.

## Pocket mode (native)

Full-screen black overlay above the web view: proximity monitoring on (iOS blanks the screen when covered), idle timer disabled, brightness kept at max(current, 0.5) for the first 10 s so the labels are readable, then dropped to minimum (restored on exit), touches ignored except: long-press (0.3 s) anywhere = toggle play/pause; two-finger tap = replay original `pocketReplaySlowdown`% slower than `rate`; two-finger double tap = run `settings.rewinds[0]` (default English then original at normal `rate`); the English-then-again zone label shows that preset's name ("English → Original", "Original 20% slower", ...) and refreshes when settings change; swipe left = next; swipe right = prev; three-finger tap = `command save`. Four giant labelled zones are drawn faintly for when the phone is out of the pocket. Exit: a visible "Exit pocket mode" button needing a 1 s long-press. While in pocket mode, the AirPods double-press (nextTrack) means `voice on` if settings.pocketDoublePress == "voice", else next.

## Voice commands (native)

On-device SFSpeechRecognizer, locale from a small table; mic opened only for the listening window, audio session returns to playback-only afterwards. Vocabulary (either language): again/otra vez -> replay original; english/inglés -> replay translation; clear/claro -> replay clear; vocab/vocabulario -> replay vocab; next/siguiente; back/atrás -> prev; save/guardar -> command save; pause/pausa; play/sigue; slower/más lento (rate -0.1); faster/más rápido (rate +0.1). Unmatched -> `heard` with matched null, nothing else.
