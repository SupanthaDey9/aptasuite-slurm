#!/usr/bin/env python3
"""Write a small synthetic HT-SELEX dataset (3 rounds, per-file FASTQ) for an AptaSuite smoke test.

Reads are PRIMER5 + 40-nt random region + PRIMER3. Five planted "winner" aptamers
enrich from round 0 to round 6 so clustering and AptaTRACE have something to find.

usage: make_test_data.py OUTDIR [READS_PER_ROUND]
"""
import random
import sys
from pathlib import Path

PRIMER5 = "GGGAGGACGATGCGG"
PRIMER3 = "CAGACGACTCGCCCGA"
RR = 40
READS_PER_ROUND = 20000
# fraction of reads drawn from each planted winner, per round
WINNER_FRACTION = {0: 0.0005, 3: 0.02, 6: 0.10}

rng = random.Random(7)


def rand_seq(n):
    return "".join(rng.choice("ACGT") for _ in range(n))


def mutate(seq, n_mut):
    s = list(seq)
    for i in rng.sample(range(len(s)), n_mut):
        s[i] = rng.choice([b for b in "ACGT" if b != s[i]])
    return "".join(s)


def main(outdir, reads_per_round=READS_PER_ROUND):
    outdir = Path(outdir)
    outdir.mkdir(parents=True, exist_ok=True)
    winners = [rand_seq(RR) for _ in range(5)]
    for rnd, frac in WINNER_FRACTION.items():
        path = outdir / f"round_{rnd}.fastq"
        with path.open("w") as fh:
            for i in range(reads_per_round):
                if rng.random() < frac * len(winners):
                    core = mutate(rng.choice(winners), rng.choice([0, 0, 0, 1, 2]))
                else:
                    core = rand_seq(RR)
                read = PRIMER5 + core + PRIMER3
                fh.write(f"@r{rnd}_{i}\n{read}\n+\n{'I' * len(read)}\n")
        print(f"wrote {path}")
    (outdir / "winners.txt").write_text("\n".join(winners) + "\n")


if __name__ == "__main__":
    main(sys.argv[1], int(sys.argv[2]) if len(sys.argv) > 2 else READS_PER_ROUND)
