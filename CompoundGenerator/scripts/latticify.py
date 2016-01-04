import sys
import argparse
import codecs
import itertools
from math import log, floor
from collections import defaultdict, Counter, namedtuple

LatticeEdge = namedtuple('LatticeEdge', 'to_node, label, features')

class Lattice:
	# 0 is always the start node
	# Node count ranges from [0, N - 1]
	def __init__(self):
		self.node_count = 1
		self.edges = defaultdict(list)

	def __len__(self):
		return self.node_count

	# Adds as many nodes as needed to ensure that node_id
	# is in [0, N - 1]
	def add_node(self, node_id):
		if node_id >= self.node_count:
			self.node_count = node_id + 1

	def add_edge(self, from_node, to_node, label, features):
		self.add_node(from_node)
		self.add_node(to_node)
		self.edges[from_node].append(LatticeEdge(to_node, label, features))

	def to_plf(self):
		assert len(self.edges[len(self) - 1]) == 0
		plf = []
		plf.append('(')
		for i in range(len(self) - 1):
			plf.append('(')
			for edge in self.edges[i]:
				plf.append('(')
				plf.append('\'%s\',' % escape(edge.label))
				plf.append('{')
				plf.append(','.join('\'%s\':%f' % (escape(f), v) for f, v in edge.features.iteritems()))
				plf.append('},')
				#plf.append('1.0,')
				plf.append('%d' % (edge.to_node - i))
				plf.append('),')
			plf.append('),')
		plf.append(')')
		return ''.join(plf)

def escape(word):
	return word.replace('\\', '\\\\').replace('\'', '\\\'')

def powerset(iterable):
	"powerset([1,2,3]) --> () (1,) (2,) (3,) (1,2) (1,3) (2,3) (1,2,3)"
	s = list(iterable)
	return itertools.chain.from_iterable(itertools.combinations(s, r) for r in range(len(s) + 1))

# Note words are NOT in order
# The first word in this sequence is actually
# words[permutation[0]]
def compute_path_features(original, words, dropped_words, permutation, pos=False):
	def getword(w):
		if pos:	return w[0][1]
		else: return w[1]

	def getindex(w):
		if pos: return str(w[0][0])
		else: return str(w[0])

	features = defaultdict(float)
        drop_lex = '_'.join(sorted([getword(w) for w in dropped_words]))
        drop_count = 0
	pos_drop_count = defaultdict(int)
        drop_index = '_'.join([getindex(w) for w in dropped_words])
	keep_index = '_'.join([getindex(words[ind]) for ind in permutation])
	for word, count in dropped_words.iteritems():
		features['drop_lex_%s' % getword(word)] = count
		loglen = int(log(len(getword(word))) / log(1.6))
		features['drop_wordlen_%d' % loglen] += 1
                drop_count += count
		if pos:
			pos_drop_count[word[1]] += count

	features['drop_count'] = drop_count
	features['drop_%d_words' % drop_count] = 1.0
        for tag in pos_drop_count:
		features['drop_pos_%s' % tag] = pos_drop_count[tag]

	if pos:
		orig_tag = '_'.join([w[1] for w in original])
		features['path_pos_conj_keep_index_'+orig_tag+'_'+keep_index] = 1.0
		drop_pos = '_'.join(sorted([tup[1] for tup in dropped_words]))
		features['drop_pos_path_'+drop_pos] = 1.0
		keep_pos = '_'.join([words[ind][1] for ind in permutation])
		features['keep_pos_'+keep_pos] = 1.0
		features['path_pos_'+keep_pos+'_drop_'+drop_pos] = 1.0
                features['keep_pos_index_'+'_'.join([str(ind)+words[ind][1] for ind in permutation])] = 1.0

	features['drop_lex_path_'+drop_lex] = 1.0
	features['drop_index_path_'+drop_index] = 1.0
        keep_lex = '_'.join([getword(words[ind]) for ind in permutation])
	features['keep_lex_'+keep_lex] = 1.0
        features['keep_index_'+keep_index] = 1.0
        features['index_path_keep_'+keep_index+'_drop_'+drop_index] = 1.0

	monotonic = True
	for i in range(1, len(permutation)):
		if permutation[i] < permutation[i - 1]:
			monotonic = False
	if monotonic:
		features['monotonic'] = 1
	return features

def add_feature_sets(feats1, feats2):
	r = defaultdict(float)
	for k, v in feats1.iteritems():
		r[k] = v
	for k, v in feats2.iteritems():
		r[k] += v
	return r 

def compute_edge_features(word, pos=None, suff=False, end=False):
	features = defaultdict(float)
        if suff:
                features['uses_suff'] = 1.0
                features['suff_%s' % word] = 1.0
		if pos:	features['suff_%s' % pos] = 1.0
        elif end:
                features['uses_end'] = 1.0
                features['end_%s' % word] = 1.0
		if pos:	features['end_%s' % pos] = 1.0
        else:
		features['keep_%s' % word] = 1.0
		if pos:	features['keep_%s' % pos] = 1.0
	return features

# Outputs a lattice path and returns the ID of the last node in that path
def add_lattice_path(original, lattice, words, dropped_words, permutation, pos=False):
	next_state = len(lattice)
	path_features = compute_path_features(
				original,
				words, dropped_words,
				permutation, pos=pos)
	final_edges = []

	prev_state = 0
	for i, j in enumerate(permutation):
		if pos:
			word = words[j][0][1]
                        #index = words[j][0][0]
			tag = words[j][1]
		else:
			word = words[j][1]
			#index = words[j][0]
		next_state = len(lattice)
		if pos:
			features = compute_edge_features(word, tag)
		else:	features = compute_edge_features(word)
		if i == 0:
			features = add_feature_sets(features, path_features)
		lattice.add_edge(prev_state, next_state, word, features)
		if i != len(permutation) - 1:
			lattice.add_edge(prev_state, next_state + 1, word, features)
			if not args.no_sufs:
				if pos:	features = compute_edge_features(word, tag, suff=True)
				else:	features = compute_edge_features(word, suff=True)
				lattice.add_edge(next_state, next_state + 1, '<suf>', features)
		if i == len(permutation) - 1:
			final_edges.append((prev_state, word, features))
			if not args.no_ends:
				if pos:	features = compute_edge_features(word, tag, suff=True)
				else:	features = compute_edge_features(word, suff=True)
				final_edges.append((next_state, '<end>', features))
		prev_state = next_state + 1

	return final_edges

parser = argparse.ArgumentParser()
parser.add_argument('-p', '--pos', help='File containing pos tagged input')
parser.add_argument('--no_sufs', help='Disable medial suffixes in lattices', action='store_true')
parser.add_argument('--no_ends', help='Disable final suffixes in lattices', action='store_true')
parser.add_argument('--keep_content', help='Don\'t allow dropping of content words', action='store_true')
args = parser.parse_args()

if args.keep_content and not args.pos:
	print >>sys.stderr, '--keep_content flag requires --pos to be set'
	sys.exit(1)

if args.pos:
  pos_file = open(args.pos)

sys.stdout = codecs.getwriter('utf-8')(sys.stdout)
for line in sys.stdin:
	line = line.decode('utf-8').strip()
	words = [word for word in enumerate(line.split()) if len(word) > 0]
        if args.pos:
		pos_line = pos_file.readline().strip()
		tags = [pos for pos in pos_line.split() if len(pos) > 0]
                assert(len(tags) == len(words))
		words = zip(words, tags)
	word_counter = Counter(words)
	lattice = Lattice()
	final_edges = []

	valid_word_sets = [word_set for word_set in powerset(words) if len(word_set) >= 2]
	for word_set in valid_word_sets:
		dropped_words = word_counter - Counter(word_set)
		if args.keep_content:
			valid = True
			for word, pos in dropped_words:
				if pos in 'NN NNS JJ VBG VBD RB VBP VBN VBZ VB JJR JJS RBR RBS NNP CD'.split():
					valid = False
					break
			if not valid:
				continue
		for permutation in itertools.permutations(range(len(word_set))):
			features = defaultdict(float)
			final_edges += add_lattice_path(
				words,
				lattice, word_set,
				dropped_words, permutation, pos=args.pos)

	# For each node that was on the end of a path,
	# add an epsilon transition to the single end state
	end_node = len(lattice)
	for from_state, label, features in final_edges:
		lattice.add_edge(from_state, end_node, label, features)

	print lattice.to_plf()
