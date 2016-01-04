import sys
import argparse
import gzip

parser = argparse.ArgumentParser()
parser.add_argument('grammar')
args = parser.parse_args()

vocab = set()
grammar_file = gzip.open(args.grammar) if args.grammar.endswith('.gz') else open(args.grammar)
print >>sys.stderr, 'Reading grammar...'
for i, line in enumerate(grammar_file):
	if i % 10000 == 9999:
		sys.stderr.write('.')
	_, source, _ = line.split('|||', 2)
	source = source.strip().decode('utf-8').split()
	if len(source) == 1:
		vocab.add(source[0])

print >>sys.stderr
print >>sys.stderr, 'Reading dev set...'
for line in sys.stdin:
	parts = line.decode('utf-8').strip().split('\t', 1)
	source = parts[0]
	source = source.strip().split()
	for word in source:
		if word not in vocab:
			line = '[X] ||| %s ||| %s ||| SyntheticPassThrough=1 ||| |||' % (word, ' '.join(word))
			print line.encode('utf-8')
