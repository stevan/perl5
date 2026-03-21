#!/usr/bin/perl

use v5.36;
use Test::More;
use autobox;

# ============================================================================
# string.t - String role methods (CORE::Autobox::String)
# ============================================================================

# --- length ---

is("hello"->length, 5, 'length of "hello"');
is(""->length, 0, 'length of empty string');
is("a"->length, 1, 'length of single character');

# --- uc / lc ---

is("hello"->uc, "HELLO", 'uc');
is("HELLO"->lc, "hello", 'lc');
is(""->uc, "", 'uc of empty string');

# --- ucfirst / lcfirst ---

is("hello"->ucfirst, "Hello", 'ucfirst');
is("Hello"->lcfirst, "hello", 'lcfirst');
is(""->ucfirst, "", 'ucfirst of empty string');

# --- reverse ---

is("hello"->reverse, "olleh", 'reverse');
is("a"->reverse, "a", 'reverse single char');
is(""->reverse, "", 'reverse empty string');

# --- chomp ---

is("hello\n"->chomp, "hello", 'chomp removes trailing newline');
is("hello"->chomp, "hello", 'chomp with no trailing newline is identity');

# --- chop ---

is("hello"->chop, "hell", 'chop removes last character');
is("a"->chop, "", 'chop single character leaves empty string');

# --- trim ---

is("  hello  "->trim, "hello", 'trim removes leading and trailing whitespace');
is("hello"->trim, "hello", 'trim with no whitespace is identity');
is("  \t\n hello \t\n  "->trim, "hello", 'trim removes tabs and newlines');

# --- starts_with ---

ok("hello world"->starts_with("hello"), 'starts_with matching prefix');
ok(!"hello world"->starts_with("world"), 'starts_with non-matching prefix');
ok("hello"->starts_with(""), 'starts_with empty string always true');

# --- ends_with ---

ok("hello world"->ends_with("world"), 'ends_with matching suffix');
ok(!"hello world"->ends_with("hello"), 'ends_with non-matching suffix');
ok("hello"->ends_with(""), 'ends_with empty string always true');

# --- contains ---

ok("hello world"->contains("lo wo"), 'contains matching substring');
ok(!"hello world"->contains("xyz"), 'contains non-matching substring');
ok("hello"->contains(""), 'contains empty string always true');

# --- split ---

is_deeply("a,b,c"->split(","), ["a", "b", "c"], 'split with separator');
is_deeply("hello world"->split, ["hello", "world"], 'split without separator (whitespace)');
is_deeply("a::b::c"->split("::"), ["a", "b", "c"], 'split with multi-char separator');

# --- substr ---

is("hello"->substr(0, 3), "hel", 'substr with offset and length');
is("hello"->substr(2), "llo", 'substr with only offset');
is("hello"->substr(-2), "lo", 'substr with negative offset');

# --- Edge: unicode ---

is("\x{263A}"->length, 1, 'length of unicode smiley is 1');
is("\x{263A}"->reverse, "\x{263A}", 'reverse of single unicode char');

done_testing;
