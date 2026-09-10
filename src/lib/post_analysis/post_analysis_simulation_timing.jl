# Simulation timing comparison: the "typical" clearForDays-derived auction range (as used in
# compare_laura_cases_with_first_period_lock.yaml, with no explicit cap) vs. the validation runs'
# explicit lastAuctionMTU cap (validate_laura_rolling_36.yaml, which stops 12 auctions short of
# what clearForDays alone would allow, to match Laura's exact comparable_delivery_hours_override -
# the fixed validation config behaves identically, so it's left out here). Also plots each config's
# test_range - the samplePeriodExcludeSpinUp/samplePeriodExcludeEnd-derived analysis window used
# for post-hoc plotting/reporting (clear_market.jl) - which is a genuinely separate bound from the
# auction range itself and, for the validation config, extends past where auctions actually stop
# (the same executed-vs-full-export mismatch this session spent a long time on).
#
# Reads the live config files and recomputes the same longest_market_window/last_mtu_simulation/
# last_mtu_full/test_range bounds ClearSimple/ClearMarketComparisonForConfig use internally
# (clear_market.jl), so the chart stays accurate as those configs change - it does not hardcode any
# MTU numbers. The x-axis is real calendar dates, derived from each config's own startDate.

module PostAnalysisSimulationTiming

using Plots, Dates

include("../data_importer.jl")

results_path_base = "results/analysis"

function CleanDirectory(path)
	mkpath(path)
end

# mirrors the last_mtu_full/longest_market_window/last_mtu_simulation/test_range computation in
# ClearSimple/ClearMarketComparisonForConfig (clear_market.jl) - kept in sync by hand, since this
# module only reads config metadata and never calls into clear_market.jl itself
function SimulationTimingFor(config_path)
	config = DataImporter.load_input_data(config_path)

	market_sequences = haskey(config, :marketSequences) ? values(config[:marketSequences]) : [config[:marketSequence]]
	longest_market_window = maximum(m[:optimizationWindow] + m[:lookAheadDistance] for ms in market_sequences for m in ms)

	last_mtu_full = config[:clearForDays] * config[:timePeriodsPerDay]
	natural_last_mtu = last_mtu_full - longest_market_window
	last_mtu_simulation = config[:lastAuctionMTU] !== nothing ? min(natural_last_mtu, config[:lastAuctionMTU]) : natural_last_mtu

	# test_range: the samplePeriodExcludeSpinUp/samplePeriodExcludeEnd-derived analysis window
	# (both expressed in days), matching clear_market.jl's own test_range = range(...) exactly -
	# this is independent of skipEarlyAuctions/lastAuctionMTU, and can fall outside the auction
	# range entirely (e.g. samplePeriodExcludeEnd: 0 doesn't know about lastAuctionMTU, so the
	# validation config's test_range reaches well past its actual last auction)
	test_range_start = config[:timePeriodsPerDay] * config[:samplePeriodExcludeSpinUp]
	test_range_stop = config[:timePeriodsPerDay] * (config[:clearForDays] - config[:samplePeriodExcludeEnd]) - 1

	# the two ranges post_analysis_laura_kpis.jl actually analyzes: "executed hours" is the h=1
	# leg of every auction (skip_early_auctions:last_mtu_simulation - identical to the auctions-run
	# span itself, e.g. her hardcoded time_range = 12:672), while "all traded hours" additionally
	# covers the speculative look-ahead tail of the LAST auction's own window (matching her Gross
	# Traded Volume / Total Financial Revenue sections, which sum every leg of every clearing's
	# full optimizationWindow+lookAheadDistance, not just the executed one)
	executed_hours_stop = last_mtu_simulation
	all_traded_hours_stop = last_mtu_simulation + longest_market_window - 1

	return (
		name = config[:name],
		start_date = config[:startDate],
		time_periods_per_day = config[:timePeriodsPerDay],
		skip_early_auctions = config[:skipEarlyAuctions],
		last_mtu_full = last_mtu_full,
		longest_market_window = longest_market_window,
		natural_last_mtu = natural_last_mtu,
		last_auction_mtu = config[:lastAuctionMTU],
		last_mtu_simulation = last_mtu_simulation,
		num_auctions = last_mtu_simulation - config[:skipEarlyAuctions] + 1,
		test_range_start = test_range_start,
		test_range_stop = test_range_stop,
		executed_hours_stop = executed_hours_stop,
		all_traded_hours_stop = all_traded_hours_stop,
	)
end

# converts an MTU offset (relative to a row's own startDate/time_periods_per_day) into fractional
# days since a shared reference date - the common numeric x-coordinate every row's geometry uses,
# so rows with different startDates land on a true shared calendar timeline
function mtu_to_x(t, mtu, reference_date)
	minutes_per_mtu = 24*60 / t.time_periods_per_day
	dt = DateTime(t.start_date) + Dates.Minute(round(Int, minutes_per_mtu * mtu))
	return Dates.value(dt - DateTime(reference_date)) / (1000*60*60*24)
end

# draws one filled horizontal segment [x0, x1] on row y as a rectangle of the given height
function hbar!(p, x0, x1, y, height, color; label="")
	x0 >= x1 && return
	Plots.plot!(p, Shape([x0, x1, x1, x0], [y - height/2, y - height/2, y + height/2, y + height/2]);
		color=color, linecolor=color, label=label)
end

# draws a bracket (horizontal line + end ticks) representing test_range beneath row y
function test_range_bracket!(p, x0, x1, y, color; label="")
	Plots.plot!(p, [x0, x1], [y, y]; color=color, linewidth=2, label=label)
	tick = 0.08
	Plots.plot!(p, [x0, x0], [y - tick, y + tick]; color=color, linewidth=2, label="")
	Plots.plot!(p, [x1, x1], [y - tick, y + tick]; color=color, linewidth=2, label="")
end

function PlotSimulationTiming(rows)
	n = length(rows)
	height = 0.6
	reference_date = minimum(r.timing.start_date for r in rows)
	max_x = maximum(mtu_to_x(r.timing, r.timing.last_mtu_full, reference_date) for r in rows)
	min_x = minimum(mtu_to_x(r.timing, 0, reference_date) for r in rows)

	color_notauctioned = RGB(0.60, 0.60, 0.60) # before skipEarlyAuctions - never auctioned at all
	color_auction = RGB(0.16, 0.47, 0.84)      # actual auctions that run
	color_lookahead = RGB(0.95, 0.80, 0.45)    # not auctioned after the last actual auction (reserved for look-ahead, or trimmed by lastAuctionMTU)
	color_testrange = RGB(0.45, 0.20, 0.60)    # samplePeriodExcludeSpinUp/End analysis window
	color_executed = RGB(0.75, 0.15, 0.45)     # executed hours (h=1) - the KPI validation's time_range
	color_alltraded = RGB(0.05, 0.55, 0.55)    # all traded hours - executed hours plus the last auction's look-ahead tail

	p = Plots.plot(
		size=(1300, 320 + 90*n),
		xlims=(min_x - (max_x-min_x)*0.02, max_x + (max_x-min_x)*0.02),
		ylims=(0.1, n + 0.7),
		yticks=(1:n, reverse([r.label for r in rows])),
		xlabel="Date",
		legend=:outerbottom,
		legendcolumns=2,
		title="Simulation and Data Analysis Timeline",
		titlefontsize=12,
		left_margin=32Plots.mm,
		top_margin=4Plots.mm,
		bottom_margin=18Plots.mm,
		grid=:x,
	)

	# x ticks for every single day across the full displayed date span, labelled with real dates
	tick_dates = Date(reference_date) + Dates.Day(floor(Int, min_x)) : Dates.Day(1) : Date(reference_date) + Dates.Day(ceil(Int, max_x))
	xticks_pos = [Dates.value(DateTime(d) - DateTime(reference_date)) / (1000*60*60*24) for d in tick_dates]
	xticks_lbl = [Dates.format(d, "u dd") for d in tick_dates]
	Plots.plot!(p, xticks=(xticks_pos, xticks_lbl), xrotation=90, xtickfontsize=6)

	# only the FIRST row that actually draws a given segment kind gets its legend label - segments
	# that don't appear in every row (e.g. "trimmed by lastAuctionMTU") would silently vanish from
	# the legend if labeled strictly by row index instead
	labeled = Dict{String,Bool}()
	function legend_label(key)
		get(labeled, key, false) && return ""
		labeled[key] = true
		return key
	end

	for (i, r) in enumerate(rows)
		y = n - i + 1 # first row on top
		t = r.timing
		x(mtu) = mtu_to_x(t, mtu, reference_date)

		hbar!(p, x(0), x(t.skip_early_auctions), y, height, color_notauctioned; label = legend_label("not auctioned (before skipEarlyAuctions)"))
		hbar!(p, x(t.skip_early_auctions), x(t.last_mtu_simulation), y, height, color_auction; label = legend_label("auctions run"))
		# only the span actually reached by some run auction's own look-ahead window - not the
		# full structural buffer up to last_mtu_full, which (when lastAuctionMTU trims the run
		# short of natural_last_mtu) includes MTUs nothing ever touches at all
		hbar!(p, x(t.last_mtu_simulation), x(t.all_traded_hours_stop + 1), y, height, color_lookahead; label = legend_label("reserved for look-ahead"))

		if r.range_mode == :executed_vs_traded
			test_range_bracket!(p, x(t.skip_early_auctions), x(t.executed_hours_stop), y - height/2 - 0.16, color_executed;
				label = legend_label("executed hours"))
			test_range_bracket!(p, x(t.skip_early_auctions), x(t.all_traded_hours_stop), y - height/2 - 0.32, color_alltraded;
				label = legend_label("all traded hours"))
		else
			test_range_bracket!(p, x(t.test_range_start), x(t.test_range_stop), y - height/2 - 0.16, color_testrange;
				label = legend_label("test range (samplePeriodExcludeSpinUp/End)"))
		end

		Plots.annotate!(p, (x(t.skip_early_auctions) + x(t.last_mtu_simulation))/2, y, Plots.text("$(t.num_auctions) auctions", 9, :white, :center))
	end

	return p
end

function PerformAnalysis()
	CleanDirectory(results_path_base)

	typical = SimulationTimingFor("src/configs/experiments/compare_laura_cases_with_first_period_lock.yaml")
	validation_rolling = SimulationTimingFor("src/configs/experiments/validate_laura_rolling_36.yaml")

	println(typical)
	println(validation_rolling)

	rows = [
		(label = "Previous Case 1", timing = typical, range_mode = :samplePeriod),
		(label = "Validation", timing = validation_rolling, range_mode = :executed_vs_traded),
	]

	p = PlotSimulationTiming(rows)
	savefig(p, "$results_path_base/simulation_timing_comparison.png")
	println("saved: $results_path_base/simulation_timing_comparison.png")

	return p
end

end;
