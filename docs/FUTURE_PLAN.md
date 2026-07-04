# Nihongo Buddy — Future Plan

**Vision:** grow from a voice conversation partner (v1) into a full-fledged, fully **offline** Japanese learning app — **Learn, Practice, Track** — all on the same local stack (Gemma 4 E2B + Kokoro + SQLite). No accounts, no cloud, no subscriptions required to function.

The conversation app ships first because it generates the data every other module feeds on.

---

## Product Arc

```
v1  Conversation partner        ← PROCEDURE.md (current build)
v2  Track                       ← dashboard over data v1 already collects
v3  Practice                    ← drills + SRS driven by tracked weaknesses
v4  Learn                       ← generated mini-lessons targeting weak points
```

Order matters: Track before Practice before Learn — each module consumes the previous one's data.

---

## Design Decisions to Make in v1 (cheap now, expensive later)

These go into the v1 build (PROCEDURE.md §7) so future modules need zero migration:

1. **Generic `learning_events` table** instead of a mistakes-only store:
   ```sql
   CREATE TABLE learning_events (
     id INTEGER PRIMARY KEY,
     ts DATETIME NOT NULL,
     session_id INTEGER NOT NULL,
     type TEXT NOT NULL,        -- mistake | success | new_word | drill_result
     item TEXT NOT NULL,        -- the word/phrase/sentence involved
     wrong TEXT,                -- what user said (mistakes only)
     correct TEXT,              -- corrected form
     grammar_point TEXT,        -- e.g. "particle を vs に"
     jlpt_level TEXT            -- N5 | N4 | N3 | ...
   );
   ```
   Track successes too, not only errors — progress needs both sides.
2. **JLPT level tag on every event** from day one. Retrofitting level data onto months of history is impossible.
3. **Session records:** `{start, end, turn_count, mistake_count, new_item_count}` — streaks, minutes-practiced, and charts come free later.
4. **Engine/UI separation** (already in v1 architecture): `ConversationEngine` is one mode; `DrillEngine` and `LessonEngine` become siblings sharing `BrainEngine` + `SpeechOutput`.

---

## v2 — Track (dashboard)

Pure UI over SQLite. No new AI work.

- **Streaks & time practiced** — from session records.
- **Weakness heatmap** — grammar points ranked by recurring-mistake count; "conquered" when N consecutive successes follow.
- **JLPT coverage** — vocabulary/grammar encountered vs typical N5/N4 syllabus checklists (bundled static JSON, offline).
- **Trend lines** — mistakes-per-session over time; the "you're improving" graph is the retention feature.
- Buddy references the data in character: "Ohh! One week streak?? I'm SO proud. Don't you dare break it tomorrow."

## v3 — Practice (drills + SRS)

- **SRS scheduler:** SM-2 algorithm (~50 lines, no dependency) over `learning_events` items. Due-today queue on launch.
- **Voice drills:** Buddy prompts ("Say: 'I went to school yesterday' — in Japanese!"), user answers by voice, Gemma scores against expected form, result logged as `drill_result`.
- **Drill types:** particle fill-in, verb conjugation, vocab recall, listen-and-repeat (Kokoro speaks, user repeats, Gemma compares).
- **Targeted sets:** auto-built from the weakness heatmap — user's top 5 recurring grammar points become this week's drill deck.
- Personality carries over: drills framed as Buddy "testing you because it cares," teasing on repeat offenders.

## v4 — Learn (generated mini-lessons)

- **On-device lesson generation:** Gemma writes a 3–5 minute mini-lesson targeting one weak grammar point — explanation (English), 3 examples (Japanese, Kokoro-spoken), then hands off to a v3 drill for immediate practice.
- **Level-matched:** lesson vocabulary constrained to user's JLPT level ± known words.
- **Curriculum spine:** bundled static N5→N4 grammar-point sequence (offline JSON); generation fills it with personalized content, weakness data reorders it.
- Loop closes: Learn → Practice → tracked → weakness updates → next lesson chosen.

---

## Later / Maybe

- iOS/iPad version (whole stack — MLX/CoreML/llama.cpp — runs on iPhone-class hardware; E2B does ~30 tok/s on phones).
- Multiple characters/voices (Kokoro has 5 Japanese voices; character = system prompt swap + own Rive/Live2D rig).
- **Character animation upgrades** (v1 ships with state-swapped GIFs — PROCEDURE.md §7.5). Both swap in behind the `CharacterView` protocol:
  - *Step 1 — Rive:* official native Apple Swift runtime, state machines authored in the Rive editor, vector-crisp, smooth transitions between states, lip flap via Kokoro audio amplitude → mouth input.
  - *Step 2 — Live2D Cubism:* full VTuber-grade waifu rig — mesh deformation, hair physics, built-in phoneme lip sync; native C++ SDK with Metal renderer on macOS. Commission rigged model on nizima/VGen; publication license fee applies at ship time.
- Unlockable outfits/expressions tied to streaks and conquered grammar points (Track data → cosmetic rewards — retention loop).
- Kanji handwriting practice (PencilKit, iPad).
- Optional iCloud sync of the SQLite DB (private, still no server of ours).
- Export progress report (PDF) — "show your teacher."

---

## Constraints (never violate)

1. **Offline is the product.** Every feature must work with networking disabled. No feature that needs a server.
2. **One brain, one voice.** New modules reuse Gemma + Kokoro via existing protocols — no per-feature models unless benchmarks force it.
3. **Personality everywhere.** Buddy teaches the lessons, runs the drills, celebrates the streaks. Never a sterile flashcard screen.
4. **Data stays local** — user's learning history never leaves the machine (export only by explicit user action).
