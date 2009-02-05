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

package Mail::SpamAssassin::Locker::Win32;

use strict;
use bytes;
use Fcntl;

use Mail::SpamAssassin;
use Mail::SpamAssassin::Locker;
use Mail::SpamAssassin::Util;
use File::Spec;
use Time::Local;

use vars qw{
  @ISA 
};

@ISA = qw(Mail::SpamAssassin::Locker);

###########################################################################

sub new {
  my $class = shift;
  my $self = $class->SUPER::new(@_);
  $self;
}

###########################################################################

use constant LOCK_MAX_AGE => 600;       # seconds 

sub safe_lock {
  my ($self, $path, $max_retries) = @_;
  my @stat;

  $max_retries ||= 30;

  my $lock_file = "$path.lock";

  if (-e $lock_file && -M $lock_file > (LOCK_MAX_AGE / 86400)) {
    dbg("lock: $$ breaking stale lock: $lock_file");
    unlink($lock_file) || warn "lock: $$ unlink of lock file $lock_file failed: $!\n";
  }
  for (my $retries = 0; $retries < $max_retries; $retries++) {
    if ($retries > 0) {
      sleep(1);
      # TODO: $self->jittery_one_second_sleep();?
    }
    dbg("lock: $$ trying to get lock on $path with $retries retries");
    if (sysopen(LOCKFILE, $lock_file, O_RDWR|O_CREAT|O_EXCL)) {
      dbg("lock: $$ link to $lock_file: sysopen ok");
      close(LOCKFILE);
      return 1;
    }
    my @stat = stat($lock_file);
    # check age of lockfile ctime
    my $age = ($#stat < 11 ? undef : $stat[10]);
    if ((!defined($age) && $retries > $max_retries / 2) ||
	(defined($age) && (time - $age > LOCK_MAX_AGE)))
    {
      dbg("lock: $$ breaking stale lock: $lock_file");
      unlink ($lock_file) || warn "lock: $$ unlink of lock file $lock_file failed: $!\n";
    }
  }
  return 0;
}

###########################################################################

sub safe_unlock {
  my ($self, $path) = @_;

  unlink ("$path.lock") || warn "unlock: $$ unlink failed: $path.lock\n";
  dbg("unlock: $$ unlink $path.lock");
}

###########################################################################

sub refresh_lock {
  my($self, $path) = @_;

  return unless $path;

  # this could arguably read the lock and make sure the same process
  # owns it, but this shouldn't, in theory, be an issue.
  utime time, time, "$path.lock";

  dbg("refresh: $$ refresh $path.lock");
}

###########################################################################


sub dbg { Mail::SpamAssassin::dbg (@_); }

1;
