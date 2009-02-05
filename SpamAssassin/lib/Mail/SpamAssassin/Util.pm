# A general class for utility functions.  Please use this for
# functions that stand alone, without requiring a $self object,
# Portability functions especially.

# <@LICENSE>
# Copyright 2004 Apache Software Foundation
# 
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
# 
#     http://www.apache.org/licenses/LICENSE-2.0
# 
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
# </@LICENSE>

package Mail::SpamAssassin::Util;

use strict;
use bytes;

use vars qw (
  @ISA @EXPORT
  $AM_TAINTED
);

require Exporter;

@ISA = qw(Exporter);
@EXPORT = qw(local_tz base64_decode);

use Mail::SpamAssassin;
use Mail::SpamAssassin::Util::RegistrarBoundaries;

use Config;
use File::Spec;
use Time::Local;
use Sys::Hostname (); # don't import hostname() into this namespace!
use Fcntl;
use POSIX (); # don't import anything unless we ask explicitly!

###########################################################################

use constant HAS_MIME_BASE64 => eval { require MIME::Base64; };
use constant RUNNING_ON_WINDOWS => ($^O =~ /^(?:mswin|dos|os2)/oi);

###########################################################################

# find an executable in the current $PATH (or whatever for that platform)
{
  # Show the PATH we're going to explore only once.
  my $displayed_path = 0;

  sub find_executable_in_env_path {
    my ($filename) = @_;

    clean_path_in_taint_mode();
    if ( !$displayed_path++ ) {
      dbg("Current PATH is: ".join($Config{'path_sep'},File::Spec->path()));
    }
    foreach my $path (File::Spec->path()) {
      my $fname = File::Spec->catfile ($path, $filename);
      if ( -f $fname ) {
        if (-x $fname) {
          dbg ("executable for $filename was found at $fname");
          return $fname;
        }
        else {
          dbg("$filename was found at $fname, but isn't executable");
        }
      }
    }
    return undef;
  }
}

###########################################################################

# taint mode: delete more unsafe vars for exec, as per perlsec
{
  # We only need to clean the environment once, it stays clean ...
  my $cleaned_taint_path = 0;

  sub clean_path_in_taint_mode {
    return if ( $cleaned_taint_path++ );
    return unless am_running_in_taint_mode();

    dbg("Running in taint mode, removing unsafe env vars, and resetting PATH");

    delete @ENV{qw(IFS CDPATH ENV BASH_ENV)};

    # Go through and clean the PATH out
    my @path = ();
    my @stat;
    foreach my $dir (File::Spec->path()) {
      next unless $dir;

      $dir =~ /^(.+)$/; # untaint, then clean ( 'foo/./bar' -> 'foo/bar', etc. )
      $dir = File::Spec->canonpath($1);

      if (!File::Spec->file_name_is_absolute($dir)) {
	dbg("PATH included '$dir', which is not absolute, dropping.");
	next;
      }
      elsif (!(@stat=stat($dir))) {
	dbg("PATH included '$dir', which doesn't exist, dropping.");
	next;
      }
      elsif (!-d _) {
	dbg("PATH included '$dir', which isn't a directory, dropping.");
	next;
      }
      elsif (($stat[2]&2) != 0) {
        # World-Writable directories are considered insecure.
        # We could be more paranoid and check all of the parent directories as well,
        # but it's good for now.
	dbg("PATH included '$dir', which is world writable, dropping.");
	next;
      }

      dbg("PATH included '$dir', keeping.");
      push(@path, $dir);
    }

    $ENV{'PATH'} = join($Config{'path_sep'}, @path);
    dbg("Final PATH set to: ".$ENV{'PATH'});
  }
}

# taint mode: are we running in taint mode? 1 for yes, 0 for no.
sub am_running_in_taint_mode {
  return $AM_TAINTED if defined $AM_TAINTED;

  if ($] >= 5.008) {
    # perl 5.8 and above, ${^TAINT} is a syntax violation in 5.005
    $AM_TAINTED = eval q(no warnings q(syntax); ${^TAINT});
  }
  else {
    # older versions
    my $blank;
    for my $d ((File::Spec->curdir, File::Spec->rootdir, File::Spec->tmpdir)) {
      opendir(TAINT, $d) || next;
      $blank = readdir(TAINT);
      closedir(TAINT);
      last;
    }
    if (!(defined $blank && $blank)) {
      # these are sometimes untainted, so this is less preferable than readdir
      $blank = join('', values %ENV, $0, @ARGV);
    }
    $blank = substr($blank, 0, 0);
    # seriously mind-bending perl
    $AM_TAINTED = not eval { eval "1 || $blank" || 1 };
  }
  dbg ("running in taint mode? ". ($AM_TAINTED ? "yes" : "no"));
  return $AM_TAINTED;
}

###########################################################################

sub am_running_on_windows {
  return RUNNING_ON_WINDOWS;
}

###########################################################################

# untaint a path to a file, e.g. "/home/jm/.spamassassin/foo",
# "C:\Program Files\SpamAssassin\tmp\foo", "/home/��t/etc".
#
# TODO: this does *not* handle locales well.  We cannot use "use locale"
# and \w, since that will not detaint the data.  So instead just allow the
# high-bit chars from ISO-8859-1, none of which have special metachar
# meanings (as far as I know).
#
sub untaint_file_path {
  my ($path) = @_;

  return unless defined($path);
  return '' if ($path eq '');

  # Barry Jaspan: allow ~ and spaces, good for Windows.  Also return ''
  # if input is '', as it is a safe path.
  my $chars = '-_A-Za-z\xA0-\xFF0-9\.\@\=\+\,\/\\\:';
  my $re = qr/^\s*([$chars][${chars}~ ]*)$/o;

  if ($path =~ $re) {
    return $1;
  } else {
    warn "security: cannot untaint path: \"$path\"\n";
    return $path;
  }
}

sub untaint_hostname {
  my ($host) = @_;

  return unless defined($host);
  return '' if ($host eq '');

  # from RFC 1035, but allowing domains starting with numbers
  my $label = q/[A-Za-z\d](?:[A-Za-z\d-]{0,61}[A-Za-z\d])?/;
  my $domain = qq<$label(?:\.$label)*>;

  if (length($host) <= 255 && $host =~ /^($domain)$/) {
    return $1;
  }
  else {
    warn "security: cannot untaint hostname: \"$host\"\n";
    return $host;
  }
}

# This sub takes a scalar or a reference to an array, hash, scalar or another
# reference and recursively untaints all its values (and keys if it's a
# reference to a hash). It should be used with caution as blindly untainting
# values subverts the purpose of working in taint mode. It will return the
# untainted value if requested but to avoid unnecessary copying, the return
# value should be ignored when working on lists.
# Bad:
#  %ENV = untaint_var(\%ENV);
# Better:
#  untaint_var(\%ENV);
#
sub untaint_var {
  local ($_) = @_;
  return undef unless defined;

  unless (ref) {
    /^(.*)$/s;
    return $1;
  }
  elsif (ref eq 'ARRAY') {
    @{$_} = map { $_ = untaint_var($_) } @{$_};
    return @{$_} if wantarray;
  }
  elsif (ref eq 'HASH') {
    while (my ($k, $v) = each %{$_}) {
      if (!defined $v && $_ == \%ENV) {
	delete ${$_}{$k};
	next;
      }
      ${$_}{untaint_var($k)} = untaint_var($v);
    }
    return %{$_} if wantarray;
  }
  elsif (ref eq 'SCALAR' or ref eq 'REF') {
    ${$_} = untaint_var(${$_});
  }
  else {
    warn "Can't untaint a " . ref($_) . "!\n";
  }
  return $_;
}

###########################################################################

# timezone mappings: in case of conflicts, use RFC 2822, then most
# common and least conflicting mapping
my %TZ = (
	# standard
	'UT'   => '+0000',
	'UTC'  => '+0000',
	# US and Canada
	'NDT'  => '-0230',
	'AST'  => '-0400',
	'ADT'  => '-0300',
	'NST'  => '-0330',
	'EST'  => '-0500',
	'EDT'  => '-0400',
	'CST'  => '-0600',
	'CDT'  => '-0500',
	'MST'  => '-0700',
	'MDT'  => '-0600',
	'PST'  => '-0800',
	'PDT'  => '-0700',
	'HST'  => '-1000',
	'AKST' => '-0900',
	'AKDT' => '-0800',
	'HADT' => '-0900',
	'HAST' => '-1000',
	# Europe
	'GMT'  => '+0000',
	'BST'  => '+0100',
	'IST'  => '+0100',
	'WET'  => '+0000',
	'WEST' => '+0100',
	'CET'  => '+0100',
	'CEST' => '+0200',
	'EET'  => '+0200',
	'EEST' => '+0300',
	'MSK'  => '+0300',
	'MSD'  => '+0400',
	'MET'  => '+0100',
	'MEZ'  => '+0100',
	'MEST' => '+0200',
	'MESZ' => '+0200',
	# South America
	'BRST' => '-0200',
	'BRT'  => '-0300',
	# Australia
	'AEST' => '+1000',
	'AEDT' => '+1100',
	'ACST' => '+0930',
	'ACDT' => '+1030',
	'AWST' => '+0800',
	# New Zealand
	'NZST' => '+1200',
	'NZDT' => '+1300',
	# Asia
	'JST'  => '+0900',
	'KST'  => '+0900',
	'HKT'  => '+0800',
	'SGT'  => '+0800',
	'PHT'  => '+0800',
	# Middle East
	'IDT'  => '+0300',
	);

# month mappings
my %MONTH = (jan => 1, feb => 2, mar => 3, apr => 4, may => 5, jun => 6,
	     jul => 7, aug => 8, sep => 9, oct => 10, nov => 11, dec => 12);

sub local_tz {
  # standard method for determining local timezone
  my $time = time;
  my @g = gmtime($time);
  my @t = localtime($time);
  my $z = $t[1]-$g[1]+($t[2]-$g[2])*60+($t[7]-$g[7])*1440+($t[5]-$g[5])*525600;
  return sprintf("%+.2d%.2d", $z/60, $z%60);
}

sub parse_rfc822_date {
  my ($date) = @_;
  local ($_);
  my ($yyyy, $mmm, $dd, $hh, $mm, $ss, $mon, $tzoff);

  # make it a bit easier to match
  $_ = " $date "; s/, */ /gs; s/\s+/ /gs;

  # now match it in parts.  Date part first:
  if (s/ (\d+) (Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec) (\d{4}) / /i) {
    $dd = $1; $mon = lc($2); $yyyy = $3;
  } elsif (s/ (Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec) +(\d+) \d+:\d+:\d+ (\d{4}) / /i) {
    $dd = $2; $mon = lc($1); $yyyy = $3;
  } elsif (s/ (\d+) (Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec) (\d{2,3}) / /i) {
    $dd = $1; $mon = lc($2); $yyyy = $3;
  } else {
    dbg ("time cannot be parsed: $date");
    return undef;
  }

  # handle two and three digit dates as specified by RFC 2822
  if (defined $yyyy) {
    if (length($yyyy) == 2 && $yyyy < 50) {
      $yyyy += 2000;
    }
    elsif (length($yyyy) != 4) {
      # three digit years and two digit years with values between 50 and 99
      $yyyy += 1900;
    }
  }

  # hh:mm:ss
  if (s/ (\d?\d):(\d\d)(:(\d\d))? / /) {
    $hh = $1; $mm = $2; $ss = $4 || 0;
  }

  # numeric timezones
  if (s/ ([-+]\d{4}) / /) {
    $tzoff = $1;
  }
  # common timezones
  elsif (s/\b([A-Z]{2,4}(?:-DST)?)\b/ / && exists $TZ{$1}) {
    $tzoff = $TZ{$1};
  }
  # all other timezones are considered equivalent to "-0000"
  $tzoff ||= '-0000';

  # months
  if (exists $MONTH{$mon}) {
    $mmm = $MONTH{$mon};
  }

  $hh ||= 0; $mm ||= 0; $ss ||= 0; $dd ||= 0; $mmm ||= 0; $yyyy ||= 0;

  my $time;
  eval {		# could croak
    $time = timegm($ss, $mm, $hh, $dd, $mmm-1, $yyyy);
  };

  if ($@) {
    dbg ("time cannot be parsed: $date, $yyyy-$mmm-$dd $hh:$mm:$ss");
    return undef;
  }

  if ($tzoff =~ /([-+])(\d\d)(\d\d)$/)	# convert to seconds difference
  {
    $tzoff = (($2 * 60) + $3) * 60;
    if ($1 eq '-') {
      $time += $tzoff;
    } else {
      $time -= $tzoff;
    }
  }

  return $time;
}

sub time_to_rfc822_date {
  my($time) = @_;

  my @days = qw/Sun Mon Tue Wed Thu Fri Sat/;
  my @months = qw/Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec/;
  my @localtime = localtime($time || time);
  $localtime[5]+=1900;

  sprintf("%s, %02d %s %4d %02d:%02d:%02d %s", $days[$localtime[6]], $localtime[3],
    $months[$localtime[4]], @localtime[5,2,1,0], local_tz());
}

###########################################################################

# Some base64 decoders will remove intermediate "=" characters, others
# will stop decoding on the first "=" character, this one translates "="
# characters to null.
sub base64_decode {
  local $_ = shift;

  s/\s+//g;
  if (HAS_MIME_BASE64 && (length($_) % 4 == 0) &&
      m|^(?:[A-Za-z0-9+/=]{2,}={0,2})$|s)
  {
    # only use MIME::Base64 when the XS and Perl are both correct and quiet
    s/(=+)(?!=*$)/'A' x length($1)/ge;
    return MIME::Base64::decode_base64($_);
  }
  tr|A-Za-z0-9+/=||cd;			# remove non-base64 characters
  s/=+$//;				# remove terminating padding
  tr|A-Za-z0-9+/=| -_`|;		# translate to uuencode
  s/.$// if (length($_) % 4 == 1);	# unpack cannot cope with extra byte

  my $length;
  my $out = '';
  while ($_) {
    $length = (length >= 84) ? 84 : length;
    $out .= unpack("u", chr(32 + $length * 3/4) . substr($_, 0, $length, ''));
  }

  return $out;
}

sub qp_decode {
  local $_ = shift;

  s/\=\r?\n//gs;
  s/\=([0-9a-fA-F]{2})/chr(hex($1))/ge;
  return $_;
}

sub base64_encode {
  local $_ = shift;

  if (HAS_MIME_BASE64) {
    return MIME::Base64::encode_base64($_);
  }

  $_ = pack("u57", $_);
  s/^.//mg;
  tr| -_`|A-Za-z0-9+/A|;
  s/(A+)$/'=' x length $1/e;
  return $_;
}

###########################################################################

sub portable_getpwuid {
  if (defined &Mail::SpamAssassin::Util::_getpwuid_wrapper) {
    return Mail::SpamAssassin::Util::_getpwuid_wrapper(@_);
  }

  if (!RUNNING_ON_WINDOWS) {
    eval ' sub _getpwuid_wrapper { getpwuid($_[0]); } ';
  } else {
    dbg ("defining getpwuid() wrapper using 'unknown' as username");
    eval ' sub _getpwuid_wrapper { fake_getpwuid($_[0]); } ';
  }

  if ($@) {
    warn "Failed to define getpwuid() wrapper: $@\n";
  } else {
    return Mail::SpamAssassin::Util::_getpwuid_wrapper(@_);
  }
}

sub fake_getpwuid {
  return (
    'unknown',		# name,
    'x',		# passwd,
    $_[0],		# uid,
    0,			# gid,
    '',			# quota,
    '',			# comment,
    '',			# gcos,
    '/',		# dir,
    '',			# shell,
    '',			# expire
  );
}

###########################################################################

# Given a string, extract an IPv4 address from it.  Required, since
# we currently have no way to portably unmarshal an IPv4 address from
# an IPv6 one without kludging elsewhere.
#
sub extract_ipv4_addr_from_string {
  my ($str) = @_;

  return unless defined($str);

  if ($str =~ /\b(
			(?:1\d\d|2[0-4]\d|25[0-5]|\d\d|\d)\.
			(?:1\d\d|2[0-4]\d|25[0-5]|\d\d|\d)\.
			(?:1\d\d|2[0-4]\d|25[0-5]|\d\d|\d)\.
			(?:1\d\d|2[0-4]\d|25[0-5]|\d\d|\d)
		      )\b/ix)
  {
    if (defined $1) { return $1; }
  }

  # ignore native IPv6 addresses; currently we have no way to deal with
  # these if we could extract them, as the DNSBLs don't provide a way
  # to query them!  TODO, eventually, once IPv6 spam starts to appear ;)
  return;
}

###########################################################################
{
  my($hostname, $fq_hostname);

# get the current host's unqalified domain name (better: return whatever
# Sys::Hostname thinks out hostname is, might also be a full qualified one)
  sub hostname {
    return $hostname if defined($hostname);

    # Sys::Hostname isn't taint safe and might fall back to `hostname`. So we've
    # got to clean PATH before we may call it.
    clean_path_in_taint_mode();
    $hostname = Sys::Hostname::hostname();

    return $hostname;
  }

# get the current host's fully-qualified domain name, if possible.  If
# not possible, return the unqualified hostname.
  sub fq_hostname {
    return $fq_hostname if defined($fq_hostname);

    $fq_hostname = hostname();
    if ($fq_hostname !~ /\./) { # hostname doesn't contain a dot, so it can't be a FQDN
      my @names = grep(/^\Q${fq_hostname}.\E/o,                         # grep only FQDNs
                    map { split } (gethostbyname($fq_hostname))[0 .. 1] # from all aliases
                  );
      $fq_hostname = $names[0] if (@names); # take the first FQDN, if any 
    }

    return $fq_hostname;
  }
}

###########################################################################

sub ips_match_in_16_mask {
  my ($ipset1, $ipset2) = @_;
  my ($b1, $b2);

  foreach my $ip1 (@{$ipset1}) {
    foreach my $ip2 (@{$ipset2}) {
      next unless defined $ip1;
      next unless defined $ip2;
      next unless ($ip1 =~ /^(\d+\.\d+\.)/); $b1 = $1;
      next unless ($ip2 =~ /^(\d+\.\d+\.)/); $b2 = $1;
      if ($b1 eq $b2) { return 1; }
    }
  }

  return 0;
}

sub ips_match_in_24_mask {
  my ($ipset1, $ipset2) = @_;
  my ($b1, $b2);

  foreach my $ip1 (@{$ipset1}) {
    foreach my $ip2 (@{$ipset2}) {
      next unless defined $ip1;
      next unless defined $ip2;
      next unless ($ip1 =~ /^(\d+\.\d+\.\d+\.)/); $b1 = $1;
      next unless ($ip2 =~ /^(\d+\.\d+\.\d+\.)/); $b2 = $1;
      if ($b1 eq $b2) { return 1; }
    }
  }

  return 0;
}

###########################################################################

sub my_inet_aton { unpack("N", pack("C4", split(/\./, $_[0]))) }

###########################################################################

sub parse_content_type {
  # This routine is typically called by passing a
  # get_header("content-type") which passes all content-type headers
  # (array context).  If there are multiple Content-type headers (invalid,
  # but it happens), MUAs seem to take the last one and so that's what we
  # should do here.
  #
  my $ct = $_[-1] || 'text/plain; charset=us-ascii';

  # This could be made a bit more rigid ...
  # the actual ABNF, BTW (RFC 1521, section 7.2.1):
  # boundary := 0*69<bchars> bcharsnospace
  # bchars := bcharsnospace / " "
  # bcharsnospace :=    DIGIT / ALPHA / "'" / "(" / ")" / "+" /"_"
  #               / "," / "-" / "." / "/" / ":" / "=" / "?"
  #
  # The boundary may be surrounded by double quotes.
  # "the boundary parameter, which consists of 1 to 70 characters from
  # a set of characters known to be very robust through email gateways,
  # and NOT ending with white space.  (If a boundary appears to end with
  # white space, the white space must be presumed to have been added by
  # a gateway, and must be deleted.)"
  #
  # In practice:
  # - MUAs accept whitespace before and after the "=" character
  # - only an opening double quote seems to be needed
  # - non-quoted boundaries should be followed by space, ";", or end of line
  # - blank boundaries seem to not work
  #
  my($boundary) = $ct =~ m!\bboundary\s*=\s*("[^"]+|[^\s";]+(?=[\s;]|$))!i;

  # remove double-quotes in boundary (should only be at start and end)
  #
  $boundary =~ tr/"//d if defined $boundary;

  # Parse out the charset and name, if they exist.
  #
  my($charset) = $ct =~ /\bcharset\s*=\s*["']?(.*?)["']?(?:;|$)/i;
  my($name) = $ct =~ /\b(?:file)?name\s*=\s*["']?(.*?)["']?(?:;|$)/i;

  # Get the actual MIME type out ...
  # Note: the header content may not be whitespace unfolded, so make sure the
  # REs do /s when appropriate.
  #
  $ct =~ s/;.*$//s;                     # strip everything after first semi-colon
  $ct =~ s@^([^/]+(?:/[^/]*)?).*$@$1@s;	# only something/something ...
  $ct =~ tr/\000-\040\177-\377\042\050\051\054\056\072-\077\100\133-\135//d;    # strip inappropriate chars
  $ct = lc $ct;

  # Now that the header has been parsed, return the requested information.
  # In scalar context, just the MIME type, in array context the
  # four important data parts (type, boundary, charset, and filename).
  #
  return wantarray ? ($ct,$boundary,$charset,$name) : $ct;
}

###########################################################################

sub url_encode {
  my ($url) = @_;
  my (@characters) = split(/(\%[0-9a-fA-F]{2})/, $url);
  my (@unencoded) = ();
  my (@encoded) = ();

  foreach (@characters) {
    # escaped character set ...
    if (/\%[0-9a-fA-F]{2}/) {
      # IF it is in the range of 0x00-0x20 or 0x7f-0xff
      #    or it is one of  "<", ">", """, "#", "%",
      #                     ";", "/", "?", ":", "@", "=" or "&"
      # THEN preserve its encoding
      unless (/(20|7f|[0189a-fA-F][0-9a-fA-F])/i) {
	s/\%([2-7][0-9a-fA-F])/sprintf "%c", hex($1)/e;
	push(@unencoded, $_);
      }
    }
    # other stuff
    else {
      # 0x00-0x20, 0x7f-0xff, <, >, and " ... "
      s/([\000-\040\177-\377\074\076\042])
	  /push(@encoded, $1) && sprintf "%%%02x", unpack("C",$1)/egx;
    }
  }
  if (wantarray) {
    return(join("", @characters), join("", @unencoded), join("", @encoded));
  }
  else {
    return join("", @characters);
  }
}

###########################################################################

=item $module = first_available_module (@module_list)

Return the first module that can be successfully loaded with C<require>
from the list.  Returns C<undef> if none are available.

This is used instead of C<AnyDBM_File> as follows:

  my $module = Mail::SpamAssassin::Util::first_available_module
                        (qw(DB_File GDBM_File NDBM_File SDBM_File));
  tie %hash, $module, $path, [... args];

Note that C<SDBM_File> is guaranteed to be present, since it comes
with Perl.

=cut

sub first_available_module {
  my (@packages) = @_;
  foreach my $mod (@packages) {
    if (eval 'require '.$mod.'; 1; ') {
      return $mod;
    }
  }
  undef;
}

###########################################################################

# thanks to http://www2.picante.com:81/~gtaylor/autobuse/ for this
# code.
sub secure_tmpfile {
  my $tmpdir = Mail::SpamAssassin::Util::untaint_file_path(
                 File::Spec->tmpdir()
               );
  if (!$tmpdir) {
    die "Cannot find a temporary directory! set TMP or TMPDIR in env";
  }

  my ($reportfile,$tmpfile);
  my $umask = umask 077;
  do {
    # we do not rely on the obscurity of this name for security...
    # we use a average-quality PRG since this is all we need
    my $suffix = join ('',
                       (0..9, 'A'..'Z','a'..'z')[rand 62,
                                                 rand 62,
                                                 rand 62,
                                                 rand 62,
                                                 rand 62,
                                                 rand 62]);
    $reportfile = File::Spec->catfile(
                    $tmpdir,
                    join ('.',
                      "spamassassin",
                      $$,
                      $suffix,
                      "tmp",
                    )
                  );
    # ...rather, we require O_EXCL|O_CREAT to guarantee us proper
    # ownership of our file; read the open(2) man page.
  } while (! sysopen ($tmpfile, $reportfile, O_RDWR|O_CREAT|O_EXCL, 0600));
  umask $umask;

  return ($reportfile, $tmpfile);
}

###########################################################################

sub uri_to_domain {
  my ($uri) = @_;

  #return if ($uri =~ /^mailto:/i);	# not mailto's, please (TODO?)

  # Javascript is not going to help us, so return.
  return if ($uri =~ /^javascript:/i);

  $uri =~ s,#.*$,,gs;			# drop fragment
  $uri =~ s#^[a-z]+:/{0,2}##gsi;	# drop the protocol
  $uri =~ s,^[^/]*\@,,gs;		# username/passwd
  $uri =~ s,[/\?\&].*$,,gs;		# path/cgi params
  $uri =~ s,:\d+$,,gs;			# port

  return if $uri =~ /\%/;         # skip undecoded URIs.
  # we'll see the decoded version as well

  # keep IPs intact
  if ($uri !~ /^\d+\.\d+\.\d+\.\d+$/) { 
    # get rid of hostname part of domain, understanding delegation
    $uri = Mail::SpamAssassin::Util::RegistrarBoundaries::trim_domain($uri);

    # ignore invalid domains
    return unless
        (Mail::SpamAssassin::Util::RegistrarBoundaries::is_domain_valid($uri));
  }
  
  # $uri is now the domain only
  return lc $uri;
}

sub uri_list_canonify {
  my(@uris) = @_;

  # make sure we catch bad encoding tricks
  my @nuris = ();
  for my $uri (@uris) {
    next if $uri =~ /^mailto:/i;

    # sometimes we catch URLs on multiple lines
    $uri =~ s/\n//g;

    # URLs won't have leading/trailing whitespace
    $uri =~ s/^\s+//;
    $uri =~ s/\s+$//;

    # Make a copy so we don't trash the original
    my $nuri = $uri;

    # http:www.foo.biz -> http://www.foo.biz
    $nuri =~ s#^(https?:)/{0,2}#$1//#i;

    # http://www.foo.biz?id=3 -> http://www.foo.biz/?id=3
    $nuri =~ s/^(https?:\/\/[^\/\?]+)\?/$1\/?/;

    # deal with encoding of chars, this is just the set of printable
    # chars minus ' ' (that is, dec 33-126, hex 21-7e)
    $nuri =~ s/\&\#0*(3[3-9]|[4-9]\d|1[01]\d|12[0-6]);/sprintf "%c",$1/ge;
    $nuri =~ s/\&\#x0*(2[1-9]|[3-6][a-f0-9]|7[0-9a-e]);/sprintf "%c",hex($1)/gei;

    # deal with wierd hostname parts
    if ($nuri =~ /^(https?:\/\/)([^\/]+)(\.?\/.*)$/i) {
      my ($proto, $host, $rest) = ($1,$2,$3);

      # remove "www.fakehostname.com@" username part
      $host =~ s/^[^\@]+\@//gs;

      # deal with 'http://213.172.0x1f.13/'; decode encoded octets
      if ($host =~ /^([0-9a-fx]*\.)([0-9a-fx]*\.)([0-9a-fx]*\.)([0-9a-fx]*)$/ix)
      {
        my (@chunk) = ($1,$2,$3,$4);
        for my $octet (0 .. 3) {
          $chunk[$octet] =~ s/^0x([0-9a-f][0-9a-f])/sprintf "%d",hex($1)/gei;
        }
        my $parsed = join ('', $proto, @chunk, $rest);
        if ($parsed ne $nuri) { push(@nuris, $parsed); }
      }

      # "http://0x7f000001/"
      if ($host =~ /^0x[0-9a-f]+$/i) {
        $host =~ s/^0x([0-9a-f]+)/sprintf "%d",hex($1)/gei;
        $host = decode_ulong_to_ip ($host);
        my $parsed = join ('', $proto, $host, $rest);
        push(@nuris, $parsed);
      }

      # "http://1113343453/"
      if ($host =~ /^[0-9]+$/) {
        $host = decode_ulong_to_ip ($host);
        my $parsed = join ('', $proto, $host, $rest);
        push(@nuris, $parsed);
      }
    }

    ($nuri) = Mail::SpamAssassin::Util::url_encode($nuri);
    if ($nuri ne $uri) {
      push(@nuris, $nuri);
    }

    # deal with http redirectors.  strip off one level of redirector
    # and add back to the array.  the foreach loop will go over those
    # and deal appropriately.
    # bug 3308: redirectors like yahoo only need one '/' ... <grrr>
    if ($nuri =~ m{^https?://.+?(https?:/{0,2}.+)$}i) {
      push(@uris, $1);
    }
  }

  # remove duplicates, merge nuris and uris
  my %uris = map { $_ => 1 } @uris, @nuris;

  return keys %uris;
}

sub decode_ulong_to_ip {
  return join(".", unpack("CCCC",pack("H*", sprintf "%08lx", $_[0])));
}

###########################################################################

sub first_date {
  my (@strings) = @_;

  foreach my $string (@strings) {
    my $time = parse_rfc822_date($string);
    return $time if defined($time) && $time;
  }
  return undef;
}

sub receive_date {
  my ($header) = @_;

  $header ||= '';
  $header =~ s/\n[ \t]+/ /gs;	# fix continuation lines

  my @rcvd = ($header =~ /^Received:(.*)/img);
  my @local;
  my $time;

  if (@rcvd) {
    if ($rcvd[0] =~ /qmail \d+ invoked by uid \d+/ ||
	$rcvd[0] =~ /\bfrom (?:localhost\s|(?:\S+ ){1,2}\S*\b127\.0\.0\.1\b)/)
    {
      push @local, (shift @rcvd);
    }
    if (@rcvd && ($rcvd[0] =~ m/\bby localhost with \w+ \(fetchmail-[\d.]+/)) {
      push @local, (shift @rcvd);
    }
    elsif (@local) {
      unshift @rcvd, (shift @local);
    }
  }

  if (@rcvd) {
    $time = first_date(shift @rcvd);
    return $time if defined($time);
  }
  if (@local) {
    $time = first_date(@local);
    return $time if defined($time);
  }
  if ($header =~ /^(?:From|X-From-Line:)\s+(.+)$/im) {
    my $string = $1;
    $string .= " ".local_tz() unless $string =~ /(?:[-+]\d{4}|\b[A-Z]{2,4}\b)/;
    $time = first_date($string);
    return $time if defined($time);
  }
  if (@rcvd) {
    $time = first_date(@rcvd);
    return $time if defined($time);
  }
  if ($header =~ /^Resent-Date:\s*(.+)$/im) {
    $time = first_date($1);
    return $time if defined($time);
  }
  if ($header =~ /^Date:\s*(.+)$/im) {
    $time = first_date($1);
    return $time if defined($time);
  }

  return time;
}

###########################################################################

sub setuid_to_euid {
  return if (RUNNING_ON_WINDOWS);

  # remember the target uid, the first number is the important one
  my $touid = $>;

  if ($< != $touid) {
    dbg ("changing real uid from $< to match effective uid $touid");
    $< = $touid; # try the simple method first

    # bug 3586: Some perl versions, typically those on a BSD-based
    # platform, require RUID==EUID (and presumably == 0) before $<
    # can be changed.  So this is a kluge for us to get around the
    # typical spamd-ish behavior of: $< = 0, $> = someuid ...
    if ( $< != $touid ) {
      dbg("initial attempt to change real uid failed, trying BSD workaround");

      $> = $<;			# revert euid to ruid
      $< = $touid;		# change ruid to target
      $> = $touid;		# change euid back to target
    }

    # Check that we have now accomplished the setuid
    if ($< != $touid) {
      die "setuid $< to $touid failed!";
    }
  }
}

# helper app command-line open
sub helper_app_pipe_open {
  if (RUNNING_ON_WINDOWS) {
    return helper_app_pipe_open_windows (@_);
  } else {
    return helper_app_pipe_open_unix (@_);
  }
}

sub helper_app_pipe_open_windows {
  my ($fh, $stdinfile, $duperr2out, @cmdline) = @_;

  # use a traditional open(FOO, "cmd |")
  my $cmd = join(' ', @cmdline);
  if ($stdinfile) { $cmd .= " < '$stdinfile'"; }
  if ($duperr2out) { $cmd .= " 2>&1"; }
  return open ($fh, $cmd.'|');
}

sub helper_app_pipe_open_unix {
  my ($fh, $stdinfile, $duperr2out, @cmdline) = @_;

  # do a fork-open, so we can setuid() back
  my $pid = open ($fh, '-|');
  if (!defined $pid) {
    die "cannot fork: $!";
  }

  if ($pid != 0) {
    return $pid;          # parent process; return the child pid
  }

  # else, child process.  go setuid...
  setuid_to_euid();
  dbg ("setuid: helper proc $$: ruid=$< euid=$>");

  # now set up the fds.  due to some wierdness, we may have to ensure that we
  # *really* close the correct fd number, since some other code may have
  # redirected the meaning of STDOUT/STDIN/STDERR it seems... (bug 3649). use
  # POSIX::close() for that. it's safe to call close() and POSIX::close() on
  # the same fd; the latter is a no-op in that case.

  if (!$stdinfile) {              # < $tmpfile
    # ensure we have *some* kind of fd 0.
    $stdinfile = "/dev/null";
  }

  my $f = fileno(STDIN);
  close STDIN;

  # sanity: was that the *real* STDIN? if not, close that one too ;)
  if ($f != 0) {
    POSIX::close(0);
  }
  open STDIN, "<$stdinfile" or die "cannot open $stdinfile: $!";

  # this should be impossible; if we just closed fd 0, UNIX
  # fd behaviour dictates that the next fd opened (the new STDIN)
  # will be the lowest unused fd number, which should be 0.
  # so die with a useful error if this somehow isn't the case.
  if (fileno(STDIN) != 0) {
    die "setuid: oops: fileno(STDIN) [".fileno(STDIN)."] != 0";
  }

  # ensure STDOUT is open.  since we just created a pipe to ensure this, it has
  # to be open to that pipe, and if it isn't, something's seriously screwy.
  # Update: actually, this fails! see bug 3649 comment 37.  For some reason,
  # fileno(STDOUT) can be 0; possibly because open("-|") didn't change the fh
  # named STDOUT, instead changing fileno(1) directly.  So this is now
  # commented.
  # if (fileno(STDOUT) != 1) {
  # die "setuid: oops: fileno(STDOUT) [".fileno(STDOUT)."] != 1";
  # }

  if ($duperr2out) {             # 2>&1
    my $f = fileno(STDERR);
    close STDERR;

    # sanity: was that the *real* STDERR? if not, close that one too ;)
    if ($f != 2) {
      POSIX::close(2);
    }
    open STDERR, ">&STDOUT" or die "dup STDOUT failed: $!";

    # STDERR must be fd 2 to be useful to subprocesses! (bug 3649)
    if (fileno(STDERR) != 2) {
      die "setuid: oops: fileno(STDERR) [".fileno(STDERR)."] != 2";
    }
  }

  exec @cmdline;
  die "exec failed: $!";
}

###########################################################################

sub dbg { Mail::SpamAssassin::dbg (@_); }

1;
