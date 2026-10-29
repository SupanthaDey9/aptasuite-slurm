#!/bin/bash
# Run the AptaSuite command-line interface as a Slurm job.
#
# Usage, from any folder:
#   sbatch [sbatch options] /path/to/aptasuite-slurm/run_aptasuite.sbatch experiment.cfg -parse -predict structure -cluster -trace -export pool
#
# Everything after the config file is passed to AptaSuite unchanged
# (options: -parse -simulate -predict structure,bppm -cluster -trace -export ...).
# Change cores, memory and time with sbatch options before the script path
# (-c 32 --mem=128G -t 48:00:00), and add -p <partition> / -A <account> if your cluster
# needs them. Set Performance.maxNumberOfCores in the config to the same number of cores.
#
# Needs Java 11 (or 8): the module named in JAVA_MODULE if set (sbatch --export=ALL,JAVA_MODULE=<module>),
# else the java on PATH if it is 11 or 8, else module openjdk/11, java/11 or Java/11.
#
# The job is marked FAILED if AptaSuite prints "Exception in thread" or "Parameter Error",
# or logs a SEVERE error, because AptaSuite itself often exits 0 after an error.
#SBATCH --job-name=aptasuite
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=16
#SBATCH --mem=64G
#SBATCH --time=24:00:00
#SBATCH --output=aptasuite_%j.out

# A job submitted from a non-login (or non-bash) shell may have no `module` command.
if ! type module >/dev/null 2>&1; then
    source /etc/profile >/dev/null 2>&1 || true
fi

set -euo pipefail

if [ $# -lt 2 ]; then
    echo "usage: sbatch run_aptasuite.sbatch <config.cfg> <aptasuite options...>" >&2
    exit 2
fi
CONFIG=$(readlink -f "$1"); shift

# sbatch runs a spooled copy of this script, so ask Slurm where the original lives.
if [ -z "${APTA_HOME:-}" ]; then
    SELF=${BASH_SOURCE[0]}
    case "$SELF" in
        */slurmd/*|*/slurm_script)
            SELF=$(scontrol show job "$SLURM_JOB_ID" | sed -n 's/^ *Command=\([^ ]*\).*/\1/p')
            SELF=${SELF%%$'\n'*}
            case "$SELF" in /*) ;; *) SELF=$SLURM_SUBMIT_DIR/$SELF ;; esac ;;
    esac
    APTA_HOME=$(dirname "$(readlink -f "$SELF")")
fi
JAR=$APTA_HOME/aptasuite-0.9.8/aptasuite-0.9.8.jar
if [ ! -f "$JAR" ]; then
    echo "AptaSuite not found at $JAR." >&2
    echo "Run install.sh in your aptasuite-slurm clone; if you submitted a copy of this script" >&2
    echo "from elsewhere, add --export=ALL,APTA_HOME=/path/to/aptasuite-slurm to sbatch." >&2
    exit 1
fi

# Java 11 (tested) or 8 (AptaSuite's own target). Under Java 17+ AptaSuite fails while
# saving its metadata, so never fall through to whatever newer java happens to be on PATH.
java_ok() { local v; v=$(java -version 2>&1 || true); [[ $v == *'version "11.'* || $v == *'version "1.8.'* ]]; }
if [ -n "${JAVA_MODULE:-}" ]; then
    module load "$JAVA_MODULE"
elif ! java_ok; then
    module load openjdk/11 >/dev/null 2>&1 || module load java/11 >/dev/null 2>&1 \
        || module load Java/11 >/dev/null 2>&1 || true
fi
if ! java_ok; then
    echo "Java 11 not found. Submit with --export=ALL,JAVA_MODULE=<your cluster's Java 11 module>" >&2
    echo "(see 'module avail openjdk java Java'), or load it before submitting." >&2
    exit 1
fi

# AptaSuite silently writes next to the config file if projectPath does not exist yet.
# It uses the first projectPath line, so do the same.
PROJ=$(sed -n 's/^[[:space:]]*Experiment\.projectPath[[:space:]]*[=:][[:space:]]*//p' "$CONFIG" | head -n1 | sed 's/[[:space:]]*$//')
if [ -n "$PROJ" ]; then mkdir -p "$PROJ"; fi
PROJ_DIR=${PROJ:-$(dirname "$CONFIG")}

# Give the JVM heap ~85% of the job's memory; the rest covers JVM overhead and MapDB's mmap use.
if [ -n "${SLURM_MEM_PER_NODE:-}" ]; then MEM_MB=$SLURM_MEM_PER_NODE
elif [ -n "${SLURM_MEM_PER_CPU:-}" ]; then MEM_MB=$(( SLURM_MEM_PER_CPU * ${SLURM_CPUS_ON_NODE:-1} ))
else MEM_MB=8192; fi
HEAP_MB=$(( MEM_MB * 85 / 100 ))

echo "node=${SLURMD_NODENAME:-local} nproc=$(nproc) heap=${HEAP_MB}M config=$CONFIG project=${PROJ:-<config dir>}"
java -version 2>&1 | head -1

# AptaSuite can exit 0 after an error (a bad option, an exception in a worker thread,
# an unreadable input file), so keep a copy of its output and check it and this run's log.
# The marker sits in the project folder so its time and the logs' times come from one clock.
# Headless: the CLI never opens the JavaFX GUI.
MARK=$(mktemp "$PROJ_DIR/.aptasuite_run.XXXXXX")
OUT=$(mktemp "${TMPDIR:-/tmp}/aptasuite.XXXXXX")
trap 'rm -f "$MARK" "$OUT"' EXIT
java -Djava.awt.headless=true -Xmx${HEAP_MB}m -jar "$JAR" -config "$CONFIG" "$@" 2>&1 | tee "$OUT"
SEVERE=$(find "$PROJ_DIR/logs" -maxdepth 1 -name 'log_*.txt' -newer "$MARK" -exec grep -l '| SEVERE |' {} + 2>/dev/null || true)
if grep -q -E 'Exception in thread|Parameter Error' "$OUT" || [ -n "$SEVERE" ]; then
    echo "FAILED: AptaSuite reported an error (see above${SEVERE:+ and $SEVERE}), although its exit status was 0." >&2
    exit 1
fi
echo "Done: no errors reported. Outputs are in $PROJ_DIR/export/."
