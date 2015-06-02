#!/usr/bin/perl -w
use strict;
use utf8;

my %codebook;
my $MAX_E_GIVEN_F = 100;

my $MAX_CODE = 5;
die "Usage: $0 brown-paths.gz < grammar" unless scalar @ARGV == 1;
print STDERR "Reading codes...\n";
open Z, "zcat $ARGV[0]|" or die;
binmode(Z,":utf8");
while(<Z>) {
  my ($code, $w, $cnt) = split /\s+/;
  $w = lc $w;
  if (length($code) > $MAX_CODE) { $code = substr $code, 0, $MAX_CODE; }
  $codebook{$w} = "C$code";
}
close Z;

my $cur = '';
my %d;
binmode STDIN,":utf8";
binmode STDOUT,":utf8";
while(<STDIN>) {
  my ($lhs, $src, $trg, $ff, @d) = split / \|\|\| /;
  if ($src =~ /<(suf|end)>/) {
    print;
    next;
  }
  next if ("$trg $src" =~ /[^ abcdefghijklmnopqrstuvwxyzöüäßåšž]/);
  next unless "$src $trg" =~ /[a-z]/;
  if ($cur ne $src) {
    my $n = 0;
    for my $k (sort {$d{$b} <=> $d{$a}} keys %d) {
      print "$k\n";
      $n++;
      if ($n >= $MAX_E_GIVEN_F) { last; }
    }
    $cur = $src;
    %d = ();
  }
  my $f = -99999;
  if (/ fwd=([0-9\.\-]+)/) {
    $f = $1;
  }
  my $kk = $trg;
  $kk =~ s/ //g;
  my $c = $codebook{$kk};
  unless ($c) { $c = 'CUNK'; }
  my $ls = int(log(length($src))/log(1.6));
  my $lt = int(log(length($trg) / 2 + 0.5)/log(1.6));
  my @feats;
  push @feats, "lmatch_${ls}_${lt}=1 $c=1";
  $d{"[X] ||| $src ||| $trg ||| $ff @feats"} = $f;
}

