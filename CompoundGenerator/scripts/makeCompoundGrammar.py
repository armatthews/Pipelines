import sys
import argparse

parser = argparse.ArgumentParser()
parser.add_argument('input_phrases')
parser.add_argument('kbest_list')
args = parser.parse_args()

f = open(args.input_phrases)
input_phrases = [line.decode('utf-8').strip() for line in f.readlines()]
f.close()

f = open(args.kbest_list)
for line in f:
	line = line.decode('utf-8').strip()
	parts = [part.strip() for part in line.split('|||')]
	sent_no, compound, feats, score = parts
	sent_no = int(sent_no)
	score = float(score)
	compound = compound.replace(' ', '')
	print '[X] ||| %s ||| %s ||| OracleCompound=1 CompoundScore=%f ||| ' % (input_phrases[sent_no].encode('utf-8'), compound.encode('utf-8'), score)
	print '[X] ||| %s ||| %s ||| OracleCompound=1 CompoundScore=%f CompoundUpper=1 ||| ' % (input_phrases[sent_no].encode('utf-8'), compound.title().encode('utf-8'), score)

f.close()
