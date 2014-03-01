import sys
import gzip
import sgml
import argparse
import xml.etree.ElementTree as ElementTree

def extract_vocab_from_rules(rules):
	vocab = set()
	for lhs, src_rhs, tgt_rhs, features, alignment in rules:	
		src_symbols = [symbol.strip() for symbol in src_rhs.split() if len(symbol.strip()) != 0]
		src_words = [word for word in src_symbols if word[0] != '[' or word[-1] != ']']
		for word in src_words:
			vocab.add(word)
	return vocab

oovs = set()
for line in sys.stdin:
	line = line.decode('utf-8')
	parts = [part.strip() for part in line.split('|||')]
	source_sgml = parts[0]
	source_sgml = source_sgml.replace('<s>', '&lt;s&gt;').replace('</s>', '&lt;/s&gt;')
	segment = sgml.Segment.from_string(source_sgml)
	vocab = extract_vocab_from_rules(segment.rules)

	segment.text = segment.text.replace('&lt;s&gt;', '<s>').replace('&lt;/s&gt;', '</s>')
	words = [word.strip() for word in segment.text.split() if len(word.strip()) != 0]
	for word in words:
		if word not in vocab and word not in oovs:
			oovs.add(word)
			print word.encode('utf-8')
