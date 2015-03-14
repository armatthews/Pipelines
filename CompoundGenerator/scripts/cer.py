import sys
import argparse

parser = argparse.ArgumentParser()
parser.add_argument('hyps')
parser.add_argument('refs')
args = parser.parse_args()

def levenshtein(seq1, seq2):
    oneago = None
    thisrow = range(1, len(seq2) + 1) + [0]
    for x in xrange(len(seq1)):
        twoago, oneago, thisrow = oneago, thisrow, [0] * len(seq2) + [x + 1]
        for y in xrange(len(seq2)):
            delcost = oneago[y] + 1
            addcost = thisrow[y - 1] + 1
            subcost = oneago[y - 1] + (seq1[x] != seq2[y])
            thisrow[y] = min(delcost, addcost, subcost)
    return thisrow[len(seq2) - 1]

sent_count = 0
total_errors = 0
for hyp, ref in zip(open(args.hyps), open(args.refs)):
	hyp = hyp.strip().split()
	ref = ref.strip().split()
	errors = levenshtein(hyp, ref)
	total_errors += errors
	sent_count += 1

print 1.0 * total_errors / sent_count
