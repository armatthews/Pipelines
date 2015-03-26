import sys
import argparse

parser = argparse.ArgumentParser()
parser.add_argument('refs')
args = parser.parse_args()

ref_file = open(args.refs)
sent_id = None
ref = None
j = 0 # index into the kbest list

sent_count = 0 # count of sentences seen so far. This is usually equal to sent_id + 1, but not always!
done = False # Keep track of whether or not we've already hit the reference

sum_rr = 0.0
inf = float('inf')
indices = []

for line in sys.stdin:
	i, hyp, feats, score = [part.strip() for part in line.decode('utf-8').strip().split('|||')]
	i = int(i)
	if i != sent_id:
		if not done:
			indices.append(inf)
		sent_id = i
		refs = [ref.strip() for ref in ref_file.readline().decode('utf-8').split('\t')]
		j = 0
		sent_count += 1
		done = False
	j += 1

	if hyp in refs and not done:
		indices.append(j)
		sum_rr += 1.0 / j
		done = True

for k in [1, 5, 10]:
	print 'p@%d: %f' % (k, 1.0 * len([1 for i in indices if i <= k]) / sent_count)
print 'mrr: %f' % (sum_rr / sent_count)
