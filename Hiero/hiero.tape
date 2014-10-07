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

task AlignS2T
    < corpus=$train_corpus
    > alignment
    :: cdec_dir=@
    :: .submitter=$partial_node_scheduler .walltime="12:00:00" .cpus=1 .vmem=$medium_task .q=shared {
  $cdec_dir/word-aligner/fast_align -i $corpus -d -v -o > $alignment
}

task AlignT2S
    < corpus=$train_corpus
    > alignment
    :: cdec_dir=@
    :: .submitter=$partial_node_scheduler .walltime="12:00:00" .cpus=1 .vmem=$medium_task .q=shared {
  $cdec_dir/word-aligner/fast_align -i $corpus -d -v -o -r > $alignment
}

task Symmetrize
    < s2tAlignment=$alignment@AlignS2T
    < t2sAlignment=$alignment@AlignT2S
    > alignment
    :: heuristic=(AlignSym: gdfa="grow-diag-final-and" gd="grow-diag")
    :: cdec_dir=@
    :: .submitter=$partial_node_scheduler .walltime="01:00:00" .cpus=1 .vmem=$tiny_task .q=shared {
  $cdec_dir/utils/atools -i $s2tAlignment -j $t2sAlignment -c $heuristic > $alignment
}

task AddSentenceBoundaryTags
    < in_corpus=(DataSection:
                  train=$train_corpus
                  tune=$tune_corpus
                  test=$test_corpus)
    < in_alignment=(DataSection:
                      train=$alignment@Symmetrize 
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
                    no=$alignment@Symmetrize
                    yes=$alignment@AddSentenceBoundaryTags[DataSection:train])
     > ini
     > suffix_array
    :: cdec_dir=@
    :: .submitter=$partial_node_scheduler .walltime="48:00:00" .cpus=1 .vmem=$medium_task .q=shared {
  export PYTHONPATH=`echo $cdec_dir/python/build/lib.*`
  python -m cdec.sa.compile -b $corpus -a $alignment -c $ini -o $suffix_array
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
    :: cores=1
    :: cdec_dir=@
    :: .submitter=$partial_node_scheduler .walltime="48:00:00" .cpus=1 .vmem=$medium_task .q=shared {
  export PYTHONPATH=`echo $cdec_dir/python/build/lib.*`
  cat $corpus | python -m cdec.sa.extract -c $ini -g $grammar_dir -j $cores -z > $wrapped_corpus
}

task TagPassthroughs
    < test_set=(DataSection:
                  train=$train_corpus
                  tune=$tune_corpus
                  test=$test_corpus)
    > bio_tags
    :: magic="Something Swabha gives me? lol"
    :: script_dir=@
    :: cdec_dir=@
    :: .submitter=$partial_node_scheduler .walltime="4:00:00" .cpus=1 .vmem=$medium_task .q=shared {
  pv $test_set | $cdec_dir/corpus/cut-corpus.pl 1 | python $script_dir/tag_passthroughs.py > $bio_tags
}

task MakeGlueGrammars
    < test_set=(DataSection:
                  train=$train_corpus
                  tune=$tune_corpus
                  test=$test_corpus)
    < bio_tags=@TagPassthroughs
    > grammar_dir
    :: script_dir=@
    :: cdec_dir=@
    :: .submitter=$partial_node_scheduler .walltime="4:00:00" .cpus=1 .vmem=$medium_task .q=shared {
  mkdir -p $grammar_dir
  script_location="/usr0/home/cdyer/wmt14/make-self-translations.pl"
  $cdec_dir/corpus/paste-files.pl <(perl $cdec_dir/corpus/cut-corpus.pl 1 $test_set) $bio_tags | \
    perl $script_dir/make-self-translations.pl $grammar_dir
}

task LMBrownClusters
    < lm_data=@
    < corpus=$train_corpus
    < target_cluster_map=@
    > out_lm_data
    > out_corpus
    :: cdec_dir=@
    :: script_dir=@
    :: .submitter=$partial_node_scheduler .walltime="4:00:00" .cpus=2 .vmem=$medium_task .q=shared {
  zcat -f $lm_data | python $script_dir/map_clusters.py $target_cluster_map | gzip > $out_lm_data
  zcat -f $corpus | $cdec_dir/corpus/cut-corpus.pl 2 | python $script_dir/map_clusters.py $target_cluster_map > ./out_corpus_tgt

  # Repackage the test corpus as a parallel corpus, as the BuildLanguageModel expects one
  $cdec_dir/corpus/paste-files.pl <(zcat -f $corpus | $cdec_dir/corpus/cut-corpus.pl 1) ./out_corpus_tgt > $out_corpus
  rm ./out_corpus_tgt
}    

task BuildLanguageModel
    < corpus=(LMType:
                 surface=$train_corpus
                 brown=$out_corpus@LMBrownClusters)
    < lm_data=(LMType:
                 surface=$lm_data
                 brown=$out_lm_data@LMBrownClusters)
    > language_model
    :: lm_order=(LMType:
                   surface=$lm_order
                   brown=$brown_lm_order)
    :: use_custom_lm=@
    :: custom_lm=@
    :: cdec_dir=@
    :: .submitter=$partial_node_scheduler .walltime="06:00:00" .cpus=1 .vmem=$medium_task .q=shared {
  if [[ $use_custom_lm == "true" ]]; then
     ln -s $custom_lm $language_model
  else
     corpus_target="./corpus_target"
     $cdec_dir/corpus/cut-corpus.pl 2 $corpus > $corpus_target
     zcat -f $lm_data >> $corpus_target
     $cdec_dir/klm/lm/builder/lmplz --order $lm_order -T . -S 10% < $corpus_target > $language_model
     rm $corpus_target
  fi
}

task CompileLanguageModel
    < arpa=$language_model@BuildLanguageModel
    > language_model
    :: lm_quant_flags=@
    :: use_custom_lm=@
    :: custom_lm=@
    :: cdec_dir=@
    :: .submitter=$partial_node_scheduler .walltime="06:00:00" .cpus=1 .vmem=$medium_task .q=shared {
 if [[ $use_custom_lm == "true" ]]; then
     ln -s $custom_lm $language_model
 elif [[ -z $lm_quant_flags ]]; then
     $cdec_dir/klm/lm/build_binary trie $arpa $language_model
 else
     $cdec_dir/klm/lm/build_binary $lm_quant_flags trie $arpa $language_model
 fi
}

task MakeCdecIni
    < language_model=$language_model@CompileLanguageModel[LMType:surface]
    > cdec_ini
    :: use_sentence_boundaries_flag=(UseSentenceBoundaries: no="" yes="-x")
    :: use_passthrough_grammars=(UsePassThroughGrammars: no yes)
    :: use_ruleshape2=(UseRuleShape2: no yes)
    :: use_ngram_features=(UseNGramFeatures: no yes)
    :: use_source_ngram_features=(UseSourceNGramFeatures: no yes)
    :: use_source_path_features=(UseSourcePathFeatures: no yes)
    :: use_brown_lm=(UseBrownLM: no yes)
    :: use_source_lm=(UseSourceLM: no yes)
    :: source_cluster_map=@
    :: target_cluster_map=@
    :: scfg_max_span_limit=@ 
    :: cubepruning_pop_limit=@ {
  echo "formalism=scfg" > $cdec_ini
  echo "add_pass_through_rules=true" >> $cdec_ini 
  echo "feature_function=KLanguageModel $use_sentence_boundaries_flag $language_model" >> $cdec_ini
  echo "feature_function=WordPenalty" >> $cdec_ini

  # Moar features!!1
  echo "feature_function=NonLatinCount" >> $cdec_ini
  echo "feature_function=RuleShape" >> $cdec_ini
  echo "feature_function=ArityPenalty" >> $cdec_ini
  if [[ $use_ngram_features != "false" ]]; then
    echo "feature_function=NgramFeatures -o 2 -c $target_cluster_map" >> $cdec_ini
  fi
  if [[ $use_source_path_features != "false" ]]; then
    echo "feature_function=SourcePathFeatures" >> $cdec_ini # Chris says to be leery of these
  fi

  echo "scfg_max_span_limit=$scfg_max_span_limit" >> $cdec_ini
  echo "cubepruning_pop_limit=$cubepruning_pop_limit" >> $cdec_ini
}

task AddBrownLMToCdecIni
    < input_cdec_ini=$cdec_ini@MakeCdecIni
    < language_model=$language_model@CompileLanguageModel[LMType:brown]
    :: use_sentence_boundaries_flag=(UseSentenceBoundaries:
                                       no=""
                                       yes="-x ")
    :: target_cluster_map=@
    > cdec_ini {
  cp $input_cdec_ini $cdec_ini
  echo "feature_function=KLanguageModel $use_sentence_boundaries_flag -m $target_cluster_map $language_model" >> $cdec_ini
}

task Tune
    < tune_set=$wrapped_corpus@ExtractGrammars[DataSection:tune]
    < cdec_ini=(UseBrownLM:
                  no=$cdec_ini@MakeCdecIni
                  yes=$cdec_ini@AddBrownLMToCdecIni)
    > mira_work
    > optimized_weights
    :: metric_flag=(TuneMetric: bleu=" " meteor="-m meteor --no-pseudo --sent-approx")
    :: cores=$decode_cores
    :: cdec_dir=@ 
    :: .submitter=$full_node_scheduler .walltime="48:00:00" .cpus=$many_cpus .vmem=$big_task .q=normal {

  python $cdec_dir/training/mira/mira.py --jobs $cores $metric_flag --kbest-size 500 -d $tune_set -o $mira_work -c $cdec_ini --step-size 0.001 \
    >mira_out.txt 2>mira_err.txt

  ln -s $mira_work/weights.final $optimized_weights
}

task TuneWithMert
    < tune_set=$wrapped_corpus@ExtractGrammars[DataSection:tune]
    < cdec_ini=(UseBrownLM:
                  no=$cdec_ini@MakeCdecIni
                  yes=$cdec_ini@AddBrownLMToCdecIni)
    > mert_work
    > optimized_weights
    :: metric_flag=(TuneMetric: bleu=" " meteor="--metric meteor")
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
    < cdec_ini=(UseBrownLM:
        no=$cdec_ini@MakeCdecIni
        yes=$cdec_ini@AddBrownLMToCdecIni)
    < weights=(Optimizer: mira=$optimized_weights@Tune mert=$optimized_weights@TuneWithMert)
    > kbest
    > output
    :: k=1000
    :: cores=$decode_cores
    :: cdec_dir=@
    :: .submitter=$full_node_scheduler .walltime="6:00:00" .cpus=$many_cpus .vmem=$big_task .q=normal {

  num_lines=$(cat $test_set | wc -l)
  lines_per_piece=$(echo "( $num_lines + $cores - 1 ) / $cores" | bc)
  mkdir split
  cd split
  split -a 2 -d -l $lines_per_piece $test_set "piece_"
  ls -1 piece_* | parallel -j $cores "cat {} | $cdec_dir/corpus/cut-corpus.pl 1 | cdec -c $cdec_ini -w $weights -k $k -r > kbest_{}"
  cd ..
  echo split/kbest* | sort -n | xargs cat > $kbest
  #cat $test_set | $cdec_dir/corpus/cut-corpus.pl 1 | cdec -c $cdec_ini -w $weights -k $k -r > $kbest
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
  METEORTASK=$meteor_task
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
