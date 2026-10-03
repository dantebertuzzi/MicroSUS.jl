#!/usr/bin/env bash
# Roda a matriz do benchmark e acrescenta uma linha JSON por medição em
# benchmark/resultados.jsonl. Cada medição é um processo novo.
#
#   DBC=<pasta com os .dbc>  RSCRIPT=<Rscript>  PYTHON=<python>  benchmark/roda.sh
#
# Os arquivos vêm do cache do MicroSUS (mesmos bytes para os três).
set -u
cd "$(dirname "$0")/.."
DBC=${DBC:?pasta com os .dbc}
RSCRIPT=${RSCRIPT:-Rscript}
PYTHON=${PYTHON:-python3}
SAIDA=benchmark/resultados.jsonl
LIMITE_KB=${LIMITE_KB:-9000000}   # R e Python: MemoryError em vez de esgotar a RAM

FERRAMENTAS=${FERRAMENTAS:-"julia1 juliaN r python"}

mede() {  # ferramenta arquivo tarefa reps
    case " $FERRAMENTAS " in *" $1 "*) ;; *) return ;; esac
    local f=$DBC/$2
    case $1 in
        julia1)  julia --project=. -t 1    benchmark/bench_julia.jl "$f" "$3" "$4" ;;
        juliaN)  julia --project=. -t auto benchmark/bench_julia.jl "$f" "$3" "$4" ;;
        r)       (ulimit -v $LIMITE_KB; "$RSCRIPT" benchmark/bench_r.R "$f" "$3" "$4") ;;
        python)  (ulimit -v $LIMITE_KB; "$PYTHON" benchmark/bench_python.py "$f" "$3" "$4") ;;
    esac 2>/dev/null | grep '^{' >> $SAIDA || echo "{\"ferramenta\":\"$1\",\"arquivo\":\"$2\",\"tarefa\":\"$3\",\"falhou\":true}" >> $SAIDA
}

for arq in DOPE2023.dbc DOSP2023.dbc DNSP2023.dbc DENGBR23.dbc; do
    reps=3; [ $arq = DENGBR23.dbc ] && reps=1
    for fer in julia1 juliaN r python; do mede $fer $arq tudo $reps; done
done
for arq in DOPE2023.dbc DOSP2023.dbc; do
    for fer in julia1 juliaN r python; do mede $fer $arq cvli 3; done
    for fer in julia1 juliaN r; do mede $fer $arq padronizar 3; done
done
