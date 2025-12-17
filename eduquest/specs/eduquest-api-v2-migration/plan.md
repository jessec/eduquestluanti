# EduQuest API v2 Migration Plan (Luanti Mod)

## Summary
Migrate the `eduquest` Luanti/Minetest mod from legacy EduQuest endpoints to the new API while preserving the current in-game behavior:

- Fetch active multiple-choice questions.
- Show them in the existing slideshow UI.
- Save per-question progress.
- Avoid repeating already-answered questions.
- Keep the existing token/session-key flow.

## Milestones

### M1 — Confirm target API contract
- Confirm base URL stays `https://server.eduquest.vip`.
- Confirm endpoints:
  - `GET /api/v2/questions/active`
  - `POST /api/courses/{courseId}/progress`
  - `GET /api/student/credit/get`
- Confirm auth requirements (Bearer token) and error codes.
- Confirm `currentIndex` semantics for progress saves.

### M2 — Introduce a normalized internal question model
- Define a “legacy-shaped” question record derived from `questionItems[]`:
  - `questionText`, `answers`, `correctAnswer`
  - stable IDs: `courseId`, `itemId`, `order`
  - answered marker: `selectedAnswer` (optional)
- Keep the slideshow UI and selection logic working against this normalized shape.

### M3 — Update fetch/cache/selection
- Replace question-set caching with question-item caching.
- Preserve “random unseen multiple-choice question” selection.
- Define “answered/unseen” using (in this order):
  - server `selectedAnswer != null` when present
  - local mod storage as a fallback/back-compat
- Adopt a one-course-at-a-time selection policy (deterministic course choice; sticky between sessions).

### M4 — Update save/progress call
- Replace `/api/question/save` with `POST /api/courses/{courseId}/progress`.
- Map UI selection → payload (`itemId`, `currentIndex`, `selectedAnswer`, `completed`).
- Set `currentIndex` from a per-course local attempt counter (not `order`).
- Compute `completed=true` only when the current course has no remaining eligible unseen items after saving; otherwise `false`.
- Update local answered tracking immediately on successful save.

### M5 — Update credit endpoint
- Update legacy `/student/credit/get` to `/api/student/credit/get`.
- Keep behavior minimal (logging / optional parsing).

### M6 — Verification pass
- Manual test checklist:
  - HTTP permission configured (`secure.http_mods = eduquest`)
  - token/session key present
  - questions appear
  - submit calls progress endpoint
  - next question differs and previously answered questions do not repeat

## Out of Scope (for this migration)
- UI redesign.
- Persistence beyond existing mod storage.
- Multi-course UI/selection controls (unless required by new API behavior).

## Open Questions (to resolve before coding)
- Confirm whether `completed` is required or optional (we will send it, defaulting to `false` unless we can safely compute course completion).
- Confirm `GET /api/student/credit/get` uses the same Bearer token as questions/progress (assumed yes).
