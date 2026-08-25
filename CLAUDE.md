# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A Julia/JuMP simulation platform that models sequential short-term electricity market clearing (e.g. day-ahead, rolling intraday) to study how the *temporal organization* of these markets (clearing frequency, optimization window, look-ahead distance) affects dispatch efficiency, prices, and storage/generator behavior. Experiments are driven by YAML (or, partially, Excel) configuration files and run interactively from Jupyter notebooks.

## Setup

```
julia
]
activate .
instantiate
```
Then run JupyterLab from the repo root and open `UseExcelInput.ipynb` or `TemporalOrganizationExperiments.ipynb`.

`Project.toml` declares `YAML`, `XLSX`, `Gurobi`, and `MathOptInterface` as direct deps (needed by `data_importer.jl`, `clear_market.jl`, and `src/lib/models/latest_model.jl` respectively), so a plain `instantiate` is sufficient. Note `Gurobi` requires a working Gurobi license to actually solve — `HiGHS` is also declared as a license-free alternative solver, but `latest_model.jl` hardcodes `USE_GUROBI = true` at module scope, so switching solvers currently means editing that constant.

## Running an experiment

From a Julia session/notebook at the repo root:
```julia
include("src/lib/experiments/test_experiment.jl")
TestExperiment.RunBasic("experiment_name", "src/configs/xlsx/experiments/OneIntraday.xlsx")  # or a .yaml path
```
Output location is printed at the end: `results/{unix_timestamp}_{experiment_name}/`.

Other entry points in `TestExperiment` (`src/lib/experiments/test_experiment.jl`):
- `RunBasic(name, config_file)` — single market design.
- `RunComparisonExperiment(name, config_file)` — config with `compare: market`, runs multiple market designs side by side (see `ClearMarket.ClearMarketComparison`).
- `RunComparisonExperimentWithErrors(name, config_file, error_indexes)` — comparison run repeated per wind-forecast-error scenario index, output nested under `results/stochastic_test_{timestamp}/`.
- `RunSweepRampRatesTest(...)` — sweeps dispatchable generator ramp rates across a range.

## Tests

```
julia --project=test test/runtests.jl
```
`test/` has its own `Project.toml`/`Manifest.toml` (separate environment from the root package). Coverage is currently thin — mostly `market_data_storage_tests.jl` (exercises `Helpers.HelperModelResults` / `MarketDataStorage`).

## Architecture

The simulation is a **time-stepped loop over market clearings**, not a single optimization:

1. **Config loading** (`src/lib/data_importer.jl`, module `DataImporter`) — merges an experiment config (temporal parameters, `clearForDays`, `noiseLevel`) with a referenced **market configuration** (`src/configs/markets/*.yaml`, defines a `marketSequence` of named markets each with `clearingInterval`, `optimizationWindow`, `lookAheadDistance`, `clockTimeBegin`) and an **agent configuration** (`src/configs/agents/*.yaml`, defines `dispatchableGenerators`, `variableGenerators`, `batteryStorage`, `demand.segments`). Excel-based configs (`src/configs/xlsx/`) mirror this but are not feature-complete (no market comparison support). All quantities are expressed in MTU (market time unit), the granularity set by `timePeriodsPerDay`.

2. **Market scheduling** (`src/lib/market_clearers/market_sequence.jl`, module `MarketSequence`) — for each MTU in the simulated horizon, determines which market(s) are scheduled to clear (`clockTimeBegin` + `clearingInterval` modulo arithmetic). This is what makes "fixed day-ahead" vs "rolling intraday" vs a combination of both just different config data rather than different code paths.

3. **Market clearing loop** (`src/lib/market_clearers/clear_market.jl`, module `ClearMarket`) — the orchestrator. `ClearSimple` (single market design) / `ClearMarketComparisonForConfig` (multiple market designs run against the same agent config, for comparison) iterate MTU by MTU, and for each scheduled market: build a JuMP optimization model for that market's window, `optimize!`, then store results and write per-clearing `decisionvariables_*.xlsx` / `transactions_*.xlsx` to `results/{test_id}/RAW/`. `GetModel(config)` selects which optimization model module to build with, based on `optimizationModelConfig.model` in the experiment config (falls back to a set of module-level `USE_*` booleans).

4. **Optimization models** (`src/lib/models/*.jl`) — each is a self-contained JuMP model builder following the same 4-step pattern (`define_sets!` → `process_time_series_data!` → `process_parameters!` → `build_market_clearing!`, then `build(...)` wires them together). `latest_model.jl` (`LatestMarketModel`) is the active/current model — it welfare-maximizes over generators, demand segments, and a centrally-operated battery, with explicit "adjustment" variables (`Qg_adj`, `Qd_adj`) representing the delta from previously-dispatched quantities so that later markets in a sequence can revise earlier commitments, plus generator ramp-rate constraints relative to the prior MTU's dispatch and storage SOC continuity carried across clearings via `MarketDataStorage`. The other files under `models/` (`explicit_adjustment_model.jl`, `flexible_model.jl`, `laura_convergence_model.jl`, `laura_minimum_match_model.jl`, `simple_model.jl`) are earlier/alternate formulations kept for comparison and reproducibility of past experiments — check `GetModel` / the experiment's `optimizationModelConfig` to see which one a given run actually uses.

5. **Result storage** (`src/lib/output_data/market_data_storage.jl`, module `MarketDataStorage`) — accumulates one `MarketResult` (decision variables + derived transactions DataFrame) per market clearing into a `MarketResultContainer`, with caching for fast lookups (e.g. "what was previously dispatched for generator X at MTU t" — used by later clearings to compute adjustments and enforce ramp limits across the rolling horizon).

6. **Post-processing**: `src/lib/plots/market_results/*.jl` generate comparison plots (generation stack, price dispersion, imbalance/retrading impacts) written into `results/{test_id}/`; `src/lib/post_analysis/post_analysis_runner.jl` (`PostAnalysisRunner.Run`) runs a suite of post-hoc analyses (lead time, quantities by agent, socioeconomic welfare, storage, prices, daily aggregates) over a completed results directory. `src/lib/plots/archive/` holds superseded plotting code (git-ignored).

### Config resolution conventions
- Market/agent config filenames referenced from an experiment YAML are resolved relative to `src/configs/markets/` and `src/configs/agents/` respectively (`DataImporter.CONFIG_PATH`), not relative to the experiment file's own location.
- A market config's `timePeriodsPerDay` must match the experiment's, or `load_market_configuration` throws — this is meant to catch MTU-granularity mismatches between an experiment and the market design it's paired with.
- The valid simulation range in `ClearSimple`/`ClearMarketComparisonForConfig` is `0` to `clearForDays*timePeriodsPerDay - longest_market_window` (a market's `optimizationWindow + lookAheadDistance`), since a market clearing needs full data for its whole look-ahead window.
- `samplePeriodExcludeSpinUp`/`samplePeriodExcludeEnd` (default 2 days each) trim the analyzed/plotted window so results reflect a "warmed up" system, not startup transients or an under-covered tail.

### Data flow for variable generation / demand profiles
`addTimeseriesProfiles!` in `clear_market.jl` resolves each variable generator's/demand segment's `profile` from either an inline `profile`, a `profile_file`/`profile_type` pair, or (for demand) a `quantity_constant`, via `HelperInputData.GetProfileFromFile[s]` (`src/lib/helpers/helper_input_data.jl`) — profile files are currently assumed to be in the NED.nl (ned.nl) download format. Wind generation additionally gets synthetic forecast error/noise injected per-MTU via `HelperInputData.add_wind_forecast_noise!`, using precomputed error scenarios loaded/cached from `input_data/laura/wind_forecast_error_shared_final_20260502.csv` (or `config[:wind_noise_scenario_path]` override) — this is how `noiseLevel` in the experiment config translates into dispatch uncertainty across successive market clearings.

### Naming note
Numbered/dated result directories at the repo root (e.g. `1785953177_compare_lld_match_no_end_soc_cnst_pen/`, `stochastic_test_1783681085/`) are output from prior experiment runs (unix-timestamp-prefixed, per the `results/{timestamp}_{name}` convention), not source code — treat them as data, not something to refactor.
