#coding: utf-8
import sys
import gzip
import argparse
from collections import namedtuple
import xml.etree.ElementTree as ElementTree

Segment = namedtuple('Segment', 'text, attrib')
GrammarRule = namedtuple('GrammarRule', 'lhs, src_rhs, tgt_rhs, features, alignment')

class Segment:
	@staticmethod
	def from_string(sgml):
		sgml = sgml.encode('utf-8') if isinstance(sgml, unicode) else sgml
		 # The parser doesn't appreciate ampersands that aren't part of XML entities
		sgml = sgml.replace('&', '&amp;');	
		root = ElementTree.fromstring(sgml)
		text = root.text if isinstance(root.text, unicode) else root.text.decode('utf-8')
		attrib = {key.decode('utf-8') : value.decode('utf-8') for key, value in root.attrib.iteritems()}	
		return Segment(text, attrib)

	def __init__(self, text='', attrib={}):
		self.text = text
		self.attrib = attrib

	def __str__(self):
		root = ElementTree.Element("seg", self.attrib)
		root.text = self.text
		return ElementTree.tostring(root, 'utf-8').replace('&amp;', '&')

	def add_grammar(self, filename):
		i = 0
		while True:
			attrib_name = ('grammar%d' % i) if i > 0 else 'grammar'
			if attrib_name not in self.attrib:
				self.attrib[attrib_name] = filename
				return
			i += 1

	@staticmethod
	def read_grammar(stream):
	        for line in stream:
        	        line = line.decode('utf-8')
                	parts = tuple(part.strip() for part in line.split('|||'))
			if len(parts) == 4:
				yield GrammarRule(*parts, alignment='')
			elif len(parts) == 5:
		                yield GrammarRule(*parts)
			else:
				raise Exception('Invalid grammar format!')

	@property
	def rules(self):
		for key, value in self.attrib.iteritems():
			if key.startswith('grammar'):
				with gzip.open(value) as f:
					for rule in Segment.read_grammar(f):
						yield rule

		
if __name__ == "__main__":
	sgml = "<seg id=\"0\" grammar=\"/oasis/projects/nsf/cmu126/armatthe/Research/Systems/dede-enus-wmt14/ducttape/MakeGlueGrammars/Corpus.cleaner+DataSection.tune/grammar_dir/pt.0.gz\" grammar1=\"/oasis/projects/nsf/cmu126/armatthe/Research/Systems/dede-enus-wmt14/ducttape/MakeGlueGrammars/Corpus.cleaner+DataSection.tune/grammar_dir/pt.1.gz\">  This & नमस्ते &amp; text   </seg>"	
#	sgml = "<seg id=\"0\" grammar=\"/oasis/projects/nsf/cmu126/armatthe/Research/Systems/dede-enus-wmt14/ducttape/MakeGlueGrammars/Corpus.cleaner+DataSection.tune/grammar_dir/pt.0.gz\" grammar1=\"/oasis/projects/nsf/cmu126/armatthe/Research/Systems/dede-enus-wmt14/ducttape/MakeGlueGrammars/Corpus.cleaner+DataSection.tune/grammar_dir/pt.1.gz\">  <s> This & नमस्ते &amp; text </s>   </seg>"	
	segment = Segment.from_string(sgml)
	print segment.text
	print segment.attrib
	print segment
	#for rule in segment.rules:
	#	print rule
