#!perl

use v5.42;
use experimental qw[ class ];

use List::Util ();
use Data::Dumper;

## -----------------------------------------------------------------------------

class Origin {
    field $identity :param :reader;

    method equal_to ($other) {
        return $identity eq $other->identity;
    }

    method to_string { "${identity}" }
}

class Origin::Set {
    field $_origins :param :reader;

    sub of ($, @origins) {
        Origin::Set->new( _origins => +{ map { $_->identity, $_ } @origins })
    }

    method origins {
        map { $_origins->{$_} } sort { $a cmp $b } keys %$_origins
    }

    method insert ($origin) {
        return $self if exists $_origins->{ $origin->identity };
        return Origin::Set->new( _origins => +{ %$_origins, $origin->identity, $origin });
    }

    method union ($other) {
        Origin::Set->new( _origins => +{ %$_origins, $other->origins->%* })
    }

    method to_string {
        sprintf '{ %s }' => join ', ' => map $_->to_string, $self->origins;
    }
}

## -----------------------------------------------------------------------------

class Slot::Method {
    field $identity :param :reader;

    method merge ($other) { ... }

    method label { ... }

    method to_string {
        sprintf '`%s` := %s' => $self->identity, $self->label;
    }
}

class Required::Method :isa(Slot::Method) {

    method merge ($other) {
        return $other;
        # no need to actually do the conditionals :)
        # return $other if $other isa Required::Method;
        # return $other if $other isa Defined::Method;
        # return $other if $other isa Conflicted::Method;
    }

    method label { 'Required' }
}

class Defined::Method :isa(Slot::Method) {
    field $origin :param :reader;

    method merge ($other) {
        return $self if $other isa Required::Method;

        if ($other isa Defined::Method) {
            return $other if $origin->equal_to($other->origin);
            return Conflicted::Method->new(
                identity   => $self->identity,
                origin_set => Origin::Set->of( $origin, $other->origin )
            )
        }

        if ($other isa Conflicted::Method) {
            return Conflicted::Method->new(
                identity   => $self->identity,
                origin_set => $other->origin_set->insert( $origin )
            )
        }
    }

    method label {
        sprintf 'Defined @ %s' => $self->origin->to_string;
    }
}

class Conflicted::Method :isa(Slot::Method) {
    field $origin_set :param :reader;

    method merge ($other) {
        return $self if $other isa Required::Method;

        if ($other isa Defined::Method) {
            return Conflicted::Method->new(
                identity   => $self->identity,
                origin_set => $origin_set->insert( $other->origin )
            )
        }

        if ($other isa Conflicted::Method) {
            return Conflicted::Method->new(
                identity   => $self->identity,
                origin_set => $other->origin_set->union( $origin_set )
            )
        }
    }

    method label {
        sprintf 'Conflicted ! %s' => $self->origin_set->to_string;
    }
}

## -----------------------------------------------------------------------------

class Role {
    field $identity :param :reader;
    field $slots    :param :reader;

    ADJUST {
        @$slots = sort { $a->identity cmp $b->identity } @$slots;
    }

    method to_string {
        my $max_size = List::Util::max( map length($_->identity), @$slots );
        return join "\n" => (
            (sprintf 'role %s {' => $identity),
            (map { sprintf "  method %-${max_size}s : %s" => $_->identity, $_->label } @$slots),
            ('}'),
        )
    }
}

class ProtoRole {
    field $identity :param :reader;

    field $roles  :reader = +[];
    field $slots  :reader = +[];
    field $origin :reader;

    ADJUST {
        $origin = Origin->new( identity => $identity );
    }

    method does_role ($role) {
        push @$roles => $role;
        return $self
    }

    method require_slot ($ident) {
        push @$slots => Required::Method->new( identity => $ident );
        return $self;
    }

    method define_slot ($ident) {
        push @$slots => Defined::Method->new( identity => $ident, origin => $origin );
        return $self;
    }

    method compose {
        my @all_slots = (@$slots, map { $_->slots->@* } @$roles);

        my %composed;
        foreach my $slot (@all_slots) {
            if (exists $composed{ $slot->identity }) {
                $composed{ $slot->identity } = $composed{ $slot->identity }->merge( $slot );
            } else {
                $composed{ $slot->identity } = $slot;
            }
        }

        return Role->new(
            identity => $identity,
            slots    => +[ values %composed ]
        );
    }

    method to_string {
        my @out;
        push @out => sprintf 'ProtoRole(%s) :does(%s) {' => $identity, join ', ' => map $_->identity, @$roles;
        push @out =>(sprintf '    %s' => $_->to_string) foreach @$slots;
        push @out => '}';
        return join "\n" => @out;
    }
}


my $Eq = ProtoRole->new( identity => 'Eq' )
    ->require_slot('equal_to')
    ->define_slot('not_equal_to');

my $Comparable = ProtoRole->new( identity => 'Comparable' )
    ->does_role($Eq)
    ->require_slot('compare')
    ->define_slot('equal_to')
    ->define_slot('less_than')
    ->define_slot('less_than_or_equal_to')
    ->define_slot('greater_than')
    ->define_slot('greater_than_or_equal_to');

my $Printable = ProtoRole->new( identity => 'Printable' )
    ->require_slot('to_string');

my $Currency = ProtoRole->new( identity => 'Currency' )
    ->does_role($Comparable)
    ->does_role($Printable)
    #->define_slot('compare') # do not fulfill the reqwuirement
    ->define_slot('greater_than') # add a conflict
    ->define_slot('to_string'); # fulfill this requirement though

say $Currency->compose->to_string;









