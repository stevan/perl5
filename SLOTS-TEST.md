# Trait Composition Test Fixtures for MXCL

Designed against the Slot Composition Algebra formal specification.

## Design Principles

The algebra has three slot variants (Required, Defined, Conflicted), one
operation (compose), and resolution is a separate phase. Composition is
total — it never fails. Conflict is structural (different content hash),
not origin-based.

Every Defined slot's value is a string identifying its source, making
assertions trivial. Two Defined slots with the same string have the same
hash and compose idempotently. Two Defined slots with different strings
have different hashes and produce a Conflicted node.

We write slots as:
- `Req(n)` for Required("n")
- `Def(n, v)` for Defined("n", v)
- `Con(L, R)` for Conflicted(L, R)

We write roles as `{ n1: slot1, n2: slot2, ... }`.

---

## Part 1: Slot-Level Composition (the 3×3 table)

These tests verify every cell of the composition table from §4.1 of the
spec, plus the Defined+Defined split from §4.2.

### Test S1: Required + Required → Required
```
compose(Req("x"), Req("x"))  =  Req("x")
```

### Test S2: Required + Defined → Defined
```
compose(Req("x"), Def("x", "v1"))  =  Def("x", "v1")
```

### Test S3: Defined + Required → Defined
```
compose(Def("x", "v1"), Req("x"))  =  Def("x", "v1")
```

### Test S4: Defined + Defined (same hash) → Defined
```
compose(Def("x", "v1"), Def("x", "v1"))  =  Def("x", "v1")
```

### Test S5: Defined + Defined (different hash) → Conflicted
```
compose(Def("x", "v1"), Def("x", "v2"))  =  Con(Def("x", "v1"), Def("x", "v2"))
```

### Test S6: Required + Conflicted → Conflicted (unchanged)
```
let c = Con(Def("x", "v1"), Def("x", "v2"))
compose(Req("x"), c)  =  c
```
Required is the identity element, so the Conflicted passes through.

### Test S7: Conflicted + Required → Conflicted (unchanged)
```
let c = Con(Def("x", "v1"), Def("x", "v2"))
compose(c, Req("x"))  =  c
```

### Test S8: Defined + Conflicted → Conflicted (wraps)
```
let c = Con(Def("x", "v1"), Def("x", "v2"))
compose(Def("x", "v3"), c)  =  Con(Def("x", "v3"), c)
```
The Defined is absorbed into a new Conflicted node. The original
Conflicted subtree is preserved as the right child.

### Test S9: Conflicted + Defined → Conflicted (wraps)
```
let c = Con(Def("x", "v1"), Def("x", "v2"))
compose(c, Def("x", "v3"))  =  Con(c, Def("x", "v3"))
```
Mirror of S8. The original Conflicted is the left child.

### Test S10: Conflicted + Conflicted → Conflicted (wraps)
```
let c1 = Con(Def("x", "v1"), Def("x", "v2"))
let c2 = Con(Def("x", "v3"), Def("x", "v4"))
compose(c1, c2)  =  Con(c1, c2)
```
Both subtrees preserved. The result is a tree with four leaves.

---

## Part 2: Base Roles

### Atomic Roles (no requirements, no composition)

```
role RA {
    m1: Def("m1", "RA::m1")
    m2: Def("m2", "RA::m2")
}

role RB {
    m2: Def("m2", "RB::m2")
    m3: Def("m3", "RB::m3")
}

role RC {
    m3: Def("m3", "RC::m3")
    m4: Def("m4", "RC::m4")
}

role RD {
    m1: Def("m1", "RD::m1")
    m4: Def("m4", "RD::m4")
}
```

Overlap graph (all overlapping slots have **different** hashes):
```
    m1      m2      m3      m4
RA   ●───────●
RB           ●───────●
RC                   ●───────●
RD   ●───────────────────────●
```

### Identical-Body Roles (for content-hash idempotency)

```
role RX {
    m1: Def("m1", "shared::m1")
    m5: Def("m5", "RX::m5")
}

role RY {
    m1: Def("m1", "shared::m1")    // same value as RX → same hash
    m6: Def("m6", "RY::m6")
}
```

### Requirement Roles

```
role RReqM1 {
    m1: Req("m1")
    r1: Def("r1", λ() -> self.m1())
}

role RReqM2 {
    m2: Req("m2")
    r2: Def("r2", λ() -> self.m2())
}

role RReqM1M2 {
    m1: Req("m1")
    m2: Req("m2")
    r12: Def("r12", λ() -> [self.m1(), self.m2()])
}

role RReqM3DefM4 {
    m3: Req("m3")
    m4: Def("m4", "RReqM3DefM4::m4")
    uses_m3: Def("uses_m3", λ() -> self.m3())
}
```

### Diamond-Forming Roles

```
role RBase {
    m: Def("m", "RBase::m")
    shared: Def("shared", "RBase::shared")
}

role RLeft {
    // flattened: contains RBase's slots + its own
    m: Def("m", "RBase::m")                 // same hash as RBase
    shared: Def("shared", "RBase::shared")  // same hash as RBase
    left: Def("left", "RLeft::left")
}

role RRight {
    m: Def("m", "RBase::m")                 // same hash as RBase
    shared: Def("shared", "RBase::shared")  // same hash as RBase
    right: Def("right", "RRight::right")
}

role RLeftOverride {
    m: Def("m", "RLeftOverride::m")         // DIFFERENT hash from RBase
    shared: Def("shared", "RBase::shared")  // same hash as RBase
    left: Def("left", "RLeftOverride::left")
}

role RRightOverride {
    m: Def("m", "RRightOverride::m")        // different from both RBase and RLeftOverride
    shared: Def("shared", "RBase::shared")
    right: Def("right", "RRightOverride::right")
}

role RRightSameOverride {
    m: Def("m", "RLeftOverride::m")         // SAME hash as RLeftOverride's m
    shared: Def("shared", "RBase::shared")
    right: Def("right", "RRightSameOverride::right")
}
```

### Circular Requirement Roles

```
role RCircA {
    n: Req("n")
    m: Def("m", "RCircA::m")
}

role RCircB {
    m: Req("m")
    n: Def("n", "RCircB::n")
}
```

### Trivial Roles

```
role REmpty {}

role RBaz {
    m5: Def("m5", "RBaz::m5")
}

role RC2 {
    m2: Def("m2", "RC2::m2")
}
```

### Conflict-Tree Roles (for testing Con + Con)

```
role RX2 { m2: Def("m2", "RX2::m2") }
role RY2 { m2: Def("m2", "RY2::m2") }
```

### Same-Hash Provider Roles (for testing R26)

```
role RProvM1      { m1: Def("m1", "shared::m1") }
role RAlsoProvM1  { m1: Def("m1", "shared::m1") }  // same hash
```

---

## Part 3: Role Compositions and Expected Results

For each composition we specify the resulting role as a slot map.
`Con(...)` trees show the exact expected structure.

---

### 3.1 — Disjoint Composition

#### Test R1: No overlap
```
compose_roles(RA, RBaz)
```
```
{
    m1: Def("m1", "RA::m1"),
    m2: Def("m2", "RA::m2"),
    m5: Def("m5", "RBaz::m5")
}
```
Slots from different names simply merge.

#### Test R2: Empty is identity
```
compose_roles(REmpty, RA)  =  RA
compose_roles(RA, REmpty)  =  RA
```
Empty role has no keys. Per §6.3, missing keys are implicitly
Required, which is the identity element. Result is RA unchanged.

---

### 3.2 — Requirement Satisfaction

#### Test R3: Requirement met
```
compose_roles(RA, RReqM1)
```
```
{
    m1: Def("m1", "RA::m1"),        // RA's Def + RReqM1's Req → Def
    m2: Def("m2", "RA::m2"),        // only in RA
    r1: Def("r1", λ() -> self.m1()) // only in RReqM1
}
```
Req("m1") + Def("m1", "RA::m1") → Def("m1", "RA::m1").
Calling `r1()` returns `"RA::m1"`.

#### Test R4: Requirement unmet
```
compose_roles(RB, RReqM1)
```
```
{
    m1: Req("m1"),                   // only in RReqM1, propagates
    m2: Def("m2", "RB::m2"),        // only in RB
    m3: Def("m3", "RB::m3"),        // only in RB
    r1: Def("r1", λ() -> self.m1()) // only in RReqM1
}
```
RB doesn't have m1, so the Req propagates.

#### Test R5: Multiple requirements, all met
```
compose_roles(RA, RReqM1M2)
```
```
{
    m1: Def("m1", "RA::m1"),                         // Req met by RA
    m2: Def("m2", "RA::m2"),                         // Req met by RA
    r12: Def("r12", λ() -> [self.m1(), self.m2()])   // from RReqM1M2
}
```

#### Test R6: Multiple requirements, none met
```
compose_roles(RC, RReqM1M2)
```
```
{
    m1: Req("m1"),                                    // unmet
    m2: Req("m2"),                                    // unmet
    m3: Def("m3", "RC::m3"),
    m4: Def("m4", "RC::m4"),
    r12: Def("r12", λ() -> [self.m1(), self.m2()])
}
```

#### Test R7: Mutual satisfaction (circular requirements)
```
compose_roles(RCircA, RCircB)
```
```
{
    m: Def("m", "RCircA::m"),    // RCircB's Req("m") + RCircA's Def → Def
    n: Def("n", "RCircB::n")     // RCircA's Req("n") + RCircB's Def → Def
}
```
Each role provides what the other requires. No leftover requirements.

#### Test R8: Requirement meets a conflict (not satisfied)
```
compose_roles(RReqM2, compose_roles(RA, RB))
```
```
{
    m1: Def("m1", "RA::m1"),
    m2: Con(Def("m2", "RA::m2"), Def("m2", "RB::m2")),  // Req is identity
    m3: Def("m3", "RB::m3"),
    r2: Def("r2", λ() -> self.m2())
}
```
m2 is Conflicted between RA and RB. RReqM2's Req("m2") composes with
the Conflicted → Conflicted wins (Req is identity). The requirement
is NOT satisfied by a conflicted slot.

---

### 3.3 — Conflict Detection

#### Test R9: Simple conflict
```
compose_roles(RA, RB)
```
```
{
    m1: Def("m1", "RA::m1"),
    m2: Con(Def("m2", "RA::m2"), Def("m2", "RB::m2")),
    m3: Def("m3", "RB::m3")
}
```

#### Test R10: No conflict — same hash, different origin
```
compose_roles(RX, RY)
```
```
{
    m1: Def("m1", "shared::m1"),     // same hash → idempotent
    m5: Def("m5", "RX::m5"),
    m6: Def("m6", "RY::m6")
}
```
Content-hash equality means independently-authored identical bodies
compose without conflict.

#### Test R11: Mixed — some same hash, some different
```
compose_roles(RX, RA)
```
RX has Def("m1", "shared::m1"), RA has Def("m1", "RA::m1"). Different hashes.
```
{
    m1: Con(Def("m1", "shared::m1"), Def("m1", "RA::m1")),
    m2: Def("m2", "RA::m2"),
    m5: Def("m5", "RX::m5")
}
```

#### Test R12: Two conflicts
```
compose_roles(RA, compose_roles(RB, RC))
```
```
{
    m1: Def("m1", "RA::m1"),
    m2: Con(Def("m2", "RA::m2"), Def("m2", "RB::m2")),
    m3: Con(Def("m3", "RB::m3"), Def("m3", "RC::m3")),
    m4: Def("m4", "RC::m4")
}
```

#### Test R13: Total conflict — four roles
```
compose_roles(RA, compose_roles(RB, compose_roles(RC, RD)))
```
```
{
    m1: Con(Def("m1", "RA::m1"), Def("m1", "RD::m1")),
    m2: Con(Def("m2", "RA::m2"), Def("m2", "RB::m2")),
    m3: Con(Def("m3", "RB::m3"), Def("m3", "RC::m3")),
    m4: Con(Def("m4", "RC::m4"), Def("m4", "RD::m4"))
}
```
Every slot has exactly one conflict (two providers with different hashes).

---

### 3.4 — Algebraic Properties

#### Test R14: Commutativity (same resolution semantics)
```
let AB = compose_roles(RA, RB)
let BA = compose_roles(RB, RA)
```
AB:
```
{
    m1: Def("m1", "RA::m1"),
    m2: Con(Def("m2", "RA::m2"), Def("m2", "RB::m2")),
    m3: Def("m3", "RB::m3")
}
```
BA:
```
{
    m1: Def("m1", "RA::m1"),
    m2: Con(Def("m2", "RB::m2"), Def("m2", "RA::m2")),  // children swapped
    m3: Def("m3", "RB::m3")
}
```
The m2 Conflicted nodes have **different hashes** (children are swapped),
but under symmetric resolution (role composition) they are equivalent:
both contain the same two leaves, both are errors requiring resolution.

The non-conflicted slots (m1, m3) are identical in both.

#### Test R15: Associativity (same structure in this case)
```
let AB_C = compose_roles(compose_roles(RA, RB), RC)
let A_BC = compose_roles(RA, compose_roles(RB, RC))
```
Focus on m3 (conflicted in both):

In AB_C: (RA+RB) has m3 as Def("m3", "RB::m3"), then composed with RC's
Def("m3", "RC::m3") → Con(Def(RB), Def(RC)).

In A_BC: (RB+RC) has m3 as Con(Def(RB), Def(RC)), then RA has no m3 →
implicit Req("m3"), and Req + Conflicted → Conflicted (identity).

Both yield `Con(Def("m3", "RB::m3"), Def("m3", "RC::m3"))`.

Focus on m2:

In AB_C: (RA+RB) has m2 as Con(Def(RA), Def(RB)), then RC has no m2 →
implicit Req, identity. Unchanged.

In A_BC: (RB+RC) has m2 as Def("m2", "RB::m2"), then composed with
RA's Def("m2", "RA::m2") → Con(Def(RA), Def(RB)).

Both yield `Con(Def("m2", "RA::m2"), Def("m2", "RB::m2"))`.

Full result — both produce:
```
{
    m1: Def("m1", "RA::m1"),
    m2: Con(Def("m2", "RA::m2"), Def("m2", "RB::m2")),
    m3: Con(Def("m3", "RB::m3"), Def("m3", "RC::m3")),
    m4: Def("m4", "RC::m4")
}
```
In this case, the results happen to be structurally identical because
each conflict involves exactly two Defined leaves.

#### Test R16: Associativity with three-way conflict (tree shape diverges)

All three of RA, RB, and RC2 provide m2 with different hashes.

```
let AB = compose_roles(RA, RB)       // m2: Con(Def(RA), Def(RB))
let AB_C2 = compose_roles(AB, RC2)   // m2: Con(Con(Def(RA), Def(RB)), Def(RC2))

let BC2 = compose_roles(RB, RC2)     // m2: Con(Def(RB), Def(RC2))
let A_BC2 = compose_roles(RA, BC2)   // m2: Con(Def(RA), Con(Def(RB), Def(RC2)))
```

AB_C2 m2 tree:
```
        Con
       /   \
     Con    Def("m2","RC2::m2")
    /   \
Def     Def
(RA)    (RB)
```

A_BC2 m2 tree:
```
     Con
    /   \
Def      Con
(RA)    /   \
    Def     Def
    (RB)    (RC2)
```

These have **different hashes** (different tree shapes), but the flattened
multiset of leaves is identical: {Def(RA), Def(RB), Def(RC2)}.

Under symmetric resolution, both are equivalent — all three values
are in conflict and must be resolved.

#### Test R17: Idempotency
```
compose_roles(RA, RA)  =  RA
```
Every slot composes with its identical twin (same hash). Per §4.2,
Def + Def with same hash → Def. Result is structurally identical
to the input (same role hash).

#### Test R18: Idempotency with requirements
```
compose_roles(RReqM1, RReqM1)  =  RReqM1
```
```
{
    m1: Req("m1"),                    // Req + Req → Req
    r1: Def("r1", λ() -> self.m1())  // Def + Def (same hash) → Def
}
```

---

### 3.5 — Diamond Composition

#### Test R19: Classic diamond — same hash, no conflict
```
compose_roles(RLeft, RRight)
```
Both RLeft and RRight contain `m` and `shared` with the same values
(inherited from RBase with identical hashes).
```
{
    m: Def("m", "RBase::m"),                // same hash → idempotent
    shared: Def("shared", "RBase::shared"), // same hash → idempotent
    left: Def("left", "RLeft::left"),
    right: Def("right", "RRight::right")
}
```
No conflicts. The diamond is resolved structurally by content-hashing.

#### Test R20: Diamond — one side overrides
```
compose_roles(RLeftOverride, RRight)
```
RLeftOverride has `m: Def("m", "RLeftOverride::m")` — different hash
from RRight's `m: Def("m", "RBase::m")`.
```
{
    m: Con(Def("m", "RLeftOverride::m"), Def("m", "RBase::m")),
    shared: Def("shared", "RBase::shared"),   // same hash → no conflict
    left: Def("left", "RLeftOverride::left"),
    right: Def("right", "RRight::right")
}
```
Only `m` conflicts. `shared` composes idempotently.

#### Test R21: Diamond — both sides override, different bodies
```
compose_roles(RLeftOverride, RRightOverride)
```
```
{
    m: Con(Def("m", "RLeftOverride::m"), Def("m", "RRightOverride::m")),
    shared: Def("shared", "RBase::shared"),
    left: Def("left", "RLeftOverride::left"),
    right: Def("right", "RRightOverride::right")
}
```

#### Test R22: Diamond — both sides override, convergent (same body)
```
compose_roles(RLeftOverride, RRightSameOverride)
```
```
{
    m: Def("m", "RLeftOverride::m"),           // same hash → idempotent!
    shared: Def("shared", "RBase::shared"),
    left: Def("left", "RLeftOverride::left"),
    right: Def("right", "RRightSameOverride::right")
}
```
Both sides overrode RBase::m but arrived at the same value.
Content-hashing means convergent evolution is conflict-free.

---

### 3.6 — Conflict Absorption (Conflicted is "sticky")

#### Test R23: Conflicted survives composition with empty
```
compose_roles(compose_roles(RA, RB), REmpty)
```
```
{
    m1: Def("m1", "RA::m1"),
    m2: Con(Def("m2", "RA::m2"), Def("m2", "RB::m2")),   // unchanged
    m3: Def("m3", "RB::m3")
}
```
REmpty's implicit Req slots are identity elements. Conflict persists.

#### Test R24: Third provider does NOT resolve — it compounds
```
compose_roles(compose_roles(RA, RB), RC2)
```
RC2 provides Def("m2", "RC2::m2").
```
{
    m1: Def("m1", "RA::m1"),
    m2: Con(Con(Def("m2", "RA::m2"), Def("m2", "RB::m2")), Def("m2", "RC2::m2")),
    m3: Def("m3", "RB::m3")
}
```
The existing Conflicted on m2 absorbs RC2's Def into a deeper tree.
This is the key associativity-preserving behavior: conflicts are
never accidentally resolved.

#### Test R25: Conflicted + Conflicted from independent compositions
```
let AB = compose_roles(RA, RB)       // m2: Con(Def(RA), Def(RB))
let XY = compose_roles(RX2, RY2)     // m2: Con(Def(RX2), Def(RY2))
compose_roles(AB, XY)
```
```
{
    m1: Def("m1", "RA::m1"),
    m2: Con(
        Con(Def("m2", "RA::m2"), Def("m2", "RB::m2")),
        Con(Def("m2", "RX2::m2"), Def("m2", "RY2::m2"))
    ),
    m3: Def("m3", "RB::m3")
}
```
Four-leaf conflict tree from composing two independent conflicts.

---

### 3.7 — Requirement Interaction Patterns

#### Test R26: Requirement met by same-hash Defined from two roles
```
compose_roles(RReqM1, compose_roles(RProvM1, RAlsoProvM1))
```
RProvM1 + RAlsoProvM1 → m1: Def("m1", "shared::m1") (idempotent).
Then Req("m1") + Def("m1", "shared::m1") → Def.
```
{
    m1: Def("m1", "shared::m1"),
    r1: Def("r1", λ() -> self.m1())
}
```
Requirement satisfied. `r1()` returns `"shared::m1"`.

#### Test R27: Requirement meets a conflict (not satisfied)
```
compose_roles(RReqM1, compose_roles(RA, RD))
```
RA + RD: m1 conflicts (different hashes).
```
{
    m1: Con(Def("m1", "RA::m1"), Def("m1", "RD::m1")),  // Req is identity
    m2: Def("m2", "RA::m2"),
    m4: Def("m4", "RD::m4"),
    r1: Def("r1", λ() -> self.m1())
}
```
Req + Conflicted → Conflicted. The requirement is NOT satisfied.

#### Test R28: Requirement satisfied + separate conflict on another slot
```
compose_roles(RReqM3DefM4, RC)
```
RReqM3DefM4 requires m3, provides m4 and uses_m3.
RC provides m3 and m4 (different hash from RReqM3DefM4::m4).
```
{
    m3: Def("m3", "RC::m3"),
    m4: Con(Def("m4", "RReqM3DefM4::m4"), Def("m4", "RC::m4")),
    uses_m3: Def("uses_m3", λ() -> self.m3())
}
```
m3 requirement is satisfied. m4 conflicts. `uses_m3()` returns `"RC::m3"`.

#### Test R29: Requirement satisfied, no other conflicts
```
compose_roles(RReqM3DefM4, RB)
```
RB provides m2 and m3. No overlap on m4.
```
{
    m2: Def("m2", "RB::m2"),
    m3: Def("m3", "RB::m3"),
    m4: Def("m4", "RReqM3DefM4::m4"),
    uses_m3: Def("uses_m3", λ() -> self.m3())
}
```
Clean composition — requirement met, no conflicts.

---

### 3.8 — Class Override (Resolution Phase)

These tests verify that class-provided methods override trait methods.
This is resolution, not composition, but it exercises the full pipeline.

#### Test R30: Class overrides a Defined slot
```
class C uses RA {
    m1: Def("m1", "C::m1")
}
```
After composition + resolution:

| slot | value |
|------|-------|
| m1 | "C::m1" (class wins) |
| m2 | "RA::m2" |

#### Test R31: Class resolves a conflict
```
class C uses compose_roles(RA, RB) {
    m2: Def("m2", "C::m2")
}
```
| slot | value |
|------|-------|
| m1 | "RA::m1" |
| m2 | "C::m2" (resolves the RA/RB conflict) |
| m3 | "RB::m3" |

#### Test R32: Class satisfies a requirement
```
class C uses RReqM1 {
    m1: Def("m1", "C::m1")
}
```
| slot | value |
|------|-------|
| m1 | "C::m1" |
| r1 | λ() -> self.m1() → returns "C::m1" |

#### Test R33: Class with unresolved conflict → error at resolution
```
class C uses compose_roles(RA, RB) {
    // does NOT provide m2
}
```
Resolution must report: m2 is Conflicted and unresolved.

#### Test R34: Class with unresolved requirement → error at resolution
```
class C uses RReqM1 {
    // does NOT provide m1
}
```
Resolution must report: m1 is Required and unsatisfied.

---

## Part 4: Cheat Sheet

| # | Composition | Defined | Required | Conflicted | Key property |
|---|-------------|---------|----------|------------|-------------|
| R1 | RA + RBaz | 3 | 0 | 0 | Disjoint merge |
| R2 | REmpty + RA | 2 | 0 | 0 | Identity element |
| R3 | RA + RReqM1 | 3 | 0 | 0 | Req satisfaction |
| R4 | RB + RReqM1 | 3 | 1 | 0 | Req propagation |
| R5 | RA + RReqM1M2 | 3 | 0 | 0 | Multi-req satisfied |
| R6 | RC + RReqM1M2 | 3 | 2 | 0 | Multi-req propagation |
| R7 | RCircA + RCircB | 2 | 0 | 0 | Mutual satisfaction |
| R8 | RReqM2 + (RA+RB) | 3 | 0 | 1 | Req + conflict |
| R9 | RA + RB | 2 | 0 | 1 | Simple conflict |
| R10 | RX + RY | 3 | 0 | 0 | Same-hash non-conflict |
| R11 | RX + RA | 2 | 0 | 1 | Mixed hash conflict |
| R12 | RA + (RB+RC) | 2 | 0 | 2 | Two conflicts |
| R13 | RA+(RB+(RC+RD)) | 0 | 0 | 4 | Total conflict |
| R14 | RA+RB vs RB+RA | - | - | - | Commutativity |
| R15 | (RA+RB)+RC vs RA+(RB+RC) | - | - | - | Associativity (same) |
| R16 | (RA+RB)+RC2 vs RA+(RB+RC2) | - | - | - | Associativity (diverges) |
| R17 | RA + RA | 2 | 0 | 0 | Idempotency |
| R18 | RReqM1 + RReqM1 | 1 | 1 | 0 | Idempotency + reqs |
| R19 | RLeft + RRight | 4 | 0 | 0 | Diamond (same hash) |
| R20 | RLeftOverride + RRight | 3 | 0 | 1 | Diamond (one override) |
| R21 | RLeftOverride + RRightOverride | 3 | 0 | 1 | Diamond (both, diff) |
| R22 | RLeftOverride + RRightSameOverride | 4 | 0 | 0 | Diamond (convergent) |
| R23 | (RA+RB) + REmpty | 2 | 0 | 1 | Conflict survives |
| R24 | (RA+RB) + RC2 | 2 | 0 | 1 | No accidental resolution |
| R25 | (RA+RB) + (RX2+RY2) | 2 | 0 | 1 | Con + Con → deeper tree |
| R26 | RReqM1 + (RProv+RAlsoProv) | 2 | 0 | 0 | Req met by idempotent |
| R27 | RReqM1 + (RA+RD) | 3 | 0 | 1 | Req meets conflict |
| R28 | RReqM3DefM4 + RC | 2 | 0 | 1 | Req sat + conflict |
| R29 | RReqM3DefM4 + RB | 4 | 0 | 0 | Clean req + provision |
