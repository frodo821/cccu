# evals

Scratch space for driving real sites and apps with the plugin at volume (harness scripts, JSONL run logs,
screenshots of unexpected pages). Everything in this directory is ignored by git by default; files worth
keeping are whitelisted one by one in `.gitignore` (`!server/evals/<file>`).

Run a harness from `server/`, for example:

```sh
bun run evals/<harness>.ts
```

Harnesses connect to `bin/cccu-server` as an MCP client, so they exercise the same tool layer Claude Code uses.

## Volume test: an e-learning course driven through the user's own Chrome (October 2026)

Method: a general-purpose subagent is given the `cu_*` tools and a one-page brief (how the lessons are built, what
the tools do, what to report), completes three lessons in a row in one tab, and returns a structured report:
outcome, tool issues, long-run effects, snapshot quality, workflow friction, counts. Every report drove fixes and a
release; the lesson results themselves were secondary. The brief lives in `subagent-lesson-prompt.md` (ignored:
it names the course).

What the runs found, in the order the fixes shipped:

| Release | Finding | Change |
|---|---|---|
| 0.3.3 | Modals and scrims swallowed clicks silently | hit test before every real click, `OBSTRUCTED` names the cover, `force` |
| 0.3.4–0.3.6 | Elements in scroll containers report 1x1 frames; frames lag behind layout; `count` off by one | treat tiny frames as off-screen, scroll into view, wait for stable frames, count matches at leaves |
| 0.3.7 | `cu_key` with a browser target sent keys to the front app; a hidden `group` in Chrome's tab strip looked like a cover | resolve pid from the target; frames contained in the target count as the target; `scope: "app"` |
| 0.3.9 | Buttons at the page bottom and hidden inputs behind cards missed ~1 in 25 | visibility judged against the webarea, nudge-scroll clipped buttons, click the sized ancestor of a 1x1 input, `cu_navigate` for the user's Chrome |
| 0.3.10 | The user's typing and mouse collided with the agent's | `cu_session` (app kept in front, input blocked, Escape ×3 to end), per-action input guard, warnings |
| 0.3.11–0.3.12 | Needed evidence for the remaining misses; a crash in the new log; dead helper never restarted | per-click diagnostics in `~/.cccu/helper.log`, crash fix, automatic restart, `cu_query` |
| 0.3.13–0.3.14 | Diagnostics showed presses landing on stale frames right after scrolling | wait after scroll-into-view, press again when the frame moved under the press |
| 0.3.15–0.3.19 | Every question cost act + find + check | change reports on actions (`report`, `reportWaitMs`), positional diff, noise filters |
| 0.3.20–0.3.22 | A re-press hit a button that replaced the first one; a ref pointed at a re-rendered node; a frame was stale before the press | re-press only with evidence, refs re-resolved by tree path, frame refresh when the hit test disagrees |

Numbers: 41 lessons (20 grammar, 21 reading) over 17 runs; test scores 80–100%, mostly 100%. The last run (three lessons, 216 clicks) had no missed click, no retry and no tool error. Calls per lesson went from
95–125 (about 40 round trips) to about 60 (13–16 round trips). Missed clicks went from about 2% to 0–1 per run
of 150–250 clicks, each with a diagnosed cause. No degradation was seen over 3-lesson runs (STALE_REF never
occurred after the ref window was raised to 200).

Limits that stayed: the site exposes no selected state on option buttons (verify through the sentence text or a
screenshot); audio-gated steps cannot be shortened; the course shows only three adaptive cards at a time.
