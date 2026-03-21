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

class Foo {
    field $bar :param;
    field $baz :param = 42;
    field @items;
    field %lookup;
}

my $meta = B::MOP->for_class('Foo');
my @fields = $meta->fields;

is(scalar @fields, 4, 'Foo has 4 fields');

# Fields are in declaration order
{
    my $f = $fields[0];
    is($f->name,       '$bar', 'field name $bar');
    is($f->sigil,      '$',    'scalar sigil');
    is($f->fieldix,    0,      'fieldix 0');
    is($f->param_name, 'bar',  'param_name bar');
    ok(!$f->has_default,       'no default');

    my $fc = $f->class;
    isa_ok($fc, 'B::MOP::Class');
    is($fc->name, 'Foo', 'field class is Foo');
}

{
    my $f = $fields[1];
    is($f->name,       '$baz', 'field name $baz');
    is($f->sigil,      '$',    'scalar sigil');
    is($f->fieldix,    1,      'fieldix 1');
    is($f->param_name, 'baz',  'param_name baz');
    ok($f->has_default,        'has default');
}

{
    my $f = $fields[2];
    is($f->name,    '@items', 'field name @items');
    is($f->sigil,   '@',     'array sigil');
    is($f->fieldix, 2,       'fieldix 2');
    is($f->param_name, undef, 'no param_name');
    ok(!$f->has_default,      'no default');
}

{
    my $f = $fields[3];
    is($f->name,    '%lookup', 'field name %lookup');
    is($f->sigil,   '%',      'hash sigil');
    is($f->fieldix, 3,        'fieldix 3');
    is($f->param_name, undef, 'no param_name');
    ok(!$f->has_default,      'no default');
}

# Inherited fields are not included in subclass ->fields
class Bar :isa(Foo) {
    field $extra :param;
}

{
    my $bar_meta = B::MOP->for_class('Bar');
    my @bar_fields = $bar_meta->fields;
    is(scalar @bar_fields, 1, 'Bar has 1 own field');
    is($bar_fields[0]->name, '$extra', 'own field is $extra');
}

done_testing;
