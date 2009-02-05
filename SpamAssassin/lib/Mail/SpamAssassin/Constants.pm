# Constants used in many parts of the SpamAssassin codebase.
#
# TODO! we need to reimplement parts of the RESERVED regexp!

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

package Mail::SpamAssassin::Constants;

use vars qw (
	@BAYES_VARS @IP_VARS @SA_VARS
);

use base qw( Exporter );

@IP_VARS = qw(
	IP_IN_RESERVED_RANGE LOCALHOST IPV4_ADDRESS IP_ADDRESS
);
@BAYES_VARS = qw(
	DUMP_MAGIC DUMP_TOKEN DUMP_BACKUP 
);
# These are generic constants that may be used across several modules
@SA_VARS = qw(
	META_TEST_MIN_PRIORITY HARVEST_DNSBL_PRIORITY MBX_SEPARATOR
	MAX_BODY_LINE_LENGTH MAX_HEADER_KEY_LENGTH MAX_HEADER_VALUE_LENGTH
	MAX_HEADER_LENGTH ARITH_EXPRESSION_LEXER
);

%EXPORT_TAGS = (
	bayes => [ @BAYES_VARS ],
        ip => [ @IP_VARS ],
        sa => [ @SA_VARS ],
        all => [ @BAYES_VARS, @IP_VARS, @SA_VARS ],
);

@EXPORT_OK = ( @BAYES_VARS, @IP_VARS, @SA_VARS );

# BAYES_VARS
use constant DUMP_MAGIC  => 1;
use constant DUMP_TOKEN  => 2;
use constant DUMP_SEEN   => 4;
use constant DUMP_BACKUP => 8;

# IP_VARS
# ---------------------------------------------------------------------------
# Initialize a regexp for reserved IPs, i.e. ones that could be
# used inside a company and be the first or second relay hit by
# a message. Some companies use these internally and translate
# them using a NAT firewall. These are listed in the RBL as invalid
# originators -- which is true, if you receive the mail directly
# from them; however we do not, so we should ignore them.
# 
# sources:
#   IANA  = <http://www.iana.org/assignments/ipv4-address-space>,
#           <http://duxcw.com/faq/network/privip.htm>,
#   APIPA = <http://duxcw.com/faq/network/autoip.htm>,
#   3330  = <ftp://ftp.rfc-editor.org/in-notes/rfc3330.txt>
#   CYMRU = <http://www.cymru.com/Documents/bogon-list.html>
#
# Last update
#   2004-07-23 Daniel Quinlan - added CYMRU source, sorted, many updates
#   2004-05-22 Daniel Quinlan - removed 58/8 and 59/8
#   2004-03-08 Justin Mason - reimplemented removed code
#   2003-11-07 bug 1784 changes removed due to relicensing
#   2003-04-15 Updated - bug 1784
#   2003-04-07 Justin Mason - removed some now-assigned nets
#   2002-08-24 Malte S. Stretz - added 172.16/12, 169.254/16
#   2002-08-23 Justin Mason - added 192.168/16
#   2002-08-12 Matt Kettler - mail to SpamAssassin-devel
#              msgid:<5.1.0.14.0.20020812211512.00a33cc0@192.168.50.2>
#
use constant IP_IN_RESERVED_RANGE => qr{^(?:
# private use ranges
  192\.168|			   # 192.168/16:       Private Use (3330)
  10|				   # 10/8:             Private Use (3330)
  172\.(?:1[6-9]|2[0-9]|3[01])|	   # 172.16-172.31/16: Private Use (3330)
  169\.254|			   # 169.254/16:       Private Use (APIPA)
  127|				   # 127/8:            Private Use (localhost)
# reserved/multicast ranges
  [01257]|			   # 000-002/8, 005/8, 007/8: IANA Reserved
  2[37]|			   # 023/8, 027/8:     IANA Reserved
  3[1679]|			   # 031/8, 036/8, 037/8, 039/8: IANA Reserved
  4[129]|			   # 041/8, 042/8, 049/8: IANA Reserved
  50|				   # 050/8:            IANA Reserved
  7[1-9]|			   # 071-079/8:        IANA Reserved
  89|				   # 089/8:            IANA Reserved
  9[0-9]|			   # 090-099/8:        IANA Reserved
  1[01][0-9]|			   # 100-119/8:        IANA Reserved
  12[0-6]|			   # 126/8:            IANA Reserved
  1(?:7[3-9]|8[0-79]|90)	   # 173-187/8, 189/8, 190/8: IANA Reserved
  192\.0\.2|			   # 192.0.2/24:       Reserved (3330)
  197|				   # 197/8:            IANA Reserved
  198\.1[89]|			   # 198.18/15:        Reserved (3330)
  22[3-9]|			   # 223-239/8:        IANA Rsvd, Mcast
  23[0-9]|			   # 230-239/8:        IANA Multicast
  24[0-9]|			   # 240-249/8:        IANA Reserved
  25[0-5]			   # 255/8:            IANA Reserved
)\.}ox;

# ---------------------------------------------------------------------------
# match the various ways of saying "localhost".
# 
use constant LOCALHOST => qr/
		    (?:
		      # as a string
		      localhost(?:\.localdomain)?
		    |
		      \b(?<!:)	# ensure no "::" IPv4 marker before this one
		      # plain IPv4
		      127\.0\.0\.1 \b
		    |
		      # IPv4 mapped in IPv6
		      0{0,4} : (?:0{0,4}\:){1,2} ffff: 
		      127\.0\.0\.1 \b
		    |
		      # pure-IPv6 address
		      (?<!:)
		      (?:0{0,4}\:){0,7} 1 
		    )
		  /oxi;

# ---------------------------------------------------------------------------
# an IP address, in IPv4 format only.
#
use constant IPV4_ADDRESS => qr/\b
		    (?:1\d\d|2[0-4]\d|25[0-5]|\d\d|\d)\.
                    (?:1\d\d|2[0-4]\d|25[0-5]|\d\d|\d)\.
                    (?:1\d\d|2[0-4]\d|25[0-5]|\d\d|\d)\.
                    (?:1\d\d|2[0-4]\d|25[0-5]|\d\d|\d)
                  \b/ox;

# ---------------------------------------------------------------------------
# an IP address, in IPv4, IPv4-mapped-in-IPv6, or IPv6 format.  NOTE: cannot
# just refer to $IPV4_ADDRESS, due to perl bug reported in nesting qr//s. :(
#
use constant IP_ADDRESS => qr/
		    (?:
		      \b(?<!:)	# ensure no "::" IPv4 marker before this one
		      # plain IPv4, as above
		      (?:1\d\d|2[0-4]\d|25[0-5]|\d\d|\d)\.
		      (?:1\d\d|2[0-4]\d|25[0-5]|\d\d|\d)\.
		      (?:1\d\d|2[0-4]\d|25[0-5]|\d\d|\d)\.
		      (?:1\d\d|2[0-4]\d|25[0-5]|\d\d|\d)\b
		    |
		      # IPv4 mapped in IPv6
		      \:\: (?:[a-f0-9]{0,4}\:){0,4}
		      (?:1\d\d|2[0-4]\d|25[0-5]|\d\d|\d)\.
		      (?:1\d\d|2[0-4]\d|25[0-5]|\d\d|\d)\.
		      (?:1\d\d|2[0-4]\d|25[0-5]|\d\d|\d)\.
		      (?:1\d\d|2[0-4]\d|25[0-5]|\d\d|\d)\b
		    |
		      # a pure-IPv6 address
		      # don't use \b here, it hits on :'s
		      (?<!:)
		      (?:[a-f0-9]{0,4}\:){0,7} [a-f0-9]{0,4}
		    )
		  /oxi;

# ---------------------------------------------------------------------------

use constant META_TEST_MIN_PRIORITY => 500;
use constant HARVEST_DNSBL_PRIORITY => 500;

# regular expression that matches message separators in The University of
# Washington's MBX mailbox format
use constant MBX_SEPARATOR => qr/([\s|\d]\d-[a-zA-Z]{3}-\d{4}\s\d{2}:\d{2}:\d{2}.*),(\d+);([\da-f]{12})-(\w{8})/;
# $1 = datestamp (str)
# $2 = size of message in bytes (int)
# $3 = message status - binary (hex)
# $4 = message ID (hex)

# ---------------------------------------------------------------------------
# values used for internal message representations

# maximum byte length of lines in the body
use constant MAX_BODY_LINE_LENGTH => 2048;
# maximum byte length of a header key
use constant MAX_HEADER_KEY_LENGTH => 256;
# maximum byte length of a header value including continued lines
use constant MAX_HEADER_VALUE_LENGTH => 8192;
# maximum byte length of entire header
use constant MAX_HEADER_LENGTH => 65536;

# used for meta rules and "if" conditionals in Conf::Parser
use constant ARITH_EXPRESSION_LEXER => qr/(?:
        [\-\+\d\.]+|                            # A Number
        \w[\w\:]+|                              # Rule or Class Name
        [\(\)]|                                 # Parens
        \|\||                                   # Boolean OR
        \&\&|                                   # Boolean AND
        \^|                                     # Boolean XOR
        !|                                      # Boolean NOT
        >=?|                                    # GT or EQ
        <=?|                                    # LT or EQ
        ==|                                     # EQ
        !=|                                     # NEQ
        [\+\-\*\/]|                             # Mathematical Operator
        [\?:]                                   # ? : Operator
      )/ox;

1;
