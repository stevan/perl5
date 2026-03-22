# Slot Composition Algebra: Formal Specification

## 1. Overview

This document specifies a total algebra over slot states. A **slot** is the fundamental unit, and **composition** is the sole operation. The algebra serves two purposes: composing roles into classes/objects, and constructing lexical scopes. The key design principle is that composition is pure and total—it never fails and never discards information. All policy decisions are deferred to a separate resolution phase.

The system is content-addressed: every slot and role has a hash that serves as its identity. Identical structures (by construction, not just by value) have identical hashes and exist once in memory.

---

## 2. Foundational Types

### 2.1 Sym (Symbol)

Names in the system are **Sym** terms—content-addressed symbols. Two Sym values are equal if and only if their hashes are equal. This means name comparison is O(1) hash comparison, and names themselves are immutable and shareable.

For this specification, we treat Sym as primitive. The hash function for Sym is:
```
H(Sym(string)) = hash(string)
```

Two Syms with the same string have the same hash and are identical.

### 2.2 Value

Values are the payloads carried by Defined slots. For this specification, values are content-addressed: two values are equal if and only if their hashes are equal.

```
v1 == v2  ⟺  H(v1) == H(v2)
```

This makes value equality decidable and efficient (O(1) hash comparison). The specific hash function for values depends on their type (primitives, lambdas, continuations, etc.) but is assumed to be defined elsewhere. For the purposes of slot composition, we only need:
- Value equality is hash equality
- Values can be hashed deterministically

---

## 3. The Slot ADT

A **Slot** is the fundamental unit. Every slot has an **external name** (a Sym) that it presents to the world. There are four variants:

### 3.1 Slot Variants

**Required(name)**
- Declares that `name` must be fulfilled but provides no implementation
- This is an abstract method or an unbound variable
- External name: `name`

**Defined(name, value)**
- Provides a concrete implementation for `name`
- The value is the method body, variable binding, or other payload
- External name: `name`

**Conflicted(left, right)**
- Records that two slots with the same external name were composed
- Does not carry its own name—the name is derived from its children
- Both children are slots and must have identical external names
- External name: `external_name(left)` (by invariant, equals `external_name(right)`)

**Excluded**
- This variant was removed from the algebra (see rationale below)

### 3.2 External Name Function

The external name of a slot is recovered by:

```
external_name : Slot → Sym

external_name(Required(name))      = name
external_name(Defined(name, _))    = name
external_name(Conflicted(left, _)) = external_name(left)
```

For `Conflicted`, we examine only the left child's immediate external name. This is a single-step operation, not a recursive descent. The invariant guarantees `external_name(left) == external_name(right)`, so we could equally well look at the right child—left is chosen by convention.

**Invariant:** For any `Conflicted(left, right)`:
```
external_name(left) == external_name(right)
```

This invariant must be checked at construction time. It ensures that Conflicted nodes only form when slots with the same name collide.

### 3.3 Slot Hashing

Each slot variant hashes as follows:

**Required(name)**
```
H(Required(name)) = hash("Required", H(name))
```
Two Required slots with the same name (same Sym hash) are identical.

**Defined(name, value)**
```
H(Defined(name, value)) = hash("Defined", H(name), H(value))
```
Two Defined slots are identical iff they have the same name AND the same value (by hash equality).

**Conflicted(left, right)**
```
H(Conflicted(left, right)) = hash("Conflicted", H(left), H(right))
```
A Conflicted node is identified by its children's hashes. Importantly, `H(Conflicted(A, B)) ≠ H(Conflicted(B, A))`—the order is part of the identity. This ordering encodes composition history, which matters for resolution policies (e.g., which side shadows which in scope resolution).

**Note:** There is no name component in the Conflicted hash. The name is derivable from the children, and including it would be redundant. The children's hashes already incorporate their names.

### 3.4 Hash Properties

The hash function satisfies:
1. **Determinism:** Hashing the same structure always yields the same hash
2. **Injectivity (ideal):** Different structures should have different hashes (collision resistance)
3. **Composability:** Composite structures hash in terms of their components' hashes

Property 3 is what makes the system content-addressed: a structure's hash depends only on the hashes of its parts, not on memory addresses or construction order (except where order is semantically significant, as in Conflicted).

---

## 4. Composition

Composition is a **total, binary operation** on slots with the same external name. It is the only operation in the algebra.

### 4.1 Composition Function

```
compose : Slot × Slot → Slot

where external_name(left) == external_name(right)
```

The function is defined by the following table:

| left ↓ \ right →     | Required(n)      | Defined(n, v2)        | Conflicted(_, _)      |
|----------------------|------------------|-----------------------|-----------------------|
| **Required(n)**      | Required(n)      | Defined(n, v2)        | Conflicted(_, _)      |
| **Defined(n, v1)**   | Defined(n, v1)   | *(see §4.2)*          | Conflicted(L, R)      |
| **Conflicted(_, _)** | Conflicted(_, _) | Conflicted(L, R)      | Conflicted(L, R)      |

Where:
- `L` = left (the entire slot, not decomposed)
- `R` = right (the entire slot, not decomposed)
- "*(see §4.2)*" depends on whether the values are equal

### 4.2 Defined + Defined Case

When composing two Defined slots with the same name:

```
compose(Defined(n, v1), Defined(n, v2)) = 
  if H(v1) == H(v2)
  then Defined(n, v1)  // idempotent case
  else Conflicted(Defined(n, v1), Defined(n, v2))
```

If the values are identical (by hash), the composition is idempotent—the result is just that Defined slot. If the values differ, we have a conflict.

### 4.3 Composition Semantics

**Required is the identity element:**
```
compose(Required(n), s) = s
compose(s, Required(n)) = s
```
for any slot `s` with `external_name(s) == n`.

**Conflicted absorbs:**
Once a slot is Conflicted, further composition wraps it in a new Conflicted node:
```
compose(Conflicted(l, r), s) = Conflicted(Conflicted(l, r), s)
compose(s, Conflicted(l, r)) = Conflicted(s, Conflicted(l, r))
```

This preserves the full composition history as a binary tree.

**No information is lost:**
Composition never discards information. A Conflicted node retains both children unchanged. A Defined that shadows a Required replaces it, but that's fulfillment, not loss.

---

## 5. Algebraic Properties

### 5.1 Totality

The composition function is total: it is defined for all pairs of slots with matching external names. There is no "error" case in composition. All decisions about whether a composed structure is valid are made during resolution, not during composition.

### 5.2 Associativity

Composition is associative:
```
compose(compose(A, B), C) ≡ compose(A, compose(B, C))
```

**Caveat on ≡:** The two compositions produce structures with **different hashes** (different tree shapes in Conflicted nodes), but they are **semantically equivalent** under resolution. The flattened multiset of leaf slots is identical; only the binary tree structure differs.

For example:
```
compose(compose(Defined("x",1), Defined("x",2)), Defined("x",3))
→ Conflicted(Conflicted(Defined("x",1), Defined("x",2)), Defined("x",3))

compose(Defined("x",1), compose(Defined("x",2), Defined("x",3)))
→ Conflicted(Defined("x",1), Conflicted(Defined("x",2), Defined("x",3)))
```

These have different hashes but resolve identically (the resolution phase walks the tree and applies policy uniformly).

### 5.3 Commutativity (Qualified)

Composition is **commutative with respect to resolution semantics in symmetric contexts**, but **not commutative with respect to structural identity (hash)**.

**Symmetric context** (e.g., role into class):
```
compose(A, B) and compose(B, A) resolve identically
```
The resolution phase treats Conflicted nodes symmetrically—both children are errors, both must be handled. The order doesn't matter.

**Asymmetric context** (e.g., scope shadowing):
```
H(Conflicted(A, B)) ≠ H(Conflicted(B, A))
```
The hashes differ because composition order encodes shadowing direction. For scopes, "right shadows left" is the convention, so the order matters. The caller must be deliberate about which argument is left and which is right.

**Why this design:**
- Symmetric resolution (roles) benefits from treating composition as commutative—the order you compose roles doesn't affect conflict detection
- Asymmetric resolution (scopes) benefits from encoding order—the hash reflects which binding is most recent
- Both use the same underlying algebra; only the resolution policy differs

We gain more by encoding order in the hash (scopes work correctly, composition history is preserved) than we lose by sacrificing pure commutativity.

### 5.4 Idempotency (for identical values)

```
compose(s, s) = s
```

for any slot `s`. Composing a slot with itself (same hash) is idempotent.

More generally:
```
if H(s1) == H(s2) then compose(s1, s2) = s1
```

Content-addressed identity means "same hash" implies "same slot," so this reduces to the above.

---

## 6. Role Composition

### 6.1 Role Definition

A **Role** is a finite map from Sym (names) to Slot:
```
Role = { name1: slot1, name2: slot2, ... }
```

Two roles are identical iff their hash is identical.

### 6.2 Role Hashing

A role's hash is computed from its slots using order-independent aggregation:

```
H(Role) = hash(sort_by_name([(n, H(s)) for each (n, s) in Role]))
```

**Algorithm:**
1. For each slot in the role, form a pair `(name, H(slot))`
2. Sort these pairs lexicographically by name (Sym hash)
3. Hash the sorted sequence

This ensures that two roles with the same set of name-slot bindings have the same hash, regardless of construction order or internal map representation.

**Example:**
```
Role { x: Defined("x", 1), y: Defined("y", 2) }
```
Hash input: sorted pairs `[("x", H(Defined("x",1))), ("y", H(Defined("y",2)))]`

Two roles with these exact slots have identical hashes.

### 6.3 Role Composition

Composing two roles operates pointwise over names:

```
compose_roles(R1, R2) = 
  { n: compose(R1[n], R2[n]) 
    for each n in (keys(R1) ∪ keys(R2)) }
```

For each name in the union of both roles' keys:
- If the name exists in both roles, compose the slots
- If the name exists in only one role, include that slot unchanged (implicitly, the other role has `Required(n)`, which is the identity element)

**Note:** The identity element behavior means we can write this as a pure union-and-compose without explicitly checking membership. Conceptually:
```
R1[n] defaults to Required(n) if n ∉ R1
R2[n] defaults to Required(n) if n ∉ R2
```

### 6.4 Role Composition Properties

Role composition inherits the properties of slot composition:
- **Associative:** `compose_roles(compose_roles(R1, R2), R3) ≡ compose_roles(R1, compose_roles(R2, R3))`
- **Commutative (up to resolution):** `compose_roles(R1, R2)` and `compose_roles(R2, R1)` resolve equivalently in symmetric contexts
- **Identity:** The empty role `{}` is the identity element (all its slots are implicitly `Required`, which are identity elements)

---

## 7. Resolution (Non-Normative)

Resolution is **not part of the composition algebra**—it is a separate phase that interprets composed structures. This section is included for completeness but is not normative for the algebra itself.

### 7.1 Resolution for Roles (Class Finalization)

When a composed role is finalized into a class:
1. **No Conflicted slots allowed:** Every Conflicted slot is an error
2. **No Required slots allowed (optionally):** Depending on whether the target is abstract or concrete

The resolution phase walks the role, checks these conditions, and either produces a validated structure or reports all violations.

### 7.2 Resolution for Scopes (Variable Lookup)

When a scope is used for variable lookup:
1. **Conflicted slots indicate shadowing:** Not an error
2. **Resolve by walking the tree:** Convention is "right child wins" (most recent binding)
3. **Required slots indicate unbound variables:** May be an error depending on context

The resolution phase selects a value from the Conflicted tree based on policy.

---

## 8. Rationale for Removed Features

**Alias(name, slot):** Removed because it introduces complexity at the algebraic level for what is essentially a user-level renaming mechanism. Renaming can be handled by class definition macros without being a fundamental algebraic operation. If renaming is needed during composition, it can be done by constructing a new Defined slot with the new name and the old value, rather than wrapping in an Alias node.

**Exclusion:** Removed for similar reasons. Excluding a slot from composition is a user-level operation (don't include it in the source role) rather than an algebraic primitive. It doesn't need a dedicated slot variant or composition rule.

**Projection (project(role, names)):** Removed because it's a derived operation (filter a role to a subset of names), not a fundamental algebraic operation. It can be defined straightforwardly as:
```
project(role, names) = { n: role[n] for each n in names if n ∈ keys(role) }
```
No special algebraic treatment is needed.

These features remain available at the language level as conveniences, but they're not part of the core algebra.

---

## 9. Summary

The slot composition algebra consists of:

**Primitives:**
- Four slot variants: Required, Defined, Conflicted (Alias removed)
- Content-addressed identity via hash functions
- External name function for name recovery

**Operations:**
- One total binary operation: `compose(Slot, Slot) → Slot`
- Pointwise role composition: `compose_roles(Role, Role) → Role`

**Properties:**
- Associative (up to tree shape)
- Commutative (up to resolution policy)
- Identity element (Required for slots, empty role for roles)
- Idempotent (for identical values)
- Total (never fails)

**Design principle:**
Composition accumulates structure; resolution interprets it. The algebra's job is to preserve all information and compose purely. Policy decisions are deferred to a separate phase.
