#!/usr/bin/env bash
set -eou pipefail

pieces=$1
shift
file=$1
shift
command="$@"

temp_dir=$(mktemp -d --tmpdir=$HOME/tmp)
echo "Using temporary directory $temp_dir" >&2

ln -s $PWD/$file $temp_dir/input
#while read -r line
#do
#  echo "$line" >> $temp_dir/input
#done

line_count=$(cat ${temp_dir}/input | wc -l)
lines_per_part=$(expr $(expr $line_count + $pieces - 1) / $pieces)

suffix_length=$(expr $(echo "$pieces" | wc -c) - 1)
mkdir $temp_dir/split
mkdir $temp_dir/output
mkdir $temp_dir/error
split -d -a $suffix_length -l $lines_per_part $temp_dir/input $temp_dir/split/

seq -f "%0${suffix_length}g" 0 $(expr $pieces - 1) | parallel -j $pieces "cat $temp_dir/split/{} | $command 2> >(gzip > $temp_dir/error/{}) | gzip > $temp_dir/output/{}"

for i in `seq -f "%0${suffix_length}g" 0 $(expr $pieces - 1)`; do
  zcat $temp_dir/output/$i
  zcat $temp_dir/error/$i >&2
done
