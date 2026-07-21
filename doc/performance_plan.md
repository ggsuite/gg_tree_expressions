# Performance check — plan (hand-off)

Audience: a fresh Claude session (Opus 4.8) with no prior context.
Read first: `CLAUDE.md` (repo root — landmines, coverage regime),
`doc/architecture.md` §11.12 (deferred performance decisions) and
§13 (implementation decisions). Do not start optimizing before
Phase 2 numbers exist — §11.12 deliberately deferred all perf work
until profiling demands it; that bar still applies.

## 0. Preconditions & ground rules

- Verify 0.1.0 was published before starting: `git log --oneline -3`
  should show gg's release commits and `git tag -l` a `0.1.0` tag.
  If the working tree still holds an uncommitted CHANGELOG/publish
  state, stop and ask the user.
- Work on a fresh branch off the current state. Commit per phase,
  do NOT push.
- Hard constraints (violating these breaks the toolchain):
  - `gg one can commit` must stay green. Its coverage is per-file
    1:1 (`lib/src/x.dart` counts only hits from `test/x_test.dart`).
    Any new `lib/src` file needs a mirror test at 100% by itself.
  - Benchmarks go into `benchmark/` (NOT `test/`, NOT `lib/`) —
    gg ignores that folder and `can commit` stays fast.
  - Nothing may ever write to stderr — not even benchmarks — see
    CLAUDE.md (gg deadlocks on undrained stderr).
  - Lints apply repo-wide (80 chars, `public_member_api_docs`,
    format). Keep benchmark code inside `main()`/private helpers to
    avoid doc-comment requirements.
  - The property/conformance tests (`test/resolver_property_test.
    dart`, `test/tree_reader_conformance_test.dart`) are the safety
    net for every optimization — they must stay green untouched.

## 1. Benchmark harness (measure before judging)

Create `benchmark/` with a small Stopwatch-based harness (or dev-dep
`benchmark_harness`; if added, run an online `dart pub get` once so
gg's offline pub get keeps working). Reuse/adapt the generators from
`test/resolver_property_test.dart` for realistic shapes.

Workload profiles (parameterized; sizes reflect a realistic consumer —
trees of tens-to-hundreds of nodes, resolved once per item, potentially
thousands of items per run):

| Profile | Shape | What it stresses |
|---|---|---|
| slotTreeLike | 200–2000 nodes, depth 5–8, refs on ~10% of nodes, book of 10–50 rules, multi-segment inherited queries (`#settings/...`) | the realistic path |
| denseRefs | ref/inline on every node | collect + worklist volume |
| deepChain | dependency chains of length 8 / 32 (ref reads value produced by previous ref) | deferral rounds (worst case: rounds × items) |
| wideBook | 500-rule book, 2–4 selector conditions per variant | `Rule.select` / selector matching |
| bigValues | few refs, but node data holds large nested containers (1k+ entries) | `containsMarker` deep walks on every read |
| growLoop | resolve → add subtrees with new refs → resolve, ×3 | re-collect cost, idempotent re-runs |

Measurements per profile (median + p90 of ≥20 runs after ≥5 warmup
runs; JIT via `dart run` AND one AOT pass via `dart compile exe` —
consumers ship AOT, JIT-only numbers mislead):

- end-to-end `resolve()` — copy mode vs `inPlace: true` (isolates
  `deepCopy` cost),
- `Resolver(ruleBook: …)` construction (eager ANTLR parse + plan of
  every expression — matters if consumers build one Resolver per
  fit; the compile cache `_cache` is per-instance),
- micro: `readQuery` per query shape, `Selector.match`,
  `CompiledExpression.evaluate`, `containsMarker` on large values.

Record everything in `benchmark/RESULTS.md` with machine label and
Dart version. These are the baselines all later commits compare to.

## 2. Attribution profiling

Before reaching for DevTools, hand-instrument with counters — it is
agent-friendly and answers the actual questions. Temporarily (do not
commit instrumentation) count per profile run:

- worklist rounds; items deferred per round,
- `readQuery` calls total, split by caller (selector vs input),
- nodes visited by `_scanForMarkers` (chain length × prefix walks),
- `containsMarker` invocations and visited element counts,
- `CompiledExpression.evaluate` calls,
- allocations worth noting: `entries.toList()` in scans, per-round
  `[...deferred, ...discovered]` rebuilds, `Map.of(inputs)` per
  evaluate.

If wall-time attribution is still unclear, use `package:vm_service`
scripted CPU sampling (no UI needed) on the two slowest profiles.

Known suspicions to confirm or acquit (from the implementation
sessions — see architecture.md §13):

1. Every `readQuery` walks the search chain twice: the marker scan,
   then the real `Tree.getOrNull` (engine of record). Reads are the
   hot loop of everything.
2. `containsMarker` deep-walks every clean read result — on trees
   with large container values this may dominate (`bigValues`).
3. Selector conditions repeat across variants of the same rule
   (same query evaluated per variant per round).
4. Deferral re-runs full select+bind for every deferred item every
   round (`deepChain` quantifies this).
5. gg_tree re-parses `TreeQuery`/`parseJsonPath` on every call —
   both in my scan and in the real read.

## 3. Optimization candidates (only what the numbers convict)

Apply one at a time; full suite + property/conformance tests +
`gg one can commit` green after each; re-benchmark; keep only wins
that are clearly outside run-to-run noise (guideline: >15% on a
relevant profile). One commit per accepted optimization, with
before/after numbers in the commit message. Ranked by expected
value/risk:

1. **Per-`select()` read cache** (low risk): within one
   `Rule.select` call, cache `readQuery` results by query string —
   identical conditions across variants stop re-reading. Contained
   in `rule.dart`/`selector.dart`.
2. **Parsed-query cache** (low risk): cache `TreeQuery`/segment
   parsing per query string in `tree_reader.dart` (query strings
   are a small stable set per book).
3. **Single-walk readQuery** (medium risk, biggest win): the marker
   scan already walks the exact search path — return the value from
   the scan instead of calling `Tree.getOrNull` afterwards. This
   promotes the mirror to engine-of-record: MANDATORY to bump the
   conformance corpus iterations (e.g. 120 → 1000 locally) while
   developing, and keep the shipped corpus as the tripwire.
4. **Shared/injectable expression cache** (low risk): allow passing
   a `Map<String, CompiledExpression>` into `Resolver` (or make the
   cache static) so a Resolver-per-fit consumer does not re-parse
   the book each time. Only if Phase 1 shows construction matters.
5. **`containsMarker` cost** (only if `bigValues` convicts it):
   options — skip deep check when the scan already walked the full
   path clean, or short-circuit on container size heuristics. No
   marker-count bookkeeping unless truly forced; it complicates
   every write.
6. **Book indexing by first selector condition** (§11.12; only if
   `wideBook` convicts `select()`).
7. Allocation trims (`entries.toList()`, round-list rebuilds) —
   last, only with allocation-profiling evidence.

Non-goals: no changes to the reference format, blocking semantics,
error quality, or the cel wrapper's engine repairs (CLAUDE.md
landmines). No async/isolate parallelism — resolution is
mutation-based and order-sensitive within rounds.

## 4. Wrap-up

- `benchmark/RESULTS.md`: baseline vs final numbers per profile,
  plus the acquitted suspicions (explicitly note what was measured
  and NOT optimized, so the next session doesn't re-litigate).
- Update `doc/architecture.md` §11.12 (resolved/refined) and the
  repo `CLAUDE.md` open-items list.
- Decide with the user whether a coarse perf smoke test belongs in
  `test/` (very generous threshold, e.g. 10× baseline, to catch
  catastrophic regressions) — default: no, benchmarks stay manual;
  CI-timing tests flake.
- Report: a short table (profile × before × after), the dominant
  cost found, and what was deliberately left alone.
