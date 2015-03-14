import sys
import subprocess
from collections import defaultdict
from tree import TreeNode, TerminalNode

def remove_function_words(bag_of_words):
	for word in ['the', 'a', 'and', 'of', '\'s', '\'', 's', 'an', 'to', 'be', 'on', 'up', 'down', 'in', 'out', 'through'] + \
		['am', 'are', 'is', 'was', 'been', '.', ',', '-LRB-', '-RRB-', 'it', 'for', 'with', 'and', 'at', 'this', 'that'] + \
                ['some', 'which', 'as', 'by', 'who']:
		while word in bag_of_words:
			bag_of_words.remove(word)
	return bag_of_words

def form_constituent(words, tree):
	if not isinstance(tree, TerminalNode):
		terms = set(map(str, tree.find_terminals()))
	else:
		terms = set([str(tree)])
	words = set(words)
	terms = remove_function_words(terms)
	words = remove_function_words(words)
	if terms == words:
		return True
	elif words <= terms and not isinstance(tree, TerminalNode):
		for child in tree.children:
			if form_constituent(words, child):
				return True
	return False

def span_covers_indices(span, indices):
	for index in indices:
		if span[0] > index or index >= span[1]:
			return False
	return True

def find_covering_constituant(indices, tree):
	assert span_covers_indices(tree.span, indices)

	while True:
		found = False
		for child in tree.children:
			if not isinstance(child, TerminalNode) and span_covers_indices(child.span, indices):
				tree = child
				found = True
				break
		if not found:
			break
	return tree

def bracket_crossing_level(indices, tree):
	parent = find_covering_constituant(indices, tree)
	return distance_to_nodes(indices, parent) - 2

def annotate_spans(tree, start=0):
	if isinstance(tree, TerminalNode):
		tree.span = (start, start + 1)
	else:
		end = start
		for child in tree.children:
			annotate_spans(child, end)
			end = child.span[1]
		tree.span = (start, end)

def distance_to_nodes(indices, tree, nodes_seen=set()):
	assert(tree not in nodes_seen)
	if isinstance(tree, TerminalNode):
		if tree.span[0] in indices:
			return 0
		else:
			return -1
	else:
		max_child_distance = -2
		nodes_seen.add(tree)
		for child in tree.children:
			d = distance_to_nodes(indices, child, nodes_seen)
			if d > max_child_distance:
				max_child_distance = d
		nodes_seen.remove(tree)
		return max_child_distance + 1
		#child_distances = [distance_to_nodes(indices, child, nodes_seen) for child in tree.children if distance_to_nodes(indices, child) >= 0 and child != tree]
		#if len(child_distances) > 0:
		#	return max(child_distances) + 1
		#else:
		#	return -1

def findConstituentSpans(tree):
	spans = defaultdict(set)	
	if not isinstance(tree, TerminalNode):
		spans[tree.span].add(tree.label)
		for child in tree.children:
			spans.update(findConstituentSpans(child))
	else:
		spans[tree.span].add('<terminal:%s>' % tree.word)
	return spans

def parse(sentences):
        command = 'java -jar /usr0/home/austinma/svn/berkeleyparser-read-only/BerkeleyParser.jar -gr /usr0/home/austinma/svn/berkeleyparser-read-only/eng_sm6.gr -accurate -tokenize'
        parser_process = subprocess.Popen(command.split(), stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        for sentence in sentences:
                out, err = parser_process.communicate(sentence)
                assert out[0] == '('
                assert out[-2] == ')'
                assert out[-1] == '\n'
                # err holds the stderr stream from Berkeley, which can be useful
                yield out[1:-2].strip()

line_num = 0
for line in sys.stdin:
	line_num += 1
	source, tree_string = [part.strip() for part in line.split('|||')]
	source = source.split()

	# Sometimes Berkeley outputs broken trees. In this case, just skip this input sentence
	if tree_string.strip() == '()' or not tree_string.strip():
		continue

	# Read in the tree structure
	tree = TreeNode.from_string(tree_string)
	annotate_spans(tree)
	constituent_spans = findConstituentSpans(tree)

	# Ensure that the tree represents the input sentence correctly
	if [w.lower() for w in source] != [str(node).lower() for node in tree.find_terminals()]:
		continue

	# Extract POS tags for each terminal
	pos_tags = [node.label for node in tree.find_preterminals()]
	if len(pos_tags) != len(source):
		continue

	sys.stderr.write('Processing line %d\n' % line_num)
	for i in range(len(source) - 1):
		for j in range(i + 2, min(i + 6, len(source) + 1)):
			span = (i, j)
			covering_constituant = find_covering_constituant(list(range(i, j)), tree)
			bracket_crossing_level = distance_to_nodes(list(range(i, j)), covering_constituant) - 2
			is_constit = 1 if span in constituent_spans else 0
			prev_tag = pos_tags[i - 1] if i > 0 else '<s>'
			next_tag = pos_tags[j] if j < len(source) else '</s>'
			sys.stdout.write('%s\t' % ' '.join(source[i:j]))
			print line_num, i, j,
			print (j - i), prev_tag, pos_tags[i], pos_tags[j - 1], next_tag,
			print len(source[i]), len(source[j - 1]),
			print covering_constituant.label, bracket_crossing_level, is_constit
