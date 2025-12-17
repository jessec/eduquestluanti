# Spec — EduQuest API v2 Migration (Luanti Mod)

## Background
The `eduquest` mod currently integrates with EduQuest via:
- legacy active question sets endpoint (question-set tree)
- legacy save endpoint `/api/question/save`
- legacy credit endpoint `/student/credit/get`

The API has changed to:
- `GET /api/v2/questions/active` returning `data.questionItems[]` + `data.courses[]`
- `POST /api/courses/{courseId}/progress` to save per-item progress
- `GET /api/student/credit/get` for the credit check

This spec describes how to update the integration while keeping the current in-game quiz flow and slideshow UI behavior.

## Goals
- Keep the current quiz UX and slideshow logic working.
- Use v2 endpoints and payload shapes.
- Preserve the “random unseen multiple-choice question” behavior.
- Use a one-course-at-a-time selection policy (sticky, deterministic) so progress/completion semantics remain clear.
- Continue supporting token and session-key based auth.
- Avoid repeats using server state when possible, local mod storage otherwise.

## Non-Goals
- Redesigning UI.
- Introducing new persistence beyond existing mod storage.
- Adding course selection UI (unless required later).

## APIs

### Active questions
**Request**
- `GET /api/v2/questions/active`
- Auth: `Authorization: Bearer <token>`

**Response shape**
```json
{
  "success": true,
  "message": "OK",
  "data": {
    "questionItems": [ /* items */ ],
    "courses": [ /* courses */ ]
  }
}
```

**Question item**
- `courseId` (string UUID)
- `itemId` (string UUID)
- `order` (number)
- `title` (string)
- `prompt` (string)
- `answers` (string[])
- `correctAnswer` (string)
- `selectedAnswer` (string|null)

### Save progress
**Request**
- `POST /api/courses/{courseId}/progress`
- Auth: `Authorization: Bearer <token>`
- Body:
```json
{
  "itemId": "…",
  "currentIndex": 4,
  "selectedAnswer": "…",
  "completed": false
}
```

**Response**
- `data.completedItemIds[]` (array of itemId)
- `data.answers` map `{ [itemId]: selectedAnswer }`
- `data.currentIndex`, `data.completed`

### Credit
**Request**
- `GET /api/student/credit/get`
- Auth: (assumed Bearer; confirm)
**Response**
```json
{"success":true,"message":"","data":{"id":1765937820888,"deltaMinutes":0}}
```

## Internal Data Model (Normalization)
To minimize UI churn, normalize `questionItems[]` into a legacy-ish “question” record compatible with existing quiz code:

**NormalizedQuestion**
- `questionText`: `prompt` or `title`
- `answers`: `answers[]` (strings)
- `correctAnswer`: `correctAnswer`
- `questionHash`: `itemId` (stable unique id)
- `questionSetId`: `courseId` (legacy field reused; treated as the “group id” for saves)
- `order`: `order`
- `selectedAnswer`: `selectedAnswer`
- `_raw`: original item (optional)

This allows the existing “adapt + render + validate correctness” flow to continue with minimal changes, while sourcing data from `questionItems`.

## Selection Rules (Unseen MC)
An item is eligible if:
- `answers` is an array with `#answers >= 2`
- `correctAnswer` is non-empty and matches one of the answers (case/trim normalization consistent with current logic)

An item is considered **already answered** if:
- server reports `selectedAnswer != null`, OR
- local mod storage contains an answered marker for that item

Recommended local storage key (fallback/offline suppression):
- `"<courseId>:<itemId>"`

Selection picks a random item from eligible + unseen.

## Course Policy (One-Course-at-a-Time)
The game runs one course at a time to avoid cognitive switching and to give `completed` a clear meaning.

### Persisted state (mod storage)
- `eduquest.current_course_id` (string, may be empty)
- `eduquest.course_attempt_counter.<courseId>` (integer; used to populate `currentIndex`)
- `questions_done` (existing JSON storage) should store item keys in the format `"<courseId>:<itemId>"` for v2 items

### Recommended deterministic course pick rule (stable + user-friendly)
1. If `eduquest.current_course_id` is set and still appears in `data.courses` (or appears in `questionItems[].courseId`), keep using it.
2. Else choose the course with the **most eligible unseen** questions (computed from `questionItems` under the unseen rules in this spec).
3. Tie-breaker: prefer the most recent `courses[].updatedAt` (if present); otherwise choose the lowest UUID string.

### Course rotation
- If the current course has zero eligible unseen items, select a new course using the same deterministic rule.
- If no course has eligible unseen items:
  - Prefer treating this as “done” for the game session (stop/celebrate), or
  - Optionally allow a “practice wrong” mode if the backend starts returning previously answered/wrong items (future feature; not required for this migration).

## Saving Progress Mapping
When the player submits:
- `courseId` comes from `NormalizedQuestion.questionSetId`
- `itemId` comes from `NormalizedQuestion.questionHash`
- `currentIndex` must **not** assume `order`. Use a per-course local attempt counter:
  - `currentIndex = attemptsCountForCourse` (0, 1, 2, ...) stored under `eduquest.course_attempt_counter.<courseId>`
- `selectedAnswer` comes from the selected answer label (prefer the raw string before any display normalization)
- `completed`:
  - default `false`
  - set `true` only if (a) the game is currently on `courseId` and (b) after marking this item answered there are no remaining eligible unseen items for that course

After a successful save:
- Update local storage to mark the item answered.
- Update in-memory cache (set `selectedAnswer`) to prevent repeats within the same session without waiting for refresh.
- Optionally reconcile with server response (`completedItemIds`, `answers`) to improve correctness.

## Settings / Config
- Keep base URL configurable via existing `eduquest_base_url`.
- Update default credit endpoint to `/api/student/credit/get`.
- If there are any references to legacy question-set endpoints, remove/replace them with the new v2 endpoint.

## Error Handling
- For fetch:
  - 4xx should not retry indefinitely; surface a clear log.
  - 5xx/network should keep the existing retry/backoff pattern.
- For save:
  - if POST fails, do not mark answered in storage; allow retry via re-submit.

## Compatibility Notes
- If `questionItems` is empty or fetch fails, the mod should continue to fall back to built-in questions (current behavior).
- Session-key exchange remains as currently implemented (no change in this migration unless the API changes).

## Open Questions
- Is `completed` required or optional? (Plan: always send it, defaulting to `false` unless safely computable.)
- Does `/api/student/credit/get` require the same Bearer token as questions/progress? (Assumed yes.)
