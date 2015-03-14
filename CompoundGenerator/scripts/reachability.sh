INPUT="dev.lower.uniq.short.lat2"
CDEC_INI=cdec.ini
WEIGHTS="mira_work_wer2/weights.1"
OUT=$(mktemp)

#cat $INPUT cdec -c $CDEC_INI -w $WEIGHTS >$OUT 2>&1
unreachable=$(grep 'REFERENCE UNREACHABLE' cdec.out | wc -l)
reachable=$(grep 'Constr. VitTree:' cdec.out | wc -l)
echo "$unreachable unreachable, $reachable reachable"
