import sys
from math import log
from collections import defaultdict

lines = []
sums = defaultdict(int)
for line in sys.stdin:
  parts = line.strip().split()
  cluster, word, count = parts
  count = int(count)
  lines.append((cluster, word, count))
  sums[cluster] += count

for cluster, word, count in lines:
  print '%s %s %f' % (cluster, word, log(count) - log(sums[cluster]))
