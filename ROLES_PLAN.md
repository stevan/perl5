# Plan: Adding Roles to `feature 'class'`

This plan builds on the field index rework (`slittle/class-field-index-rework` branch), which
introduced deferred field index resolution at seal time. Much of the
implementation can be ported from the `slittle/roles` branch POC, but
the field composition logic must be rewritten to use the new index
resolution mechanism instead of the cv_clone + magic-offset approach.

The plan is divided into steps that can each be implemented and tested
independently.

## Step 1: `role` Keyword and `HvAUXf_IS_ROLE` Flag

**Reuse from `slittle/roles`**: all of it.

Files:
- `regen/keywords.pl` -- add `-role` keyword, `role => 'class'` in
  `%feature_kw`
- `toke.c` -- add `case KEY_role:` handler
- `perly.y` -- add `KW_ROLE` token, grammar rules for role declaration
  and definition (mirrors class grammar, no constructor)
- `hv.h` -- add `HvAUXf_IS_ROLE` (0x8), `HvSTASH_IS_ROLE()`,
  `HvSTASH_IS_CLASS_OR_ROLE()` macros; add `xhv_class_pending_roles` AV
  to `xpvhv_aux`
- `embed.fnc` / `proto.h` / `embed.h` -- declare `role_setup_stash`,
  `role_seal_stash`
- Generated files (`keywords.h`, `keywords.c`, `perly.h`, `perly.act`,
  `perly.tab`) -- regenerated from the above

`role_setup_stash` is identical to `class_setup_stash` except:
- No constructor is injected
- Sets `HvAUXf_IS_ROLE` instead of `HvAUXf_IS_CLASS`
- Registers `invoke_role_seal` as the destructor

Several existing `HvSTASH_IS_CLASS` checks in `class.c` need to become
`HvSTASH_IS_CLASS_OR_ROLE` so that `field`, `method`, and `ADJUST` work
inside roles. This is a straightforward search-and-replace for the
relevant assertion sites:
- `croak_kw_unless_class`
- `class_prepare_initfield_parse`
- `class_prepare_method_parse`
- `class_wrap_method_body`
- `class_add_field`
- Field and method attribute handlers

The `:isa` handler should reject roles (`HvSTASH_IS_ROLE`) with a
compile-time error.

**Test**: Verify that `role Foo { field $x; method m { ... } }` parses,
that roles cannot use `:isa`, and that roles are not directly
instantiable (no `new`).

## Step 2: `role_seal_stash` with Deferred Field Resolution

**Partially reuse from `slittle/roles`**, rewritten for the new approach.

A role is sealed just like a class, but:
- It has no superclass, so the base offset is always 0.
- Its `xhv_class_next_fieldix` after sealing reflects the count of its
  own fields (this value becomes the "cost" of composing the role).
- Its initfields CV is compiled normally (existing `class_seal_stash`
  logic works).

Implementation: `role_seal_stash` can call the same three-phase logic
that `class_seal_stash` now uses. Either extract the shared phases into
a common helper, or have `role_seal_stash` call `class_seal_stash`
directly after adjusting the flag check. The simplest approach is to
make `class_seal_stash` accept both classes and roles (check
`HvSTASH_IS_CLASS_OR_ROLE`), with the superclass chaining step
conditional on `HvSTASH_IS_CLASS`.

At this point roles don't compose anything yet -- they're just sealed
packages with fields and methods, ready to be composed into classes.

**Test**: Verify that a role seals without error and that its
`xhv_class_initfields_cv`, `xhv_class_fields`, and
`xhv_class_next_fieldix` are populated correctly (introspectable via
B or a small XS test helper).

## Step 3: `:does` Attribute and Role Collection

**Reuse from `slittle/roles`**: almost all of it.

- Add `apply_class_attribute_does` to the attribute dispatch table. It
  validates the role stash, loads the module if needed, and appends the
  stash to `aux->xhv_class_pending_roles`. No composition happens at
  parse time.
- Both classes and roles can use `:does` (role-composes-role for
  transitive composition).

**Test**: Verify that `:does(RoleName)` is accepted on classes and
roles, that it croaks if the target is not a role, and that pending
roles are accumulated correctly.

## Step 4: Role Composition -- Methods and Required Methods

**Reuse from `slittle/roles`**: the method composition and required
method logic from `S_class_compose_roles` can be ported nearly verbatim.
The field-related parts are deferred to Step 5.

Write `S_class_compose_roles(stash)`, called from `class_seal_stash`
(and `role_seal_stash`) before Phase 1 (field resolution). For the
method portion:

1. Collect unique direct roles (`S_collect_unique_roles`) with diamond
   deduplication by stash pointer identity.

2. For each role, walk its stash for `CvIsMETHOD` CVs:
   - **Bodyless stub** (`!CvROOT`): this is a required method. Track it
     in a `required_methods` HV. If the consumer (or a previously
     composed role) already provides a real method with that name, the
     requirement is satisfied. For role consumers, install the stub into
     the consumer stash for transitive propagation.
   - **Real method**: check for conflicts (same name, different origin
     stash). Diamond case (same origin) is idempotent. Install into the
     consumer stash. At this stage, **do not clone or offset** -- just
     install the CV. Field binding for composed methods is handled
     separately in Step 5.
   - A real method from one role satisfies a requirement from another.

3. After all roles: if the consumer is a class (not a role) and
   `required_methods` is non-empty, croak.

4. Compose ADJUST blocks: for each role's `xhv_class_adjust_blocks`,
   append the CVs to the consumer's adjust list. (Field binding for
   these is handled in Step 5.)

5. Add each role to the consumer's `@ISA`.

**Test**: method composition, conflict detection, diamond deduplication,
required methods (satisfied and unsatisfied), transitive requirements,
ADJUST block composition. The `t/class/role_compose.t`,
`t/class/role_does.t`, and `t/class/role_requires.t` from the POC
branch contain tests for all of these -- the method-only subset can be
used here.

## Step 5: Role Composition -- Fields

This is the part that must be written from scratch using the new
deferred index resolution. It runs inside `S_class_compose_roles`,
interleaved with the method composition from Step 4.

### Index allocation

For each role being composed, compute its field block:

```
role_base_offset = aux->xhv_class_next_fieldix  (starts after inherited fields)
```

The role contributes `roleaux->xhv_class_next_fieldix` fields (its own
total, including any transitively composed role fields). Advance the
consumer's counter:

```
aux->xhv_class_next_fieldix += roleaux->xhv_class_next_fieldix
```

After all roles are composed, the consumer's own fields (which already
have `relative_fieldix` values) will be resolved in Phase 1 with a
`base_offset` that accounts for both inherited and role fields.

### Composing role fields into the class

For each role field (from `roleaux->xhv_class_fields`):

1. Check for field name conflicts against previously composed fields
   (same as the POC).

2. Compute the field's absolute index:
   `absolute_fieldix = role_base_offset + role_field->relative_fieldix`

3. Create a **new** `padname_fieldinfo` struct with:
   - `fieldix = absolute_fieldix` (already resolved)
   - `relative_fieldix` copied from the role field
   - `fieldstash` pointing to the role's stash (original defining class)
   - `defop = NULL` (the role's initfields CV handles initialization)
   - `paramname` copied from the role field

4. Create a new PADNAME wrapping this fieldinfo and add it to the
   consumer's `xhv_class_fields`. This makes the composed field visible
   for introspection but does not generate new `OP_INITFIELD` ops (the
   role's initfields CV handles initialization).

5. If the field has a `:param` name, add it to the consumer's
   `xhv_class_param_map`.

### Composing role initfields CVs

The role's `xhv_class_initfields_cv` handles initializing the role's
fields. It uses `OP_INITFIELD` ops with `fieldix` values that are
absolute *within the role* (resolved when the role was sealed, with
base_offset 0). When composed into a class, these need to be offset by
`role_base_offset`.

Approach: clone the role's initfields CV (`cv_clone`), then walk the
clone's optree and fix up every `OP_INITFIELD` aux `fieldix` and every
`OP_METHSTART` aux entry by adding `role_base_offset`. This is a
compile-time operation on the clone's optree -- no runtime overhead,
no magic.

Write a helper `S_fixup_cv_field_offsets(cv, offset)` that:
- Walks the optree for `OP_INITFIELD` nodes, adds `offset` to
  `aux[0].uv`
- Finds `OP_METHSTART`, if it has aux, adds `offset` to each fieldix
  entry

Chain the cloned (and fixed-up) initfields CV into the consumer's
initfields optree, before the consumer's own field initialization.
This is done in `class_seal_stash` Phase 3, between the superclass
`OP_ENTERSUB` call and the consumer's own `OP_INITFIELD` ops.

### Composing role methods and ADJUST blocks (field binding)

Role methods and ADJUST blocks that reference fields need their field
bindings adjusted. Two options:

**Option A -- Clone and fixup (like initfields).** Clone each role
method/ADJUST CV that references fields. Walk the clone's pad: for each
field PADNAME, create a new fieldinfo with `fieldix` offset by
`role_base_offset`. Then the seal-time Phase 2 method fixup builds
correct aux for the clone. This requires cloning only methods that
reference fields; methods without fields can be shared directly.

**Option B -- Pad fieldinfo replacement.** Install role methods directly
(no clone). Before Phase 2 runs, walk each installed role method's pad
and replace its field PADNAMEs' fieldinfo pointers with new structs that
have the offset fieldix. This mutates the method's pad but not the
role's original PADNAMEs (the pad entries are `newPADNAMEouter` copies
with their own fieldinfo refcount).

Wait -- the fieldinfo is *shared* via refcount between the role's field
PADNAME and the method pad's PADNAME (see `newPADNAMEouter` in `pad.c`
line 2888). So we cannot mutate the fieldinfo in place without affecting
the role's original fields (which would break multi-consumer). We must
either clone the CV (getting fresh pad entries) or allocate new fieldinfo
structs and point the pad entries at them.

**Recommendation: Option A.** Clone role method/ADJUST CVs that
reference fields. `cv_clone` creates new pad entries that initially
share fieldinfo pointers with the originals. Then walk the clone's pad
and replace each field PADNAME's fieldinfo with a new struct whose
`fieldix` is the role's absolute fieldix + `role_base_offset`. Methods
that don't reference fields can be installed without cloning.

The Phase 2 stash walk in `class_seal_stash` will then pick up these
cloned methods (they're installed in the stash) and build correct aux
arrays from their pad's now-correct fieldinfo values.

### Phase 1 adjustment

After role composition, the consumer's own fields still need resolution.
Phase 1 currently computes `base_offset` from the superclass only. With
roles, the base offset for the class's own fields must account for role
fields too. Since `S_class_compose_roles` advances
`aux->xhv_class_next_fieldix` past the role fields, Phase 1 can simply
use `aux->xhv_class_next_fieldix` as the base offset for the class's
own fields:

```c
/* Phase 1: resolve own field indices */
PADOFFSET base_offset = 0;
if(aux->xhv_class_superclass) {
    struct xpvhv_aux *superaux = HvAUX(aux->xhv_class_superclass);
    base_offset = superaux->xhv_class_next_fieldix;
}
/* Role fields were already added to next_fieldix by compose_roles */
base_offset = aux->xhv_class_next_fieldix;  /* includes inherited + role fields */
```

Wait -- this conflates two things. Let me be precise. After
`S_class_compose_roles` returns, `aux->xhv_class_next_fieldix` already
includes inherited fields (from the superclass's sealed value, set in
compose_roles) plus role fields. The class's own fields should start
after that. So Phase 1 becomes:

```c
PADOFFSET base_offset = aux->xhv_class_next_fieldix;
/* This already accounts for superclass + role fields, set by compose_roles.
 * If no roles, it was left at 0 by class_setup_stash and compose_roles
 * was a no-op, so we still need the superclass check: */
if(!aux->xhv_class_pending_roles && aux->xhv_class_superclass) {
    struct xpvhv_aux *superaux = HvAUX(aux->xhv_class_superclass);
    base_offset = superaux->xhv_class_next_fieldix;
}
```

Actually, the cleanest approach: have `S_class_compose_roles` always set
`aux->xhv_class_next_fieldix` to the correct starting offset for the
class's own fields (superclass fields + role fields). Then Phase 1
simply reads it:

```c
PADOFFSET base_offset = aux->xhv_class_next_fieldix;
```

For this to work, `S_class_compose_roles` must:
1. Start with `base = superclass ? superaux->xhv_class_next_fieldix : 0`
2. Add each role's field count
3. Set `aux->xhv_class_next_fieldix = base`

And when no roles are composed (`S_class_compose_roles` is a no-op),
Phase 1 falls back to computing the superclass offset itself (as it does
now). So we just need to initialize `xhv_class_next_fieldix` from the
superclass at the *start* of seal, before compose_roles runs:

```c
/* At start of class_seal_stash, before compose_roles: */
if(aux->xhv_class_superclass) {
    struct xpvhv_aux *superaux = HvAUX(aux->xhv_class_superclass);
    aux->xhv_class_next_fieldix = superaux->xhv_class_next_fieldix;
}
/* S_class_compose_roles advances next_fieldix past role fields */
/* Phase 1 uses next_fieldix as base_offset for own fields */
```

This means `xhv_class_next_fieldix` is repurposed at seal time: during
parsing it counts own fields; at the start of sealing it is set to the
superclass total; compose_roles advances it past role fields; Phase 1
uses it as the base for own fields and then sets it to the final total.

**Test**: the full test suites from the POC branch
(`t/class/role_compose.t` etc.), adapted as needed. Multi-consumer
tests (same role composed into multiple classes with different field
layouts) are the critical correctness check.

## Step 6: `DOES` Semantics

The POC placed roles in `@ISA`, which makes both `DOES` and `isa`
return true for roles. This is correct for `DOES` but arguably wrong
for `isa` (roles are not classes). Fixing this properly requires:

- A separate roles list on `xpvhv_aux` (or walking `@ISA` and checking
  `HvSTASH_IS_ROLE`)
- Overriding `DOES` at the class level, or making `sv_does_sv` in
  `universal.c` role-aware
- Making `pp_methstart`'s type check work without `@ISA` (it currently
  uses `sv_derived_from_hv`)

This can be deferred to a later step. The POC behavior (roles in `@ISA`)
is functional and acceptable as a starting point.

## Step 7: `pad.c` cv_clone Fix

**Reuse from `slittle/roles`**: the fix in `S_cv_clone_pad` that
initializes field pad slots with `newSV_type(SVt_NULL)` instead of
leaving them NULL. This is needed because `save_padsv` (called by
`pp_methstart`) crashes on NULL pad slots in cloned CVs.

This is a one-line fix that should be applied early (Step 1 or 2) since
it affects any use of `cv_clone` on method CVs.

## Implementation Order

```
Step 1: role keyword + HvAUXf_IS_ROLE          ✅ DONE
Step 7: pad.c cv_clone fix                      ✅ DONE
Step 2: role_seal_stash                         ✅ DONE
Step 3: :does attribute                         ✅ DONE
Step 4: method + required method composition    ✅ DONE
Step 5: field composition                       ✅ DONE
Step 6: DOES semantics                          ✅ DONE
```

## Implementation Notes (from slittle/roles-v2 branch)

### Steps 1-3: Keyword, Sealing, :does

All ported from POC and adapted to the new three-phase seal. Key
differences from POC:

- `role_seal_stash` uses the same three-phase approach as
  `class_seal_stash` (resolve field indices, build OP_METHSTART aux,
  generate initfields CV) rather than duplicating the old single-phase
  logic.
- `croak_kw_unless_class` and all relevant assertions changed to
  `HvSTASH_IS_CLASS_OR_ROLE`.
- `:does` attribute validates target is `HvSTASH_IS_ROLE` (tighter
  than POC which accepted classes too).
- `hv.c` and `sv.c` updated for role stash cleanup and thread cloning.

### Step 4: Method + Required Method Composition

`S_class_compose_roles(stash)` implements:
- Diamond deduplication via `S_collect_unique_roles` (stash pointer
  identity).
- Method composition with conflict detection (same name, different
  CvSTASH = croak; same origin = diamond skip).
- Required method tracking (bodyless `CvIsMETHOD` stubs). Stubs
  installed into role consumers for transitive propagation. Unsatisfied
  requirements croak for classes only.
- ADJUST block composition.
- Roles added to consumer `@ISA` for DOES/isa support.

### Step 5: Field Composition

Uses the POC's runtime magic offset approach (`role_field_offset_vtbl`)
rather than the compile-time optree fixup described in the original
plan. The compile-time approach doesn't work because `cv_clone` shares
the optree (via `OpREFCNT`), so `OP_INITFIELD` and `OP_METHSTART` aux
arrays cannot be mutated per-clone.

**Runtime offset mechanism:**
- `cv_clone_with_field_offset(proto, offset)` clones a CV and attaches
  the offset as `PERL_MAGIC_ext` with `role_field_offset_vtbl`.
- `pp_initfield` checks running CV for magic, adds offset to fieldix.
- `pp_methstart` checks running CV for magic, adds offset to all
  field bindings.

**Field composition in `S_class_compose_roles`:**
- `fieldix_offset = aux->xhv_class_next_fieldix` per role.
- Conflict detection with diamond dedup (same fieldstash = skip).
- `:param` fields added to consumer's `xhv_class_param_map`.
- Initfields CVs cloned with offset magic, returned for chaining.
- Methods and ADJUST blocks cloned with offset magic when they
  reference fields (checked via `OP_METHSTART` aux `fieldcount > 0`).

**Phase 1 adjustment:**
- `class_seal_stash` initializes `xhv_class_next_fieldix` from
  superclass before `compose_roles`. After composition,
  `xhv_class_next_fieldix` = superclass + role fields. Phase 1 uses
  this as `base_offset` for the class's own fields.

**Phase 3 chaining:**
- Role initfields CVs chained via `OP_ENTERSUB` after superclass
  initfields, before the class's own `OP_INITFIELD` ops.

### Known Limitation: Diamond Fields

Diamond composition with fields creates duplicate field slots (one per
composition path). This is inherent to the ENTERSUB + magic offset
approach — the shared role's initfields CV gets called from both paths.
For `:param` fields in the diamond, the param is extracted/deleted by
the first path and unavailable to the second. Non-diamond cases and
diamond cases without `:param` fields work correctly.

### Step 6: DOES Semantics

Roles are no longer added to `@ISA`. Instead, composed role stashes
are stored in a new `xhv_class_roles` AV on `xpvhv_aux`. This
separates `DOES` from `isa` — `DOES` returns true for composed roles,
while `isa` does not.

**Implementation:**
- `hv.h`: Added `AV *xhv_class_roles` field to `xpvhv_aux`.
- `class.c` — `S_class_compose_roles`: Replaced `@ISA` insertion with
  `xhv_class_roles` storage. Transitive roles (from role-composes-role)
  are also recorded with deduplication.
- `class.c` — `S_class_does_role(stash, rolestash)`: New helper that
  walks `xhv_class_roles` and the superclass chain to check if a
  class/role composes a given role.
- `class.c` — `pp_methstart`: Type check extended to handle role
  methods — when `CvSTASH(curcv)` is a role, uses `class_does_role`
  instead of `sv_derived_from_hv`.
- `universal.c` — `sv_does_sv`: Added role-aware check before the
  generic `UNIVERSAL::DOES` method dispatch. Walks the class hierarchy's
  `xhv_class_roles` to match by stash pointer identity.
- `hv.c`, `sv.c`: Cleanup and thread cloning for `xhv_class_roles`.

**Also fixed:** `apply_class_attribute_does` no longer calls
`load_module` when the stash exists but is not a role — it only loads
when the stash is missing entirely.

## Files Changed

| File               | Steps   | Nature of change                              |
|--------------------|---------|-----------------------------------------------|
| `regen/keywords.pl`| 1       | add `role` keyword                            |
| `toke.c`           | 1       | `KEY_role` handler                            |
| `perly.y`          | 1       | role grammar rules                            |
| `hv.h`             | 1,3,6   | `HvAUXf_IS_ROLE`, `xhv_class_pending_roles`, `xhv_class_roles` |
| `embed.fnc`        | 1       | declare role functions                        |
| `class.c`          | 1-6     | bulk of the implementation                    |
| `pad.c`            | 7       | cv_clone field pad slot fix                   |
| `hv.c`             | 1, 6    | cleanup for new aux fields                    |
| `sv.c`             | 1, 6    | thread cloning for new aux fields             |
| `universal.c`      | 6       | role-aware DOES                               |
| generated files    | 1       | regen from keywords/grammar                   |
| `t/class/role.t`   | 1-2     | basic role keyword tests                      |
| `t/class/role_does.t` | 3    | :does attribute tests                         |
| `t/class/role_does_semantics.t` | 6 | DOES/isa semantics tests                |
