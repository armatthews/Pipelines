import sys
import argparse
from collections import defaultdict

parser = argparse.ArgumentParser()
parser.add_argument('spans', help='Each line should be line number [tab] start-end, with start being included, and end not being included.')
args = parser.parse_args()

spans = defaultdict(list)
with open(args.spans) as f:
  for line in f:
    line_number, span = line.strip().split('\t')
    line_number = int(line_number)
    span = map(int, span.split('-'))
    spans[line_number].append(span)

line_number = -1
for line in sys.stdin:
  line_number += 1
  line_spans = spans[line_number]
  if len(line_spans) == 0:
    continue

  words = line.strip().split()
  for start, end in line_spans:
    assert start >= 0
    assert start < end
    assert end <= len(words), 'Line %d does not have %d words!' % (line_number, end)
    print ' '.join(words[start : end])
