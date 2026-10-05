# Changelog

## 2.0.0 - 2026-10-05

### Added

- `value` variants: a variant may carry a literal, marker-free JSON
`value` instead of a CEL `expression` (exactly one of the two).
- `Resolver.annotate` / `Resolver.annotateNode` and the new `Annotation`
class apply a rule book push-style: every rule's winning variant
annotates every node. Requires a resolved tree.
- Add value variants and annotation books
- `Resolver(context: …)` and the `{"context": "a/b"}` input form let
rules read read-only caller data that is not in the tree. Context
inputs are never blocked, bound as copies, and never modify the
context; selectors stay tree-only (use `when`). `RuleInput` gains
`context` and `isContext`; new `validateContextPath` and `readContext`
in `tree_reader.dart`.
- `where` (`MarkerFilter`) on `resolve`, `resolveVerbose`, and
`resolveAtomic` for staged resolution: only selected markers are
resolved, plus the unselected markers they wait for.
- Add resolver context and partial resolution

### Changed

- **Breaking:** `RuleVariant.expression` is now `String?` (null for
`value` variants); `RuleVariant` gains `value` and `hasValue`.
- **Breaking:** `RuleInput.query` is now `String?` (null for `context`
inputs); `RuleInput`'s constructor takes exactly one of `query` /
`context`. `MissingInputException.query` holds the context path for a
context input.
- `resolveAtomic` writes back only the nodes whose data changed, so
untouched nodes keep their data maps and nested values.

## 1.2.0 - 2026-08-14

### Changed

- Rework copyright headers
- Use ggwsm in pipelines
- Install the dna_ggsuite DNA

### Fixed

- Cleanup copy right headers. Update to dart 3.13. Auto fixes.
- Cleanup copy right headers. Update to dart 3.13. Auto fixes. Setup quick-check pipeline.

## 1.1.0 - 2026-07-21

### Added

- Add examples, goldens and remove paragraph sign from rule names
- Add when field for rule selectors, allowing CEL for values

## 1.0.1 - 2026-07-13

### Changed

- Update dependencies

## 1.0.0 - 2026-07-10

### Added

- Add resolveAtomic for atomic in-place resolution

## 0.3.0 - 2026-07-10

### Changed

- Verbose mode

## 0.2.0 - 2026-07-09

### Added

- `Resolver` accepts an optional `expressionCache` so resolvers built
per fit/article share compiled expressions instead of re-parsing the
rule book each time (warm construction ~99% cheaper).
- Benchmark harness under `benchmark/` (six workload profiles, JIT and
AOT) with baselines and attribution in `benchmark/RESULTS.md`.

### Changed

- Performance: `readQuery` walks the search chain once — the marker
scan is now the engine of record and returns the value directly
instead of re-reading via `Tree.getOrNull`, also dropping a
redundant deep marker check. Added a per-`select()` read cache and a
bounded parsed-query cache. Large read-path and end-to-end speedups
with no behavior change.

## 0.1.0 - 2026-07-08

### Added

- Rule data model: `RuleBook` (JSON round-trip, merge with ascending
priority, lint, did-you-mean suggestions), `Rule` (variants,
CSS-like specificity, optional flag, result types), `RuleVariant`,
`RuleInput`, `Selector`.
- `CompiledExpression`: compile-once CEL wrapper reporting syntax
errors at compile time (with line and column), JSON-safe input
binding, and concise error mapping.
- `Resolver`: one `resolve()` call replaces every reference
(`{"§": "§rule"}`) and inline `§expression` map — worklist with
deferral, rule aliasing with cycle detection, optional rules,
result-type validation, and stuck diagnostics naming every pending
item. Strings are never references, so resolved trees stay
re-resolvable without escaping rules.
- Sealed exception hierarchy with typed fields
(`UnknownRuleException`, `CircularAliasException`, ...).
- Property-based test layer: a readQuery-vs-gg_tree conformance
corpus and resolver invariants (marker-free, idempotent,
order-independent) over random trees and rule books.
- CEL conformance fixtures (`test/fixtures/cel_conformance.json`)
pinning the supported cross-language subset.

### Changed

- Correct version in pubspec for publish
- Correct version in changelog for publish
- Correct version in changelog for publish again

## 0.0.2 - 2026-06-30

### Added

- Initial boilerplate.
