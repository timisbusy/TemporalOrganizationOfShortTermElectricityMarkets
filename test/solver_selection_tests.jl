using Test

# guard against re-including (and thereby redefining) ClearMarket - see two_stage_model_tests.jl
if !isdefined(Main, :ClearMarket)
	include("../src/lib/market_clearers/clear_market.jl")
end

# Loading ClearMarket must not create a Gurobi environment (that needs a license) - it is created on the
# first Gurobi solve. The tests here only check what is true with or without a license.
@testset "SolverSelection" begin
	S = ClearMarket.SolverSelection

	@test S.solver(Dict{Symbol,Any}()) == "highs"
	@test S.solver_method(Dict{Symbol,Any}()) == "simplex"
	@test S.solver(Dict{Symbol,Any}(:optimizationModelConfig => Dict("solver" => "Gurobi"))) == "gurobi"
	@test S.solver_method(Dict{Symbol,Any}(:optimizationModelConfig => Dict("solver" => "highs"))) == "simplex"
	@test S.solver_method(Dict{Symbol,Any}(:optimizationModelConfig => Dict("solver_method" => "IPM"))) == "ipm"

	@test S.select_optimizer(Dict{Symbol,Any}()) === S.HiGHS.Optimizer

	# building the Gurobi factory does not start Gurobi - only calling it does (an earlier test file may already have)
	env_before = S._gurobi_env[]
	S.select_optimizer("gurobi")
	@test S._gurobi_env[] === env_before
	@test_throws String S.select_optimizer("cplex")
end
