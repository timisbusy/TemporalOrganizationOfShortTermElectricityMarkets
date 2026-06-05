include("../lib/data_importer.jl")



function print_import()
	input_config = DataImporter.load_input_data("../configs/xlsx/experiments/OneIntraday.xlsx")
	println(input_config)

	println("done")
end


function print_import2()
	input_config = DataImporter.load_input_data("../configs/experiments/one_intraday.yaml")
	println(input_config)

	println("done")
end


print_import()
print_import2()