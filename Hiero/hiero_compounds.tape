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
  #medium_task=30g
  medium_task=32g
  #big_task=30g
  big_task=60g
  #many_cpus=8
  many_cpus=32
}

import ../submitters.tape

task AddSentenceBoundaryTags
    < in_corpus=(DataSection:
        train=$train_corpus
        tune=$tune_corpus
        test=$test_corpus)
    < in_alignment=(DataSection:
        train=$alignment 
        tune="/dev/null"
        test="/dev/null")
    > corpus
    > alignment
    :: cdec_dir=@
    :: .submitter=shell .walltime="1:00:00" .cpus=1 .vmem=1g .q=shared {
  if [[ $in_alignment == "/dev/null" ]]; then
    perl $cdec_dir/corpus/add-sos-eos.pl $in_corpus > $corpus
    cat $in_alignment > $alignment
  else
    perl $cdec_dir/corpus/add-sos-eos.pl $in_corpus $in_alignment $alignment > $corpus
  fi
}

task BuildSuffixArray
     < corpus=(UseSentenceBoundaries:
         no=$train_corpus
         yes=$corpus@AddSentenceBoundaryTags[DataSection:train])
     < alignment=(UseSentenceBoundaries:
         no=$alignment
         yes=$alignment@AddSentenceBoundaryTags[DataSection:train])
     > ini
     > suffix_array
    :: cdec_dir=@
    :: .submitter=$partial_node_scheduler .walltime="48:00:00" .cpus=1 .vmem=$medium_task .q=shared {
  zcat -f $corpus > ./corpus
  zcat -f $alignment > ./alignment
  #/usr/bin/python -m cdec.sa.compile -b ./corpus -a ./alignment -c $ini -o $suffix_array
  $cdec_dir/extractor/sacompile -b ./corpus -a ./alignment -c $ini -o $suffix_array
  rm ./alignment ./corpus
}

task ExtractGrammars
    < corpus=(UseSentenceBoundaries:
        no=(DataSection:
          train=$train_corpus
          tune=$tune_corpus
          test=$test_corpus)
        yes=$corpus@AddSentenceBoundaryTags)
    < ini=@BuildSuffixArray
    > wrapped_corpus
    > grammar_dir
    :: cores=32
    :: cdec_dir=@
    :: .submitter=$partial_node_scheduler .walltime="48:00:00" .cpus=1 .vmem=$medium_task .q=shared {
  export PYTHONPATH=`echo $cdec_dir/python/build/lib.*`
  #cat $corpus | /usr/bin/python -m cdec.sa.extract -c $ini -g $grammar_dir -j $cores -z > $wrapped_corpus
  zcat -f $corpus | $cdec_dir/extractor/extract -c $ini -g $grammar_dir -t $cores --gzip > $wrapped_corpus
}

task MakeCdecIni
    < language_model=@
    < brown_language_model=@
    < oxlm_language_model=@
    > cdec_ini
    :: use_sentence_boundaries_flag=(UseSentenceBoundaries: no="" yes="-x")
    :: use_non_latin_count=(UseNonLatinCount: no yes)
    :: use_ruleshape=(UseRuleShape: no yes)
    #:: use_ruleshape2=(UseRuleShape2: no yes)
    :: use_arity_penalty=(UseArityPenalty: no yes)
    :: use_ngram_features=(UseNGramFeatures: no yes)
    #:: use_source_ngram_features=(UseSourceNGramFeatures: no yes)
    :: use_source_path_features=(UseSourcePathFeatures: no yes)
    #:: use_source_lm=(UseSourceLM: no yes)
    :: use_oxlm=(UseOxLM: no conditional)
    :: oxlm_module_path=@
    :: oxlm_flags=@
    :: source_cluster_map=@
    :: target_cluster_map=@
    :: scfg_max_span_limit=@ 
    :: cubepruning_pop_limit=@
    :: compound_grammar=@ {
  echo "formalism=scfg" > $cdec_ini
  echo "scfg_max_span_limit=$scfg_max_span_limit" >> $cdec_ini
  echo "cubepruning_pop_limit=$cubepruning_pop_limit" >> $cdec_ini

  echo "add_pass_through_rules=true" >> $cdec_ini 
  echo "feature_function=WordPenalty" >> $cdec_ini
  echo "feature_function=KLanguageModel $use_sentence_boundaries_flag $language_model" >> $cdec_ini

  if [[ $brown_language_model != "/dev/null" ]]; then
    echo "feature_function=KLanguageModel $use_sentence_boundaries_flag -m $target_cluster_map $brown_language_model" >> $cdec_ini
  fi 
  if [[ $use_non_latin_count == "yes" ]]; then
    echo "feature_function=NonLatinCount" >> $cdec_ini
  fi
  if [[ $use_rule_shape == "yes" ]]; then
    echo "feature_function=RuleShape" >> $cdec_ini
  fi
  if [[ $use_arity_penalty == "yes" ]]; then
    echo "feature_function=ArityPenalty" >> $cdec_ini
  fi
  if [[ $use_ngram_features == "yes" ]]; then
    echo "feature_function=NgramFeatures -o 2 -c $target_cluster_map" >> $cdec_ini
  fi
  if [[ $use_source_path_features == "yes" ]]; then
    echo "feature_function=SourcePathFeatures" >> $cdec_ini # Chris says to be leery of these
  fi
  if [[ $oxlm_language_model != "/dev/null" ]]; then
    echo "feature_function=External $oxlm_module_path --file $oxlm_model_path $oxlm_flags" >> $cdec_ini
  fi
  echo "grammar=$compound_grammar" >> $cdec_ini
}

task Tune
    < tune_set=$wrapped_corpus@ExtractGrammars[DataSection:tune]
    < cdec_ini=@MakeCdecIni[TuneOrTest:tune]
    > mira_work
    > optimized_weights
    :: metric_flag=(TuneMetric:
         bleu=" "
         meteor="-m meteor --no-pseudo --sent-approx")
    :: cores=$decode_cores
    :: cdec_dir=@ 
    :: .submitter=$full_node_scheduler .walltime="48:00:00" .cpus=$many_cpus .vmem=$big_task .q=normal {

  /usr/bin/python $cdec_dir/training/mira/mira.py --jobs $cores $metric_flag --kbest-size 500 -d $tune_set -o $mira_work -c $cdec_ini --step-size 0.001 \
    >mira_out.txt 2>mira_err.txt

  ln -s $mira_work/weights.final $optimized_weights
}

task TuneWithMert
    < tune_set=$wrapped_corpus@ExtractGrammars[DataSection:tune]
    < cdec_ini=@MakeCdecIni[TuneOrTest:tune]
    > mert_work
    > optimized_weights
    :: metric_flag=(TuneMetric:
         bleu=" "
         meteor="--metric meteor")
    :: cores=$decode_cores
    :: cdec_dir=@
    :: .submitter=$full_node_scheduler .walltime="48:00:00" .cpus=$many_cpus .vmem=$big_task .q=normal {
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

  perl $cdec_dir/training/dpmert/dpmert.pl $metric_flag --devset $tune_set --weights $initialWeights --jobs $cores --output-dir $mert_work --config ./cdec.ini
  ln -s $mert_work/weights.final $optimized_weights
}

task Decode
    < test_set=(TuneOrTest:
        test=$wrapped_corpus@ExtractGrammars[DataSection:test]
        tune=$wrapped_corpus@ExtractGrammars[DataSection:tune])
    < cdec_ini=@MakeCdecIni
    < weights=(Optimizer:
        mira=$optimized_weights@Tune
        mert=$optimized_weights@TuneWithMert)
    > kbest
    > output
    :: k=1000
    :: cores=$decode_cores
    :: cdec_dir=@
    :: script_dir=@
    :: .submitter=$full_node_scheduler .walltime="6:00:00" .cpus=$many_cpus .vmem=$big_task .q=normal {

  cat $test_set | $cdec_dir/corpus/cut-corpus.pl 1 | $script_dir/embarrassingly_parallel.sh $cores cdec -c $cdec_ini -w $weights -k $k -r > $kbest
  sed 's/ ||| /\t/g' $kbest | sort -u -k 1,1 -n | cut -f 2 | sed 's/<\/\?s>//g' | sed 's/\s\+/ /g' | sed 's/^\s*\|\s*$//g' > $output
}

task Evaluate 
    < output=$output@Decode
    < refs=(TuneOrTest: test=$test_corpus tune=$tune_corpus)
    > bleu meteor ter length
    :: multeval=@
    :: meteor_task=@
    :: meteor_lang=@
    :: .submitter=$partial_node_scheduler .walltime="00:20:00" .cpus=1 .vmem=$medium_task .q=shared {
  scoreFile=scores.txt

  num_refs=$(head -n 1 $refs | grep -o '|||' | wc -l)
  for i in `seq 1 $num_refs`; do
    cut -f $(expr 3 \* $i + 1) -d '|' $refs | sed 's/^\s*//' | sed 's/\s*$//' > refs.$i
  done

  ln -s $(dirname $multeval)/constants .
  $multeval eval --refs refs.* --hyps-baseline $output --meteor.task $meteor_task --meteor.language $meteor_lang &> $scoreFile
  tail -n 2 $scoreFile | head -n 1 | sed 's/(\S\+)//g' | sed 's/\s\+/\t/g' | cut -f 2 > $bleu
  tail -n 2 $scoreFile | head -n 1 | sed 's/(\S\+)//g' | sed 's/\s\+/\t/g' | cut -f 3 > $meteor
  tail -n 2 $scoreFile | head -n 1 | sed 's/(\S\+)//g' | sed 's/\s\+/\t/g' | cut -f 4 > $ter
  tail -n 2 $scoreFile | head -n 1 | sed 's/(\S\+)//g' | sed 's/\s\+/\t/g' | cut -f 5 > $length
}

summary EvaluationSummary {
  of Evaluate > BLEU METEOR TER len {
    cp $bleu $BLEU
    cp $meteor $METEOR
    cp $ter $TER
    cp $length $len
  }
}
