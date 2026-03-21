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

# Basic class
class Point {
    field $x :param;
    field $y :param;
    method x { $x }
    method y { $y }
}

# for_class with a class name
{
    my $meta = B::MOP->for_class('Point');
    isa_ok($meta, 'B::MOP::Class');
    is($meta->name, 'Point', 'class name');
}

# for_class with an object instance
{
    my $obj = Point->new(x => 1, y => 2);
    my $meta = B::MOP->for_class($obj);
    isa_ok($meta, 'B::MOP::Class');
    is($meta->name, 'Point', 'for_class from object');
}

# for_class croaks on non-class package
{
    eval { B::MOP->for_class('main') };
    like($@, qr/is not a class/, 'croaks on non-class package');
}

# for_class croaks on non-existent package
{
    eval { B::MOP->for_class('No::Such::Package') };
    like($@, qr/No such class/, 'croaks on non-existent package');
}

# superclass - no parent
{
    my $meta = B::MOP->for_class('Point');
    is($meta->superclass, undef, 'no superclass returns undef');
}

# superclass - with parent
class Point3D :isa(Point) {
    field $z :param;
    method z { $z }
}

{
    my $meta = B::MOP->for_class('Point3D');
    my $super = $meta->superclass;
    isa_ok($super, 'B::MOP::Class');
    is($super->name, 'Point', 'superclass name');
}

# fields list
{
    my $meta = B::MOP->for_class('Point');
    my @fields = $meta->fields;
    is(scalar @fields, 2, 'Point has 2 fields');
    for my $f (@fields) {
        isa_ok($f, 'B::MOP::Field');
    }
}

# methods list
{
    my $meta = B::MOP->for_class('Point');
    my @methods = $meta->methods;
    is(scalar @methods, 2, 'Point has 2 methods');
    for my $m (@methods) {
        isa_ok($m, 'B::MOP::Method');
    }
    my @names = sort map { $_->name } @methods;
    is_deeply(\@names, ['x', 'y'], 'method names');
}

# stash returns B::HV
{
    my $meta = B::MOP->for_class('Point');
    my $stash = $meta->stash;
    isa_ok($stash, 'B::HV');
}

done_testing;
