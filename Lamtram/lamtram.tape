#!/usr/bin/env ducttape

task LowercaseCorpus
  < in_source=(DataSection:
    train=$train_source
    dev=$dev_source
    test=$test_source)
  < in_target=(DataSection:
    train=$train_target
    dev=$dev_target
    test=$test_source)
  > source
  > target {
  cat $in_source | perl -nle 'print lc' > $source
  cat $in_target | perl -nle 'print lc' > $target
}

task TrainSentencePiece
  < train_source=(Lowercase:
    no=$train_source
    yes=$source@LowercaseCorpus[DataSection:train])
  < train_target=(Lowercase:
    no=$train_target
    yes=$target@LowercaseCorpus[DataSection:train])
  > model="model.model"
  :: vocab_size=@
  :: sentence_piece_dir=@ {
  cat $train_source $train_target > ./concat
  $sentence_piece_dir/src/spm_train --input=./concat --model_prefix="./model" --vocab_size=$vocab_size --model_type=unigram
}

task EncodeSentencePiece
  < in_source=(DataSection:
    train=$train_source
    dev=$dev_source
    test=$test_source)
  < in_target=(DataSection:
    train=$train_target
    dev=$dev_target
    test=$test_target)
  < model=@TrainSentencePiece
  > source
  > target
  :: sentence_piece_dir=@ {
  cat $in_source | $sentence_piece_dir/src/spm_encode --model=$model --output_format=piece > $source
  cat $in_target | $sentence_piece_dir/src/spm_encode --model=$model --output_format=piece > $target
}

task Align
  < train_source=$source@EncodeSentencePiece[DataSection:train]
  < train_target=$target@EncodeSentencePiece[DataSection:train]
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

task Train
  < train_source=$source@EncodeSentencePiece[DataSection:train]
  < train_target=$target@EncodeSentencePiece[DataSection:train]
  < dev_source=$source@EncodeSentencePiece[DataSection:dev]
  < dev_target=$target@EncodeSentencePiece[DataSection:dev]
  < prob_table=@MakeProbTable
  < prev_model="/dev/null"
  :: model_type="encatt"
  :: alpha="0.0001"
  :: attention_type="mlp:512"
  :: layers="lstm:512:1"
  :: trainer="adam"
  :: learning_rate="0.0002"
  :: minibatch_size="512"
  :: rate_decay="0.5"
  :: eval_every="10000"
  :: early_stop="5"
  :: seed=1
  :: lamtram_dir=@
  > model=model3 {
  for step in 1 2 3; do
    if [[ $step == 1 ]]; then
      prev_model_flag=""
    else
      prev=$(echo "$step - 1" | bc)
      prev_model_flag="--model_in=./model$prev"
    fi
    step_learning_rate=$(echo "scale=8; $learning_rate / 2 ^ ($step - 1)" | bc)
    $lamtram_dir/src/lamtram/lamtram-train \
      --dynet_mem 10000 \
      --model_type $model_type \
      --train_src $train_source \
      --train_trg $train_target \
      --dev_src $dev_source \
      --dev_trg $dev_target \
      --attention_lex prior:file=$prob_table:alpha=$alpha \
      --attention_type $attention_type \
      --layers $layers \
      --trainer $trainer \
      --learning_rate $step_learning_rate \
      --minibatch_size $minibatch_size \
      --rate_decay $rate_decay \
      --eval_every $eval_every \
      --early_stop $early_stop \
      --seed $seed \
      $prev_model_flag \
      --model_out ./model$step > ./log$step 2>&1
  done
}

task TrainMinRisk
  < train_source=$source@EncodeSentencePiece[DataSection:train]
  < train_target=$target@EncodeSentencePiece[DataSection:train]
  < dev_source=$source@EncodeSentencePiece[DataSection:dev]
  < dev_target=$target@EncodeSentencePiece[DataSection:dev]
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
  :: run_number=(MinRiskRun: 1 2 3)
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
    --max_len 100 \
    --model_in $model_in \
    --model_out $model > ./log 2>&1
}

task Test
  < input=(DevOrTest:
    test=$source@EncodeSentencePiece[DataSection:test]
    dev=$source@EncodeSentencePiece[DataSection:dev])
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

task Detok
  < input=$output@Test
  < model=@TrainSentencePiece
  > output
  :: sentence_piece_dir=@ {
  $sentence_piece_dir/src/spm_decode --model=$model --input_format=piece < $input > $output
}

task Evaluate
    < output=@Detok
    < refs=(DevOrTest:
      test=$test_target
      dev=$dev_target)
    > bleu meteor ter length
    :: multeval=@
    :: meteor_task=@
    :: meteor_lang=@ {
        #test=$target@EncodeSentencePiece[DataSection:test]
        #dev=$target@EncodeSentencePiece[DataSection:dev])
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
