#!/bin/bash

## Parameters of the request:
#PBS -q normal
#PBS -l nodes=1:ppn=32
#PBS -l walltime=24:00:00

## Job name:
#PBS -N syntax

## Where to save STDOUT and STDERR:
#PBS -o /home/armatthe/streams/build_syntax.out
#PBS -e /home/armatthe/streams/build_syntax.err

## Export environment variables from the submitting environment:
#PBS -V

### specify your project allocation
##PBS -A


## Run actual program here:

set -e
set -o pipefail
set -u
set -x

cd /home/armatthe/Research/Pipelines/Syntax
tconf="fbis.tconf"
./timber.tape -p Full -y -C $tconf
