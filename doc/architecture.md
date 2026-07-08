# gg_tree_expressions — Architecture & Implementation Plan

Status: **implemented** (0.1.0, 2026-07-07). This document defines
the data model, schema, syntax, and resolution semantics for the rule
expression system, plus an implementation roadmap and the list of
decisions that are still open. §13 records the decisions taken at
implementation start and the corrections that came out of verifying
the dependency APIs (`gg_tree` 2.3.1, `gg_json` 3.1.1, `cel` 0.5.4+1).

---

## 1. Goal

Provide a small, open-source Dart package that lets consumers

1. attach **rule references** to properties of a `gg_tree` tree,
2. define the **rules** themselves as plain JSON data (a *rule book*),
   with per-context overrides selected declaratively,
3. **resolve** all references in one pass: every reference is replaced
   by the value its rule's CEL expression evaluates to, in the context
   of the node that carries the reference.

One sentence: *values in a tree can say "ask rule X", and the resolver
answers every such question in place.*

The package is generic. It knows nothing about furniture, catalogs, or
any other domain — it depends only on `gg_tree`, `gg_json`, and `cel`.
Domain semantics (what the resolved values *mean*) belong to consumers.

---

## 2. Evaluation of the planning input

The planning (see the internal "Regeln im SlotTree" post) holds up well
against the actual `gg_tree` 2.3.1 / `ds_slot` APIs. Findings from the
code review that refine it:

| Planning statement | Assessment |
|---|---|
| Rules address tree properties via inheritance and relative/absolute paths | Directly supported: `Tree.getOrNull` already implements upward search (`searchToRoot`), own-node anchoring (`./#key`), node paths (`a/b#key`), and absolute paths. The rule system reuses this untouched. |
| "Resolution happens in one step over the whole tree, root-down" | Almost. A strict single root-down pass breaks when a rule's input reads a value that is *itself* a still-unresolved reference on a sibling or via an absolute path. The design below keeps the single `resolve()` call but implements it as a **worklist with deferral** — order-independent, with built-in cycle detection. |
| References are written as `{key: "§ruleName"}` string values | Confirmed and kept. Note the `§` prefix appears in two places with different roles: as the **rule book key** (`"§panelWidth": [...]`) and as the **reference value** in tree data (`"§panelWidth"`). Tree data *keys* stay plain camelCase. |
| Selectors (formerly "tags") pick rule variants per manufacturer/catalog/… | Modeled as tree-query → literal equality conditions. Works because step 1 of the strategy (standardized tree) guarantees the queried paths exist. In this package that standardization is a *consumer contract*, not code. |
| CEL as engine; rules also producible from JavaScript | `cel` 0.5.4+1 (Dart) and `@bufbuild/cel` (TS) both implement the CEL spec. Keeping expressions inside the common subset + shared JSON test fixtures gives cross-language parity. |
| Existing CEL usage (`showIf` in a downstream package) | Works, but substitutes query results into the expression *source* via regex and recompiles per evaluation (its compile cache is keyed inconsistently and rarely hits). This package instead compiles each expression **once** and binds inputs per evaluation through CEL's activation map. |
| Rule results: variables, growth instructions, fitter control | Only **values** are in scope here. Growth and processing-step control are consumer interpretations of resolved values (see §9). The resolver is deliberately re-runnable so consumers can loop resolve → grow → resolve. |

---

## 3. Concepts and terminology

| Term | Meaning |
|---|---|
| **Reference** | A string value in tree data of the form `§ruleName`. Placeholder that resolution replaces with a concrete value. |
| **Rule** | A named unit (`§ruleName`) consisting of one or more variants. |
| **Variant** | One concrete definition of a rule: optional selector, optional inputs, one CEL expression. |
| **Selector** | A set of `treeQuery = literal` conditions deciding whether a variant applies at a given node. All conditions must hold (AND). |
| **Rule book** | A JSON document mapping rule keys to variant lists. Multiple books can be merged in a defined order. |
| **Resolver** | Walks a tree, finds all references, selects the winning variant per reference in node context, evaluates it, writes the result. |
| **Input** | A named binding from a CEL identifier to a tree query, evaluated relative to the node holding the reference. |

---

## 4. Rule data model & JSON schema

### 4.1 Rule book

A rule book is a JSON object. Every top-level key is a rule key and
must match:

```
^§[a-zA-Z][a-zA-Z0-9_]*$        (camelCase preferred)
```

Every value is a **list of variants**. A variant without a selector is
the *base* definition (specificity 0). Uniform lists — rather than a
nested `base` + `overrides` shape — make merging several rule books a
plain concatenation per key.

```jsonc
{
  "§borderWidth": [
    {
      // Base definition: applies everywhere.
      "expression": "1.0"
    },
    {
      // Override for one context.
      "selector": { "theme#id": "dark" },
      "expression": "2.0"
    },
    {
      // Override with inputs read from the tree.
      "selector": { "theme#id": "dark", "#platform": "mobile" },
      "inputs": { "screenWidth": "screen#width" },
      "expression": "screenWidth < 400.0 ? 3.0 : 2.0",
      "description": "Thicker borders on small dark-mode screens."
    }
  ]
}
```

### 4.2 Variant fields

| Field | Type | Required | Meaning |
|---|---|---|---|
| `expression` | string (CEL) | yes | Computes the rule result from the bound inputs. |
| `selector` | object: treeQuery → literal | no | Conditions for this variant to apply. Absent/empty = base variant. |
| `inputs` | object: identifier → query | no | Binds CEL identifiers to tree queries. Identifier must be a valid CEL identifier; query uses `gg_tree` query syntax. |
| `description` | string | no | Documentation only. |

Input values (long form) may declare a default used when the query
resolves to nothing:

```jsonc
"inputs": {
  "screenWidth": "screen#width",                          // short form
  "margin": { "query": "#margin", "default": 4.0 }        // long form
}
```

Without a default, an unresolvable input query is an **error** (fail
fast, with node path + query in the message).

### 4.3 Selector semantics

- Each condition key is a `gg_tree` query (`node/path#data/key`), each
  value a JSON scalar (string, number, bool). The condition holds when
  `node.getOrNull(query) == literal`.
- Queries use normal `gg_tree` semantics, evaluated **from the node
  holding the reference** — so `manufacturer#id` finds the nearest
  ancestor's `manufacturer` child node, `#articleType` searches data
  upward, `./#x` anchors to the node itself.
- A query that resolves to nothing makes the condition **false** (not
  an error).
- All conditions of a selector must hold (AND). OR is expressed by
  adding another variant.

### 4.4 Precedence (decided)

When several variants of the same rule match a node:

1. **Specificity wins**: the variant with the most selector conditions
   is chosen (CSS-like). Base variant has specificity 0.
2. **Ties**: the variant that appears **later** in the merged rule book
   wins. Merge order is defined by the caller
   (`RuleBook.merge([general, …, specific])`), so "later" means "from
   the more specific book" — e.g. global → vendor → catalog → item.

If **no** variant matches (all variants carry selectors, none applies),
resolution fails with a diagnostic listing the rule, node path, and the
selectors that were tried. Authors are encouraged to always provide a
base variant. (An `optional` flag is an open question, §11.)

### 4.5 References in tree data

- A reference is a string value exactly matching the rule-key pattern:
  `"§borderWidth"`. It may sit at any depth inside a node's data map
  (nested maps and list elements included).
- Strings starting with `§` that do **not** match the pattern (e.g.
  `"§ 5 Abs. 2"`) are ordinary literals and never touched.
- Strings that match the pattern but name an **unknown rule** are an
  error (they are almost certainly typos). Consequence: a literal
  string that exactly looks like a rule key cannot be represented in
  v1 — see open question §11.1.
- Rule *results* that themselves match the reference pattern are an
  error in v1 (no aliasing/indirection — §11.2).

Example tree (generic UI-configurator flavor):

```
app                     data: { platform: "mobile" }
├─ theme                data: { id: "dark" }
├─ screen               data: { width: 380.0 }
└─ dialog               data: { borderWidth: "§borderWidth" }
   └─ okButton          data: { }
```

After `resolve()`, `dialog.borderWidth == 3.0`. `okButton` never sees
the rule — it reads the **resolved** value via plain inheritance
(`getOrNull('#borderWidth')`), exactly as the planning intends:
resolve once at a chosen node, inherit everywhere below, re-declare the
same reference deeper in the tree to re-evaluate in a more specific
context.

---

## 5. Expression engine

### 5.1 Choice: CEL via the `cel` package (decided)

Rationale (from the project planning): no heavyweight JS engine in the
lightweight generator, no eval security surface, engine already proven
in the stack, and rule *authoring* can still happen in JS/TS via
`@bufbuild/cel` because CEL is a cross-language spec.

### 5.2 Integration design

- **Compile once, evaluate many.** `Environment.standard()` compiles
  each distinct expression source to a `Program` exactly once; a cache
  keyed by the source string lives in the resolver (not a global).
- **Inputs are CEL variables.** Evaluation passes
  `program.evaluate({identifier: value, …})`. No string substitution
  into the source — this is the main correction over the existing
  `showIf` implementation downstream.
- Results are converted to Dart natives by the engine
  (`convertToNative()`): num, String, bool, List, Map. Whatever comes
  back is written verbatim as JSON data.

### 5.3 Supported CEL subset & gotchas

- `cel` 0.5.x implements the core spec **without macros, protobuf
  types, or custom function registration**. v1 restricts rule books to
  this subset; it is also the subset shared with `@bufbuild/cel`.
- CEL is strict about int vs double: `screenWidth < 400` fails if
  `screenWidth` is bound to a double — write `400.0`. Schema validation
  should surface engine errors with the rule key and expression in the
  message. (Possible input auto-coercion: open question §11.3.)
- No `min`/`max` built-ins in standard CEL; use the ternary
  (`a < b ? a : b`) or pre-compute via inputs. Custom functions are an
  upstream-contribution candidate (§11.4).
- The engine is wrapped behind one small class (`CompiledExpression`)
  so the package could swap or upgrade engines without touching the
  rule model.

---

## 6. Resolution algorithm

Signature (sketch):

```dart
final resolver = Resolver(ruleBook: book);
final resolved = resolver.resolve(tree);            // returns a copy
resolver.resolve(tree, inPlace: true);              // mutate directly
```

Semantics:

1. **Working tree.** By default resolution runs on a `deepCopy()` of
   the input; the original keeps its references and can be re-resolved
   later against changed context (matches the planning: results go into
   a copy). `inPlace: true` skips the copy for pipeline steps that own
   their tree.
2. **Collect.** One `visit` (top-down) over the working tree deep-scans
   every node's data for reference strings, producing work items
   `(node, containerLocation, ruleKey)`.
3. **Worklist rounds.** Repeatedly sweep the pending items:
   - **Select variant**: evaluate selectors at the item's node. If a
     selector read hits a value that is itself an unresolved reference,
     **defer** the item to the next round.
   - **Bind inputs**: evaluate each input query from the node. If a
     value is (or deep-contains) an unresolved reference, defer.
     Missing value without default → error.
   - **Evaluate** the compiled expression with the bound inputs.
   - **Write** the result at the reference's exact location in the
     node's data (replacing the reference string, including inside
     nested maps/lists) and drop the item.
4. **Termination.** A round that resolves nothing while items remain
   aborts with a diagnostic listing every pending item and the query it
   is blocked on — this reports both dependency cycles and unresolvable
   setups in one message. Otherwise the loop ends when the list is
   empty (≤ N rounds for N references).
5. **Idempotency.** A resolved tree contains no reference strings, so
   `resolve()` on it is a no-op. Consumers implementing *growth* can
   therefore loop: resolve → interpret values → add subtrees (which may
   carry new references) → resolve again.

Why a worklist instead of the planned strict single root-down pass:
top-down ordering already resolves the common parent→child dependency
chain in round one, but inputs may legally read siblings or absolute
paths whose references are not yet resolved. Deferral makes the result
independent of traversal order without giving up the "one call resolves
the whole tree" contract.

Error reporting follows `gg_tree`'s style: every failure names the node
path, the rule key, the variant, and — where applicable — the available
alternatives.

---

## 7. Public API sketch

```dart
// Data model (all JSON round-trip capable)
class RuleBook {
  factory RuleBook.fromJson(Json json);
  factory RuleBook.merge(Iterable<RuleBook> booksInAscendingPriority);
  Rule? ruleForKey(String key);        // '§borderWidth'
  Json toJson();
}

class Rule {
  final String key;                    // with § prefix
  final List<RuleVariant> variants;
  RuleVariant? select(Tree<Json> node);
}

class RuleVariant {
  final Selector selector;             // Selector.none for base
  final Map<String, RuleInput> inputs;
  final String expression;
  final String? description;
}

class RuleInput {
  final String query;
  final Object? defaultValue;
  final bool hasDefault;
}

class Selector {
  final Map<String, Object?> conditions;
  int get specificity;
  MatchResult match(Tree<Json> node);  // matched | notMatched | blocked
}

// Engine wrapper
class CompiledExpression {
  factory CompiledExpression.compile(String source); // cached
  Object? evaluate(Map<String, Object?> inputs);
}

// Resolution
class Resolver {
  Resolver({required RuleBook ruleBook});
  Tree<T> resolve<T extends Json>(Tree<T> tree, {bool inPlace = false});
  Object? resolveRule(Tree<Json> node, Rule rule); // single-shot helper
}
```

Notes:

- Everything is generic over `Tree<T extends Json>`; no subclass
  knowledge. Result writes mutate the working copy's data containers
  directly, which also covers references inside lists (where
  path-based `set` has no index syntax).
- `RuleBook.merge` takes books in ascending priority; later books win
  specificity ties (§4.4).
- `resolveRule` exists for tooling and tests (evaluate one rule at one
  node without a tree sweep).

---

## 8. Package structure & dependencies

```
lib/
  gg_tree_expressions.dart      // exports
  src/
    rule_book.dart
    rule.dart
    rule_variant.dart
    rule_input.dart
    selector.dart
    rule_ref.dart               // reference pattern, escaping, markers
    result_type.dart            // optional result validation
    tree_reader.dart            // marker-aware query reads (defer)
    compiled_expression.dart    // CEL wrapper + cache
    resolver.dart
    tree_expressions_exception.dart
    did_you_mean.dart           // suggestion helper
example/
  gg_tree_expressions_example.dart
test/
  ... (mirrors src/, plus fixtures/)
  fixtures/*.json               // cross-language CEL conformance
                                // vectors, reusable from a TS harness
doc/
  architecture.md               // this document
```

`pubspec.yaml` changes (as implemented):

```yaml
dependencies:
  gg_json: ^3.2.0
  gg_tree: ^2.5.0
  antlr4: ^4.13.2    # listener-free CEL parsing, see §13.3
  cel: ^0.5.4+1
```

(`path` was dropped.) Dev deps: `coverage`, `lints`, `test`. License
compatibility: `cel` (cel-dart) is MIT — fine for this repository.

---

## 9. Downstream integration (informative, out of scope here)

How the generic package serves the original planning goals — none of
this lives in this repository:

- **Processing-step wrapper.** Consumers with a step-chain concept
  (e.g. a `Fitter` in `ds_slot`) wrap `Resolver.resolve` as one step in
  their pipeline, positioned after the standardized tree is built and
  before steps that consume the resolved variables.
- **Growth instructions.** A rule may return structured JSON (e.g.
  `{"add": "innerDrawer", "count": 2}`). A consumer step interprets
  such values, grows the tree, and re-runs `resolve()` for the new
  nodes. The resolver's idempotency and re-runnability are the enabling
  contract; the instruction vocabulary is consumer-defined (§11.5).
- **Step control.** Steps read resolved plain variables
  (`getOrNull('#…')`) to decide their behavior — no coupling to this
  package beyond the data they read.
- **Guarded subclass keys.** Tree subclasses that gate certain data
  keys behind typed accessors keep their invariants at *authoring*
  time (references are written through the gated `set`). The resolver
  only replaces values that already exist. Whether the resolver should
  additionally route writes through `Tree.set` to re-enforce subclass
  gates on JSON-imported trees is open (§11.6).
- **Selector vocabulary.** Selectors like `manufacturer#id` only work
  if the consumer's trees reliably contain those nodes/keys — that is
  exactly the already-completed "standardized tree" step of the
  planning, and it remains a consumer contract.
- **Migration candidate.** The existing downstream `showIf` mechanism
  (regex substitution + per-node recompile) can later be re-based onto
  `CompiledExpression` to gain the compile-once cache.

---

## 10. Implementation roadmap

Each phase lands with 100 % test coverage and green CI before the next
starts.

1. **Data model.** `RuleBook`, `Rule`, `RuleVariant`, `RuleInput`,
   `Selector` + JSON round-trip, key validation, merge, specificity
   ordering, selector matching against `Tree<Json>` (no CEL yet —
   expressions are opaque strings). Table-driven tests for precedence.
2. **Expression layer.** `CompiledExpression` with compile cache,
   input binding, native result conversion, error mapping (rule key +
   expression in every message). Conformance fixtures under
   `test/fixtures/` defining the supported CEL subset.
3. **Resolver.** Reference scanning (nested maps/lists), worklist with
   deferral, copy/inPlace, defaults, cycle & blocked diagnostics,
   idempotency and resolve-grow-resolve tests.
4. **DX & release.** README with the §4 example, dartdoc, `example/`,
   error-message polish, CHANGELOG, publish `0.1.0`.

Phase 1 and 2 are independent and could proceed in parallel; phase 3
depends on both.

---

## 11. Open questions & deferred decisions

1. **Literal `§` strings.** A literal value that exactly matches the
   reference pattern is unrepresentable in v1. If the need arises:
   `§§name` escaping (breaks naive idempotency — the unescape must
   happen exactly once) vs. an object reference form
   (`{"§": "name"}`) that frees the string namespace entirely.
2. **Rule aliasing.** Should a rule result that is itself a reference
   be re-enqueued (giving indirection for free via the existing cycle
   detection) instead of erroring? v1: error, revisit on demand.
3. **Numeric coercion.** Auto-convert int↔double at the input boundary
   to soften CEL's strict typing, or keep strict and rely on authoring
   discipline (`400.0`)? v1: strict.
4. **Custom CEL functions.** `min`/`max`/`round` etc. are not in the
   standard library and `cel`-dart has no registration hook yet.
   Options: upstream contribution, vendored fork, or pre-computed
   inputs. Also note the single-maintainer risk of `cel`-dart — the
   `CompiledExpression` wrapper is the mitigation boundary.
5. **Growth-instruction envelope.** Should this package standardize a
   result convention for tree-growth commands, or stay values-only
   forever? Deferred until the first real consumer loop exists.
6. **Write path.** Direct container mutation (current design, supports
   list elements) vs. routing through `Tree.set` (re-enforces subclass
   key gates, but no list-index syntax). Possibly: direct mutation +
   an optional post-write validation hook.
7. **Selector expressiveness.** Equality-only selectors cover the
   planned dimensions (vendor, catalog, item type, …) but not ranges
   (dates!). Likely v2: an optional `when` field holding a CEL
   predicate as an alternative/addition to the equality map. Interim
   workaround: put the date into the tree and branch inside the rule
   *expression*.
8. **Result typing.** Optional `resultType` field per rule for
   validation (`number`, `string`, `bool`, `json`)? v1: untyped.
9. **Provenance / debugging.** Optionally record which rule/variant
   produced each resolved value (sidecar keys or a resolution report
   object) for tooling. v1: rich errors only.
10. **Namespacing.** Rule keys are flat camelCase. If rule books grow
    large, dotted namespaces (`§geometry.panelWidth`) may be worth the
    added key-pattern complexity.
11. **Optional rules.** An `optional: true` variant-list flag making
    "no variant matched" resolve to `null`/removal instead of an
    error. v1: always error; require a base variant instead.
12. **Performance.** Selector evaluation is O(refs × variants ×
    conditions) with repeated tree reads. Fine for expected sizes;
    if profiling ever disagrees: per-node read memoization within a
    resolve run, and rule-book indexing by first condition.

---

## 12. Decision log

| # | Decision | Source |
|---|---|---|
| D1 | Inputs are bound via an explicit `inputs` map; expressions use bare CEL identifiers. No query substitution into expression sources. | Team decision, 2026-07-02 |
| D2 | Variant precedence: CSS-like specificity (condition count), ties broken by merge order (later book wins). | Team decision, 2026-07-02 |
| D3 | CEL as the expression engine (`cel` on pub.dev; `@bufbuild/cel` for JS-side authoring parity). No JavaScript engine. | Project planning |
| D4 | Package is generic over `Tree<T extends Json>`; zero domain dependencies; domain semantics live in consumers. | Repo charter (open source) |
| D5 | References are `§name` string values; rule books key rules as `§name`; a rule is a uniform list of variants (base = selector-less). | This document |
| D6 | Resolution: one `resolve()` call, worklist with deferral, into a deep copy by default (`inPlace` opt-in), idempotent and re-runnable. | This document (refines "single root-down pass") |
| D7 | Expressions compile once per source string; inputs bind per evaluation via the CEL activation map. | This document (lesson from downstream `showIf`) |
| D8 | Open questions 1–12 answered; see §13.1. | Team decision, 2026-07-06 |
| D9 | Inline expressions in tree data via `§`-marked variant maps. | Team decision, 2026-07-06 |
| D10 | `§§` escaping, unescaped at resolve time. | Team decision, 2026-07-06 |
| D11 | Growth stays consumer-side (values-only results). | Team decision, 2026-07-06 |

---

## 13. Implementation decisions (2026-07-06)

### 13.1 Answers to the open questions of §11

1. **Literal `§` strings** → escaping. Any string starting with `§§`
   is an escaped literal; resolution replaces it with the same string
   minus one leading `§` (exactly once, at resolve time — D10).
   Caveat (documented): re-resolving an already-resolved tree can
   misread an unescaped literal that collides with a rule key.
2. **Rule aliasing** → allowed. A rule result that is itself a
   reference string is re-enqueued. Each work item records its chain
   of applied rule keys; a key repeating in the chain is a cycle
   error naming the full chain.
3. **Numeric coercion** → strict, rely on authoring discipline;
   pair with `resultType` (see 8).
4. **Custom CEL functions** → none in v1; work with what `cel` has.
5. **Growth** → rule results may *describe* growth (plain JSON
   values); the package never grows trees itself. Consumers loop
   resolve → interpret → grow → resolve (D11).
6. **Write path** → direct container mutation (now *mandatory*, see
   §13.3).
7. **Date/range selectors** → out of scope for v1.
8. **Result typing** → optional `resultType` per rule
   (`number | string | bool | list | map`), validated after
   evaluation.
9. **Provenance/verbose mode** → not in v1; error paths carry full
   context so a report object can be added later.
10. **Namespacing** → flat keys only in v1.
11. **Optional rules** → implemented: object-form rule with
    `optional: true` resolves "no variant matched" by removing the
    map entry (list elements become `null`) instead of erroring.
12. **Performance** → no premature optimization; compile cache +
    single collect pass; revisit on profiling evidence.

### 13.2 Additional decisions

- **Inline expressions (D9).** A data value that is a map containing
  the key `§expression` is an inline variant:
  `{"§expression": "w < 400.0 ? 3.0 : 2.0", "§inputs": {"w": "screen#width"}}`.
  Evaluated in node context like a nameless single-variant rule; the
  whole map is replaced by the result. Unknown `§`-keys inside such a
  map are an error (typo protection). No selector inline — context is
  already fixed. The scanner treats these maps as atomic (their
  contents are not scanned for references).
- **Rule shape.** A rule book value is either a plain variant list
  (shorthand) or an object `{"optional": …, "resultType": …,
  "variants": [...]}`. Merge concatenates variant lists;
  conflicting `optional`/`resultType` across merged books is an
  error.
- **Diagnostics.** Unknown rule keys report did-you-mean suggestions
  (edit distance) plus the available keys. `RuleBook.lint()` flags
  suspicious-but-legal setups: identical variant lists under two
  names, duplicate selectors within one rule, missing base variant
  for non-optional rules.
- **Markers.** Three value shapes make a location "unresolved":
  reference strings (`§name`), escaped literals (`§§…`), and inline
  expression maps. All three are work items *and* block any
  selector/input query whose resolution touches them (defer).

### 13.3 Corrections from dependency verification

- **Writes must mutate containers directly.** gg_json's `set` has a
  runtime-type guard: overwriting a `String` (the reference) with a
  bool/num/map throws. `Tree.set` is therefore unusable for result
  writes; the resolver writes `parent[key] = result` inside
  `Json.visit`, which is explicitly mutation-safe. Direct data
  mutation breaks no gg_tree/ds_slot invariant (no listeners, no hash
  caches; ds_slot's own typed setters mutate directly).
- **`cel` 0.5.4+1 swallows syntax errors.** Bad sources compile to a
  `StringLiteralExpr('<<error>>')` subtree and misbehave only at
  eval. `CompiledExpression` must scan the compiled AST for
  `'<<error>>'` literals and fail fast at compile with the rule
  context. `-x` (unary minus on non-literals) hits the same bug.
- **`cel`'s parser prints to stderr on every parse** (ANTLR
  `DiagnosticErrorListener` + console error listener) — this
  deadlocks test runners that never drain stderr, notably
  `gg one can commit`. `CompiledExpression` therefore parses
  listener-free itself (replicating the engine's 5-line
  `Parser.parse` via `package:cel/gen/` + `antlr4`), which also
  yields real syntax errors with line and column.
- **`cel` is *not* int/double-strict** (unlike cel-go): comparisons
  mix freely, but `int + double` truncates to int when the int is on
  the left. `size()`, macros (`has/all/exists/map/filter`), type
  conversions, `bytes`, and timestamps are unsupported; ternary
  branches cannot return lists or null; list/map `==` is identity.
  The README must document this subset.
- **List bindings**: binding any list other than `List<String>`
  (including lists nested in bound maps) throws in the engine. The
  wrapper pre-wraps lists as `List<Value>` (src import — accepted;
  `CompiledExpression` is the declared mitigation boundary).
- **Unknown-identifier errors embed the whole activation map** — the
  wrapper replaces engine messages instead of appending them.
- **Blocked-query detection needs prefix checks.** `getOrNull` can
  (a) throw when a data path traverses a reference string, and
  (b) silently continue the upward search past an inline map that
  lacks the queried sub-key. Both would corrupt resolution order, so
  query evaluation checks every data-path prefix along the search
  chain for markers before trusting a `null`/thrown result.
- **`null` results are second-class in gg_tree**: a resolved `null`
  is indistinguishable from "missing" for queries (upward search
  continues past it). Documented; `optional` rules exploit this
  deliberately.
- **Coverage regime**: `gg one can commit` requires per-file 1:1
  coverage — `lib/src/x.dart` counts only hits produced while
  `test/x_test.dart` runs. File layout keeps that feasible.

### 13.4 Post-review refinements (2026-07-06)

An adversarial review pass confirmed seven defects; their fixes
sharpened the semantics:

- **Blocking is pendency-based, not shape-based, inside a resolve
  run.** `readQuery`/`Selector.match`/`Rule.select` accept an
  optional `isPending(location)` predicate; the resolver passes one
  backed by its worklist. Consequence: literals produced by `§§`
  unescaping no longer deadlock selectors/inputs that read them.
  Standalone calls (no predicate) keep the conservative shape-based
  behavior.
- **Copy mode requires the tree root.** `deepCopy` detaches
  ancestors, which silently changed upward-searching queries;
  `resolve()` now fails fast for non-root subtrees and points to
  `inPlace: true`.
- **Aliasing only applies to known rules.** A reference-shaped rule
  result that names no rule is plain data (e.g. a copied literal);
  tree-authored references still error on unknown rules.
- **The engine runs with a JSON-safe type adapter** (injected via an
  `Environment` subclass). This fixed crashes on index access into
  bound maps with list/null members and made ternary list/null
  branches work; bytes literals now behave as integer lists.
- **Unknown functions are compile errors** (`max(1, 2)` etc. no
  longer fail at evaluation with a raw cast error).
- **Attribute errors distinguish failed member access from unknown
  variables**, and leading-dot identifiers no longer dump the
  activation map.
- Work items carry their data path separately from the rendered
  location (map keys may contain `#`).

### 13.5 Format revision: references are maps (2026-07-07)

Before any consumer adopted the format, the reference encoding was
revised (supersedes the `§name`-string form of D5 and the `§§`
escaping of D10):

- **A reference is `{"§": "§ruleName"}`** — a map with the single
  reserved key `§` holding the rule key verbatim. Rule book keys are
  unchanged.
- **Strings are always data.** `"§name"`, `"§ 5 Abs. 2"`, and any
  rule result string are never treated as references. This removes
  the entire escaping problem class: no `§§` unescaping, no
  collision between produced literals and references, structurally
  sound idempotency and grow-loops. The in-band surface shrinks to
  "map keys starting with `§` are reserved" — and a marker map that
  matches no known form (e.g. the typo `"§expresion"`) fails loudly
  instead of passing through silently.
- **Blocking is shape-based again** and therefore correct without
  the pendency predicate of §13.4; the `isPending` parameter was
  removed from `readQuery`/`Selector.match`/`Rule.select`, and the
  resolver dropped its pending-location bookkeeping. Aliasing needs
  no known-rule special case anymore: a reference map in a result is
  always deliberate, and unknown rules fail loudly.
- **Sealed exception hierarchy**: all failures are subtypes of
  `TreeExpressionsException` with typed fields (`SchemaException`,
  `ExpressionException`, `QueryException`, `UnknownRuleException`,
  `CircularAliasException`, `NoVariantException`,
  `MissingInputException`, `StuckException`, `ResolveException`).
- **Property-based test layer**: `tree_reader_conformance_test.dart`
  pins `readQuery` against the real `Tree.getOrNull` over a random
  corpus (guarding the §13.3 mirror against gg_tree drift);
  `resolver_property_test.dart` checks marker-freeness, copy-mode
  purity, idempotency, and order-independence over random books and
  trees. Its first run immediately caught an off-by-one-index
  blocker-location bug — the harness pays for itself.
