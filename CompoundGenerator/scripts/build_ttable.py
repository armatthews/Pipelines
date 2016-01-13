import sys
from collections import defaultdict

ttable = defaultdict(lambda:defaultdict(int))
source_counts = defaultdict(int)
target_counts = defaultdict(int)

for line in sys.stdin:
  source, target, alignment = [part.strip() for part in line.decode('utf-8').split('|||')]
  source = source.split()
  target = target.split()
  alignment = [map(int, link.split('-')) for link in alignment.split()]
  for i, j in alignment:
    s = source[i]
    t = target[j]
    source_counts[s] += 1
    target_counts[t] += 1
    ttable[s][t] += 1

for s, tt in ttable.iteritems():
  for t, c in tt.iteritems():
    print ('%s\t%s\t%f\t%f' % (s, t, 1.0 * c / source_counts[s], 1.0 * c / target_counts[t])).encode('utf-8')
