#!/usr/bin/perl

use lib '.'; use lib 't';
use SATest; sa_t_init("strip2");
use Test; BEGIN { plan tests => 4 };

# ---------------------------------------------------------------------------

use File::Copy;
use File::Compare qw(compare_text);

my $INPUT = 'data/spam/002';
my $MUNGED = 'log/strip2.munged';

tstprefs ("
        $default_cf_lines
        report_safe 1
	");

# create report_safe 1 and -t output
sarun ("-L -t < $INPUT");
if (move("log/$testname.${Test::ntest}", $MUNGED)) {
  sarun ("-d < $MUNGED");
  ok(!compare_text($INPUT,"log/$testname.${Test::ntest}"));
}
else {
  warn "move failed: $!\n";
  ok(0);
}

tstprefs ("
        $default_cf_lines
        report_safe 2
	");

# create report_safe 2 output
sarun ("-L < $INPUT");
if (move("log/$testname.${Test::ntest}", $MUNGED)) {
  sarun ("-d < $MUNGED");
  ok(!compare_text($INPUT,"log/$testname.${Test::ntest}"));
}
else {
  warn "move failed: $!\n";
  ok(0);
}

tstprefs ("
        $default_cf_lines
        report_safe 0
	");

# create report_safe 0 output
sarun ("-L < $INPUT");
if (move("log/$testname.${Test::ntest}", $MUNGED)) {
  sarun ("-d < $MUNGED");
  ok(!compare_text($INPUT,"log/$testname.${Test::ntest}"));
}
else {
  warn "move failed: $!\n";
  ok(0);
}

# Work directly on regular message, as though it was not spam
sarun ("-d < $INPUT");
ok(!compare_text($INPUT,"log/$testname.${Test::ntest}"));
