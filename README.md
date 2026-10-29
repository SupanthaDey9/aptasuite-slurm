# aptasuite-slurm

Run [AptaSuite](https://github.com/drivenbyentropy/aptasuite) (HT-SELEX aptamer analysis: AptaPLEX, AptaCLUSTER, AptaTRACE, structure prediction) as Slurm jobs on an HPC cluster.

> **AptaSuite is not our software.** AptaSuite and its algorithms are the work of Jan Hoinka and colleagues; its structure predictions build on CapR and the ViennaRNA package, by other groups. This repo only adds scripts for running it on a Slurm cluster and is not affiliated with or endorsed by the AptaSuite authors. If you use it, cite their papers: see [How to cite](#how-to-cite).

This repo does not contain AptaSuite. `install.sh` downloads the official v0.9.8 release from the authors' GitHub and checks its SHA-256. What the repo adds:

- **`run_aptasuite.sbatch`:** a job script that finds Java 11, sizes the Java heap from your Slurm memory request, runs the AptaSuite command line, and marks the job FAILED when AptaSuite reports an error (AptaSuite's own exit status is unreliable).
- **`example.cfg`:** a configuration template with every required setting.
- **`test/smoke_test.sbatch`:** a 10-minute end-to-end test that ends with PASS when everything works.

The interactive AptaSuite GUI is not used here; the command line runs the analyses (import, structure prediction, clustering, AptaTRACE, export).

## What you need

| Component | Notes |
|---|---|
| Linux cluster with Slurm | tested on Nova at Iowa State University |
| Java 11 | on PATH or as a module; the job script tries `openjdk/11`, `java/11` and `Java/11`, or set `JAVA_MODULE`. Java 8 (AptaSuite's own target) is also accepted but was not tested here; Java 17+ does not work. |
| curl, unzip, sha256sum | for `install.sh` |
| python3 | only for the smoke test |
| about 1.5 GB of disk | the install plus one test run |

## Install (once)

On your cluster's login node, in a project or scratch folder (not a small home directory, and no spaces in the path):

```bash
git clone https://github.com/SupanthaDey9/aptasuite-slurm.git
cd aptasuite-slurm
./install.sh                       # downloads AptaSuite 0.9.8 (345 MB), about a minute
sbatch test/smoke_test.sbatch      # add -p <partition> / -A <account> if your cluster needs them
```

When the test job ends, `aptasuite_test_<jobid>.out` should finish with `PASS`; anything else means it failed, and the lines above say why. The test makes a synthetic 3-round SELEX dataset with 5 planted winners, runs every step except `-simulate`, and checks that the 5 largest clusters are those winners and that AptaTRACE wrote motifs. Each run leaves under 1 GB in `test/work/<jobid>/`, which you can remove afterwards.

If the job stops with `Java 11 not found`, find your cluster's Java 11 module (`module avail openjdk java`) and submit with `sbatch --export=ALL,JAVA_MODULE=<that module> ...`. If your cluster has no Java 11 module, a conda environment with `openjdk=11` from conda-forge should also work (not tested here): activate it before `sbatch`, and the job inherits your PATH.

## Run your data

```bash
R=/path/to/aptasuite-slurm                     # where you cloned it
cp $R/example.cfg my_selex.cfg                 # edit the lines marked EDIT
sbatch $R/run_aptasuite.sbatch my_selex.cfg \
    -parse -predict structure -cluster -trace -export pool,cycles,clusters,clustertable
```

- **Options.** Everything after the config file goes to AptaSuite unchanged:
  - `-parse` (AptaPLEX) imports the reads, checks the primers and counts each sequence per round.
  - `-predict structure` predicts secondary-structure contexts (CapR). `-trace` needs these, so run it first, in the same job or an earlier one.
  - `-predict bppm` computes base-pair probabilities. Only AptaSuite's experimental AptaNET uses them, so most people can leave it out.
  - `-cluster` (AptaCLUSTER) groups similar sequences into families.
  - `-trace` (AptaTRACE) finds sequence-structure motifs that become enriched over the rounds.
  - `-export pool,cycles,clusters,structures,clustertable` writes results to files (see below).
  - `-simulate` (AptaSIM) makes a simulated pool instead of importing reads.
- **Resources.** The defaults are 16 cores, 64 GB and 24 h. Change them with sbatch options before the script path, and set `Performance.maxNumberOfCores` in the config to the same core count:
  `sbatch -c 32 --mem=128G -t 48:00:00 $R/run_aptasuite.sbatch my_selex.cfg -parse ...`
  During `-predict structure` the job log shows `Completed: x/N ... ETA`, where N is your number of unique sequences; check it early to see whether the time limit is long enough.
- **Steps in separate jobs.** Run `-parse -predict structure` first. Then run `-cluster -trace -export ...` on the same config, chained so it starts only if the first job succeeded:
  `sbatch --dependency=afterok:<first jobid> $R/run_aptasuite.sbatch my_selex.cfg -cluster -trace -export pool,clustertable`
- **Check the import.** The job log shows AptaPLEX's counts. If Accepted Reads is only a small part of Total Reads, look at which error column is large: many 3' Primer Errors usually mean `Experiment.primer3` was entered as the reverse primer you ordered instead of as it appears in the reads.
- **Job log.** `aptasuite_<jobid>.out` is written in the folder you submitted from.

### What you get

Everything goes under `Experiment.projectPath`: AptaSuite's database, `logs/`, and `export/`. With `-export pool,cycles,clusters,clustertable`, `export/` holds:

- **`cluster_table.txt.gz`:** start here. One row per cluster, sorted by size in the last round: the seed sequence, then for each round the cluster's size (fraction of that round's reads), diversity (number of distinct sequences in the cluster) and CPM (counts per million).
- **`pool.txt.gz`:** every unique sequence with its frequency in each round (set `Export.PoolCardinalityFormat = counts` for counts).
- **`<round>.fastq.gz` and `clusters_<round>.fastq.gz`:** the sequences and clusters of the rounds listed in `Export.Cycles`.
- **`aptatrace/`:** AptaTRACE's motifs, with logos and summary PDFs.

Exported sequences include the primers (`Export.IncludePrimerRegions = False` removes them). The project folder grows with the number of unique sequences: the 51k-sequence test used about 590 MB on disk.

## Measured on Nova

Synthetic data, 3 rounds of 20,000 reads, 40-nt random region (71-nt reads including primers), 50,878 unique sequences, 8 cores of one node, Java 11:

| step | time | rate |
|---|---|---|
| `-parse` (AptaPLEX) | 2 s | |
| `-predict structure` (CapR) | 287 s | about 180 sequences/s |
| `-predict bppm` | 106 s | about 480 sequences/s |
| `-cluster -trace -export` | 74 s | |

Structure prediction dominates. At the measured rate, 10 million unique sequences of similar length would take about 15 h on 8 cores; if it scales linearly with cores (not measured), about 4 h on 32. Each number is a single run (n = 1), and other clusters' CPUs will differ.

## Things that will bite you

- **Steps delete their own earlier results.** `-parse` deletes `pooldata/`, `cycledata/`, `structuredata/`, `clusterdata/` and `bppmdata/` inside the project folder. `-predict structure`, `-predict bppm` and `-cluster` each delete their own previous output, and `-simulate` replaces the data with a simulated pool. Give each experiment its own folder.
- **`Experiment.primer3` is required.** In AptaSuite 0.9.8, `-parse` fails without it, although the AptaSuite wiki calls it optional.
- **`Aptacluster.LSHDimension` is required.** AptaSuite has no default and `-cluster` crashes without it. About 3/4 of the random region works (30 for 40 nt); it must be smaller than `Aptacluster.RandomizedRegionSize`.
- **AptaCLUSTER only clusters one length.** Sequences whose random region is not exactly `Aptacluster.RandomizedRegionSize` long are silently skipped.
- **A missing project folder is not an error.** If `Experiment.projectPath` does not exist, AptaSuite writes everything next to the config file, with only a warning in its log. `run_aptasuite.sbatch` creates the folder first. Use absolute paths in the config: `~` and `$VARIABLES` are not expanded.
- **AptaSuite's exit status is unreliable.** It exits 0 even on a misspelled option, an exception in one of its worker threads, or an unreadable input file. `run_aptasuite.sbatch` therefore marks the job FAILED when the output contains `Exception in thread` or `Parameter Error`, or this run's log in `<projectPath>/logs/` contains a SEVERE entry.
  Every run prints a harmless `IntrospectionException` DEBUG line at start-up; ignore it.
- **Structure exports are large.** `-export structures` wrote 168 MB for 51k sequences, so tens of GB for a full dataset. Leave it out unless you need it.
- **Use Java 11, not 17 or newer.** Under Java 17 and 21, `-parse` throws `InaccessibleObjectException` while saving the experiment metadata, carries on, and AptaSuite still exits 0. In our test the imported reads were identical to the Java 11 run, but the metadata file was not saved cleanly. The job script therefore runs only on Java 11 or 8.
- **Clustering is not deterministic.** AptaCLUSTER uses random hashing, so the same data gives slightly different cluster sizes from run to run (a few percent for the top clusters in our tests). The imported counts themselves are identical.
- **Keep the job script in the clone.** It finds AptaSuite next to itself. If you submit a copy from somewhere else, add `--export=ALL,APTA_HOME=/path/to/aptasuite-slurm`; it is simpler to pass options on the sbatch line instead of editing a copy.
- **Submitting from a script or over plain `ssh <cluster> 'sbatch ...'`** works too: when the `module` command is missing, the job script loads the system profile itself.

## Tested with

Nova, the HPC cluster at Iowa State University (RHEL 9, x86-64, Slurm, Lmod modules), AptaSuite 0.9.8, OpenJDK 11.0.31, October 2026. On Nova the job script finds `openjdk/11` by itself. Other clusters have not been tested; the smoke test tells you in 10 minutes whether it works on yours.

## How to cite

Cite AptaSuite, plus the paper for each step you ran. The AptaSuite entries follow AptaSuite's own Help → How to Cite dialog, which is only in the GUI. The two structure-prediction steps are AptaSuite's Java ports of CapR and RNAfold, so cite those too. `-trace` uses the CapR predictions, so AptaTRACE users should cite CapR as well.

- **AptaSuite (always):** Hoinka J, Backofen R, Przytycka TM (2018). AptaSUITE: A Full-Featured Bioinformatics Framework for the Comprehensive Analysis of Aptamers from HT-SELEX Experiments. *Mol Ther Nucleic Acids* 11:515–517. https://doi.org/10.1016/j.omtn.2018.04.006
- **`-parse` (AptaPLEX):** Hoinka J, Przytycka T (2016). AptaPLEX - A dedicated, multithreaded demultiplexer for HT-SELEX data. *Methods* 106:82–85. https://doi.org/10.1016/j.ymeth.2016.04.011
- **`-predict structure` (CapR):** Fukunaga T, Ozaki H, Terai G, Asai K, Iwasaki W, Kiryu H (2014). CapR: revealing structural specificities of RNA-binding protein target recognition using CLIP-seq data. *Genome Biol* 15(1):R16. https://doi.org/10.1186/gb-2014-15-1-r16
- **`-predict bppm` (RNAfold, ViennaRNA package 1.8.5):** Hofacker IL, Fontana W, Stadler PF, Bonhoeffer LS, Tacker M, Schuster P (1994). Fast folding and comparison of RNA secondary structures. *Monatsh Chem* 125:167–188. https://doi.org/10.1007/BF00818163
- **`-cluster` (AptaCLUSTER):** Hoinka J, Berezhnoy A, Sauna ZE, Gilboa E, Przytycka TM (2014). AptaCluster – A Method to Cluster HT-SELEX Aptamer Pools and Lessons from Its Application. *Lecture Notes in Computer Science* 8394:115–128. https://doi.org/10.1007/978-3-319-05269-4_9
- **`-trace` (AptaTRACE):** Dao P, Hoinka J, Takahashi M, Zhou J, Ho M, Wang Y, Costa F, Rossi JJ, Backofen R, Burnett J, Przytycka TM (2016). AptaTRACE Elucidates RNA Sequence-Structure Motifs from Selection Trends in HT-SELEX Experiments. *Cell Syst* 3(1):62–70. https://doi.org/10.1016/j.cels.2016.07.003
- **`-simulate` (AptaSIM) and AptaMUT:** Hoinka J, Berezhnoy A, Dao P, Sauna ZE, Gilboa E, Przytycka TM (2015). Large scale analysis of the mutational landscape in HT-SELEX improves aptamer discovery. *Nucleic Acids Res* 43(12):5699–5707. https://doi.org/10.1093/nar/gkv308

## License

AptaSuite is licensed GPL-3.0 by its authors. `install.sh` downloads it from their official release; this repo does not redistribute it. The scripts in this repo are Apache-2.0 (`LICENSE`).
