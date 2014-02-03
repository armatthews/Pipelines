#!/usr/bin/env ducttape

global {
  ducttape_experimental_submitters=enable
  ducttape_experimental_imports=enable
  full_node_scheduler=torque_normal
  partial_node_scheduler=torque_shared
  tiny_task=2g
  small_task=16g
  medium_task=32g
  big_task=60g
  many_cpus=32
}

import ../submitters.tape

task AlignWithFastAlign
    < source=@
    < target=@
    > alignment
    > joint_corpus
    :: alignment_sym_heuristic=@
    :: cdec=@
    :: .submitter=$partial_node_scheduler .walltime="24:00:00" .cpus=1 .vmem=$medium_task .q=shared {
  paste -d $'\t' $source $target | sed 's/\t/ ||| /' > $joint_corpus
  $cdec/word-aligner/fast_align -i $joint_corpus -d -v -o > fwd_align
  $cdec/word-aligner/fast_align -i $joint_corpus -d -v -o -r > rev_align
  $cdec/utils/atools -i fwd_align -j rev_align -c $alignment_sym_heuristic > $alignment
}

task AlignWithMeteor
    < source=@
    < target=@
    > alignment
    :: multeval=@
    :: meteor_lang=@
    :: meteor_modules=@
    :: meteor_task=@
    :: .submitter=$partial_node_scheduler .walltime="24:00:00" .cpus=1 .vmem=$medium_task .q=shared {
  meteor=$(dirname $multeval)/lib/meteor-*/
  java -Xmx2G -cp $meteor/meteor-*.jar Matcher $source $target -l $meteor_lang -m "$meteor_modules" -t $meteor_task | \
    python /home/armatthe/git/timber/timber_scripts/convert_meteor_alignment.py > $alignment
}

task SafabaAlign
    > source
    > target
    > alignment {
  # Magic !
}

task AddPassthroughs
    < in_source=(UseSafabaMagic:
                   no=$source
                   yes=$source@SafabaAlign)
    < in_target=(UseSafabaMagic:
                   no=$target
                   yes=$target@SafabaAlign)
    < in_alignment=(UseSafabaMagic:
                      no=(Aligner:
                            fast_align=$alignment@AlignWithFastAlign
                            meteor=$alignment@AlignWithMeteor)
                      yes=$alignment@SafabaAlign)
    > source
    > target
    > alignment
    :: .submitter=$partial_node_scheduler .walltime="01:00:00" .cpus=1 .vmem=$tiny_task .q=shared {
  vocab="./vocab"
  cat $in_target | tr ' ' $'\n' | sort | uniq | sed '/^\s*$/d' > $vocab
  cat $in_source $vocab > $source
  cat $in_target $vocab > $target
  cat $in_alignment > $alignment
  cat $vocab | sed 's/^.*$/0-0/' >> $alignment
}

task LexicalProbs
    < source=(UsePassthroughs:
                no=(UseSafabaMagic:
                      no=$source
                      yes=$source@SafabaAlign)
                yes=$source@AddPassthroughs)
    < target=(UsePassthroughs:
                no=(UseSafabaMagic:
                      no=$target
                      yes=$target@SafabaAlign)
                yes=$target@AddPassthroughs)
    < alignment=(UsePassthroughs:
                   no=(UseSafabaMagic:
                         no=(Aligner:
                               fast_align=$alignment@AlignWithFastAlign
                               meteor=$alignment@AlignWithMeteor)
                         yes=$alignment@SafabaAlign)
                   yes=$alignment@AddPassthroughs)
    > lex_f2e=lex.f2e
    > lex_e2f=lex.e2f
    :: moses=@
    :: .submitter=$partial_node_scheduler .walltime="01:00:00" .cpus=1 .vmem=$tiny_task .q=shared {
  $moses/scripts/training/get-lexical.perl $source $target $alignment lex
}

task SynthesizePassthroughRules
    < target=@
    > phrase_instances
    > phrase_instances_inverse
    > phrase_orientations
    :: .submitter=$partial_node_scheduler .walltime="1:00:00" .cpus=1 .vmem=$small_task .q=shared {
    cat $target | tr ' ' $'\n' | sort | uniq | sed '/^\s*$/d' > vocab
    cat vocab | sed 's/\(.*\)/\1 ||| \1 ||| 0-0/' | gzip > $phrase_instances
    cat vocab | sed 's/\(.*\)/\1 ||| \1 ||| 0-0/' | gzip > $phrase_instances_inverse
    cat vocab | sed 's/\(.*\)/\1 ||| \1 ||| mono mono/' | gzip > $phrase_orientations
}

task ExtractPhrases
    < source=(UsePassthroughs:
                no=$source
                yes=$source@AddPassthroughs)
    < target=(UsePassthroughs:
                no=$target
                yes=$target@AddPassthroughs)
    < alignment=(UsePassthroughs:
                   no=(Aligner:
                         fast_align=$alignment@AlignWithFastAlign
                         meteor=$alignment@AlignWithMeteor)
                   yes=$alignment@AddPassthroughs)
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
  zcat -f phrase_instances.gz | $SORT | gzip > phrase_instances.sorted.gz
  zcat -f phrase_instances.inv.gz | $SORT | gzip > phrase_instances.inv.sorted.gz
  zcat -f phrase_instances.o.gz | $SORT | gzip > phrase_orientations.sorted.gz

  rm phrase_instances.gz
  rm phrase_instances.inv.gz
}

task SafabaExtractPhrases
    > phrase_instances 
    > phrase_instances_inverse {
  # Magic !
}

task CombinePhrases
    < real_phrase_instances=(UseSafabaMagic:
                               no=$phrase_instances@ExtractPhrases
                               yes=$phrase_instances@SafabaExtractPhrases)
    < real_phrase_instances_inverse=(UseSafabaMagic:
                                       no=$phrase_instances_inverse@ExtractPhrases
                                       yes=$phrase_instances_inverse@SafabaExtractPhrases)
    < synthetic_phrase_instances=(UseSyntheticPassthroughs:
                                    no=/home/armatthe/Research/Pipelines/MPE/empty.gz
                                    yes=$phrase_instances@SynthesizePassthroughRules)
    < synthetic_phrase_instances_inverse=(UseSyntheticPassthroughs:
                                            no=/home/armatthe/Research/Pipelines/MPE/empty.gz
                                            yes=$phrase_instances_inverse@SynthesizePassthroughRules)
    > phrase_instances
    > phrase_instances_inverse
    :: .submitter=$partial_node_scheduler .walltime="12:00:00" .cpus=1 .vmem=$small_task .q=shared {
  cores=1
  sort_buffer_size="1G"
  export LC_ALL=C
  SORT="sort --parallel=$cores --buffer-size=$sort_buffer_size --temporary-directory=$PWD"
  zcat -f $real_phrase_instances $synthetic_phrase_instances | $SORT | gzip > $phrase_instances
  zcat -f $real_phrase_instances_inverse $synthetic_phrase_instances_inverse | $SORT | gzip > $phrase_instances_inverse
}


task ScorePhrases
    < lex_f2e=@LexicalProbs
    < lex_e2f=@LexicalProbs
    < phrase_instances=@CombinePhrases
    < phrase_instances_inverse=@CombinePhrases
    > scored_phrase_table=pt.gz
    :: cores=1
    :: moses=@
    :: .submitter=$partial_node_scheduler .walltime="12:00:00" .cpus=1 .vmem=$small_task .q=shared {
  SCORE="$moses/bin/score"
  sort_buffer_size="1G"

  export LC_ALL=C
  SORT="sort --parallel=$cores --buffer-size=$sort_buffer_size --temporary-directory=$PWD"

  $SCORE <(zcat -f $phrase_instances) $lex_f2e /dev/stdout | gzip > pt.f2e.gz
  $SCORE <(zcat -f $phrase_instances_inverse) $lex_e2f /dev/stdout --Inverse | $SORT | gzip > pt.e2f.gz

  $moses/bin/consolidate pt.f2e.gz pt.e2f.gz /dev/stdout | gzip > $scored_phrase_table

  rm pt.f2e.gz
  rm pt.e2f.gz
}

task MakeMosesIni
    < scored_phrase_table=(PhraseTableFiltering:
                             none=$scored_phrase_table@ScorePhrases
                             samecontentwordcount=$scored_phrase_table@FilterPhraseTableByContentWordCount
                             exactstem=$scored_phrase_table@FilterPhraseTableByStems)
    > mosesIni=moses-init.ini
    :: languageModel=@
    :: ttable_limit=@
    :: n_best_size=@
    :: moses=@ { 
  nPtFeatures=5
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
  echo "[distortion-limit]" >> moses-init.ini
  echo "0" >> moses-init.ini
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

task FilterPhraseTableByContentWordCount
    < phrase_table=$scored_phrase_table@ScorePhrases
    > scored_phrase_table {
  exit 1
}

task FilterPhraseTableByStems
    < phrase_table=$scored_phrase_table@ScorePhrases
    > scored_phrase_table {
  exit 1
}

task FilterPhraseTable
    < scored_phrase_table=(PhraseTableFiltering:
                             none=$scored_phrase_table@ScorePhrases
                             samecontentwordcount=$scored_phrase_table@FilterPhraseTableByContentWordCount
                             exactstem=$scored_phrase_table@FilterPhraseTableByStems)
    < source=(TuneOrTest: test=$testSetSource tune=$tuneSetSource)
    < mosesIni=@MakeMosesIni
    > filtered_pt
    > filteredMosesIni=filtered_pt/moses.ini
    :: moses=@
    :: .submitter=$partial_node_scheduler .walltime="06:00:00" .cpus=1 .vmem=$small_task .q=shared {
  perl $moses/scripts/training/filter-model-given-input.pl $filtered_pt $mosesIni $source
}

task Tune
    < src=$tuneSetSource
    < refs=$tuneSetRefs
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
  cat $tunedMosesIni | sed "s/$old_pt/$new_pt/" > $mosesIni
} 

task Decode
    < mosesIni=@MakeFilteredMosesIni
    < src=(TuneOrTest:
        test=$testSetSource
        tune=$tuneSetSource)
    > output
    :: cores=$decode_cores
    :: moses=@
    :: .submitter=$full_node_scheduler .walltime="4:00:00" .cpus=$many_cpus .vmem=$big_task .q=normal {
  cat $src | $moses/bin/moses -f $mosesIni -threads $cores > $output
}

task Evaluate
    < output=$output@Decode
    < refs=(TuneOrTest:
      test=$testSetRefs
      tune=$tuneSetRefs)
    > bleu meteor ter length
    :: multeval=@
    :: meteor_lang=@
    :: .submitter=$partial_node_scheduler .walltime="01:00:00" .cpus=1 .vmem=$small_task .q=shared {
  METEORTASK=li
  METEORLANG=other #$meteor_lang
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

