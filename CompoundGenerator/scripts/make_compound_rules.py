import sys
import argparse
from math import log

parser = argparse.ArgumentParser()
parser.add_argument('phrases')
args = parser.parse_args()

phrases = [line.split('\t')[0].strip().decode('utf-8') for line in open(args.phrases).readlines()]

prev_sent_id = None
i = 0
for line in sys.stdin:
	line = line.decode('utf-8')
	parts = [part.strip() for part in line.strip().split('|||')]
	sent_id = int(parts[0])
	if sent_id != prev_sent_id:
		i = 0
	i += 1
	prev_sent_id = sent_id

	if i > 100:
		continue
	target = parts[1].replace(' ', '')
	score = float(parts[3])

	contains_digit = ''
	for c in '1234567890':
		if c in target:
			contains_digit = 'CompoundContainsDigit=1'
			break

	rule = '[X] ||| %s ||| %s ||| SynthCompound=1 CompoundScore=%f CompoundLogRank%d=1 %s ||| 0-0' % (phrases[sent_id], target, score / 100, int(log(i) / log(1.6)), contains_digit)
	print rule.encode('utf-8')
