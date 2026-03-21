#!/usr/bin/perl

use v5.36;
use Test::More;
use autobox;

# ============================================================================
# hash.t - Hash role methods (CORE::Autobox::Hash)
# ============================================================================

# --- keys ---

{
    my $h = { a => 1, b => 2, c => 3 };
    my @k = sort @{ $h->keys };
    is_deeply(\@k, ["a", "b", "c"], 'keys returns all keys');
}

is_deeply({}->keys, [], 'keys of empty hash');

# --- values ---

{
    my $h = { a => 1, b => 2 };
    my @v = sort @{ $h->values };
    is_deeply(\@v, [1, 2], 'values returns all values');
}

# --- kv ---

{
    my $h = { x => 10 };
    my $kv = $h->kv;
    is(ref $kv, 'ARRAY', 'kv returns arrayref');
    is_deeply($kv->[0], ['x', 10], 'kv returns [key, value] pairs');
}

{
    my $h = { a => 1, b => 2 };
    my @pairs = sort { $a->[0] cmp $b->[0] } @{ $h->kv };
    is_deeply(\@pairs, [['a', 1], ['b', 2]], 'kv with multiple pairs');
}

# --- length ---

is({ a => 1, b => 2, c => 3 }->length, 3, 'length of 3-element hash');
is({}->length, 0, 'length of empty hash');

# --- is_empty ---

ok({}->is_empty, 'empty hash is_empty');
ok(!{ a => 1 }->is_empty, 'non-empty hash is not is_empty');

# --- exists ---

ok({ a => 1, b => 2 }->exists("a"), 'exists for present key');
ok(!{ a => 1 }->exists("z"), 'exists for absent key');

# --- delete ---

{
    my $h = { a => 1, b => 2, c => 3 };
    my $val = $h->delete("b");
    is($val, 2, 'delete returns removed value');
    ok(!exists $h->{b}, 'delete removes the key');
    is($h->length, 2, 'hash length decremented after delete');
}

# --- merge ---

{
    my $h = { a => 1, b => 2 };
    my $merged = $h->merge(c => 3, d => 4);
    is_deeply($merged, { a => 1, b => 2, c => 3, d => 4 }, 'merge adds new keys');
}

{
    my $h = { a => 1, b => 2 };
    my $merged = $h->merge(b => 99);
    is($merged->{b}, 99, 'merge overrides existing key');
    is($h->{b}, 2, 'merge does not mutate original');
}

# --- slice ---

{
    my $h = { a => 1, b => 2, c => 3, d => 4 };
    my $s = $h->slice("a", "c");
    is_deeply($s, { a => 1, c => 3 }, 'slice returns subset of keys');
}

# --- map ---

{
    my $h = { a => 1, b => 2 };
    my $result = $h->map(sub { ($_[0], $_[1] * 10) });
    is($result->{a}, 10, 'map transforms values (a)');
    is($result->{b}, 20, 'map transforms values (b)');
}

# --- grep ---

{
    my $h = { a => 1, b => 2, c => 3, d => 4 };
    my $evens = $h->grep(sub { $_[1] % 2 == 0 });
    my @k = sort keys %$evens;
    is_deeply(\@k, ["b", "d"], 'grep filters by predicate');
    is($evens->{b}, 2, 'grep preserves values');
}

# --- invert ---

{
    my $h = { a => 1, b => 2 };
    my $inv = $h->invert;
    is($inv->{1}, "a", 'invert swaps key 1 -> a');
    is($inv->{2}, "b", 'invert swaps key 2 -> b');
}

done_testing;
