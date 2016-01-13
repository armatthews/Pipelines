import sys

scores = []
sep = '|||'

for line in sys.stdin:
  _, __, prob, ref = line.strip().split(sep)
  prob = float(prob)
  ref = int(ref)
  scores.append((prob, ref))

total_ref_positives = len([_ for (prob, ref) in scores if ref == 1])
total_ref_positives_so_far = 0
total_so_far = 0
for prob, ref in sorted(scores, reverse=True):
  total_so_far += 1
  total_ref_positives_so_far += 1 if ref == 1 else 0
  precision = 1.0 * total_ref_positives_so_far / total_so_far
  recall = 1.0 * total_ref_positives_so_far / total_ref_positives
  fscore = 2 * precision * recall / (precision + recall) if precision + recall > 0.0 else 0.0
  print '\t'.join(map(str, [prob, precision, recall, fscore]))
