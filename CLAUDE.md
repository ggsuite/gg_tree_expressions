# gg_tree_expressions — working notes

Rule/expression system for gg_tree: tree values reference JSON-defined
rules whose CEL expressions evaluate in node context; one
`Resolver.resolve()` answers everything. Generic OSS package
(ggsuite), no ds_*/CARAT dependencies.

**Read `doc/architecture.md` first** — §12 has the decision log
(D1–D11), §13 the implementation decisions, corrections, and the two
post-review revisions (§13.4 review fixes, §13.5 format revision).
Do not trust older material (blog post "Regeln im SlotTree",
pre-§13.5 docs): it shows `"§name"` **string** references, which no
longer exist.

## Format essentials (post §13.5)

- Reference = map `{"§": "§ruleName"}` (single reserved key, value =
  rule key verbatim). Inline expression = `{"§expression": …,
  "§inputs": {…}}`.
- **Strings are always data.** `"§name"` is never a reference; there
  is no escaping mechanism. Map keys starting with `§` are reserved;
  a marker map matching no known form fails with a clear error.
- Blocking is shape-based: any value containing a marker map defers
  the reader. Do not reintroduce state-dependent blocking (an
  `isPending` predicate existed briefly and was deliberately
  removed).
- All errors are subtypes of the sealed `TreeExpressionsException`
  (typed fields; tests should assert types, not only message text).

## Landmines — do not "simplify" these away

1. **cel 0.5.4+1 prints ANTLR diagnostics to stderr on every parse.**
   `gg one can commit` never drains child stderr → **deadlocks**
   (dartvm freezes, one `.vm.json` missing under `coverage/test/`).
   That is why `CompiledExpression._parse` replicates the engine's
   parse listener-free via `package:cel/gen/` + `antlr4`. Nothing in
   this package (incl. tests) may write to stderr.
2. **The engine swallows syntax errors** into `'<<error>>'` string
   literals; `_containsParseError` + the collecting error listener
   exist because `Environment.compile` cannot be trusted to reject
   bad sources. `-x` (unary minus on non-literals) parses "fine" and
   is caught the same way.
3. **`_JsonEnvironment` overrides `Environment.adapter`** so the
   interpreter uses the JSON-safe `_JsonTypeAdapter`. Without it,
   index access into bound maps with list/null members, ternary
   list/null branches, and most list bindings crash with
   `UnimplementedError`.
4. **Results are written by direct container mutation**
   (`parent[key] = result`), never `Tree.set` — gg_json's
   runtime-type guard throws when a value changes type.
5. **`tree_reader.dart` mirrors gg_tree's private `_getOrNull`
   search — and since the single-walk optimization (branch
   `Performance`) the mirror is the ENGINE OF RECORD, not just a
   block detector.** `readQuery` now returns the value the scan
   walks to instead of re-reading via `Tree.getOrNull` (that is only
   the fallback for the `#node/...` namespace and shape anomalies).
   So a gg_tree/gg_json drift no longer just breaks block detection —
   it can return WRONG resolution VALUES.
   `test/tree_reader_conformance_test.dart` pins the mirror against
   the real read over a random corpus and is now load-bearing: run it
   FIRST after any gg_tree/gg_json bump, and bump its iteration count
   (shipped tripwire is 120; validate at ≥1000 when touching the read
   path). If it fails, gg_tree semantics drifted. Verified against
   gg_tree 2.5.0 / gg_json 3.2.0 (note: gg_json's deep equality is
   literally named `deeplEquals`).
6. The `// ignore_for_file: implementation_imports` in
   `compiled_expression.dart` is deliberate (declared mitigation
   boundary). A cel version bump can break these src imports — the
   conformance fixtures in `test/fixtures/cel_conformance.json` pin
   every engine quirk (int-left arithmetic truncation, identity list
   equality, unsupported `m[0].key`, bytes-as-int-lists, …) and must
   be re-run on upgrade.

## Coverage & workflow

- `gg one can commit` enforces **per-file 1:1 coverage**:
  `lib/src/x.dart` counts only hits produced by `test/x_test.dart`.
  Every new src file needs its mirror test reaching 100% alone.
  Extra non-mirror tests (property/conformance harnesses) are fine.
- Property tests use fixed seeds (`Random(2026…)`) — keep them
  deterministic; `Date.now`-style seeding makes CI flaky.
- Ship via `gg do commit` / `gg do push` — CI runs `gg did commit` /
  `gg did push` and fails on plain git pushes. Never commit
  `coverage/`; `.gg/.gg.json` is tool-managed state.
- Sources are UTF-8 (no BOM); `§` may *display* as `ยง` if an editor
  misdetects the charset — check bytes (`0xC2 0xA7`) before
  "fixing", and never convert, only reload as UTF-8.

## Open items

- Verbose/provenance mode (which rule/variant produced each value) —
  wanted eventually, off by default (user decision, answer 9).
- ds_slot adapter: a `ResolveRulesFitter` wrapping `resolve()` —
  needs copy semantics or a transaction story, since `inPlace: true`
  leaves partial state on error.
- Performance: profiled and optimized on branch `Performance`
  (2026-07-09). Four evidence-gated wins landed — per-select read
  cache, bounded parsed-query cache in `tree_reader`, single-walk
  `readQuery` (the marker scan is now the engine of record; see
  landmine 5), and an injectable shared expression cache on
  `Resolver`. Benchmarks live in `benchmark/` (ignored by gg); run
  `dart run benchmark/main.dart jit 2.0` or the AOT exe; baselines +
  acquitted candidates (book indexing, allocation trims) in
  `benchmark/RESULTS.md`. Book indexing / per-node memoization were
  measured unnecessary. Not pushed.
- cel upstreaming candidates: stderr-free parsing, adapter
  pass-through fix.
