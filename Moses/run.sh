#!/bin/bash

## Parameters of the request:
#PBS -q normal
#PBS -l nodes=1:ppn=32
#PBS -l walltime=24:00:00

## Job name:
#PBS -N build_moses

## Where to save STDOUT and STDERR:
#PBS -o /home/armatthe/streams/build_moses.out
#PBS -e /home/armatthe/streams/build_moses.err

## Export environment variables from the submitting environment:
#PBS -V

cd /home/armatthe/Research/Pipelines/Moses
tconf="fbis.tconf"
./moses.tape -p Full -y -C $tconf -j 40 
