#!/usr/bin/perl

use v5.36;
use Test::More;
use autobox;

# ============================================================================
# code.t - Code role methods (CORE::Autobox::Code)
# ============================================================================

# --- curry with one bound arg ---

{
    my $add = sub { $_[0] + $_[1] };
    my $add5 = $add->curry(5);
    is($add5->(3), 8, 'curry with one bound arg');
    is($add5->(10), 15, 'curried function reusable with different arg');
}

# --- curry with multiple bound args ---

{
    my $sum3 = sub { $_[0] + $_[1] + $_[2] };
    my $sum_10_20 = $sum3->curry(10, 20);
    is($sum_10_20->(30), 60, 'curry with two bound args');
}

# --- curry with no bound args ---

{
    my $greet = sub { "hi $_[0]" };
    my $same = $greet->curry();
    is($same->("world"), "hi world", 'curry with no args is identity-like');
}

# --- compose ---

{
    my $double = sub { $_[0] * 2 };
    my $inc    = sub { $_[0] + 1 };

    my $double_then_inc = $inc->compose($double);
    is($double_then_inc->(5), 11, 'compose: inc(double(5)) = 11');

    my $inc_then_double = $double->compose($inc);
    is($inc_then_double->(5), 12, 'compose: double(inc(5)) = 12');
}

# --- compose chaining ---

{
    my $add1 = sub { $_[0] + 1 };
    my $mul2 = sub { $_[0] * 2 };
    my $sub3 = sub { $_[0] - 3 };

    # sub3(mul2(add1(x))): add1(10)=11, mul2(11)=22, sub3(22)=19
    my $chain = $sub3->compose($mul2)->compose($add1);
    is($chain->(10), 19, 'compose chaining: sub3(mul2(add1(10))) = 19');
}

done_testing;
