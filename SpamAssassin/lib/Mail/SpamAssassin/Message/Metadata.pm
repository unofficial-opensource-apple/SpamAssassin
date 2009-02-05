# $Id: Metadata.pm,v 1.1 2004/11/29 21:55:38 dasenbro Exp $

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

=head1 NAME

Mail::SpamAssassin::Message::Metadata - extract metadata from a message

=head1 SYNOPSIS

=head1 DESCRIPTION

This class is tasked with extracting "metadata" from messages for use as
Bayes tokens, fodder for eval tests, or other rules.  Metadata is
supplemental data inferred from the message, like the examples below.

It is held in two forms:

1. as name-value pairs of strings, presented in mail header format.  For
  example, "X-Language" => "en".  This is the general form for simple
  metadata that's useful as Bayes tokens, can be added to marked-up
  messages using "add_header", etc., such as the trusted-relay inference
  and language detection.

2. as more complex data structures on the $msg->{metadata} object.  This
  is the form used for metadata like the HTML parse data, which is stored
  there for access by eval rule code.   Because it's not simple strings,
  it's not added as a Bayes token by default (Bayes needs simple strings).

=head1 PUBLIC METHODS

=over 4

=cut

package Mail::SpamAssassin::Message::Metadata;
use strict;
use bytes;

use Mail::SpamAssassin;
use Mail::SpamAssassin::Constants qw(:sa);
use Mail::SpamAssassin::TextCat;
use Mail::SpamAssassin::Message::Metadata::Received;

=item new()

=cut

sub new {
  my ($class, $msg) = @_;
  $class = ref($class) || $class;

  my $self = {
    msg =>		$msg,
    strings =>		{ }
  };

  bless($self,$class);
  $self;
}

sub extract {
  my ($self, $msg, $main) = @_;

  # pre-chew Received headers
  $self->parse_received_headers ($main, $msg);

  # and identify the language (if we're going to do that), before we
  # run any Bayes tests, so they can use that as a token
  $self->check_language($main);

  $main->call_plugins ("extract_metadata", { msg => $msg });
}

sub finish {
  my ($self) = @_;
  delete $self->{msg};
  delete $self->{strings};
}

# ---------------------------------------------------------------------------

sub check_language {
  my ($self, $main) = @_;

  my @languages = split (' ', $main->{conf}->{ok_languages});
  if (grep { $_ eq "all" } @languages) {
    # user doesn't care what lang it's in, so return.
    # TODO: might want to have them as bayes tokens all the same, though.
    # should we add a new config setting to control that?  or make it a
    # plugin?
    return;
  }

  my $body = $self->{msg}->get_rendered_body_text_array();
  $body = join ("\n", @{$body});
  $body =~ s/^Subject://i;

  my $len = length($body);

  # truncate after 10k; that should be plenty to classify it
  if ($len > 10000) {
    substr ($body, 10000) = '';
    $len = 10000;
  }

  # note body text length, since the check_languages() eval rule also
  # uses it
  $self->{languages_body_len} = $len;

  # need about 256 bytes for reasonably accurate match (experimentally derived)
  if ($len < 256) {
    dbg("Message too short for language analysis");
    $self->{textcat_matches} = [];
    return;
  }

  my @matches = Mail::SpamAssassin::TextCat::classify($self,
                                \$body, $main->{languages_filename});

  undef $body;          # free that memory

  $self->{textcat_matches} = \@matches;
  my $matches_str = join(' ', @matches);

  # add to metadata so Bayes gets to take a look
  $self->{msg}->put_metadata ("X-Languages", $matches_str);

  dbg ("metadata: X-Languages: $matches_str");
}

# ---------------------------------------------------------------------------

#sub dbg { Mail::SpamAssassin::dbg(@_); }

1;
