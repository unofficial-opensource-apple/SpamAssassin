# $Id: HTML.pm,v 1.2 2004/11/29 21:34:14 dasenbro Exp $

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

# HTML decoding TODOs
# - add URIs to list for faster URI testing

use strict;
use bytes;

package Mail::SpamAssassin::HTML;

require Exporter;
my @ISA = qw(Exporter);
my @EXPORT = qw($re_start $re_loose $re_strict get_results);
my @EXPORT_OK = qw();

use HTML::Parser 3.24 ();
use vars qw($re_start $re_loose $re_strict $re_other);

# elements that trigger HTML rendering in text/plain in some mail clients
# (repeats ones listed in $re_strict)
$re_start = 'body|head|html|img|pre|table|title';

# elements defined by the HTML 4.01 and XHTML 1.0 DTDs (do not change them!)
$re_loose = 'applet|basefont|center|dir|font|frame|frameset|iframe|isindex|menu|noframes|s|strike|u';
$re_strict = 'a|abbr|acronym|address|area|b|base|bdo|big|blockquote|body|br|button|caption|cite|code|col|colgroup|dd|del|dfn|div|dl|dt|em|fieldset|form|h1|h2|h3|h4|h5|h6|head|hr|html|i|img|input|ins|kbd|label|legend|li|link|map|meta|noscript|object|ol|optgroup|option|p|param|pre|q|samp|script|select|small|span|strong|style|sub|sup|table|tbody|td|textarea|tfoot|th|thead|title|tr|tt|ul|var';

# loose list of HTML events
my $events = 'on(?:activate|afterupdate|beforeactivate|beforecopy|beforecut|beforedeactivate|beforeeditfocus|beforepaste|beforeupdate|blur|change|click|contextmenu|controlselect|copy|cut|dblclick|deactivate|errorupdate|focus|focusin|focusout|help|keydown|keypress|keyup|load|losecapture|mousedown|mouseenter|mouseleave|mousemove|mouseout|mouseover|mouseup|mousewheel|move|moveend|movestart|paste|propertychange|readystatechange|reset|resize|resizeend|resizestart|select|submit|timeerror|unload)';

# other non-standard tags
$re_other = 'o:\w+/?|x-sigsep|x-tab';

# attributes: HTML 4.01 deprecated, loose DTD, frameset DTD
my $re_attr = 'abbr|accept-charset|accept|accesskey|action|align|alink|alt|archive|axis|background|bgcolor|border|cellpadding|cellspacing|char|charoff|charset|checked|cite|class|classid|clear|code|codebase|codetype|color|cols|colspan|compact|content|coords|data|datetime|declare|defer|dir|disabled|enctype|face|for|frame|frameborder|headers|height|href|hreflang|hspace|http-equiv|id|ismap|label|lang|language|link|longdesc|marginheight|marginwidth|maxlength|media|method|multiple|name|nohref|noresize|noshade|nowrap|object|onblur|onchange|onclick|ondblclick|onfocus|onkeydown|onkeypress|onkeyup|onload|onmousedown|onmousemove|onmouseout|onmouseover|onmouseup|onreset|onselect|onsubmit|onunload|profile|prompt|readonly|rel|rev|rows|rowspan|rules|scheme|scope|scrolling|selected|shape|size|span|src|standby|start|style|summary|tabindex|target|text|title|type|usemap|valign|value|valuetype|version|vlink|vspace|width';

# attributes: stuff we accept
my $re_attr_extra = 'family|wrap|/';

# style attribute not accepted
my $re_attr_no_style = 'base|basefont|head|html|meta|param|script|style|title';

# style attributes
my %ok_attribute = (
		 text => [qw(body)],
		 color => [qw(basefont font)],
		 bgcolor => [qw(body table tr td th marquee)],
		 face => [qw(basefont font)],
		 size => [qw(basefont font)],
		 link => [qw(body)],
		 alink => [qw(body)],
		 vlink => [qw(body)],
		 background => [qw(body marquee)],
		 );

my %tested_colors;

sub new {
  my $this = shift;
  my $class = ref($this) || $this;
  my $self = {};
  bless($self, $class);

  $self->html_start();

  return $self;
}

sub html_start {
  my ($self) = @_;

  $self->{basefont} = 3;

  undef $self->{text_style};
  my %default = (tag => "default",
		 fgcolor => "#000000",
		 bgcolor => "#ffffff",
		 size => $self->{basefont});
  push @{ $self->{text_style} }, \%default;
}

sub html_end {
  my ($self) = @_;

  $self->display_text();
}

sub get_results {
  my ($self) = @_;

  return $self->{html};
}

sub html_render {
  my ($self, $text) = @_;

  # clean this up later
  for my $key (keys %{ $self->{html} }) {
    delete $self->{html}{$key};
  }

  $self->{html}{ratio} = 0;
  $self->{html}{image_area} = 0;
  $self->{html}{shouting} = 0;
  $self->{html}{max_shouting} = 0;
  $self->{html}{anchor_index} = -1;
  $self->{html}{title_index} = -1;
  $self->{html}{max_size} = 3;	# start at default size
  $self->{html}{min_size} = 3;	# start at default size

  $self->{html_text} = [];
  $self->{html_visible_text} = [];
  $self->{html_invisible_text} = [];
  $self->{last_text} = "";
  $self->{last_visible_text} = "";
  $self->{last_invisible_text} = "";
  $self->{html_last_tag} = 0;
  $self->{html}{closed_html} = 0;
  $self->{html}{closed_body} = 0;

  $self->{html}{length} += $1 if (length($text) =~ m/^(\d+)$/);	# untaint

  # NOTE: We *only* need to fix the rendering when we verify that it
  # differs from what people see in their MUA.  Testing is best done with
  # the most common MUAs and browsers, if you catch my drift.

  # NOTE: HTML::Parser can cope with: <?xml pis>, <? with space>, so we
  # don't need to fix them here.

  # bug #1551: HTML declarations, like <!foo>, are being used by spammers
  # for obfuscation, and they aren't stripped out by HTML::Parser prior to
  # version 3.28.  We have to modify these out *before* the parser is
  # invoked, because otherwise a spammer could do "&lt;! body of message
  # &gt;", which would get turned into "<! body of message >" by the
  # parser, and then the whole body message would be stripped.

  # convert <!foo> to <!--foo-->
  if ($HTML::Parser::VERSION < 3.28) {
    $text =~ s/<!((?!--|doctype)[^>]*)>/<!--$1-->/gsi;
  }

  # remove empty close tags: </>, </ >, </ foo>
  if ($HTML::Parser::VERSION < 3.29) {
    $text =~ s/<\/(?:\s.*?)?>//gs;
  }

  # HTML::Parser 3.31, at least, converts &nbsp; into a question mark "?" for some reason.
  # Let's convert them to spaces.
  $text =~ s/&nbsp;/ /g;

  my $hp = HTML::Parser->new(
		api_version => 3,
		handlers => [
		  start_document => [sub { $self->html_start(@_) }],
		  start => [sub { $self->html_tag(@_) }, "tagname,attr,'+1'"],
		  end_document => [sub { $self->html_end(@_) }],
		  end => [sub { $self->html_tag(@_) }, "tagname,attr,'-1'"],
		  text => [sub { $self->html_text(@_) }, "dtext"],
		  comment => [sub { $self->html_comment(@_) }, "text"],
		  declaration => [sub { $self->html_declaration(@_) }, "text"],
		],
		marked_sections => 1);

  # ALWAYS pack it into byte-representation, even if we're using 'use bytes',
  # since the HTML::Parser object may use Unicode internally.
  # (bug 1417, maybe)
  $hp->parse(pack ('C0A*', $text));
  $hp->eof;

  delete $self->{html_last_tag};

  return $self->{html_text};
}

sub html_tag {
  my ($self, $tag, $attr, $num) = @_;

  my $is_element = ($tag =~ /^(?:$re_strict|$re_loose|$re_other)$/io);

  # general tracking
  if ($is_element) {
    $self->{html}{elements}++;
    $self->{html}{elements_seen}++ if !exists $self->{html}{"inside_$tag"};
  }
  $self->{html}{tags}++;
  $self->{html}{tags_seen}++ if !exists $self->{html}{"inside_$tag"};
  $self->{html}{"inside_$tag"} += $num;
  $self->{html}{"inside_$tag"} = 0 if $self->{html}{"inside_$tag"} < 0;

  # check attributes
  for my $name (keys %$attr) {
    if ($name !~ /^(?:$re_attr|$re_attr_extra)$/io) {
      $self->{html}{attr_bad}++;
      $self->{html}{attr_unique_bad}++ if !exists $self->{"attr_seen_$name"};
    }
    $self->{html}{attr_all}++;
    $self->{html}{attr_unique_all}++ if !exists $self->{"attr_seen_$name"};
    $self->{"attr_seen_$name"} = 1;
  }

  # ignore non-elements
  if ($is_element) {
    if ($tag =~ /^(?:body|font|table|tr|th|td|big|small|basefont|marquee)$/) {
      $self->text_style($tag, $attr, $num);
    }
    # TODO: cover "style" and CSS
    if ($tag !~ /^(?:$re_attr_no_style)$/ && exists $attr->{style}) {
      $self->css_style($tag, $attr, $num);
    }

    # start tags
    if ($num == 1) {
      $self->html_format($tag, $attr, $num);
      $self->html_uri($tag, $attr, $num);
      $self->html_tests($tag, $attr, $num);
    }
    # end tags
    elsif ($num == -1) {
      $self->{html}{closed_html} = 1 if $tag eq "html";
      $self->{html}{closed_body} = 1 if $tag eq "body";
    }
    # shouting
    if ($tag =~ /^(?:b|i|u|strong|em|big|center|h\d)$/) {
      $self->{html}{shouting} += $num;
      if ($self->{html}{shouting} > $self->{html}{max_shouting}) {
	$self->{html}{max_shouting} = $self->{html}{shouting};
      }
    }

    $self->{html_last_tag} = (($num < 0) ? "/" : "") . $tag;
  }
}

sub html_format {
  my ($self, $tag, $attr, $num) = @_;

  # ordered by frequency of tag groups
  if ($tag eq "br" || $tag eq "div") {
    $self->display_text();
    push @{$self->{html_visible_text}}, "\n";
    push @{$self->{html_invisible_text}}, "\n";
    push @{$self->{html_text}}, "\n";
  }
  elsif ($tag =~ /^(?:li|t[hd]|d[td])$/) {
    $self->display_text();
    push @{$self->{html_visible_text}}, " ";
    push @{$self->{html_invisible_text}}, " ";
    push @{$self->{html_text}}, " ";
  }
  elsif ($tag =~ /^(?:p|hr|blockquote|pre)$/) {
    $self->display_text();
    push @{$self->{html_visible_text}}, "\n\n";
    push @{$self->{html_invisible_text}}, "\n\n";
    push @{$self->{html_text}}, "\n\n";
  }
}

use constant URI_STRICT => 0;

# resolving relative URIs as defined in RFC 2396 (steps from section 5.2)
# using draft http://www.gbiv.com/protocols/uri/rev-2002/rfc2396bis.html
sub parse_uri {
  my ($u) = @_;
  my %u;
  ($u{scheme}, $u{authority}, $u{path}, $u{query}, $u{fragment}) =
    $u =~ m|^(?:([^:/?#]+):)?(?://([^/?#]*))?([^?#]*)(?:\?([^#]*))?(?:#(.*))?|;
  return %u;
}

sub remove_dot_segments {
  my ($input) = @_;
  my $output = "";

  $input =~ s@^(?:\.\.?/)@/@;

  while ($input) {
    if ($input =~ s@^/\.(?:$|/)@/@) {
    }
    elsif ($input =~ s@^/\.\.(?:$|/)@/@) {
      $output =~ s@/?[^/]*$@@;
    }
    elsif ($input =~ s@(/?[^/]*)@@) {
      $output .= $1;
    }
  }
  return $output;
}

sub merge_uri {
  my ($base_authority, $base_path, $r_path) = @_;

  if (defined $base_authority && !$base_path) {
    return "/" . $r_path;
  }
  else {
    if ($base_path =~ m|/|) {
      $base_path =~ s|(?<=/)[^/]*$||;
    }
    else {
      $base_path = "";
    }
    return $base_path . $r_path;
  }
}

sub target_uri {
  my ($base, $r) = @_;

  my %r = parse_uri($r);	# parsed relative URI
  my %base = parse_uri($base);	# parsed base URI
  my %t;			# generated temporary URI

  if ((not URI_STRICT) and
      (defined $r{scheme} && defined $base{scheme}) and
      ($r{scheme} eq $base{scheme}))
  {
    undef $r{scheme};
  }

  if (defined $r{scheme}) {
    $t{scheme} = $r{scheme};
    $t{authority} = $r{authority};
    $t{path} = remove_dot_segments($r{path});
    $t{query} = $r{query};
  }
  else {
    if (defined $r{authority}) {
      $t{authority} = $r{authority};
      $t{path} = remove_dot_segments($r{path});
      $t{query} = $r{query};
    }
    else {
      if ($r{path} eq "") {
	$t{path} = $base{path};
	if (defined $r{query}) {
	  $t{query} = $r{query};
	}
	else {
	  $t{query} = $base{query};
	}
      }
      else {
	if ($r{path} =~ m|^/|) {
	  $t{path} = remove_dot_segments($r{path});
	}
	else {
	  $t{path} = merge_uri($base{authority}, $base{path}, $r{path});
	  $t{path} = remove_dot_segments($t{path});
	}
	$t{query} = $r{query};
      }
      $t{authority} = $base{authority};
    }
    $t{scheme} = $base{scheme};
  }
  $t{fragment} = $r{fragment};

  # recompose URI
  my $result = "";
  if ($t{scheme}) {
    $result .= $t{scheme} . ":";
  }
  elsif (defined $t{authority}) {
    # this block is not part of the RFC
    # TODO: figure out what MUAs actually do with unschemed URIs
    # maybe look at URI::Heuristic
    if ($t{authority} =~ /^www\d*\./i) {
      # some spammers are using unschemed URIs to escape filters
      $result .= "http:";
    }
    elsif ($t{authority} =~ /^ftp\d*\./i) {
      $result .= "ftp:";
    }
  }
  if ($t{authority}) {
    $result .= "//" . $t{authority};
  }
  $result .= $t{path};
  if ($t{query}) {
    $result .= "?" . $t{query};
  }
  if ($t{fragment}) {
    $result .= "#" . $t{fragment};
  }
  return $result;
}

sub push_uri {
  my ($self, $uri) = @_;

  $uri ||= '';

  # URIs don't have leading/trailing whitespace ...
  $uri =~ s/^\s+//;
  $uri =~ s/\s+$//;

  my $target = target_uri($self->{html}{base_href} || "", $uri);
  push @{$self->{html}{uri}}, $target if $target;
}

sub html_uri {
  my ($self, $tag, $attr, $num) = @_;

  # ordered by frequency of tag groups
  if ($tag =~ /^(?:body|table|tr|td)$/) {
    $self->push_uri($attr->{background});
  }
  elsif ($tag =~ /^(?:a|area|link)$/) {
    $self->push_uri($attr->{href});
  }
  elsif ($tag =~ /^(?:img|frame|iframe|embed|script)$/) {
    $self->push_uri($attr->{src});
  }
  elsif ($tag eq "form") {
    $self->push_uri($attr->{action});
  }
  elsif ($tag eq "base") {
    if (my $uri = $attr->{href}) {
      # use <BASE HREF="URI"> to turn relative links into absolute links

      # even if it is a base URI, handle like a normal URI as well
      push @{$self->{html}{uri}}, $uri;

      # a base URI will be ignored by browsers unless it is an absolute
      # URI of a standard protocol
      if ($uri =~ m@^(?:https?|ftp):/{0,2}@i) {
	# remove trailing filename, if any; base URIs can have the
	# form of "http://foo.com/index.html"
	$uri =~ s@^([a-z]+:/{0,2}[^/]+/.*?)[^/\.]+\.[^/\.]{2,4}$@$1@i;

	# Make sure it ends in a slash
	$uri .= "/" unless $uri =~ m@/$@;
	$self->{html}{base_href} = $uri;
      }
    }
  }
}

my %html_color = (
  # HTML 4 defined 16 colors
  aqua => 0x00ffff,
  black => 0x000000,
  blue => 0x0000ff,
  fuchsia => 0xff00ff,
  gray => 0x808080,
  green => 0x008000,
  lime => 0x00ff00,
  maroon => 0x800000,
  navy => 0x000080,
  olive => 0x808000,
  purple => 0x800080,
  red => 0xff0000,
  silver => 0xc0c0c0,
  teal => 0x008080,
  white => 0xffffff,
  yellow => 0xffff00,
  # colors specified in CSS3 color module
  aliceblue => 0xf0f8ff,
  antiquewhite => 0xfaebd7,
  aqua => 0x00ffff,
  aquamarine => 0x7fffd4,
  azure => 0xf0ffff,
  beige => 0xf5f5dc,
  bisque => 0xffe4c4,
  black => 0x000000,
  blanchedalmond => 0xffebcd,
  blue => 0x0000ff,
  blueviolet => 0x8a2be2,
  brown => 0xa52a2a,
  burlywood => 0xdeb887,
  cadetblue => 0x5f9ea0,
  chartreuse => 0x7fff00,
  chocolate => 0xd2691e,
  coral => 0xff7f50,
  cornflowerblue => 0x6495ed,
  cornsilk => 0xfff8dc,
  crimson => 0xdc143c,
  cyan => 0x00ffff,
  darkblue => 0x00008b,
  darkcyan => 0x008b8b,
  darkgoldenrod => 0xb8860b,
  darkgray => 0xa9a9a9,
  darkgreen => 0x006400,
  darkgrey => 0xa9a9a9,
  darkkhaki => 0xbdb76b,
  darkmagenta => 0x8b008b,
  darkolivegreen => 0x556b2f,
  darkorange => 0xff8c00,
  darkorchid => 0x9932cc,
  darkred => 0x8b0000,
  darksalmon => 0xe9967a,
  darkseagreen => 0x8fbc8f,
  darkslateblue => 0x483d8b,
  darkslategray => 0x2f4f4f,
  darkslategrey => 0x2f4f4f,
  darkturquoise => 0x00ced1,
  darkviolet => 0x9400d3,
  deeppink => 0xff1493,
  deepskyblue => 0x00bfff,
  dimgray => 0x696969,
  dimgrey => 0x696969,
  dodgerblue => 0x1e90ff,
  firebrick => 0xb22222,
  floralwhite => 0xfffaf0,
  forestgreen => 0x228b22,
  fuchsia => 0xff00ff,
  gainsboro => 0xdcdcdc,
  ghostwhite => 0xf8f8ff,
  gold => 0xffd700,
  goldenrod => 0xdaa520,
  gray => 0x808080,
  green => 0x008000,
  greenyellow => 0xadff2f,
  grey => 0x808080,
  honeydew => 0xf0fff0,
  hotpink => 0xff69b4,
  indianred => 0xcd5c5c,
  indigo => 0x4b0082,
  ivory => 0xfffff0,
  khaki => 0xf0e68c,
  lavender => 0xe6e6fa,
  lavenderblush => 0xfff0f5,
  lawngreen => 0x7cfc00,
  lemonchiffon => 0xfffacd,
  lightblue => 0xadd8e6,
  lightcoral => 0xf08080,
  lightcyan => 0xe0ffff,
  lightgoldenrodyellow => 0xfafad2,
  lightgray => 0xd3d3d3,
  lightgreen => 0x90ee90,
  lightgrey => 0xd3d3d3,
  lightpink => 0xffb6c1,
  lightsalmon => 0xffa07a,
  lightseagreen => 0x20b2aa,
  lightskyblue => 0x87cefa,
  lightslategray => 0x778899,
  lightslategrey => 0x778899,
  lightsteelblue => 0xb0c4de,
  lightyellow => 0xffffe0,
  lime => 0x00ff00,
  limegreen => 0x32cd32,
  linen => 0xfaf0e6,
  magenta => 0xff00ff,
  maroon => 0x800000,
  mediumaquamarine => 0x66cdaa,
  mediumblue => 0x0000cd,
  mediumorchid => 0xba55d3,
  mediumpurple => 0x9370db,
  mediumseagreen => 0x3cb371,
  mediumslateblue => 0x7b68ee,
  mediumspringgreen => 0x00fa9a,
  mediumturquoise => 0x48d1cc,
  mediumvioletred => 0xc71585,
  midnightblue => 0x191970,
  mintcream => 0xf5fffa,
  mistyrose => 0xffe4e1,
  moccasin => 0xffe4b5,
  navajowhite => 0xffdead,
  navy => 0x000080,
  oldlace => 0xfdf5e6,
  olive => 0x808000,
  olivedrab => 0x6b8e23,
  orange => 0xffa500,
  orangered => 0xff4500,
  orchid => 0xda70d6,
  palegoldenrod => 0xeee8aa,
  palegreen => 0x98fb98,
  paleturquoise => 0xafeeee,
  palevioletred => 0xdb7093,
  papayawhip => 0xffefd5,
  peachpuff => 0xffdab9,
  peru => 0xcd853f,
  pink => 0xffc0cb,
  plum => 0xdda0dd,
  powderblue => 0xb0e0e6,
  purple => 0x800080,
  red => 0xff0000,
  rosybrown => 0xbc8f8f,
  royalblue => 0x4169e1,
  saddlebrown => 0x8b4513,
  salmon => 0xfa8072,
  sandybrown => 0xf4a460,
  seagreen => 0x2e8b57,
  seashell => 0xfff5ee,
  sienna => 0xa0522d,
  silver => 0xc0c0c0,
  skyblue => 0x87ceeb,
  slateblue => 0x6a5acd,
  slategray => 0x708090,
  slategrey => 0x708090,
  snow => 0xfffafa,
  springgreen => 0x00ff7f,
  steelblue => 0x4682b4,
  tan => 0xd2b48c,
  teal => 0x008080,
  thistle => 0xd8bfd8,
  tomato => 0xff6347,
  turquoise => 0x40e0d0,
  violet => 0xee82ee,
  wheat => 0xf5deb3,
  white => 0xffffff,
  whitesmoke => 0xf5f5f5,
  yellow => 0xffff00,
  yellowgreen => 0x9acd32,
);

sub name_to_rgb {
  my $color = lc $_[0];
  if (my $hex = $html_color{$color}) {
      return sprintf("#%06x", $hex);
  }
  return $color;
}

# this might not be quite right, may need to pay attention to table nesting
sub close_table_tag {
  my ($self, $tag) = @_;

  # don't close if never opened
  return unless grep { $_->{tag} eq $tag } @{ $self->{text_style} };

  my $top;
  while (@{ $self->{text_style} } && ($top = $self->{text_style}[-1]->{tag})) {
    if (($tag eq "td" && $top =~ /^(?:font|td)$/) ||
	($tag eq "tr" && $top =~ /^(?:font|td|tr)$/))
    {
      pop @{ $self->{text_style} };
    }
    else {
      last;
    }
  }
}

sub close_tag {
  my ($self, $tag) = @_;

  # don't close if never opened
  return if !grep { $_->{tag} eq $tag } @{ $self->{text_style} };

  # close everything up to and including tag
  while (my %current = %{ pop @{ $self->{text_style} } }) {
    last if $current{tag} eq $tag;
  }
}

# process CSS style attribute
sub css_style {
  my ($self, $tag, $attr, $num) = @_;

  # TODO: something here
}

# body, font, table, tr, th, td, big, small
sub text_style {
  my ($self, $tag, $attr, $num) = @_;

  # treat <th> as <td>
  $tag = "td" if $tag eq "th";

  # open
  if ($num == 1) {
    # HTML browsers generally only use first <body> for colors,
    # so only push if we haven't seen a body tag yet
    if ($tag eq "body") {
      # TODO: skip if we've already seen body
    }

    # change basefont (only change size)
    if ($tag eq "basefont" &&
	exists $attr->{size} && $attr->{size} =~ /^\s*(\d+)/)
    {
      $self->{basefont} = $1;
      return;
    }

    # close elements with optional end tags
    $self->close_table_tag($tag) if ($tag eq "td" || $tag eq "tr");

    # copy current text state
    my %new = %{ $self->{text_style}[-1] };

    # change tag name!
    $new{tag} = $tag;

    # big and small tags
    if ($tag eq "big") {
      $new{size} += 1;
      push @{ $self->{text_style} }, \%new;
      return;
    }
    if ($tag eq "small") {
      $new{size} -= 1;
      push @{ $self->{text_style} }, \%new;
      return;
    }

    # tag attributes
    for my $name (keys %$attr) {
      next unless (grep { $_ eq $tag } @{ $ok_attribute{$name} });
      if ($name =~ /^(?:text|color)$/) {
	# two different names for text color
	$new{fgcolor} = name_to_rgb(lc($attr->{$name}));
      }
      elsif ($name eq "size" && $attr->{size} =~ /^\s*([+-]\d+)/) {
	# relative font size
	$new{size} = $self->{basefont} + $1;
      }
      else {
	if ($name eq "bgcolor") {
	  # overwrite with hex value, $new{bgcolor} is set below
	  $attr->{bgcolor} = name_to_rgb(lc($attr->{bgcolor}));
	}
	if ($name eq "size" && $attr->{size} !~ /^\s*([+-])(\d+)/) {
	  # attribute is malformed
	}
	else {
	  # attribute is probably okay
	  $new{$name} = $attr->{$name};
	}
      }
      if ($new{size} > $self->{html}{max_size}) {
	$self->{html}{max_size} = $new{size};
      }
      elsif ($new{size} < $self->{html}{min_size}) {
	$self->{html}{min_size} = $new{size};
      }
    }
    push @{ $self->{text_style} }, \%new;
  }
  # explicitly close a tag
  else {
    if ($tag ne "body") {
      # don't close body since browsers seem to render text after </body>
      $self->close_tag($tag);
    }
  }
}

sub html_font_invisible {
  my ($self, $text) = @_;

  my $fg = $self->{text_style}[-1]->{fgcolor};
  my $bg = $self->{text_style}[-1]->{bgcolor};
  my $visible_for_bayes = 1;

  # invisibility
  if (substr($fg,-6) eq substr($bg,-6)) {
    $self->{html}{font_invisible} = 1;
    $visible_for_bayes = 0;
  }
  # near-invisibility
  elsif ($fg =~ /^\#?([0-9a-f]{2})([0-9a-f]{2})([0-9a-f]{2})$/) {
    my ($r1, $g1, $b1) = (hex($1), hex($2), hex($3));

    if ($bg =~ /^\#?([0-9a-f]{2})([0-9a-f]{2})([0-9a-f]{2})$/) {
      my ($r2, $g2, $b2) = (hex($1), hex($2), hex($3));

      my $r = ($r1 - $r2);
      my $g = ($g1 - $g2);
      my $b = ($b1 - $b2);

      # geometric distance weighted by brightness
      # maximum distance is 191.151823601032
      my $distance = ((0.2126*$r)**2 + (0.7152*$g)**2 + (0.0722*$b)**2)**0.5;

      # the text is very difficult to read if the distance is under 12,
      # a limit of 14 to 16 might be okay if the usage significantly
      # increases (near-invisible text is at about 0.95% of spam and
      # 1.25% of HTML spam right now), but please test any changes first
      if ($distance < 12) {
	$self->{html}{"font_low_contrast"} = 1;
        $visible_for_bayes = 0;
      }
    }
  }

  return $visible_for_bayes;
}

sub html_tests {
  my ($self, $tag, $attr, $num) = @_;
  local ($_);

  if ($tag eq "table" && exists $attr->{border} && $attr->{border} =~ /(\d+)/)
  {
    $self->{html}{thick_border} = 1 if $1 > 1;
  }
  # if ($tag eq "script") {
  # $self->{html}{javascript} = 1;
  # }
  if ($tag =~ /^(?:a|body|div|input|form|td|layer|area|img)$/i) {
    for (keys %$attr) {
      if (/\b(?:$events)\b/io)
      {
	$self->{html}{html_event} = 1;
      }
      if (/\bon(?:contextmenu|load|resize|submit|unload)\b/i &&
	  $attr->{$_})
      {
	$self->{html}{html_event_unsafe} = 1;
        # if ($attr->{$_} =~ /\.open\s*\(/) { $self->{html}{window_open} = 1; }
      }
    }
  }
  if ($tag eq "font" && exists $attr->{size}) {
    my $size = $attr->{size};
    $self->{html}{tiny_font} = 1 if (($size =~ /^\s*(\d+)/ && $1 < 1) ||
				     ($size =~ /\-(\d+)/ && $1 >= 3));
    $self->{html}{big_font} = 1 if (($size =~ /^\s*(\d+)/ && $1 > 3) ||
				    ($size =~ /\+(\d+)/ && $1 >= 1));
  }
  if ($tag eq "font" && exists $attr->{face}) {
    if ($attr->{face} =~ /[A-Z]{3}/ && $attr->{face} !~ /M[ST][A-Z]|ITC/) {
      $self->{html}{font_face_caps} = 1;
    }
    if ($attr->{face} !~ /^[a-z][a-z -]*[a-z](?:,\s*[a-z][a-z -]*[a-z])*$/i) {
      $self->{html}{font_face_bad} = 1;
    }
  }
  if (exists($attr->{style})) {
    if ($attr->{style} =~ /font(?:-size)?:\s*(\d+(?:\.\d*)?|\.\d+)(p[tx])/i) {
      $self->examine_text_style ($1, $2);
    }
  }
  if ($tag eq "img") {
    push @{ $self->{html}{img_src} }, $attr->{src} if exists $attr->{src};
  }
  if ($tag eq "img" && exists $attr->{width} && exists $attr->{height}) {
    my $width = 0;
    my $height = 0;
    my $area = 0;

    # assume 800x600 screen for percentage values
    if ($attr->{width} =~ /^(\d+)(\%)?$/) {
      $width = $1;
      $width *= 8 if (defined $2 && $2 eq "%");
    }
    if ($attr->{height} =~ /^(\d+)(\%)?$/) {
      $height = $1;
      $height *= 6 if (defined $2 && $2 eq "%");
    }
    # guess size
    $width = 200 if $width <= 0;
    $height = 200 if $height <= 0;
    if ($width > 0 && $height > 0) {
      $area = $width * $height;
      $self->{html}{image_area} += $area;
    }
    # this is intended to match any width and height if they're specified
    if (exists $attr->{src} &&
	$attr->{src} =~ /\.(?:pl|cgi|php|asp|jsp|cfm)\b/i)
    {
      $self->{html}{web_bugs} = 1;
    }
  }
  if ($tag eq "form" && exists $attr->{action}) {
    $self->{html}{form_action_mailto} = 1 if $attr->{action} =~ /mailto:/i
  }
  if ($tag =~ /^(?:object|embed)$/) {
    $self->{html}{embeds} = 1;
  }

  # special text delimiters - <a> and <title>
  if ($tag eq "a") {
    $self->{html}{anchor_index}++;
    $self->{html}{anchor}->[$self->{html}{anchor_index}] = "";
  }
  if ($tag eq "title") {
    $self->{html}{title_index}++;
    $self->{html}{title}->[$self->{html}{title_index}] = "";

    # $self->{html}{title_extra}++ if $self->{html}{title_index} > 0;
  }

  if ($tag eq "meta" &&
      exists $attr->{'http-equiv'} &&
      exists $attr->{content} &&
      $attr->{'http-equiv'} =~ /Content-Type/i &&
      $attr->{content} =~ /\bcharset\s*=\s*["']?([^"']+)/i)
  {
    $self->{html}{charsets} .= exists $self->{html}{charsets} ? " $1" : $1;
  }
}

sub examine_text_style {
  my ($self, $size, $type) = @_;
  $type = lc $type;
  $self->{html}{tiny_font} = 1 if ($type eq "pt" && $size < 4);
  $self->{html}{tiny_font} = 1 if ($type eq "pt" && $size < 4);
  $self->{html}{big_font} = 1 if ($type eq "pt" && $size > 14);
  $self->{html}{big_font} = 1 if ($type eq "px" && $size > 18);
}

sub display_text {
  my ($self) = @_;

  for my $type ('text', 'visible_text', 'invisible_text') {
    my $text = $self->{"last_$type"};
    $text =~ s/[ \t\n\r\f\x0b\xa0]+/ /g;
    $text =~ s/^ //;
    $text =~ s/ $//;
    push @{$self->{"html_$type"}}, $text;
    $self->{"last_$type"} = "";
  }
}

sub html_text {
  my ($self, $text) = @_;

  # note: this comes back from HTML::Parser as UTF-8-tainted.  Enforce byte
  # mode by repacking the string in byte mode, to avoid 'Malformed UTF-8
  # character (unexpected non-continuation byte)' warnings
  $text = pack ("C0A*", $text);

  # text that is not part of body
  if (exists $self->{html}{inside_script} && $self->{html}{inside_script} > 0)
  {
    if ($text =~ /\bon(?:blur|contextmenu|focus|load|resize|submit|unload)\b/i)
    {
      $self->{html}{html_event_unsafe} = 1;
    }
    if ($text =~ /\b(?:$events)\b/io) { $self->{html}{html_event} = 1; }
    # if ($text =~ /\.open\s*\(/) { $self->{html}{window_open} = 1; }
    return;
  }
  if (exists $self->{html}{inside_style} && $self->{html}{inside_style} > 0) {
    if ($text =~ /font(?:-size)?:\s*(\d+(?:\.\d*)?|\.\d+)(p[tx])/i) {
      $self->examine_text_style ($1, $2);
    }
    return;
  }

  # text that is part of body and also stored separately
  if (exists $self->{html}{inside_a} && $self->{html}{inside_a} > 0) {
    $self->{html}{anchor}->[$self->{html}{anchor_index}] .= $text;
  }
  if (exists $self->{html}{inside_title} && $self->{html}{inside_title} > 0) {
    $self->{html}{title}->[$self->{html}{title_index}] .= $text;
  }

  my $visible_for_bayes = 1;
  if ($text =~ /[^ \t\n\r\f\x0b\xa0]/) {
    $visible_for_bayes = $self->html_font_invisible($text);
    $self->{html}{text_after_body} = 1 if $self->{html}{closed_body};
    $self->{html}{text_after_html} = 1 if $self->{html}{closed_html};
  }

  if ($self->{last_text}) {
    # ideas discarded since they would be easy to evade:
    # 1. using \w or [A-Za-z] instead of \S or non-punctuation
    # 2. exempting certain tags
    if ($text =~ /^[^\s\x21-\x2f\x3a-\x40\x5b-\x60\x7b-\x7e]/s &&
	$self->{last_text} =~ /[^\s\x21-\x2f\x3a-\x40\x5b-\x60\x7b-\x7e]\z/s)
    {
      $self->{html}{obfuscation}++;
    }
    if ($self->{last_text} =~
	/\b([^\s\x21-\x2f\x3a-\x40\x5b-\x60\x7b-\x7e]{1,7})\z/s)
    {
      my $start = length($1);
      if ($text =~ /^([^\s\x21-\x2f\x3a-\x40\x5b-\x60\x7b-\x7e]{1,7})\b/s) {
	my $backhair = $start . "_" . length($1);
	$self->{html}{backhair}->{$backhair}++;
	$self->{html}{backhair_count} = keys %{ $self->{html}{backhair} };
      }
    }
  }

  if ($visible_for_bayes) {
    $self->{last_visible_text} .= $text;
  }
  else {
    $self->{last_invisible_text} .= $text;
  }
  $self->{last_text} .= $text;
}

# note: $text includes <!-- and -->
sub html_comment {
  my ($self, $text) = @_;

  push @{ $self->{html}{comment} }, $text;

  if ($self->{html_last_tag} eq "div" &&
      $text =~ /Converted from text\/plain format/)
  {
    $self->{html}{div_converted} = 1;
  }
  if (exists $self->{html}{inside_script} && $self->{html}{inside_script} > 0)
  {
    if ($text =~ /\b(?:$events)\b/io)
    {
      $self->{html}{html_event} = 1;
    }
    if ($text =~ /\bon(?:blur|contextmenu|focus|load|resize|submit|unload)\b/i)
    {
      $self->{html}{html_event_unsafe} = 1;
    }
    # if ($text =~ /\.open\s*\(/) { $self->{html}{window_open} = 1; }
    return;
  }

  if (exists $self->{html}{inside_style} && $self->{html}{inside_style} > 0) {
    if ($text =~ /font(?:-size)?:\s*(\d+(?:\.\d*)?|\.\d+)(p[tx])/i) {
      $self->examine_text_style ($1, $2);
    }
  }

  if (exists $self->{html}{shouting} && $self->{html}{shouting} > 1) {
    $self->{html}{comment_shouting} = 1;
  }
}

sub html_declaration {
  my ($self, $text) = @_;

  if ($text =~ /^<!doctype/i) {
    my $tag = "!doctype";

    $self->{html}{elements}++;
    $self->{html}{tags}++;
    $self->{html}{"inside_$tag"} = 0;
  }
}

1;
__END__
