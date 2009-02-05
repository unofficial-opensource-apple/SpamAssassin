# $Id: Received.pm,v 1.1 2004/11/29 21:55:39 dasenbro Exp $

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

# ---------------------------------------------------------------------------

# So, what's the difference between a trusted and untrusted Received header?
# Basically, relays we *know* are trustworthy are 'trusted', all others after
# the last one of those are 'untrusted'.
#
# We determine trust by detecting if they are inside the network ranges
# specified in 'trusted_networks'.  There is also an inference algorithm
# which determines other trusted relays without user configuration.
#
# There's another type of Received header: the semi-trusted one.  This is the
# header added by *our* MX, at the boundary of trust; we can trust the IP
# address (and possibly rDNS) in this header, but that's about it; HELO name is
# untrustworthy.  We just use this internally for now.
#
# Finally, there's also 'internal_networks'.  These are the networks that you
# control; your MXes should be included.  This way, if you specify a wide range
# of trusted hosts, a mail that is relayed from a dynamic IP address via a
# 'trusted' host will not hit RCVD_IN_DYNABLOCK.

# ---------------------------------------------------------------------------

package Mail::SpamAssassin::Message::Metadata::Received;
1;

package Mail::SpamAssassin::Message::Metadata;
use strict;
use bytes;

use Mail::SpamAssassin::Dns;
use Mail::SpamAssassin::PerMsgStatus;
use Mail::SpamAssassin::Util::RegistrarBoundaries;
use Mail::SpamAssassin::Constants qw(:ip);

use vars qw{
};

# Should trust be computed based on the MX records of hostnames used in
# HELO?  Disabled; too slow.
use constant SLOW_TRUST_BASED_ON_HELO_MXES => 0;

# ---------------------------------------------------------------------------

sub parse_received_headers {
  my ($self, $main, $msg) = @_;

  # argh.  this is only used to perform DNS lookups.
  # TODO! we need to get Dns.pm code into a class that is NOT
  # part of Mail::SpamAssassin::PerMsgStatus to avoid this crap!
  $self->{dns_pms} = Mail::SpamAssassin::PerMsgStatus->new($main, $msg);

  $self->{relays} = [ ];

  my @hdrs = $msg->get_header('Received');
  foreach my $line (@hdrs) {
    $line =~ s/\n[ \t]+/ /gs;
    $self->parse_received_line ($line);
  }

  $self->{relays_trusted} = [ ];
  $self->{num_relays_trusted} = 0;
  $self->{relays_trusted_str} = '';

  $self->{relays_untrusted} = [ ];
  $self->{num_relays_untrusted} = 0;
  $self->{relays_untrusted_str} = '';

  # now figure out what relays are trusted...
  my $trusted = $main->{conf}->{trusted_networks};
  my $internal = $main->{conf}->{internal_networks};
  my $relay;
  my $first_by;
  my $in_trusted = 1;
  my $in_internal = 1;

  if ($trusted->get_num_nets() > 0 && $internal->get_num_nets() > 0) {
    # good; we can use both reliably.
  }
  elsif ($trusted->get_num_nets() <= 0 && $internal->get_num_nets() > 0) {
    $trusted = $internal;	# use 'internal' for 'trusted'
  }
  elsif ($trusted->get_num_nets() > 0 && $internal->get_num_nets() <= 0) {
    # use 'trusted' for 'internal'; compatibility with SpamAssassin 2.60
    $internal = $trusted;
  }

  my $did_user_specify_trust = ($trusted->get_num_nets() > 0);
  my $did_user_specify_internal = ($internal->get_num_nets() > 0);

  my $IP_IN_RESERVED_RANGE = IP_IN_RESERVED_RANGE;
  my $LOCALHOST = LOCALHOST;

  while (defined ($relay = shift @{$self->{relays}}))
  {
    # trusted_networks matches?
    if ($in_trusted && $did_user_specify_trust && !$trusted->contains_ip ($relay->{ip}))
    {
      $in_trusted = 0;		# we're in deep water now
    }

    # internal_networks matches?
    if ($did_user_specify_internal) {
      if (!$internal->contains_ip ($relay->{ip})) {
	$in_internal = 0;
      }
    } else {
      # if the user didn't specify it, assume we immediately transition
      # to the external network (the internet) once we leave this host.
      $in_internal = 0;
    }

# OK, infer the trusted/untrusted handover, if we don't have real info.
# Here's the algorithm used (taken from Dan's mail):
# 
# Talking with Scott Banister (this was his idea) and Andrew Flury at
# IronPort, we came up with an alternate and easier algorithm that doesn't
# involve trees and we think should be good enough most of the time
# whenever trusted IP headers is not set.  It also has the nice property
# of being very easy to implement, but it should, of course, be tested
# out.
# 
# "first" = top Received line in the message
# 
# "public" = not a local or private IP address
# 
# "mypublicnet" = first public "by" address
# 
# 1. Ignore all Received line where the "from" IP is in mypublicnet/16
#    regardless of where they appear.  (The goal is to remove any relay
#    steps that involve your network, relying on /16 is good enough since
#    anything on your /16 is you or at worst involves your ISP.)
# 
# 2. Ignore all Received lines that contain local (127) or private (10.1,
#    etc.) IP addresses anywhere, whether "from" or "by".  (The goal
# 
# 3. The first Received line that you don't ignore is the one that
#    contains the "by" of your trusted relay and the "from" of the first
#    untrusted relay (which is used for bondedsender testing and so on).

    if ($in_trusted && !$did_user_specify_trust) {
      my $inferred_as_trusted = 0;

      # do we know what the IP addresses of the "by" host in the first
      # header is?  If not, set them from this header, since it's the
      # first one.  NOTE: this is a ref to an array, NOT a string.
      if (!defined $first_by && $self->{dns_pms}->is_dns_available()) {
	$first_by = [ $self->lookup_all_ips ($relay->{by}) ];
      }

      # if the 'from' IP addr is in a reserved net range, it's not on
      # the public internet.
      if ($relay->{ip_is_reserved}) {
	dbg ("received-header: 'from' ".$relay->{ip}." has reserved IP");
	$inferred_as_trusted = 1;
      }

      # can we use DNS?  If not, we cannot use this algorithm, as we
      # cannot lookup hostnames. :(
      # Consider the first relay trusted, and all others untrusted.
      if (!$self->{dns_pms}->is_dns_available()) {
	dbg ("received-header: cannot use DNS, do not trust any hosts from here on");
      }

      # if the 'from' IP addr shares the same class B mask (/16) as
      # the first relay found in the message, it's still on the
      # user's network.
      elsif (Mail::SpamAssassin::Util::ips_match_in_16_mask
					([ $relay->{ip} ], $first_by))
      {
	dbg ("received-header: 'from' ".$relay->{ip}." is near to first 'by'");
	$inferred_as_trusted = 1;
      }

      # if *all* of the IP addrs for the 'by' host are in a reserved net range,
      # it's not on the public internet.  Note that we should still stop if
      # only *some* of the IPs are reserved; this can happen for multi-homed
      # gateway hosts.  For example
      #
      #   PRIVATE NET    A          B    INTERNET
      #     scanner <---> gateway_MX <---> internet
      #
      # Interface A would be on a reserved net, but B would have a "public" IP
      # address.  Same can happen if the scanner runs on the gateway-MX, since
      # lookup_all_ips() will return [ public_IP_addr, 127.0.0.1 ] as the list
      # of addresses, and 127.0.0.1 is a "reserved" address. (bug 2113)

      else {
	my @ips = $self->lookup_all_ips ($relay->{by});
	my $found_non_rsvd = 0;
	my $found_rsvd = 0;
	foreach my $ip (@ips) {
	  next if ($ip =~ /^${LOCALHOST}$/o);

	  if ($ip !~ /${IP_IN_RESERVED_RANGE}/o) {
	    dbg ("received-header: 'by' ".$relay->{by}." has public IP $ip");
	    $found_non_rsvd = 1;
	  } else {
	    dbg ("received-header: 'by' ".$relay->{by}." has reserved IP $ip");
	    $found_rsvd = 1;
	  }
	}

	if ($found_rsvd && !$found_non_rsvd) {
	  dbg ("received-header: 'by' ".$relay->{by}." has no public IPs");
	  $inferred_as_trusted = 1;
	}
      }

      # if the IP address used is close to an MX for the hostname used in
      # the HELO, then it's likely to be incoming traffic.  Trust it.
      # (TODO: not 100% sure about this yet)
      # Disabled: way too slow.  Seems to be 3 times slower with this on!

      if (!$inferred_as_trusted) {
	if (SLOW_TRUST_BASED_ON_HELO_MXES) {
	  if ($self->mx_of_helo_near_ip ($relay->{helo}, $relay->{ip})) {
	    dbg ("received-header: helo $relay->{helo} is near $relay->{ip}");
	    $inferred_as_trusted = 1;
	  }
	}
      }

      if (!$inferred_as_trusted) { $in_trusted = 0; }
    }

    dbg ("received-header: relay ".$relay->{ip}.
	" trusted? ".($in_trusted ? "yes" : "no").
	" internal? ".($in_internal ? "yes" : "no"));

    if ($in_internal) {
      $relay->{internal} = 1;
    } else {
      $relay->{internal} = 0;
    }

    # be sure to mark up the as_string version for users too
    $relay->{as_string} =~ s/ intl=\d / intl=$relay->{internal} /;

    if ($in_trusted) {
      push (@{$self->{relays_trusted}}, $relay);
      $self->{relays_trusted_str} .= $relay->{as_string}." ";
    } else {
      push (@{$self->{relays_untrusted}}, $relay);
      $self->{relays_untrusted_str} .= $relay->{as_string}." ";
    }
  }
  delete $self->{relays};		# tmp, no longer needed

  # drop the temp PerMsgStatus object
  $self->{dns_pms}->finish();
  delete $self->{dns_pms};

  chop ($self->{relays_trusted_str});	# remove trailing ws
  chop ($self->{relays_untrusted_str});	# remove trailing ws

  # OK, we've now split the relay list into trusted and untrusted.

  # add the stringified representation to the message object, so Bayes
  # and rules can use it.  Note that rule_tests.t does not impl put_metadata,
  # so protect against that here.  These will not appear in the final
  # message; they're just used internally.

  if ($self->{msg}->can ("delete_header")) {
    $self->{msg}->delete_header ("X-Spam-Relays-Trusted");
    $self->{msg}->delete_header ("X-Spam-Relays-Untrusted");
 
    if ($self->{msg}->can ("put_metadata")) {
      $self->{msg}->put_metadata ("X-Spam-Relays-Trusted",
			$self->{relays_trusted_str});
      $self->{msg}->put_metadata ("X-Spam-Relays-Untrusted",
			$self->{relays_untrusted_str});
    }
  }

  # be helpful; save some cumbersome typing
  $self->{num_relays_trusted} = scalar (@{$self->{relays_trusted}});
  $self->{num_relays_untrusted} = scalar (@{$self->{relays_untrusted}});

  dbg ("metadata: X-Spam-Relays-Trusted: ".$self->{relays_trusted_str});
  dbg ("metadata: X-Spam-Relays-Untrusted: ".$self->{relays_untrusted_str});
}

sub lookup_all_ips {
  my ($self, $hostname) = @_;

  # cannot use gethostbyname without DNS :(
  if (!$self->{dns_pms}->is_dns_available()) {
    return ();
  }
  
  my @addrs = $self->{dns_pms}->lookup_a ($hostname);

  # bug 2324: this fails if the user has an /etc/hosts entry for that
  # hostname; force a DNS lookup by appending a dot, but only if there's
  # a domain in the hostname (ie. it really is likely to be in external DNS).
  # use both sets of addrs, as the /etc/hosts data is usable anyway for
  # internal relaying.
  # NOW OFF: we now force DNS use through Net::DNS

  my @ips = ();
  my %seenaddr = ();
  foreach my $addr (@addrs) {
    next if ($seenaddr{$addr});
    $seenaddr{$addr} = 1;
    push (@ips, $addr);
  }
  return @ips;
}

sub mx_of_helo_near_ip {
  my ($self, $helo, $ip) = @_;

  my $helodom = $helo;

  # TODO: should we just traverse down the chain instead of this;
  # e.g. "foo.bar.baz.co.uk" would be "bar.baz.co.uk", "baz.co.uk",
  # instead of just "baz.co.uk" straight away?
  
  if ($helo !~ /^\d+\.\d+\.\d+\.\d+$/) {
    $helodom = Mail::SpamAssassin::Util::RegistrarBoundaries::trim_domain ($helo);
  }

  my $mxes = $self->lookup_mx ($helodom);
  my @mxips = ();
  foreach my $mx (@$mxes) {
    push (@mxips, $self->lookup_all_ips ($mx));
  }
  if ($mxes && Mail::SpamAssassin::Util::ips_match_in_24_mask ([ $ip ], [ @mxips ]))
  {
    dbg ("IP address $ip is near to an MX (".join (', ', @mxips).
					") for ".$helodom);
    return 1;
  }
  return 0;
}

# ---------------------------------------------------------------------------

sub parse_received_line {
  my ($self) = shift;
  local ($_) = shift;

  s/\s+/ /gs;
  my $ip = '';
  my $helo = '';
  my $rdns = '';
  my $by = '';
  my $id = '';
  my $ident = '';
  my $envfrom = '';
  my $mta_looked_up_dns = 0;
  my $IP_ADDRESS = IP_ADDRESS;
  my $IP_IN_RESERVED_RANGE = IP_IN_RESERVED_RANGE;
  my $LOCALHOST = LOCALHOST;

  # Received: (qmail 27981 invoked by uid 225); 14 Mar 2003 07:24:34 -0000
  # Received: (qmail 84907 invoked from network); 13 Feb 2003 20:59:28 -0000
  # Received: (ofmipd 208.31.42.38); 17 Mar 2003 04:09:01 -0000
  # we don't care about this kind of gateway noise
  if (/^\(/) { return; }

  # OK -- given knowledge of most Received header formats,
  # break them down.  We have to do something like this, because
  # some MTAs will swap position of rdns and helo -- so we can't
  # simply use simplistic regexps.

  # try to catch unique message identifier
  if (/\sid\s+<?([^\s<>;]{3,})/) {
    $id = $1;
  }

  if (/^from /) {
    # try to catch enveloper senders
    if (/(?:return-path:? |envelope-(?:sender|from)[ =])(\S+)\b/i) {
      $envfrom = $1;
    }

    # bug 3236: ignore Squirrelmail injection steps.
    # from 142.169.110.122 (SquirrelMail authenticated user synapse) by
    # mail.nomis80.org with HTTP; Sat, 3 Apr 2004 10:33:43 -0500 (EST)
    if (/ \(SquirrelMail authenticated user /) {
      dbg ("received-header: ignored SquirrelMail injection: $_");
      return;
    }

    if (/\[XMail /) { # bug 3791
      # Received: from list.brainbuzz.com (63.146.189.86:23198) by mx1.yourtech.net with [XMail 1.20 ESMTP Server] id <S72E> for <jason@ellingson.org> from <bounce-cscommunity-11965901@list.cramsession.com>; Sat, 18 Sep 2004 23:17:54 -0500
      # Received: from list.brainbuzz.com (63.146.189.86:23198) by mx1.yourtech.net (209.32.147.34:25) with [XMail 1.20 ESMTP Server] id <S72E> for <jason@ellingson.org> from <bounce-cscommunity-11965901@list.cramsession.com>; Sat, 18 Sep 2004 23:17:54 -0500
      if (/^from (\S+) \((${IP_ADDRESS})(?::\d+)?\) by (\S+)(?: \(\S+\)|) with \[XMail/)
      {
	$helo = $1; $ip = $2; $by = $3;
        / id <(\S+)> / and $id = $1;
        / from <(\S+)>; / and $envfrom = $1;
        goto enough;
      }
    }

    # catch MS-ish headers here
    if (/ SMTPSVC/) {
      # MS servers using this fmt do not lookup the rDNS.
      # Received: from inet-vrs-05.redmond.corp.microsoft.com ([157.54.6.157])
      # by INET-IMC-05.redmond.corp.microsoft.com with Microsoft
      # SMTPSVC(5.0.2195.6624); Thu, 6 Mar 2003 12:02:35 -0800
      # Received: from 0 ([61.31.135.91]) by bass.bass.com.eg with Microsoft
      # SMTPSVC(5.0.2195.6713); Tue, 21 Sep 2004 08:59:06 +0300
      # Received: from 0 ([61.31.138.57] RDNS failed) by nccdi.com with 
      # Microsoft SMTPSVC(6.0.3790.0); Thu, 23 Sep 2004 08:51:06 -0700
      # Received: from tthompson ([217.35.105.172] unverified) by
      # mail.neosinteractive.com with Microsoft SMTPSVC(5.0.2195.5329);
      # Tue, 11 Mar 2003 13:23:01 +0000
      if (/^from (\S+) \(\[(${IP_ADDRESS})\][^\)]{0,40}\) by (\S+) with Microsoft SMTPSVC/) {
        $helo = $1; $ip = $2; $by = $3; goto enough;
      }

      # Received: from mail pickup service by mail1.insuranceiq.com with
      # Microsoft SMTPSVC; Thu, 13 Feb 2003 19:05:39 -0500
      if (/^from mail pickup service by (\S+) with Microsoft SMTPSVC;/) {
        return;
      }
    }

    if (/Exim/) {
      # one of the HUGE number of Exim formats :(
      # This must be scriptable.

      # Received: from [61.174.163.26] (helo=host) by sc8-sf-list1.sourceforge.net with smtp (Exim 3.31-VA-mm2 #1 (Debian)) id 18t2z0-0001NX-00 for <razor-users@lists.sourceforge.net>; Wed, 12 Mar 2003 01:57:10 -0800
      # Received: from [218.19.142.229] (helo=hotmail.com ident=yiuhyotp) by yzordderrex with smtp (Exim 3.35 #1 (Debian)) id 194BE5-0005Zh-00; Sat, 12 Apr 2003 03:58:53 +0100
      if (/^from \[(${IP_ADDRESS})\] \((.*?)\) by (\S+) /) {
	$ip = $1; my $sub = $2; $by = $3;
	$sub =~ s/helo=(\S+)// and $helo = $1;
	$sub =~ s/ident=(\S+)// and $ident = $1;
	goto enough;
      }

      # Received: from sc8-sf-list1-b.sourceforge.net ([10.3.1.13] helo=sc8-sf-list1.sourceforge.net) by sc8-sf-list2.sourceforge.net with esmtp (Exim 3.31-VA-mm2 #1 (Debian)) id 18t301-0007Bh-00; Wed, 12 Mar 2003 01:58:13 -0800
      # Received: from dsl092-072-213.bos1.dsl.speakeasy.net ([66.92.72.213] helo=blazing.arsecandle.org) by sc8-sf-list1.sourceforge.net with esmtp (Cipher TLSv1:DES-CBC3-SHA:168) (Exim 3.31-VA-mm2 #1 (Debian)) id 18lyuU-0007TI-00 for <SpamAssassin-talk@lists.sourceforge.net>; Thu, 20 Feb 2003 14:11:18 -0800
      # Received: from eclectic.kluge.net ([66.92.69.221] ident=[W9VcNxE2vKxgWHD05PJbLzIHSxcmZQ/O]) by sc8-sf-list1.sourceforge.net with esmtp (Cipher TLSv1:DES-CBC3-SHA:168) (Exim 3.31-VA-mm2 #1 (Debian)) id 18m0hT-00031I-00 for <spamassassin-talk@lists.sourceforge.net>; Thu, 20 Feb 2003 16:06:00 -0800
      if (/^from (\S+) \(\[(${IP_ADDRESS})\](:\d+)? helo=(\S+) ident=(\S+)\) by (\S+) /) {
	$rdns=$1; $ip = $2; $helo = $4; $ident = $5; $by = $6; goto enough;
      }
      # (and without ident)
      if (/^from (\S+) \(\[(${IP_ADDRESS})\](:\d+)? helo=(\S+)\) by (\S+) /) {
	$rdns=$1; $ip = $2; $helo = $4; $by = $5; goto enough;
      }

      # Received: from mail.ssccbelen.edu.pe ([216.244.149.154]) by yzordderrex
      # with esmtp (Exim 3.35 #1 (Debian)) id 18tqiz-000702-00 for
      # <jm@example.com>; Fri, 14 Mar 2003 15:03:57 +0000
      if (/^from (\S+) \(\[(${IP_ADDRESS})\](:\d+)?\) by (\S+) /) {
	# speculation: Exim uses this format when rdns==helo. TODO: verify fully
	$rdns= $1; $ip = $2; $helo = $1; $by = $4; goto enough;
      }
      if (/^from (\S+) \(\[(${IP_ADDRESS})\](:\d+)? ident=(\S+)\) by (\S+) /) {
	$rdns= $1; $ip = $2; $helo = $1; $ident = $4; $by = $5; goto enough;
      }

      # Received: from boggle.ihug.co.nz [203.109.252.209] by grunt6.ihug.co.nz
      # with esmtp (Exim 3.35 #1 (Debian)) id 18SWRe-0006X6-00; Sun, 29 Dec 
      # 2002 18:57:06 +1300
      if (/^from (\S+) \[(${IP_ADDRESS})\](:\d+)? by (\S+) /) {
	$rdns= $1; $ip = $2; $helo = $1; $by = $4; goto enough;
      }

      # else it's probably forged. fall through
    }

    # Received: from 217.137.58.28 ([217.137.58.28])
    # by webmail.ukonline.net (IMP) with HTTP
    # for <anarchyintheuk@localhost>; Sun, 11 Apr 2004 00:31:07 +0100
    if (/\bwith HTTP\b/ &&        # more efficient split up this way
        /^from (${IP_ADDRESS}) \(\[${IP_ADDRESS}\]\) by (\S+)/)
    {
      # some smarty-pants decided to fake a numeric HELO for HTTP
      # no rDNS for this format?
      $ip = $1; $by = $2; goto enough;
    }

    # Received: from ns.elcanto.co.kr (66.161.246.58 [66.161.246.58]) by
    # mail.ssccbelen.edu.pe with SMTP (Microsoft Exchange Internet Mail Service
    # Version 5.5.1960.3) id G69TW478; Thu, 13 Mar 2003 14:01:10 -0500
    if (/^from (\S+) \((\S+) \[(${IP_ADDRESS})\]\) by (\S+) with \S+ \(/) {
      $mta_looked_up_dns = 1;
      $rdns = $2; $ip = $3; $helo = $1; $by = $4; goto enough;
    }

    # from mail2.detr.gsi.gov.uk ([51.64.35.18] helo=ahvfw.dtlr.gsi.gov.uk) by mail4.gsi.gov.uk with smtp id 190K1R-0000me-00 for spamassassin-talk-admin@lists.sourceforge.net; Tue, 01 Apr 2003 12:33:46 +0100
    if (/^from (\S+) \(\[(${IP_ADDRESS})\] helo=(\S+)\) by (\S+) with /) {
      $rdns = $1; $ip = $2; $helo = $3; $by = $4;
      goto enough;
    }

    # from 12-211-5-69.client.attbi.com (<unknown.domain>[12.211.5.69]) by rwcrmhc53.attbi.com (rwcrmhc53) with SMTP id <2002112823351305300akl1ue>; Thu, 28 Nov 2002 23:35:13 +0000
    if (/^from (\S+) \(<unknown\S*>\[(${IP_ADDRESS})\]\) by (\S+) /) {
      $helo = $1; $ip = $2; $by = $3;
      goto enough;
    }

    # from attbi.com (h000502e08144.ne.client2.attbi.com[24.128.27.103]) by rwcrmhc53.attbi.com (rwcrmhc53) with SMTP id <20030222193438053008f7tee>; Sat, 22 Feb 2003 19:34:39 +0000
    if (/^from (\S+) \((\S+\.\S+)\[(${IP_ADDRESS})\]\) by (\S+) /) {
      $mta_looked_up_dns = 1;
      $helo = $1; $rdns = $2; $ip = $3; $by = $4;
      goto enough;
    }

    if (/ \(Postfix\) with/) {
      # Received: from localhost (unknown [127.0.0.1])
      # by cabbage.jmason.org (Postfix) with ESMTP id A96E18BD97
      # for <jm@localhost>; Thu, 13 Mar 2003 15:23:15 -0500 (EST)
      if ( /^from (\S+) \((\S+) \[(${IP_ADDRESS})\]\) by (\S+) / ) {
	$mta_looked_up_dns = 1;
	$helo = $1; $rdns = $2; $ip = $3; $by = $4;
	if ($rdns eq 'unknown') { $rdns = ''; }
	goto enough;
      }

      # Received: from 207.8.214.3 (unknown[211.94.164.65])
      # by puzzle.pobox.com (Postfix) with SMTP id 9029AFB732;
      # Sat,  8 Nov 2003 17:57:46 -0500 (EST)
      # (Pobox.com version: reported in bug 2745)
      if ( /^from (\S+) \((\S+)\[(${IP_ADDRESS})\]\) by (\S+) / ) {
	$mta_looked_up_dns = 1;
	$helo = $1; $rdns = $2; $ip = $3; $by = $4;
	if ($rdns eq 'unknown') { $rdns = ''; }
	goto enough;
      }
    }

    # MiB: 2003/11/29 Some qmail-ldap headers may be misinterpreted as sendmail-headers
    #      resulting in a messed-up interpretation. We have to skip sendmail tests
    #      if we find evidence that this is a qmail-ldap header.
    #
    unless (/^from .* by \S+ \(qmail-\S+\) with /) {
      #
      # sendmail:
      # Received: from mail1.insuranceiq.com (host66.insuranceiq.com [65.217.159.66] (may be forged)) by dogma.slashnull.org (8.11.6/8.11.6) with ESMTP id h2F0c2x31856 for <jm@jmason.org>; Sat, 15 Mar 2003 00:38:03 GMT
      # Received: from BAY0-HMR08.adinternal.hotmail.com (bay0-hmr08.bay0.hotmail.com [65.54.241.207]) by dogma.slashnull.org (8.11.6/8.11.6) with ESMTP id h2DBpvs24047 for <webmaster@efi.ie>; Thu, 13 Mar 2003 11:51:57 GMT
      # Received: from ran-out.mx.develooper.com (IDENT:qmailr@one.develooper.com [64.81.84.115]) by dogma.slashnull.org (8.11.6/8.11.6) with SMTP id h381Vvf19860 for <jm-cpan@jmason.org>; Tue, 8 Apr 2003 02:31:57 +0100
      # from rev.net (natpool62.rev.net [63.148.93.62] (may be forged)) (authenticated) by mail.rev.net (8.11.4/8.11.4) with ESMTP id h0KKa7d32306 for <spamassassin-talk@lists.sourceforge.net>
      #
      if (/^from (\S+) \((\S+) \[(${IP_ADDRESS})\].*\) by (\S+) \(/) {
        $mta_looked_up_dns = 1;
        $helo = $1; $rdns = $2; $ip = $3; $by = $4;
        $rdns =~ s/^IDENT:([^\@]+)\@// and $ident = $1; # remove IDENT lookups
        $rdns =~ s/^([^\@]+)\@// and $ident = $1;	# remove IDENT lookups
        goto enough;
      }
    }

    # Received: from 4wtgRl (kgbxn@[211.244.147.115]) by dogma.slashnull.org (8.11.6/8.11.6) with SMTP id h8BBsUJ18848; Thu, 11 Sep 2003 12:54:31 +0100
    if (/^from (\S+) \((\S+)\@\[(${IP_ADDRESS})\].*\) by (\S+) \(/) {
      $mta_looked_up_dns = 1;	# this one does.  there just wasn't one
      $helo = $1; $ip = $3; $by = $4;
      $ident = $2;
      goto enough;
    }

    # Received: from 213.123.174.21 by lw11fd.law11.hotmail.msn.com with HTTP;
    # Wed, 24 Jul 2002 16:36:44 GMT
    if (/by (\S+\.hotmail\.msn\.com) /) {
      $by = $1;
      /^from (\S+) / and $ip = $1;
      goto enough;
    }

    # Received: from x71-x56-x24-5.webspeed.dk (HELO niels) (69.96.3.15) by la.mx.develooper.com (qpsmtpd/0.27-dev) with SMTP; Fri, 02 Jan 2004 19:26:52 -0800
    # Received: from sc8-sf-sshgate.sourceforge.net (HELO sc8-sf-netmisc.sourceforge.net) (66.35.250.220) by la.mx.develooper.com (qpsmtpd/0.27-dev) with ESMTP; Fri, 02 Jan 2004 14:44:41 -0800
    # Received: from mx10.topofferz.net (HELO ) (69.6.60.10) by blazing.arsecandle.org with SMTP; 3 Mar 2004 20:34:38 -0000
    if (/^from (\S+) \((?:HELO|EHLO) (\S*)\) \((${IP_ADDRESS})\) by (\S+) \(qpsmtpd\/(\S+)\) with (ESMTP|SMTP)/) {
      $rdns = $1; $helo = $2; $ip = $3; $by = $4; goto enough;
    }

    # MiB (Michel Bouissou, 2003/11/16)
    # Moved some tests up because they might match on qmail tests, where this
    # is not qmail
    #
    # Received: from imo-m01.mx.aol.com ([64.12.136.4]) by eagle.glenraven.com
    # via smtpd (for [198.85.87.98]) with SMTP; Wed, 08 Oct 2003 16:25:37 -0400
    if (/^from (\S+) \(\[(${IP_ADDRESS})\]\) by (\S+) via smtpd \(for \S+\) with SMTP\(/) {
      $helo = $1; $ip = $2; $by = $3; goto enough;
    }

    # Try to match most of various qmail possibilities
    #
    # General format:
    # Received: from postfix3-2.free.fr (HELO machine.domain.com) (foobar@213.228.0.169) by totor.bouissou.net with SMTP; 14 Nov 2003 08:05:50 -0000
    #
    # "from (remote.rDNS|unknown)" is always there
    # "(HELO machine.domain.com)" is there only if HELO differs from remote rDNS.
    # HELO may be "" -- ie no string. "HELO" may also be "EHLO".  HELO string
    # may be an IP in fmt [1.2.3.4] -- do not strip [ and ], they are important.
    # "foobar@" is remote IDENT info, specified only if ident given by remote
    # Remote IP always appears between (parentheses), with or without IDENT@
    # "by local.system.domain.com" always appears
    #
    # Protocol can be different from "SMTP", i.e. "RC4-SHA encrypted SMTP" or "QMQP"
    # qmail's reported protocol shouldn't be "ESMTP", so by allowing only "with (.* )(SMTP|QMQP)"
    # we should avoid matching on some sendmailish Received: lines that reports remote IP
    # between ([218.0.185.24]) like qmail-ldap does, but use "with ESMTP".
    #
    # Normally, qmail-smtpd remote IP isn't between square brackets [], but some versions of
    # qmail-ldap seem to add square brackets around remote IP. These versions of qmail-ldap
    # use a longer format that also states the (envelope-sender <sender@domain>) and the
    # qmail-ldap version. Example:
    # Received: from unknown (HELO terpsichore.farfalle.com) (jdavid@[216.254.40.70]) (envelope-sender <jdavid@farfalle.com>) by mail13.speakeasy.net (qmail-ldap-1.03) with SMTP for <jm@jmason.org>; 12 Feb 2003 18:23:19 -0000
    #
    # Some others of the numerous qmail patches out there can also add variants of their own
    #
    # Received: from 211.245.85.228  (EHLO ) (211.245.85.228) by mta232.mail.scd.yahoo.com with SMTP; Sun, 25 Jan 2004 00:24:37 -0800
    if (/^from \S+( \((?:HELO|EHLO) \S*\))? \((\S+\@)?\[?${IP_ADDRESS}\]?\)( \(envelope-sender <\S+>\))? by \S+( \(.+\))* with (.* )?(SMTP|QMQP)/) {

       if (/^from (\S+) \((?:HELO|EHLO) ([^ \(\)]*)\) \((\S+)\@\[?(${IP_ADDRESS})\]?\)( \(envelope-sender <\S+>\))? by (\S+)/) {
         $rdns = $1; $helo = $2; $ident = $3; $ip = $4; $by = $6;
       }
       elsif (/^from (\S+) \((?:HELO|EHLO) ([^ \(\)]*)\) \(\[?(${IP_ADDRESS})\]?\)( \(envelope-sender <\S+>\))? by (\S+)/) {
         $rdns = $1; $helo = $2; $ip = $3; $by = $5;
       }
       elsif (/^from (\S+) \((\S+)\@\[?(${IP_ADDRESS})\]?\)( \(envelope-sender <\S+>\))? by (\S+)/) {
	 # note: absence of HELO means that it matched rDNS in qmail-land
         $helo = $rdns = $1; $ident = $2; $ip = $3; $by = $5;
       }
       elsif (/^from (\S+) \(\[?(${IP_ADDRESS})\]?\)( \(envelope-sender <\S+>\))? by (\S+)/) {
         $helo = $rdns = $1; $ip = $2; $by = $4;
       }
       # qmail doesn't perform rDNS requests by itself, but is usually called
       # by tcpserver or a similar daemon that passes rDNS information to qmail-smtpd.
       # If qmail puts something else than "unknown" in the rDNS field, it means that
       # it received this information from the daemon that called it. If qmail-smtpd
       # writes "Received: from unknown", it means that either the remote has no
       # rDNS, or qmail was called by a daemon that didn't gave the rDNS information.
       if ($rdns ne "unknown") {
          $mta_looked_up_dns = 1;
       } else {
          $rdns = '';
       }
       goto enough;

    }
    # /MiB
    
    # Received: from [193.220.176.134] by web40310.mail.yahoo.com via HTTP;
    # Wed, 12 Feb 2003 14:22:21 PST
    if (/^from \[(${IP_ADDRESS})\] by (\S+) via HTTP\;/) {
      $ip = $1; $by = $2; goto enough;
    }

    # Received: from 192.168.5.158 ( [192.168.5.158]) as user jason@localhost by mail.reusch.net with HTTP; Mon, 8 Jul 2002 23:24:56 -0400
    if (/^from (\S+) \( \[(${IP_ADDRESS})\]\).*? by (\S+) /) {
      # TODO: is $1 helo?
      $ip = $2; $by = $3; goto enough;
    }

    # Received: from (64.52.135.194 [64.52.135.194]) by mail.unearthed.com with ESMTP id BQB0hUH2 Thu, 20 Feb 2003 16:13:20 -0700 (PST)
    if (/^from \((\S+) \[(${IP_ADDRESS})\]\) by (\S+) /) {
      $helo = $1; $ip = $2; $by = $3; goto enough;
    }

    # Received: from [65.167.180.251] by relent.cedata.com (MessageWall 1.1.0) with SMTP; 20 Feb 2003 23:57:15 -0000
    if (/^from \[(${IP_ADDRESS})\] by (\S+) /) {
      $ip = $1; $by = $2; goto enough;
    }

    # Received: from acecomms [202.83.84.95] by mailscan.acenet.net.au [202.83.84.27] with SMTP (MDaemon.PRO.v5.0.6.R) for <spamassassin-talk@lists.sourceforge.net>; Fri, 21 Feb 2003 09:32:27 +1000
    if (/^from (\S+) \[(${IP_ADDRESS})\] by (\S+) \[(\S+)\] with /) {
      $mta_looked_up_dns = 1;
      $helo = $1; $ip = $2;
      $by = $4; # use the IP addr for "by", more useful?
      goto enough;
    }

    # Received: from mail.sxptt.zj.cn ([218.0.185.24]) by dogma.slashnull.org
    # (8.11.6/8.11.6) with ESMTP id h2FH0Zx11330 for <webmaster@efi.ie>;
    # Sat, 15 Mar 2003 17:00:41 GMT
    if (/^from (\S+) \(\[(${IP_ADDRESS})\]\) by (\S+) \(/) { # sendmail
      $mta_looked_up_dns = 1;
      $helo = $1; $ip = $2; $by = $3; goto enough;
    }

    # Received: from umr-mail7.umr.edu (umr-mail7.umr.edu [131.151.1.64]) via ESMTP by mrelay1.cc.umr.edu (8.12.1/) id h06GHYLZ022481; Mon, 6 Jan 2003 10:17:34 -0600
    # Received: from Agni (localhost [::ffff:127.0.0.1]) (TLS: TLSv1/SSLv3, 168bits,DES-CBC3-SHA) by agni.forevermore.net with esmtp; Mon, 28 Oct 2002 14:48:52 -0800
    # Received: from gandalf ([4.37.75.131]) (authenticated bits=0) by herald.cc.purdue.edu (8.12.5/8.12.5/herald) with ESMTP id g9JLefrm028228 for <spamassassin-talk@lists.sourceforge.net>; Sat, 19 Oct 2002 16:40:41 -0500 (EST)
    # Received: from bushinternet.com (softdnserr [::ffff:61.99.99.67]) by mail.cs.helsinki.fi with esmtp; Fri, 22 Aug 2003 12:25:41 +0300
    if (/^from (\S+) \((\S+) \[(${IP_ADDRESS})\]\).*? by (\S+) /) { # sendmail
      if ($2 eq 'softdnserr') {
        $mta_looked_up_dns = 0; # bug 2326: couriertcpd
      } else {
        $mta_looked_up_dns = 1; $rdns = $2;
      }
      $helo = $1; $ip = $3; $by = $4; goto enough;
    }

    if (/^from (\S+) \(\[(${IP_ADDRESS})\]\).*? by (\S+) /) {
      $mta_looked_up_dns = 1;
      $helo = $1; $ip = $2; $by = $3; goto enough;
    }

    # Received: from roissy (p573.as1.exs.dublin.eircom.net [159.134.226.61])
    # (authenticated bits=0) by slate.dublin.wbtsystems.com (8.12.6/8.12.6)
    # with ESMTP id g9MFWcvb068860 for <jm@jmason.org>;
    # Tue, 22 Oct 2002 16:32:39 +0100 (IST)
    if (/^from (\S+) \((\S+) \[(${IP_ADDRESS})\]\)(?: \(authenticated bits=\d+\))? by (\S+) \(/) { # sendmail
      $mta_looked_up_dns = 1;
      $helo = $1; $rdns = $2; $ip = $3; $by = $4; goto enough;
    }

    # Received: from cabbage.jmason.org [127.0.0.1]
    # by localhost with IMAP (fetchmail-5.9.0)
    # for jm@localhost (single-drop); Thu, 13 Mar 2003 20:39:56 -0800 (PST)
    if (/^from (\S+) \[(${IP_ADDRESS})\] by (\S+) with \S+ \(fetchmail/) {
      $self->found_pop_fetcher_sig();
      return;		# skip fetchmail handovers
    }

    # Let's try to support a few qmailish formats in one;
    # http://bugzilla.spamassassin.org/show_bug.cgi?id=2744#c14 :
    # Received: from unknown (HELO feux01a-isp) (213.199.4.210) by totor.bouissou.net with SMTP; 1 Nov 2003 07:05:19 -0000 
    # Received: from adsl-207-213-27-129.dsl.lsan03.pacbell.net (HELO merlin.net.au) (Owner50@207.213.27.129) by totor.bouissou.net with SMTP; 10 Nov 2003 06:30:34 -0000 
    if (/^from (\S+) \((?:HELO|EHLO) ([^\)]*)\) \((\S+@)?\[?(${IP_ADDRESS})\]?\).* by (\S+) /)
    {
      $mta_looked_up_dns = 1;
      $rdns = $1; $helo = $2; $ident = (defined $3) ? $3 : '';
      $ip = $4; $by = $5;
      if ($ident) { $ident =~ s/\@$//; }
      goto enough;
    }

    # Received: from x1-6-00-04-bd-d2-e0-a3.k317.webspeed.dk (benelli@80.167.158.170) by totor.bouissou.net with SMTP; 5 Nov 2003 23:18:42 -0000
    if (/^from (\S+) \((\S+@)?\[?(${IP_ADDRESS})\]?\).* by (\S+) /)
    {
      $mta_looked_up_dns = 1;
      # http://bugzilla.spamassassin.org/show_bug.cgi?id=2744 notes that
      # if HELO == rDNS, qmail drops it.
      $rdns = $1; $helo = $rdns; $ident = (defined $2) ? $2 : '';
      $ip = $3; $by = $4;
      if ($ident) { $ident =~ s/\@$//; }
      goto enough;
    }

    # Received: from [129.24.215.125] by ws1-7.us4.outblaze.com with http for
    # _bushisevil_@mail.com; Thu, 13 Feb 2003 15:59:28 -0500
    if (/^from \[(${IP_ADDRESS})\] by (\S+) with http for /) {
      $ip = $1; $by = $2; goto enough;
    }

    # Received: from po11.mit.edu [18.7.21.73]
    # by stark.dyndns.tv with POP3 (fetchmail-5.9.7)
    # for stark@localhost (single-drop); Tue, 18 Feb 2003 10:43:09 -0500 (EST)
    # by po11.mit.edu (Cyrus v2.1.5) with LMTP; Tue, 18 Feb 2003 09:49:46 -0500
    if (/^from (\S+) \[(${IP_ADDRESS})\] by (\S+) with POP3 /) {
      $rdns = $1; $ip = $2; $by = $3; goto enough;
    }

    # Received: from snake.corp.yahoo.com(216.145.52.229) by x.x.org via smap (V1.3)
    # id xma093673; Wed, 26 Mar 03 20:43:24 -0600
    if (/^from (\S+)\((${IP_ADDRESS})\) by (\S+) via smap /) {
      $mta_looked_up_dns = 1;
      $rdns = $1; $ip = $2; $by = $3; goto enough;
    }

    # Received: from smtp.greyware.com(208.14.208.51, HELO smtp.sff.net) by x.x.org via smap (V1.3)
    # id xma002908; Fri, 27 Feb 04 14:16:56 -0800
    if (/^from (\S+)\((${IP_ADDRESS}), (?:HELO|EHLO) (\S*)\) by (\S+) via smap /) {
      $mta_looked_up_dns = 1;
      $rdns = $1; $ip = $2; $helo = $3; $by = $4; goto enough;
    }

    # Received: from [192.168.0.71] by web01-nyc.clicvu.com (Post.Office MTA
    # v3.5.3 release 223 ID# 0-64039U1000L100S0V35) with SMTP id com for
    # <x@x.org>; Tue, 25 Mar 2003 11:42:04 -0500
    if (/^from \[(${IP_ADDRESS})\] by (\S+) \(Post/) {
      $ip = $1; $by = $2; goto enough;
    }

    # Received: from [127.0.0.1] by euphoria (ArGoSoft Mail Server 
    # Freeware, Version 1.8 (1.8.2.5)); Sat, 8 Feb 2003 09:45:32 +0200
    if (/^from \[(${IP_ADDRESS})\] by (\S+) \(ArGoSoft/) {
      $ip = $1; $by = $2; goto enough;
    }

    # Received: from 157.54.8.23 by inet-vrs-05.redmond.corp.microsoft.com
    # (InterScan E-Mail VirusWall NT); Thu, 06 Mar 2003 12:02:35 -0800
    if (/^from (${IP_ADDRESS}) by (\S+) \(InterScan/) {
      $ip = $1; $by = $2; goto enough;
    }

    # Received: from faerber.muc.de by slarti.muc.de with BSMTP (rsmtp-qm-ot 0.4)
    # for asrg@ietf.org; 7 Mar 2003 21:10:38 -0000
    if (/^from (\S+) by (\S+) with BSMTP/) {
      return;	# BSMTP != a TCP/IP handover, ignore it
    }

    # Received: from spike (spike.ig.co.uk [193.32.60.32]) by mail.ig.co.uk with
    # SMTP id h27CrCD03362 for <asrg@ietf.org>; Fri, 7 Mar 2003 12:53:12 GMT
    if (/^from (\S+) \((\S+) \[(${IP_ADDRESS})\]\) by (\S+) with /) {
      $mta_looked_up_dns = 1;
      $helo = $1; $rdns = $2; $ip = $3; $by = $4; goto enough;
    }

    # Received: from customer254-217.iplannetworks.net (HELO AGAMENON) 
    # (baldusi@200.69.254.217 with plain) by smtp.mail.vip.sc5.yahoo.com with
    # SMTP; 11 Mar 2003 21:03:28 -0000
    if (/^from (\S+) \((?:HELO|EHLO) (\S*)\) \((\S+).*?\) by (\S+) with /) {
      $mta_looked_up_dns = 1;
      $rdns = $1; $helo = $2; $ip = $3; $by = $4;
      $ip =~ s/([^\@]*)\@//g and $ident = $1;	# remove IDENT lookups
      goto enough;
    }

    # Received: from raptor.research.att.com (bala@localhost) by
    # raptor.research.att.com (SGI-8.9.3/8.8.7) with ESMTP id KAA14788 
    # for <asrg@example.com>; Fri, 7 Mar 2003 10:37:56 -0500 (EST)
    if (/^from (\S+) \((\S+\@\S+)\) by (\S+) \(/) { return; }

    # Received: from mmail by argon.connect.org.uk with local (connectmail/exim) id 18tOsg-0008FX-00; Thu, 13 Mar 2003 09:20:06 +0000
    if (/^from (\S+) by (\S+) with local/) { return; }

    # Received: from [192.168.1.104] (account nazgul HELO [192.168.1.104])
    # by somewhere.com (CommuniGate Pro SMTP 3.5.7) with ESMTP-TLS id 2088434;
    # Fri, 07 Mar 2003 13:05:06 -0500
    if (/^from \[(${IP_ADDRESS})\] \(account \S+ (?:HELO|EHLO) (\S*)\) by (\S+) \(/) {
      $ip = $1; $helo = $2; $by = $3; goto enough;
    }

    # Received: from ([10.0.0.6]) by mail0.ciphertrust.com with ESMTP ; Thu,
    # 13 Mar 2003 06:26:21 -0500 (EST)
    if (/^from \(\[(${IP_ADDRESS})\]\) by (\S+) with /) {
      $ip = $1; $by = $2;
    }

    # Received: from ironport.com (10.1.1.5) by a50.ironport.com with ESMTP; 01 Apr 2003 12:00:51 -0800
    # Received: from dyn-81-166-39-132.ppp.tiscali.fr (81.166.39.132) by cpmail.dk.tiscali.com (6.7.018)
    # note: must be before 'Content Technologies SMTPRS' rule, cf. bug 2787
    if (/^from ([^\d]\S+) \((${IP_ADDRESS})\) by (\S+) /) {
      $helo = $1; $ip = $2; $by = $3; goto enough;
    }

    # Received: from scv3.apple.com (scv3.apple.com) by mailgate2.apple.com (Content Technologies SMTPRS 4.2.1) with ESMTP id <T61095998e1118164e13f8@mailgate2.apple.com>; Mon, 17 Mar 2003 17:04:54 -0800
    if (/^from (\S+) \((\S+)\) by (\S+) \(/) {
      return;		# useless without the $ip anyway!
      #$helo = $1; $rdns = $2; $by = $3; goto enough;
    }

    # Received: from 01al10015010057.ad.bls.com ([90.152.5.141] [90.152.5.141])
    # by aismtp3g.bls.com with ESMTP; Mon, 10 Mar 2003 11:10:41 -0500
    if (/^from (\S+) \(\[(\S+)\] \[(\S+)\]\) by (\S+) with /) {
      # not sure what $3 is ;)
      $helo = $1; $ip = $2; $by = $4;
      goto enough;
    }

    # Received: from 206.47.0.153 by dm3cn8.bell.ca with ESMTP (Tumbleweed MMS
    # SMTP Relay (MMS v5.0)); Mon, 24 Mar 2003 19:49:48 -0500
    if (/^from (${IP_ADDRESS}) by (\S+) with /) {
      $ip = $1; $by = $2;
      goto enough;
    }

    # Received: from pobox.com (h005018086b3b.ne.client2.attbi.com[66.31.45.164])
    # by rwcrmhc53.attbi.com (rwcrmhc53) with SMTP id <2003031302165605300suph7e>;
    # Thu, 13 Mar 2003 02:16:56 +0000
    if (/^from (\S+) \((\S+)\[(${IP_ADDRESS})\]\) by (\S+) /) {
      $mta_looked_up_dns = 1;
      $helo = $1; $rdns = $2; $ip = $3; $by = $4; goto enough;
    }

    # Received: from [10.128.128.81]:50999 (HELO dfintra.f-secure.com) by fsav4im2 ([10.128.128.74]:25) (F-Secure Anti-Virus for Internet Mail 6.0.34 Release) with SMTP; Tue, 5 Mar 2002 14:11:53 -0000
    if (/^from \[(${IP_ADDRESS})\]\S+ \((?:HELO|EHLO) (\S*)\) by (\S+) /) {
      $ip = $1; $helo = $2; $by = $3; goto enough;
    }

    # Received: from 62.180.7.250 (HELO daisy) by smtp.altavista.de (209.228.22.152) with SMTP; 19 Sep 2002 17:03:17 +0000
    if (/^from (${IP_ADDRESS}) \((?:HELO|EHLO) (\S*)\) by (\S+) /) {
      $ip = $1; $helo = $2; $by = $3; goto enough;
    }

    # Received: from oemcomputer [63.232.189.195] by highstream.net (SMTPD32-7.07) id A4CE7F2A0028; Sat, 01 Feb 2003 21:39:10 -0500
    if (/^from (\S+) \[(${IP_ADDRESS})\] by (\S+) /) {
      $helo = $1; $ip = $2; $by = $3; goto enough;
    }

    # from nodnsquery(192.100.64.12) by herbivore.monmouth.edu via csmap (V4.1) id srcAAAyHaywy
    if (/^from (\S+)\((${IP_ADDRESS})\) by (\S+) /) {
      $rdns = $1; $ip = $2; $by = $3; goto enough;
    }

    # Received: from [192.168.0.13] by <server> (MailGate 3.5.172) with SMTP;
    # Tue, 1 Apr 2003 15:04:55 +0100
    if (/^from \[(${IP_ADDRESS})\] by (\S+) \(MailGate /) {
      $ip = $1; $by = $2; goto enough;
    }

    # Received: from jmason.org (unverified [195.218.107.131]) by ni-mail1.dna.utvinternet.net <B0014212518@ni-mail1.dna.utvinternet.net>; Tue, 11 Feb 2003 12:18:12 +0000
    if (/^from (\S+) \(unverified \[(${IP_ADDRESS})\]\) by (\S+) /) {
      $helo = $1; $ip = $2; $by = $3; goto enough;
    }

    # # from 165.228.131.11 (proxying for 139.130.20.189) (SquirrelMail authenticated user jmmail) by jmason.org with HTTP
    # if (/^from (\S+) \(proxying for (${IP_ADDRESS})\) \([A-Za-z][^\)]+\) by (\S+) with /) {
    # $ip = $2; $by = $3; goto enough;
    # }
    if (/^from (${IP_ADDRESS}) \([A-Za-z][^\)]+\) by (\S+) with /) {
      $ip = $1; $by = $2; goto enough;
    }

    # Received: from [212.87.144.30] (account seiz [212.87.144.30] verified) by x.imd.net (CommuniGate Pro SMTP 4.0.3) with ESMTP-TLS id 5026665 for spamassassin-talk@lists.sourceforge.net; Wed, 15 Jan 2003 16:27:05 +0100
    if (/^from \[(${IP_ADDRESS})\] \([^\)]+\) by (\S+) /) {
      $ip = $1; $by = $2; goto enough;
    }

    # Received: from mtsbp606.email-info.net (?dXqpg3b0hiH9faI2OxLT94P/YKDD3rQ1?@64.253.199.166) by kde.informatik.uni-kl.de with SMTP; 30 Apr 2003 15:06:29
    if (/^from (\S+) \((?:\S+\@)?(${IP_ADDRESS})\) by (\S+) with /) {
      $rdns = $1; $ip = $2; $by = $3; goto enough;
    }
  }

  # ------------------------------------------------------------------------
  # IGNORED LINES: generally local-to-local or non-TCP/IP handovers

  # from qmail-scanner-general-admin@lists.sourceforge.net by alpha by uid 7791 with qmail-scanner-1.14 (spamassassin: 2.41. Clear:SA:0(-4.1/5.0):. Processed in 0.209512 secs)
  if (/^from \S+\@\S+ by \S+ by uid \S+ /) { return; }

  # Received: by x.x.org (bulk_mailer v1.13); Wed, 26 Mar 2003 20:44:41 -0600
  if (/^by (\S+) \(bulk_mailer /) { return; }

  # Received: from DSmith1204@aol.com by imo-m09.mx.aol.com (mail_out_v34.13.) id 7.53.208064a0 (4394); Sat, 11 Jan 2003 23:24:31 -0500 (EST)
  if (/^from \S+\@\S+ by \S+ /) { return; }

  # Received: from Unknown/Local ([?.?.?.?]) by mailcity.com; Fri, 17 Jan 2003 15:23:29 -0000
  if (/^from Unknown\/Local \(/) { return; }

  # Received: by SPIDERMAN with Internet Mail Service (5.5.2653.19) id <19AF8VY2>; Tue, 25 Mar 2003 11:58:27 -0500
  if (/^by \S+ with Internet Mail Service \(/) { return; }

  # Received: by oak.ein.cz (Postfix, from userid 1002) id DABBD1BED3;
  # Thu, 13 Feb 2003 14:02:21 +0100 (CET)
  if (/^by (\S+) \(Postfix, from userid /) { return; }

  # Received: from localhost (mailnull@localhost) by x.org (8.12.6/8.9.3) 
  # with SMTP id h2R2iivG093740; Wed, 26 Mar 2003 20:44:44 -0600 
  # (CST) (envelope-from x@x.org)
  # Received: from localhost (localhost [127.0.0.1]) (uid 500) by mail with local; Tue, 07 Jan 2003 11:40:47 -0600
  if (/^from ${LOCALHOST} \((?:\S+\@)?${LOCALHOST}[\) ]/) { return; }

  # Received: from olgisoft.com (127.0.0.1) by 127.0.0.1 (EzMTS MTSSmtp
  # 1.55d5) ; Thu, 20 Mar 03 10:06:43 +0100 for <asrg@ietf.org>
  if (/^from \S+ \((?:\S+\@)?${LOCALHOST}\) /) { return; }

  # Received: from casper.ghostscript.com (raph@casper [127.0.0.1]) h148aux8016336verify=FAIL); Tue, 4 Feb 2003 00:36:56 -0800
  # TODO: could use IPv6 localhost
  if (/^from (\S+) \(\S+\@\S+ \[127\.0\.0\.1\]\) /) { return; }

  # Received: from (AUTH: e40a9cea) by vqx.net with esmtp (courier-0.40) for <asrg@ietf.org>; Mon, 03 Mar 2003 14:49:28 +0000
  if (/^from \(AUTH: (\S+)\) by (\S+) with /) { return; }

  # Received: by faerber.muc.de (OpenXP/32 v3.9.4 (Win32) alpha @
  # 2003-03-07-1751d); 07 Mar 2003 22:10:29 +0000
  # ignore any lines starting with "by", we want the "from"s!
  if (/^by \S+ /) { return; }

  # Received: FROM ca-ex-bridge1.nai.com BY scwsout1.nai.com ;
  # Fri Feb 07 10:18:12 2003 -0800
  if (/^FROM \S+ BY \S+ \; /) { return; }

  # Received: from andrew by trinity.supernews.net with local (Exim 4.12)
  # id 18xeL6-000Dn1-00; Tue, 25 Mar 2003 02:39:00 +0000
  # Received: from CATHY.IJS.SI by CATHY.IJS.SI (PMDF V4.3-10 #8779) id <01KTSSR50NSW001MXN@CATHY.IJS.SI>; Fri, 21 Mar 2003 20:50:56 +0100
  # Received: from MATT_LINUX by hippo.star.co.uk via smtpd (for mail.webnote.net [193.120.211.219]) with SMTP; 3 Jul 2002 15:43:50 UT
  # Received: from cp-its-ieg01.mail.saic.com by cpmx.mail.saic.com for me@jmason.org; Tue, 23 Jul 2002 14:09:10 -0700
  if (/^from \S+ by \S+ (?:with|via|for|\()/) { return; }

  # Received: from virtual-access.org by bolero.conactive.com ; Thu, 20 Feb 2003 23:32:58 +0100
  if (/^from (\S+) by (\S+) *\;/) {
    return;	# can't trust this
  }

  # Received: Message by Barricade wilhelm.eyp.ee with ESMTP id h1I7hGU06122 for <spamassassin-talk@lists.sourceforge.net>; Tue, 18 Feb 2003 09:43:16 +0200
  if (/^Message by /) {
    return;	# whatever
  }

  # ------------------------------------------------------------------------
  # FALL-THROUGH: OK, let's try some general patterns
  if (/\bhelo=([-A-Za-z0-9\.]+)[^-A-Za-z0-9\.]/) { $helo = $1; }
  elsif (/^from (\S+)[^-A-Za-z0-9\.]/) { $helo = $1; }
  if (/\[(${IP_ADDRESS})\]/) { $ip = $1; }
  if (/ by (\S+)[^-A-Za-z0-9\;\.]/) { $by = $1; }
  if ($ip && $by) { goto enough; }

  # ------------------------------------------------------------------------
  # OK, if we still haven't figured out at least the basics (IP and by), or
  # returned due to it being a known-crap format, let's warn so the user can
  # file a bug report or something.

  dbg ("received-header: unknown format: $_");
  # and skip the line entirely!  We can't parse it...
  return;

  # ------------------------------------------------------------------------
  # OK, line parsed (at least partially); now deal with the contents

enough:

  # flag handovers we couldn't get an IP address from at all
  if ($ip eq '') {
    dbg ("received-header: could not parse IP address from: $_");
  }

  $ip = Mail::SpamAssassin::Util::extract_ipv4_addr_from_string ($ip);
  if (!$ip) {
    dbg ("received-header: could not parse IPv4 address, assuming IPv6");
    return;   # ignore IPv6 handovers
  }

  # DISABLED: if we cut out localhost-to-localhost SMTP handovers,
  # we will give FPs on SPF checks -- since the SMTP "MAIL FROM" addr
  # will be recorded, but we won't have the relays handover recorded
  # for that SMTP transaction, so we wind up checking the wrong IP
  # for the addr.
  if (0) {
    if ($ip eq '127.0.0.1') {
      dbg ("received-header: ignoring localhost handover");
      return;   # ignore localhost handovers
    }
  }

  if ($rdns =~ /^unknown$/i) {
    $rdns = '';		# some MTAs seem to do this
  }

  $envfrom =~ s/^\s*<*//gs; $envfrom =~ s/>*\s*$//gs;
  $by =~ s/\;$//;

  # ensure invalid chars are stripped.  Replace with '!' to flag their
  # presence, though.  NOTE: this means "[1.2.3.4]" IP addr HELO
  # strings, which are legit by RFC-2821, look like "!1.2.3.4!".
  # still useful though.
  $ip =~ s/[\s\0\#\[\]\(\)\<\>\|]/!/gs;
  $rdns =~ s/[\s\0\#\[\]\(\)\<\>\|]/!/gs;
  $helo =~ s/[\s\0\#\[\]\(\)\<\>\|]/!/gs;
  $by =~ s/[\s\0\#\[\]\(\)\<\>\|]/!/gs;
  $ident =~ s/[\s\0\#\[\]\(\)\<\>\|]/!/gs;
  $envfrom =~ s/[\s\0\#\[\]\(\)\<\>\|]/!/gs;

  my $relay = {
    ip => $ip,
    by => $by,
    helo => $helo,
    id => $id,
    ident => $ident,
    envfrom => $envfrom,
    lc_by => (lc $by),
    lc_helo => (lc $helo)
  };

  # perform rDNS check if MTA has not done it for us.
  #
  # TODO: do this for untrusted headers anyway; if it mismatches it
  # could be a spamsign.  Probably better done later after we've
  # moved the "trusted" ones out of the way.  In fact, this op
  # here may be movable too; no need to lookup trusted IPs all the time.
  #
  if ($rdns eq '') {
    if (!$self->{dns_pms}->is_dns_available()) {
      if ($mta_looked_up_dns) {
	# we know the MTA always does lookups, so this means the host
	# really has no rDNS (rather than that the MTA didn't bother
	# looking it up for us).
	$relay->{no_reverse_dns} = 1;
	$rdns = '';
      } else {
	$relay->{rdns_not_in_headers} = 1;
      }

    } else {
      $rdns = $self->{dns_pms}->lookup_ptr ($ip);

      if (!$rdns) {
	$relay->{no_reverse_dns} = 1;
	$rdns = '';
      }
    }
  }
  $relay->{rdns} = $rdns;
  $relay->{lc_rdns} = lc $rdns;

  # as-string rep. use spaces so things like Bayes can tokenize them easily.
  # NOTE: when tokenizing or matching, be sure to note that new
  # entries may be added to this string later.   However, the *order*
  # of entries must be preserved, so that regexps that assume that
  # e.g. "ip" comes before "helo" will still work.
  #
  my $asstr = "[ ip=$ip rdns=$rdns helo=$helo by=$by ident=$ident envfrom=$envfrom intl=0 id=$id ]";
  dbg ("received-header: parsed as $asstr");
  $relay->{as_string} = $asstr;

  my $isrsvd = ($ip =~ /${IP_IN_RESERVED_RANGE}/o);
  $relay->{ip_is_reserved} = $isrsvd;

  # add it to an internal array so Eval tests can use it
  push (@{$self->{relays}}, $relay);
}

# restart the parse if we find a fetchmail marker or similar.
# spamcop does this, and it's a great idea ;)
sub found_pop_fetcher_sig {
  my ($self) = @_;
  dbg ("found fetchmail marker, restarting parse");
  $self->{relays} = [ ];
}

sub dbg { Mail::SpamAssassin::dbg(@_); }

# ---------------------------------------------------------------------------

1;
