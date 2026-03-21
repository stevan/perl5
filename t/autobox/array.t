#!/usr/bin/perl

use v5.36;
use Test::More;
use autobox;

# ============================================================================
# array.t - Array role methods (CORE::Autobox::Array)
# ============================================================================

# --- length / is_empty ---

is([1, 2, 3]->length, 3, 'length of 3-element array');
is([]->length, 0, 'length of empty array');
ok([]->is_empty, 'empty array is_empty');
ok(![1]->is_empty, 'non-empty array is not is_empty');

# --- head / tail / first / last ---

is([10, 20, 30]->head, 10, 'head returns first element');
is_deeply([10, 20, 30]->tail, [20, 30], 'tail returns all but first');
is([10, 20, 30]->first, 10, 'first returns first element');
is([10, 20, 30]->last, 30, 'last returns last element');
is_deeply([42]->tail, [], 'tail of single-element array is empty');

# --- push / pop / shift / unshift (mutating) ---

{
    my $arr = [1, 2, 3];
    my $ret = $arr->push(4, 5);
    is_deeply($arr, [1, 2, 3, 4, 5], 'push mutates the array');
    is($ret, $arr, 'push returns self');
}

{
    my $arr = [1, 2, 3];
    my $val = $arr->pop;
    is($val, 3, 'pop returns last element');
    is_deeply($arr, [1, 2], 'pop mutates the array');
}

{
    my $arr = [1, 2, 3];
    my $val = $arr->shift;
    is($val, 1, 'shift returns first element');
    is_deeply($arr, [2, 3], 'shift mutates the array');
}

{
    my $arr = [1, 2, 3];
    my $ret = $arr->unshift(0);
    is_deeply($arr, [0, 1, 2, 3], 'unshift mutates the array');
    is($ret, $arr, 'unshift returns self');
}

# --- reverse ---

is_deeply([1, 2, 3]->reverse, [3, 2, 1], 'reverse');
is_deeply([]->reverse, [], 'reverse of empty array');

# --- sort ---

is_deeply([3, 1, 2]->sort, [1, 2, 3], 'sort without comparator');
is_deeply([3, 1, 2]->sort(sub { $_[1] <=> $_[0] }), [3, 2, 1], 'sort with reverse comparator');
is_deeply(["b", "a", "c"]->sort, ["a", "b", "c"], 'sort strings');

# --- join ---

is([1, 2, 3]->join(", "), "1, 2, 3", 'join with separator');
is([1, 2, 3]->join, "1,2,3", 'join with default separator (comma)');
is([]->join(", "), "", 'join of empty array');

# --- flatten ---

{
    my @flat = [1, 2, 3]->flatten;
    is_deeply(\@flat, [1, 2, 3], 'flatten returns list');
}

# --- map ---

is_deeply([1, 2, 3]->map(sub { $_[0] * 2 }), [2, 4, 6], 'map doubles');
is_deeply([]->map(sub { $_[0] * 2 }), [], 'map on empty array');

# --- grep ---

is_deeply([1, 2, 3, 4, 5]->grep(sub { $_[0] % 2 }), [1, 3, 5], 'grep odd numbers');
is_deeply([1, 2, 3]->grep(sub { 0 }), [], 'grep matching nothing');

# --- any / all / none ---

ok([1, 2, 3]->any(sub { $_[0] == 2 }), 'any finds match');
ok(![1, 2, 3]->any(sub { $_[0] == 5 }), 'any returns false when no match');

ok([2, 4, 6]->all(sub { $_[0] % 2 == 0 }), 'all even numbers');
ok(![1, 2, 3]->all(sub { $_[0] % 2 == 0 }), 'all fails when one is odd');

ok([1, 3, 5]->none(sub { $_[0] % 2 == 0 }), 'none even in odd list');
ok(![1, 2, 3]->none(sub { $_[0] == 2 }), 'none fails when one matches');

# --- uniq ---

is_deeply([1, 2, 2, 3, 3, 3]->uniq, [1, 2, 3], 'uniq removes duplicates');
is_deeply([1, 2, 3]->uniq, [1, 2, 3], 'uniq on already unique list');
is_deeply([]->uniq, [], 'uniq on empty array');

# --- reduce ---

is([1, 2, 3, 4]->reduce(sub { $_[0] + $_[1] }), 10, 'reduce sum');
is([5]->reduce(sub { $_[0] + $_[1] }), 5, 'reduce single element');
is(["a", "b", "c"]->reduce(sub { $_[0] . $_[1] }), "abc", 'reduce concatenation');

# --- zip ---

is_deeply(
    [1, 2, 3]->zip([4, 5, 6]),
    [[1, 4], [2, 5], [3, 6]],
    'zip two equal-length arrays'
);

is_deeply(
    [1, 2]->zip([3, 4], [5, 6]),
    [[1, 3, 5], [2, 4, 6]],
    'zip three arrays'
);

is_deeply(
    [1, 2, 3]->zip([4, 5]),
    [[1, 4], [2, 5], [3, undef]],
    'zip unequal length arrays pads with undef'
);

# --- Method chaining ---

is([3, 1, 2]->sort->join(", "), "1, 2, 3", 'method chaining: sort then join');
is_deeply(
    [1, 2, 3, 4, 5]->grep(sub { $_[0] > 2 })->sort->reverse,
    [5, 4, 3],
    'method chaining: grep, sort, reverse'
);
is(
    [1, 2, 2, 3, 3]->uniq->map(sub { $_[0] * 10 })->join("-"),
    "10-20-30",
    'method chaining: uniq, map, join'
);

done_testing;
