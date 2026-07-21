# gg_tree_expressions — Rule Authoring Reference

A complete, precise description of what a **rule** is, every field it may
contain, every value each field accepts, and where each piece may be
placed. Written to be usable as the ground-truth basis for generating
rules from natural-language prompts.

This document reflects the **implementation** (post format-revisions
§13.5 and §13.6), not older blog posts or pre-§13.5 docs. In particular:
**references are maps `{"§": "ruleName"}`, never `"§name"` strings, and
rule keys are plain identifiers with no `§` prefix.**

> The `§` character is U+00A7 (SECTION SIGN, UTF-8 bytes `0xC2 0xA7`).
> Every rule key and every reference/inline marker uses it. If it shows
> up as `ยง` in an editor, the file was misdecoded — reload as UTF-8, do
> not convert.

---

## 0. Mental model (read this first)

There are exactly **two** things an author writes:

1. A **rule book** — a JSON document that *defines* named rules. Each
   rule computes a value, optionally different per context.
2. **Markers** placed inside a `gg_tree` node's data — either a
   **reference** to a rule, or an **inline expression**. A marker is a
   placeholder saying "compute this value here".

At runtime, `Resolver.resolve(tree)` walks the tree, finds every marker,
computes its value **in the context of the node that holds the marker**,
and writes the result back in place. A resolved tree contains no markers.

One sentence: *values in a tree can say "ask rule X", and one
`resolve()` answers every such question in place.*

Key consequences that shape everything below:

- A rule's expression is **CEL** and can read tree values **only**
  through explicitly declared `inputs`. There is no implicit "self" or
  free tree access inside an expression.
- Which node a query reads from is decided by **gg_tree query
  semantics** (inheritance / own-node / child / info), evaluated from
  the node holding the marker.
- Selecting *which variant* of a rule applies is decided by
  **selectors** (equality conditions) with **CSS-like specificity**.

> **Generating a rule from a requirement?** §2–§13 are the format
> reference (what is legal). **Part II (§16) is the translation
> methodology** — how a natural-language requirement decomposes into a
> rule *and* its marker placement so it resolves to the intended
> effect. Read Part II if the task is "prompt → working rule".

---

## 1. Anatomy at a glance

A rule book with one rule, `borderWidth`, having three variants:

```jsonc
{
  "borderWidth": [                                  // rule key → variant list
    { "expression": "1.0" },                         // base variant (no selector)

    {                                                // override for one context
      "selector": { "theme#id": "dark" },
      "expression": "2.0"
    },

    {                                                // override reading the tree
      "selector": { "theme#id": "dark", "#platform": "mobile" },
      "inputs":   { "screenWidth": "screen#width" },
      "expression": "screenWidth < 400.0 ? 3.0 : 2.0",
      "description": "Thicker borders on small dark-mode screens."
    }
  ]
}
```

The tree that triggers it (a reference marker in `dialog`'s data):

```jsonc
app        data: { "platform": "mobile" }
├─ theme   data: { "id": "dark" }
├─ screen  data: { "width": 380.0 }
└─ dialog  data: { "borderWidth": { "§": "borderWidth" } }   // ← reference
```

After `resolve()`, `dialog.data["borderWidth"] == 3.0` (variant 2 wins:
most conditions match). Every node **below** `dialog` reads the resolved
`3.0` by ordinary inheritance (`getOrNull('#borderWidth')`); it never
sees the rule.

---

## 2. The rule book

### 2.1 Shape

A rule book is a JSON **object**. Every top-level entry is
`ruleKey → ruleDefinition`.

```jsonc
{
  "ruleA": <ruleDefinition>,
  "ruleB": <ruleDefinition>,
  ...
}
```

- An **empty** book `{}` is valid (inline expressions still resolve).
- `RuleBook.fromJson(json)` validates the whole book and reports **all**
  invalid rules together.

### 2.2 Rule key

Every top-level key **must** match:

```
^[a-zA-Z][a-zA-Z0-9_]*$
```

- A letter, then letters / digits / underscores. No leading `§` — that
  prefix is reserved for the marker keys (§9), not rule names.
- camelCase is the convention: `panelWidth`, `border_width2`.
- Keys are **flat** — no dotted namespaces (`geometry.width` is
  invalid).
- The **same** key string is used verbatim in a reference:
  `{"§": "panelWidth"}`.

Invalid keys (`"1x"`, `"a.b"`, or a leading `§`) →
`SchemaException` at load.

### 2.3 Rule definition — two forms

A rule definition is **either**:

**(a) Shorthand** — a plain non-empty array of variants (most common):

```jsonc
"borderWidth": [ { "expression": "1.0" }, ... ]
```

**(b) Object form** — when the rule needs `optional` and/or
`resultType`:

```jsonc
"hint": {
  "optional":   true,          // optional; default false
  "resultType": "number",      // optional; no default (unvalidated)
  "variants":   [ ... ]        // required, non-empty
}
```

Object-form allowed keys are **exactly** `optional`, `resultType`,
`variants`. Any other key → `SchemaException`. `variants` must be a
non-empty list. The two forms are interchangeable except that shorthand
cannot carry `optional`/`resultType`.

| Field | Type | Required | Meaning |
|---|---|---|---|
| `variants` | array (non-empty) | yes | The variant list (see §3). |
| `optional` | bool | no (default `false`) | When no variant matches: `true` removes the marker instead of erroring (§8, §10). |
| `resultType` | `"number"` \| `"string"` \| `"bool"` \| `"list"` \| `"map"` | no (default unvalidated) | Validates every resolved result of this rule (§7.3). |

---

## 3. Variants

A variant is one concrete definition of a rule: an optional selector,
optional inputs, and exactly one expression.

```jsonc
{
  "selector":    { <treeQuery>: <literal>, ... },   // optional
  "when":        "<CEL bool predicate>",             // optional (§4.6)
  "inputs":      { <identifier>: <query|longForm>, ... },  // optional
  "expression":  "<CEL expression>",                // REQUIRED
  "description": "free text"                         // optional, docs only
}
```

Allowed keys are **exactly** `selector`, `when`, `inputs`,
`expression`, `description`. Any other key → `SchemaException`.

| Field | Type | Required | Notes |
|---|---|---|---|
| `expression` | string (CEL) | **yes** | Must be non-empty after trimming. Computes the result. |
| `selector` | object | no | Equality conditions for this variant to apply. Absent/empty ⇒ **base variant** (specificity 0, matches everywhere). |
| `when` | string (CEL) | no | A bool predicate that must **also** hold for the variant to apply (§4.6). For ranges/comparisons/OR that equality cannot express. |
| `inputs` | object | no | Binds CEL identifiers to tree queries, shared by `when` and `expression`. Absent ⇒ no inputs. |
| `description` | string | no | Documentation only; ignored at runtime. |

A variant with **no** selector and **no** inputs — `{"expression":
"42"}` — is a valid constant base variant.

---

## 4. Selectors — choosing *which* variant applies

A selector is a JSON object of `treeQuery → literal` conditions. All
conditions must hold (logical **AND**). OR is expressed by adding
another variant.

```jsonc
"selector": {
  "theme#id":   "dark",       // condition 1
  "#platform":  "mobile",     // condition 2   → AND
  "screen#dpi": 320           // condition 3
}
```

### 4.1 Condition keys — queries

Each **key** is a tree query (§6), evaluated from the node holding the
reference. The condition holds when `node.read(query) == literal`.

### 4.2 Condition values — literals

Each **value** is a JSON scalar: **string**, **number**, or **bool**.

- `null` is **not allowed** (gg_tree treats null as "missing", so a
  `null` literal could never match) → `SchemaException`.
- Objects and arrays are **not allowed** as selector literals.
- Equality is exact. Numbers compare by value; strings by content;
  bools by value.

### 4.3 Match / fail / block

For each condition, reading the query yields one of:

| Outcome | When | Effect on the variant |
|---|---|---|
| **value == literal** | query resolves to the exact literal | condition holds |
| **value != literal** | query resolves to a different value | condition fails ⇒ variant does not match |
| **missing** | query resolves to nothing (incl. a shape mismatch) | condition fails ⇒ variant does not match (**not** an error) |
| **blocked** | query touches a still-unresolved marker | variant selection is **deferred** and retried later |

A selector reading a value that does not exist yet is normal — the
variant simply does not match. This differs from inputs, where a missing
value without a default **is** an error (§5.4).

### 4.4 Specificity

`specificity = number of conditions`. The base variant (empty selector)
has specificity 0. More conditions ⇒ more specific ⇒ higher priority
(§10). If two matching variants share the highest **effective**
specificity, that is an **error**, not a guess (§10) — make one more
specific. (A `when` refines this: two variants with the same condition
count do *not* tie if one has a `when` — it ranks higher; see §4.6.)

### 4.5 Selector patterns

```jsonc
// Match a value inherited from an ancestor's data:
"selector": { "#articleType": "cabinet" }

// Match a value on THIS node only:
"selector": { "./#kind": "door" }

// Match a property of a specific named node found by upward search:
"selector": { "manufacturer#id": "acme" }

// Match a nested data value:
"selector": { "config#layout/columns": 3 }

// Multiple conditions (AND):
"selector": { "manufacturer#id": "acme", "#series": "premium" }
```

### 4.6 The `when` predicate — logic beyond equality

Selectors only test `treeQuery == literal`. For ranges, comparisons,
negation, or OR, add an optional **`when`** — a CEL predicate that must
evaluate to **bool**. A variant applies when its selector matches
**and** its `when` (if present) is `true`.

```jsonc
{
  "selector": { "manufacturer#id": "acme" },       // categorical (equality)
  "when":     "height < 2000.0 || width > 1000.0",  // the rest, in CEL
  "inputs":   { "height": "#height", "width": "#width" },
  "expression": "'compact'"
}
```

- **`when` reads the tree through the same `inputs` as `expression`.**
  Declare every identifier the predicate uses there (§5). A blocked
  input defers the variant; a missing one without a default is an
  error; a non-bool result is an error.
- **Specificity (§10):** effective specificity is
  `2 × selectorConditions + (has when ? 1 : 0)`. More selector
  conditions always win; a `when` only breaks ties among variants with
  the *same* condition count — so a `when`-variant outranks the
  otherwise-identical one, including the base.
- **OR / ranges for free:** `when: "a || b"`, `"h >= 3.0 && h < 9.0"`,
  `"!premium"`. No separate OR selector syntax exists — use `||`.
- **Mutual exclusion matters.** Because a same-specificity tie is an
  error (§10), two `when`-variants at the same tier must be mutually
  exclusive (only one true per node). For "either condition ⇒ the
  **same** result", write one variant with `when: "a || b"`; for
  different results, keep the predicates non-overlapping (e.g. the
  second excludes the first's range).

Prefer plain equality selectors when they suffice — they are simpler
and statically analyzable; reach for `when` only for the logic
equality can't express.

---

## 5. Inputs — feeding tree values into the expression

An expression can **only** reference identifiers declared in `inputs`
(plus literals). `inputs` binds each CEL identifier to a tree query,
evaluated from the node holding the reference.

```jsonc
"inputs": {
  "screenWidth": "screen#width",                     // short form
  "margin":      { "query": "#margin", "default": 4.0 }  // long form
}
```

Then `"expression": "screenWidth < 400.0 ? screenWidth : margin"`.

### 5.1 Input identifiers (the map keys)

Each key is the CEL variable name used in the expression. It **must**:

- match `^[a-zA-Z_][a-zA-Z0-9_]*$`, and
- **not** be a CEL reserved word:

  `true false null in as break const continue else for function if
  import let loop package namespace return var void while`

Violations → `SchemaException`.

### 5.2 Input values — short form

A **string** is the query (§6), validated for syntax at load:

```jsonc
"inputs": { "w": "screen#width" }
```

### 5.3 Input values — long form

An **object** with keys **exactly** `query` (required string) and
`default` (optional, any JSON value — scalar, list, or map):

```jsonc
"inputs": {
  "w":     { "query": "screen#width", "default": 320.0 },
  "gaps":  { "query": "#gaps",        "default": [4, 4, 4] },
  "flags": { "query": "#flags",       "default": { "a": true } }
}
```

Any key other than `query`/`default` → `SchemaException`.

### 5.4 Missing inputs

- **With** a `default`: when the query resolves to nothing, the default
  (deep-copied) is bound.
- **Without** a `default`: when the query resolves to nothing, resolution
  fails with `MissingInputException` (names the input, query, rule,
  node).
- **Blocked**: when the query touches an unresolved marker, the item is
  deferred and retried (never a hard error by itself).

---

## 6. The query language (used by selectors *and* inputs)

Both selector condition keys and input queries use **gg_tree query
syntax**. A query has exactly **one** `#`:

```
<nodePath>#<dataPath>
```

- Left of `#` = **which node** to read from.
- Right of `#` = **which value inside that node's data**.
- Exactly one `#` is required. Zero or ≥2 `#` → invalid query
  (`SchemaException` at load / `QueryException` at runtime).

### 6.1 Node path — which node

The node path is resolved **from the node holding the marker**. Whether
the search climbs to the root depends on the first segment:

| Node path | `searchToRoot` | Meaning |
|---|---|---|
| *(empty)* — e.g. `#width` | yes | **Inheritance search**: read `width` on this node; if absent, climb ancestors until found. |
| `./` — e.g. `./#width` | no | **This node only**. No inheritance. |
| `../` — e.g. `../#width` | no | The **parent** node only. |
| `foo` — e.g. `foo#id` | yes | Find child `foo` relative to this node, then each ancestor, climbing until a `foo` exists with the value (nearest wins). |
| `a/b` — e.g. `a/b#x` | yes | Descend `a` then `b`, searching upward the same way. |
| `../sibling` — e.g. `../sibling#x` | no | Relative to parent (no upward search). |

Rules of thumb:

- **Empty node path** (`#key`) = "the nearest value of `key` at or above
  me" — ordinary inheritance. This is the most common selector/input
  form.
- **`./`** anchors to the current node (no inheritance).
- A **plain name** or **path** climbs ancestors looking for that
  child/descendant. Leading `/` is ignored (paths are effectively
  relative to the walked node); there is no absolute-from-root form in
  `getOrNull`.
- Node segments: `.` = current, `..` = parent, a name = child by key.

A node path that matches no node ⇒ the query resolves to **missing**
(condition fails / input uses default or errors). It is not a crash.

### 6.2 Data path — which value inside the node's data

The data path navigates the node's JSON data map. Segments are separated
by **`/` or `.`** (both work; `/` is the convention in this codebase),
and **`[i]`** indexes into lists.

| Data path | Reads |
|---|---|
| `#width` | `data["width"]` |
| `#layout/columns` | `data["layout"]["columns"]` |
| `#layout.columns` | same as above (`.` == `/` here) |
| `#sizes[0]` | `data["sizes"][0]` |
| `#grid[0][1]` | `data["grid"][0][1]` |
| `#rows[0]/cells[1]` | `data["rows"][0]["cells"][1]` |

If the data path traverses an incompatible shape (e.g. indexes a
non-list, or descends into a scalar), the read is treated as
**missing** in selector context, and raises a `QueryException` in input
context.

### 6.3 Node-info namespace `#node/...`

A data path starting with `node/` reads **computed node properties**
(structure, not data) — e.g. `#node/index`. These values live outside
node data, can never hold markers, and are read-only. Rarely needed for
authoring; listed here for completeness.

### 6.4 Where queries read is always the marker's node

Both selectors and inputs evaluate **relative to the node that holds the
reference/inline marker** — never relative to where the rule is defined
(rules are context-free JSON). Re-declaring the same reference deeper in
the tree re-evaluates it in that deeper node's context.

---

## 7. Expressions (CEL) and result values

`expression` is a **CEL** string, compiled once and evaluated with the
bound inputs. It returns a JSON-compatible value (num, string, bool,
list, map, or null) that is written into the tree.

### 7.1 What an expression may reference

- **Declared input identifiers** — nothing else from the tree.
- **Literals**: numbers (`1`, `2.5`, `-4`), strings (`'a'` or `"a"`),
  `true`, `false`, `null`, lists (`[1, 2]`), maps (`{'a': 1}`).

Referencing an identifier that is not a declared input → evaluation
error (`ExpressionException`, "Unknown variable …", listing available
inputs).

### 7.2 Supported CEL subset

Pinned by `test/fixtures/cel_conformance.json`. Supported:

| Category | Examples |
|---|---|
| Arithmetic | `+ - * / %` — `1 + 2`, `7 % 3`, `2.5 * 2.0` |
| Comparison | `< <= > >= == !=` — `x < 400.0`, `uid == 'abc'` |
| Logical | `&& \|\| !` — `a && !b`, `a \|\| b` |
| Ternary | `c ? a : b` — including list/null branches: `c ? [1] : [2]`, `false ? 1 : null` |
| Membership | `x in list`, `key in map` — `'x' in items`, `'k' in m` |
| String funcs | `.contains(s)`, `.startsWith(s)`, `.endsWith(s)`, `.matches(regex)` |
| String concat | `'a' + 'b'` |
| List build/concat | `[1, 2, w]`, `[1] + [2, 3]` |
| Map build | `{'a': 1, 'b': w}` |
| Indexing | `xs[1]`, `m['b']`, `m.b`, `grid[0][1]`, `rows[0]['cells'][1]` |
| Literals | `-4`, `'s'`, `"s"`, `true`, `null` |

### 7.2.1 NOT supported (compile-time errors)

- `size()` (no length function).
- Macros: `has`, `all`, `exists`, `exists_one`, `map`, `filter`.
- Type conversions: `int()`, `double()`, `string()`, `bool()`,
  `bytes()`, `timestamp()`, `duration()`, `dyn()`.
- `min` / `max` / `round` and any other custom function — **use the
  ternary** (`a < b ? a : b`) or pre-compute via an input.
- **Unary minus on non-literals**: `-x` fails; write `0 - x` or
  `-1 * x`. (`-4` on a literal is fine.)
- **Field access after an index**: `m[0].key` fails — write
  `m[0]["key"]`.
- Protobuf message construction `x{a: 1}`.

Unknown functions, macros, and the above are rejected at **compile**
(resolver construction / first inline use), not silently at evaluation.

### 7.2.2 Evaluation gotchas (they succeed but surprise)

- **Int-on-the-left arithmetic truncates**: `1 + 1.5 == 2`, but
  `1.5 + 1 == 2.5`. Put the double first, or make both sides doubles.
- **Int division truncates**: `10 / 4 == 2`; write `10.0 / 4.0` for
  `2.5`.
- **Comparisons mix int/double freely**: `x < 400` works with a double
  `x`, and `x < 400.0` works with an int `x`. (Only *arithmetic* has the
  truncation quirk, not comparison.)
- **List/map equality is identity, not structural**: `[1,2] == [1,2]` is
  **false**. Do not compare lists/maps with `==`.
- **Regex** uses Dart `RegExp`; an invalid pattern (`s.matches('[')`) is
  an evaluation error.
- **Division by zero**, comparing incompatible types (`1 < 'abc'`), and
  `!1` (logical-not on non-bool) are evaluation errors.

### 7.3 Result values and `resultType`

Whatever the expression returns is written verbatim into the tree
(numbers, strings, bools, lists, maps, null).

If the rule declares `resultType`, the result is validated after
evaluation:

| `resultType` | Accepts |
|---|---|
| `"number"` | int or double |
| `"string"` | string |
| `"bool"` | bool |
| `"list"` | list |
| `"map"` | map |

A mismatch → `ResolveException`. `resultType` is a rule-level field
(object form only), so it validates **all** variants of the rule.

### 7.4 Results may be structured (growth instructions)

A result can be any JSON, e.g. `{"add": "innerDrawer", "count": 2}`. The
package itself only writes values; a **consumer** may interpret such a
value, grow the tree, and `resolve()` again (see §9). A result that
itself contains a reference map triggers **aliasing** (§9.3).

---

## 8. Optional rules

By default, if **no** variant matches at a node, resolution fails
(`NoVariantException`). Marking a rule `optional: true` (object form)
changes that outcome to **removal**:

```jsonc
"hint": {
  "optional": true,
  "variants": [ { "selector": { "#showHints": true }, "expression": "'tip'" } ]
}
```

- Inside a **map**: the marker's key is removed entirely.
- Inside a **list**: the element is set to `null`.

Use `optional` when "produce nothing here" is a legitimate outcome.
Otherwise always provide a base variant (a selector-less variant) so
every node resolves.

---

## 9. Markers in the tree (references & inline expressions)

Markers are what you place in **node data** to trigger resolution. There
are two kinds; both are JSON **maps** whose presence defers the node.

### 9.1 Reference

```json
{ "§": "ruleName" }
```

- A map with the **single** reserved key `§`, whose value is a rule key
  **string** matching `^[a-zA-Z][a-zA-Z0-9_]*$`.
- Naming a rule the book does not contain → `UnknownRuleException` (with
  did-you-mean suggestions).
- Wrong shape (extra keys, non-string value, non-rule-key value) →
  `SchemaException`.

### 9.2 Inline expression

An expression written directly at the site, with no named rule:

```json
{ "§expression": "w < 400.0 ? 3.0 : 2.0", "§inputs": { "w": "screen#width" } }
```

- Reserved keys: `§expression` (required string) and `§inputs`
  (optional, same shape as a variant's `inputs`, §5).
- **No selector** — the context is already fixed to this node.
- Any other `§`-key inside the map → `SchemaException`.
- The whole map is replaced by the result.

Use inline for one-off, context-specific values; use a named rule when
the same logic is reused or needs per-context variants.

### 9.3 Where markers may be placed

A marker may sit **at any depth** inside a node's data:

```jsonc
"data": {
  "borderWidth": { "§": "borderWidth" },          // top-level value

  "config": {                                        // nested in a map
    "gap": { "§": "gap" }
  },

  "sizes": [                                         // inside a list
    600,
    { "§": "dynamicSize" },
    { "§expression": "base * 2", "§inputs": { "base": "#base" } }
  ]
}
```

- The resolver deep-scans maps and list elements.
- A marker map is **atomic**: its own contents are not scanned for
  further markers (so `§inputs` values are read as data, not as nested
  markers).
- The result replaces the marker at that exact location (map key or list
  index).

### 9.4 Strings are always data — reserved keys

- **No string is ever a reference.** `"§name"`, `"§ 5 Abs. 2"`, and any
  rule result string are plain data. There is no string escaping and no
  collision problem.
- **Map keys starting with `§` are reserved.** A data map that contains
  a `§`-key must be a valid reference or inline expression; anything else
  (e.g. a typo `{"§expresion": …}` or `{"§": …, "extra": …}`) fails
  resolution loudly with a `SchemaException`. Do not use `§`-prefixed
  keys for ordinary data.

---

## 10. Selection & precedence (which variant wins)

When a reference resolves, the rule picks one variant at the node:

1. **Evaluate every variant's selector** at the node; for a matching
   selector, also evaluate its `when` predicate (§4.6). A variant
   **applies** when both hold.
2. Among the variants that **apply**, choose the one with the highest
   **effective specificity** — `2 × selectorConditions + (has when ?
   1 : 0)`. More conditions win outright; a `when` breaks ties among
   equal condition counts (so a `when`-variant beats the otherwise-
   identical one, including the base).
3. **Ties** (two or more apply at equal, highest effective specificity)
   → an **error** (`AmbiguousVariantException`). The resolver never
   picks by order; make a selector or `when` more specific so exactly
   one variant applies. This holds within one book and across merged
   books alike (§11).
4. If a still-blocked variant *could* win or tie once resolved, the
   item is **deferred** and retried after more resolution.
5. If **no** variant matches:
   - rule is `optional` → remove the marker (§8);
   - else → `NoVariantException` (lists why each variant failed).

Guidance: give every non-optional rule a **base variant** so step 5
never triggers unexpectedly.

---

## 11. Merging rule books

`RuleBook.merge([bookA, bookB, …])` takes books in **ascending
priority** and concatenates variant lists per rule key.

- Typical order: `global → vendor → catalog → item` (most specific
  last).
- A later book overrides an earlier one only with a **more specific**
  variant; a same-specificity tie is an **error**, not resolved by
  order (§10.3).
- Conflicting rule-level `optional` or `resultType` across books for the
  same key → `SchemaException`. (`null`/absent defers to the other
  book's value.)

---

## 12. Resolution semantics (behavior authors rely on)

- `resolve(tree)` works on a **deep copy** and returns it; the original
  keeps its markers. Copy mode **requires the tree root** (a detached
  subtree copy would lose inherited context — the resolver fails fast
  and points to `inPlace`).
- `resolve(tree, inPlace: true)` mutates in place; also used to resolve a
  subtree within its full tree. On error, the tree may be partially
  resolved.
- `resolveAtomic(tree)` mutates in place but **all-or-nothing**:
  resolves a copy, writes back only on success. Meant for pipeline steps
  that must stay clean on failure.
- **Order-independent**: markers whose selectors/inputs read
  still-unresolved values are deferred and retried; a query never
  silently searches past an unresolved marker.
- **Aliasing**: a result containing a reference map is re-resolved.
  A rule key repeating in the chain → `CircularAliasException` (full
  chain in the message). A location that keeps regenerating markers is
  capped at 64 steps → `ResolveException`.
- **Idempotent & re-runnable**: a resolved tree has no markers, so
  `resolve()` on it is a no-op. Enables resolve → interpret → grow →
  resolve loops.
- **Stuck**: if a round makes no progress while markers remain →
  `StuckException`, listing every pending item and what it waits for
  (cycles or values that never resolve).
- **Verbose**: `resolveVerbose(tree, {rich})` returns
  `(tree, ResolutionReport)` describing which rule/variant produced each
  value. `resolve()` records nothing and pays nothing.

---

## 13. Validation constraints (generation checklist)

Every one of these is enforced; a generated rule must satisfy all of
them. Failures are typed subclasses of `TreeExpressionsException`.

**Rule book / keys**
- [ ] Rule keys match `^[a-zA-Z][a-zA-Z0-9_]*$` (camelCase, flat, no
      leading `§`).
- [ ] Object-form rule uses only `optional` / `resultType` / `variants`;
      `variants` is a non-empty array.
- [ ] `optional` is a bool; `resultType` ∈
      `number|string|bool|list|map`.

**Variants**
- [ ] Only `selector` / `when` / `inputs` / `expression` /
      `description`.
- [ ] `expression` present and non-empty.
- [ ] `description`, if present, is a string.

**Selectors**
- [ ] Keys are valid one-`#` queries.
- [ ] Values are string / number / bool (never `null`, object, array).

**`when` (§4.6)**
- [ ] If present, a non-empty CEL string that evaluates to **bool**.
- [ ] Every identifier it uses is declared in `inputs`.

**Inputs**
- [ ] Identifiers match `^[a-zA-Z_][a-zA-Z0-9_]*$` and are not CEL
      reserved words.
- [ ] Value is a query string or `{ "query": <string>, "default": <json> }`.
- [ ] Every identifier used in `expression` or `when` is declared here.

**Expressions**
- [ ] Valid CEL in the supported subset (§7.2); no `size`/macros/
      conversions/custom functions; no `-x`; no `m[0].key`. Applies to
      `when` predicates too.
- [ ] Mind the numeric quirks (use `400.0`, don't `==` lists/maps).

**Markers in the tree**
- [ ] Reference is exactly `{ "§": "ruleName" }` naming a known rule.
- [ ] Inline uses only `§expression` (+ optional `§inputs`).
- [ ] No other data map carries a `§`-prefixed key.

**Semantics**
- [ ] Non-optional rules have a base variant (or every node is
      guaranteed to match some selector).
- [ ] No node can match two variants at the same top specificity
      (same-specificity ties are an error, not order-broken).
- [ ] No circular aliases.

`RuleBook.lint()` additionally flags *legal but suspicious* setups:
identical rules under two names, duplicate selectors within one rule,
and non-optional rules without a base variant.

---

## 14. Worked examples

### 14.1 Constant

```jsonc
{ "gap": [ { "expression": "4.0" } ] }
```
Reference `{"§": "gap"}` → `4.0` everywhere.

### 14.2 Context override by inherited value

```jsonc
{
  "handleStyle": [
    { "expression": "'bar'" },                                   // base
    { "selector": { "#series": "premium" }, "expression": "'inset'" }
  ]
}
```
`premium` series → `'inset'`; otherwise `'bar'`.

### 14.3 Reading tree values with a computed result

```jsonc
{
  "columnWidth": [
    {
      "inputs": {
        "total":   "#cabinetWidth",
        "columns": { "query": "#columns", "default": 1 }
      },
      "expression": "total / columns"
    }
  ]
}
```
Note: with integer inputs this truncates (`§7.2.2`); bind/author doubles
(`#cabinetWidth` = `1200.0`) for a fractional result.

### 14.4 Specificity ladder

```jsonc
{
  "depth": [
    { "expression": "560.0" },                                   // spec 0
    { "selector": { "#type": "wall" }, "expression": "320.0" },  // spec 1
    { "selector": { "#type": "wall", "#deep": true },            // spec 2 (wins if both)
      "expression": "350.0" }
  ]
}
```

### 14.5 Optional rule (produce nothing when it doesn't apply)

```jsonc
{
  "badge": {
    "optional": true,
    "resultType": "string",
    "variants": [
      { "selector": { "#isNew": true }, "expression": "'NEW'" }
    ]
  }
}
```
On a node without `isNew == true`, the `badge` key is removed.

### 14.6 String logic with the ternary (no min/max)

```jsonc
{
  "clampedGap": [
    {
      "inputs": { "g": "#requestedGap" },
      "expression": "g < 2.0 ? 2.0 : (g > 10.0 ? 10.0 : g)"
    }
  ]
}
```

### 14.7 Structured result (consumer-interpreted growth)

```jsonc
{
  "shelves": [
    {
      "inputs": { "h": "#innerHeight" },
      "resultType": "map",
      "expression": "{ 'kind': 'shelf', 'count': h > 800.0 ? 3 : 2 }"
    }
  ]
}
```
(For a rule-level `resultType`, use the object form — shown flat here for
brevity; wrap in `{ "resultType": "map", "variants": [...] }`.)

### 14.8 Inline expression in the tree (no rule)

Tree data:
```json
{ "width": { "§expression": "col * count", "§inputs": { "col": "#colWidth", "count": "#cols" } } }
```

### 14.9 Nearest-named-node selector

```jsonc
{
  "priceTier": [
    { "expression": "'standard'" },
    { "selector": { "manufacturer#id": "acme" }, "expression": "'oem'" }
  ]
}
```
`manufacturer#id` climbs from the marker's node to the root, finds the
nearest `manufacturer` child, and reads its `id`.

### 14.10 Range gate with `when` (partitioned)

Equality can't say "taller than 2000mm", so the height test lives in a
`when`. The two `when`-variants **partition** the height axis (mutually
exclusive), so exactly one applies — no ambiguity, no base needed:

```jsonc
{
  "shelfCount": [
    {
      "when": "h > 2000.0",
      "inputs": { "h": "./#slot/size/height" },
      "expression": "4"
    },
    {
      "when": "h <= 2000.0",
      "inputs": { "h": "./#slot/size/height" },
      "expression": "2"
    }
  ]
}
```

For "small **or** wide ⇒ the same result", collapse to one variant with
OR: `{ "when": "h < 2000.0 || w > 1000.0", "inputs": { … }, "expression":
"'compact'" }`.

---

## 15. Do / don't cheat sheet

**Do**
- Give every non-optional rule a base variant.
- Use `#key` for inherited values, `./#key` for own-node values.
- Declare every expression identifier in `inputs`.
- Write doubles where fractions matter (`400.0`, `total / cols` with
  double inputs).
- Express OR with a `when: "a || b"` predicate (or by adding
  variants); express AND with multiple selector conditions.
- Use `when` for ranges/comparisons equality can't state; keep plain
  equality selectors when they suffice.
- Use the ternary for min/max/clamp.

**Don't**
- Don't write references as strings (`"name"`) — use `{"§": "name"}`.
- Don't put `null`, arrays, or objects as selector literals.
- Don't leave two `when`-variants at the same specificity both able to
  apply — partition them (mutually exclusive), or they error.
- Don't compare lists/maps with `==`.
- Don't use `size`, `min`, `max`, macros, or type conversions.
- Don't use `-x` (write `0 - x`) or `m[0].key` (write `m[0]["key"]`).
- Don't put `§`-prefixed keys on ordinary data maps.
- Don't rely on absolute-from-root node paths; paths are relative with
  upward search.

---

# Part II — Translating a requirement into a rule (end-to-end)

This part is the "how to think" layer for turning a natural-language
requirement into a **complete, working change**: a rule (added to the
rule book) **and** the reference marker(s) placed in the tree, such that
`resolve()` produces the intended effect.

The generator's output is therefore **two artifacts**, always:

1. a **rule-book delta** — the new/edited rule(s), and
2. **marker placements** — where a `{"§": "rule"}` reference (or an
   inline expression) is written in the tree.

Neither alone does anything: a rule with no marker never runs; a marker
with no rule fails to resolve.

---

## 16. Decompose the requirement into five questions

Every requirement answers these five. Getting each into the **right
mechanism** is the whole game.

| # | Question | Goes into | Notes |
|---|---|---|---|
| Q1 | **WHERE** does the effect land? | marker **placement** (which node(s), which data key) | One target ⇒ one marker; N targets ⇒ N markers sharing one rule. |
| Q2 | **WHAT** value appears there (and its type)? | the **expression result** (+ optional `resultType`) | Must also define the value when the condition is *false* (Q4). |
| Q3 | **WHEN — categorically** — does the rule apply? | **selector** (`query == literal`) | Catalog, manufacturer, type, series, feature flags — anything expressible as equality. |
| Q4 | **WHEN — by runtime data** — does the effect trigger? | **inputs + expression** | Comparisons (`>`, `<`, ranges), counts, arithmetic, string tests. **Never a selector.** |
| Q5 | **Which tree values** does the logic need? | **inputs** (queries) | Each query locates a value *relative to the marker's node*. |

### 16.1 The decisive rule: equality → selector, everything else → expression

Selectors test **equality only** (`query == literal`). So natural-
language phrases split into two buckets:

- **Selector material** (categorical / equality): "in catalog XYZ",
  "for wall cabinets", "when the door is glass", "series = premium".
- **Expression material** (everything comparative or computed): "taller
  than 2000mm", "more than 3 shelves", "between 400 and 800", "width ×
  2", "name contains 'X'". These need an **input** that reads the value
  and an **expression** that compares/computes it.

> If you catch yourself wanting `{"height > 2000": true}` in a selector —
> stop. That is not legal. Read the height via an `input` and compare in
> the `expression`.

### 16.2 The false-branch obligation

A reference **replaces** the value at its location, so a placed marker
must resolve to *something* for **every** case it can be reached:

- **Categorical gate only** (the whole condition is a selector): you may
  make the rule `optional` and omit the base variant — when the selector
  does not match, the marker is **removed** (map key deleted / list
  element nulled). Use this when "no value here" is the correct "else".
- **Runtime gate** (a comparison in the expression): the expression is
  always evaluated once a variant matches, so it must return the **else
  value explicitly** — `cond ? effectValue : defaultValue`. A numeric
  gate can *not* be expressed as optional-removal, because `optional`
  reacts to selector non-match, not to a false expression.
- **Mixed gate** (categorical selector *and* a runtime comparison): the
  selector scopes it; inside, the expression still needs an explicit
  else value; and you still need a **base variant** (or `optional`) for
  nodes the selector does not scope.

### 16.3 Units and types

- Convert units to the tree's stored representation ("2000mm" → the
  number `2000.0` if the tree stores millimetres).
- Prefer **doubles** for measurements (`2000.0`, not `2000`) so
  arithmetic does not truncate (§7.2.2). Comparisons mix int/double
  freely, so a `>` gate is safe either way; arithmetic is where the
  quirk bites.

### 16.4 Choosing marker placement (Q1) vs. positional selectors

"the first and last …" is a **placement** decision, not a selector:

- **Preferred — targeted placement**: write the marker only on the nodes
  the effect names (the first inset node and the last inset node). The
  rule stays simple; "which nodes" is answered by tree navigation.
- **Alternative — broad placement + positional selector**: put the
  marker on *every* candidate node and let the rule decide via a
  positional signal — a domain flag (`./#isEdge == true`) or the node-
  info namespace (`#node/index` for "first"). "Last" needs a count or a
  domain flag, so targeted placement is usually clearer.

Rule of thumb: if the effect names *specific* nodes, place markers
there; if it applies to *a category* of nodes, place broadly and gate
with a selector.

---

## 17. Worked translation of the example prompt

> **"If the high shelf in catalog XYZ is taller than 2000mm, the first
> and last inset positions are fixed."**

`‹angle brackets›` mark the **domain-specific** bits — the queries and
node locations that come from the consumer's tree-schema knowledge
(deferred). Everything outside the brackets is the complete, correct
rule mechanism and does not depend on the domain.

> This example is **illustrative of the shape**, not a committed design.
> The concrete result vocabulary — here a boolean `fixed` with a `false`
> default — is a domain choice still open. The decomposition (selector
> vs. expression, inputs, placement) is the same whatever that choice
> turns out to be; only the literal the expression returns changes.

### 17.1 Decomposition

| Fragment | Bucket | Mechanism |
|---|---|---|
| "in catalog XYZ" | categorical (Q3) | selector `‹catalog-id query› == "XYZ"` |
| "the high shelf … taller than 2000mm" | runtime numeric (Q4, Q5) | input `shelfHeight = ‹high-shelf height query›`, expression `shelfHeight > 2000.0` |
| "the first and last inset positions" | effect location (Q1) | a reference on each of the two nodes' `‹fixed key›` |
| "are fixed" | effect value (Q2) | result `true`; else `false` (Q4.2 false-branch) |

### 17.2 Rule-book delta (artifact 1)

```jsonc
{
  "insetPositionFixed": [
    { "expression": "false" },                       // default: not fixed

    {
      "selector": { "‹catalog-id query›": "XYZ" },   // scope: catalog XYZ
      "inputs": {
        "shelfHeight": "‹query to the high shelf's height,
                         relative to an inset-position node›"
      },
      "expression": "shelfHeight > 2000.0"           // taller than 2000mm ⇒ fixed
    }
  ]
}
```

Why this shape:
- The **selector** carries only the categorical part (catalog XYZ).
- The **height comparison lives in the expression**, fed by an input.
- The **base variant** (`false`) satisfies the false-branch obligation
  for nodes outside catalog XYZ; inside XYZ, `shelfHeight > 2000.0`
  yields `true`/`false`. So every placed marker always resolves.

### 17.3 Marker placement (artifact 2)

Write the reference at the two target nodes' `fixed` slot:

```jsonc
// ‹first inset-position node›.data
{ "‹fixed key›": { "§": "insetPositionFixed" }, ... }

// ‹last inset-position node›.data
{ "‹fixed key›": { "§": "insetPositionFixed" }, ... }
```

Both nodes share the one rule; each resolves in **its own** node
context, so the `‹high-shelf height query›` is evaluated from each inset
node.

### 17.4 Resolved effect

| Catalog | High-shelf height | `fixed` at first & last inset |
|---|---|---|
| XYZ | 2100mm | `true` |
| XYZ | 1800mm | `false` |
| ABC (any) | any | `false` (base variant) |

### 17.5 The domain seams (deferred, consumer-specific)

Exactly three `‹…›` placeholders remain, and they are precisely the
consumer-schema tasks:

1. **`‹catalog-id query›`** — where the catalog identifier lives relative
   to an inset node (likely an inherited value, e.g. `#catalogId`, or a
   named ancestor like `catalog#id`).
2. **`‹high-shelf height query›`** — how to reach the high shelf's height
   from an inset node (a named-node search or an inherited key).
3. **The two target nodes and their `‹fixed key›`** — locating "first and
   last inset positions" and the data key that means "fixed".

The rule *mechanism* (selector vs. expression split, inputs, base
variant, marker placement, shared rule) is complete and correct without
these; the consumer's tree layer only supplies the queries and node
addresses.

---

## 18. Two more patterns (contrast the gates)

**Categorical gate → `optional` removal.**
*"Only wall cabinets get a top light rail."*

```jsonc
{ "topLightRail": {
    "optional": true,
    "variants": [ { "selector": { "#type": "wall" }, "expression": "true" } ]
} }
```
Marker on each cabinet's `‹lightRail key›`. Wall ⇒ `true`; every other
type matches no variant ⇒ the key is **removed** (no rail). Optional
works here because the gate is *purely categorical*.

**Runtime gate → explicit else value.**
*"If a cabinet has more than 3 shelves, reduce shelf spacing to 32mm."*

```jsonc
{ "shelfSpacing": [
    { "inputs": { "n": "‹shelf-count query›" },
      "expression": "n > 3 ? 32.0 : 64.0" }   // else value is mandatory
] }
```
No selector (applies to all cabinets); the threshold is in the
expression; `64.0` is the required false-branch value.

---

## 19. Generator output contract (summary)

For any requirement, emit:

1. **Rule-book delta** — one rule per distinct effect value/type.
   - Categorical conditions → `selector` (equality only).
   - Comparisons / counts / arithmetic / string tests → `inputs` +
     `expression`.
   - Provide a base variant *or* `optional`, per §16.2.
   - Set `resultType` when the effect has a fixed type (defensive).
2. **Marker placements** — a `{"§": "rule"}` reference at each effect
   location's data key (targeted), or a broad placement + positional
   selector (§16.4). Use an **inline expression** instead of a named
   rule only for a genuinely one-off, single-site value.
3. Keep every constraint in the §13 checklist satisfied.

Validate the pair the way the runtime will: does each placed marker
resolve, in every reachable context, to the intended value — and to a
sensible default otherwise?

---

## Appendix A — JSON shape cheat sheet

```jsonc
// RULE BOOK
{
  "<camelCase>": [ <variant>, ... ],           // shorthand
  "<camelCase>": {                             // object form
    "optional":   <bool>,                      // optional
    "resultType": "number|string|bool|list|map", // optional
    "variants":   [ <variant>, ... ]           // required, non-empty
  }
}

// VARIANT
{
  "selector":    { "<query>": <string|number|bool>, ... },  // optional
  "when":        "<CEL bool predicate>",                    // optional
  "inputs":      { "<ident>": "<query>"                     // optional
                            | { "query": "<query>", "default": <json> }, ... },
  "expression":  "<CEL>",                                   // required
  "description": "<text>"                                   // optional
}

// MARKERS IN TREE DATA
{ "§": "ruleName" }                                        // reference
{ "§expression": "<CEL>", "§inputs": { "<ident>": "<query>|<longForm>" } }  // inline
```

## Appendix B — Query cheat sheet

```
<nodePath>#<dataPath>          exactly one '#'

nodePath (which node, from the marker's node):
  (empty)   #x        inherit: this node, then climb ancestors
  ./        ./#x      this node only
  ../       ../#x     parent only
  name      foo#x     nearest 'foo' child (climbs ancestors)
  a/b       a/b#x     descend a→b (climbs ancestors)
  . .. name segments; leading '/' ignored (no absolute form)

dataPath (which value in node data):
  x                   data["x"]
  a/b   or  a.b       data["a"]["b"]      ('/' and '.' both work)
  xs[0]               data["xs"][0]
  a[0][1] / a[0]/b    nested indexing / mixed
  node/<prop>         computed node info (read-only, e.g. node/index)
```

## Appendix C — CEL quick reference

```
literals    1  2.5  -4  'txt'  "txt"  true  false  null  [1,2]  {'a':1}
arithmetic  + - * / %          (int-on-left truncates; int/int truncates)
compare     < <= > >= == != in (mix int/double freely; NOT for lists/maps)
logical     && || !
ternary     cond ? a : b       (branches may be list/null)
strings     s.contains(x)  s.startsWith(x)  s.endsWith(x)  s.matches(re)
index       xs[0]  m['k']  m.k  grid[0][1]  rows[0]['cells'][1]
NO          size min max round has all exists map filter int() string()
            -x (non-literal)   m[0].key   x{a:1}
```
