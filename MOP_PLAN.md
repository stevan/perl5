# Meta-Object Protocol for `feature 'class'`

## 1. Design Philosophy

The MOP for Perl 5's core class system follows a different philosophy than
Moose/Class::MOP. The core class system already formalizes methods and fields
as first-class concepts — there is no need for extreme runtime manipulation
to make them work. Instead, the MOP provides:

1. **Read-only introspection** on any sealed class or role.
2. **Programmatic construction** of new classes and roles at runtime.
3. **No mutation after seal** — the same invariant as the parser path.

Classes and roles are immutable once sealed. There is no unseal/reseal
mechanism. This avoids the entire category of problems around instance
migration (existing objects have fixed-size field arrays sized at
construction time). Moose allowed unsealing but strongly discouraged it;
we simply don't allow it.

The useful capability that a mutable MOP provides — generating classes
dynamically — is fully supported. You can create a brand new class or role
at runtime, compose roles into it, add methods, set a superclass, and seal
it. Once sealed, it behaves identically to a parser-declared class.

## 2. Scope

### What the MOP provides

- **Introspection:** Query fields, methods, superclass, roles, constructor
  params, sealed status, field count — all from Perl space.
- **Programmatic construction:** Create new classes and roles entirely from
  Perl code, without `eval` or source-level `class` blocks.
- **Method installation:** Add pre-compiled CVs (plain subs) as methods on
  a class under construction.
- **Role composition:** Compose existing sealed roles into a new class or
  role, using the same proto-role algebra as the parser path.
- **Inheritance:** Set a superclass on a class under construction.

### What the MOP does not provide

- **Field creation at runtime.** Programmatic classes cannot add new fields.
  Fields come only from composed roles and the superclass. This eliminates
  the hardest problems: field default OP trees, suspended compcv for
  initfield parsing, field index resolution for own fields, and field pad
  binding in methods.
- **Post-seal mutation.** No adding methods, fields, roles, or changing
  inheritance after seal. The sealed flag is final.
- **Unseal/reseal.** No mechanism to reopen a sealed class. Existing
  instances have fixed-size field arrays; changing the field count would
  require an instance registry or lazy reallocation.

## 3. Introspection API (Read-Only)

All metadata needed for introspection is already stored on `struct xpvhv_aux`
at runtime:

| Data | Source | Available? |
|------|--------|------------|
| Fields (names, sigils, defaults, params) | `xhv_class_fields` (PADNAMELIST) + `PadnameFIELDINFO` | Yes |
| Superclass | `xhv_class_superclass` | Yes |
| Composed roles | `xhv_class_roles` | Yes |
| Constructor params | `xhv_class_param_map` | Yes |
| Total field count | `xhv_class_next_fieldix` | Yes |
| Sealed status | `HvAUXf_IS_CLASS_SEALED` flag | Yes |
| Is class / is role | `HvAUXf_IS_CLASS` / `HvAUXf_IS_ROLE` flags | Yes |
| Methods | Stash walk (check `CvIsMETHOD`) | Yes |
| Method provenance | Proto-role `method_slot_t` (if retained per Phase 6) | After Phase 6 |
| Object field values | `ObjectFIELDS(sv)[fieldix]` | Yes |

Implementation: XS wrappers around existing data structures. No structural
changes needed.

## 4. Programmatic Construction

### 4.1 Lifecycle

The programmatic lifecycle mirrors the parser path:

```
create_class / create_role
    → set_superclass      (classes only)
    → add_role             (zero or more)
    → add_method           (zero or more)
    → seal
```

Once sealed, the class/role is indistinguishable from a parser-declared one.

### 4.2 `mop_create_class(name)` / `mop_create_role(name)`

A variant of `class_setup_stash` / `role_setup_stash` that:

- Creates the stash, sets `HvAUXf_IS_CLASS` (or `HvAUXf_IS_ROLE`)
- Injects the constructor (classes only)
- Initializes all `xhv_class_*` aux fields
- Creates the proto-role (`proto_role_new`)
- **Does NOT** register a `SAVEDESTRUCTOR_X` (no auto-seal; caller seals
  explicitly)
- **Does NOT** create a suspended compcv (no fields to parse init
  expressions for)

### 4.3 `mop_set_superclass(stash, super_stash)`

- Sets `xhv_class_superclass`
- Pushes onto `@ISA`
- The superclass must already be sealed

### 4.4 `mop_add_role(stash, role_stash)`

- Pushes to `xhv_class_pending_roles`
- The role must already be sealed
- Composition happens at seal time (same as parser path)

### 4.5 `mop_add_method(stash, name_sv, cv)`

Accepts a plain `sub` (not `method { ... }`) and installs it:

- Sets `CvSTASH(cv)` to the target class stash
- Stores in the stash via `hv_store`
- Records in the proto-role's method slots (so composition algebra sees it)

**Why plain subs, not anonymous methods:**

Anonymous `method { ... }` is always bound to the class in which it is
compiled — `CvSTASH` is set to the enclosing class, and `pp_methstart`
validates `$self` against that class. Moving the CV to a different class
requires patching `CvSTASH`. Since programmatic classes have no fields,
there are no field pad bindings to worry about — only the `CvSTASH` check.

Plain subs are simpler: they have no `CvIsMETHOD` flag, no OP_METHSTART,
and no class-binding assumptions. The MOP's `add_method` can optionally
set `CvIsMETHOD` and inject OP_METHSTART for `$self` validation, or
simply install the CV as-is. Methods installed this way access inherited/
composed fields through accessors (`:reader`/`:writer`), not direct pad
binding.

### 4.6 `mop_seal(stash)`

A variant of `class_seal_stash` that:

1. **Seals superclass if needed** (same as parser path)
2. **Initializes `next_fieldix` from superclass** (same)
3. **Finalizes proto-role** — records any methods added via `mop_add_method`
4. **Composes roles** via `proto_role_compose_and_install` (same — this
   function has no parser dependency)
5. **Skips Phase 1** (own field index resolution — no own fields)
6. **Runs Phase 2** (method fieldmap binding — will produce empty aux for
   methods with no field PADNAMEs, which is correct)
7. **Builds initfields CV from scratch** — this is the key difference from
   the parser path:
   - `start_subparse(FALSE, 0)` to create a fresh compcv
   - Inject `$self`, `%params`, `$role_offset` into the pad
   - Build optree: `OP_METHSTART` + `OP_ENTERSUB` calls to chain
     superclass and role initfields CVs
   - `newATTRSUB(floor_ix, NULL, NULL, NULL, ops)` to compile
   - No `OP_INITFIELD` ops (no own fields)
8. **Sets `HvAUXf_IS_CLASS_SEALED`**

## 5. Parser Coupling Analysis

The current `class_seal_stash` has one hard parser dependency: the
initfields CV is built by resuming a suspended compcv created during
`class_setup_stash`. This suspended compcv captures parser state
(`PL_compcv`, pad entries for `$self`/`%params`/`$role_offset`, field
default expressions).

For programmatic classes (no fields), we don't need the suspended compcv
at all. The initfields CV is trivial — it just chains superclass/role
initfields calls. Building it from scratch (~30 lines of C) avoids the
parser dependency entirely.

Everything else in the seal path is parser-independent:
- Proto-role finalization: walks the stash, sorts arrays
- Role composition: pure data manipulation on proto-roles
- Method fieldmap binding: walks CV pads, builds aux arrays
- Sealed flag: just sets a bit

## 6. Usage Examples

```perl
use feature 'class';

# Source-level declarations (existing)
role Logging {
    method log ($msg) { say $msg }
}

class Base {
    field $name :param :reader;
}

# Programmatic class creation (new MOP capability)
use mop;

my $meta = mop::create_class('Greeter', isa => 'Base', does => ['Logging']);

$meta->add_method('greet', sub ($self) {
    $self->log("Hello, " . $self->name);
});

$meta->seal;

# Now fully usable
my $obj = Greeter->new(name => "world");
$obj->greet;           # "Hello, world"
$obj->isa('Base');     # true
$obj->DOES('Logging'); # true
```

## 7. Implementation Phases

### Phase 8: Read-Only Introspection API

XS module exposing existing `xhv_class_*` data:

- `mop::fields(stash)` — returns field metadata from `xhv_class_fields`
- `mop::superclass(stash)` — returns `xhv_class_superclass`
- `mop::roles(stash)` — returns `xhv_class_roles`
- `mop::is_class(stash)` / `mop::is_role(stash)` / `mop::is_sealed(stash)`
- `mop::param_map(stash)` — returns `xhv_class_param_map`

No structural changes. Pure wrappers.

### Phase 9: Programmatic Class/Role Construction

New C functions in `class.c`:

- `S_mop_setup_class` / `S_mop_setup_role` — parser-free setup
- `S_mop_add_method` — install CV into unsealed class
- `S_mop_set_superclass` — set `:isa` equivalent
- `S_mop_add_role` — queue role for composition
- `S_mop_seal` — seal with from-scratch initfields CV generation

Refactoring: extract the initfields-CV-building logic from
`class_seal_stash` Phase 3 into a helper that can be driven either by
the suspended compcv (parser path) or by a fresh compcv (MOP path).

### Phase 10: XS/Perl API + Tests

- XS bindings for Phase 9 functions
- `mop.pm` Perl module with the user-facing API
- Test suite: programmatic class creation, role composition, inheritance,
  method dispatch, constructor params from composed roles/superclass
