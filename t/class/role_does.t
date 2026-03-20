#!/usr/bin/perl

use v5.36;
use feature 'class';
no warnings 'experimental::class';

use Test::More;

# :does accepted on a class
{
    role Greetable {
        method greet { "hello" }
    }

    class Greeter :does(Greetable) {
        field $name :param;
        method name { $name }
    }

    ok(1, ':does on class compiles');
}

# :does accepted on a role (role-composes-role)
{
    role Inner {
        method inner { "inner" }
    }

    role Outer :does(Inner) {
        method outer { "outer" }
    }

    ok(1, ':does on role compiles');
}

# :does with multiple roles
{
    role R1 {
        method r1 { "r1" }
    }

    role R2 {
        method r2 { "r2" }
    }

    class Multi :does(R1) :does(R2) {
        field $x :param;
        method x { $x }
    }

    ok(1, 'multiple :does on class compiles');
}

# :does rejects non-role targets
{
    ok(!eval q{
        use v5.36;
        use feature 'class';
        no warnings 'experimental::class';

        class NotARole {
            field $x :param;
        }

        class Consumer :does(NotARole) {
            field $y :param;
        }
        1;
    }, ':does with a class (not role) fails');
    like($@, qr/:does attribute requires a role/, 'correct error for :does with non-role');
}

# :does rejects non-existent packages
{
    ok(!eval q{
        use v5.36;
        use feature 'class';
        no warnings 'experimental::class';
        class Bad :does(No::Such::Role::Anywhere) { }
        1;
    }, ':does with non-existent package fails');
    ok($@, 'got an error for non-existent role');
}

# :does rejects plain packages
package PlainPkg { sub dummy { 1 } }
{
    ok(!eval q{
        use v5.36;
        use feature 'class';
        no warnings 'experimental::class';
        class Consumer2 :does(PlainPkg) { }
        1;
    }, ':does with plain package fails');
    like($@, qr/:does attribute requires a role/, 'correct error for :does with plain package');
}

done_testing;
