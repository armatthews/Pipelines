#!/usr/bin/env ducttape

global {
  ducttape_output="/home/austinma/Systems/compounds-test-lower2"
  #ducttape_output="/usr0/home/austinma/git/Pipelines/CompoundGenerator/german/compounds-test-dir"
  cdec_dir="/home/austinma/git/cdec"
  script_dir="/home/austinma/git/Pipelines/CompoundGenerator/scripts"
  tag_english_script="/usr0/home/austinma/git/Pipelines/CompoundGenerator/german/pos_tag.py"
}

global {
  #parallel_data="/usr0/home/austinma/compounds/wood_german/filtered.en-de.tok"
  parallel_data="/usr0/home/austinma/compounds/wood_german/filtered.en-de.tok.lower"
  source_trees="/usr0/home/austinma/compounds/wood_german/trees.gz"

  train_compounds="/usr0/home/austinma/git/Pipelines/CompoundGenerator/german/train.compound.txt"
  dev_compounds=(TuningSet:
    dev="/usr0/home/austinma/git/Pipelines/CompoundGenerator/german/dev.compound.txt"
    train="/usr0/home/austinma/git/Pipelines/CompoundGenerator/german/train.compound.txt")
  test_compounds=(TestSet:
    bitext="/usr0/home/austinma/git/Pipelines/CompoundGenerator/german/test.compound.txt"
    isabl="/usr0/home/austinma/git/Pipelines/CompoundGenerator/german/isabelle/test.txt")

  length_limit=3
}

plan All {
    #reach EvaluateCER, EvaluateMRR, EvaluateReachability via (DecodeSet: test tune) * (POSLatticeFeatures: no yes)
    reach EvaluateCER, EvaluateMRR, EvaluateReachability via (DecodeSet: test tune) * (POSLatticeFeatures: yes) * (TuningSet: train) * (TestSet: bitext isabl) * (TuningIterations: 10)
}

#plan TestTag {
#    reach Latticify via (DecodeSet: tune) * (POSLatticeFeatures: yes no)
#}

# Prerequisites
task CompoundSplit
  < parallel_data=@
  > split_corpus=split_corpus.gz
  :: cdec_dir=@ {
  # test to make sure compound splitter doesn't freak out when you give hyphenated stuff
  pv $parallel_data | $cdec_dir/corpus/cut-corpus.pl 1 > en
  pv $parallel_data | $cdec_dir/corpus/cut-corpus.pl 2 > de
  pv de | $cdec_dir/compound-split/compound-split.pl --preserve_case --output 1best > de.cs
  $cdec_dir/corpus/paste-files.pl en de.cs | gzip > $split_corpus
  rm en de de.cs
}

task Align
  < parallel_data=(CompoundSplit:
      no=$parallel_data
      yes=$split_corpus@CompoundSplit)
  > alignment=alignment.gz
  > ttable=ttable.gz
  :: direction_flag=(Direction:
      forward=""
      reverse="-r")
  :: cdec_dir=@ {
  $cdec_dir/word-aligner/fast_align -i $parallel_data -ovd $direction_flag -p >(gzip > $ttable) | gzip > $alignment
}

task Symmetrize
  < s2t=$alignment@Align[Direction:forward]
  < t2s=$alignment@Align[Direction:reverse]
  > alignment=alignment.gz
  :: heuristic="grow-diag"
  :: cdec_dir=@ {
  $cdec_dir/utils/atools -i $s2t -j $t2s -c $heuristic | gzip > $alignment
}

task IdentifyPseudoCompounds
  < parallel_data=@
  < alignment=@Symmetrize[CompoundSplit:no]
  > compounds=compounds.gz
  :: script_dir=@ {
#  echo 'a ||| a ||| 0-0' | python $script_dir/findCompounds.py > $compounds
  paste <(zcat -f $parallel_data) <(zcat -f $alignment) | sed 's/\t/ ||| /g' | python $script_dir/findCompounds.py | gzip > $compounds
}

task PruneUnreachable
  < pseudo_compounds=$compounds@IdentifyPseudoCompounds
  < ttable=@Align[Direction:forward,CompoundSplit:yes]
  > compounds=compounds.gz {
  zcat -f $pseudo_compounds | cut -f 4,5 | awk -F $'\t' '{print $2 "\t" $1}' | /home/austinma/git/CompoundCRF/reachable <(zcat -f $ttable) | gzip > $compounds
}

task AnalyzeCompounds
  < compounds=@PruneUnreachable
  < fwd_ttable=$ttable@Align[Direction:forward,CompoundSplit:yes]
  < rev_ttable=$ttable@Align[Direction:reverse,CompoundSplit:yes]
  > analyses=analyses.gz {
  zcat -f $compounds | /usr0/home/austinma/git/CompoundCRF/split <(zcat -f $fwd_ttable) <(zcat -f $rev_ttable) | gzip > $analyses
}

# Classifier stuff
task ExtractSpanFeatures
  < parallel_data=@
  < source_trees=@
  > span_features=span_features.gz
  :: cdec_dir=@
  :: script_dir=@ {
  paste <($cdec_dir/corpus/cut-corpus.pl 1 $parallel_data) <(zcat -f $source_trees) | sed 's/\t/ ||| /g' | python $script_dir/extractFeatures.py | gzip > $span_features
}

task LabelSpanData {
#  < training_data=@ {
}

task BuildSpanClassifier {
#  < training_data=@
#  < dev_data=@ {
}

# Compound Generator Stuff
task BuildLanguageModel
  < compounds=@PruneUnreachable
  > language_model=compounds.klm
  :: cdec_dir=@
  :: script_dir=@ {
  $cdec_dir/klm/lm/builder/lmplz -S 20% -T . -o 10 --discount_fallback --text <(zcat $compounds | cut -f 2 | python $script_dir/space.py) | gzip > arpa.gz
  $cdec_dir/klm/lm/build_binary -S 20% -T . trie arpa.gz $language_model
  #rm arpa.gz
}

task MakeCdecGrammar
  < forward_ttable=$ttable@Align[Direction:forward,CompoundSplit:yes] 
  < reverse_ttable=$ttable@Align[Direction:reverse,CompoundSplit:yes]
  > grammar=grammar.gz
  :: script_dir=@ {
  zcat -f $forward_ttable | LC_ALL=C sort -k 1,1 -k 2,2 -t ' ' > fwd
  zcat -f $reverse_ttable | LC_ALL=C sort -k 2,2 -k 1,1 -t ' ' > rev
  python $script_dir/convert_ttable.py fwd rev | gzip > $grammar
  rm fwd
  rm rev
}

task MakePassthroughGrammar
  < decode_set=(DecodeSet:
      test=$test_compounds
      dev=$dev_compounds)
  < grammar=@MakeCdecGrammar
  > passthrough_grammar=grammar.gz
  :: script_dir=@ {
  zcat -f $decode_set | python $script_dir/make_passthrough_grammar.py $grammar | gzip > $passthrough_grammar
}

task MakeSuffixGrammar
  < analyses=@AnalyzeCompounds
  > grammar=grammar.gz
  :: script_dir=@ {
  zcat -f $analyses | python $script_dir/build_suffix_table.py | gzip > $grammar
}

task MakeCdecIni
  < language_model=@BuildLanguageModel 
  < grammar=@MakeCdecGrammar
  < pt_grammar=$passthrough_grammar@MakePassthroughGrammar 
  < suf_grammar=$grammar@MakeSuffixGrammar
  > cdec_ini=cdec.ini {
  echo "formalism=scfg" > $cdec_ini
  echo "feature_function=KLanguageModel $language_model" >> $cdec_ini
  echo "grammar=$grammar" >> $cdec_ini
  echo "grammar=$suf_grammar" >> $cdec_ini
  echo "grammar=$pt_grammar" >> $cdec_ini
  echo "cubepruning_pop_limit=1000" >> $cdec_ini
  echo "feature_function=WordPenalty" >> $cdec_ini
}

task POSTagEnglish
  < decode_set=(DecodeSet:
      test=$test_compounds
      dev=$dev_compounds)
  > pos
  :: tag_english_script=@ {
  cat $decode_set | $tag_english_script > $pos
}

task Latticify
  < decode_set=(DecodeSet:
      test=$test_compounds
      dev=$dev_compounds)
  < decode_pos=(POSLatticeFeatures:
      no=""
      yes=$pos@POSTagEnglish)
  > lattice_set=lattice_set.gz
  #:: use_pos_features=(POSLatticeFeatures: no=false yes=true)
  :: script_dir=@
  :: length_limit=@ {
  pos_flag=""
  if [ -f $decode_pos ]; then
    pos_flag="--pos ./pos"
  fi
  paste <(zcat -f $decode_set) <(zcat -f $decode_pos) | awk -F $'\t' '{n = split($1, a, " "); if (n <= '"$length_limit"') { print $0; }}' > x
  cat x | cut -f 1,2 | gzip > ./temp.gz
  cat x | cut -f 3 > ./pos
  zcat -f $decode_set | awk -F $'\t' '{n = split($1, a, " "); if (n <= '"$length_limit"') { print $0; }}' | gzip > ./temp.gz
  paste <(zcat -f ./temp.gz | cut -f 1 | python $script_dir/latticify.py $pos_flag) <(zcat -f ./temp | cut -f 2 | python $script_dir/space.py) | sed 's/\t/ ||| /g' | gzip > $lattice_set
}

task Tune
  < lattice_set=@Latticify[DecodeSet:dev]
  < cdec_ini=@MakeCdecIni[DecodeSet:dev]
  > weights
  :: cores=40
  :: tuning_metric="wer"
  :: cdec_dir=@
  :: iterations=(TuningIterations: 5 10 15) {
  ulimit -v 1000000000
  /usr/bin/python $cdec_dir/training/mira/mira.py -m $tuning_metric -j $cores -c $cdec_ini -d <(zcat -f $lattice_set) -o mira_work --max-iterations $iterations 
  ln -s mira_work/weights.final $weights
}

task Decode
  < lattice_set=@Latticify
  < cdec_ini=@MakeCdecIni
  < weights=@Tune
  > kbest
  > output
  :: cores=40
  :: kbest_size=1000
  :: cdec_dir=@ {
  zcat $lattice_set | $cdec_dir/corpus/cut-corpus.pl 1 | ~/Tools/embarrassingly_parallel.sh $cores $cdec_dir/decoder/cdec -w $weights -c $cdec_ini -k $kbest_size -r > $kbest
  sed 's/ ||| /\t/g' $kbest | awk 'BEGIN {p=-1;} {if($1 != p) { print $0;} p = $1; }' | cut -f 2 | sed 's/<\/\?s>//g' | sed 's/\s\+/ /g' | sed 's/^\s*\|\s*$//g' > $output
}

task EvaluateCER
  < test_set=$test_compounds
  < hyps=$output@Decode
  > cer
  :: script_dir=@ {
  cut -f 2 $test_set | python $script_dir/space.py > ./refs
  python $script_dir/cer.py $hyps ./refs > cer
  rm ./refs
}

task EvaluateMRR
  < test_set=$test_compounds
  < hyps=$kbest@Decode
  > mrr
  :: script_dir=@
  :: length_limit=@ {
  zcat -f $test_set | awk -F $'\t' '{n = split($1, a, " "); if (n <= '"$length_limit"') { print $0; }}' | cut -f 2- | python $script_dir/space.py > ./refs
  cat $hyps | python $script_dir/mrr.py ./refs > mrr
  rm ./refs
}

task EvaluateReachability
  < lattice_set=@Latticify
  < weights=@Tune
  < cdec_ini=@MakeCdecIni
  > reachability
  :: cores=40
  :: cdec_dir=@ {

  cat $cdec_ini | sed '/^\s*feature_function\s*=\s*KLanguageModel\s/d' > ./cdec_ini
  zcat -f $lattice_set | ~/Tools/embarrassingly_parallel.sh $cores $cdec_dir/decoder/cdec -w $weights -c ./cdec_ini >output 2>&1
  unreachable=$(grep 'REFERENCE UNREACHABLE' output | wc -l)
  reachable=$(grep 'Constr. VitTree:' output | wc -l)
  echo "$reachable reachable" > $reachability
  echo "$unreachable unreachable" >> $reachability
}

task Evaluate {
  # Reachability
  # Mean reciprocal rank
  # Perplexity
  # Character error rate
}
