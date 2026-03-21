#!/usr/bin/perl

use v5.36;
use Test::More;
use autobox;

# ============================================================================
# number.t - Number role methods (CORE::Autobox::Number)
# ============================================================================

# --- abs ---

is(42->abs, 42, 'abs of positive number');
is((-42)->abs, 42, 'abs of negative number');
is(0->abs, 0, 'abs of zero');

# --- int ---

is(3.7->int, 3, 'int truncates positive float');
is((-3.7)->int, -3, 'int truncates negative float');
is(5->int, 5, 'int of integer is identity');

# --- sqrt ---

is(9->sqrt, 3, 'sqrt of 9');
is(0->sqrt, 0, 'sqrt of zero');
ok(2->sqrt > 1.414 && 2->sqrt < 1.415, 'sqrt of 2 is approximately 1.4142');

# --- chr ---

is(65->chr, 'A', 'chr of 65 is A');
is(97->chr, 'a', 'chr of 97 is a');
is(48->chr, '0', 'chr of 48 is 0');

# --- hex ---

is(255->to_hex, 'ff', 'to_hex of 255');
is(10->to_hex, 'a', 'to_hex of 10');

# --- to_oct ---

is(8->to_oct, '10', 'to_oct of 8');
is(255->to_oct, '377', 'to_oct of 255');

# --- is_positive, is_negative, is_zero ---

ok(42->is_positive, '42 is positive');
ok(!42->is_negative, '42 is not negative');
ok(!42->is_zero, '42 is not zero');

ok((-1)->is_negative, '-1 is negative');
ok(!(-1)->is_positive, '-1 is not positive');

ok(0->is_zero, '0 is zero');
ok(!0->is_positive, '0 is not positive');
ok(!0->is_negative, '0 is not negative');

# --- times ---

{
    my @collected;
    my $ret = 5->times(sub { push @collected, $_ });
    is_deeply(\@collected, [0, 1, 2, 3, 4], 'times iterates 0 to n-1');
    is($ret, 5, 'times returns self');
}

{
    my @collected;
    0->times(sub { push @collected, $_ });
    is_deeply(\@collected, [], 'times with 0 does nothing');
}

# --- Edge: large numbers ---

is(1_000_000->abs, 1000000, 'abs of large number');
ok(1_000_000->is_positive, 'large number is positive');

done_testing;
