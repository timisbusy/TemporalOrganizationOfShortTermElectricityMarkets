using Test, DataFrames, XLSX

include(joinpath(@__DIR__, "..", "src", "lib", "data_importer.jl"))

# an Excel experiment workbook whose "data" sheet holds the given columns
function write_experiment_xlsx(dir, name; columns...)
	path = joinpath(dir, "$name.xlsx")
	XLSX.writetable(path, "data" => DataFrame(; Name=["x"], columns...); overwrite=true)
	return path
end

@testset "DataImporter Excel experiments" begin
	dir = mktempdir()

	@testset "market comparison is rejected, with a message that says so" begin
		path = write_experiment_xlsx(dir, "compare_market"; Compare=["market"])
		err = try DataImporter.load_input_data(path); nothing catch e e end

		@test err isa ErrorException
		@test occursin("do not support market comparison", err.msg)
		@test occursin(path, err.msg)
	end

	@testset "a blank or other Compare value is not treated as market comparison" begin
		for compare in (missing, "agents")
			path = write_experiment_xlsx(dir, "compare_$(ismissing(compare) ? "blank" : compare)"; Compare=[compare])
			# the rest of this minimal workbook is incomplete, so loading fails later - but not on the comparison check
			err = try DataImporter.load_input_data(path); nothing catch e e end

			@test err !== nothing
			@test !occursin("market comparison", sprint(showerror, err))
		end
	end
end
