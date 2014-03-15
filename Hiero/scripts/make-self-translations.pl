#!/usr/bin/perl -w

use strict;

die "Usage: $0 OUTPUT-DIR\n\nReads lines from STDIN and creates new grammars in OUTPUT-DIR\n" unless scalar @ARGV == 1;

my $dir = shift @ARGV;

`mkdir -p $dir`;
die "Couldn't create $dir\n" unless $? == 0;

my @nopass = qw(
<s> </s> mein ich mir schon ihr ihren ihre vielleicht viel wenig dieses diesem diese wurde wurden all alle All doch zwar bis zwischen zusammen ohne hin her fest dar Plan Jahr Jahre fast Fall falls Falls tut tat noch wo was waren kein keine keinen keines gut Gut gern Im sind seit wird werden gewesen auch hat haben hatten habe über soll kann sollen geworden wir er ihn ihm sie Sie müssen muss müsse zu Zu dazu damit mit Mit ist um ab wie will von Will ein nicht eine durch unter auf aus ausser wohl seinen seine viele sein eines hatte bzw. aber jedoch ja gibt geben gab nahm nehme
es im ins nach als sank sink sung ging für sich mag sein dass wenn man kam vor du dich mich mir Mann des vom und das dem zu zum zur der den die ein eine einem einen einer Und in In IN am Am An an AN AM so was So Was
% - also wieso . ? : ! -- ; $ " ' würde war Art bei nur ob
);
my %forbid;
for my $np (@nopass) { $forbid{$np} = 1; }
$forbid{','} = 1;
$forbid{'('} = 1;
$forbid{')'} = 1;
my %mtrans = qw(
 Januar January
 Februar February
 März March
 April April
 Mai May
 Juni June
 Juli July
 August August
 September September
 Oktober October
 November November
 Dezember December
);

sub special {
  my ($fh) = @_;
  print $fh <<EOT;
[X] ||| , ||| ||| DelComma=1
[X] ||| - ||| ||| DelHyphen=1
[X] ||| . ||| . ||| PassThroughPeriod=1 PTP=1
[X] ||| ? ||| ? ||| PassThroughQ=1 PTP=1
[X] ||| ! ||| ! ||| PassThroughE=1 PTP=1
[X] ||| , ||| , ||| PassThroughComma=1 PTP=1
[X] ||| : ||| : ||| PassThroughCol=1 PTP=1
[X] ||| ; ||| ; ||| PassThroughSemi=1 PTP=1
[X] ||| ( ||| ( ||| PassThroughLRB=1 PTP=1
[X] ||| ) ||| ) ||| PassThroughRRB=1 PTP=1
[X] ||| % ||| % ||| PassThroughPercent=1 PTP=1
[X] ||| " ||| " ||| PassThroughDQ=1 PTP=1
[X] ||| " [X] " ||| " [1] " ||| PassThroughDQDQ=1 PTP=1
[X] ||| ( [X] ) ||| ( [1] ) ||| PassThroughLRBRRB=1 PTP=1
[X] ||| -- ||| -- ||| PassThroughDash=1 PTP=1
[X] ||| - ||| - ||| PassThroughHyphen=1 PTP=1
[X] ||| \$ ||| \$ ||| PassThroughDollar=1 PTP=1
[Z] ||| [Y] ||| [1] ||| StopOOVGlue=1
[Z] ||| [Z] [Y] ||| [1] [2] ||| OOVGlue=1
[X] ||| [Z] ||| [1] ||| UsePT=1
EOT
}

sub normalize {
  my $num = shift;
  if ($num =~ /^(\d+)(\.| )(\d{3})$/) {
    return "$1,$3";
  } elsif ($num =~ /^(\d+)(\.| )(\d{3})(\.| )(\d{3})$/) {
    return "$1,$3,$5";
  } elsif ($num =~ /^(\d+),(\d+)$/) {
    return "$1.$2";
  } else { return $num; }
}

my $id = -1;
while(<>) {
  chomp;
  $id++;
  my ($ssrc, @rest) = split / \|\|\| /;
  my $biotags = pop @rest;
  die "Expected last segment in input file to be B-I-O tags indicating spans likely to pass through!\n" unless $biotags =~ /^((B|I|O) )*(B|I|O)$/;
  my $gc = 0;
  my $others = '';
  if ($ssrc =~ /<seg\s*([^>]*)>\s*(.*)\s*<\/seg>/) {
    my $tags = $1;
    $ssrc = $2;
    if ($tags =~ /id="(\d+)"/) {
      $id = $1;
      $tags =~ s/id="(\d+)"//;
    }
    while($tags =~ /grammar(\d+)?=/g) { $gc++; }
    $others = $tags;
  }
  my $gname = "$dir/pt.$id.gz";
  my $gtag = "grammar$gc=\"$gname\"";
  $gtag =~ s/grammar0=/grammar=/;
  $gtag = "<seg id=\"$id\" $others $gtag>";
  $gtag =~ s/  +/ /g;
  $gtag =~ s/" >/">/g;
  my $oo = join ' ||| ', ("$gtag $ssrc </seg>", @rest);
  print "$oo\n";
  open O, "|gzip -9 > $gname" or die "Couldn't fork: $!";
  special(\*O);
  my @src = split /\s+/, $ssrc;
  $ssrc = " $ssrc ";
  my @tag = split /\s+/, $biotags;
  die "Mismatched number of B-I-O tags relative to source words!:\n@src\n@tag\n" unless scalar @src == scalar @tag;
  my $len = scalar @src;
  my $i = 0;
  while ($i < $len) {
    my $s = $src[$i];
    if ($tag[$i] eq 'O') {
      unless ($forbid{$s}) {
        if ($s =~ /^[0-9,. ]+$/) {
          my $num=normalize($s);
          my $x = int(log(length($num)) / log(1.8) + 1);
          print O "[X] ||| $s ||| $num ||| Num=1 NumLen_$x=1\n";
        } else {
          my @ff=();
          push @ff, 'URL=1' if $s =~ /www|http|\.com|\.edu|\.de|\.cz|\.co\.uk|\.fr|\.es|\.org/;
          print O "[X] ||| $s ||| $s ||| @ff PassThrough=1 PassThroughAsX=1\n" unless $forbid{$s};
          print O "[Y] ||| $s ||| $s ||| @ff PassThrough=1 PassThroughAsY=1\n" unless $forbid{$s};
        }
      }
      $i++;
    } elsif ($tag[$i] eq 'B') {
      my $start = $i;
      while ($i < $len && $tag[$i] ne 'O') { $i++; }
      my @sl = @src[$start .. $i-1];
      my $out = "@sl";
      my $x = int(log(scalar @sl) / log(1.6) + 1);
      my @ff = ('Tagged=1');
      push @ff, 'URL=1' if $out =~ /www|http|\.com|\.edu|\.de|\.cz|\.co\.uk|\.fr|\.es|\.org/;
      print O "[X] ||| @sl ||| $out ||| @ff TaggedLen_$x=1 TaggedAsX=1\n";
      print O "[Y] ||| @sl ||| $out ||| @ff TaggedLen_$x=1 TaggedAsY=1\n";
      my $num="@sl";
      if ($num =~ /^[0-9,. ]+$/) {
        $num=normalize($num);
        my $x = int(log(length($num)) / log(1.8) + 1);
        print O "[X] ||| @sl ||| $num ||| Num=1 NumLen_$x=1\n";
      }
    }
  }
  while($ssrc =~ /(im|Im) Jahre? (\d+)/g) {
    my $year = $2;
    my $t = "in $year";
    print O "[X] ||| $& ||| $t ||| Year=1\n";
    print O "[X] ||| $& ||| $t , ||| Year=1 YearComma=1\n";
  }
  while($ssrc =~ /([1-9]|[1-9]\d|[1-9]\d\d)([ .]\d{3})* (Dollar |Euro |Kč |CZK |EUR |INR )?/g) {
    my $src = $&;
    my $trg = $1;
    $trg .= $2 if defined $2;
    my $cur = $3;
    $trg =~ s/ /,/g;
    $trg =~ s/\./,/g;
    my @ff = ('Num=1','SpaceNum=1');
    if ($cur) {
      push @ff, 'Currency=1';
      if ($cur eq 'Dollar ') {
          print O "[X] ||| $src||| \$ $trg ||| @ff\n";
          print O "[X] ||| $src||| $trg dollars ||| @ff\n";
        }
        elsif ($cur eq 'Euro ' or $cur eq 'EUR ') {
          print O "[X] ||| $src||| € $trg ||| @ff\n";
          print O "[X] ||| $src||| $trg euros ||| @ff\n";
        } elsif ($cur eq 'INR ') {
          print O "[X] ||| $src||| $trg rupees ||| @ff\n";
          print O "[X] ||| $src||| ₹ $trg ||| @ff\n";
        } elsif ($cur eq 'CZK ' or $cur eq 'Kč' ) {
          print O "[X] ||| $src||| $trg Kč ||| @ff\n";
          print O "[X] ||| $src||| $trg Czech crowns ||| @ff\n";
        } else {
          print O "[X] ||| $src||| $trg $cur ||| @ff\n";
        }
    } else {
      print O "[X] ||| $src||| $trg ||| @ff\n";
    }
  }
  while($ssrc =~ /(\d+(\,\d+)?) (Prozent|%|Million|Milliard|Billion|Mrd|Mio)(en)? ((- |\. )?(Dollar |Euro |Kč |INR |CZK |EUR ))?/g) {
    my $src = $&;
    my $pc = $1;
    my $type = $3;
    my $cur = $7;
    $pc =~ s/,/./;
    if ($type =~ /Prozent|%/) {
      print O "[X] ||| $src ||| $pc % ||| Percent=1\n";
      print O "[X] ||| $src ||| $pc percent ||| Percent=1\n";
    } else {
      my @ff = ('TypeNum=1');
      $type =~ s/Million/million/;
      $type =~ s/Milliard/billion/;
      $type =~ s/Mio/million/;
      $type =~ s/Mrd/billion/;
      $type =~ s/Billion/trillion/;
      if ($cur) {
        push @ff, 'Currency=1';
        if ($cur eq 'Dollar ') {
          print O "[X] ||| $src||| \$ $pc $type ||| @ff\n";
          print O "[X] ||| $src||| $pc $type dollars ||| @ff\n";
        }
        elsif ($cur eq 'Euro ' or $cur eq 'EUR ') {
          print O "[X] ||| $src||| € $pc $type ||| @ff\n";
          print O "[X] ||| $src||| $pc $type euros ||| @ff\n";
        } elsif ($cur eq 'INR ') {
          print O "[X] ||| $src||| $pc $type rupees ||| @ff\n";
          print O "[X] ||| $src||| ₹ $pc $type ||| @ff\n";
        } elsif ($cur eq 'CZK ' or $cur eq 'Kč' ) {
          print O "[X] ||| $src||| $pc $type Kč ||| @ff\n";
          print O "[X] ||| $src||| $pc $type Czech crowns ||| @ff\n";
        } else {
          print O "[X] ||| $src||| $cur$pc $type ||| @ff\n";
        }
      } else {
        print O "[X] ||| $src||| $pc $type ||| @ff\n";
      }
    }
  }
  while(/(am |Am )?(\d+)\.? (Januar|Februar|März|April|Mai|Juni|Juli|August|September|Oktober|November|Dezember) (\d{2,4})?/g) {
    my $day = $2;
    my $mon = $mtrans{$3};
    my $src = $&;
    my $out = "$mon $day";
    if (defined $4) {
      $out .= " , $4";
    }
    if (defined $1) {
      $out = "on $out";
    }
    $out = "[X] ||| $src ||| $out";
    $out =~ s/  +/ /g;
    print O "$out ||| Date=1\n";
    print O "$out , ||| Date=1\n";
  }
  while(/(gegen|um|Um)? ((\d+)([.:]\d+)?) Uhr /g) {
    my $at = $1;
    my $src = $&;
    my $time = $3;
    my $min = $4;
    my $t = "$time";
    my $t2;
    my $pfx = ' ';
    if ($t > 12) { $t2 = $t - 12; }
    if ($at) {
      $pfx = "about " if $at =~ '[Gg]egen';
      $pfx = "at " if $at =~ /[Uu]m/;
    }
    $t =~ s/\./:/;
    unless ($min) {
      print O "[X] ||| $src||| $pfx$t o'clock ||| Time=1\n";
      print O "[X] ||| $src||| $pfx$t2 o'clock ||| Time=1 TwelveHour=1\n" if $t2;
      print O "[X] ||| $src||| $pfx$t:00 ||| Time=1\n";
      print O "[X] ||| $src||| $pfx$t2:00 ||| Time=1 TwelveHour=1\n" if $t2;
      print O "[X] ||| $src||| $pfx$t2:00 p.m. ||| Time=1 TwelveHour=1\n" if $t2;
    } else {
      $min =~ s/\./:/;
      my $o = "[X] ||| $src ||| $pfx$t$min ||| Time=1";
      $o =~ s/  +/ /g;
      print O "$o\n";
      if ($t2) {
        my $o = "[X] ||| $src ||| $pfx$t2$min PM ||| Time=1 TwelveHour=1";
        $o =~ s/  +/ /g;
        print O "$o\n";
        $o = "[X] ||| $src ||| $pfx$t2$min ||| Time=1 TwelveHour=1";
        $o =~ s/  +/ /g;
        print O "$o\n";
      }
    }
  }
}

