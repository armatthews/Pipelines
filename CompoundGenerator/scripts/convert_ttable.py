import sys
import argparse
from math import exp

parser = argparse.ArgumentParser(description='When sorting make sure to use LC_ALL=C!')
parser.add_argument('fwd', help='sorted by -k 1,1 -k 2,2 -t \' \'')
parser.add_argument('rev', help='sorted by -k 2,2 -k 1,1 -t \' \'')
args = parser.parse_args()

def read_ttable(filename):
	f = open(filename)
	for line in f:
		f, e, p = line.decode('utf-8').strip().split()
		yield (f, e, p)

def read_phrases(fwd, rev):
	NullPhrase = (None, None, None)
	inf = float('inf')
	(ff, fe, fp) = next(fwd, NullPhrase)
	(re, rf, rp) = next(rev, NullPhrase)
	while ff != None or rf != None:
		if (ff, fe) < (rf, re) or rf == None:
			yield (ff, fe, {'fwd': float(fp), 'norev': 1.0})
			(ff, fe, fp) = next(fwd, NullPhrase)
		elif (ff, fe) > (rf, re) or ff == None:
			yield (rf, re, {'nofwd': 1.0, 'rev': float(rp)})
			(re, rf, rp) = next(rev, NullPhrase)
		elif (ff, fe) == (rf, re):
			yield(ff, fe, {'fwd': float(fp), 'rev': float(rp)})
			(ff, fe, fp) = next(fwd, NullPhrase)
			(re, rf, rp) = next(rev, NullPhrase)

fwd = read_ttable(args.fwd)
rev = read_ttable(args.rev)
for (f, e, scores) in read_phrases(fwd, rev):
	print ('[X] ||| %s ||| %s ||| %s ||| |||' % (f, ' '.join(e), ' '.join('%s=%f' % (k, v) for (k, v) in scores.iteritems()))).encode('utf-8')
