import sys

for line in sys.stdin:
	parts = line.decode('utf-8').strip().split('\t')
	print '\t'.join(' '.join(part) for part in parts).encode('utf-8')
