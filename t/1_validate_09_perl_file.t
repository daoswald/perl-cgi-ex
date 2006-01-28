# -*- Mode: Perl; -*-

use Test::More tests => 12;
use strict;
$^W = 1;

sub print_ok {
  my ($ok, $msg) = @_;
  ok($ok, $msg);
  warn "Test failed at line ".(caller)[2]."\n" if ! $ok;
}

use_ok('CGI::Ex::Validate');

my ($v, $e);

sub validate {
  return scalar &CGI::Ex::Validate::validate(@_);
}

print_ok(1, 'Compiles');

###----------------------------------------------------------------###

### where are my samples
my $dir = __FILE__;
$dir =~ tr|\\|/|; # should probably use File::Spec
$dir =~ s|[^/]+$|../samples| || die "Couldn't determine dir";
$dir =~ s|^t/|./t/|; # to satisfy conf

### single group
$v = "$dir/perl1.pl";

$e = validate({}, $v);
print_ok($e);
$e = validate({user => 1}, $v);
print_ok(! $e);
$e = validate({user => 1, bar => 1}, $v);
print_ok($e);
$e = validate({user => 1, bar => 1, foo => 1}, $v);
print_ok(! $e);


### three groups, some with validate_if's - using arrayref
$v = "$dir/perl2.pl";

$e = validate({}, $v);
print_ok($e);

$e = validate({
  raspberry => 'tart',
}, $v);
print_ok(! $e);

$e = validate({
  foo => 1,
  raspberry => 'tart',
}, $v);
print_ok($e);

$e = validate({
  foo => 1,
  bar => 1,
  raspberry => 'tart',
}, $v);
print_ok(! $e);

$e = validate({
  foo => 1,
  bar => 1,
  hem => 1,
  raspberry => 'tart',
}, $v);
print_ok($e);

$e = validate({
  foo => 1,
  bar => 1,
  hem => 1,
  haw => 1,
  raspberry => 'tart',
}, $v);
print_ok(! $e);
