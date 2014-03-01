import os
import sys
import sgml
import argparse

parser = argparse.ArgumentParser()
parser.add_argument('grammar')
args = parser.parse_args()

for line in sys.stdin:
	line = line.decode('utf-8').strip()
	parts = [part.strip() for part in line.split('|||')]
	parts[0] = parts[0].replace('<s>', '&lt;s&gt;').replace('</s>', '&lt;/s&gt;')
	segment = sgml.Segment.from_string(parts[0])
	segment.add_grammar(args.grammar)
	parts[0] = str(segment).decode('utf-8')
	parts[0] = parts[0].replace('&lt;s&gt;', '<s>').replace('&lt;/s&gt;', '</s>')
	print ' ||| '.join(parts).encode('utf-8')
