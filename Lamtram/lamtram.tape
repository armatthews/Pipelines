#!/usr/bin/env ducttape

task Align
  < train_source=@
  < train_target=@
  > alignment
  > ttable
  :: fast_align=@ {
  if [[ $(cat $train_source | grep '	' | wc -l) != 0 ]]; then
    echo "train_source contains tabs. Please fix." >&2
    exit 1
  fi
  if [[ $(cat $train_target | grep '	' | wc -l) != 0 ]]; then
    echo "train_target contains tabs. Please fix." >&2
    exit 1
  fi

  paste $train_source $train_target | sed 's/	/ ||| /g' > ./corpus
  $fast_align -i ./corpus -v -p $ttable > $alignment && \
  rm ./corpus
}

task MakeProbTable
  < ttable=@Align
  > prob_table
  :: lamtram_dir=@ {
  cat $ttable | $lamtram_dir/script/convert-cond.pl > $prob_table
}

task Unkify
  < corpus=(Side:
    source=$train_source
    target=$train_target)
  > unk_corpus
  :: lamtram_dir=@ {
  cat $corpus | $lamtram_dir/script/unk-single.pl > $unk_corpus
}

task Train
  < train_source=$unk_corpus@Unkify[Side:source]
  < train_target=$unk_corpus@Unkify[Side:target]
  < dev_source=@
  < dev_target=@
  < prob_table=@MakeProbTable
  :: model_type="encatt"
  :: alpha="0.0001"
  :: attention_type="mlp:512"
  :: layers="lstm:512:1"
  :: trainer="adam"
  :: learning_rate="0.001"
  :: minibatch_size="512"
  :: rate_decay="0.5"
  :: eval_every="30000"
  :: lamtram_dir=@
  > model {
  $lamtram_dir/src/lamtram/lamtram-train \
    --cnn_mem 10000 \
    --model_type $model_type \
    --train_src $train_source \
    --train_trg $train_target \
    --dev_src $dev_source \
    --dev_trg $dev_target \
    --attention_lex prior:file=$prob_table:alpha=$alpha \
    --attention_type $attention_type \
    --layers $layers \
    --trainer $trainer \
    --learning_rate $learning_rate \
    --minibatch_size $minibatch_size \
    --rate_decay $rate_decay \
    --eval_every $eval_every \
    --model_out $model > ./log 2>&1
}

task TrainMinRisk
  < train_source=$unk_corpus@Unkify[Side:source]
  < train_target=$unk_corpus@Unkify[Side:target]
  < dev_source=@
  < dev_target=@
  < model_in=$model@Train
  > model
  :: model_type="encatt"
  :: eval_every="10000"
  :: trainer="sgd"
  :: learning_rate="0.1"
  :: rate_decay="1.0"
  :: num_samples="15"
  :: minrisk_scaling="0.005"
  :: eval_meas=$eval_measure
  :: lamtram_dir=@
  {
  $lamtram_dir/src/lamtram/lamtram-train \
    --cnn_mem 4850,4850,1800 \
    --model_type encatt \
    --train_src $train_source \
    --train_trg $train_target \
    --dev_src $dev_source \
    --dev_trg $dev_target \
    --eval_every $eval_every \
    --trainer $trainer \
    --learning_criterion minrisk \
    --learning_rate $learning_rate \
    --rate_decay $rate_decay \
    --minrisk_num_samples $num_samples \
    --minrisk_scaling $minrisk_scaling \
    --minrisk_include_ref false \
    --eval_meas $eval_meas \
    --model_in /tmp/model.enru2 \
    --model_out $model > ./log 2>&1
}
    #--model_in $model_in \

task Test
  < input=(DevOrTest:
    test=$test_source
    dev=$dev_source)
  < model=(MinRisk:
    no=$model@Train
    yes=$model@TrainMinRisk)
  < prob_table=@MakeProbTable
  > output
  :: model_type=@Train
  :: beam="5"
  :: word_pen="0.0"
  :: lamtram_dir=@ {
  $lamtram_dir/src/lamtram/lamtram \
    --cnn_mem 10000 \
    --operation gen \
    --models_in $model_type=$model \
    --src_in $input \
    --map_in $prob_table \
    --beam $beam \
    --word_pen $word_pen \
    > $output
}

task Evaluate 
    < output=@Test
    < refs=(DevOrTest:
        test=$test_target
        dev=$dev_target)
    > bleu meteor ter length
    :: multeval=@
    :: meteor_task=@
    :: meteor_lang=@ {
  scoreFile=scores.txt

  if [ ! -e constants ]; then
    ln -s $(dirname $multeval)/constants .
  fi

  $multeval eval --refs $refs --hyps-baseline $output --meteor.task $meteor_task --meteor.language $meteor_lang &> $scoreFile && \
  tail -n 2 $scoreFile | head -n 1 | sed 's/(\S\+)//g' | sed 's/\s\+/\t/g' | cut -f 2 > $bleu && \
  tail -n 2 $scoreFile | head -n 1 | sed 's/(\S\+)//g' | sed 's/\s\+/\t/g' | cut -f 3 > $meteor && \
  tail -n 2 $scoreFile | head -n 1 | sed 's/(\S\+)//g' | sed 's/\s\+/\t/g' | cut -f 4 > $ter && \
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
