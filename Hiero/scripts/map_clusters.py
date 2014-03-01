import sys
import argparse
from collections import defaultdict

parser = argparse.ArgumentParser()
parser.add_argument('cluster_map')
parser.add_argument('--prefix_length', '-p', type=int, default=0, help='Keep only the first p characters of each cluster ID')
args = parser.parse_args()

clusters = defaultdict(lambda: '<unk>')
cluster_file = open(args.cluster_map)
for line in cluster_file:
	line = line.decode('utf-8').strip()
	cluster, word, count = [part.strip() for part in line.split('\t')]
	if args.prefix_length != 0:
		cluster = cluster[:args.prefix_length]
	clusters[word] = cluster

for line in sys.stdin:
	words = line.decode('utf-8').strip().split()
	print ' '.join([clusters[word] for word in words]).encode('utf-8')
