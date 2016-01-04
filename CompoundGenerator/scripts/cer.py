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
for hyp, refs in zip(open(args.hyps), open(args.refs)):
	hyp = hyp.strip().split()
	min_errors = sys.maxint
	for ref in refs.split('\t'):
		ref = ref.strip().split()
		errors = levenshtein(hyp, ref)
		if errors < min_errors:
			min_errors = errors
	assert min_errors != sys.maxint
	total_errors += min_errors
	sent_count += 1

if sent_count > 0:
	print 1.0 * total_errors / sent_count
else:
	print 0.0
