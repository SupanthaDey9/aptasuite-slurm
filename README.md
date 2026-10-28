# aptasuite-nova

Run [AptaSuite](https://github.com/drivenbyentropy/aptasuite) (HT-SELEX aptamer analysis: AptaPLEX, AptaCLUSTER, AptaTRACE, structure prediction) as Slurm jobs on ISU Nova.

This repo does not contain AptaSuite. `install.sh` downloads the official v0.9.8 release from the authors' GitHub and checks its SHA-256. What the repo adds:

- **`run_aptasuite.sbatch`:** a job script that loads Java 11, sizes the Java heap from your Slurm memory request, runs the AptaSuite command line, and marks the job FAILED when AptaSuite reports an error (AptaSuite's own exit status is unreliable).
- **`example.cfg`:** a configuration template with every required setting.
- **`test/smoke_test.sbatch`:** a 10-minute end-to-end test that prints PASS or FAIL.

The interactive AptaSuite GUI is not available on Nova; the command line runs the analyses (import, structure prediction, clustering, AptaTRACE, export).

## Install (once)

```bash
ssh <NetID>@nova.its.iastate.edu
cd /work/YOURGROUP/YOU            # ~1.5 GB free, no spaces in the path; not your small home directory
git clone https://github.com/SupanthaDey9/aptasuite-nova.git
cd aptasuite-nova
./install.sh                       # downloads AptaSuite 0.9.8 (345 MB), about a minute
sbatch test/smoke_test.sbatch      # add -A <account> if you have several Slurm accounts
```

When the test job ends, `aptasuite_test_<jobid>.out` should finish with `PASS`. The test makes a synthetic 3-round SELEX dataset with 5 planted winners, runs every module, and checks that the 5 largest clusters are those winners and that AptaTRACE wrote motifs. Each run leaves under 1 GB in `test/work/<jobid>/`, which you can remove afterwards.

## Run your data

```bash
R=/work/YOURGROUP/YOU/aptasuite-nova           # where you cloned it
cp $R/example.cfg my_selex.cfg                 # edit the lines marked EDIT
sbatch $R/run_aptasuite.sbatch my_selex.cfg \
    -parse -predict structure -cluster -trace -export pool,cycles,clusters,clustertable
```

- **Resources.** The defaults are 16 cores, 64 GB and 24 h. Change them with sbatch options before the script path, and set `Performance.maxNumberOfCores` in the config to the same core count:
  `sbatch -c 32 --mem=128G -t 48:00:00 $R/run_aptasuite.sbatch my_selex.cfg -parse ...`
- **Options.** Everything after the config file goes to AptaSuite unchanged: `-parse`, `-simulate`, `-predict structure,bppm`, `-cluster`, `-trace`, `-export pool,cycles,clusters,structures,clustertable`.
  `-trace` (AptaTRACE) needs the structure predictions, so run `-predict structure` first, in the same job or an earlier one.
- **Steps in separate jobs.** Run `-parse -predict structure` first. Then run `-cluster -trace -export ...` on the same config, chained so it starts only if the first job succeeded:
  `sbatch --dependency=afterok:<first jobid> $R/run_aptasuite.sbatch my_selex.cfg -cluster -trace -export pool,clustertable`
- **Outputs.** Everything goes under `Experiment.projectPath`: the database, `logs/`, and `export/` (including `export/aptatrace/`).
- **Job log.** `aptasuite_<jobid>.out` is written in the folder you submitted from.

## Measured on Nova

Synthetic data, 3 rounds of 20,000 reads, 40-nt random region (71-nt reads after primers), 50,878 unique sequences, 8 cores, Java 11:

| step | time | rate |
|---|---|---|
| `-parse` (AptaPLEX) | 2 s | |
| `-predict structure` (CapR) | 287 s | about 180 sequences/s |
| `-predict bppm` | 106 s | about 490 sequences/s |
| `-cluster -trace -export` | 74 s | |

Structure prediction dominates. At the measured rate, 10 million unique sequences of similar length would take about 15 h on 8 cores; if it scales linearly with cores (not measured), about 4 h on 32. Each number is a single run (n = 1).

## Things that will bite you

- **Steps delete their own earlier results.** `-parse` deletes `pooldata/`, `cycledata/`, `structuredata/`, `clusterdata/` and `bppmdata/` inside the project folder. `-predict structure`, `-predict bppm` and `-cluster` each delete their own previous output, and `-simulate` replaces the data with a simulated pool. Give each experiment its own folder.
- **`Experiment.primer3` is required.** In AptaSuite 0.9.8, `-parse` fails without it, although the AptaSuite wiki calls it optional.
- **`Aptacluster.LSHDimension` is required.** AptaSuite has no default and `-cluster` crashes without it. About 3/4 of the random region works (30 for 40 nt); it must be smaller than `Aptacluster.RandomizedRegionSize`.
- **AptaCLUSTER only clusters one length.** Sequences whose random region is not exactly `Aptacluster.RandomizedRegionSize` long are silently skipped.
- **A missing project folder is not an error.** If `Experiment.projectPath` does not exist, AptaSuite quietly writes everything next to the config file. `run_aptasuite.sbatch` creates the folder first.
- **AptaSuite's exit status is unreliable.** It exits 0 even on a misspelled option, an exception in one of its worker threads, or an unreadable input file. `run_aptasuite.sbatch` therefore marks the job FAILED when the output contains `Exception in thread` or `Parameter Error`, or this run's log in `<projectPath>/logs/` contains a SEVERE entry.
  Every run prints a harmless `IntrospectionException` DEBUG line at start-up; ignore it.
- **Structure exports are large.** `-export structures` wrote 168 MB for 51k sequences, so tens of GB for a full dataset. Leave it out unless you need it.
- **Use Java 11.** The job script loads `openjdk/11.0.31_11-b3sms67`. Under Java 17 and 21 (`openjdk/17.0.11_9-cvie7ad`, `openjdk/21.0.3_9-vngib7s`), `-parse` throws `InaccessibleObjectException` while saving the experiment metadata, carries on, and AptaSuite still exits 0.
  In our test the imported reads were identical to the Java 11 run, but the metadata file was not saved cleanly.
  To use another module anyway: `sbatch --export=ALL,JAVA_MODULE=<module> ...`; `JAVA_MODULE=` (empty) uses the `java` already on your PATH.
- **Clustering is not deterministic.** AptaCLUSTER uses random hashing, so the same data gives slightly different cluster sizes from run to run (a few percent for the top clusters in our tests). The imported counts themselves are identical.
- **Keep the job script in the clone.** It finds AptaSuite next to itself. If you submit a copy from somewhere else, add `--export=ALL,APTA_HOME=/path/to/aptasuite-nova`; it is simpler to pass options on the sbatch line instead of editing a copy.
- **Submitting from a script or over plain `ssh nova 'sbatch ...'`** works too: the job script loads Nova's module setup itself.

## Tested with

ISU Nova (RHEL 9, x86-64), AptaSuite 0.9.8, OpenJDK 11.0.31, October 2026. Not tested on other clusters; on another Slurm cluster, set `JAVA_MODULE` to a local Java 11 module.

## Credit and license

AptaSuite is by Jan Hoinka and colleagues and is licensed GPL-3.0. If you use it, cite:

> Hoinka, J., Backofen, R. and Przytycka, T. M. (2018). AptaSUITE: A Full-Featured Bioinformatics Framework for the Comprehensive Analysis of Aptamers from HT-SELEX Experiments. *Molecular Therapy - Nucleic Acids* 11, 515–517. https://doi.org/10.1016/j.omtn.2018.04.006

and the algorithms you used (listed in the AptaSuite GUI under Help → How to Cite, and printed in the job log).

The scripts in this repo are Apache-2.0 (`LICENSE`).
