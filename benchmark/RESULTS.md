# Benchmark results — gg_tree_expressions

Run `dart run benchmark/main.dart jit 2.0` (JIT) and
`dart compile exe benchmark/main.dart -o build/bench.exe && build/bench.exe
aot 2.0` (AOT). The harness lives in `benchmark/main.dart` and prints
Markdown tables to stdout only (never stderr). Optional args: label
(`jit`/`aot`) and a run-count scale (`2.0` → 40 runs / 10 warmup).

## Environment & methodology

- Dart: `3.11.4 (stable)` on `windows_x64`
- OS: Windows 11 Pro, Build 26200
- CPUs: 16 logical
- Sampling: median + p90 of **40 runs after 10 warmup runs** (scale
  `2.0`; the plan's floor is ≥20 / ≥5).
- End-to-end `resolve()` timed in two modes: **copy** (default —
  includes `deepCopy`) and **inPlace** (a fresh `deepCopy` prepared
  outside the timed region each run, so the copy cost is excluded);
  their difference isolates `deepCopy`. deepChain / growLoop are
  inPlace-only (they mutate / grow their own tree).
- **Cross-run drift** on this machine is ~30 %, which swamps a single
  JIT/AOT pass for the smaller profiles. Every optimization decision
  below therefore used **paired exes** — a fixed baseline binary and
  the optimized binary run back-to-back (and, for the final table,
  min-of-3 interleaved passes) so machine drift cancels. Cold-vs-warm
  construction is measured within one run for the same reason.

Profiles map 1:1 to the plan's workload table.

---

## Headline: baseline 0.1.0 → all four optimizations

End-to-end, AOT, paired baseline-vs-final, **min of 3 interleaved
passes** (drift-cancelled):

| profile | copy Δ | inPlace Δ |
|---|--:|--:|
| slotTreeLike/255 | −28 % | −41 % |
| slotTreeLike/1093 | −25 % | −40 % |
| denseRefs/511 | −33 % | −35 % |
| deepChain/8 | — | −27 % |
| deepChain/32 | — | −22 % |
| wideBook/500 | **−72 %** | **−65 %** |
| bigValues/1000 | −16 % | −18 % |

Reads (the hot loop), AOT micro, baseline → final:

| micro | baseline ns | final ns | Δ |
|---|--:|--:|--:|
| readQuery own (`./#c`) | 902 | 183 | **−80 %** |
| readQuery inherited (`#a`) | 1368 | 438 | −68 % |
| readQuery multi-seg (`#settings/dims/width`) | 2699 | 920 | −66 % |
| readQuery child (`mid#b`) | 888 | 214 | −76 % |
| readQuery indexed (`#list[1]`) | 1197 | 325 | −73 % |
| readQuery absolute (`/#a`) | 1519 | 485 | −68 % |
| Selector.match (hit) | 2955 | 966 | −67 % |
| Selector.match (miss) | 1599 | 492 | −69 % |
| CompiledExpression.evaluate | 199 | 195 | ~0 % (untouched) |
| containsMarker (1000-entry, standalone) | 233580 | 199680 | ~noise |

Resolver construction with a shared, pre-warmed cache (per-fit
consumer), AOT:

| book | cold | warm | Δ |
|---|--:|--:|--:|
| slotBook/30 (60 variants) | 269 µs | **1 µs** | −99.6 % |
| wideBook/500 (580 variants) | 3732 µs | **14 µs** | −99.6 % |

The standalone `containsMarker` micro walks the value directly and was
never changed; opt 3 removed the **redundant second** walk inside
`readQuery`, which is why bigValues end-to-end dropped ~18 % while this
micro did not.

---

## Per-optimization (each: paired before-vs-after, one commit)

| # | Optimization | Convicted by | Result |
|---|---|---|---|
| 1 | Per-select read cache | wideBook (1831 selector reads / 106 selects, ~318 distinct) | wideBook −55 % copy/inPlace; others flat |
| 2 | Parsed-query cache | parses == reads on every profile | readQuery micro −24…−60 %; slotTreeLike/255 −17…−31 % |
| 3 | Single-walk readQuery (folds in candidate 5) | readQuery calls == getOrNull calls everywhere; bigValues did 2 containsMarker walks/read | reads −32…−42 %; slotTreeLike inPlace −50 %; bigValues −18 % |
| 4 | Injectable shared expression cache | construction scales with variants (Phase 1) | warm construction −99.6 % for per-fit consumers |

Details, attribution counts, and before/after numbers are in each
commit message (`git log` on branch `Performance`).

---

## Attribution (Phase 2, throwaway counter instrumentation)

One inPlace resolve per profile, counters since reverted:

- **Reads are walked twice.** `readQueryCalls == realGetOrNull` on
  every profile (denseRefs 1033/1033, wideBook 1831/1831): the marker
  scan and then `getOrNull` walk the identical chain. On slotTreeLike
  the scan alone did ~7.5 node-visits per read (multi-seg reads climb
  to root). → opt 3.
- **`treeQueryParses == jsonPathParses == readQueryCalls`** — every
  read re-parsed; distinct query strings per book are a handful. → opt 2.
- **containsMarker.** bigValues did **64024 element-visits for 8
  reads** (~8000/read = two ~4000-element walks: the scan's plus the
  redundant `readQuery` safety net). Small values are cheap (224
  visits / 96 reads on slotTreeLike). → opt 3 removes the second walk.
- **Selector fan-out.** wideBook: 1831 selector reads for 106 selects
  (17.3/select) but only ~318 distinct condition queries. → opt 1.
- **Deferral.** deepChain/32: 32 rounds, 528 step-calls, 496
  deferrals for 32 items (16.5× re-work). The realistic slotTreeLike
  resolved in **1 round, 0 deferrals** — deferral only bites deep
  dependency chains. (No candidate targets it; see below.)

---

## Deliberately NOT optimized (acquitted, with evidence)

- **Candidate 5 — containsMarker deep-walk cost:** folded into opt 3.
  The dominant waste was the *redundant* second walk in `readQuery`
  (removed). The remaining single walk is semantically required (a
  read must block if the value hides an unresolved marker) and is
  cheap on normal-sized values.
- **Candidate 6 — book indexing by first selector condition:**
  acquitted. After opt 1 the expensive part of `select()` (the reads)
  is cached; wideBook already improved 65–72 %. Remaining variant
  iteration is ns-level cached map lookups. Indexing adds a real index
  structure for a speculative sub-15 % gain on an already-fast path.
- **Candidate 7 — allocation trims (`entries.toList()`, round-list
  rebuilds, `Map.of(inputs)`):** acquitted **by measurement**.
  Removing the two provably-safe `entries.toList()` snapshots in
  `_collect`/`_scanValue` (paired benchmark) moved profiles at most
  ~3–10 %, mostly within noise — no profile cleared the >15 % bar. The
  `.toList()` snapshots were kept (defensive; negligible cost). Round
  rebuilds are 1/round for realistic trees; `Map.of(inputs)` is one
  small copy per evaluate.
- **Deferral re-runs (deepChain):** real (quantified above) but out of
  scope — resolution is mutation-based and order-sensitive within
  rounds (plan non-goal). Opts 2 and 3 still cut deepChain/32 ~22 %.
- **`deepCopy` (copy mode):** a real but minority slice (copy − inPlace
  ≈ 550 µs on slotTreeLike/1093); consumers that own their tree
  already avoid it via `inPlace: true`. Not a code target.

---

## Full baseline vs final tables (AOT, one representative pass)

### Baseline — 0.1.0 (commit d673c78)

#### End-to-end resolve() — median / p90 (µs)

| profile | copy median | copy p90 | inPlace median | inPlace p90 |
|---|--:|--:|--:|--:|
| slotTreeLike/255 | 1087 | 1434 | 753 | 1072 |
| slotTreeLike/1093 | 2658 | 3550 | 1826 | 2547 |
| denseRefs/511 | 7228 | 8589 | 7133 | 8865 |
| deepChain/8 | — | — | 124 | 141 |
| deepChain/32 | — | — | 1754 | 2392 |
| wideBook/500 | 3379 | 4395 | 3387 | 3989 |
| bigValues/1000 | 13671 | 15327 | 12309 | 14095 |

#### Construction (µs) | Micro (ns/op)

| book | cold median |   | micro | median |
|---|--:|---|---|--:|
| slotBook/30 | 347 |   | readQuery own | 902 |
| wideBook/500 | 5430 |   | Selector.match (hit) | 2955 |

### Final — all four optimizations

#### End-to-end resolve() — median / p90 (µs)

| profile | copy median | copy p90 | inPlace median | inPlace p90 |
|---|--:|--:|--:|--:|
| slotTreeLike/255 | 480 | 600 | 238 | 329 |
| slotTreeLike/1093 | 1391 | 1754 | 855 | 1066 |
| denseRefs/511 | 3850 | 4428 | 3271 | 3919 |
| deepChain/8 | — | — | 55 | 58 |
| deepChain/32 | — | — | 1043 | 1188 |
| wideBook/500 | 803 | 876 | 748 | 890 |
| bigValues/1000 | 6800 | 7592 | 6658 | 7159 |

#### Grow loop — resolve → grow → resolve ×3 (resolve µs only)

| profile | resolves | median | p90 |
|---|--:|--:|--:|
| growLoop/x3 | 3 | 242 | 305 |

#### Resolver construction — cold vs shared-cache warm (µs)

| book | rules | variants | cold median | cold p90 | warm median |
|---|--:|--:|--:|--:|--:|
| slotBook/30 | 30 | 60 | 269 | 308 | 1 |
| wideBook/500 | 500 | 580 | 3732 | 4239 | 14 |

#### Micro-benchmarks — median / p90 (ns per op)

| micro | median | p90 |
|---|--:|--:|
| readQuery own (`./#c`) | 183 | 324 |
| readQuery inherited (`#a`) | 438 | 555 |
| readQuery multi-seg inherited (`#settings/dims/width`) | 920 | 1089 |
| readQuery child (`mid#b`) | 214 | 300 |
| readQuery indexed (`#list[1]`) | 325 | 380 |
| readQuery absolute (`/#a`) | 485 | 555 |
| Selector.match (hit) | 966 | 1181 |
| Selector.match (miss) | 492 | 579 |
| CompiledExpression.evaluate | 195 | 224 |
| containsMarker (1000-entry value) | 199680 | 216120 |

(JIT numbers track AOT within ~15–25 % and tell the same story; AOT is
the reference since consumers ship AOT.)
