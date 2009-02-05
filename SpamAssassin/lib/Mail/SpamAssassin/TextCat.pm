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

package Mail::SpamAssassin::TextCat;

use strict;
use bytes;

use vars qw(
  $opt_a $opt_f $opt_t $opt_u
);

my @nm;

# settings
$opt_a = 10;
$opt_f = 0;
$opt_t = 400;
$opt_u = 1.05;

# $opt_a  If the number of languages to be returned by &classify is larger
#         than the value of $opt_a then an empty list is returned signifying
#         that the language is unknown.
#
# $opt_f  Before sorting is performed, the ngrams which occur $opt_f times
#         or less are removed.  This can be used to speed up the program for
#         longer inputs.  For shorter inputs, this should be set to 0.
#
# $opt_t  This option indicates the maximum number of ngrams that should be
#         compared with each of the language models (note that each of those
#         models is used completely).
#
# $opt_u  &classify returns a list of the best-scoring language together with
#         all languages which are less than $opt_u times worse.  Typical
#         values are 1.05 or 1.1.

sub classify {
  my ($self, $inputptr, $languages_filename) = @_;
  my %results;
  my $maxp = $opt_t;

  # create ngrams for input
  my @unknown = create_lm($inputptr);

  # load language models once
  if (! @nm) {
    my @lm;
    my $ngram = {};
    my $rang = 1;
    dbg("Loading languages file...");

    if (!defined $languages_filename) {
      return;
    }

    open(LM, $languages_filename)
	|| die "cannot open languages: $!\n";
    local $/ = undef;
    @lm = split(/\n/, <LM>);
    close(LM);
    # create language ngram maps once
    for (@lm) {
      # look for end delimiter
      if (/^0 (.+)/) {
	$ngram->{"language"} = $1;
	push(@nm, $ngram);
	# reset for next language
	$ngram = {};
	$rang = 1;
      }
      else {
	$ngram->{$_} = $rang++;
      }
    }
  }

  # test each language
  foreach my $ngram (@nm) {
    my $language = $ngram->{"language"};
    my $i = 0;
    my $p = 0;

    # compute result for language
    for (@unknown) {
      $p += exists($ngram->{$_}) ? abs($ngram->{$_} - $i) : $maxp;
      $i++;
    }
    $results{$language} = $p;
  }
  my @results = sort { $results{$a} <=> $results{$b} } keys %results;

  my $best = $results{$results[0]};

  my @answers=(shift(@results));
  while (@results && $results{$results[0]} < ($opt_u * $best)) {
    @answers=(@answers, shift(@results));
  }
  if (@answers > $opt_a) {
    dbg("Can't determine language uniquely enough");
    return ();
  }
  else {
    dbg("Language possibly: ".join(",",@answers));
    return @answers;
  }
}

sub create_lm {
  my %ngram;
  my @sorted;

  # my $non_word_characters = qr/[0-9\s]/;
  for my $word (split(/[0-9\s]+/, ${$_[0]}))
  {
    $word = "\000" . $word . "\000";
    my $len = length($word);
    my $flen = $len;
    my $i;
    for ($i = 0; $i < $flen; $i++) {
      $len--;
      $ngram{substr($word, $i, 1)}++;
      ($len < 1) ? next : $ngram{substr($word, $i, 2)}++;
      ($len < 2) ? next : $ngram{substr($word, $i, 3)}++;
      ($len < 3) ? next : $ngram{substr($word, $i, 4)}++;
      if ($len > 3) { $ngram{substr($word, $i, 5)}++ };
    }
  }

  if ($opt_f > 0) {
    # as suggested by Karel P. de Vos <k.vos@elsevier.nl> we speed
    # up sorting by removing singletons, however I have very bad
    # results for short inputs, this way
    @sorted = sort { $ngram{$b} <=> $ngram{$a} }
		   (grep { $ngram{$_} > $opt_f } keys %ngram);
  }
  else {
    @sorted = sort { $ngram{$b} <=> $ngram{$a} } keys %ngram;
  }
  splice(@sorted, $opt_t) if (@sorted > $opt_t);

  return @sorted;
}

sub dbg { Mail::SpamAssassin::dbg (@_); }

1;
