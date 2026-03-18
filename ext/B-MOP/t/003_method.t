#!./perl

BEGIN {
    chdir 't' if -d 't';
    @INC = '../lib';
}

use strict;
use warnings;
use feature 'class';
no warnings 'experimental::class';

use Test::More;

BEGIN { use_ok('B::MOP') }

class Dog {
    field $name :param;
    field $tricks :param = 0;

    method name { $name }
    method tricks { $tricks }
    method learn_trick { $tricks++ }
}

my $meta = B::MOP->for_class('Dog');
my @methods = sort { $a->name cmp $b->name } $meta->methods;

is(scalar @methods, 3, 'Dog has 3 methods');

# Method names
{
    my @names = map { $_->name } @methods;
    is_deeply(\@names, ['learn_trick', 'name', 'tricks'], 'method names sorted');
}

# Method class
{
    my $m = $methods[0];
    my $mc = $m->class;
    isa_ok($mc, 'B::MOP::Class');
    is($mc->name, 'Dog', 'method class is Dog');
}

# Method cv returns B::CV
{
    my $m = $methods[1]; # 'name'
    my $cv = $m->cv;
    isa_ok($cv, 'B::CV');
}

# Plain subs in a class stash are NOT returned as methods
class WithSub {
    field $x :param;
    method get_x { $x }

    # A regular sub, not a method
    sub helper { 42 }
}

{
    my $meta2 = B::MOP->for_class('WithSub');
    my @methods2 = $meta2->methods;
    is(scalar @methods2, 1, 'only CvIsMETHOD subs are returned');
    is($methods2[0]->name, 'get_x', 'method is get_x, not helper');
}

done_testing;
