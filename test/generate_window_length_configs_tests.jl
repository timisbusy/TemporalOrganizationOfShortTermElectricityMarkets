using Test, Dates

include(joinpath(@__DIR__, "..", "src", "lib", "experiments", "generate_window_length_configs.jl"))
using .GenerateWindowLengthConfigs

const SOURCE_CONFIG = """
name: base # old name
clearForDays: 10
# stale comment describing the old clearForDays value
samplePeriodExcludeSpinUp: 3
samplePeriodExcludeEnd: 2
marketConfig: old.yaml
agentConfig: agents.yaml
noiseLevel: 0.1
"""

# value of a top-level `key: value # comment` line
function yaml_value(path, key)
	for l in readlines(path)
		m = match(Regex("^" * key * raw":\s*([^#\s]+)"), l)
		m === nothing || return String(m.captures[1])
	end
	return nothing
end

@testset "GenerateWindowLengthConfigs" begin
	dir = mktempdir()
	src = joinpath(dir, "source.yaml")
	write(src, SOURCE_CONFIG)

	@testset "default designs" begin
		out = joinpath(dir, "default")
		paths = GenerateConfigs(src, "2025-03-10", "2025-03-19"; output_dir=out)

		@test length(paths) == length(DEFAULT_DESIGNS)
		@test all(isfile, paths)
		@test basename.(paths) == ["$(d[1])_20250310_20250319.yaml" for d in DEFAULT_DESIGNS]
	end

	@testset "custom designs replace the defaults" begin
		out = joinpath(dir, "custom")
		designs = [("rolling_24", "rolling_24.yaml", 24), ("fixed_60", "fixed_60.yaml", 60)]
		paths = GenerateConfigs(src, Date(2025, 3, 10), Date(2025, 3, 19);
		                        designs=designs, output_dir=out)

		@test basename.(paths) == ["rolling_24_20250310_20250319.yaml", "fixed_60_20250310_20250319.yaml"]
		@test yaml_value(paths[1], "marketConfig") == "rolling_24.yaml"
		@test yaml_value(paths[2], "marketConfig") == "fixed_60.yaml"
	end

	@testset "derived parameters" begin
		out = joinpath(dir, "derived")
		# 10 analyzed days, spin-up 3 (from source); window 60h -> ceil(60/24) = 3 end days
		paths = GenerateConfigs(src, "2025-03-10", "2025-03-19";
		                        designs=[("w60", "w60.yaml", 60)], output_dir=out)
		p = only(paths)

		@test yaml_value(p, "name") == "w60_20250310_20250319"
		@test yaml_value(p, "startDate") == "2025-03-07"
		@test yaml_value(p, "samplePeriodExcludeEnd") == "3"
		@test yaml_value(p, "clearForDays") == string(10 + 3 + 3)
		@test yaml_value(p, "samplePeriodExcludeSpinUp") == "3"
	end

	@testset "other parameters are kept and stale comments dropped" begin
		out = joinpath(dir, "kept")
		p = only(GenerateConfigs(src, "2025-03-10", "2025-03-19";
		                         designs=[("w36", "w36.yaml", 36)], output_dir=out))
		text = read(p, String)

		@test yaml_value(p, "agentConfig") == "agents.yaml"
		@test yaml_value(p, "noiseLevel") == "0.1"
		@test !occursin("stale comment", text)
		@test !occursin("old.yaml", text)
	end

	@testset "absent keys are appended; spin-up defaults to 2" begin
		bare = joinpath(dir, "bare.yaml")
		write(bare, "agentConfig: agents.yaml\n")
		p = only(GenerateConfigs(bare, "2025-03-10", "2025-03-10";
		                         designs=[("w24", "w24.yaml", 24)], output_dir=joinpath(dir, "bare_out")))

		@test yaml_value(p, "startDate") == "2025-03-08"
		@test yaml_value(p, "clearForDays") == string(1 + 2 + 1)
		@test yaml_value(p, "marketConfig") == "w24.yaml"
	end

	@testset "invalid input" begin
		@test_throws ErrorException GenerateConfigs(src, "2025-03-19", "2025-03-10"; output_dir=joinpath(dir, "x"))
		@test_throws ErrorException GenerateConfigs(src, "2025-03-10", "2025-03-19"; designs=[], output_dir=joinpath(dir, "y"))
	end
end
