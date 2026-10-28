#!/bin/bash
# End-to-end check of this install on a compute node: makes a synthetic 3-round SELEX
# dataset with 5 planted winners, runs every AptaSuite module through run_aptasuite.sbatch,
# and prints PASS if the 5 largest clusters in the last round are the 5 winners.
#
#   sbatch /path/to/aptasuite-nova/test/smoke_test.sbatch      (add -A <account> if needed)
#
# Takes about 10 minutes on 8 cores. Each run writes into its own test/work/<jobid>/
# inside the clone (under 1 GB; safe to remove afterwards).
#SBATCH --job-name=aptasuite_test
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=8
#SBATCH --mem=16G
#SBATCH --time=01:00:00
#SBATCH --output=aptasuite_test_%j.out

if [[ ${MODULEPATH:-} != */opt/rit/* ]] || ! type module >/dev/null 2>&1; then
    source /etc/profile >/dev/null 2>&1
fi

set -euo pipefail

SELF=${BASH_SOURCE[0]}
case "$SELF" in
    */slurmd/*|*/slurm_script)
        SELF=$(scontrol show job "$SLURM_JOB_ID" | sed -n 's/^ *Command=\([^ ]*\).*/\1/p')
        SELF=${SELF%%$'\n'*}
        case "$SELF" in /*) ;; *) SELF=$SLURM_SUBMIT_DIR/$SELF ;; esac ;;
esac
TEST=$(dirname "$(readlink -f "$SELF")")
APTA_HOME=$(dirname "$TEST")
# A fresh folder per job, so a re-run can never pass on an earlier run's files.
W=$TEST/work/${SLURM_JOB_ID:-$$}

# 20,000 reads per round: with much less data AptaTRACE finds no k-mers above alpha and writes no motifs.
python3 "$TEST/make_test_data.py" "$W/data" 20000

cat > "$W/test.cfg" <<EOF
Experiment.name = "aptasuite-nova smoke test"
Experiment.description = "synthetic 3-round SELEX with 5 planted winners"
Experiment.projectPath = $W/project
Experiment.primer5 = GGGAGGACGATGCGG
Experiment.primer3 = CAGACGACTCGCCCGA

SelectionCycle.name = R0
SelectionCycle.round = 0
SelectionCycle.isControlSelection = False
SelectionCycle.isCounterSelection = False

SelectionCycle.name = R3
SelectionCycle.round = 3
SelectionCycle.isControlSelection = False
SelectionCycle.isCounterSelection = False

SelectionCycle.name = R6
SelectionCycle.round = 6
SelectionCycle.isControlSelection = False
SelectionCycle.isCounterSelection = False

AptaplexParser.isPerFile = True
AptaplexParser.forwardFiles = $W/data/round_0.fastq
AptaplexParser.forwardFiles = $W/data/round_3.fastq
AptaplexParser.forwardFiles = $W/data/round_6.fastq

Aptacluster.RandomizedRegionSize = 40
Aptacluster.LSHDimension = 30
Export.Cycles = R0, R6
Performance.maxNumberOfCores = ${SLURM_CPUS_PER_TASK:-8}
EOF

APTA_HOME=$APTA_HOME bash "$APTA_HOME/run_aptasuite.sbatch" "$W/test.cfg" \
    -parse -predict structure,bppm -cluster -trace -export pool,cycles,clusters,clustertable

echo
echo "=== checks ==="
fail=0
for f in export/pool.txt.gz export/cluster_table.txt.gz; do
    if [ -s "$W/project/$f" ]; then echo "ok   $f"; else echo "FAIL $f missing"; fail=1; fi
done
if ls "$W"/project/export/aptatrace/*/KLScore.txt >/dev/null 2>&1; then echo "ok   AptaTRACE output"
else echo "FAIL AptaTRACE output missing"; fail=1; fi

# The 5 largest R6 clusters should be seeded by the 5 planted winners (primers stripped).
top=$(zcat "$W/project/export/cluster_table.txt.gz" | sed -n '2,6p' | cut -f2 \
      | sed -e 's/^GGGAGGACGATGCGG//' -e 's/CAGACGACTCGCCCGA$//' | sort)
if [ "$top" = "$(sort "$W/data/winners.txt")" ]; then echo "ok   top 5 clusters are the 5 planted winners"
else echo "FAIL top 5 clusters differ from the planted winners"; fail=1; fi

if [ $fail -eq 0 ]; then echo "PASS"; else echo "FAIL"; exit 1; fi
