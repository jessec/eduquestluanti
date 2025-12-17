# Tasks — EduQuest API v2 Migration

## Implementation Tasks

### 1) Update active-question fetch to v2
- [ ] In `application/services/quiz/course_service.lua`, replace the active fetch URL from `/api/questionset/get/active` to `/api/v2/questions/active`.
- [ ] Update JSON parsing to read `data.questionItems` (and optionally `data.courses`).
- [ ] Replace “question sets” cache fields with:
  - [ ] `self._question_items` (array)
  - [ ] `self._courses` (optional array)
  - [ ] `self._last_fetch_time`, retry/refresh behavior unchanged

### 2) Normalize questions to the existing quiz expectations
- [ ] In `application/services/quiz/course_service.lua`, add a normalization function that converts a `questionItem` into the legacy-ish shape consumed by `application/services/quiz/quiz_service.lua`:
  - [ ] `questionText = prompt or title`
  - [ ] `answers = answers[]` (strings)
  - [ ] `correctAnswer`
  - [ ] `questionHash = itemId`
  - [ ] `questionSetId = courseId` (legacy field repurposed)
  - [ ] keep `order`, `selectedAnswer`

### 3) Preserve “random unseen MC question” selection
- [ ] In `application/services/quiz/course_service.lua`, update selection to iterate `questionItems` rather than nested sets/blocks.
- [ ] Define “already answered” as:
  - [ ] server `selectedAnswer != nil` OR
  - [ ] local mod storage marks it answered
- [ ] Keep existing reason codes returned to caller (`loading_or_empty`, `no_unseen_mc`, etc.) where practical.
- [ ] Adopt a one-course-at-a-time selection policy:
  - [ ] Persist `currentCourseId` in mod storage and keep it if still present in the active response.
  - [ ] If unset/invalid, pick a course deterministically (see spec: “Recommended course pick rule”).
  - [ ] Select questions only where `questionItem.courseId == currentCourseId`.
  - [ ] If the current course has no eligible unseen items, rotate to the next eligible course (deterministic selection).

### 4) Replace save endpoint with progress endpoint
- [ ] In `application/services/quiz/course_service.lua`, replace `save_question` with a new save method for:
  - [ ] `POST /api/courses/{courseId}/progress`
  - [ ] JSON payload `{ itemId, currentIndex, selectedAnswer, completed }`
- [ ] In `application/services/quiz/quiz_service.lua`, replace the old `/api/question/save` payload builder with the new payload shape.
- [ ] Ensure the save call uses the correct `courseId` and `itemId` from the normalized question.
- [ ] Populate `currentIndex` from a per-course local attempt counter (not `order`).
- [ ] Default `completed=false`; set `true` only when there are no remaining eligible unseen questions for the current course after saving.

### 5) Update local answered tracking
- [ ] In `application/services/quiz/quiz_service.lua`, store answered items using a stable key:
  - [ ] recommended key format: `"<courseId>:<itemId>"`
- [ ] Mark answered when:
  - [ ] the user advances (`next`) OR
  - [ ] save returns success (preferred)
- [ ] Use the server `selectedAnswer` to suppress repeats even if local storage is empty.
- [ ] Persist per-course attempt counter for `currentIndex`:
  - [ ] `eduquest.course_attempt_counter.<courseId>` increments on successful save.

### 6) Update credit endpoint path
- [ ] In `app/defaults.lua` and/or `infrastructure/settings/settings.lua`, change the default credit endpoint from `/student/credit/get` to `/api/student/credit/get`.
- [ ] In `infrastructure/http/http.lua`, update any assumptions about the response shape (optional if only logging).

### 7) Logging and diagnostics
- [ ] Log counts: fetched `questionItems`, computed unseen MC count, chosen item `courseId/itemId/order`.
- [ ] Log progress POST failures with HTTP code + response body.

## Acceptance Criteria
- [ ] With `secure.http_mods = eduquest` and a valid token/session key, the mod fetches from `GET /api/v2/questions/active`.
- [ ] The mod displays multiple-choice questions with answer options and correct/incorrect feedback unchanged.
- [ ] On Submit, the mod sends `POST /api/courses/{courseId}/progress` with correct payload fields.
- [ ] After answering, the next question is not a repeat of an already-answered item (using server `selectedAnswer` and/or local storage).
- [ ] The mod sticks to one course at a time and rotates deterministically when a course is exhausted.
- [ ] The “credit” call hits `GET /api/student/credit/get` (no 404) and logs success.

## Rollback Plan
- [ ] Keep legacy code paths behind a single switch (optional) or preserve old constants in a small diff for fast revert.
- [ ] If v2 returns empty, fall back to the built-in fallback question bank (already present).
