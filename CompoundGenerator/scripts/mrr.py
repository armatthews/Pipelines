import sys
import argparse

parser = argparse.ArgumentParser()
parser.add_argument('refs')
args = parser.parse_args()

refs = open(args.refs)
sent_id = None
ref = None
j = 0 # index into the kbest list

sent_count = 0 # count of sentences seen so far. This is usually equal to sent_id + 1, but not always!
done = False # Keep track of whether or not we've already hit the reference

sum_rr = 0.0

for line in sys.stdin:
	i, hyp, feats, score = [part.strip() for part in line.decode('utf-8').strip().split('|||')]
	i = int(i)
	if i != sent_id:
		sent_id = i
		ref = refs.readline().decode('utf-8').strip()
		j = 0
		sent_count += 1
		done = False
	j += 1

	if hyp == ref and not done:
		sum_rr += 1.0 / j
		done = True

print sum_rr / sent_count
