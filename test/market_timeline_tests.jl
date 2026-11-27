include("../src/lib/figures/market_timeline.jl")

# a market configuration file with the given markets: (name, clearingInterval, optimizationWindow, lookAheadDistance, clockTimeBegin)
function write_market_config(dir, name, markets; override=false)
	path = joinpath(dir, "$name.yaml")
	open(path, "w") do io
		println(io, "timePeriodsPerDay: 24")
		override && println(io, "overrideMTU1Restriction: true")
		println(io, "marketSequence:")
		for (market, interval, window, look_ahead, clock) in markets
			println(io, "  $market:\n    clearingInterval: $interval\n    optimizationWindow: $window\n    lookAheadDistance: $look_ahead\n    clockTimeBegin: $clock")
		end
	end
	return path
end

@testset "MarketTimeline" begin
	dir = mktempdir()
	I, A, B = MarketTimeline.INITIAL, MarketTimeline.ADJUSTMENT, MarketTimeline.BALANCING

	@testset "rolling auctions: one new MTU each, the first MTU locked after the first auction" begin
		(; markets) = MarketTimeline.LoadMarkets(write_market_config(dir, "rolling", [("Rolling", 1, 4, 0, 0)]))
		auctions = MarketTimeline.ClassifyAuctions(markets, 0:3)

		@test [a.clearing_mtu for a in auctions] == [0, 1, 2, 3]
		@test auctions[1].window == 0:3
		@test auctions[1].kinds == [I, I, I, I] # nothing is dispatched before the first auction, so no lock either
		@test auctions[2].window == 1:4
		@test auctions[2].kinds == [B, A, A, I]
		@test auctions[4].window == 3:6
		@test auctions[4].kinds == [B, A, A, I]
	end

	@testset "no lock without restrict_mtu1_trading, or when the market configuration overrides it" begin
		(; markets) = MarketTimeline.LoadMarkets(write_market_config(dir, "rolling_free", [("Rolling", 1, 4, 0, 0)]))
		@test MarketTimeline.ClassifyAuctions(markets, 0:1; restrict_mtu1_trading=false)[2].kinds == [A, A, A, I]

		(; markets) = MarketTimeline.LoadMarkets(write_market_config(dir, "rolling_override", [("Rolling", 1, 4, 0, 0)]; override=true))
		@test MarketTimeline.ClassifyAuctions(markets, 0:1)[2].kinds == [A, A, A, I]
	end

	@testset "fixed auctions: new MTUs only in the auction that first reaches them" begin
		(; markets) = MarketTimeline.LoadMarkets(write_market_config(dir, "fixed", [("Fixed", 4, 6, 0, 0)]))
		auctions = MarketTimeline.ClassifyAuctions(markets, 0:8)

		@test [a.clearing_mtu for a in auctions] == [0, 4, 8]
		@test auctions[1].kinds == fill(I, 6)
		@test auctions[2].window == 4:9
		@test auctions[2].kinds == [B, A, I, I, I, I] # MTUs 4 and 5 were in the first auction, 6 to 9 are new
		@test auctions[3].window == 8:13
		@test auctions[3].kinds == [B, A, I, I, I, I] # the second auction reached MTUs 8 and 9, 10 to 13 are new
	end

	@testset "auctions skipped by skip_early_auctions are not held, and the first one held is exempt from the lock" begin
		(; markets) = MarketTimeline.LoadMarkets(write_market_config(dir, "rolling_skip", [("Rolling", 1, 4, 0, 0)]))
		auctions = MarketTimeline.ClassifyAuctions(markets, 0:3; skip_early_auctions=2)

		@test [a.clearing_mtu for a in auctions] == [2, 3]
		@test auctions[1].kinds == [I, I, I, I]
		@test auctions[2].kinds == [B, A, A, I]
	end

	@testset "a lock with a look-ahead distance fails loudly" begin
		(; markets) = MarketTimeline.LoadMarkets(write_market_config(dir, "lookahead", [("Rolling", 1, 4, 2, 0)]))

		@test_throws ErrorException MarketTimeline.ClassifyAuctions(markets, 0:2)
		@test length(MarketTimeline.ClassifyAuctions(markets, 0:2; restrict_mtu1_trading=false)) == 3
	end

	@testset "several markets at the same MTU are ordered and labelled by name" begin
		(; markets) = MarketTimeline.LoadMarkets(write_market_config(dir, "two_markets", [("A", 4, 4, 0, 0), ("B", 4, 4, 0, 0)]))
		auctions = MarketTimeline.ClassifyAuctions(markets, 0:0)

		@test length(auctions) == 2
		@test sort([a.market for a in auctions]) == ["A", "B"]
		@test sort(MarketTimeline.RowLabels(auctions)) == ["0 · A", "0 · B"]
	end

	@testset "Plot draws the figure and saves it" begin
		path = write_market_config(dir, "rolling_plot", [("Rolling", 1, 6, 0, 0)])
		output = joinpath(dir, "figures", "timeline.png")
		p = MarketTimeline.Plot(path; days=1, output_path=output)

		@test isfile(output)
		@test p isa MarketTimeline.Plots.Plot
		@test_throws ErrorException MarketTimeline.Plot("no_such_market_config.yaml"; output_path=nothing)
	end
end
