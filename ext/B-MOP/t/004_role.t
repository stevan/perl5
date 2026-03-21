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

# Define a simple role
role Greetable {
    method greet { "hello" }
}

# Role with fields
role HasName {
    field $name :param;
    method name { $name }
}

# Role with a required method
role Stringable {
    method to_string;
    method display { ">> " . $self->to_string . " <<" }
}

# Role composing another role
role Displayable :does(Stringable) {
    method show { "[" . $self->to_string . "]" }
}

# Class composing roles
class Person :does(HasName) :does(Stringable) {
    field $age :param;
    method age { $age }
    method to_string { $self->name . " age " . $age }
}

# --- for_role works ---
{
    my $meta = B::MOP->for_role('Greetable');
    isa_ok($meta, 'B::MOP::Role');
    is($meta->name, 'Greetable', 'role name');
}

# --- for_role croaks on a class ---
{
    eval { B::MOP->for_role('Person') };
    like($@, qr/is not a role/, 'for_role croaks on class');
}

# --- for_role croaks on non-existent package ---
{
    eval { B::MOP->for_role('No::Such::Role') };
    like($@, qr/No such role/, 'for_role croaks on non-existent package');
}

# --- for_role croaks on plain package ---
{
    eval { B::MOP->for_role('main') };
    like($@, qr/is not a role/, 'for_role croaks on plain package');
}

# --- Role name ---
{
    my $meta = B::MOP->for_role('HasName');
    is($meta->name, 'HasName', 'HasName role name');
}

# --- Role fields ---
{
    my $meta = B::MOP->for_role('HasName');
    my @fields = $meta->fields;
    is(scalar @fields, 1, 'HasName has 1 field');
    isa_ok($fields[0], 'B::MOP::Field');
    is($fields[0]->name, '$name', 'field name is $name');
}

# --- Role methods ---
{
    my $meta = B::MOP->for_role('HasName');
    my @methods = sort { $a->name cmp $b->name } $meta->methods;
    is(scalar @methods, 1, 'HasName has 1 method');
    is($methods[0]->name, 'name', 'method name');
}

# --- Role stash ---
{
    my $meta = B::MOP->for_role('Greetable');
    my $stash = $meta->stash;
    isa_ok($stash, 'B::HV');
}

# --- Role required_methods ---
{
    my $meta = B::MOP->for_role('Stringable');
    my @required = $meta->required_methods;
    is(scalar @required, 1, 'Stringable has 1 required method');
    is($required[0], 'to_string', 'required method is to_string');
}

# --- Role with no required methods ---
{
    my $meta = B::MOP->for_role('Greetable');
    my @required = $meta->required_methods;
    is(scalar @required, 0, 'Greetable has no required methods');
}

# --- Role composing role (transitive) ---
{
    my $meta = B::MOP->for_role('Displayable');
    my @roles = $meta->roles;
    is(scalar @roles, 1, 'Displayable composes 1 role');
    isa_ok($roles[0], 'B::MOP::Role');
    is($roles[0]->name, 'Stringable', 'composed role is Stringable');
}

# --- Class->roles returns B::MOP::Role objects ---
{
    my $meta = B::MOP->for_class('Person');
    my @roles = sort { $a->name cmp $b->name } $meta->roles;
    is(scalar @roles, 2, 'Person composes 2 roles');
    for my $r (@roles) {
        isa_ok($r, 'B::MOP::Role');
    }
    my @names = map { $_->name } @roles;
    is_deeply(\@names, ['HasName', 'Stringable'], 'role names');
}

# --- Method->class returns B::MOP::Role for role methods ---
{
    my $meta = B::MOP->for_role('Greetable');
    my @methods = $meta->methods;
    is(scalar @methods, 1, 'Greetable has 1 method');
    my $mc = $methods[0]->class;
    isa_ok($mc, 'B::MOP::Role', 'method->class returns B::MOP::Role for role method');
    is($mc->name, 'Greetable', 'method->class name is Greetable');
}

# --- Field->class returns B::MOP::Role for role fields ---
{
    my $meta = B::MOP->for_role('HasName');
    my @fields = $meta->fields;
    my $fc = $fields[0]->class;
    isa_ok($fc, 'B::MOP::Role', 'field->class returns B::MOP::Role for role field');
    is($fc->name, 'HasName', 'field->class name is HasName');
}

# --- Role with no roles composed ---
{
    my $meta = B::MOP->for_role('Greetable');
    my @roles = $meta->roles;
    is(scalar @roles, 0, 'Greetable composes no roles');
}

# --- Role adjust_blocks ---
role WithAdjust {
    field $initialized = 0;
    ADJUST {
        $initialized = 1;
    }
    method initialized { $initialized }
}

{
    my $meta = B::MOP->for_role('WithAdjust');
    my @adjusts = $meta->adjust_blocks;
    is(scalar @adjusts, 1, 'WithAdjust has 1 ADJUST block');
    isa_ok($adjusts[0], 'B::CV');
}

# --- Role with no adjust blocks ---
{
    my $meta = B::MOP->for_role('Greetable');
    my @adjusts = $meta->adjust_blocks;
    is(scalar @adjusts, 0, 'Greetable has no ADJUST blocks');
}

done_testing;
