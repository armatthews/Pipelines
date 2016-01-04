#!/usr/bin/env python
import sys
import nltk

for line in sys.stdin:
  parts = line.strip().decode('utf8').split('\t', 1)
  eng = parts[0]
  tagged = nltk.pos_tag(eng.split())
  tags = [tup[1] for tup in tagged]
  print ' '.join(tags)
