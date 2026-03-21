#!/usr/bin/perl

use v5.36;
use Test::More;

# ============================================================================
# scope.t - Advanced scoping and override tests
# ============================================================================

# --- Lexical scoping across eval string boundaries ---

{
    use autobox;

    my $result = eval q{
        "hello"->uc;
    };
    is($result, "HELLO", 'autobox works inside eval string when active in outer scope');
}

{
    # No autobox in this scope
    my $ok = eval q{
        "hello"->uc;
        1;
    };
    ok(!$ok, 'autobox does not leak into eval string when not active');
}

# --- eval string with use/no inside ---

{
    my $result = eval q{
        use autobox;
        42->abs;
    };
    is($result, 42, 'use autobox inside eval string works');
}

{
    use autobox;
    my $result = eval q{
        no autobox;
        my $r = eval { "test"->length; 1 };
        $r;
    };
    ok(!$result, 'no autobox inside eval string disables it');
}

# --- Nested scopes with no autobox in inner ---

{
    use autobox;

    my $outer = "HELLO"->lc;
    is($outer, "hello", 'autobox active in outer scope');

    {
        no autobox;
        my $ok = eval { "test"->lc; 1 };
        ok(!$ok, 'no autobox in inner scope disables');
    }

    my $still_works = "WORLD"->lc;
    is($still_works, "world", 'autobox restored after inner no autobox scope');
}

# --- Autobox does not affect blessed object method dispatch ---

{
    package My::Obj {
        sub new { bless {}, shift }
        sub hello { "blessed hello" }
    }

    use autobox;

    my $obj = My::Obj->new;
    is($obj->hello, "blessed hello", 'blessed object dispatch unaffected by autobox');
}

# --- Blessed objects with same method names as autobox ---

{
    package My::StringLike {
        sub new { bless {}, shift }
        sub length { 999 }
        sub uc { "CUSTOM" }
    }

    use autobox;

    my $obj = My::StringLike->new;
    is($obj->length, 999, 'blessed object length method not overridden by autobox');
    is($obj->uc, "CUSTOM", 'blessed object uc method not overridden by autobox');

    # Meanwhile, autobox still works on raw strings
    is("abc"->length, 3, 'autobox string length still works alongside blessed objects');
}

# --- undef method call fails (UNDEF not configured by default) ---

{
    use autobox;

    my $ok = eval { undef->some_method; 1 };
    ok(!$ok, 'method call on undef fails with default autobox (no UNDEF role)');
    like($@, qr/Can't call method/, 'undef method call gives appropriate error');
}

# --- Boolean values are not autoboxable ---
# Booleans (from !!1 and !!0) are a distinct type and autobox
# should not dispatch on them as NUMBER or STRING

{
    use autobox;

    my $true = !!1;
    my $false = !!0;

    my $ok_true = eval { $true->is_positive; 1 };
    ok(!$ok_true, 'method call on boolean true fails (booleans not autoboxable)');

    my $ok_false = eval { $false->is_zero; 1 };
    ok(!$ok_false, 'method call on boolean false fails (booleans not autoboxable)');
}

# --- Multiple sequential scopes are independent ---

{
    {
        use autobox;
        is("a"->length, 1, 'first autobox scope works');
    }

    {
        my $ok = eval { "a"->length; 1 };
        ok(!$ok, 'gap between scopes has no autobox');
    }

    {
        use autobox;
        is("b"->length, 1, 'second autobox scope works independently');
    }
}

done_testing;
