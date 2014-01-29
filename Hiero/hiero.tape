#!/usr/bin/env ducttape

global {
  ducttape_experimental_submitters=enable
  ducttape_experimental_imports=enable
}

import ../submitters.tape

task Tokenize
    < corpus=(DataSection:
                train=$train_corpus
                tune=$tune_corpus
                test=$test_corpus)
    > tokenized_corpus
    :: tokenize_corpus=@
    :: cdec_dir=@
    :: .submitter=shell .walltime="01:00:00" .cpus=1 .vmem=2g .q=shared {
  if [[ $tokenize_corpus == "false" ]]; then
    cp $corpus $tokenized_corpus
  else
    cat $corpus | $cdec_dir/corpus/tokenize-anything.sh > $tokenized_corpus
  fi
}

task Lowercase
    < corpus=$tokenized_corpus@Tokenize
    > lowercased_corpus
    :: lowercase_corpus=@
    :: cdec_dir=@
    :: .submitter=shell .walltime="01:00:00" .cpus=1 .vmem=2g .q=shared {
  if [[ $lowercase_corpus == "false" ]]; then
    cp $corpus $lowercased_corpus
  else
    cat $corpus | $cdec_dir/corpus/lowercase.pl > $lowercased_corpus
  fi
}

task FilterCorpus
    < corpus=$lowercased_corpus@Lowercase[DataSection:train]
    > filtered_corpus
    :: max_sentence_length=@
    :: cdec_dir=@
    :: .submitter=shell .walltime="01:00:00" .cpus=1 .vmem=2g .q=shared {
  if (( $max_sentence_length > 0 )); then
    $cdec_dir/corpus/filter-length.pl -$max_sentence_length $corpus > $filtered_corpus
  else
    cp $corpus $filtered_corpus
  fi
}

task AlignS2T
    < corpus=$filtered_corpus@FilterCorpus
    > alignment
    :: cdec_dir=@
    :: .submitter=shell .walltime="12:00:00" .cpus=1 .vmem=32g .q=shared {
  $cdec_dir/word-aligner/fast_align -i $corpus -d -v -o > $alignment
}

task AlignT2S
    < corpus=$filtered_corpus@FilterCorpus
    > alignment
    :: cdec_dir=@
    :: .submitter=shell .walltime="12:00:00" .cpus=1 .vmem=32g .q=shared {
  $cdec_dir/word-aligner/fast_align -i $corpus -d -v -o -r > $alignment
}

task Symmetrize
    < s2tAlignment=$alignment@AlignS2T
    < t2sAlignment=$alignment@AlignT2S
    > alignment
    :: cdec_dir=@
    :: .submitter=shell .walltime="01:00:00" .cpus=1 .vmem=2g .q=shared {
  $cdec_dir/utils/atools -i $s2tAlignment -j $t2sAlignment -c grow-diag-final-and > $alignment
}

# TODO: UseCustomAlignments: yes is broken if we do corpus filtering.
#       Avoid this by either setting UseCustomAlignments: no, or by
#       setting max_sentence_length=0, which disables filtering.
task BuildSuffixArray
     < corpus=$filtered_corpus@FilterCorpus
     < alignment=(UseCustomAlignment: 
                    no=$alignment@Symmetrize
                    yes=$alignment)  
     > ini
     > suffix_array
    :: cdec_dir=@
    :: .submitter=shell .walltime="48:00:00" .cpus=1 .vmem=33g .q=shared {
  export PYTHONPATH=`echo $cdec_dir/python/build/lib.*`
  python -m cdec.sa.compile -b $corpus -a $alignment -c $ini -o $suffix_array
}

task ExtractGrammars
    < corpus=(ExtractSection:
                tune=$lowercased_corpus@Lowercase[DataSection:tune]
                test=$lowercased_corpus@Lowercase[DataSection:test])
    < ini=@BuildSuffixArray
    > wrapped_corpus
    > grammar_dir
    :: cores=1
    :: cdec_dir=@
    :: .submitter=shell .walltime="24:00:00" .cpus=1 .vmem=33g .q=shared {
  export PYTHONPATH=`echo $cdec_dir/python/build/lib.*`
  cat $corpus | python -m cdec.sa.extract -c $ini -g $grammar_dir -j $cores -z > $wrapped_corpus
}

task BuildLanguageModel
    < corpus=$filtered_corpus@FilterCorpus
    < lm_data=@
    > language_model
    :: lm_order=@
    :: cdec_dir=@
    :: .submitter=shell .walltime="06:00:00" .cpus=1 .vmem=33g .q=shared {
  corpus_target="./corpus_target"
  $cdec_dir/corpus/cut-corpus.pl 2 $corpus > $corpus_target
  cat $corpus_target $lm_data | $cdec_dir/klm/lm/builder/builder --order $lm_order -T /usr2/home/austinma/tmp/lm > $language_model
}

task CompileLanguageModel
    < arpa=$language_model@BuildLanguageModel
    > language_model
    :: cdec_dir=@
    :: .submitter=shell .walltime="06:00:00" .cpus=1 .vmem=33g .q=shared {
  $cdec_dir/klm/lm/build_binary $arpa $language_model
}

task MakeCdecIni
    < language_model=(UseCustomLM:
                        no=$language_model@CompileLanguageModel
                        yes=$language_model)
    > cdec_ini {
  echo "formalism=scfg" > $cdec_ini
  echo "add_pass_through_rules=true" >> $cdec_ini
  echo "feature_function=KLanguageModel $language_model" >> $cdec_ini
  echo "feature_function=WordPenalty" >> $cdec_ini
  echo "feature_function=NonLatinCount" >> $cdec_ini
  echo "feature_function=RuleShape" >> $cdec_ini
}

task Tune
    < tune_set=$wrapped_corpus@ExtractGrammars[ExtractSection:tune]
    < cdec_ini=@MakeCdecIni
    > mira_work
    > optimized_weights
    :: cores=$decode_cores
    :: cdec_dir=@
    :: .submitter=shell .walltime="48:00:00" .cpus=32 .vmem=60g .q=normal {

  python $cdec_dir/training/mira/mira.py --jobs $cores --kbest-size 500 -d $tune_set -o $mira_work -c $cdec_ini --step-size 0.001 >mira_out.txt 2>mira_err.txt
  ln -s $mira_work/weights.final $optimized_weights
}

task TuneWithMert
    < tune_set=$wrapped_corpus@ExtractGrammars[ExtractSection:tune]
    < cdec_ini=@MakeCdecIni
    > mert_work
    > optimized_weights
    :: cores=$decode_cores
    :: cdec_dir=@
    :: .submitter=shell .walltime="48:00:00" .cpus=32 .vmem=60g .q=normal {
  initialWeights="./initialWeights.txt"
  echo 'CountEF 0.19419531547'            >> $initialWeights
  echo 'EgivenFCoherent -0.143753598764'  >> $initialWeights
  echo 'Glue -0.15449154903'              >> $initialWeights
  echo 'LanguageModel 0.272887994276'     >> $initialWeights
  echo 'MaxLexEgivenF 0.0533512109614'    >> $initialWeights
  echo 'MaxLexFgivenE -0.0946672851272'   >> $initialWeights
  echo 'IsSingletonF 0.025706841532'      >> $initialWeights
  echo 'IsSingletonFE -0.0523385640397'   >> $initialWeights
  echo 'LanguageModel_OOV -0.22058847817' >> $initialWeights
  echo 'NonLatinCount -0.01'              >> $initialWeights
  echo 'PassThrough -0.223671632264'      >> $initialWeights
  echo 'PassThrough_1 -0.00179887258152'  >> $initialWeights
  echo 'PassThrough_2 -0.0165592335722'   >> $initialWeights
  echo 'PassThrough_3 -0.0596159465362'   >> $initialWeights
  echo 'PassThrough_4 -0.0756845014188'   >> $initialWeights
  echo 'PassThrough_5 -0.0630230674949'   >> $initialWeights
  echo 'PassThrough_6 -0.00699001065989'  >> $initialWeights
  echo 'SampleCountF 0.0670507378596'     >> $initialWeights
  echo 'WordPenalty -0.0677495426343'     >> $initialWeights

  cp $cdec_ini ./cdec.ini
  echo 'density_prune=100.0' >> cdec.ini

  perl $cdec_dir/training/dpmert/dpmert.pl --devset $tune_set --weights $initialWeights --jobs $cores --output-dir $mert_work --config ./cdec.ini
  ln -s $mert_work/weights.final $optimized_weights
}
task Decode
    < test_set=(TuneOrTest:
        test=$wrapped_corpus@ExtractGrammars[ExtractSection:test]
        tune=$wrapped_corpus@ExtractGrammars[ExtractSection:tune])
    < cdec_ini=@MakeCdecIni
    < weights=(Optimizer: mira=$optimized_weights@Tune mert=$optimized_weights@TuneWithMert)
    > kbest
    > output
    :: k=1000
    :: cores=$decode_cores
    :: cdec_dir=@
    :: .submitter=shell .walltime="6:00:00" .cpus=32 .vmem=60g .q=normal {

  cat $test_set | $cdec_dir/corpus/cut-corpus.pl 1 | cdec -c $cdec_ini -w $weights -k $k -r > $kbest
  sed 's/ ||| /\t/g' $kbest | sort -u -k 1,1 -n | cut -f 2 > $output
}

task Evaluate 
    < output=$output@Decode
    < refs=(TuneOrTest: test=$test_corpus tune=$tune_corpus)
    > bleu meteor ter length
    :: multeval=@
    :: meteor_lang=@
    :: .submitter=shell .walltime="00:20:00" .cpus=1 .vmem=4g .q=shared {
  METEORTASK=li
  METEORLANG=$meteor_lang
  scoreFile=scores.txt

  num_refs=$(head -n 1 $refs | grep -o '|||' | wc -l)
  for i in `seq 1 $num_refs`; do
    cut -f $(expr 3 \* $i + 1) -d '|' $refs | sed 's/^\s*//' | sed 's/\s*$//' > refs.$i
  done

  ln -s $(dirname $multeval)/constants .
  $multeval eval --refs refs.* --hyps-baseline $output --meteor.task $METEORTASK --meteor.language $METEORLANG &> $scoreFile
  tail -n 2 $scoreFile | head -n 1 | sed 's/(\S\+)//g' | sed 's/\s\+/\t/g' | cut -f 2 > $bleu
  tail -n 2 $scoreFile | head -n 1 | sed 's/(\S\+)//g' | sed 's/\s\+/\t/g' | cut -f 3 > $meteor
  tail -n 2 $scoreFile | head -n 1 | sed 's/(\S\+)//g' | sed 's/\s\+/\t/g' | cut -f 4 > $ter
  tail -n 2 $scoreFile | head -n 1 | sed 's/(\S\+)//g' | sed 's/\s\+/\t/g' | cut -f 5 > $length
}

summary EvaluationSummary {
  of Evaluate > Score {
    cp $bleu $Score
  }
}
