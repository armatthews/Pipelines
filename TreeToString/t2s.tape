#!/usr/bin/env ducttape

global {
  ducttape_experimental_submitters=enable
  ducttape_experimental_imports=enable
  full_node_scheduler=shell
  #full_node_scheduler=torque_normal
  partial_node_scheduler=shell
  #partial_node_scheduler=torque_shared
  tiny_task=2g
  small_task=4g
  medium_task=30g
  #medium_task=32g
  big_task=30g
  #big_task=60g
  many_cpus=8
  #many_cpus=32
}

import ../submitters.tape

task GetSurfaceCorpus
    < in_corpus=$train_corpus
    > corpus
    :: cdec_dir=@
    :: .submitter=$partial_node_scheduler .walltime="1:00:00" .cpus=1 .vmem=$medium_task .q=shared {
  $cdec_dir/corpus/cut-corpus.pl 1 $in_corpus | sed 's/ \([^ )]\+\))\+/ \1/g' | sed 's/([^ ]* //g' > source
  $cdec_dir/corpus/cut-corpus.pl 2 $in_corpus > target
  $cdec_dir/corpus/paste-files.pl source target > $corpus
}

task AlignS2T
    < corpus=@GetSurfaceCorpus
    > alignment
    :: cdec_dir=@
    :: .submitter=$partial_node_scheduler .walltime="12:00:00" .cpus=1 .vmem=$medium_task .q=shared {
  $cdec_dir/word-aligner/fast_align -i $corpus -d -v -o > $alignment
}

task AlignT2S
    < corpus=@GetSurfaceCorpus
    > alignment
    :: cdec_dir=@
    :: .submitter=$partial_node_scheduler .walltime="12:00:00" .cpus=1 .vmem=$medium_task .q=shared {
  $cdec_dir/word-aligner/fast_align -i $corpus -d -v -o -r > $alignment
}

task Symmetrize
    < s2tAlignment=$alignment@AlignS2T
    < t2sAlignment=$alignment@AlignT2S
    > alignment
    :: cdec_dir=@
    :: .submitter=$partial_node_scheduler .walltime="01:00:00" .cpus=1 .vmem=$tiny_task .q=shared {
  $cdec_dir/utils/atools -i $s2tAlignment -j $t2sAlignment -c grow-diag-final-and > $alignment
}

task LexicalProbs
    < corpus=@GetSurfaceCorpus
    < alignment=@Symmetrize
    > e2f
    > f2e
    :: scriptDir=@
    :: cdec_dir=@
    :: .submitter=$partial_node_scheduler .walltime="01:00:00" .cpus=1 .vmem=$medium_task {
  $cdec_dir/corpus/cut-corpus.pl 1 $corpus > source
  $cdec_dir/corpus/cut-corpus.pl 2 $corpus > target
  perl $scriptDir/lex.perl --f source --e target --a $alignment --f2e $f2e --e2f $e2f
  rm source target
}

task ExtractGrammar
    < corpus=$train_corpus
    < alignment=@Symmetrize
    > grammar
    :: flags=(MinimalRules: yes="-m -s 1000" no="-s 5")
    :: grammar_extractor_dir=@
    :: cdec_dir=@
    :: .submitter=$full_node_scheduler .walltime="02:00:00" .cpus=$many_cpus .q=normal {
  mkdir output
  mkdir tmp
  paste $corpus $alignment | sed 's/\t/ ||| /g' > tmp/corpus
  for i in $(seq -f %02g 1 $cpus); do
    split -n l/$i/$cpus tmp/corpus | $cdec_dir/corpus/cut-corpus.pl 1 > tmp/src$i
    split -n l/$i/$cpus tmp/corpus | $cdec_dir/corpus/cut-corpus.pl 2 > tmp/tgt$i
    split -n l/$i/$cpus tmp/corpus | $cdec_dir/corpus/cut-corpus.pl 3 > tmp/aln$i
  done
  seq -f %02g 1 $cpus | parallel -j $cpus "pypy $grammar_extractor_dir/hg_rule_extractor.py tmp/src{} tmp/tgt{} tmp/aln{} --t2s -d $flags > output/out_{} 2> output/err_{}; echo $? > exit_codes.txt"
  cat output/out_* | grep -v ^Sentence > $grammar
  if [[ $(grep '[^0]' exit_codes.txt | wc -l) != 0 ]]; then
    echo 'Non-zero exit code found in exit_codes.txt.' >&2
    exit 1
  fi
  rm -rf tmp
}

task ScoreGrammar
    < grammar=@ExtractGrammar
    < e2f=@LexicalProbs
    < f2e=@LexicalProbs
    > scored_grammar {
  pv $grammar | sed 's/ ||| /\t/g' | LC_ALL=C sort -k 1,4 -t $'\t' | sed 's/\t/ ||| /g' | python /usr0/home/austinma/git/grascore-t2s/collect_rule_counts.py > tmp1
  pv tmp1 | sed 's/ ||| /\t/g' | LC_ALL=C sort -k 1,1 -t $'\t' | sed 's/\t/ ||| /g' | python /usr0/home/austinma/git/grascore-t2s/score_phrase_sgt.py 2,2 1,1 -n phrase_tgs > tmp2
  pv tmp2 | sed 's/ ||| /\t/g' | LC_ALL=C sort -k 2,2 -t $'\t' | sed 's/\t/ ||| /g' | python /usr0/home/austinma/git/grascore-t2s/score_phrase_sgt.py 1,1 2,2 -n phrase_sgt > tmp3
  pv tmp3 | python /usr0/home/austinma/git/grascore-t2s/score_lex_probs.py $e2f $f2e -n lex_sgt -m lex_tgs > tmp4
  pv tmp4 | python /usr0/home/austinma/git/grascore-t2s/log_feats.py -r > $scored_grammar
}

task MakeCdecIni
    < scored_grammar=@ScoreGrammar
    < language_model=@
    > cdec_ini
    :: pop_limit=@ {
  echo "formalism=t2s" > $cdec_ini
  echo "add_pass_through_rules=true" >> $cdec_ini 
  echo "feature_function=KLanguageModel $language_model" >> $cdec_ini
  echo "feature_function=WordPenalty" >> $cdec_ini 
  echo "grammar=$scored_grammar" >> $cdec_ini
  echo "cubepruning_pop_limit=$pop_limit" >> $cdec_ini

  # Do these work in t2s?
  #echo "feature_function=NonLatinCount" >> $cdec_ini
  #echo "feature_function=RuleShape" >> $cdec_ini
  #echo "feature_function=ArityPenalty" >> $cdec_ini
}


task Tune
    < tune_set=$tune_corpus
    < cdec_ini=@MakeCdecIni
    > mira_work
    > optimized_weights
    :: cores=$decode_cores
    :: cdec_dir=@
    :: .submitter=$full_node_scheduler .walltime="48:00:00" .cpus=$many_cpus .vmem=$big_task .q=normal {

  python $cdec_dir/training/mira/mira.py --jobs $cores --kbest-size 500 -d $tune_set -o $mira_work -c $cdec_ini --step-size 0.001 -w /usr0/home/austinma/git/Pipelines/TreeToString/weights.final >mira_out.txt 2>mira_err.txt
  ln -s $mira_work/weights.final $optimized_weights
}

task TuneWithPro
    < tune_set=$tune_corpus
    < cdec_ini=@MakeCdecIni
    > pro_work
    > optimized_weights
    :: cores=$decode_cores
    :: cdec_dir=@
    :: .submitter=$full_node_scheduler .walltime="48:00:00" .cpus=$many_cpus .vmem=$big_task .q=normal {
  initialWeights="./initialWeights.txt"
  echo "Glue 0" >> $initialWeights
  perl $cdec_dir/training/pro/pro.pl --weights $initialWeights --config $cdec_ini --devset $tune_set --output-dir $pro_work --jobs $cores
  ln -s $pro_work/weights.final $optimized_weights
}

task TuneWithMert
    < tune_set=$tune_corpus
    < cdec_ini=@MakeCdecIni
    > mert_work
    > optimized_weights
    :: cores=$decode_cores
    :: cdec_dir=@
    :: .submitter=$full_node_scheduler .walltime="48:00:00" .cpus=$many_cpus .vmem=$big_task .q=normal {
  initialWeights="./initialWeights.txt"

  echo 'LanguageModel 1.12'            >> $initialWeights
  echo 'LanguageModel_OOV -1.12'       >> $initialWeights
  echo 'log_lex_sgt 0.52'     >> $initialWeights
  echo 'log_lex_tgs 0.94'     >> $initialWeights
  echo 'log_phrase_sgt 1.81'  >> $initialWeights
  echo 'log_phrase_tgs 2.91'  >> $initialWeights
  echo 'PassThrough 0.861338' >> $initialWeights
  echo 'rarity -0.07'         >> $initialWeights
  echo 'WordPenalty -1'       >> $initialWeights

  cp $cdec_ini ./cdec.ini
  echo 'density_prune=100.0' >> cdec.ini

  perl $cdec_dir/training/dpmert/dpmert.pl --devset $tune_set --weights $initialWeights --jobs $cores --output-dir $mert_work --config ./cdec.ini --random-directions 50 --iterations 30
  ln -s $mert_work/weights.final $optimized_weights
}

task Decode
    < test_set=(TuneOrTest:
        test=$test_corpus
        tune=$tune_corpus)
    < cdec_ini=@MakeCdecIni
    < weights=(Optimizer: mira=$optimized_weights@Tune mert=$optimized_weights@TuneWithMert pro=$optimized_weights@TuneWithPro)
    > kbest
    > output
    :: k=1000
    :: cores=$decode_cores
    :: cdec_dir=@
    :: .submitter=$full_node_scheduler .walltime="6:00:00" .cpus=$many_cpus .vmem=$big_task .q=normal {

  cat $test_set | $cdec_dir/corpus/cut-corpus.pl 1 | cdec -c $cdec_ini -w $weights -k $k -r > $kbest
  sed 's/ ||| /\t/g' $kbest | sort -u -k 1,1 -n | cut -f 2 > $output
}

task Evaluate 
    < output=$output@Decode
    < refs=(TuneOrTest: test=$test_corpus tune=$tune_corpus)
    > bleu meteor ter length
    :: multeval=@
    :: meteor_task=@
    :: meteor_lang=@
    :: cdec_dir=@
    :: .submitter=$partial_node_scheduler .walltime="00:20:00" .cpus=1 .vmem=$tiny_task .q=shared {
  METEORTASK=$meteor_task
  METEORLANG=$meteor_lang
  scoreFile=scores.txt

  num_refs=$(head -n 1 $refs | grep -o '|||' | wc -l)
  for i in `seq 1 $num_refs`; do
    $cdec_dir/corpus/cut-corpus.pl $i $refs | sed 's/^\s*//' | sed 's/\s*$//' > refs.$i
  done

  ln -s $(dirname $multeval)/constants .
  $multeval eval --refs refs.* --hyps-baseline $output --meteor.task $METEORTASK --meteor.language $METEORLANG &> $scoreFile
  tail -n 2 $scoreFile | head -n 1 | sed 's/(\S\+)//g' | sed 's/\s\+/\t/g' | cut -f 2 > $bleu
  tail -n 2 $scoreFile | head -n 1 | sed 's/(\S\+)//g' | sed 's/\s\+/\t/g' | cut -f 3 > $meteor
  tail -n 2 $scoreFile | head -n 1 | sed 's/(\S\+)//g' | sed 's/\s\+/\t/g' | cut -f 4 > $ter
  tail -n 2 $scoreFile | head -n 1 | sed 's/(\S\+)//g' | sed 's/\s\+/\t/g' | cut -f 5 > $length
}

summary EvaluationSummary {
  of Evaluate > Bleu Meteor TER Length {
    cp $bleu Bleu
    cp $meteor $Meteor
    cp $ter $TER
    cp $length $Length
  }
}
