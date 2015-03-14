import sys
from math import log
from collections import Counter

suffix_counts = Counter()
end_counts = Counter()
def update_counts(analyses):
	for analysis in analyses:
		parts = analysis.split()
		pairs = [part.split('+', 1) for part in parts]
		for pair in pairs:
			if len(pair) != 2:
				print >>sys.stderr, 'Invalid pair:', pair
				print >>sys.stderr, 'Part of analysis:', analysis
				print >>sys.stderr, 'From line #', line_number
			assert len(pair) == 2
		for (stem, suf) in pairs[:-1]:
			suffix_counts[suf] += 1.0 / len(analyses)
		for (stem, end) in pairs[-1:]:
			end_counts[end] += 1.0 / len(analyses)

analyses = []
prev_line_number = None
for line in sys.stdin:
	parts = [part.strip() for part in line.decode('utf-8').strip().split('|||')]
	# line number, analysis, alignment, features
	assert len(parts) == 4
	line_number = int(parts[0])
	analysis = parts[1] 
	if line_number != prev_line_number:
		update_counts(analyses)
		analyses = []
	prev_line_number = line_number
	analyses.append(analysis)

if len(analyses) > 0:
	update_counts(analyses)
	analyses = []

def output_line(suf_type, suffix, log_prob):
	line = '[X] ||| <%s> ||| %s ||| fwd=%f uses_%s_%s=1.0 ||| |||' % (suf_type, ' '.join(suffix), log_prob, suf_type, suffix)
	print line.encode('utf-8')

total_count = sum(suffix_counts.values())
for suffix, count in suffix_counts.iteritems():
	output_line('suf', suffix, log(count) - log(total_count))

total_count = sum(end_counts.values())
for end, count in end_counts.iteritems():
	output_line('end', end, log(count) - log(total_count))
