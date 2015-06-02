import sys
from tree import TreeNode, TerminalNode

function_word_list = ['the', 'a', 'and', 'of', '\'s', '\'', 's', 'an', 'to', 'be', 'on', 'up', 'down', 'in', 'out', 'through'] + \
		     ['am', 'are', 'is', 'was', 'been', '-', ',', '.', 'not', 'at', 'for', 'off', 'an', 'mr', 'mrs', 'take', 'takes'] + \
		     ['taking', 'taken', 'took', 'make', 'making', 'made', 'makes', 'do', 'doing', 'done', 'did', 'does', '"'] + \
		     ['have', 'having', 'had', 'has', 'should', 'may', 'can', 'would', 'will', 'might', 'could', 'shall', 'its'] + \
		     ['this', 'that', 'these', 'those', 'by', 'with', 'my', 'mine', 'your', 'yours', 'i', 'you', 'from', 'into'] + \
		     ['us', 'our', 'we', 'ours', 'they', 'them', 'their', 'theirs', 'his', 'her', 'hers', 'him', 'were', 'being'] + \
		     ['no', 'who', 'as', 'so', 'just', 'it', 'it\'s']

def parse_alignment(s, include_possible_links):
	links = []
	for token in s.strip().split():
		token = token.strip()
		if len(token) == 0:
			continue
		if len(token.split('-')) == 2:
			i, j = token.split('-')
			i, j = int(i), int(j)
			links.append((i, j))
		elif len(token.split('?')) == 2:
			if include_possible_links:
				i, j = token.split('?')
				i, j = int(i), int(j)
				links.append(i, j)
		else:
			raise Exception('Invalid alignment link: "%s"' % token)
	return links

def is_function_word(word):
	global function_word_list
	return word in function_word_list

def remove_function_words(bag):
	global function_word_list
	for word in function_word_list:
		while word in bag:
			bag.remove(word)
	return bag

line_num = 0
for line in sys.stdin:
	line_num += 1
	source, target, alignment = [part.strip() for part in line.split('|||')]
	source = source.split()
	target = target.split()
	alignment = parse_alignment(alignment, False)

	# A target word is considered a compound if it meets the following criteria
        # 1) It must be at least 5 characters long
        # 2) It must be aligned to at least two content (i.e. non-function) words
	# 3) The span to which it is aligned must be at most 5 English words long
        # 4) There must be no unaligned content words between the words too which it is aligned
	for t, word in enumerate(target):
		# Criterion 1
		if len(word) < 5 and word != '-':
			continue

		# Quick check for criterion 2
		if word != '-':
			alignments = [i for (i, j) in alignment if j == t]
		else:
			alignments = [i for (i, j) in alignment if j == t or j == t - 1 or j == t + 1]
		if len(alignments) < 2:
			continue

		# Criterion 2
		aligned_words = [source[s] for s in alignments]
		if len(remove_function_words(set(aligned_words))) < 2:
			continue

		# Criterion 3
		min_i = min(alignments)
		max_i = max(alignments)
		if max_i - min_i >= 5:
			continue

		# Criterion 4
		valid = True
		for i in range(min_i, max_i + 1):
			if i not in alignments and not is_function_word(source[i]):
				valid = False
		if not valid:
			continue

		rev_aligned_words = [j for (i, j) in alignment if i >= min_i and i <= max_i]
		valid = True
		for j in rev_aligned_words:
			if word != '-' and j != t:
				valid = False
			elif word == '-' and j != t - 1 and j != t and j != t + 1:
				valid = False
		if not valid:
			continue
		

		parts = []
		parts.append(str(line_num))
		parts.append(str(t))
		parts.append(' '.join(map(str, alignments)))
		if word != '-':
			parts.append(word)
		else:
			parts.append(''.join(target[max(t - 1, 0):min(t + 2, len(target))]))
		parts.append(' '.join(source[min_i : max_i + 1]))
		print '\t'.join(parts)
