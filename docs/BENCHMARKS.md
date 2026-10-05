# Benchmarks

> Historical upstream FluidAudio measurements. For this Core AI fork, see [COREAI.md](COREAI.md).

How Pladder's speed is measured, and the baseline to compare against. The
benchmark is run by hand before and after any change on the release-to-paste
path (see [CLAUDE.md](../CLAUDE.md)). It is not part of the test suite: a
benchmark that fails on noise gets ignored. For why the numbers look the way
they do, see [PERFORMANCE.md](PERFORMANCE.md).

## What is measured

- **Engine time and realtime factor** per fixture: wall clock around
  `engine.transcribe`, the same call the coordinator makes. Realtime factor is
  audio length divided by engine time, so 30x means a minute of speech in two
  seconds.
- **Word error rate** per fixture against the known script, so a change that
  is faster but worse is caught. Case and punctuation are ignored; only the
  words count. The calculation lives in the `PladderBench` target, which
  only the CLI links; the app carries nothing benchmark-related.
- **Model load time** (cold start, one measurement per process, the time the
  app spends before the hotkey is enabled) and **physical memory footprint**
  after load, the number Activity Monitor shows.
- **Release-to-paste time** per dictation, in the app, between the
  `recordingStopped` and `inserted` coordinator events. Logged, not
  benchmarked: it is the number the user feels and includes capture stop,
  engine, processors and paste. See the end of this file for how to read it.

## Fixtures

`scripts/make-fixtures.sh` synthesises speech with the macOS `say` command
(voice Samantha, 175 words per minute) from a fixed script of plain prose, at
six lengths, as 16 kHz mono Float32 WAV with the spoken text beside each file.
They are generated on demand into `bench/fixtures` (gitignored) and never
committed, so there is no personal audio in the repo and anyone can regenerate
them.

| Fixture | Target | Why |
|---|---|---|
| 10s | 10 s | One encoder pass. FluidAudio's encoder window is 15 s. |
| 30s | 30 s | Chunked path: 15 s windows with 2 s overlap, up to four decoded concurrently. |
| 60s | 60 s | Chunked path. |
| 2m | 2 min | A long dictation. |
| 5m | 5 min | A very long dictation. |
| 10m | 10 min | The app's recording cap. Heats the chip, so it runs last. |

30 s through 10 min show whether engine time grows linearly with chunk count
and whether accuracy degrades at chunk seams, which FluidAudio's own notes
flag for the v3 multilingual model. The concurrency is FluidAudio's default
and the same one the app uses, so the realtime factor rises with length: a
single window runs alone, long audio keeps four workers busy.

Synthetic speech is cleaner than a real microphone, so the word error rate is
a regression check, not an accuracy claim. Each fixture is a whole number of
sentences, so actual lengths differ from the targets by a few percent; the
benchmark reports the actual length.

## Procedure

1. Close other heavy work and check that `uptime` shows a low load average.
   Numbers jitter with thermal state and other load.
2. Generate the fixtures once: `./scripts/make-fixtures.sh`
3. Run: `swift run -c release pladder-cli bench bench/fixtures`. It takes
   about seven minutes; leave the machine alone while it runs.
4. Runs never overlap, and every run is preceded by ten seconds of idle so
   it starts from the same state a real dictation does, rather than with
   warm clocks and residual heat from the previous run. `--pause` changes
   the idle time; `--pause 0` gives back-to-back runs, which are faster but
   flatter the numbers.
5. Six runs per fixture. The first, which pays CoreML's first-call warm-up,
   is discarded and the median of the remaining five is reported, with the
   spread of those five (largest minus smallest, relative to the median) as
   the noise floor for that fixture. Fixtures run shortest to longest. When
   a result lands near the noise line and you need to know, `--runs 11`
   keeps ten and takes about twelve minutes.
6. The tool prints the one-minute load average at start and end and tags
   any run during which the chip left its normal thermal state. A run with
   a thermal tag or a load average well above one is not comparable.
7. A difference under roughly ten percent is noise. If a change lands near
   that line, run again.

Baselines from other machines are not comparable to the one below. Add a
separate table with chip, macOS version and model version.

### The paced bench, for engines that transcribe while speaking

`--paced` replaces the whole-buffer call with the live one: each fixture is
pushed in one-second chunks paced at real time, as the coordinator's feed
task delivers them, and only `endUtterance` is timed. That is the part left
on the release-to-paste path.

```sh
swift run -c release pladder-cli bench bench/fixtures --paced --runs 2 --pause 2
```

Pacing takes as long as the audio, so fixtures under 13 s are skipped: below
one encoder window there is only one window either way, so nothing is paced
about the result. `--all` keeps them.

Every fixture also goes through the same engine once with the whole buffer,
after the same idle pause and timed the same way, and the two raw texts are
compared before any processor runs. The line reads `identical: yes`, or
`identical: no` with the first differing word and its index. That line is a
gate, not a metric: transcribing while speaking runs the same windows the
whole-buffer path would have run, so anything but `yes` is a bug.

### `--live`, for the Live Transcript overlay

The Live Transcript style asks the engine what it has heard so far every half
second while the key is held, in place of the warm pass the other styles make
every two seconds. `--paced --live` models exactly that: a second task calls
`livePass()` on the same cadence while the fixture is paced in, and is
cancelled just before the release, as the coordinator's feed loop is.

```sh
swift run -c release pladder-cli bench bench/fixtures --paced --live --runs 2 --pause 2
```

Two things come out of it. The run line and two extra table columns report how
many live passes a fixture took and what the median pass cost, which is the
duty cycle the style puts on the Neural Engine. And the `identical:` line now
covers the live passes too: they transcribe a copy of the audio and never
touch the session, so the windows the release merges must come out the same as
without them. Run it beside a plain `--paced` run and compare the
`endUtterance` medians: the difference is what a release that lands next to a
live pass costs.

## Baseline

Reference machine: Apple M1, 16 GB, macOS 26.6.2 (25G83), FluidAudio 0.15.6,
model `parakeet-tdt-0.6b-v3` (CoreML). Recorded 2026-09-11 with `--runs 11`,
ten kept runs per fixture. The M1 is the least powerful chip Pladder
supports: if it is fast enough here, it is fast enough everywhere.

| Measurement | Value |
|---|---:|
| Model load, fresh process | 0.26 s (0.18 to 0.32 s across five runs) |
| Physical footprint after load | 98 MB |

The load time is with CoreML's compiled-model cache warm. The very first load
after the download, or after a macOS update invalidates the cache, compiles
the models and takes far longer; that is a one-time cost and not what this
number tracks. The weights run on the Neural Engine and are held outside the
process, so the footprint understates total memory use.

| Fixture | Audio | Engine (median) | Spread | Realtime | WER |
|---|---:|---:|---:|---:|---:|
| 10s | 9.7 s | 0.237 s | 20 % | 41x | 0.0 % |
| 30s | 31.8 s | 0.399 s | 11 % | 80x | 0.0 % |
| 60s | 60.8 s | 0.563 s | 29 % | 108x | 1.4 % |
| 2m | 125.1 s | 0.908 s | 11 % | 138x | 0.9 % |
| 5m | 315.6 s | 1.976 s | 6 % | 160x | 0.6 % |
| 10m | 631.4 s | 3.704 s | 3 % | 170x | 0.6 % |

Ten seconds of idle before every run; load average 1.6 at the start and 3.3
at the end from other processes on the machine; no thermal tags.

How to read the spread: it is the full range of the kept runs, so it grows
with the run count and is set by the outliers. Eight of the ten 60 s runs
sit between 0.547 and 0.573 s; the other two, at 0.645 and 0.712 s, landed
while the load average was climbing. The medians are the stable part. A
six-run pass under the same procedure gave 0.252, 0.398, 0.558, 0.915,
1.963 and 3.698 s: within six percent of this table on the 10 s fixture and
within one percent everywhere else. Compare medians; use the spread to judge
whether the machine was quiet enough for the comparison to mean anything.

Engine time grows close to linearly with audio length; the realtime factor
rises because the fixed cost per call is amortised and long audio keeps four
workers busy.

Two earlier passes without the idle pause gave 0.150 and 0.152 s for the
10 s fixture, 0.34 to 0.36 s for 30 s and 0.50 s for 60 s, with the long
fixtures unchanged. Back-to-back runs inherit warm clocks from the previous
run, which flatters short audio by about 0.1 s. A dictation never gets that,
so those numbers are not the baseline; the pause exists to keep it that way.

The 60 s fixture's errors are two
mishearings, "flowers" heard as "flours" and "rye loaf" merged into one word.
The sentence with "flowers" is transcribed correctly in the 30 s fixture,
where it does not sit near a window boundary, which is the kind of seam
effect the longer fixtures exist to expose.

## Reading the app's release-to-paste log

Every dictation logs one line with the total release-to-paste time, its
per-stage breakdown and the audio length:

```sh
/usr/bin/log show --last 1h --style compact --predicate 'subsystem == "de.dinooo13.pladder"'
```

The line looks like:

```
release-to-paste 0.312 s: stop 0.012, engine 0.250, process 0.003, paste 0.014; audio 4.2 s
```

A polished dictation logs its own line, with the model
call as a fifth stage and the model it ran on:

```
polished release-to-paste 1.912 s: stop 0.012, engine 0.250, process 0.003, polish 1.620 (appleIntelligence), paste 0.014; audio 6.1 s
```

`polish` is the model call; it exists only for dictations run with the
experimental polish toggle on, and the plain line is unchanged for everything else. It is
`0.000` when the transcript was under four words and the model was skipped.
The prompt's own cost and output are measured with
`swift run -c release pladder-cli polish <text file> [--model …]`, which runs
it cold and warm, and a model as a whole with the polish set below.

## Polish models

`docs/polish-set.json` holds 42 dictations, 14 each in English, German and
Spanish, with the text that should be pasted: self-corrections, spoken
punctuation, number words, both kinds of spoken list, a question and a
request that must not be answered, clean text that must come back
unchanged, code identifiers, repeats, an email and a longer passage. The
inputs are hand-written in the shape Parakeet produces, with fillers left
in; real dictation mostly arrives with numbers already as digits.

```sh
swift run -c release pladder-cli polish-set docs/polish-set.json --model apple|s1-mini|s1-mini-8bit
```

runs the app's processors over each input, then the model, warm, and prints
every answer, the word error rate against the expected text (case and
punctuation ignored), how many answers match exactly (everything counts) and
the polish time. Greedy decoding throughout, so a rerun gives the same
answers.

M1 MacBook Air, 16 GB, macOS 27.0, September 2026:

| Model | Word error (en / de / es) | Exact of 42 | Polish median | p90 |
|---|---|---|---|---|
| Apple Intelligence (macOS 27) | 0.108 (0.037 / 0.152 / 0.135) | 18 | 1.66 s | 2.07 s |
| S1-mini, full precision (f16, 1.5 GB) | 0.071 (0.021 / 0.115 / 0.078) | 22 | 0.49 s | 0.86 s |
| S1-mini, 8-bit (Q8_0, 805 MB) | 0.091 (0.008 / 0.115 / 0.149) | 21 | 0.34 s | 0.61 s |

What the numbers do not show: Apple's model translated two dictations into
English (a German question, a Spanish self-correction), changed "halb acht"
to "8:00", and wrote no list as separate lines. S1-mini, trained on English
only, translated nothing and resolved the German and Spanish
self-corrections, but ignores "Nächster Punkt" and "Siguiente punto" as list
cues and mangled one German sentence around a code identifier. Its load, at
the first key-down after launch or a model switch, is well under a second
from a warm disk and happens while the user speaks.

A German fine-tune of S1-mini, `Joni000000000/s1-mini-de-v3` (Q4_K_M, 397 MB,
trained on real Parakeet German output), was judged with
`polish-set --gguf <file> --control <line>` and not added:

| Control line styling | Word error (en / de / es) | Exact of 42 | Polish median |
|---|---|---|---|
| semi-formal (the app's) | 0.106 (0.033 / 0.132 / 0.153) | 19 | 0.25 s |
| semi-casual | 0.108 (0.033 / 0.139 / 0.153) | 19 | 0.25 s |
| casual | 0.096 (0.009 / 0.130 / 0.149) | 21 | 0.25 s |

In German it turned "Nächster Punkt" enumerations into lines (keeping the cue
words), wrote "3. März" and placed the comma after "Ich glaube", where
S1-mini did not; but it left "für vier, Entschuldigung, fünf Personen"
unresolved, dropped a code identifier, and fused "Build taggen". Part of its
higher error is its own convention of keeping small counts as words. Its
English and Spanish answers were the same as S1-mini 8-bit's in 23 of 28
cases despite its card calling it German only. It is 4-bit only; a 14-case
German slice is too small to overrule its author's 69 probes either way.

LFM2.5-1.2B-Instruct and Gemma 3 1B, run with Pladder's own prompt, were
tried and dropped: the first described or answered the transcript instead
of cleaning it, the second mostly returned it untouched. MLX 4-bit S1-mini
was faster still but lost German and Spanish.

## Processors

The processors run on every dictation, so their cost is measured on the
fixtures' text through the whole pipeline (filler remover with the app's
language hint, dictionary, custom words, whitespace, spoken punctuation),
median of 31 runs, M1. "Typical" has a filler in every sentence; "worst" adds
a spoken question mark to every sentence.

| Fixture | main, typical | spoken punctuation, typical | main, worst | spoken punctuation, worst |
|---|---|---|---|---|
| 10s | 1.53 ms | 1.97 ms | 1.51 ms | 1.62 ms |
| 60s | 1.71 ms | 1.81 ms | 1.73 ms | 2.04 ms |
| 2m | 1.96 ms | 2.14 ms | 2.00 ms | 2.61 ms |
| 10m | 3.77 ms | 4.83 ms | 4.13 ms | 6.85 ms |

The floor of about 1.5 ms is the language recogniser the filler remover asks
whenever an ambiguous filler is present. Differences under a millisecond at
10 s are noise.

What each stage contains:

- `stop` is `AudioCapture.stop()`: removing the tap and collecting the
  captured samples.
- `engine` is `TranscriptionEngine.transcribe`.
- `process` is the processor pipeline run.
- `paste` is `TextOutput.insert`.

The remainder of the total after these four stages is actor scheduling: the
coordinator resumes on the main actor between stages. If the remainder grows,
something new is contending with the main actor.

The engine's own `processingTime` is logged beside the stages as
`engine-time`; a large gap between `engine` and `engine-time` means the engine
actor was busy with something else.

A `keyboard bounce observed` line in the `hotkey` category means the keyboard
reported a held key as released and pressed again, and every release since
then has waited 50 ms before `recordingStopped`. That wait is felt but is not
in the `release-to-paste` number. A latched recording's release-to-paste runs
from the closing press.

A `clipboard read 0.008 s after Cmd+V` line in the `paste` category follows
each paste: when the target app read the transcript, measured from Cmd+V, so it
comes on top of `release-to-paste`, which ends when Cmd+V is posted. The transcript is
served from Pladder's main thread, so a value well above the usual few
milliseconds in an app that normally reads fast means that thread was busy.
`clipboard not read within 8 s of Cmd+V; restoring` means nothing read it:
the paste went somewhere that takes no text.
