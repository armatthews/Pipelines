import sys

for line in sys.stdin:
	line = line.decode('utf-8')
	for word in line.split():
		print 'O',
	print
