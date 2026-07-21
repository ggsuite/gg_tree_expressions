# gg_tree_expressions — working notes

Rule/expression system for gg_tree: tree values reference JSON-defined
rules whose CEL expressions evaluate in node context; one
`Resolver.resolve()` answers everything. Generic OSS package
(ggsuite), no domain-specific dependencies.

**Read `doc/architecture.md` first** — §12 has the decision log
(D1–D14), §13 the implementation decisions, corrections, and the
post-review revisions (§13.4 review fixes, §13.5/§13.6 format
revisions, §13.7 ambiguous-tie error, §13.8 `when` predicate).
Do not trust older material (an older internal blog post,
pre-§13.5 docs): it shows `"§name"` **string** references, which no
longer exist. Pre-§13.6 material keys rules with a leading `§`
(`"§ruleName"`); that prefix is gone — rule keys are now plain
identifiers.

## Format essentials (post §13.5)

- Reference = map `{"§": "ruleName"}` (single reserved key `§`, value =
  rule key verbatim). Rule keys are plain identifiers matching
  `^[a-zA-Z][a-zA-Z0-9_]*$` — **no `§` prefix** (dropped §13.6). Inline
  expression = `{"§expression": …, "§inputs": {…}}`.
- **Strings are always data.** `"§name"` is never a reference; there
  is no escaping mechanism. Map keys starting with `§` are reserved;
  a marker map matching no known form fails with a clear error.
- Blocking is shape-based: any value containing a marker map defers
  the reader. Do not reintroduce state-dependent blocking (an
  `isPending` predicate existed briefly and was deliberately
  removed).
- Selection: highest-specificity matching variant wins; a
  same-specificity tie among matches is an `AmbiguousVariantException`
  (no order-based tie-break — D2 reversed by D13/§13.7, so authors must
  disambiguate).
- Variant `when` (§13.8): an optional CEL bool predicate beside the
  equality `selector`; both must hold. Effective specificity is
  `2*conditions + (when?1:0)`, so a `when` breaks same-count ties and
  beats the base; it gives ranges/OR that equality can't. Shares the
  variant's `inputs`; `when`-free books behave exactly as before.
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

## Examples & goldens

- Each core data-model class has a `factory X.example()`
  (`RuleBook`/`Rule`/`RuleVariant`/`RuleInput`/`Selector`), composed
  like `Slot.example()` builds on `Size.example()`. They double as the
  readable shape spec and the golden source, anchored on the doc's
  `borderWidth` example.
- Mirror tests snapshot `example().toJson()` via gg_golden
  `writeGolden` under `test/goldens/<file>/`; `resolver_test` adds an
  end-to-end golden (resolved tree + rich `ResolutionReport`).
- gg_golden's `writeGolden` **always overwrites** — a regression shows
  up as a `git diff` on `test/goldens/`, never a red test. Review that
  diff after any change to a model, its `toJson`, or resolution
  behaviour.

## Open items

- Verbose/provenance mode (which rule/variant produced each value) —
  **implemented** on branch `Verbose-mode`. `Resolver.resolveVerbose(tree,
  {inPlace, rich})` returns `(Tree<T>, ResolutionReport)`; `resolve()` is
  untouched (the tree stays clean — no sidecar keys, so all invariants
  hold). Report is minimal by default (location, kind, rule key, variant
  index, value); `rich: true` adds the winning selector, its `when`
  predicate, bound inputs, expression source, and alias chain. One entry
  per alias hop.
  `lib/src/resolution_report.dart` (`ResolutionReport` / `ProvenanceEntry`
  / `ProvenanceKind`). Capture is threaded via a null-gated `_Recorder`,
  so `resolve()` pays nothing.
- Consumer adapter: **shipped** — a consumer's pipeline step wraps
  `resolveAtomic` (optional book; skips marker-free trees so their
  data-map key order stays byte-stable) and `resolveVerbose` behind an
  `onReport` callback. Downstream wiring lives in the consumer packages
  (their layout chain, config rule-book / rule-writes, and request
  wire + validate-rules dry-run).
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
