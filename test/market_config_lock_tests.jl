using Test, DataFrames, XLSX

if !isdefined(Main, :DataImporter)
	include(joinpath(@__DIR__, "..", "src", "lib", "data_importer.jl"))
end

@testset "lockedMTUs in market configurations" begin
	dir = mktempdir()
	sequence(m) = Dict(x[:name] => x for x in m)

	@testset "yaml: per market, file-level default, absent" begin
		path = joinpath(dir, "market.yaml")
		write(path, """
		timePeriodsPerDay: 24
		lockedMTUs: 2
		marketSequence:
		  a: {clearingInterval: 24, optimizationWindow: 36, lookAheadDistance: 0, clockTimeBegin: 0}
		  b: {clearingInterval: 1, optimizationWindow: 12, lookAheadDistance: 0, clockTimeBegin: 0, lockedMTUs: 0}
		""")
		markets = sequence(DataImporter.load_market_configuration(path, 24))
		@test markets["a"][:lockedMTUs] == 2
		@test markets["b"][:lockedMTUs] == 0

		write(path, """
		timePeriodsPerDay: 24
		marketSequence:
		  a: {clearingInterval: 1, optimizationWindow: 12, lookAheadDistance: 0, clockTimeBegin: 0}
		""")
		@test !haskey(sequence(DataImporter.load_market_configuration(path, 24))["a"], :lockedMTUs)

		write(path, """
		timePeriodsPerDay: 24
		marketSequence:
		  a: {clearingInterval: 1, optimizationWindow: 12, lookAheadDistance: 0, clockTimeBegin: 0, lockedMTUs: -1}
		""")
		@test_throws ErrorException DataImporter.load_market_configuration(path, 24)
		write(path, """
		timePeriodsPerDay: 24
		marketSequence:
		  a: {clearingInterval: 1, optimizationWindow: 12, lookAheadDistance: 0, clockTimeBegin: 0, lockedMTUs: 1.5}
		""")
		@test_throws ErrorException DataImporter.load_market_configuration(path, 24)
	end

	@testset "xlsx: Locked MTUs column, blank means unstated" begin
		path = joinpath(dir, "market.xlsx")
		sheets = ["Validation" => DataFrame("MTU Per Day" => [24]),
			"MarketSequence" => DataFrame("Market Name" => ["a", "b"], "Clearing Interval" => [24, 1], "Optimization Window" => [36, 12],
				"Look Ahead Distance" => [0, 0], "Clock Time Begin" => [0, 0], "Locked MTUs" => [3, missing])]
		XLSX.writetable(path, sheets; overwrite=true)
		markets = sequence(DataImporter.load_market_configuration_xlsx(path, 24))
		@test markets["a"][:lockedMTUs] == 3
		@test !haskey(markets["b"], :lockedMTUs)

		XLSX.writetable(path, ["Validation" => DataFrame("MTU Per Day" => [24]),
			"MarketSequence" => DataFrame("Market Name" => ["a"], "Clearing Interval" => [1], "Optimization Window" => [12],
				"Look Ahead Distance" => [0], "Clock Time Begin" => [0], "Locked MTUs" => [-2])]; overwrite=true)
		@test_throws ErrorException DataImporter.load_market_configuration_xlsx(path, 24)
	end
end
