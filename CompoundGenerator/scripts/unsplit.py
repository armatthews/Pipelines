import sys

for line in sys.stdin:
  alignment, mapping = [part.strip() for part in line.decode('utf-8').split('\t')]

  alignment = [map(int, link.split('-')) for link in alignment.split()]
  mapping = map(int, mapping.split())

  new_alignment = []
  for i, j in alignment:
    j = mapping[j]
    new_alignment.append('%d-%d' % (i, j))
  print ' '.join(new_alignment)
