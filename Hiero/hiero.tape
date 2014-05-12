#!/usr/bin/env ducttape

global {
  ducttape_experimental_submitters=enable
  ducttape_experimental_imports=enable
  #full_node_scheduler=shell
  full_node_scheduler=torque_normal
  #partial_node_scheduler=shell
  partial_node_scheduler=torque_shared
  tiny_task=2g
  small_task=8g
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
    :: cdec_dir=@
    :: .submitter=$partial_node_scheduler .walltime="01:00:00" .cpus=1 .vmem=$tiny_task .q=shared {
  $cdec_dir/utils/atools -i $s2tAlignment -j $t2sAlignment -c grow-diag-final-and > $alignment
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
    :: cores=4
    :: cdec_dir=@
    :: .submitter=$full_node_scheduler .walltime="24:00:00" .cpus=$many_cpus .vmem=$medium_task .q=normal {
  # This uses ~13 GB of RAM per core!
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
    :: tag_passthroughs=(UsePassthroughTagger: no yes)
    :: script_dir=@
    :: cdec_dir=@ {
    #:: .submitter=$partial_node_scheduler .walltime="4:00:00" .cpus=1 .vmem=$medium_task .q=shared {
  if [[ $tag_passthroughs == "yes" ]]; then
    bash /home/armatthe/git/transliteration/prep.sh $test_set > dat
    python /home/armatthe/git/transliteration/decoder.py \
      ./dat \
      /home/armatthe/git/transliteration/final.model \
      /home/armatthe/git/transliteration/gaz.dat \
      /home/armatthe/git/transliteration/brown.dat > output.dat
    cat output.dat | rev | cut -f 1 | rev | python /home/armatthe/Tools/paste-s-with-newlines.py > $bio_tags
  else
    pv $test_set | $cdec_dir/corpus/cut-corpus.pl 1 | python $script_dir/tag_passthroughs.py > $bio_tags
  fi
}

task MakePassThroughGrammars
    < test_set=(DataSection:
                  train=$train_corpus
                  tune=$tune_corpus
                  test=$test_corpus)
    < bio_tags=@TagPassthroughs
    > grammar_dir
    :: script_dir=@
    :: cdec_dir=@ {
    #:: .submitter=$partial_node_scheduler .walltime="4:00:00" .cpus=1 .vmem=$medium_task .q=shared {
  mkdir -p $grammar_dir
  script_location="/usr0/home/cdyer/wmt14/make-self-translations.pl"
  $cdec_dir/corpus/paste-files.pl <(perl $cdec_dir/corpus/cut-corpus.pl 1 $test_set) $bio_tags | \
    perl $script_dir/make-self-translations.pl $grammar_dir
}

task LMBrownClusters
    < lm_data=@
    < corpus=$train_corpus
    < cluster_map=(LMSide:
                     target=$target_cluster_map
                     source=$source_cluster_map)
    > out_lm_data
    > out_corpus
    :: cdec_dir=@
    :: script_dir=@
    :: .submitter=$partial_node_scheduler .walltime="4:00:00" .cpus=2 .vmem=$medium_task .q=shared {
  zcat -f $lm_data | python $script_dir/map_clusters.py $cluster_map | gzip > $out_lm_data
  zcat -f $corpus | $cdec_dir/corpus/cut-corpus.pl 2 | python $script_dir/map_clusters.py $cluster_map > ./out_corpus_tgt

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
    :: lm_side_index=(LMSide:
                        target=2
                        source=1)
    :: lm_order=(LMSide:
                   target=(LMType:
                             surface=$lm_order
                             brown=$brown_lm_order)
                   source=(LMType:
                             surface=2
                             brown=2))
    :: cdec_dir=@
    :: .submitter=$full_node_scheduler .walltime="06:00:00" .cpus=1 .vmem=$big_task .q=normal {
  corpus_target="./corpus_target"
  $cdec_dir/corpus/cut-corpus.pl $lm_side_index $corpus > $corpus_target
  zcat -f $lm_data >> $corpus_target
  $cdec_dir/klm/lm/builder/lmplz --order $lm_order -T . -S 90% --text $corpus_target --arpa $language_model
  rm $corpus_target
}

task CompileLanguageModel
    < arpa=$language_model@BuildLanguageModel
    > language_model
    :: lm_quant_flags=@
    :: cdec_dir=@
    :: .submitter=$full_node_scheduler .walltime="06:00:00" .cpus=1 .vmem=$big_task .q=normal {
  $cdec_dir/klm/lm/build_binary -T . -S 90% $lm_quant_flags trie $arpa $language_model
}

task MakeCdecIni
    < language_model=$language_model@CompileLanguageModel[LMType:surface,LMSide:target]
    < brown_lm=(UseBrownLM: no="/dev/null" yes=$language_model@CompileLanguageModel[LMType:brown,LMSide:target])
    < src_lm=(UseSourceLM: no="/dev/null" yes=$language_model@CompileLanguageModel[LMType:surface,LMSide:source])
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
  echo "feature_function=KLanguageModel -n LanguageModel $use_sentence_boundaries_flag $language_model" >> $cdec_ini
  echo "feature_function=WordPenalty" >> $cdec_ini
  echo "feature_function=NonLatinCount" >> $cdec_ini
  echo "feature_function=RuleShape" >> $cdec_ini
  echo "feature_function=ArityPenalty" >> $cdec_ini
  echo "scfg_max_span_limit=$scfg_max_span_limit" >> $cdec_ini
  echo "cubepruning_pop_limit=$cubepruning_pop_limit" >> $cdec_ini

  if [[ $use_passthrough_grammars != "yes" ]]; then
    echo "add_pass_through_rules=true" >> $cdec_ini 
  fi

  if [[ $use_ruleshape2 == "yes" ]]; then
    echo "feature_function=RuleShape2 -f $source_cluster_map -e $target_cluster_map -p 6" >> $cdec_ini
  fi

  if [[ $use_ngram_features == "yes" ]]; then
    echo "feature_function=NgramFeatures -x -o 2 -c $target_cluster_map" >> $cdec_ini
  fi

  if [[ $use_source_ngram_features == "yes" ]]; then
    echo "feature_function=NgramFeatures -x -o 1 -U SCI: -c $source_cluster_map" >> $cdec_ini
  fi

  if [[ $use_source_path_features == "yes" ]]; then
    echo "feature_function=SourcePathFeatures" >> $cdec_ini
  fi

  if [[ $use_brown_lm == "yes" ]]; then
    echo "feature_function=KLanguageModel -n BrownLM $use_sentence_boundaries_flag -m $target_cluster_map $brown_lm" >> $cdec_ini
  fi

  if [[ $use_source_lm == "yes" ]]; then
    echo "feature_function=KLanguageModel -n SourceLM $use_sentence_boundaries_flag $src_lm" >> $cdec_ini
  fi

}

task Tune
    < tune_set=$wrapped_corpus@ExtractGrammars[DataSection:tune]
    < cdec_ini=@MakeCdecIni
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
    < cdec_ini=@MakeCdecIni
    > mert_work
    > optimized_weights
    :: metric_flag=(TuneMetric: bleu=" " meteor="--metric meteor")
    :: cores=$decode_cores
    :: cdec_dir=@
    :: .submitter=$full_node_scheduler .walltime="48:00:00" .cpus=$many_cpus .vmem=$big_task .q=normal {
  initialWeights="./initialWeights.txt"
  echo 'Arity_0 0'                        >> $initialWeights
  echo 'Arity_1 0'                        >> $initialWeights
  echo 'Arity_2 0'                        >> $initialWeights
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
  echo 'Shape_S01010_T01010 0'            >> $initialWeights
  echo 'Shape_S01100_T01100 0'            >> $initialWeights
  echo 'Shape_S01100_T11000 0'            >> $initialWeights
  echo 'Shape_S01100_T11100 0'            >> $initialWeights
  echo 'Shape_S01110_T01011 0'            >> $initialWeights
  echo 'Shape_S01110_T01110 0'            >> $initialWeights
  echo 'Shape_S01110_T01111 0'            >> $initialWeights
  echo 'Shape_S01110_T11010 0'            >> $initialWeights
  echo 'Shape_S01110_T11011 0'            >> $initialWeights
  echo 'Shape_S01110_T11110 0'            >> $initialWeights
  echo 'Shape_S01110_T11111 0'            >> $initialWeights
  echo 'Shape_S01111_T01011 0'            >> $initialWeights
  echo 'Shape_S01111_T01110 0'            >> $initialWeights
  echo 'Shape_S01111_T01111 0'            >> $initialWeights
  echo 'Shape_S01111_T11010 0'            >> $initialWeights
  echo 'Shape_S01111_T11011 0'            >> $initialWeights
  echo 'Shape_S01111_T11110 0'            >> $initialWeights
  echo 'Shape_S01111_T11111 0'            >> $initialWeights
  echo 'Shape_S10000_T10000 0'            >> $initialWeights
  echo 'Shape_S11000_T01100 0'            >> $initialWeights
  echo 'Shape_S11000_T11000 0'            >> $initialWeights
  echo 'Shape_S11000_T11100 0'            >> $initialWeights
  echo 'Shape_S11100_T01100 0'            >> $initialWeights
  echo 'Shape_S11100_T11000 0'            >> $initialWeights
  echo 'Shape_S11100_T11100 0'            >> $initialWeights
  echo 'Shape_S11110_T01011 0'            >> $initialWeights
  echo 'Shape_S11110_T01110 0'            >> $initialWeights
  echo 'Shape_S11110_T01111 0'            >> $initialWeights
  echo 'Shape_S11110_T11010 0'            >> $initialWeights
  echo 'Shape_S11110_T11011 0'            >> $initialWeights
  echo 'Shape_S11110_T11110 0'            >> $initialWeights
  echo 'Shape_S11110_T11111 0'            >> $initialWeights
  echo 'Shape_S11111_T01011 0'            >> $initialWeights
  echo 'Shape_S11111_T01110 0'            >> $initialWeights
  echo 'Shape_S11111_T01111 0'            >> $initialWeights
  echo 'Shape_S11111_T11010 0'            >> $initialWeights
  echo 'Shape_S11111_T11011 0'            >> $initialWeights
  echo 'Shape_S11111_T11110 0'            >> $initialWeights
  echo 'Shape_S11111_T11111 0'            >> $initialWeights
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
    :: .submitter=$partial_node_scheduler .walltime="00:20:00" .cpus=1 .vmem=$small_task .q=shared {
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
  of Evaluate > Bleu Meteor TER Length {
    cp $bleu Bleu
    cp $meteor $Meteor
    cp $ter $TER
    cp $length $Length
  }
}
