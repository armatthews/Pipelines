#!/usr/bin/env ducttape

task BuildVocab
    < train=(Side: source=$train_source target=$train_target)
    > vocab="vocab"
    :: cutoff=2
    :: oxlm_dir=@ {
  bash $oxlm_dir/scripts/countcutoff.sh $train $cutoff
}

task RemoveSingletons
    < train=(Side: source=$train_source target=$train_target)
    < dev=(Side: source=$dev_source target=$dev_target)
    < vocab=@BuildVocab
    > train_unk
    > dev_unk
    :: oxlm_dir=@ {
  python $oxlm_dir/scripts/preprocess-corpus.py -i $train,$dev -o $train_unk,$dev_unk -v $vocab
}

task CombineCorpora
    < train_source=$train_unk@RemoveSingletons[Side:source]
    < train_target=$train_unk@RemoveSingletons[Side:target]
    < dev_source=$dev_unk@RemoveSingletons[Side:source]
    < dev_target=$dev_unk@RemoveSingletons[Side:target]
    > corpus {
  paste <(cat $train_source $dev_source) <(cat $train_target $dev_target) | sed 's/\t/ ||| /g' > $corpus
}

task AlignS2T
    < corpus=@CombineCorpora
    > alignment
    :: cdec_dir=@ {
  $cdec_dir/word-aligner/fast_align -i $corpus -d -v -o > $alignment
}

task AlignT2S
    < corpus=@CombineCorpora
    > alignment
    :: cdec_dir=@ {
  $cdec_dir/word-aligner/fast_align -i $corpus -d -v -o -r > $alignment
}

task Symmetrize
    < s2tAlignment=$alignment@AlignS2T
    < t2sAlignment=$alignment@AlignT2S
    > alignment
    :: heuristic="grow-diag"
    :: cdec_dir=@ {
  $cdec_dir/utils/atools -i $s2tAlignment -j $t2sAlignment -c $heuristic > $alignment
}

task SeparateAlignments
    < train=$train_source
    < traindev_alignment=$alignment@Symmetrize
    > train_alignment
    > dev_alignment {
  train_lines=$(cat $train | wc -l)
  head -n $train_lines $traindev_alignment > $train_alignment
  tail -n +$(($train_lines + 1)) $traindev_alignment > $dev_alignment
}

task BuildBrownClusters
    < train_target=$train_unk@RemoveSingletons[Side:target]
    < vocab=@BuildVocab[Side:target]
    > cluster_map="out/paths"
    :: wcluster_path=@
    :: cores=@ {
  set -x
  vocab_size=$(cat $vocab | wc -l)
  num_clusters=$(echo "3 * sqrt($vocab_size)" | bc)
  $wcluster_path --c $num_clusters --thread $cores --output_dir ./out --text "$train_target"
}

task MergeCorpora
    < source=(CorpusPart:
        train=$train_unk@RemoveSingletons[Side:source]
          dev=$dev_unk@RemoveSingletons[Side:source])
    < target=(CorpusPart:
        train=$train_unk@RemoveSingletons[Side:target]
          dev=$dev_unk@RemoveSingletons[Side:target])
    > corpus {
  paste $source $target | sed 's/\t/ ||| /g' > $corpus
}

task MakeOxLMConfig
    < train_corpus=$corpus@MergeCorpora[CorpusPart:train]
    < dev_corpus=$corpus@MergeCorpora[CorpusPart:dev]
    < train_alignment=@SeparateAlignments
    < dev_alignment=@SeparateAlignments
    < cluster_map=@BuildBrownClusters
    > config
    :: cores=@ {
  echo "iterations=50" >> config
  echo "minibatch-size=10000" >> config
  echo "lambda-lbl=2" >> config
  echo "word-width=200" >> config # Word vector dimensionality
  echo "step-size=0.1" >> config # Learning rate
  echo "order=5" >> config # Target n-gram order
  echo "source-order=6" >> config # source window size = 2 * this - 1
  echo "randomise=true" >> config
  echo "diagonal-contexts=true" >> config
  echo "threads=$cores" >> config # Number of threads
  echo "sigmoid=true" >> config
  echo "input=$train_corpus" >> config
  echo "alignment=$train_alignment" >> config
  echo "test-set=$dev_corpus" >> config
  echo "test-alignment=$dev_alignment" >> config
  echo "class-file=$cluster_map" >> config
}

task BuildModel
    < config=@MakeOxLMConfig
    > model
    :: oxlm_dir=@ {
  $oxlm_dir/bin/train_conditional_sgd -c $config --model-out=$model
  ln -s $model.* $model
}
