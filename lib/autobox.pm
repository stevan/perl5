package autobox 0.01;

use v5.40;
use warnings;

# ============================================================================
# autobox - Call methods on native (unblessed) values via role dispatch
# ============================================================================
#
# Lexically scoped pragma that enables method calls on primitive types
# (numbers, strings, arrayrefs, hashrefs, coderefs) by dispatching through
# hidden "autobox dispatch stashes" populated from roles.
#
# The C runtime (pp_hot.c S_autobox_dispatch_stash) reads stash names from
# %^H keyed as "autobox/NUMBER", "autobox/STRING", etc., and resolves them
# via gv_stashpvn at method-dispatch time.
# ============================================================================

# -- Default roles shipped in core ----------------------------------------

my %DEFAULT_ROLES = (
    NUMBER => 'CORE::Autobox::Number',
    STRING => 'CORE::Autobox::String',
    ARRAY  => 'CORE::Autobox::Array',
    HASH   => 'CORE::Autobox::Hash',
    CODE   => 'CORE::Autobox::Code',
);

# -- Internal dispatch stash namespaces -----------------------------------
# These are the hidden packages that the C runtime looks up. They are
# populated with method CVs copied from the corresponding role.

my %DISPATCH_STASH = (
    NUMBER => 'CORE::Autobox::_Dispatch::Number',
    STRING => 'CORE::Autobox::_Dispatch::String',
    ARRAY  => 'CORE::Autobox::_Dispatch::Array',
    HASH   => 'CORE::Autobox::_Dispatch::Hash',
    CODE   => 'CORE::Autobox::_Dispatch::Code',
    UNDEF  => 'CORE::Autobox::_Dispatch::Undef',
);

# -- Valid type names -----------------------------------------------------

my %VALID_TYPES = map { $_ => 1 } qw(NUMBER STRING ARRAY HASH CODE UNDEF SCALAR);

my @ALL_HINT_TYPES = qw(NUMBER STRING ARRAY HASH CODE UNDEF);

# -- Cache: track which (type, role) pairs have already been composed -----
# Key: "$type\0$role_name", Value: dispatch stash name
my %COMPOSED_CACHE;

# ============================================================================
# import -- called by `use autobox` and `use autobox TYPE => 'Role'`
# ============================================================================

sub import {
    my ($class, @args) = @_;

    # Parse arguments: either empty (all defaults) or TYPE => 'Role' pairs
    if (@args % 2) {
        _croak("Odd number of arguments to 'use autobox'");
    }
    my %args = @args;

    # Validate type names
    for my $key (keys %args) {
        unless ($VALID_TYPES{$key}) {
            _croak("Unknown autobox type '$key'; "
                 . "valid types are: NUMBER, STRING, ARRAY, HASH, CODE, UNDEF, SCALAR");
        }
    }

    # Handle SCALAR sugar: applies to both NUMBER and STRING
    if (exists $args{SCALAR}) {
        my $scalar_role = $args{SCALAR};
        $args{NUMBER} //= $scalar_role;
        $args{STRING} //= $scalar_role;
        delete $args{SCALAR};
    }

    # Determine which role to use for each standard type
    my %roles;
    for my $type (qw(NUMBER STRING ARRAY HASH CODE)) {
        $roles{$type} = $args{$type} // $DEFAULT_ROLES{$type};
    }

    # UNDEF is opt-in only -- no default role
    if (exists $args{UNDEF}) {
        $roles{UNDEF} = $args{UNDEF};
    }

    # Enable the autobox master hint (read by C runtime as fast-path guard)
    $^H{"autobox"} = 1;

    # For each type, ensure the role is loaded, validated, and composed
    # into its dispatch stash, then store the dispatch stash name in %^H
    for my $type (keys %roles) {
        my $role_name = $roles{$type};
        my $dispatch_name = _setup_dispatch($type, $role_name);
        $^H{"autobox/$type"} = $dispatch_name;
    }
}

# ============================================================================
# unimport -- called by `no autobox`
# ============================================================================

sub unimport {
    delete $^H{"autobox"};
    for my $type (@ALL_HINT_TYPES) {
        delete $^H{"autobox/$type"};
    }
}

# ============================================================================
# _setup_dispatch -- load role, validate, compose into dispatch stash
# ============================================================================
#
# Returns the dispatch stash name (string) to store in %^H.
#
# For a given (type, role) pair we:
#   1. Load the role's module if its stash is empty
#   2. Validate that the target is a real `role` (HvAUXf_IS_ROLE)
#   3. Validate that the role declares no fields
#   4. Copy all CvIsMETHOD CVs from the role stash into the dispatch stash
#   5. The dispatch stash needs HvAUXf_IS_AUTOBOX set (done by XS bootstrap)
#
# Results are cached: if the same (type, role) pair has already been set up,
# we skip recomposition and return the cached dispatch stash name.

sub _setup_dispatch {
    my ($type, $role_name) = @_;

    my $cache_key = "$type\0$role_name";
    if (my $cached = $COMPOSED_CACHE{$cache_key}) {
        return $cached;
    }

    # Determine dispatch stash name.
    # For custom roles (not the default), generate a unique dispatch namespace
    # so that different lexical scopes with different role overrides don't
    # clobber each other's dispatch tables.
    my $dispatch_name;
    if (exists $DEFAULT_ROLES{$type} && $role_name eq $DEFAULT_ROLES{$type}) {
        $dispatch_name = $DISPATCH_STASH{$type};
    }
    elsif ($type eq 'UNDEF') {
        # UNDEF has no default role; use role-specific dispatch stash
        $dispatch_name = $DISPATCH_STASH{$type} . "::" . $role_name;
    }
    else {
        $dispatch_name = $DISPATCH_STASH{$type} . "::" . $role_name;
    }

    # Step 1: Load the role module if its stash is empty
    _load_role_module($role_name);

    # Step 2 & 3: Validate the role (is it a role? does it have fields?)
    _validate_role($role_name);

    # Step 4: Copy role methods into the dispatch stash
    _compose_into_dispatch($role_name, $dispatch_name);

    # Step 5: Mark the dispatch stash with HvAUXf_IS_AUTOBOX.
    # This requires XS/C support. We call an internal bootstrap function
    # if available; otherwise the C code in pp_methstart already checks
    # for this flag -- it will be set when the stash is first used.
    _mark_autobox_stash($dispatch_name);

    # Cache the result
    $COMPOSED_CACHE{$cache_key} = $dispatch_name;

    return $dispatch_name;
}

# ============================================================================
# _load_role_module -- require the module that defines the role
# ============================================================================

sub _load_role_module {
    my ($role_name) = @_;

    # Check if the role's stash already has entries (i.e., already loaded)
    my $stash_exists = do {
        no strict 'refs';
        scalar %{"${role_name}::"};
    };

    unless ($stash_exists) {
        # Convert Foo::Bar to Foo/Bar.pm and require it
        (my $file = $role_name) =~ s{::}{/}g;
        $file .= ".pm";
        require $file;
    }
}

# ============================================================================
# _validate_role -- ensure target is a role keyword declaration with no fields
# ============================================================================
#
# Uses B::MOP introspection when available. B::MOP->for_role($name) will
# croak if the stash is not a role (HvAUXf_IS_ROLE not set). We then check
# that the role has zero fields, since autobox roles operate on raw $self
# values with no object backing store.
#
# If B::MOP is not available, we fall back to a best-effort check using
# the stash contents.

sub _validate_role {
    my ($role_name) = @_;

    my $have_bmop = eval { require B::MOP; 1 };

    if ($have_bmop) {
        # B::MOP->for_role croaks if not a role
        my $role_meta = eval { B::MOP->for_role($role_name) };
        if (!$role_meta) {
            _croak("'$role_name' is not a role declared with the 'role' keyword; "
                 . "autobox targets must be roles");
        }

        # Check for fields -- autobox roles must not have any
        my @fields = $role_meta->fields;
        if (@fields) {
            _croak("Autobox role '$role_name' must not declare fields "
                 . "(found " . scalar(@fields) . " field(s)); "
                 . "autobox methods operate on the raw value as \$self");
        }
    }
    else {
        # Fallback: we can't easily check HvAUXf_IS_ROLE from pure Perl.
        # We do a minimal sanity check: the stash should exist and have
        # at least one entry (meaning the module loaded something).
        my $stash_exists = do {
            no strict 'refs';
            scalar %{"${role_name}::"};
        };
        unless ($stash_exists) {
            _croak("'$role_name' does not appear to be a loaded role; "
                 . "autobox targets must be roles declared with the 'role' keyword");
        }
        # Without B::MOP we cannot validate IS_ROLE or field count.
        # The C runtime will catch non-autobox stashes at dispatch time.
    }
}

# ============================================================================
# _compose_into_dispatch -- copy role methods into the dispatch stash
# ============================================================================
#
# Iterates the role's stash, finds all CODE entries that are CvIsMETHOD,
# and aliases them into the dispatch stash. This is a simplified version
# of role composition -- we don't handle fields, ADJUST blocks, etc.,
# because autobox roles are fieldless.
#
# We use B::svref_2object to check CvFLAGS for CVf_IsMETHOD (0x8000).

sub _compose_into_dispatch {
    my ($role_name, $dispatch_name) = @_;

    no strict 'refs';
    no warnings 'once';

    my $role_stash    = \%{"${role_name}::"};
    my $dispatch_stash = \%{"${dispatch_name}::"};

    # We need B to inspect CV flags for CvIsMETHOD
    require B;

    for my $name (keys %$role_stash) {
        # Skip special stash entries and Perl-internal names
        next if $name =~ /^(?:ISA|BEGIN|CHECK|INIT|END|UNITCHECK|AUTOLOAD|DESTROY|VERSION|import|unimport)$/;
        next if $name =~ /::$/;  # sub-stash references

        my $glob = $role_stash->{$name};

        # In stashes, entries may be plain SVs (stub declarations), GVs,
        # or sub-stashes (trailing ::). We only want CODE slots.
        my $cv;
        if (ref(\$glob) eq 'GLOB') {
            $cv = *{$glob}{CODE};
        }
        elsif (ref($glob) eq 'CODE') {
            # Possible with newer Perl stash optimizations
            $cv = $glob;
        }
        else {
            next;
        }

        next unless defined $cv;

        # Check if this CV is a method (CvIsMETHOD flag)
        my $b_cv = B::svref_2object($cv);
        next unless $b_cv->isa('B::CV');

        # CVf_IsMETHOD is 0x8000 (from cv.h)
        my $CVf_IsMETHOD = 0x8000;
        next unless $b_cv->CvFLAGS & $CVf_IsMETHOD;

        # Alias the method CV into the dispatch stash
        *{"${dispatch_name}::${name}"} = $cv;
    }
}

# ============================================================================
# _mark_autobox_stash -- set HvAUXf_IS_AUTOBOX on the dispatch stash
# ============================================================================
#
# This needs to set the HvAUXf_IS_AUTOBOX (0x10) bit on the stash's
# xhv_aux_flags. This cannot be done from pure Perl -- it requires either:
#   (a) An XS helper function, or
#   (b) The C runtime to set the flag when it first resolves the stash name
#
# For now, we attempt to call an internal XS bootstrap if available.
# If not, the C runtime in pp_methstart already has the IS_AUTOBOX check
# path -- a future commit will add the XS helper or have the C stash
# resolution set the flag automatically.

sub _mark_autobox_stash {
    my ($dispatch_name) = @_;

    # Try to call the XS helper if it exists
    if (defined &_xs_mark_autobox_stash) {
        _xs_mark_autobox_stash($dispatch_name);
        return;
    }

    # Fallback: the C code in S_autobox_dispatch_stash will be updated to
    # set HvAUXf_IS_AUTOBOX on the stash when it resolves the name from
    # %^H. This is a temporary gap that will be closed when the C side
    # is updated.
}

# ============================================================================
# _croak -- error reporting
# ============================================================================

sub _croak {
    require Carp;
    goto &Carp::croak;
}

1;

__END__

=head1 NAME

autobox - Call methods on native types

=head1 SYNOPSIS

    use autobox;

    say 42->sqrt;                       # 6.48074069840786
    say "hello"->uc;                    # HELLO
    say [3, 1, 2]->sort->join(", ");    # 1, 2, 3
    say { a => 1 }->keys->sort->join;   # a

    # Override the default role for a type
    use autobox NUMBER => 'My::Number';

    # SCALAR is sugar for NUMBER + STRING
    use autobox SCALAR => 'My::Scalar';

    # Opt-in undef handling
    use autobox UNDEF => 'My::Maybe';

    # Lexically scoped
    {
        use autobox;
        say 10->chr;    # works
    }
    # 10->chr;          # would croak outside the scope

    # Turn off within a scope
    {
        no autobox;
        # 10->chr;      # croaks
    }

=head1 DESCRIPTION

C<autobox> is a lexically scoped pragma that enables method calls on native
(unblessed) Perl values: numbers, strings, array references, hash references,
and code references. It works by intercepting method dispatch at runtime and
routing calls through I<autobox roles> -- real C<role> declarations that
define methods operating on the raw value as C<$self>.

=head2 How it works

When you write C<use autobox>, the pragma:

=over 4

=item 1.

Loads the default autobox roles (C<CORE::Autobox::Number>, etc.)

=item 2.

Validates that each target is a real C<role> with no fields

=item 3.

Copies the role's methods into a hidden dispatch stash

=item 4.

Stores the dispatch stash name in the lexical hints hash (C<%^H>)

=back

At runtime, when a method is called on an unblessed value, the dispatch
code in C<pp_hot.c> checks C<%^H> for an active autobox hint. If found,
it classifies the value by type (number, string, arrayref, etc.) and
looks up the corresponding dispatch stash to resolve the method.

=head2 Type classification

Values are classified as follows:

=over 4

=item B<NUMBER> - values created as numbers (C<42>, C<3.14>, C<0xFF>)

=item B<STRING> - values created as strings (C<"hello">, C<'world'>)

=item B<ARRAY> - array references (C<[1, 2, 3]>)

=item B<HASH> - hash references (C<{ a =E<gt> 1 }>)

=item B<CODE> - code references (C<sub { ... }>)

=item B<UNDEF> - the undefined value (opt-in only)

=back

Scalars that are both numeric and stringy use the "created as" semantics
(same as C<builtin::created_as_number> and C<builtin::created_as_string>).
Booleans are not autoboxable.

=head2 User overrides

You can replace the default role for any type:

    use autobox NUMBER => 'Unit::Time';

The replacement must be a C<role> declared with the C<role> keyword, and
it must not have any fields. If you want to extend the default behavior,
have your custom role compose the default:

    role My::Number :does(CORE::Autobox::Number) {
        method factorial { ... }
    }

    use autobox NUMBER => 'My::Number';

=head2 SCALAR sugar

C<SCALAR> sets both C<NUMBER> and C<STRING> to the same role:

    use autobox SCALAR => 'My::Scalar';

    # equivalent to:
    use autobox NUMBER => 'My::Scalar', STRING => 'My::Scalar';

Explicit C<NUMBER> or C<STRING> overrides take precedence over C<SCALAR>.

=head2 UNDEF opt-in

By default, calling a method on C<undef> still croaks. To enable it:

    use autobox UNDEF => 'My::Maybe';

=head1 DEFAULT ROLES

The following roles ship with core Perl:

=over 4

=item L<CORE::Autobox::Number> - abs, sqrt, chr, int, hex, oct, ...

=item L<CORE::Autobox::String> - uc, lc, length, trim, split, ...

=item L<CORE::Autobox::Array> - push, pop, map, grep, sort, join, ...

=item L<CORE::Autobox::Hash> - keys, values, exists, delete, merge, ...

=item L<CORE::Autobox::Code> - curry, compose

=back

=head1 SEE ALSO

L<feature/"class">, L<perlclass>

=cut
