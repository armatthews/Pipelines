import sys
import argparse
import itertools

parser = argparse.ArgumentParser()
parser.add_argument('original')
args = parser.parse_args()

original_file = open(args.original)
line_number = 0
for original_line, output_line in itertools.izip_longest(original_file, sys.stdin):
  line_number += 1
  assert original_line is not None, 'Original input file is shorter than output file!'
  assert output_line is not None, 'Output file is shorter than input file!'
  original_words = original_line.decode('utf-8').strip().split()
  output_words = output_line.decode('utf-8').strip().split()
  if len(original_words) != len(output_words):
    print >>sys.stderr, 'Mismatch between number of words and tags on line', line_number
  assert len(original_words) == len(output_words)

  pos_tags = []
  for i in range(len(original_words)):
    rev_output_word = output_words[i][::-1]
    j = rev_output_word.find('_')
    assert j != -1 and j < len(rev_output_word) - 1
    pos = rev_output_word[:j][::-1]
    word_copy = rev_output_word[j + 1:][::-1]
    if word_copy != original_words[i]:
      print >>sys.stderr, 'Error on line number', line_number
      print >>sys.stderr, 'Word copy:'
      for c in word_copy:
        print >>sys.stderr, '%d\t%s' % (ord(c), c)
      print >>sys.stderr, 'Original word:'
      for c in original_words[i]:
        print >>sys.stderr, '%d\t%s' % (ord(c), c)
    #assert word_copy == original_words[i], 'Mismatch between input and output words on line %d: %s != %s, pos=%s' % (line_number, word_copy, original_words[i], pos)
    pos_tags.append(pos)
  print ' '.join(pos_tags).encode('utf-8')
