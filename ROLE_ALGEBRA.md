# Perl 5 Role Composition Algebra

## 1. Overview

This document specifies the algebra governing role composition in
Perl 5's `feature 'class'`. Role composition is the process by which
a role's methods and fields are incorporated into a consuming class
or role.

The central concept is the **proto-role**: an intermediate
representation that captures a class's or role's fields, methods,
and their relationships. All classes and roles are built from
proto-roles — they are the universal substrate of the object system.
Proto-roles are constructed during parsing, composed and resolved at
seal time, and their contents installed into the stash to produce the
final class or role.

The algebra has two sub-algebras — one for **methods** and one for
**fields** — that share a common structure but differ in their
conflict resolution policies. Both algebras use **origin-based
identity**: two items are considered "the same" if and only if they
originate from the same stash (package). Content equality is not
considered.

**Design principles:**

1. **Proto-roles are the foundation.** Every class and role is built
   from a proto-role. The proto-role is the intermediate
   representation through which all fields and methods flow.
2. **Composition is total.** Composing proto-roles never fails.
   Conflicts and unsatisfied requirements are recorded as data, not
   raised as exceptions.
3. **Resolution is separate.** After composition, a resolution phase
   inspects the result and either validates it or reports all errors
   at once.
4. **Origin identity.** Two methods (or fields) with the same name
   are "the same" if they originate from the same stash. This handles
   diamond composition naturally.
5. **Explicit methods resolve conflicts.** A consumer that provides
   its own explicitly declared method with a conflicting name resolves
   the conflict. Generated accessor methods do not have this power.
   This does not apply to fields — field conflicts are always errors.

---

## 2. Proto-Roles

### 2.1 Definition

A **proto-role** is a pair of finite maps plus an origin:

```
ProtoRole = {
    methods: { name₁: method_slot₁, name₂: method_slot₂, ... },
    fields:  { name₁: field_slot₁,  name₂: field_slot₂,  ... },
    origin:  stash
}
```

The `origin` is the stash (package) of the class or role being
defined. It is used for identity comparison during composition: two
methods with the same name and the same origin are considered "the
same" and compose idempotently.

The method and field slot types are defined in §4 and §5 respectively.

### 2.2 Lifecycle

A proto-role goes through the following phases:

1. **Construction** (during parsing): Fields and methods are
   accumulated into the proto-role as they are parsed. Generated
   accessor methods are recorded alongside their originating field
   declarations. Same-name collisions between generated accessors
   are detected during this phase. (§3)

2. **Composition** (at seal time): The consumer's proto-role is
   composed with the proto-roles of all roles consumed via `:does`,
   using the method and field algebras. (§4–§7)

3. **Resolution** (at seal time): The composed result is checked for
   conflicts and unsatisfied requirements. The consumer's explicitly
   declared methods can resolve conflicts and satisfy requirements.
   (§8)

4. **Sealing**: The resolved proto-role's methods are installed into
   the stash, fields are allocated storage, and the class or role
   becomes usable.

### 2.3 Roles and Classes as Sealed Proto-Roles

A **role** is a proto-role that has been constructed, had its own
construction-time conflicts resolved, and been sealed. It is
available for composition into other proto-roles via `:does`.

A **class** is a proto-role that has been constructed, composed with
its roles, resolved, and sealed. It can additionally instantiate
objects and participate in inheritance.

Both follow the same lifecycle. The difference is that a role defers
final resolution of Required and Conflicted slots to its eventual
consumer, while a class must resolve everything.

### 2.4 Retention

The implementation MAY retain proto-roles after sealing for
introspection, efficient `->DOES` checks (§11), and richer runtime
error reporting. The decision of whether to retain and at what cost
is an implementation concern.

---

## 3. Proto-Role Construction

During parsing of a class or role body, the proto-role is built
incrementally. This section specifies the rules governing that
construction.

### 3.1 Accumulation

As the parser encounters declarations in a class or role body:

- **Field declarations** (`field $x`, `field @items`, etc.) add
  entries to the proto-role's field map. Fields carry metadata
  (sigil, default, `:param` name) but this does not affect
  composition identity — only `name` and `origin` matter.

- **Explicit method declarations** (`method foo { ... }`) add
  entries to the proto-role's method map.

- **Field attributes** (`:reader`, `:writer`) generate accessor
  method CVs that are added to the proto-role's method map. These
  CVs are compiled at parse time (they must be valid Perl), but
  are held in the proto-role rather than installed directly into
  the stash. Installation happens only after composition and
  resolution succeed at seal time.

Each method entry in the proto-role tracks its **provenance**: was
it explicitly declared by the author, or generated by a field
attribute? Provenance is used for construction-time collision
detection, for determining which methods have conflict-resolving
power during resolution (§8), and for rich error messages.

### 3.2 Same-Name Collision Rules

When a method is added to the proto-role's method map and a method
with the same name already exists, the following rules apply:

**Generated accessor + generated accessor (different fields):**
The collision is recorded as a construction-time conflict. It may
be resolved by a subsequent explicit method declaration (see below).
If unresolved at seal time, it is an error.

```perl
class Foo {
    field $x :reader;   # generates accessor method 'x'
    field @x :reader;   # generates accessor method 'x' — collision recorded
}
# Error at seal time: Method 'x' conflicts between :reader for
# field '$x' (line 2) and :reader for field '@x' (line 3)
```

**Explicit method + generated accessor (either parsing order):**
The explicit method takes precedence. The generated accessor is
discarded. A warning is issued under `use warnings 'redefine'` (or
a dedicated warnings category such as `'class'` if warranted),
mirroring how Perl handles subroutine redeclaration.

```perl
class Foo {
    field $x :reader;   # generates accessor method 'x'
    field @x :reader;   # generates accessor method 'x' — collision
    method x { ... }    # explicit: resolves the collision (with warning)
}
# OK — Foo's explicit method 'x' is installed
```

```perl
class Bar {
    field $x :reader;   # generates accessor method 'x'
    method x { ... }    # explicit: takes precedence (with warning)
}
# OK — Bar's explicit method 'x' is installed, generated reader discarded
```

**Explicit method + explicit method:**
Standard Perl redeclaration semantics: the later declaration wins,
with a warning under `use warnings 'redefine'`.

### 3.3 Construction-Time vs. Composition-Time Conflicts

Construction-time conflicts (two generated accessors with the same
name within a single class or role) are distinct from composition-
time conflicts (methods from different roles with different origins).

Construction-time conflicts are detected and resolved during the
construction phase, before the composition algebra runs. A proto-role
that exits construction successfully has no unresolved construction-
time conflicts — they are either resolved by explicit methods during
parsing, or reported as errors at seal time (prior to composition).

This means construction-time conflicts do not propagate through
composition. If a role has two fields that generate conflicting
accessor names, the role must resolve the conflict itself (by
providing an explicit method or by using explicit accessor names
like `:reader(other_name)`). The conflict cannot be deferred to a
consuming class.

```perl
role Broken {
    field $x :reader;
    field @x :reader;
    # Error: role Broken must resolve this itself
}

role Fixed {
    field $x :reader;
    field @x :reader(x_list);   # no collision
}
```

### 3.4 Provenance vs. Origin

Each method in the proto-role carries two pieces of identity that
serve different purposes:

**Origin** (stash) — Used by the composition algebra (§4) for
conflict detection between proto-roles. Two methods with the same
name and the same origin compose idempotently. Two methods with
the same name and different origins conflict.

**Provenance** (field declaration or explicit) — Used during
construction for same-class collision detection (§3.2), during
resolution for determining which methods can resolve conflicts
(§8), and for rich diagnostic messages. Provenance tracks *why*
a method exists: was it explicitly declared, or generated by
`:reader` on field `$x`?

The composition algebra operates on origin only. Provenance is
orthogonal metadata for construction and diagnostics.

---

## 4. Method Algebra

### 4.1 Method Slot Variants

A **method slot** for a given name exists in one of three states:

**Required(name)**
- Declares that `name` must be provided but has no implementation.
- In Perl 5, this is a bodyless method stub: `method foo;`
- A Required slot carries no origin — it is a pure obligation.

**Defined(name, origin)**
- A concrete method implementation for `name`.
- `origin` is the stash (package) where the method was originally
  defined. Origin is used for identity comparison.

**Conflicted(name, origins)**
- Records that two or more proto-roles provided different
  implementations of `name`.
- `origins` is the set of distinct origin stashes that contributed
  conflicting implementations.
- A Conflicted slot also implies a requirement: the consumer must
  resolve the conflict by providing its own implementation. (§4.5)

### 4.2 Method Composition Rules

Composition operates on two method slots with the same name. We
write `compose(left, right)` for the result.

| left \ right         | Required        | Defined(_, o2)       | Conflicted(_, O2)     |
|----------------------|-----------------|----------------------|-----------------------|
| **Required**         | Required        | Defined(_, o2)       | Conflicted(_, O2)     |
| **Defined(_, o1)**   | Defined(_, o1)  | *(see §4.3)*         | Conflicted(_, {o1}∪O2)|
| **Conflicted(_, O1)**| Conflicted(_,O1)| Conflicted(_,O1∪{o2})| Conflicted(_,O1∪O2)  |

Where:
- `o1`, `o2` are origin stashes
- `O1`, `O2` are sets of origin stashes

### 4.3 Defined + Defined

```
compose(Defined(n, o1), Defined(n, o2)) =
    if o1 == o2:   Defined(n, o1)          # diamond: same origin, idempotent
    else:           Conflicted(n, {o1, o2}) # different origins: conflict
```

### 4.4 Key Properties

**Required is the identity element:**
```
compose(Required(n), s) = s
compose(s, Required(n)) = s
```

**Conflicted absorbs:**
Once a slot is Conflicted, composing with any Defined adds that
origin to the conflict set. Composing with Required is a no-op
(identity). Composing two Conflicted sets unions their origins.

**Idempotent for same origin:**
```
compose(Defined(n, o), Defined(n, o)) = Defined(n, o)
```

**Flat conflict sets:**
Unlike algebras that build binary trees of conflict nodes, this
algebra flattens conflicts into a set of origins. This is
sufficient because Perl 5 role composition uses symmetric
resolution — the order of composition does not affect conflict
detection, and all origins in a conflict are equally "wrong."

### 4.5 A Conflicted Method Is Also Required

A Conflicted method slot carries an implicit requirement: the
consumer must provide its own method to resolve the conflict.

During resolution (§8), a Conflicted slot is treated as both an
error (the conflict) and an obligation (the requirement), and a
consumer-provided explicit method satisfies both.

### 4.6 Example: Method Algebra

```perl
role RA { method render { "RA" } }
role RB { method render { "RB" } }
role RC { method render;  }          # Required
```

```
compose(Defined(render, RA), Defined(render, RB))
    = Conflicted(render, {RA, RB})          # different origins

compose(Defined(render, RA), Required(render))
    = Defined(render, RA)                   # Required is identity

compose(Conflicted(render, {RA, RB}), Defined(render, RC))
    — but RC has Required(render), not Defined, so:
compose(Conflicted(render, {RA, RB}), Required(render))
    = Conflicted(render, {RA, RB})          # identity, conflict unchanged
```

---

## 5. Field Algebra

### 5.1 Field Slot Variants

A **field slot** for a given name exists in one of two states:

**Defined(name, origin)**
- A concrete field declaration for `name`.
- `origin` is the stash where the field was originally declared.
- Fields carry additional metadata (sigil, default, `:param` name,
  `:reader`/`:writer` attributes) but these do not affect
  composition identity — only `name` and `origin` matter.

**Conflicted(name, origins)**
- Records that two or more proto-roles declared fields with the same
  `name` from different origins.
- Field conflicts are **unresolvable** — a class cannot "override"
  a field the way it can override a method. The only resolution is
  to fix the role hierarchy.

There is no Required variant for fields. Fields are always concrete
declarations. (A role cannot declare "I need a field named `$x`
but I don't provide it.")

### 5.2 Field Composition Rules

| left \ right          | Defined(_, o2)        | Conflicted(_, O2)      |
|-----------------------|-----------------------|------------------------|
| **Defined(_, o1)**    | *(see §5.3)*          | Conflicted(_, {o1}∪O2) |
| **Conflicted(_, O1)** | Conflicted(_,O1∪{o2}) | Conflicted(_, O1∪O2)   |

### 5.3 Defined + Defined

```
compose(Defined(n, o1), Defined(n, o2)) =
    if o1 == o2:   Defined(n, o1)          # diamond: same origin, idempotent
    else:           Conflicted(n, {o1, o2}) # different origins: conflict
```

### 5.4 Key Properties

Same as the method algebra minus the identity element (no Required
variant):

- **Idempotent for same origin**
- **Conflicted absorbs**
- **Flat conflict sets**

### 5.5 Why Fields Cannot Be Resolved

Unlike methods, where a consumer can provide its own implementation
that replaces/resolves the conflict, fields allocate storage in
the object. Two fields with the same name from different origins
would:
- Occupy different storage slots (different field indices)
- Have independent initialization logic
- Have potentially different `:param` names, defaults, and accessors

A class cannot "override" a field to unify these. The class can
declare its own field with the same name, but that creates a *third*
field, not a resolution. Therefore field conflicts are always errors.

---

## 6. Composition

### 6.1 Pointwise Composition

Composing two proto-roles operates pointwise over each map:

```
compose_proto_roles(PR1, PR2) = {
    methods: { n: compose(PR1.methods[n], PR2.methods[n])
               for each n in keys(PR1.methods) ∪ keys(PR2.methods) },
    fields:  { n: compose(PR1.fields[n], PR2.fields[n])
               for each n in keys(PR1.fields) ∪ keys(PR2.fields) }
}
```

When a method key exists in one proto-role but not the other, the
present entry passes through unchanged. Algebraically, the absent
side acts as Required (the identity element), so the composition
result is the present entry. This is a notational convenience —
no Required entry is actually created for absent keys. A proto-role
that says nothing about a name is not the same as one that requires
it; but the algebraic effect during composition is identical.

For the field map, there is no identity element. A field present
in only one proto-role enters the result directly — there is nothing
to compose with.

### 6.2 Multi-Role Composition

When a consumer composes multiple roles `R1, R2, ..., Rn`, the
composition is performed by folding:

```
result = compose_proto_roles(R1, compose_proto_roles(R2, ... compose_proto_roles(Rn-1, Rn)))
```

Because composition is associative (up to origin-set equality in
Conflicted nodes) and commutative (origin sets are unordered), the
fold order does not matter. The result is the same regardless of
the order roles are composed.

### 6.3 Diamond Composition

Diamond composition occurs when the same role is reached through
multiple paths:

```
role Base { method m { ... } field $x; }
role Left :does(Base) { ... }
role Right :does(Base) { ... }
class C :does(Left) :does(Right) { ... }
```

When composing Left and Right into C, Base's methods and fields
appear in both Left and Right. Because they share the same origin
(Base's stash), the composition is idempotent:

```
compose(Defined("m", Base), Defined("m", Base)) = Defined("m", Base)
compose(Defined("$x", Base), Defined("$x", Base)) = Defined("$x", Base)
```

No conflict. The method and field each appear once in the result.

**Note on diamond fields and storage:** Even though the algebra
says diamond fields compose idempotently, the *implementation* must
ensure that the field occupies a single storage slot, not duplicate
slots. This is an implementation concern, not an algebraic one — the
algebra says "this is the same field" and the implementation must
honor that by allocating it once.

---

## 7. Composition Pipeline

At seal time, the composition algorithm receives:

1. The **consumer's proto-role** (constructed during parsing, with
   all construction-time conflicts resolved per §3).
2. The **sealed proto-roles** of all roles from `:does` attributes.

### 7.1 Consumer Participates in Composition

The consumer's proto-role is composed alongside the role proto-roles
using the same algebra. It is not treated specially during
composition — only during resolution (§8).

```
all_proto_roles = [ConsumerPR, Role1PR, Role2PR, ...]
composed = fold(compose_proto_roles, all_proto_roles)
```

This means the consumer's fields and methods (including generated
accessors) can conflict with role content. For example, if a class
declares `field $x` and a role also declares `field $x`, the
composition produces `Conflicted($x, {Consumer, Role})` — correctly
detecting the collision.

Similarly, if a class has `field $y :reader(x)` and a role has
`method x`, the composition produces `Conflicted(x, {Consumer, Role})`.
During resolution, only the consumer's *explicit* methods can resolve
such conflicts — the generated accessor cannot.

### 7.2 Example: Consumer Proto-Role in Composition

```perl
role Identifiable {
    field $id :param :reader;    # field $id, method id
}

class User :does(Identifiable) {
    field $id :param :reader;    # field $id, method id (different origin)
    field $name :param :reader;  # field $name, method name
}
```

User's proto-role:
```
UserPR = {
    methods: { id: Defined(id, User), name: Defined(name, User) },
    fields:  { $id: Defined($id, User), $name: Defined($name, User) }
}
```

Identifiable's proto-role:
```
IdentifiablePR = {
    methods: { id: Defined(id, Identifiable) },
    fields:  { $id: Defined($id, Identifiable) }
}
```

Composition:
```
methods: {
    id:   compose(Defined(id, User), Defined(id, Identifiable))
        = Conflicted(id, {User, Identifiable})
    name: Defined(name, User)   # only in User, passes through
}
fields: {
    $id:   compose(Defined($id, User), Defined($id, Identifiable))
         = Conflicted($id, {User, Identifiable})
    $name: Defined($name, User) # only in User, passes through
}
```

Resolution: `$id` field conflict is unresolvable — always an error.
User could resolve `method id` by providing an explicit `method id`,
but the field conflict remains.

```
Role composition errors in class User:
  - Field '$id' conflicts between role Identifiable and class User
```

---

## 8. Resolution

Resolution is a separate phase that runs after composition is
complete. It examines the composed result and produces either a
validated structure or a list of all errors.

### 8.1 Consumer-Provided Methods

During resolution, only the consumer's **explicitly declared
methods** have the power to resolve conflicts and satisfy
requirements. A method generated by a field attribute (`:reader`,
`:writer`) is part of the composed content — it participates in
composition like any other method — but it is not an explicit act
of resolution by the class author.

This distinction is grounded in provenance (§3.4): the proto-role
knows which methods were explicitly declared and which were
generated. Resolution uses this information to determine what
counts as "consumer-provided."

### 8.2 Resolution Context

Resolution depends on whether the consumer is a **class** or a
**role**.

**For roles** (abstract consumers):
- A role's explicit method resolves a Conflicted or Required slot
  from composition with its sub-roles, just as a class method would.
- Any remaining Conflicted method slots propagate to the consuming
  role's interface. They carry forward the requirement for eventual
  resolution by a downstream consumer.
- Any remaining Required method slots propagate to the consuming
  role.
- Conflicted field slots are errors — even role-into-role
  composition cannot have field conflicts.

**For classes** (concrete consumers):
- A class's explicit method resolves a Conflicted or Required slot.
- An **inherited method** (from the superclass chain) also
  satisfies a Required slot. Per the original traits paper: "These
  methods can be implemented in the class itself, in a direct or
  indirect superclass, or by another trait that is used by the
  class." However, an inherited method does **not** resolve a
  Conflicted slot — only an explicitly declared class method can
  do that. (Rationale: inheriting a method is passive; resolving a
  conflict should be an explicit act by the class author.)
- All remaining Conflicted method slots are errors.
- All remaining Required method slots are errors.
- All Conflicted field slots are errors (always).

### 8.3 Resolution Rules

When the consumer provides an explicit method `m` and the composed
result has a slot for `m`:

```
resolve(Conflicted(m, origins), consumer_explicit=m) → OK
    The consumer's method is installed. The role methods are discarded.

resolve(Required(m), consumer_explicit=m) → OK
    The consumer's method satisfies the requirement.

resolve(Defined(m, role_origin), consumer_explicit=m) → OK
    The consumer's method takes precedence over the role method.
    (This is standard override, not conflict resolution.)
```

Note: because the consumer's proto-role participates in composition
(§7.1), the consumer's explicit method `m` and a role's `m` will
have already composed into `Conflicted(m, {Consumer, Role})`. The
resolution rule for Conflicted handles this case — the consumer's
explicit method resolves the conflict it created.

### 8.3.1 Inherited Method Satisfaction (Classes Only)

When a class does not provide its own method `m` but inherits one
from its superclass chain:

```
resolve(Required(m), class_inherits=m) → OK
    The inherited method satisfies the requirement.

resolve(Conflicted(m, origins), class_inherits=m) → ERROR
    An inherited method does NOT resolve a conflict.
    The class must explicitly provide its own method.

resolve(Defined(m, role_origin), class_inherits=m) → OK
    The role method takes precedence over the inherited method.
    (Flattening property: role methods behave as if defined in
    the class, so they shadow superclass methods.)
```

### 8.4 Resolution Order

The resolution phase proceeds as:

1. **Compose** all proto-roles (consumer + roles) using the method
   and field algebras.
2. **Identify** the consumer's explicit methods (by provenance).
3. **Check explicit methods** against the composed result:
   - For each Conflicted method slot: if the consumer provides an
     explicit method, the conflict is resolved.
   - For each Required method slot: if the consumer provides an
     explicit method (or, for classes, inherits one), the
     requirement is satisfied.
4. **Collect errors** from any remaining Conflicted method slots,
   Required method slots (for classes), and all Conflicted field
   slots.
5. **Report** all errors at once, or proceed with installation.

### 8.5 Error Reporting

Resolution collects **all** errors before reporting, rather than
failing on the first one. This allows developers to see the full
picture and fix all issues at once.

Error categories:

1. **Unresolved method conflicts:**
   `Method 'm' conflicts between Role1 and Role2`
   (and the consumer does not provide an explicit 'm')

2. **Unsatisfied required methods:**
   `Method 'm' is required by Role1 but not provided`
   (and neither the class/role nor any composed role provides 'm')

3. **Field conflicts:**
   `Field '$x' conflicts between Role1 and Role2`
   (always an error, no resolution possible)

Because proto-roles track provenance, error messages for conflicts
involving generated accessor methods can be enriched:

- `Method 'x' conflicts between role R and :reader for field '$x'
  (at line 5)` — explains why the method exists and what field
  produced it.

The error message should list all categories together so the
developer sees everything at once.

### 8.6 Example: Conflict Resolved by Explicit Method

```perl
role RA { method render { "RA" } }
role RB { method render { "RB" } }

class Widget :does(RA) :does(RB) {
    method render { "Widget" }
}
```

Composition (WidgetPR + RA + RB):
```
methods: {
    render: compose(Defined(render, Widget),
              compose(Defined(render, RA), Defined(render, RB)))
          = compose(Defined(render, Widget), Conflicted(render, {RA, RB}))
          = Conflicted(render, {Widget, RA, RB})
}
```

Resolution: Widget provides explicit `method render` → conflict
resolved. Widget's own `render` is installed.

### 8.7 Example: Multiple Errors Reported Together

```perl
role RA { method m1 { ... } method m2 { ... } field $x; }
role RB { method m1 { ... } method m2 { ... } field $x; }

class C :does(RA) :does(RB) {
    method m1 { ... }   # resolves m1 conflict
    # does NOT resolve m2 or $x
}
```

Resolution:
- `m1`: Conflicted({C, RA, RB}) → C provides explicit `m1` → resolved
- `m2`: Conflicted({RA, RB}) → C does NOT provide `m2` → ERROR
- `$x`: Conflicted({RA, RB}) → always error → ERROR

```
Role composition errors in class C:
  - Method 'm2' conflicts between RA and RB
  - Field '$x' conflicts between RA and RB
```

---

## 9. ADJUST Block Composition

ADJUST blocks are **not modeled as slots** in the algebra. They are
anonymous code blocks that execute during object construction and
do not participate in conflict detection or resolution.

Their composition rule is:

1. Collect ADJUST blocks from all composed role proto-roles.
2. Apply diamond deduplication: if the same ADJUST block (by origin
   CV identity) would appear multiple times, include it only once.
3. Collect the consumer's own ADJUST blocks.

Execution order among ADJUST blocks is not specified by the algebra.
By the time ADJUST blocks run, all composition conflicts have
already been detected and resolved, so the order of execution
cannot affect the correctness of the composition. Execution order
is an implementation detail.

ADJUST blocks that reference fields must have their field indices
adjusted to account for the consumer's field layout (this is an
implementation detail handled by the field offset mechanism).

---

## 10. Interaction with Inheritance

When a class has both a superclass (`:isa`) and roles (`:does`),
the composition order is:

1. **Superclass fields** occupy indices `[0, super_field_count)`.
2. **Role fields** are composed and occupy indices starting at
   `super_field_count`.
3. **Class's own fields** occupy indices after all role fields.

For methods, three precedence levels apply (following the original
traits paper):

1. **Class explicit methods take precedence over role methods.**
   A class's explicitly declared method overrides any role Defined
   slot and resolves any Conflicted or Required slot.
2. **Role methods take precedence over superclass methods.**
   This follows from the flattening property: role methods behave
   as if defined in the class itself, so they shadow inherited
   methods.
3. **Inherited methods satisfy requirements but do not resolve
   conflicts.** A method inherited from the superclass satisfies
   a Required slot (the requirement is met). However, an inherited
   method does **not** resolve a Conflicted slot — the class must
   explicitly provide its own method to do that.

---

## 11. `->does` and `->DOES` Semantics

Role composition introduces two runtime query methods with
deliberately different semantics: one nominal (reflects programmer
intent) and one structural (verifies contract fulfillment).

### 11.1 `:does` — Compile-Time Declaration

The `:does(RoleName)` attribute on a class or role is a compile-time
declaration of intent: "I compose this role." It is the input to
the composition algorithm.

### 11.2 `->does('RoleName')` — Nominal Check

`$obj->does('RoleName')` (and `ClassName->does('RoleName')`)
returns true if and only if the class declared `:does(RoleName)`,
directly or transitively through another composed role.

This is a **nominal** check. It echoes what the programmer wrote.
It does not verify that the role's contract is actually fulfilled
at runtime — because the class may have overridden role methods,
a subclass may have overridden them further, or future features
like `:aliases`/`:excludes` may have altered the composition.

`->does` answers: *"Did the programmer declare this relationship?"*

### 11.2.1 `does` as Infix Operator

Perl 5.36+ provides `isa` as an infix operator:
```perl
if ($obj isa ClassName) { ... }
```

We add `does` as an infix operator with the same pattern:
```perl
if ($obj does RoleName) { ... }
```

This is syntactic sugar for `$obj->does('RoleName')` — it is the
nominal check. It follows the same precedence and semantics as
infix `isa`, but checks role composition rather than class
inheritance.

Like `isa`, the right-hand side is a bareword (package name), not
a string. This makes it a natural companion:

```perl
if ($obj isa Widget)      { ... }  # class check
if ($obj does Drawable)   { ... }  # role check (nominal)
```

### 11.3 `->DOES('RoleName')` — Structural Contract Check

`$obj->DOES('RoleName')` returns true if and only if the object
actually fulfills the role's complete interface contract right now.

This is a **strict structural check**. It inspects the role's
proto-role and verifies each slot against the object's actual method
dispatch table:

**For each Defined(name, origin) method in the role's proto-role:**
The method that `$obj->name` would dispatch to must have the
same origin stash as the role's method. That is, the role's
original implementation is still the one that would be called —
it has not been overridden by the class, a subclass, or any
other mechanism.

**For each Required(name) method in the role's proto-role:**
`$obj->can(name)` must return true. Some implementation must
exist. (Since the role never provided an implementation, any
concrete method satisfies this — the role only cares that the
method is available, not who wrote it.)

`->DOES` answers: *"Does this object actually fulfill the
contract?"*

When proto-roles are retained after sealing (§2.4), `->DOES` can
walk the retained proto-role directly rather than reconstructing
the role's interface. This provides a natural, precomputed data
structure for the structural check.

### 11.4 When They Disagree

`->does` and `->DOES` can legitimately return different values:

```perl
role Drawable {
    method draw { ... }       # Defined(draw, Drawable)
    method visible;           # Required(visible)
}

class Widget :does(Drawable) {
    method visible { 1 }      # satisfies requirement
}
# Widget->new->does('Drawable')  → true  (declared)
# Widget->new->DOES('Drawable')  → true  (contract fulfilled:
#   draw is Drawable's CV, visible is provided)

class FancyWidget :isa(Widget) {
    method draw { ... }       # overrides Drawable's draw
}
# FancyWidget->new->does('Drawable')  → true  (inherited declaration)
# FancyWidget->new->DOES('Drawable')  → false (draw's origin is
#   now FancyWidget, not Drawable — contract broken)
```

The subclass broke the contract *at a distance*. `->does` still
returns true because Widget declared `:does(Drawable)` and
FancyWidget inherits that declaration. `->DOES` returns false
because the structural check fails — `draw` no longer dispatches
to Drawable's implementation.

Similarly, a class method override breaks the contract:

```perl
class Button :does(Drawable) {
    method visible { 1 }
    method draw { ... }       # overrides Drawable's draw
}
# Button->new->does('Drawable')  → true   (declared)
# Button->new->DOES('Drawable')  → false  (draw overridden)
```

This is intentional. `:does` is a statement of intent; `->does`
echoes it. `->DOES` is a verification tool — it tells you whether
the intent is actually being honored at runtime.

### 11.5 Transitivity

Both `->does` and `->DOES` are transitive, but in different ways:

**`->does` follows the composition graph.**
If `role A :does(B)` and `class C :does(A)`, then
`C->new->does('B')` is true because B was transitively composed
through A.

**`->DOES` checks each role's contract independently.**
`C->new->DOES('B')` verifies B's interface against the object
directly — it does not matter that B was composed through A. If
B defines `method m` and that method has been overridden somewhere
in the chain, `->DOES('B')` returns false regardless of how B
was originally composed in.

This independence is the key property: `->DOES` is a pure
structural check. It doesn't care about composition history. It
looks at the role's proto-role, looks at the object's dispatch
table, and checks whether they match.

### 11.6 Relationship to `UNIVERSAL::DOES`

Perl's existing `UNIVERSAL::DOES` (from Perl 5.10) is a nominal
check — it defaults to the same behavior as `isa`. Our `->DOES`
on role-aware classes overrides this with the strict structural
semantics described above.

For classes that do not use `feature 'class'`, `->DOES` retains
its existing `UNIVERSAL::DOES` behavior (backwards compatible).

---

## 12. `:aliases` and `:excludes` — Pre-Composition Transforms

### 12.1 Motivation

The original traits paper acknowledges that aliasing and exclusion
break the role contract. In practice, large-scale Perl codebases
have shown that these are sometimes necessary — when doing it "the
right way" (fixing the roles themselves) is either impossible
(third-party code) or needs to be deferred until later.

These operations are **not part of the composition algebra**. The
algebra (§4–§5) remains clean and total — it knows nothing about
aliases or exclusions. Instead, `:aliases` and `:excludes` are
**pre-composition transforms** that create a modified copy of a
role's sealed proto-role before it enters the composition pipeline.
The original proto-role is untouched (the role may be composed
elsewhere without modification).

### 12.2 Syntax

`:aliases` and `:excludes` are class-level attributes, separate
from `:does`, and only valid when `:does` is present:

```perl
class Foo :does(Bar, Baz)
          :aliases(Bar::baz => bar_baz)
          :excludes(Baz::gorch)
{
    ...
}
```

Both attributes are qualified with the role name (`Bar::baz`, not
just `baz`) to make explicit which role is being modified. This
avoids ambiguity when multiple roles provide methods with the same
name.

Multiple aliases or exclusions can be specified:

```perl
class Foo :does(Bar, Baz)
          :aliases(Bar::baz => bar_baz, Bar::quux => bar_quux)
          :excludes(Baz::gorch, Baz::wibble)
{
    ...
}
```

### 12.3 Semantics

`:aliases` and `:excludes` are applied **after** the role's sealed
proto-role is loaded but **before** it enters composition. They
operate on a *copy* of the role's proto-role — the original is
never mutated.

**`:excludes(Role::method)`**
Removes `method` from the copied proto-role's method map and
replaces it with `Required(method)`. The method is no longer
provided by the role, but the obligation remains — the class (or
another role) must provide it. This is exactly how the original
traits paper defines exclusion: "suppresses these methods and turns
them into requirements."

```
Before: Role = { method: Defined(method, Role), ... }
After:  Role = { method: Required(method), ... }
```

**`:aliases(Role::method => new_name)`**
Adds a copy of `method` under `new_name` in the copied proto-role's
method map. The original method is **not removed** — aliasing
creates an additional entry, not a rename. (This matches the
original traits paper: "aliasing just establishes an alternative
name without affecting the original one.") If the intent is to
alias and then exclude the original, both must be specified:

```perl
class Foo :does(Bar, Baz)
          :aliases(Bar::baz => bar_baz)
          :excludes(Bar::baz)
{
    ...
}
```

The alias has the same origin as the original method (it is the
same CV), so diamond deduplication still works correctly.

```
Before: Role = { baz: Defined(baz, Bar), ... }
After:  Role = { baz: Required(baz), bar_baz: Defined(bar_baz, Bar), ... }
```

### 12.4 Effect on `->does` and `->DOES`

`:aliases` and `:excludes` break the role contract. This is
reflected in the `->does` / `->DOES` distinction:

```perl
role Bar {
    method baz { "Bar::baz" }
    method quux { "Bar::quux" }
}

class Foo :does(Bar) :excludes(Bar::baz) {
    method baz { "Foo::baz" }   # must provide, since excluded → Required
}

Foo->new->does('Bar');   # true  — Foo declared :does(Bar)
Foo->new->DOES('Bar');   # false — baz's origin is Foo, not Bar
```

`->does` is nominal and always reflects the declaration. `->DOES`
is structural and detects that the contract was broken by the
exclusion (and subsequent re-implementation with a different
origin).

### 12.5 Restriction to Classes

`:aliases` and `:excludes` are only available on **classes**, not
on roles. A role that composes sub-roles should resolve conflicts
by providing its own methods (the clean algebraic way), not by
aliasing or excluding. This keeps the role composition graph clean
and limits contract-breaking to the point of final consumption.

If a role author finds themselves wanting `:excludes`, that is a
signal that the sub-roles should be refactored. The escape hatch
is reserved for the class author, who is assembling concrete
behavior from potentially uncoordinated third-party roles.

### 12.6 Design Rationale

**Why separate attributes, not inline syntax?**

Moose puts aliases and exclusions inside the `with` statement:
```perl
with 'Role' => { -alias => { foo => 'role_foo' }, -excludes => ['foo'] };
```

This spec uses separate `:aliases` and `:excludes` attributes for
several reasons:

1. **Visibility.** Separate attributes make it immediately obvious
   that something unusual is happening. They stand out visually as
   modifications to the normal `:does` contract.

2. **Removability.** When the underlying conflict is fixed in the
   codebase (roles are refactored, methods renamed, etc.), the
   `:aliases`/`:excludes` attributes can be deleted independently
   without modifying the `:does` attribute. This encourages
   treating them as temporary workarounds.

3. **Clarity of intent.** `:does(Bar, Baz)` states what you want
   to compose. `:excludes(Baz::gorch)` states what you're working
   around. Mixing these into a single attribute conflates intent
   with workaround.

4. **Not a feature to use liberally.** The separate syntax and the
   required role-qualification (`Bar::baz`, not just `baz`) add
   deliberate friction. This is an escape hatch, not a composition
   tool.

---

## 13. Algebraic Properties Summary

### Method Algebra

| Property         | Holds? | Notes |
|------------------|--------|-------|
| Totality         | Yes    | Composition never fails |
| Associativity    | Yes    | Conflict sets are flat (union), so grouping doesn't matter |
| Commutativity    | Yes    | Origin sets are unordered |
| Identity element | Yes    | Required is the identity |
| Idempotency      | Yes    | Same origin = same slot |

### Field Algebra

| Property         | Holds? | Notes |
|------------------|--------|-------|
| Totality         | Yes    | Composition never fails |
| Associativity    | Yes    | Conflict sets are flat (union) |
| Commutativity    | Yes    | Origin sets are unordered |
| Identity element | No     | No Required variant for fields |
| Idempotency      | Yes    | Same origin = same slot |

---

## 14. Differences from Current Implementation

The current implementation (`S_class_compose_roles` in `class.c`)
differs from this specification in several ways:

1. **Immediate croak on conflict.** The current code calls `croak`
   as soon as a method or field conflict is detected. The spec
   requires collecting all errors and reporting them together.

2. **No class-provided resolution for method conflicts.** The
   current code does not check whether the class provides a method
   that would resolve a conflict. It croaks unconditionally. The
   spec requires checking consumer-provided explicit methods before
   declaring a conflict unresolved.

3. **Installation-order override.** Currently, class methods are
   installed in the stash first, and role composition skips methods
   that already exist. The spec models this explicitly: the
   consumer's proto-role participates in composition, and its
   explicit methods resolve conflicts during the resolution phase.

4. **Diamond field duplication.** The current implementation may
   allocate duplicate storage slots for diamond-composed fields
   (each composition path allocates its own indices). The spec
   requires that diamond fields (same origin) occupy a single slot.

5. **Accessor methods bypass composition.** Currently, `:reader`
   and `:writer` generate methods at parse time and install them
   directly into the stash. This means accessor methods from
   different fields can silently overwrite each other, and they
   do not participate in role composition conflict detection. The
   spec requires that accessor methods are held in the proto-role
   and composed at seal time alongside role methods.

6. **No role-provided conflict resolution.** The current code does
   not allow a composite role to resolve conflicts from its
   sub-roles by providing its own method. The spec requires
   symmetric resolution: both classes and roles can resolve
   conflicts via explicit methods.

7. **No proto-role intermediate representation.** The current code
   does not build a unified intermediate representation during
   parsing. Fields and methods are processed independently.
   The spec introduces proto-roles as the universal substrate
   through which all fields and methods flow.

---

## 15. Relationship to Moose Role Composition

This specification is a direct descendant of Moose's role
composition model, which itself follows the original traits paper
(Schärli et al., 2003). The core semantics are intentionally
faithful to what Moose established. This section documents what is
the same, what differs, and what is new.

### 15.1 Shared Semantics

The following behaviors are identical to Moose:

- **Origin-based identity.** Two methods conflict if they have the
  same name but originate from different packages. Two methods from
  the same origin (diamond case) compose idempotently.

- **Class methods take precedence over role methods.** A class that
  provides its own method with the same name as a role method wins.
  The role method is not installed.

- **Class methods resolve conflicts.** When two roles provide
  conflicting methods, the class can resolve the conflict by
  providing its own implementation.

- **Roles can resolve sub-role conflicts.** A composite role that
  provides its own method resolves conflicts among its composed
  sub-roles, just as a class would.

- **Required methods propagate through roles.** A required method
  that is not satisfied during role-into-role composition becomes
  a requirement of the composite role.

- **Concrete methods satisfy requirements.** A concrete method from
  one role satisfies a required method from another role during
  composition.

- **Inherited methods satisfy requirements.** A method inherited
  from the superclass chain satisfies a Required slot. (Moose uses
  `->can()` for this check.)

- **Inherited methods do NOT resolve conflicts.** A method inherited
  from the superclass does not resolve a method conflict between
  roles. The class must explicitly provide its own method.

- **Conflicting methods become required.** When two roles conflict
  on a method, the consumer must provide an implementation. In
  Moose this is implicit (croak unless resolved); in this spec the
  Conflicted state carries an explicit requirement.

- **Required methods in classes are errors.** If a class fails to
  satisfy a required method (from a role or from an unresolved
  conflict), it is a compile-time error.

### 15.2 Differences from Moose

These are behavioral differences, not just implementation details:

1. **`requires` syntax.** Moose uses an explicit `requires 'foo'`
   declaration. Perl 5 core uses a bodyless method stub:
   `method foo;`. The semantics are identical — both declare an
   obligation without providing an implementation. The stub form
   is more natural in core Perl since it mirrors forward
   declarations.

2. **`:aliases`/`:excludes` are separate attributes, not inline.**
   Moose puts aliases and exclusions inside the `with` statement.
   This spec provides `:aliases` and `:excludes` as separate
   class-level attributes (§12), deliberately separated from
   `:does` to make them visible as workarounds rather than normal
   composition tools. They are also restricted to classes only —
   roles cannot use them.

### 15.3 Improvements over Moose

These are areas where this specification improves upon Moose's
behavior:

**1. All errors reported at once.**

Moose croaks on the first composition error (conflict or
unsatisfied requirement), forcing the developer to fix one problem,
recompile, discover the next, fix it, recompile, and so on.

This spec collects all composition errors — method conflicts,
unsatisfied requirements, and field conflicts — and reports them
together in a single diagnostic. This is especially valuable when
composing many roles, where multiple independent problems may exist
simultaneously.

```
# Moose: you see this first...
#   'foo' conflicts between Role::A and Role::B
# ...fix it, recompile, then discover...
#   'bar' requires method 'baz'

# This spec: you see everything at once
#   Role composition errors in class Widget:
#     - Method 'foo' conflicts between Role::A and Role::B
#     - Method 'baz' is required by Role::Bar but not provided
#     - Field '$id' conflicts between Role::A and Role::C
```

**2. Field (attribute) conflict detection.**

Moose has no conflict detection for attributes. When two roles
provide an attribute with the same name, one silently wins
(last-applied). This can cause subtle bugs where a role's
attribute (with its default, type constraint, and builder) is
quietly replaced by another role's version.

```perl
# Moose: no error, Logger's $level silently replaces Prioritized's
package Prioritized { use Moose::Role; has 'level' => (is => 'ro', default => 1); }
package Logger     { use Moose::Role; has 'level' => (is => 'ro', default => 'info'); }
package MyApp      { use Moose; with 'Prioritized', 'Logger'; }
```

This spec treats fields as first-class participants in the
composition algebra. Field conflicts (same name, different origin)
are always errors, because fields allocate object storage and
cannot be meaningfully "overridden."

**3. Accessor method conflict detection via proto-roles.**

In Moose, attribute accessors are installed into the stash as
regular methods. This means they participate in method conflict
detection between roles — but only incidentally. The connection
between an accessor method and its originating attribute is lost
in error messages, and conflicts between accessors within the
same class are not detected at all.

This spec holds each field and its generated accessor methods
within the proto-role structure (§2–§3). This provides:

- **Same-class accessor conflicts caught.** Two fields in the same
  class that generate methods with the same name (e.g.,
  `field $x :reader` and `field @x :reader`) are detected during
  proto-role construction (§3.2) rather than silently overwriting.

- **Rich error messages.** Because the proto-role tracks provenance
  — which field declaration generated each method — error messages
  can explain *why* a method exists:
  `Method 'x' conflicts between :reader for field '$x' and
  :reader for field '@x'`
  rather than just naming two packages.

- **Unified composition pipeline.** Class fields, role fields, and
  their accessor methods all flow through proto-roles. There is
  no special case for "class-local accessors" vs "role-composed
  methods" — they are all entries in proto-roles and compose by
  the same rules.

**4. Explicit algebraic model.**

Moose's role composition is implemented procedurally: walk the
roles, check for conflicts, croak or install. The logic is spread
across `Moose::Meta::Role::Application::*` classes and interleaved
with Moose's meta-object protocol.

This spec defines composition as a pure, total algebraic operation
(§4–§5) separate from resolution (§8). This separation makes the
semantics easier to reason about, test, and verify. The algebra
can be tested independently of the resolution policy, and the
resolution policy can be tested against known-good composed
structures.

**5. Proto-role as universal intermediate representation.**

Moose has no unified intermediate representation. Roles are
`Moose::Meta::Role` objects, classes are `Moose::Meta::Class`
objects, and the composition logic treats them differently.
Attribute accessors are generated and installed separately from
role composition.

This spec introduces proto-roles as the universal substrate:
classes and roles share the same representation during construction,
composition, and resolution. This unification eliminates special
cases and ensures all methods and fields — whether explicitly
declared, generated by attributes, or composed from roles — are
subject to the same conflict detection rules.

---

## 16. Implementation Concerns

This section catalogs potential performance and memory concerns
that should be addressed during implementation. These are not
blocking issues for the specification — they are recorded here so
they are not forgotten when the spec moves to implementation.

### 16.1 High Severity

**Diamond field deduplication and index assignment (§6.3).** The
spec requires that diamond-composed fields occupy a single storage
slot. The current implementation allocates duplicate slots (known
limitation). Fixing this requires either detecting diamonds before
field index assignment, or retroactively reassigning indices —
which cascades into optree adjustments for every reference to
those fields.

### 16.2 Medium Severity

**Accessor CVs held from parse to seal time (§3.1).** Currently,
accessor methods are generated and installed into the stash
immediately at parse time. The spec holds them in the proto-role
structure until seal time. This extends CV lifetime and requires
cleanup on both success and failure paths. The proto-role provides
a natural container for these CVs, but their lifecycle must be
carefully managed.

**Full composed result materialized before resolution (§7–8).**
The current implementation composes incrementally (install or
croak). The spec requires materializing the entire composed result
as a temporary data structure before anything is installed. For
the common case (1–3 roles, no conflicts) this structure is small,
but it must still be allocated and freed.

**CV cloning timing relative to diamond detection.** If the
implementation clones a CV before discovering it is a diamond
duplicate, the clone is wasted. The composition algebra handles
diamonds at the abstract level, but the implementation must be
careful to defer expensive operations (cv_clone, optree walks)
until after composition determines which items actually need
installation.

**ADJUST block and method optree adjustment (§9, §10).** Composed
role methods and ADJUST blocks that reference fields need field
index adjustments. The current implementation uses runtime magic
offsets (per-field-access cost). The alternative — compile-time
optree walks — trades runtime cost for seal-time cost. Either
way there is a cost, and with diamond composition the dedup check
must happen before or after the adjustment work.

**`->DOES` runtime method dispatch check (§11.3).** Each `->DOES`
call walks the role's proto-role and performs a method resolution
per entry to check origin identity. This is O(methods × MRO depth)
at runtime. If proto-roles are retained after sealing, this
provides a precomputed structure to walk, but the per-method
dispatch check is still needed. If `->DOES` is used in tight
loops for type-checking, this could be a hot path.

### 16.3 Low Severity

**Proto-role structure overhead.** Each class and role allocates
a proto-role structure during parsing. This is a pair of maps plus
metadata — modest overhead per class/role. For classes with many
fields, the proto-role's field map and method map grow accordingly,
but these are bounded by the number of declarations (not the number
of objects instantiated).

**Error collection data structures (§8.5).** Cold path only
(errors are rare), but requires a growable structure that is
either speculatively allocated or lazily initialized.

**Origin sets in Conflicted slots (§4, §5).** Small dynamically-
sized collections per conflicted slot, requiring heap allocation
and linear scans for dedup during set union. In practice N is
very small.

**`:aliases`/`:excludes` requiring proto-role copy (§12).** These
transforms cannot mutate the original role's proto-role (the role
may be composed elsewhere). Requires materializing a mutable copy
of the role's proto-role for this consumer. Rare escape hatch,
cold path.

**Intermediate fold results during multi-role composition (§6.2).**
Folding N roles produces N−1 intermediate composed structures.
Each must be freed promptly after the next fold step completes.

**MRO walking for inherited method satisfaction (§8.3.1).**
Checking `can()` for each unsatisfied Required slot walks the MRO.
Bounded by the typically small number of required methods and
shallow hierarchies.

---

## 17. Worked Examples

### Example 1: Simple Composition, No Conflicts

```perl
role Printable {
    method to_string;   # Required
}

role Serializable {
    method serialize { ... }  # Defined, origin=Serializable
}

class Document :does(Printable) :does(Serializable) {
    method to_string { ... }  # explicit method
}
```

**Proto-role construction:**
```
PrintablePR   = { methods: { to_string: Required },
                  fields: {} }
SerializablePR = { methods: { serialize: Defined(serialize, Serializable) },
                   fields: {} }
DocumentPR    = { methods: { to_string: Defined(to_string, Document) },
                  fields: {} }
```

**Composition (DocumentPR + PrintablePR + SerializablePR):**
```
methods: {
    to_string: compose(Defined(to_string, Document), Required(to_string))
             = Defined(to_string, Document)
    serialize: Defined(serialize, Serializable)
}
fields: {}
```

**Resolution (class = Document):**
- `to_string`: Defined with Document's origin. No conflict, no
  requirement. Document's explicit method is used.
- `serialize`: Defined with Serializable's origin. Installed from
  Serializable.
- Result: OK

### Example 2: Diamond — No Conflict

```perl
role Base { method id { ... } field $name; }
role Left :does(Base) { method left_thing { ... } }
role Right :does(Base) { method right_thing { ... } }

class C :does(Left) :does(Right) { }
```

After Left and Right each compose Base, their sealed proto-roles
carry Base's content:

```
LeftPR  = { methods: { id: Defined(id, Base), left_thing: Defined(left_thing, Left) },
            fields:  { $name: Defined($name, Base) } }
RightPR = { methods: { id: Defined(id, Base), right_thing: Defined(right_thing, Right) },
            fields:  { $name: Defined($name, Base) } }
CPR     = { methods: {}, fields: {} }
```

**Composition (CPR + LeftPR + RightPR):**
```
methods: {
    id:          compose(Defined(id, Base), Defined(id, Base)) = Defined(id, Base)
    left_thing:  Defined(left_thing, Left)
    right_thing: Defined(right_thing, Right)
}
fields: {
    $name: compose(Defined($name, Base), Defined($name, Base)) = Defined($name, Base)
}
```

No conflicts. Diamond resolved by origin identity.

### Example 3: Role Resolves Sub-Role Conflict

```perl
role Drawable { method render { "draw" } }
role Printable { method render { "print" } }

role Displayable :does(Drawable) :does(Printable) {
    method render { "display" }  # explicit, resolves the conflict
}

class Widget :does(Displayable) { }
```

**Composition of DrawablePR + PrintablePR + DisplayablePR
(during Displayable's seal):**
```
methods: {
    render: compose(Defined(render, Displayable),
              compose(Defined(render, Drawable), Defined(render, Printable)))
          = compose(Defined(render, Displayable), Conflicted(render, {Drawable, Printable}))
          = Conflicted(render, {Displayable, Drawable, Printable})
}
```

**Resolution (consumer = Displayable, a role):**
Displayable provides explicit `method render` → conflict resolved.
Displayable's sealed proto-role carries: `render` as
Defined(render, Displayable).

**Composition of WidgetPR + DisplayablePR (during Widget's seal):**
```
methods: { render: Defined(render, Displayable) }
```

Widget receives `render` as Defined — no conflict, no requirement.

### Example 4: Same-Class Accessor Conflict (Construction-Time)

```perl
class Foo {
    field $x :reader = 10;
    field @x :reader = (1, 2, 3);
}
```

**Proto-role construction:**
1. `field $x :reader` → adds `$x` to field map, adds generated
   `method x` (provenance: `:reader` for `$x`) to method map.
2. `field @x :reader` → adds `@x` to field map (different name,
   no collision). Tries to add generated `method x` — collision
   with existing generated `method x` from step 1. Construction-
   time conflict recorded.

No explicit `method x` follows → error at seal time:
```
Method 'x' conflicts between :reader for field '$x' (line 2)
and :reader for field '@x' (line 3)
```

### Example 5: Same-Class Accessor Conflict Resolved

```perl
class Foo {
    field $x :reader = 10;
    field @x :reader = (1, 2, 3);
    method x { ... }   # explicit, resolves (with redefine warning)
}
```

**Proto-role construction:**
Same as Example 4, but `method x` is encountered after the
collision. The explicit method takes precedence — the construction-
time conflict is resolved. Warning issued under
`use warnings 'redefine'`.

FooPR exits construction cleanly:
```
FooPR = {
    methods: { x: Defined(x, Foo) },    # explicit, provenance: explicit
    fields:  { $x: Defined($x, Foo), @x: Defined(@x, Foo) }
}
```

### Example 6: Role Accessor vs. Class Accessor Conflict

```perl
role Identifiable {
    field $id :param :reader;   # field $id, generated method id
}

class User :does(Identifiable) {
    field $id :param :reader;   # field $id, generated method id
    field $name :param :reader;
}
```

**Composition (UserPR + IdentifiablePR):**
```
fields: {
    $id:   Conflicted($id, {User, Identifiable})   # different origins
    $name: Defined($name, User)
}
methods: {
    id:   Conflicted(id, {User, Identifiable})      # different origins
    name: Defined(name, User)
}
```

**Resolution (class = User):**
- `$id` field conflict → unresolvable, ERROR.
- `id` method conflict → User has no *explicit* `method id`
  (the `id` in UserPR was generated by `:reader`, not explicit)
  → ERROR.
- Even if User provided an explicit `method id` to resolve the
  method conflict, the field conflict remains.

```
Role composition errors in class User:
  - Field '$id' conflicts between role Identifiable and class User
```

### Example 7: Role Composes Role — Deferred Resolution

```perl
role Eq {
    method equal_to;  # Required
}

role Comparable :does(Eq) {
    method compare;          # Required
    method equal_to { ... }  # explicit, satisfies Eq's requirement
    method less_than { ... } # explicit
}
```

**Composition of ComparablePR + EqPR (during Comparable's seal):**
```
methods: {
    equal_to: compose(Defined(equal_to, Comparable), Required(equal_to))
            = Defined(equal_to, Comparable)
    compare:  Required(compare)
    less_than: Defined(less_than, Comparable)
}
```

**Resolution (consumer = Comparable, a role):**
- `equal_to`: Defined → OK
- `compare`: Required → propagates (Comparable is a role)
- `less_than`: Defined → OK

Comparable's sealed proto-role carries: `equal_to` (Defined),
`compare` (Required), `less_than` (Defined). Any class composing
Comparable must provide `compare`.

### Example 8: Inherited Method Satisfies Requirement

```perl
role Renderable {
    method render;   # Required
}

class Base {
    method render { "base" }
}

class Widget :isa(Base) :does(Renderable) { }
```

**Composition (WidgetPR + RenderablePR):**
```
methods: { render: Required(render) }
```

**Resolution (class = Widget):**
- `render`: Required → Widget does not provide an explicit method,
  but inherits `render` from Base → satisfied.
- Result: OK

### Example 9: Inherited Method Does NOT Resolve Conflict

```perl
role RA { method render { "RA" } }
role RB { method render { "RB" } }

class Base {
    method render { "base" }
}

class Widget :isa(Base) :does(RA) :does(RB) { }
```

**Composition (WidgetPR + RA + RB):**
```
methods: { render: Conflicted(render, {RA, RB}) }
```

**Resolution (class = Widget):**
- `render`: Conflicted({RA, RB}) → Widget does not provide an
  explicit method. Widget inherits `render` from Base, but
  inherited methods do NOT resolve conflicts → ERROR.

```
Role composition errors in class Widget:
  - Method 'render' conflicts between RA and RB
```

Widget must add an explicit `method render { ... }` to resolve.
