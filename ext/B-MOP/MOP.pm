package B::MOP 0.01;

use strict;
use warnings;

require XSLoader;
XSLoader::load('B::MOP', $B::MOP::VERSION);

@B::MOP::Class::ISA  = ();
@B::MOP::Field::ISA  = ();
@B::MOP::Method::ISA = ();

1;

__END__

=head1 NAME

B::MOP - Read-only MOP introspection for the core class feature

=head1 SYNOPSIS

    use feature 'class';
    no warnings 'experimental::class';

    class Point {
        field $x :param;
        field $y :param;
        method x { $x }
        method y { $y }
    }

    use B::MOP;

    my $meta = B::MOP->for_class('Point');
    say $meta->name;            # Point

    my $super = $meta->superclass;  # B::MOP::Class or undef

    for my $field ($meta->fields) {
        say $field->name;       # $x, $y
        say $field->sigil;      # $
        say $field->param_name; # x, y
    }

    for my $method ($meta->methods) {
        say $method->name;      # x, y
        my $bcv = $method->cv;  # B::CV object
    }

=head1 DESCRIPTION

B::MOP provides read-only introspection of classes defined using Perl's
core C<class> feature. It exposes the internal C data structures as
lightweight XS wrapper objects, in the same spirit as the L<B> module
does for the Perl optree and SV internals.

This module only works with classes defined using C<use feature 'class'>.
Passing a non-class package name to C<for_class> will croak.

=head2 Entry Point

=head3 B::MOP->for_class($name_or_object)

Given a class name (string) or a blessed object reference, returns a
L<B::MOP::Class> object. Croaks if the name does not refer to a known
class, or if the package was not declared with the C<class> keyword.

=head1 B::MOP::Class

Wraps a class stash (C<HV *> with C<HvAUXf_IS_CLASS>).

=over 4

=item $class->name

Returns the class name as a string.

=item $class->superclass

Returns a C<B::MOP::Class> for the superclass, or C<undef> if there
is no superclass.

=item $class->fields

Returns a list of L<B::MOP::Field> objects for the fields declared
directly by this class (not inherited fields).

=item $class->methods

Returns a list of L<B::MOP::Method> objects for the methods declared
directly in this class's stash that have the C<CvIsMETHOD> flag set.

=item $class->adjust_blocks

Returns a list of L<B::CV> objects for the C<ADJUST> blocks defined
on this class.

=item $class->stash

Returns the underlying stash as a L<B::HV> object, for further
introspection via the B module.

=back

=head1 B::MOP::Field

Wraps a field padname (C<PADNAME *> with C<PadnameIsFIELD>).

=over 4

=item $field->name

Returns the full field name including sigil (e.g., C<$x>, C<@items>).

=item $field->sigil

Returns just the sigil character (C<$>, C<@>, or C<%>).

=item $field->fieldix

Returns the field index (position in the object's internal field array).

=item $field->class

Returns a C<B::MOP::Class> for the class that declared this field.

=item $field->param_name

Returns the C<:param> name as a string, or C<undef> if the field has
no C<:param> attribute.

=item $field->has_default

Returns true if the field has a defaulting expression.

=back

=head1 B::MOP::Method

Wraps a method CV (C<CV *> with C<CvIsMETHOD>).

=over 4

=item $method->name

Returns the method name as a string.

=item $method->class

Returns a C<B::MOP::Class> for the class this method belongs to.

=item $method->cv

Returns the underlying CV as a L<B::CV> object, for further
introspection via the B module.

=back

=head1 SEE ALSO

L<B>, L<perlclass>, L<perlclassguts>

=cut
