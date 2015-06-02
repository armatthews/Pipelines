import sys

prev = -1
curr = -1
for line in sys.stdin:
	sent_id, remainder = line.split('|||', 1)
	sent_id = int(sent_id.strip())
	if sent_id != prev:
		if sent_id == prev + 1:
			curr += 1
		elif sent_id == 0:
			curr += 1
		else:
			assert False
		prev = sent_id
	print curr, '|||', remainder.strip()
