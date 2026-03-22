# Perl 5 Role Composition Algebra

## 1. Overview

This document specifies the algebra governing role composition in
Perl 5's `feature 'class'`. Role composition is the process by which
a role's methods and fields are incorporated into a consuming class
or role.

The algebra has two sub-algebras — one for **methods** and one for
**fields** — that share a common structure but differ in their
conflict resolution policies. Both algebras use **origin-based
identity**: two items are considered "the same" if and only if they
originate from the same stash (package). Content equality is not
considered.

**Design principles:**

1. **Composition is total.** Composing roles never fails. Conflicts
   and unsatisfied requirements are recorded as data, not raised as
   exceptions.
2. **Resolution is separate.** After composition, a resolution phase
   inspects the result and either validates it or reports all errors
   at once.
3. **Origin identity.** Two methods (or fields) with the same name
   are "the same" if they originate from the same stash. This handles
   diamond composition naturally.
4. **Class-provided methods resolve conflicts.** A class that provides
   its own method with a conflicting name resolves the conflict. This
   does not apply to fields.

---

## 2. Method Algebra

### 2.1 Method Slot Variants

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
- Records that two or more roles provided different implementations
  of `name`.
- `origins` is the set of distinct origin stashes that contributed
  conflicting implementations.
- A Conflicted slot also implies a requirement: the consumer must
  resolve the conflict by providing its own implementation.

### 2.2 Method Composition Rules

Composition operates on two method slots with the same name. We
write `compose(left, right)` for the result.

| left \ right         | Required        | Defined(_, o2)       | Conflicted(_, O2)     |
|----------------------|-----------------|----------------------|-----------------------|
| **Required**         | Required        | Defined(_, o2)       | Conflicted(_, O2)     |
| **Defined(_, o1)**   | Defined(_, o1)  | *(see §2.3)*         | Conflicted(_, {o1}∪O2)|
| **Conflicted(_, O1)**| Conflicted(_,O1)| Conflicted(_,O1∪{o2})| Conflicted(_,O1∪O2)  |

Where:
- `o1`, `o2` are origin stashes
- `O1`, `O2` are sets of origin stashes

### 2.3 Defined + Defined

```
compose(Defined(n, o1), Defined(n, o2)) =
    if o1 == o2:   Defined(n, o1)          # diamond: same origin, idempotent
    else:           Conflicted(n, {o1, o2}) # different origins: conflict
```

### 2.4 Key Properties

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
Unlike the SLOTS algebra which builds binary trees of Conflicted
nodes, this algebra flattens conflicts into a set of origins. This
is sufficient because Perl 5 role composition uses symmetric
resolution — the order of composition does not affect conflict
detection, and all origins in a conflict are equally "wrong."

### 2.5 A Conflicted Method is also Required

A Conflicted method slot carries an implicit requirement: the
consumer must provide its own method to resolve the conflict. This
follows the p5-MOP model where conflicting methods become required.

During resolution (§4), a Conflicted slot is treated as both an
error (the conflict) and an obligation (the requirement), and a
class-provided method satisfies both.

---

## 3. Field Algebra

### 3.1 Field Slot Variants

A **field slot** for a given name exists in one of two states:

**Defined(name, origin)**
- A concrete field declaration for `name`.
- `origin` is the stash where the field was originally declared.
- Fields carry additional metadata (sigil, default, `:param` name,
  `:reader`/`:writer` attributes) but these do not affect
  composition identity — only `name` and `origin` matter.

**Conflicted(name, origins)**
- Records that two or more roles declared fields with the same
  `name` from different origins.
- Field conflicts are **unresolvable** — a class cannot "override"
  a field the way it can override a method. The only resolution is
  to fix the role hierarchy.

### 3.2 Field Composition Rules

| left \ right          | Defined(_, o2)        | Conflicted(_, O2)      |
|-----------------------|-----------------------|------------------------|
| **Defined(_, o1)**    | *(see §3.3)*          | Conflicted(_, {o1}∪O2) |
| **Conflicted(_, O1)** | Conflicted(_,O1∪{o2}) | Conflicted(_, O1∪O2)   |

There is no Required variant for fields. Fields are always concrete
declarations. (A role cannot declare "I need a field named `$x`
but I don't provide it.")

### 3.3 Defined + Defined

```
compose(Defined(n, o1), Defined(n, o2)) =
    if o1 == o2:   Defined(n, o1)          # diamond: same origin, idempotent
    else:           Conflicted(n, {o1, o2}) # different origins: conflict
```

### 3.4 Key Properties

Same as the method algebra minus the identity element (no Required
variant):

- **Idempotent for same origin**
- **Conflicted absorbs**
- **Flat conflict sets**

### 3.5 Why Fields Cannot Be Resolved

Unlike methods, where a class can provide its own implementation
that replaces/resolves the conflict, fields allocate storage in
the object. Two fields with the same name from different roles would:
- Occupy different storage slots (different field indices)
- Have independent initialization logic
- Have potentially different `:param` names, defaults, and accessors

A class cannot "override" a field to unify these. The class can
declare its own field with the same name, but that creates a *third*
field, not a resolution. Therefore field conflicts are always errors.

---

## 4. Resolution

Resolution is a separate phase that runs after all role composition
is complete. It examines the composed result and produces either a
validated structure or a list of all errors.

### 4.1 Resolution Context

Resolution depends on whether the consumer is a **class** or a
**role**. In both cases, **locally defined methods take precedence
over composed role methods** and can resolve conflicts. This rule
is symmetric — it applies equally to classes and composite roles.
(This follows from the flattening property of the original traits
model: a method's semantics is independent of whether it is defined
in the consumer or in a composed role.)

**For roles** (abstract consumers):
- A role-provided method resolves a Conflicted or Required slot
  from its composed sub-roles, just as a class method would.
- Any remaining Conflicted method slots propagate to the consuming
  role's interface. They carry forward the requirement for eventual
  resolution by a downstream consumer.
- Any remaining Required method slots propagate to the consuming
  role.
- Conflicted field slots are errors (always — even role-into-role
  composition cannot have field conflicts).

**For classes** (concrete consumers):
- A class-provided method resolves a Conflicted or Required slot.
- An **inherited method** (from the superclass chain) also
  satisfies a Required slot. Per the original traits paper: "These
  methods can be implemented in the class itself, in a direct or
  indirect superclass, or by another trait that is used by the
  class." However, an inherited method does **not** resolve a
  Conflicted slot — only a locally defined class method can do
  that. (Rationale: inheriting a method is passive; resolving a
  conflict should be an explicit act by the class author.)
- All remaining Conflicted method slots are errors.
- All remaining Required method slots are errors.
- All Conflicted field slots are errors (always).

### 4.2 Consumer-Provided Method Resolution

When a consumer (class or role) provides its own method `m` and
the composed role set has a slot for `m`:

```
resolve(Conflicted(m, origins), consumer_provides=m) → OK
    The consumer's method is installed. The role methods are discarded.

resolve(Required(m), consumer_provides=m) → OK
    The consumer's method satisfies the requirement.

resolve(Defined(m, role_origin), consumer_provides=m) → OK
    The consumer's method takes precedence over the role method.
    (This is standard override, not conflict resolution.)
```

### 4.2.1 Inherited Method Satisfaction (Classes Only)

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

### 4.3 Error Reporting

Resolution collects **all** errors before reporting, rather than
failing on the first one. This allows developers to see the full
picture and fix all issues at once.

Error categories:

1. **Unresolved method conflicts:**
   `Method 'm' conflicts between Role1 and Role2`
   (and the class does not provide its own 'm')

2. **Unsatisfied required methods:**
   `Method 'm' is required by Role1 but not provided`
   (and neither the class nor any other composed role provides 'm')

3. **Field conflicts:**
   `Field '$x' conflicts between Role1 and Role2`
   (always an error, no resolution possible)

The error message should list all three categories together so the
developer sees everything at once.

### 4.4 Resolution Order

The resolution phase proceeds as:

1. **Compose** all roles using the method and field algebras.
2. **Check class-provided methods** against the composed result:
   - For each Conflicted method slot: if the class provides the
     method, the conflict is resolved.
   - For each Required method slot: if the class provides the
     method (or inherits one), the requirement is satisfied.
3. **Collect errors** from any remaining Conflicted method slots,
   Required method slots, and all Conflicted field slots.
4. **Report** all errors at once, or proceed with installation.

---

## 5. Role Composition (Pointwise)

A **role** is a pair of finite maps:

```
Role = {
    methods: { name₁: method_slot₁, name₂: method_slot₂, ... },
    fields:  { name₁: field_slot₁,  name₂: field_slot₂,  ... }
}
```

Composing two roles operates pointwise over each map independently:

```
compose_roles(R1, R2) = {
    methods: { n: compose(R1.methods[n], R2.methods[n])
               for each n in keys(R1.methods) ∪ keys(R2.methods) },
    fields:  { n: compose(R1.fields[n], R2.fields[n])
               for each n in keys(R1.fields) ∪ keys(R2.fields) }
}
```

For the method map, missing keys are implicitly `Required(n)` (the
identity element), so a method present in only one role passes
through unchanged.

For the field map, there is no identity element, so a field present
in only one role also passes through unchanged (there is nothing to
compose with — it simply enters the result).

### 5.1 Multi-Role Composition

When a class or role composes multiple roles `R1, R2, ..., Rn`,
the composition is performed by folding:

```
result = compose_roles(R1, compose_roles(R2, ... compose_roles(Rn-1, Rn)))
```

Because composition is associative (up to origin-set equality in
Conflicted nodes) and commutative (origin sets are unordered), the
fold order does not matter. The result is the same regardless of
the order roles are composed.

### 5.2 Diamond Composition

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

## 6. Pseudo-Roles and Field Attribute Methods

### 6.1 The Problem

Field attributes like `:reader` and `:writer` generate methods. When
two fields in the same class generate methods with the same name,
the current implementation silently overwrites one with the other:

```perl
class Foo {
    field $x :reader = 10;
    field @x :reader = qw[ uh oh ];
}
say Foo->new->x;   # prints "uhoh" — $x's reader was silently lost
```

This is a class-level problem, not just a role problem. But we can
solve it using the role composition algebra by treating each field
(together with its generated methods) as a **pseudo-role**.

### 6.2 Pseudo-Roles

A **pseudo-role** is a C-level structure that has the same shape as
a role (a pair of method and field maps) but is not backed by a
real stash. Pseudo-roles are created internally during parsing and
exist only to participate in the composition algorithm at seal time.

Each field declaration that has method-generating attributes
(`:reader`, `:writer`) produces a pseudo-role containing:

1. The field itself.
2. All methods that the attributes would generate.

Each pseudo-role has a unique origin identity (derived from the
field declaration site), so that methods from different pseudo-roles
are distinguishable by the composition algebra.

### 6.3 Expansion Rules

```perl
field $bar :reader;
```
becomes pseudo-role:
```
PR(field_$bar) = {
    fields:  { $bar: Defined($bar, PR(field_$bar)) },
    methods: { bar:  Defined(bar,  PR(field_$bar)) }
}
```

```perl
field $baz :reader :writer;
```
becomes pseudo-role:
```
PR(field_$baz) = {
    fields:  { $baz:    Defined($baz,    PR(field_$baz)) },
    methods: { baz:     Defined(baz,     PR(field_$baz)),
               set_baz: Defined(set_baz, PR(field_$baz)) }
}
```

Fields **without** method-generating attributes also become
pseudo-roles, but with an empty method map:

```perl
field $count = 0;
```
becomes:
```
PR(field_$count) = {
    fields:  { $count: Defined($count, PR(field_$count)) },
    methods: { }
}
```

This ensures that field-field conflicts (same name, same sigil,
different declarations — which can occur through role composition)
are caught uniformly.

### 6.4 Composition at Seal Time

At seal time, the composition algorithm receives:

1. **Pseudo-roles** from the class's own field declarations.
2. **Real roles** from `:does` attributes.

All of these are composed together using the same algebra:

```
all_roles = [PR(field_1), PR(field_2), ..., Role1, Role2, ...]
composed = fold(compose_roles, all_roles)
```

The class's own explicitly written methods (not generated by
attributes) are the **consumer-provided methods** that can resolve
conflicts during the resolution phase.

### 6.5 Conflict Detection Examples

**Same-class reader conflict:**
```perl
class Foo {
    field $x :reader;   # PR1: fields={$x}, methods={x}
    field @x :reader;   # PR2: fields={@x}, methods={x}
}
```
Composition: `$x` and `@x` are different field names (different
sigils), so no field conflict. But both pseudo-roles provide
`method x` with different origins → **Conflicted(x, {PR1, PR2})**.

Error: `Method 'x' conflicts between :reader for field '$x' and
:reader for field '@x'`

**Reader/writer name collision:**
```perl
class Foo {
    field $get_bar :reader;    # PR1: methods={get_bar}
    field $bar :writer;        # PR2: methods={set_bar} — no conflict!
    field $bar2 :writer(get_bar);  # PR3: methods={get_bar} — conflict with PR1!
}
```

**Class method resolves generated-method conflict:**
```perl
class Foo {
    field $x :reader;   # PR1: methods={x}
    field @x :reader;   # PR2: methods={x}
    method x { ... }    # class-provided, resolves the conflict
}
```
The class's explicit `method x` resolves the Conflicted slot, just
as it would resolve a conflict between two roles.

**Role field vs class field conflict:**
```perl
role R { field $x :reader; }   # methods={x}, fields={$x}
class C :does(R) {
    field $x :reader;          # PR: methods={x}, fields={$x}
}
```
Both `$x` fields have different origins (R vs PR) →
**Conflicted($x, {R, PR})**. Both `method x` have different origins
→ **Conflicted(x, {R, PR})**. The field conflict is unresolvable.
The class could resolve the method conflict by providing its own
`method x`, but the field conflict remains an error.

### 6.6 Error Messages

Because each pseudo-role knows which field declaration produced it,
error messages can trace conflicts back to their source:

- `Method 'x' conflicts between :reader for field '$x' (at line 3)
  and :reader for field '@x' (at line 4)`
- `Method 'x' conflicts between role R and :reader for field '$x'
  (at line 5)`
- `Field '$x' conflicts between role R and class C`

This is richer than "Method 'x' conflicts between R1 and R2"
because it explains *why* the method exists and what field it is
attached to.

### 6.7 Implementation Notes

Pseudo-roles are a compile-time concept. They are C-level structs
(not real stashes) that carry:
- A field map (PADNAMELIST segment or equivalent)
- A method map (name → CV pairs)
- Origin identity (for conflict detection)
- Source location (for error messages)
- The originating field declaration (for rich diagnostics)

The accessor method CVs are still generated at parse time (they
need to be compiled), but they are **not installed into the stash**
at parse time. Instead, they are held in the pseudo-role structure
and installed only after composition succeeds at seal time.

---

## 7. ADJUST Block Composition


ADJUST blocks are **not modeled as slots** in the algebra. They are
anonymous code blocks that execute during object construction and
do not participate in conflict detection or resolution.

Their composition rule is:

1. Collect ADJUST blocks from all composed roles.
2. Apply diamond deduplication: if the same ADJUST block (by origin
   CV identity) would appear multiple times, include it only once.
3. Collect the class's own ADJUST blocks.

Execution order among ADJUST blocks is not specified by the algebra.
By the time ADJUST blocks run, all composition conflicts have
already been detected and resolved, so the order of execution
cannot affect the correctness of the composition. Execution order
is an implementation detail.

ADJUST blocks that reference fields must have their field indices
adjusted to account for the consumer's field layout (this is an
implementation detail handled by the field offset mechanism).

---

## 8. Interaction with Inheritance

When a class has both a superclass (`:isa`) and roles (`:does`),
the composition order is:

1. **Superclass fields** occupy indices `[0, super_field_count)`.
2. **Role fields** are composed and occupy indices starting at
   `super_field_count`.
3. **Class's own fields** occupy indices after all role fields.

For methods, three precedence levels apply (following the original
traits paper):

1. **Class methods take precedence over role methods.**
   A class-provided method overrides any role Defined slot and
   resolves any Conflicted or Required slot.
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

## 9. Algebraic Properties Summary

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

## 10. Differences from Current Implementation

The current implementation (`S_class_compose_roles` in `class.c`)
differs from this specification in several ways:

1. **Immediate croak on conflict.** The current code calls `croak`
   as soon as a method or field conflict is detected. The spec
   requires collecting all errors and reporting them together.

2. **No class-provided resolution for method conflicts.** The
   current code does not check whether the class provides a method
   that would resolve a conflict. It croaks unconditionally. The
   spec requires checking class-provided methods before declaring
   a conflict unresolved.

3. **Installation-order override.** Currently, class methods are
   installed in the stash first, and role composition skips methods
   that already exist. The spec models this as explicit resolution:
   the class method resolves the role's Defined/Conflicted/Required
   slot.

4. **Diamond field duplication.** The current implementation may
   allocate duplicate storage slots for diamond-composed fields
   (each composition path allocates its own indices). The spec
   requires that diamond fields (same origin) occupy a single slot.

5. **Accessor methods bypass composition.** Currently, `:reader`
   and `:writer` generate methods at parse time and install them
   directly into the stash. This means accessor methods from
   different fields can silently overwrite each other, and they
   do not participate in role composition conflict detection. The
   spec requires that accessor methods are held in pseudo-roles
   and composed at seal time alongside real roles.

6. **No role-provided conflict resolution.** The current code does
   not allow a composite role to resolve conflicts from its
   sub-roles by providing its own method. The spec requires
   symmetric resolution: both classes and roles can resolve
   conflicts.

---

## 11. Worked Examples

### Example 1: Simple Composition, No Conflicts

```perl
role Printable {
    method to_string;   # Required
}

role Serializable {
    method serialize { ... }  # Defined, origin=Serializable
}

class Document :does(Printable) :does(Serializable) {
    method to_string { ... }  # class-provided
}
```

**Composition:**
```
methods: {
    to_string:  compose(Required, absent) = Required
    serialize:  compose(absent, Defined(serialize, Serializable)) = Defined(serialize, Serializable)
}
fields: {}
```

**Resolution (class = Document):**
- `to_string`: Required → Document provides `to_string` → satisfied
- `serialize`: Defined → installed from Serializable
- Result: OK

### Example 2: Conflict Resolved by Class

```perl
role RA { method render { "RA" } }
role RB { method render { "RB" } }

class Widget :does(RA) :does(RB) {
    method render { "Widget" }
}
```

**Composition:**
```
methods: {
    render: compose(Defined(render, RA), Defined(render, RB))
          = Conflicted(render, {RA, RB})
}
```

**Resolution (class = Widget):**
- `render`: Conflicted({RA, RB}) → Widget provides `render` → resolved
- Result: OK, Widget's own `render` is used

### Example 3: Unresolved Conflict — Error

```perl
role RA { method render { "RA" } }
role RB { method render { "RB" } }

class Widget :does(RA) :does(RB) {
    # does NOT provide render
}
```

**Resolution:**
- `render`: Conflicted({RA, RB}) → Widget does not provide `render`
- Error: "Method 'render' conflicts between RA and RB"

### Example 4: Diamond — No Conflict

```perl
role Base { method id { ... } field $name; }
role Left :does(Base) { method left_thing { ... } }
role Right :does(Base) { method right_thing { ... } }

class C :does(Left) :does(Right) { }
```

After Left and Right each compose Base, they both carry:
- `Defined(id, Base)` and `Defined($name, Base)`

**Composition of Left + Right:**
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

### Example 5: Multiple Errors Reported Together

```perl
role RA { method m1 { ... } method m2 { ... } field $x; }
role RB { method m1 { ... } method m2 { ... } field $x; }

class C :does(RA) :does(RB) {
    method m1 { ... }  # resolves m1 conflict
    # does NOT resolve m2 or $x
}
```

**Composition:**
```
methods: {
    m1: Conflicted(m1, {RA, RB})
    m2: Conflicted(m2, {RA, RB})
}
fields: {
    $x: Conflicted($x, {RA, RB})
}
```

**Resolution:**
- `m1`: Conflicted → C provides `m1` → resolved
- `m2`: Conflicted → C does NOT provide `m2` → ERROR
- `$x`: Conflicted → always error → ERROR

**Error message reports both:**
```
Role composition errors in class C:
  - Method 'm2' conflicts between RA and RB
  - Field '$x' conflicts between RA and RB
```

### Example 6: Role Composes Role — Deferred Resolution

```perl
role Eq {
    method equal_to;  # Required
}

role Comparable :does(Eq) {
    method compare;          # Required
    method equal_to { ... }  # Defined, satisfies Eq's requirement
    method less_than { ... } # Defined
}
```

**Composition of Eq into Comparable:**
```
methods: {
    equal_to: compose(Required(equal_to), Defined(equal_to, Comparable))
            = Defined(equal_to, Comparable)
    compare:  Required(compare)    # Comparable's own requirement
    less_than: Defined(less_than, Comparable)
}
```

**Resolution (consumer = Comparable, which is a role):**
- `equal_to`: Defined → OK, installed
- `compare`: Required → propagates (Comparable is a role, not a class)
- `less_than`: Defined → OK, installed

Comparable now carries: `equal_to` (Defined), `compare` (Required),
`less_than` (Defined). Any class composing Comparable must provide
`compare`.

### Example 7: Pseudo-Roles — Field Accessor Conflict

```perl
class Foo {
    field $x :reader = 10;
    field @x :reader = (1, 2, 3);
}
```

**Pseudo-role expansion:**
```
PR1 = { fields: { $x: Defined($x, PR1) }, methods: { x: Defined(x, PR1) } }
PR2 = { fields: { @x: Defined(@x, PR2) }, methods: { x: Defined(x, PR2) } }
```

**Composition:**
```
fields:  { $x: Defined($x, PR1), @x: Defined(@x, PR2) }  # disjoint, no conflict
methods: { x: Conflicted(x, {PR1, PR2}) }                 # conflict!
```

**Resolution (class = Foo):**
Foo does not provide its own `method x` → ERROR.

```
Role composition errors in class Foo:
  - Method 'x' conflicts between :reader for field '$x' (line 2)
    and :reader for field '@x' (line 3)
```

### Example 8: Pseudo-Roles — Role + Class Field Interaction

```perl
role Identifiable {
    field $id :param :reader;
}

class User :does(Identifiable) {
    field $id :param :reader;   # different origin from role's $id
    field $name :param :reader;
}
```

**Pseudo-role expansion for User's fields:**
```
PR1 = { fields: { $id: Defined($id, PR1) },   methods: { id: Defined(id, PR1) } }
PR2 = { fields: { $name: Defined($name, PR2) }, methods: { name: Defined(name, PR2) } }
```

**Composition of [Identifiable, PR1, PR2]:**
```
fields: {
    $id: compose(Defined($id, Identifiable), Defined($id, PR1))
       = Conflicted($id, {Identifiable, PR1})     # different origins!
    $name: Defined($name, PR2)
}
methods: {
    id: compose(Defined(id, Identifiable), Defined(id, PR1))
      = Conflicted(id, {Identifiable, PR1})        # different origins!
    name: Defined(name, PR2)
}
```

**Resolution:** `$id` field conflict is unresolvable. User could
resolve `method id` by providing an explicit method, but the field
conflict remains.

```
Role composition errors in class User:
  - Field '$id' conflicts between role Identifiable and class User
```

### Example 9: Role Resolves Sub-Role Conflict

```perl
role Drawable { method render { "draw" } }
role Printable { method render { "print" } }

role Displayable :does(Drawable) :does(Printable) {
    method render { "display" }  # resolves the conflict
}

class Widget :does(Displayable) { }
```

**Composition of Drawable + Printable into Displayable:**
```
methods: { render: Conflicted(render, {Drawable, Printable}) }
```

**Resolution (consumer = Displayable, which is a role):**
Displayable provides its own `method render` → conflict resolved.

Displayable now carries: `render` as Defined(render, Displayable).

**Composition of Displayable into Widget:**
Widget receives `render` as Defined — no conflict, no requirement.
Widget does not need to provide its own `render`.
