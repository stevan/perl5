#!/usr/bin/perl

use v5.36;
use Test::More;

# ============================================================================
# basic.t - Pragma on/off, lexical scoping
# ============================================================================

# --- Autobox enables method calls on each type ---

{
    use autobox;

    # Number
    is(42->abs, 42, 'autobox enables method calls on numbers');

    # String
    is("hello"->uc, "HELLO", 'autobox enables method calls on strings');

    # Arrayref
    is_deeply([3, 1, 2]->sort, [1, 2, 3], 'autobox enables method calls on arrayrefs');

    # Hashref
    my $h = { a => 1, b => 2 };
    is($h->length, 2, 'autobox enables method calls on hashrefs');

    # Coderef
    my $add = sub { $_[0] + $_[1] };
    my $add5 = $add->curry(5);
    is($add5->(3), 8, 'autobox enables method calls on coderefs');
}

# --- no autobox disables within a scope ---

{
    use autobox;
    is("foo"->length, 3, 'autobox is active before no autobox');

    {
        no autobox;
        my $ok = eval { "foo"->length; 1 };
        ok(!$ok, 'no autobox disables method calls on strings');
        like($@, qr/Can't (?:call method|locate object method)/, 'correct error without autobox');
    }

    # autobox still active in outer scope
    is("bar"->length, 3, 'autobox still active in outer scope after no autobox in inner');
}

# --- Lexical scoping: does not leak out of blocks ---

{
    {
        use autobox;
        is(10->chr, chr(10), 'autobox active inside block');
    }

    my $ok = eval { 10->chr; 1 };
    ok(!$ok, 'autobox does not leak out of block');
}

# --- Nested scopes ---

{
    use autobox;
    is("outer"->length, 5, 'autobox active in outer scope');

    {
        # autobox is inherited lexically
        is("inner"->length, 5, 'autobox inherited in inner scope');

        {
            no autobox;
            my $ok = eval { "deep"->length; 1 };
            ok(!$ok, 'no autobox in deeply nested scope');
        }

        # Still active after inner no autobox
        is("still"->length, 5, 'autobox still active after inner no autobox block');
    }

    is("back"->length, 4, 'autobox still active in outer scope after nested blocks');
}

# --- Method calls on unblessed values fail without autobox ---

{
    my $ok;

    $ok = eval { 42->abs; 1 };
    ok(!$ok, 'method call on number fails without autobox');

    $ok = eval { "hello"->uc; 1 };
    ok(!$ok, 'method call on string fails without autobox');

    $ok = eval { [1,2,3]->length; 1 };
    ok(!$ok, 'method call on arrayref fails without autobox');

    $ok = eval { {a => 1}->keys; 1 };
    ok(!$ok, 'method call on hashref fails without autobox');
}

# --- Basic smoke of one method from each type ---

{
    use autobox;

    is((-7)->abs, 7, 'Number->abs works');
    is("Hello World"->lc, "hello world", 'String->lc works');
    is_deeply([1,2,3]->reverse, [3,2,1], 'Array->reverse works');
    ok({a => 1, b => 2}->exists("a"), 'Hash->exists works');

    my $double = sub { $_[0] * 2 };
    my $double_then_add = $double->curry();
    is($double_then_add->(5), 10, 'Code->curry (no extra args) works');
}

done_testing;
