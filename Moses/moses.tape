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
  medium_task=16g
  big_task=30g
  #many_cpus=8
  many_cpus=32
}

import ../submitters.tape

task CutTrainCorpus
    < train_corpus=@
    > source
    > target
    :: cdec_dir=@
    :: .submitter=$partial_node_scheduler .walltime="01:00:00" .cpus=1 .vmem=$tiny_task .q=shared {
  $cdec_dir/corpus/cut-corpus.pl 1 $train_corpus > $source
  $cdec_dir/corpus/cut-corpus.pl 2 $train_corpus > $target
}

task CutTuneCorpus
    < tune_corpus=@
    > tuneSetSource
    > tuneSetRefs
    :: cdec_dir=@
    :: .submitter=$partial_node_scheduler .walltime="01:00:00" .cpus=1 .vmem=$tiny_task .q=shared {
  $cdec_dir/corpus/cut-corpus.pl 1 $tune_corpus > $tuneSetSource
  $cdec_dir/corpus/cut-corpus.pl 2 $tune_corpus > $tuneSetRefs
}

task CutTestCorpus
    < test_corpus=@
    > testSetSource
    > testSetRefs
    :: cdec_dir=@
    :: .submitter=$partial_node_scheduler .walltime="01:00:00" .cpus=1 .vmem=$tiny_task .q=shared {
  $cdec_dir/corpus/cut-corpus.pl 1 $test_corpus > $testSetSource
  $cdec_dir/corpus/cut-corpus.pl 2 $test_corpus > $testSetRefs
}

task AlignS2T
    < corpus=$train_corpus
    > alignment
    :: cdec_dir=@
    :: .submitter=$partial_node_scheduler .walltime="12:00:00" .cpus=1 .vmem=$big_task .q=shared {
  $cdec_dir/word-aligner/fast_align -i $corpus -d -v -o > $alignment
}

task AlignT2S
    < corpus=$train_corpus
    > alignment
    :: cdec_dir=@
    :: .submitter=$partial_node_scheduler .walltime="12:00:00" .cpus=1 .vmem=$big_task .q=shared {
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

task BuildLanguageModel
    < target=@CutTrainCorpus
    < lm_data=@
    > language_model
    :: use_custom_lm=@
    :: custom_lm=@
    :: lm_order=@
    :: moses=@
    :: cdec_dir=@
    :: .submitter=$partial_node_scheduler .walltime="06:00:00" .cpus=1 .vmem=$medium_task .q=shared {
  if [[ $use_custom_lm == "true" ]]; then
     ln -s $custom_lm $language_model
  else
     combined_lm_data="./combined_lm_data"
     cat $target $lm_data > $combined_lm_data
     $moses/bin/lmplz -o $lm_order -T . -S 10% < $combined_lm_data > $language_model
  fi
}

task CompileLanguageModel
    < arpa=$language_model@BuildLanguageModel
    > language_model
    :: lm_quant_flags=@
    :: use_custom_lm=@
    :: custom_lm=@
    :: moses=@
    :: cdec_dir=@
    :: .submitter=$partial_node_scheduler .walltime="06:00:00" .cpus=1 .vmem=$medium_task .q=shared {
  if [[ $use_custom_lm == "true" ]]; then
     ln -s $custom_lm $language_model
  elif [[ -z $lm_quant_flags ]]; then
     $moses/bin/build_binary trie $arpa $language_model
  else
     $moses/bin/build_binary $lm_quant_flags trie $arpa $language_model
  fi
}

task LexicalProbs
    < source=@CutTrainCorpus
    < target=@CutTrainCorpus
    < alignment=@Symmetrize
    > lex_f2e=lex.f2e
    > lex_e2f=lex.e2f
    :: moses=@
    :: .submitter=$partial_node_scheduler .walltime="01:00:00" .cpus=1 .vmem=$tiny_task .q=shared {
  $moses/scripts/training/get-lexical.perl $source $target $alignment lex
}

task ExtractPhrases
    < source=@CutTrainCorpus
    < target=@CutTrainCorpus
    < alignment=@Symmetrize
    > phrase_instances=phrase_instances.sorted.gz
    > phrase_instances_inverse=phrase_instances.inv.sorted.gz
    > phrase_orientations=phrase_orientations.sorted.gz
    :: max_phrase_length=@
    :: cores=1
    :: moses=@
    :: .submitter=$partial_node_scheduler .walltime="12:00:00" .cpus=1 .vmem=$small_task .q=shared {
  sort_buffer_size="1G"
  $moses/bin/extract $target $source $alignment phrase_instances $max_phrase_length orientation --GZOutput

  export LC_ALL=C
  SORT="sort --parallel=$cores --buffer-size=$sort_buffer_size --temporary-directory=$PWD"
  #SORT="sort --buffer-size=$sort_buffer_size --temporary-directory=$PWD"
  zcat -f phrase_instances.gz | $SORT | gzip > phrase_instances.sorted.gz
  zcat -f phrase_instances.inv.gz | $SORT | gzip > phrase_instances.inv.sorted.gz
  zcat -f phrase_instances.o.gz | $SORT | gzip > phrase_orientations.sorted.gz

  rm phrase_instances.gz
  rm phrase_instances.inv.gz
}

task ScorePhrases
    < lex_f2e=@LexicalProbs
    < lex_e2f=@LexicalProbs
    < phrase_instances=@ExtractPhrases 
    < phrase_instances_inverse=@ExtractPhrases
    > scored_phrase_table=pt.gz
    :: cores=1 
    :: moses=@
    :: .submitter=$partial_node_scheduler .walltime="06:00:00" .cpus=1 .vmem=$tiny_task .q=shared {
  SCORE="$moses/bin/score"
  sort_buffer_size="1G"

  export LC_ALL=C
  SORT="sort --parallel=$cores --buffer-size=$sort_buffer_size --temporary-directory=$PWD"
  #SORT="sort --buffer-size=$sort_buffer_size --temporary-directory=$PWD"

  $SCORE $phrase_instances $lex_f2e /dev/stdout | gzip > pt.f2e.gz
  $SCORE $phrase_instances_inverse $lex_e2f /dev/stdout --Inverse | $SORT | gzip > pt.e2f.gz

  $moses/bin/consolidate pt.f2e.gz pt.e2f.gz /dev/stdout | gzip > $scored_phrase_table

  rm pt.f2e.gz
  rm pt.e2f.gz
}

task MakeMosesIni
    < scored_phrase_table=@ScorePhrases
    < reordering_table=@BuildReorderingModel
    < languageModel=$language_model@CompileLanguageModel
    > mosesIni=moses-init.ini
    :: ttable_limit=@
    :: reordering_model_type=@
    :: distortion_limit=@
    :: n_best_size=@
    :: moses=@ { 
  nPtFeatures=5
  nRoFeatures=6
  # KenLM ignores lm_order anyway
  lm_order=0
  rm -rf moses-init.ini
  echo "[input-factors]" >> moses-init.ini
  echo "0" >> moses-init.ini
  echo "" >> moses-init.ini
  echo "[mapping]" >> moses-init.ini
  echo "0 T 0" >> moses-init.ini
  echo "" >> moses-init.ini
  echo "[ttable-file]" >> moses-init.ini
  echo "0 0 0 $nPtFeatures $scored_phrase_table" >> moses-init.ini
  echo "" >> moses-init.ini
  echo "[lmodel-file]" >> moses-init.ini
  # 9 means kenlm lazy loading
  echo "9 0 $lm_order $languageModel" >> moses-init.ini
  echo "" >> moses-init.ini
  echo "[ttable-limit]" >> moses-init.ini
  echo "$ttable_limit" >> moses-init.ini
  echo "0" >> moses-init.ini
  echo "" >> moses-init.ini
  echo "[distortion-file]" >> moses-init.ini
  echo "0-0 $reordering_model_type $nRoFeatures $reordering_table" >> moses-init.ini
  echo "" >> moses-init.ini
  echo "[distortion-limit]" >> moses-init.ini
  echo "$distortion_limit" >> moses-init.ini
  echo "0" >> moses-init.ini
  echo "" >> moses-init.ini
  echo "[factor-delimiter]" >> moses-init.ini
  echo "|||" >> moses-init.ini
  echo "" >> moses-init.ini
  echo "[xml-input]" >> moses-init.ini
  echo "exclusive" >> moses-init.ini
  echo "" >> moses-init.ini

  # Add in initial weights
  echo "[weight-d]" >> moses-init.ini
  echo "0.4" >> moses-init.ini
  echo "0.15" >> moses-init.ini
  echo "0.15" >> moses-init.ini
  echo "0.15" >> moses-init.ini
  echo "0.15" >> moses-init.ini
  echo "0.15" >> moses-init.ini
  echo "0.15" >> moses-init.ini
  echo "" >> moses-init.ini
  echo "[weight-l]" >> moses-init.ini
  echo "0.5" >> moses-init.ini
  echo "" >> moses-init.ini
  echo "[weight-t]" >> moses-init.ini
  echo "0.2" >> moses-init.ini
  echo "0.2" >> moses-init.ini
  echo "0.2" >> moses-init.ini
  echo "0.2" >> moses-init.ini
  echo "0.2" >> moses-init.ini
  echo "" >> moses-init.ini
  echo "[weight-w]" >> moses-init.ini
  echo "-1.0" >> moses-init.ini
  echo "" >> moses-init.ini
}

task FilterPhraseTable
    < scored_phrase_table=@ScorePhrases
    < source=(TuneOrTest: test=$testSetSource@CutTestCorpus tune=$tuneSetSource@CutTuneCorpus)
    < mosesIni=@MakeMosesIni
    > filtered_pt
    > filteredMosesIni=filtered_pt/moses.ini
    :: moses=@
    :: .submitter=$partial_node_scheduler .walltime="06:00:00" .cpus=1 .vmem=$medium_task .q=shared {
   perl $moses/scripts/training/filter-model-given-input.pl $filtered_pt $mosesIni $source
}

task BuildReorderingModel
    < phrase_orientations=@ExtractPhrases
    > reordering_table=reordering_table.gz
    :: reordering_model_type=@
    :: moses=@
    :: .submitter=$partial_node_scheduler .walltime="06:00:00" .cpus=1 .vmem=$tiny_task .q=shared {
  smooth=0.5
  type=wbe
  orientation=msd
  spec=$type-$orientation-bidirectional-fe
  $moses/bin/lexical-reordering-score $phrase_orientations $smooth ro_ --model "$type $orientation $spec"
  mv ro_$spec.gz $reordering_table
}

task Tune
    < src=$tuneSetSource@CutTuneCorpus
    < refs=$tuneSetRefs@CutTuneCorpus
    < mosesIni=$filteredMosesIni@FilterPhraseTable[TuneOrTest:tune]
    > tunedMosesIni=moses.ini
    :: cores=$decode_cores
    :: tuning_run_number=@
    :: moses=@
    :: .submitter=$full_node_scheduler .walltime="24:00:00" .cpus=$many_cpus .vmem=$big_task .q=normal { 

  i=0
  for ref_file in $refs; do
     zcat -f $ref_file > $PWD/ref$i
     i=$(($i + 1))
  done

  #total_ref_lines=$(zcat -f $refs | wc -l)
  #total_src_lines=$(zcat -f $src | wc -l)
  #num_refs=$(( $total_ref_lines / $total_src_lines ))
  #zcat -f $refs | awk "BEGIN{i=0} {print>>(\"ref\"i);i+=1;i%=$num_refs}"

  $moses/scripts/training/absolutize_moses_model.pl $mosesIni > moses-init.abs.ini

  export LC_ALL=C
  $moses/scripts/training/mert-moses.pl --input $src --refs $PWD/ref --decoder $moses/bin/moses --config $PWD/moses-init.abs.ini --working-dir $PWD/mert-work --no-filter-phrase-table --threads $cores --decoder-flags=" -threads $cores"
  cp mert-work/moses.ini $tunedMosesIni
}

task MakeFilteredMosesIni
    < tunedMosesIni=@Tune
    < filtered_pt=@FilterPhraseTable
    > mosesIni {
  old_pt=$(grep -A 1 '^\[ttable-file\]$' $tunedMosesIni | tail -n 1 | cut -f 5 -d ' ' | sed 's/[]\/()$*.^|[]/\\&/g')
  new_pt=$(echo $filtered_pt/phrase-table* | sed 's/[\/&]/\\&/g')
  old_ro=$(grep -A 1 '^\[distortion-file\]$' $tunedMosesIni | tail -n 1 | cut -f 4 -d ' ' | sed 's/[]\/()$*.^|[]/\\&/g')
  new_ro=$(echo $filtered_pt/reordering_table* | sed 's/[\/&]/\\&/g')
  cat $tunedMosesIni | sed "s/$old_pt/$new_pt/" | sed "s/$old_ro/$new_ro/" > $mosesIni
}

task Decode
    < mosesIni=@MakeFilteredMosesIni
    < src=(TuneOrTest:
        test=$testSetSource@CutTestCorpus
        tune=$tuneSetSource@CutTuneCorpus)
    > output
    :: cores=$decode_cores
    :: moses=@
    :: .submitter=$full_node_scheduler .walltime="100:00:00" .cpus=$many_cpus .vmem=$big_task .q=normal {
  cat $src | $moses/bin/moses -f $mosesIni -threads $cores > $output
}

task Evaluate
    < output=$output@Decode
    < refs=(TuneOrTest:
      test=$testSetRefs@CutTestCorpus
      tune=$tuneSetRefs@CutTuneCorpus)
    > bleu meteor ter length
    :: multeval=@
    :: meteor_task=@
    :: meteor_lang=@
    :: .submitter=$partial_node_scheduler .walltime="01:00:00" .cpus=1 .vmem=$small_task .q=shared {
  METEORTASK=$meteor_task
  METEORLANG=$meteor_lang
  scoreFile=scores.txt

  ln -s $(dirname $multeval)/constants .
  $multeval eval --refs $refs --hyps-baseline $output --meteor.task $METEORTASK --meteor.language $METEORLANG &> $scoreFile
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
