#!/bin/bash

## Parameters of the request:
#PBS -q normal
#PBS -l nodes=1:ppn=32
#PBS -l walltime=24:00:00

## Job name:
#PBS -N build_hiero

## Where to save STDOUT and STDERR:
#PBS -o /home/armatthe/streams/build_hiero.out
#PBS -e /home/armatthe/streams/build_hiero.err

## Export environment variables from the submitting environment:
#PBS -V

cd /home/armatthe/Research/Pipelines/Hiero
tconf="enus-msa-20130728.tconf"
./hiero.tape -p Full -y -C $tconf -j 40
