import sys

lemma_map = {}
for line in open(sys.argv[1]):
  parts = line.decode('utf-8').strip().split('\t')
  key = parts[0].strip()
  val = parts[1].strip().split()
  #if key in lemma_map:
  #  print >>sys.stderr, 'Duplicate key found in lemma map:', key
  #  assert False
  lemma_map[key] = val

print >>sys.stderr, 'Done loading lemma map!'
for line in sys.stdin:
  words = line.decode('utf-8').strip().split()
  lemmas = []
  indices = []
  for i, word in enumerate(words):
    word = word.lower()
    if word in lemma_map:
      lemma = lemma_map[word]
      lemmas += lemma
      indices += list(i for _ in range(len(lemma)))
    else:
      lemmas.append(word)
      indices.append(i)
  print ' ||| '.join([' '.join(lemmas), ' '.join(map(str, indices))]).encode('utf-8')
