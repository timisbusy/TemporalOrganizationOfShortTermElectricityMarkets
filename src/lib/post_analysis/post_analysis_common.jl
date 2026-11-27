# Shared conventions for the fixed_36/rolling_36 post-analysis suite: the two cases are each a
# separate single-design run directory (produced by ClearSimple/TestExperiment.RunBasic), not a
# single ClearMarketComparisonForConfig run with case-suffixed files - that's the shape the older
# post-analysis modules (pre-dating post_analysis_laura_kpis.jl) were built for, and it's why they
# don't work unmodified against fixed_36/rolling_36 results. "Auction Only" is deliberately absent
# here: it's a third design those older comparison-run configs included, out of scope for this
# fixed_36/rolling_36 pair.

module PostAnalysisCommon

using XLSX, DataFrames, YAML, Dates, Printf, Statistics, CSV
using ZipArchives: ZipReader, ZipWriter, zip_names, zip_readentry, zip_newfile
import Plots

include("../helpers.jl")
using .Helpers.HelperModelResults

include("../output_data/market_data_storage.jl")

include("../data_importer.jl")

const CASES = ["Fixed Horizon", "Rolling Horizon"]

# fixed_36/rolling_36 with lastAuctionMTU removed (clearForDays: 31, so there's room for the
# day-28 price-analysis window - see post_analysis_prices.jl) and a full day of spin-up excluded
# (samplePeriodExcludeSpinUp: 1, not 0 - see DEFAULT_TIME_RANGE below). Exported after
# GetFinalDispatchDecisions started carrying FinalAuctionPrice through, so
# CalculateCaseIndicators' RAW backfill is a no-op for these.
const DEFAULT_CASE_PATHS = Dict{String,String}(
	"Fixed Horizon" => "results/1789572958_fixed_36_no_cap_1d_spinup",
	"Rolling Horizon" => "results/1789572958_rolling_36_no_cap_1d_spinup",
)

const DEFAULT_AGENT_MAP = Dict{HelperModelResults.AgentTypeEnum,Vector{String}}(
	AGENT_GENERATOR => ["3G_Base", "4G_Shoulder", "5G_Peak", "6G_Wind", "7G_Solar"],
	AGENT_DEMAND => ["1D_HighBid", "2D_ModerateBid"],
)

# (variable generator, balancing generator) pair for MarketDataStorage.CounterbalancedImbalance -
# Peak absorbs Wind's forecast-error adjustments in this agent config. Not passed by default (see
# CalculateCaseIndicators) since most callers in this suite don't need imbalance at all.
const DEFAULT_IMBALANCE_AGENTS = ("6G_Wind", "5G_Peak")

# D1-D28 final-auction-MTU window: a clean 28 days, excluding a full day of spin-up at the start and
# the samplePeriodExcludeEnd=2 days of tail clearings at the end (MTU 24*1 to 24*(31-2)-1). This
# used to be 12:672 (D0.5-D28, matching the Laura KPI validation's own comparable_delivery_hours
# range exactly) before samplePeriodExcludeSpinUp moved from 0 to 1 day, so this suite's own
# tables/plots no longer line up 1:1 against post_analysis_laura_kpis.jl's 12:672 window.
const DEFAULT_TIME_RANGE = 24:695

# Analysis modules take `time_range=nothing` and call ResolveTimeRange, which derives the window from
# the runs' own configs (below) - DEFAULT_TIME_RANGE is then only the fallback for runs that have no
# experiment config copy. A module passed an explicit time_range (e.g. post_analysis_laura_kpis.jl's
# 12:672) uses it as given.

# The experiment config copied into a run's Config/ folder, with the window keys sample_time_range reads:
# (path, Dict) for the yaml with a clearForDays key (the market and agent copies beside it have none) or
# the xlsx whose "data" sheet has a "Clear for Days" column. `nothing` if the run has no such copy. Read
# from the run rather than src/configs/ so the window is what the run was actually configured with.
function ExperimentConfig(case_path)
	config_dir = joinpath(case_path, "Config")
	isdir(config_dir) || return nothing
	for f in sort(readdir(config_dir))
		startswith(f, "~\$") && continue # Excel lock file
		path = joinpath(config_dir, f)
		if endswith(f, ".yaml")
			cfg = YAML.load_file(path)
			cfg isa AbstractDict && haskey(cfg, "clearForDays") && return (path, cfg)
		elseif endswith(f, ".xlsx")
			cfg = DataImporter.experiment_window_config_xlsx(path)
			cfg === nothing || return (path, cfg)
		end
	end
	return nothing
end

ExperimentConfigPath(case_path) = (c = ExperimentConfig(case_path); c === nothing ? nothing : first(c))

# A run's copied experiment/market/agent configs from its Config/ folder as the nested Dicts the yamls
# load to - from yaml copies, or from the Excel workbooks an Excel-driven run copies. Each is classified
# by content rather than filename (the names differ per case); `nothing` for any role with no copy.
function LoadCaseConfigsByRole(case_path)
	config_dir = joinpath(case_path, "Config")
	experiment_cfg = market_cfg = agent_cfg = nothing
	for f in sort(readdir(config_dir))
		startswith(f, "~\$") && continue # Excel lock file
		path = joinpath(config_dir, f)
		if endswith(f, ".yaml")
			cfg = YAML.load_file(path)
			cfg isa AbstractDict || continue
			if haskey(cfg, "marketSequence")
				market_cfg = cfg
			elseif haskey(cfg, "variableGenerators") || haskey(cfg, "dispatchableGenerators")
				agent_cfg = cfg
			elseif haskey(cfg, "clearForDays")
				experiment_cfg = cfg
			end
		elseif endswith(f, ".xlsx")
			sheets = XLSX.openxlsx(XLSX.sheetnames, path)
			if "MarketSequence" in sheets
				market_cfg = DataImporter.market_config_raw_xlsx(path)
			elseif "Generators" in sheets
				agent_cfg = DataImporter.load_agent_config_xlsx(path)
			elseif "data" in sheets
				cfg = DataImporter.experiment_window_config_xlsx(path)
				cfg === nothing || (experiment_cfg = cfg)
			end
		end
	end
	return (experiment_cfg, market_cfg, agent_cfg)
end

# MTUs of the clearings exported to a run's RAW/ folder. The final auction for MTU t is clearing t, so
# these are the MTUs that have a final dispatch.
function RawClearingMTUs(case_path)
	mtus = Int[]
	for f in readdir(joinpath(case_path, "RAW"))
		m = match(r"^decisionvariables_.+_(\d+)\.xlsx$", f)
		m === nothing || push!(mtus, parse(Int, m.captures[1]))
	end
	return mtus
end

# One run's analysis window: the samplePeriodExcludeSpinUp/End window from its experiment config
# (DataImporter.sample_time_range, the same one the simulation itself uses), trimmed to the MTUs it
# actually has a final auction for (a run stopped short by lastAuctionMTU has none past that).
# `nothing` if the run has no experiment config copy.
function CaseTimeRange(case_path)
	experiment = ExperimentConfig(case_path)
	experiment === nothing && return nothing
	range = DataImporter.sample_time_range(last(experiment))
	clearings = RawClearingMTUs(case_path)
	isempty(clearings) && return range
	return max(first(range), minimum(clearings)):min(last(range), maximum(clearings))
end

# The window an analysis of these runs should cover. An explicit `time_range` is returned unchanged.
# Otherwise it's each run's CaseTimeRange - and when the runs' ranges differ, their intersection (with
# a warning), since a comparison needs the same MTUs on both sides. Runs with no config copy are
# skipped; if none has one, falls back to DEFAULT_TIME_RANGE. Pass `output_base` to record the
# resolved range in that analysis directory's metadata.yaml.
function ResolveTimeRange(time_range, case_paths, cases=sort(collect(keys(case_paths))); output_base=nothing)
	resolved = time_range === nothing ? TimeRangeFromConfigs(case_paths, cases) : time_range
	output_base === nothing || RecordTimeRange!(output_base, resolved)
	return resolved
end

function TimeRangeFromConfigs(case_paths, cases)
	ranges = Pair{String,UnitRange{Int}}[]
	for case in cases
		haskey(case_paths, case) || continue
		range = CaseTimeRange(case_paths[case])
		if range === nothing
			println("warning: no experiment config found under $(case_paths[case])/Config - not used to derive the analysis time range")
		else
			push!(ranges, case => range)
		end
	end

	if isempty(ranges)
		println("warning: none of the runs has an experiment config copy - falling back to DEFAULT_TIME_RANGE $DEFAULT_TIME_RANGE")
		return DEFAULT_TIME_RANGE
	end

	resolved = maximum(first(r) for (_, r) in ranges):minimum(last(r) for (_, r) in ranges)
	isempty(resolved) && throw("the runs' analysis time ranges do not overlap: $(join(["$case: $r" for (case, r) in ranges], ", "))")
	if length(unique(r for (_, r) in ranges)) > 1
		println("warning: analysis time ranges differ between runs ($(join(["$case: $r" for (case, r) in ranges], ", "))) - using their intersection $resolved")
	end
	println("analysis time range: $resolved (from the runs' experiment configs)")
	return resolved
end

# The delivery-day indices (MTU ÷ mtus_per_day, both ends inclusive) a time_range covers - what the
# day_range-based modules (lead time, storage) filter on, so they cover the same days as everything else.
DayRange(time_range, mtus_per_day=24) = fld(first(time_range), mtus_per_day):fld(last(time_range), mtus_per_day)

# records the MTU window an analysis covered in its directory's metadata.yaml (written by NewAnalysisOutputDir)
function RecordTimeRange!(output_base, time_range)
	path = joinpath(output_base, "metadata.yaml")
	isfile(path) || return
	metadata = YAML.load_file(path)
	metadata["time_range"] = "$(first(time_range)):$(last(time_range))"
	YAML.write_file(path, metadata)
end

function CleanDirectory(path)
	mkpath(path)
end

# --- plot mark: every saved plot says which cluster and storage level it is based on -------------------------
#
# PlotMark(case_paths, cases) -> "Cluster 1 | small storage (6000 MWh / 2000 MW)", derived from the runs' own
# copied configs (Config/ folder): the cluster from the experiment name ("Cluster<N>_..."), the storage from the
# agent config's batteryStorage capacities, and the level from the run's name ("high_storage" in its directory
# or config names -> "large storage", otherwise "small storage"). Cases that disagree list each distinct value
# ("Cluster 1 | small / large storage"); a part that can't be determined (e.g. a run from before the cluster
# naming) is left out.
#
# Every analysis module calls SetPlotMark!(case_paths, cases) first thing in PerformAnalysis and saves its figures
# with SaveFigure(p, path) instead of savefig, which stamps the mark as a small plot_title over the figure. The
# mark lives in this module's own PLOT_MARK, so each analysis module (each includes its own copy of this file)
# sets and uses its own.
const PLOT_MARK = Ref("")

function CaseCluster(case_path)
	experiment = ExperimentConfig(case_path)
	names = String[basename(case_path)]
	experiment === nothing || pushfirst!(names, string(get(last(experiment), "name", "")))
	for name in names
		m = match(r"Cluster[_ ]?(\d+)"i, name)
		m === nothing || return "Cluster $(m.captures[1])"
	end
	return nothing
end

function CaseStorage(case_path)
	hints = [basename(case_path); isdir(joinpath(case_path, "Config")) ? readdir(joinpath(case_path, "Config")) : String[]]
	level = any(h -> occursin("high_storage", h), hints) ? "large storage" : "small storage"
	capacity = ""
	try
		agent_cfg = LoadCaseConfigsByRole(case_path)[3]
		battery = agent_cfg === nothing ? nothing : get(agent_cfg, "batteryStorage", nothing)
		if battery !== nothing
			capacity = " ($(round(Int, battery["energyCapacity"])) MWh / $(round(Int, battery["powerCapacity"])) MW)"
		end
	catch
	end
	return level * capacity
end

# true when the run locked the demand in the balancing segment: "lock_demand" in its directory name, or lockDemand set in
# its copied experiment config
function CaseDemandLocked(case_path)
	occursin("lock_demand", basename(case_path)) && return true
	try
		experiment = ExperimentConfig(case_path)
		return experiment !== nothing && get(last(experiment), "lockDemand", false) == true
	catch
		return false
	end
end

function PlotMark(case_paths, cases=sort(collect(keys(case_paths))))
	clusters = unique(filter(!isnothing, [CaseCluster(case_paths[c]) for c in cases if haskey(case_paths, c)]))
	storages = unique([CaseStorage(case_paths[c]) for c in cases if haskey(case_paths, c)])
	parts = String[]
	isempty(clusters) || push!(parts, join(clusters, " / "))
	isempty(storages) || push!(parts, join(storages, " / "))
	return join(parts, " | ")
end

function SetPlotMark!(case_paths, cases=sort(collect(keys(case_paths))))
	PLOT_MARK[] = try
		PlotMark(case_paths, cases)
	catch err
		println("warning: could not derive the plot mark ($err)")
		""
	end
	return PLOT_MARK[]
end

# savefig plus the plot mark (nothing is stamped when no mark was set or it is empty)
function SaveFigure(p, path)
	if !isempty(PLOT_MARK[])
		Plots.plot!(p; plot_title=PLOT_MARK[], plot_titlefontsize=9, plot_titlefontcolor="#52514e")
	end
	Plots.savefig(p, path)
end

# Merges the listed result workbooks into ONE workbook, output_base/folder/filename, with a "metadata" tab first and,
# when plots are given, a "Plots" tab with the listed PNGs embedded under captions.
#
# files: entries are "path/relative/to/output_base.xlsx" => "label" (or a bare path, labelled by its file name). Every
# sheet of every file is copied; its tab is named by the label alone when the file has one sheet, otherwise
# "label - sheet" (Excel tabs are capped at 31 characters, so longer names are shortened and made unique).
# A file that doesn't exist (analysis not run, or renamed) is skipped with a warning.
#
# plots: entries are "path/relative/to/output_base.png" => "caption". The file name may contain one "*" that matches
# any text (e.g. "generation_stack_energy/generation_stack_energy_*.png"): every match gets its own picture, captioned
# "caption (matched text)" with underscores shown as spaces. A pattern with no match is skipped with a warning.
#
# The metadata tab (columns Item, Value) says what the workbook is about: the cluster, the storage level (with the
# battery capacities) and the cases compared - read from the runs' own Config/ copies, the same way the plot mark is
# (see CaseCluster / CaseStorage) - plus each case's run directory, the analysis window and when the workbook was
# written. The workbook is named after the cluster and storage level (HighLevelFileName, e.g. "cluster_8_large_storage.xlsx")
# unless filename is given. Returns the workbook's path (nothing when no source file was found).
#
# notes (Item => Value pairs) are added to the end of the metadata tab, e.g. "Note" => "run stopped early ...". A
# workbook with plots but no source files (files empty) holds just the metadata and Plots tabs.
function MergeHighLevelResults(output_base, files; case_paths, cases, time_range=nothing, plots=[], folder="high_level_results", filename=HighLevelFileName(case_paths, cases), notes=Pair{String,String}[])
	isempty(files) && isempty(plots) && return nothing
	entries = [f isa Pair ? (String(first(f)), String(last(f))) : (String(f), splitext(basename(String(f)))[1]) for f in files]

	sheets = Pair{String,DataFrame}[]
	used = Set{String}(["metadata", "Plots"])
	found = String[]
	for (rel, label) in entries
		src = joinpath(output_base, rel)
		if !isfile(src)
			@warn "high-level results: $rel not found under $output_base - skipped"
			continue
		end
		push!(found, rel)
		XLSX.openxlsx(src) do book
			names = XLSX.sheetnames(book)
			for sheet in names
				df = DataFrame(XLSX.readtable(src, sheet; infer_eltypes=true))
				push!(sheets, UniqueSheetName(length(names) == 1 ? label : "$label - $sheet", used) => df)
			end
		end
	end
	pictures = ResolvePlots(output_base, plots)
	isempty(found) && isempty(pictures) && return nothing
	plot_sheet, placements = isempty(pictures) ? (nothing, []) : PlotsSheet(pictures)

	dest = "$output_base/$folder"
	mkpath(dest)
	path = "$dest/$filename"
	ordered = Pair{String,DataFrame}["metadata" => MergeMetadata(case_paths, cases, time_range; notes=notes)]
	plot_sheet === nothing || push!(ordered, "Plots" => plot_sheet)
	XLSX.writetable(path, ordered..., sheets...; overwrite=true)
	isempty(placements) || EmbedPictures(path, "Plots", placements)
	return path
end

# [(png path, caption)] for the plot entries: "*" patterns expanded, missing files warned about
function ResolvePlots(output_base, plots)
	pictures = Tuple{String,String}[]
	for entry in plots
		rel, caption = entry isa Pair ? (String(first(entry)), String(last(entry))) : (String(entry), splitext(basename(String(entry)))[1])
		dir, pattern = dirname(rel), basename(rel)
		folder = joinpath(output_base, dir)
		if occursin('*', pattern)
			prefix, suffix = split(pattern, '*'; limit=2)
			matches = isdir(folder) ? sort(filter(f -> startswith(f, prefix) && endswith(f, suffix) && length(f) > length(prefix) + length(suffix) - 1, readdir(folder))) : String[]
			isempty(matches) && @warn "high-level results: no plot matches $rel under $output_base - skipped"
			for f in matches
				middle = replace(f[length(prefix)+1:end-length(suffix)], "_" => " ")
				push!(pictures, (joinpath(folder, f), isempty(middle) ? caption : "$caption ($middle)"))
			end
		elseif isfile(joinpath(folder, pattern))
			push!(pictures, (joinpath(folder, pattern), caption))
		else
			@warn "high-level results: plot $rel not found under $output_base - skipped"
		end
	end
	return pictures
end

const PICTURE_WIDTH_PX = 900     # pictures are scaled to this width in the Plots tab
const ROW_HEIGHT_PX = 20         # Excel's default row height
const MIN_COLUMN_A_CHARS = 60

# pixel size of a PNG, read from its IHDR chunk
function PngSize(path)
	bytes = read(path, 24)
	(length(bytes) == 24 && bytes[1:8] == UInt8[0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]) || throw("$path is not a PNG file")
	be32(i) = Int(bytes[i]) << 24 | Int(bytes[i+1]) << 16 | Int(bytes[i+2]) << 8 | Int(bytes[i+3])
	return be32(17), be32(21)
end

# The "Plots" sheet: one caption row per picture followed by enough empty rows to hold it. Returns the sheet and, per
# picture, (png path, caption, 0-based anchor row, width px, height px) for EmbedPictures.
function PlotsSheet(pictures)
	rows = Union{Missing,String}[]
	placements = Tuple{String,String,Int,Int,Int}[]
	for (png, caption) in pictures
		w, h = PngSize(png)
		scale = PICTURE_WIDTH_PX / w
		width, height = PICTURE_WIDTH_PX, round(Int, h * scale)
		push!(rows, caption)                        # sheet row length(rows) + 1 (row 1 is the header)
		anchor = length(rows) + 1                    # 0-based index of the row right after the caption
		push!(placements, (png, caption, anchor, width, height))
		append!(rows, fill(missing, cld(height, ROW_HEIGHT_PX) + 1))
	end
	return DataFrame(Plots=rows), placements
end

# Adds the pictures to the sheet `sheet_name` of an existing .xlsx by writing the drawing parts into the zip archive:
# xl/media/imageN.png, xl/drawings/drawing1.xml (+ its rels), a <drawing> element and rels entry for the sheet, and the
# content types. XLSX.jl cannot embed images itself.
function EmbedPictures(xlsx_path, sheet_name, placements)
	reader = ZipReader(read(xlsx_path))
	names = zip_names(reader)
	entries = Pair{String,Vector{UInt8}}[name => zip_readentry(reader, name) for name in names]
	get_text(name) = String(copy(last(entries[findfirst(e -> first(e) == name, entries)])))
	set_entry!(name, data) = (i = findfirst(e -> first(e) == name, entries); i === nothing ? push!(entries, name => Vector{UInt8}(data)) : (entries[i] = name => Vector{UInt8}(data)))

	# sheet part of `sheet_name`: workbook.xml names the sheet and its relationship id, workbook.xml.rels maps that id to the part
	workbook = get_text("xl/workbook.xml")
	m = match(Regex("<sheet [^>]*name=\"$(sheet_name)\"[^>]*>"), workbook)
	m === nothing && throw("sheet $sheet_name not found in $xlsx_path")
	rid = match(r"r:id=\"([^\"]+)\"", m.match).captures[1]
	rels = get_text("xl/_rels/workbook.xml.rels")
	relm = match(Regex("<Relationship [^>]*Id=\"$(rid)\"[^>]*>"), rels)
	target = match(r"Target=\"([^\"]+)\"", relm.match).captures[1]
	sheet_part = startswith(target, "/") ? target[2:end] : "xl/" * target
	sheet_rels_part = dirname(sheet_part) * "/_rels/" * basename(sheet_part) * ".rels"

	# the pictures and the drawing that places them
	drawing_xml = IOBuffer()
	drawing_rels = IOBuffer()
	write(drawing_xml, "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n<xdr:wsDr xmlns:xdr=\"http://schemas.openxmlformats.org/drawingml/2006/spreadsheetDrawing\" xmlns:a=\"http://schemas.openxmlformats.org/drawingml/2006/main\" xmlns:r=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships\">")
	write(drawing_rels, "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\">")
	for (i, (png, caption, anchor, width, height)) in enumerate(placements)
		set_entry!("xl/media/image$i.png", read(png))
		cx, cy = width * 9525, height * 9525
		alt = replace(caption, "&" => "&amp;", "<" => "&lt;", ">" => "&gt;", "\"" => "&quot;")
		write(drawing_xml, "<xdr:oneCellAnchor><xdr:from><xdr:col>0</xdr:col><xdr:colOff>0</xdr:colOff><xdr:row>$anchor</xdr:row><xdr:rowOff>0</xdr:rowOff></xdr:from><xdr:ext cx=\"$cx\" cy=\"$cy\"/>" *
			"<xdr:pic><xdr:nvPicPr><xdr:cNvPr id=\"$(i + 1)\" name=\"Picture $i\" descr=\"$alt\"/><xdr:cNvPicPr><a:picLocks noChangeAspect=\"1\"/></xdr:cNvPicPr></xdr:nvPicPr>" *
			"<xdr:blipFill><a:blip r:embed=\"rId$i\"/><a:stretch><a:fillRect/></a:stretch></xdr:blipFill>" *
			"<xdr:spPr><a:xfrm><a:off x=\"0\" y=\"0\"/><a:ext cx=\"$cx\" cy=\"$cy\"/></a:xfrm><a:prstGeom prst=\"rect\"><a:avLst/></a:prstGeom></xdr:spPr></xdr:pic><xdr:clientData/></xdr:oneCellAnchor>")
		write(drawing_rels, "<Relationship Id=\"rId$i\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/image\" Target=\"../media/image$i.png\"/>")
	end
	write(drawing_xml, "</xdr:wsDr>")
	write(drawing_rels, "</Relationships>")
	set_entry!("xl/drawings/drawing1.xml", take!(drawing_xml))
	set_entry!("xl/drawings/_rels/drawing1.xml.rels", take!(drawing_rels))

	# the sheet points at the drawing
	drawing_rid = "rIdPlots1"
	sheet = get_text(sheet_part)
	occursin("xmlns:r=", sheet) || (sheet = replace(sheet, r"<worksheet\b" => "<worksheet xmlns:r=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships\""; count=1))
	element = "<drawing r:id=\"$drawing_rid\"/>"
	insert_before = something(findfirst(r"<tableParts|<extLst|</worksheet>", sheet), nothing)
	insert_before === nothing && throw("unexpected sheet xml in $xlsx_path")
	sheet = sheet[1:first(insert_before)-1] * element * sheet[first(insert_before):end]
	set_entry!(sheet_part, sheet)
	rel = "<Relationship Id=\"$drawing_rid\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/drawing\" Target=\"../drawings/drawing1.xml\"/>"
	if any(e -> first(e) == sheet_rels_part, entries)
		set_entry!(sheet_rels_part, replace(get_text(sheet_rels_part), "</Relationships>" => rel * "</Relationships>"; count=1))
	else
		set_entry!(sheet_rels_part, "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\">$rel</Relationships>")
	end

	# content types: png files and the drawing part
	types = get_text("[Content_Types].xml")
	occursin("Extension=\"png\"", types) || (types = replace(types, r"(<Types\b[^>]*>)" => s"\1<Default Extension=\"png\" ContentType=\"image/png\"/>"; count=1))
	types = replace(types, "</Types>" => "<Override PartName=\"/xl/drawings/drawing1.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.drawing+xml\"/></Types>"; count=1)
	set_entry!("[Content_Types].xml", types)

	buffer = IOBuffer()
	writer = ZipWriter(buffer)
	for (name, data) in entries
		zip_newfile(writer, name; compress=true)
		write(writer, data)
	end
	close(writer)
	write(xlsx_path, take!(buffer))
	return xlsx_path
end

# an Excel tab name: at most 31 characters, none of []:*?/\ , and not used before in this workbook
function UniqueSheetName(name, used)
	clean = replace(name, r"[\[\]:*?/\\]" => "-")
	candidate = first(clean, 31)
	n = 2
	while candidate in used
		suffix = " ($n)"
		candidate = first(clean, 31 - length(suffix)) * suffix
		n += 1
	end
	push!(used, candidate)
	return candidate
end

# "cluster_8_large_storage": the workbook's name, from the cluster and storage level of the cases (a part that cannot be
# determined is left out; "high_level_results" when neither can; several distinct values are joined with "_and_")
function HighLevelFileName(case_paths, cases)
	present = [c for c in cases if haskey(case_paths, c)]
	clusters = unique(filter(!isnothing, [CaseCluster(case_paths[c]) for c in present]))
	levels = unique([first(split(CaseStorage(case_paths[c]), " (")) for c in present])
	slug(x) = lowercase(replace(x, r"\s+" => "_"))
	parts = String[]
	isempty(clusters) || push!(parts, join(slug.(clusters), "_and_"))
	isempty(levels) || push!(parts, join(slug.(levels), "_and_"))
	any(c -> CaseDemandLocked(case_paths[c]), present) && push!(parts, "demand_locked")
	return (isempty(parts) ? "high_level_results" : join(parts, "_")) * ".xlsx"
end

function MergeMetadata(case_paths, cases, time_range; notes=Pair{String,String}[])
	clusters = unique(filter(!isnothing, [CaseCluster(case_paths[c]) for c in cases if haskey(case_paths, c)]))
	storages = unique([CaseStorage(case_paths[c]) for c in cases if haskey(case_paths, c)])
	storage_levels = unique([first(split(s, " (")) for s in storages])
	rows = Pair{String,String}[
		"Cluster" => isempty(clusters) ? "unknown" : join(clusters, " / "),
		"Storage level" => join(storage_levels, " / "),
		"Storage capacity" => join(unique([occursin("(", s) ? strip(last(split(s, " (")), ')') : "unknown" for s in storages]), " / "),
		"Demand lock" => join(unique([CaseDemandLocked(case_paths[c]) ? "locked in the balancing segment" : "not locked" for c in cases if haskey(case_paths, c)]), " / "),
		"Cases compared" => join(cases, " vs "),
	]
	for c in cases
		haskey(case_paths, c) && push!(rows, "Run: $c" => String(case_paths[c]))
	end
	time_range === nothing || push!(rows, "Analysis window (MTU)" => "$(first(time_range)):$(last(time_range))")
	append!(rows, [String(first(n)) => String(last(n)) for n in notes])
	push!(rows, "Written" => string(Dates.now()))
	return DataFrame(Item=first.(rows), Value=last.(rows))
end

# case name -> trailing directory name, own leading "{unix_timestamp}_" stripped (it's already
# redundant with NewAnalysisOutputDir's own timestamp prefix, and every extra character here
# tightens the margin against Windows' 260-char MAX_PATH once a deeply-nested output file name is
# built on top of it), in `cases` order, joined - e.g. "fresh_validate_fixed_36_vs_fresh_validate_rolling_36"
# `cases` defaults to CASES (Fixed/Rolling) rather than always iterating case_paths' own keys -
# passing a 3+ case case_paths without also passing the matching `cases` order here would otherwise
# silently drop the extra case from the label instead of erroring, producing a directory name
# indistinguishable from a 2-case run's.
function DefaultAnalysisLabel(case_paths, cases=CASES)
	names = [replace(basename(case_paths[c]), r"^\d+_" => "") for c in cases if haskey(case_paths, c)]
	return join(names, "_vs_")
end

# Windows caps a full path at 260 characters (MAX_PATH) unless long-path support has been
# explicitly opted into system-wide, which this repo doesn't rely on. The deepest relative path any
# post-analysis module currently writes under an output_base is
# post_analysis_quantities_by_agent/agent_gross_traded_volume_details.xlsx (~73 chars); this margin
# reserves comfortably more than that so future filenames have room to grow without silently
# reviving this problem.
const WINDOWS_MAX_PATH = 260
const OUTPUT_SUBPATH_MARGIN = 85

# Truncates `label` (at a "_" boundary where possible, for readability) if
# "$base_dir/$timestamp_prefix$label" plus OUTPUT_SUBPATH_MARGIN would exceed WINDOWS_MAX_PATH -
# a label built from long case_paths basenames (e.g. a "large storage" run pair) would otherwise
# only fail once some later module tries to write a file under it, deep inside XLSX.writetable with
# an opaque "No such file or directory". The full, untruncated label is still recorded in
# metadata.yaml for provenance.
function TruncateLabelForPath(label, base_dir, timestamp_prefix)
	budget = WINDOWS_MAX_PATH - length(abspath(base_dir)) - 1 - length(timestamp_prefix) - OUTPUT_SUBPATH_MARGIN
	length(label) <= budget && return label
	budget = max(budget, 10)
	cut = findlast('_', label[1:min(end, budget)])
	truncated = label[1:(cut === nothing ? budget : cut - 1)]
	println("warning: analysis label truncated to fit Windows MAX_PATH: \"$label\" -> \"$truncated\"")
	return truncated
end

# Gives each PostAnalysisRunner.Run call (or a standalone submodule PerformAnalysis) its own
# permanent, never-overwritten output directory under results/post_analysis/, the same
# {timestamp}_{name} convention TestExperiment.RunBasic uses for simulation runs - the suite used
# to always write into one fixed, silently-overwritten location regardless of which case_paths
# were actually analyzed. Also drops a metadata.yaml recording what was analyzed, the same
# provenance role ClearMarket.CopyConfigFiles! plays for a simulation run's own Config/ copy.
function NewAnalysisOutputDir(case_paths; label=DefaultAnalysisLabel(case_paths))
	base_dir = "results/post_analysis"
	timestamp_prefix = "$(round(Int, datetime2unix(now())))_"
	label = TruncateLabelForPath(label, base_dir, timestamp_prefix)
	dir = "$base_dir/$timestamp_prefix$label"
	mkpath(dir)
	YAML.write_file(joinpath(dir, "metadata.yaml"), Dict(
		"label" => label,
		"generated_at" => string(now()),
		"case_paths" => case_paths,
	))
	return dir
end

# Per-clearing RAW decision-variable exports are named "decisionvariables_<experiment
# name>_<mtu>.xlsx" - the experiment name is whatever the run's own config[:name] was, not
# derivable from the run directory's own (possibly unrelated) name, so discover it by reading one
# filename out of the case's RAW/ directory instead of requiring every caller to know/hardcode it.
function DiscoverRawDispatchPrefix(case_path)
	raw_dir = joinpath(case_path, "RAW")
	for f in readdir(raw_dir)
		m = match(r"^decisionvariables_(.+)_(\d+)\.xlsx$", f)
		m === nothing && continue
		return joinpath(raw_dir, "decisionvariables_$(m.captures[1])_")
	end
	throw("no decisionvariables_*.xlsx files found in $raw_dir")
end

function DiscoverRawDispatchPrefixes(case_paths)
	return Dict(case => DiscoverRawDispatchPrefix(path) for (case, path) in case_paths)
end

# latexify passes column headers and string cell values straight through unescaped - a bare "%"
# starts a LaTeX comment, silently truncating that line (and anything after it in the table). Call
# this on the copy of a DataFrame that's about to be handed to latexify() for a .tex export - it
# escapes "%" -> "\%" in every column name and every String-typed column's values. Not needed for
# xlsx output, which wants the plain "%".
function EscapeForLatex(df)
	escaped = rename(df, [name => replace(name, "%" => "\\%") for name in names(df)])
	for col in names(escaped)
		if eltype(escaped[!, col]) <: AbstractString
			escaped[!, col] = replace.(escaped[!, col], "%" => "\\%")
		end
	end
	return escaped
end

# Some tables in this suite latexify with a single table-wide integer fmt (e.g. "%'d", thousands-
# separated - suits big €/€-per-day totals) that would truncate a smaller-magnitude intensive
# indicator row (a €/MWh price, say) to a bare integer, since Latexify's PrintfNumberFormatter
# applies the same fmt to every Number cell with no per-row override (latextabular.jl:
# `x isa Number ? formatter(x) : x`). Since a non-Number cell passes through untouched, this
# pre-formats just the named row's case-value cells as "%.2f" strings on a copy - never the
# original df - sidestepping the shared fmt for that row without touching any other row's display.
function FormatIndicatorRowForLatex(df, indicator, case_columns)
	out = copy(df)
	row_idx = findfirst(==(indicator), out.Indicator)
	row_idx === nothing && return out
	for col in case_columns
		out[!, col] = Vector{Any}(out[!, col])
		out[row_idx, col] = Printf.@sprintf("%.2f", df[row_idx, col])
	end
	return out
end

# FormatIndicatorRowForLatex for several indicator rows at once, folding the copy-and-reformat over
# each in turn.
function FormatIndicatorRowsForLatex(df, indicators, case_columns)
	out = df
	for indicator in indicators
		out = FormatIndicatorRowForLatex(out, indicator, case_columns)
	end
	return out
end

# Rounds the named row's case-value cells to `digits` places, in place - for a daily-average
# indicator whose raw division rarely lands on a clean number (e.g. Imbalance Energy (MWh)/days).
# Complements FormatIndicatorRowForLatex, which only fixes the LaTeX-only truncation problem for a
# row like this; this actually changes the stored value, so console/xlsx output round the same way.
function RoundIndicatorRow!(df, indicator, case_columns; digits=2)
	row_idx = findfirst(==(indicator), df.Indicator)
	row_idx === nothing && return df
	for col in case_columns
		df[row_idx, col] = round(df[row_idx, col]; digits=digits)
	end
	return df
end

const PERCENT_FORMAT = Ref(Printf.Format("%0.3f%%"))

# "rolling vs fixed" percent-difference string, formatted like "12.345%" - or "—" when fixed is
# zero, since dividing by it gives NaN/Inf rather than a meaningful percentage (Printf happily
# renders those as the literal strings "NaN%"/"Inf%", which is worse than just saying there's no
# ratio to report).
function PercentDiffString(rolling, fixed)
	fixed == 0 && return "—"
	return Printf.format(PERCENT_FORMAT[], 100*(rolling - fixed)/fixed)
end

# filesystem/filename-safe case name - shared so this doesn't drift into slightly different local
# copies across modules (post_analysis_auction_snapshots.jl and post_analysis_prices.jl each used
# to define their own before this).
CaseSlug(case) = lowercase(replace(case, " " => "_"))

function LoadFile(filepath)
	return DataFrame(XLSX.readtable(filepath, "data"))
end

function LoadCaseFile(case_paths, case, filename)
	path = joinpath(case_paths[case], filename)
	# a transaction table too large for one Excel sheet is exported as {name}.csv instead of
	# {name}.xlsx (see PlotBaselineOutcomes.write_transactions) - fall back to that when the .xlsx
	# isn't there
	csv_path = splitext(path)[1] * ".csv"
	if !isfile(path) && endswith(filename, ".xlsx") && isfile(csv_path)
		return DataFrame(CSV.File(csv_path))
	end
	return LoadFile(path)
end

# shared by PostAnalysisSEW and PostAnalysisWindowLengthKPIs so their two copies can't drift apart
# the way PostAnalysisConventionalGenerationCost/PriceByHour's own case_paths defaults once did.
const MEAN_FINAL_AUCTION_PRICE_INDICATOR = "Mean Final Auction Price (€/MWh)"

# Mean Final Auction Price (€/MWh) over time_range for one case - rounded to the hundredths place,
# since it's a price meant to read like one, not a many-significant-figure aggregate like the
# totals it's usually reported alongside.
function LoadMeanFinalAuctionPrice(case_path, time_range)
	dd = LoadFile(joinpath(case_path, "final_dispatch_decisions.xlsx"))
	dd = dd[time_range.start .<= dd.mtu .<= time_range.stop, :]
	return round(mean(dd.FinalAuctionPrice); digits=2)
end

const WIND_CURTAILED_INDICATOR = "Wind Curtailed (MWh)"

# Wind Curtailment over time_range for one case, matching Laura's "Total Wind Curtailed (MWh)"
# (see post_analysis_laura_kpis.jl): Q_6G_Wind is the model's available-capacity time series for
# wind (m.ext[:timeseries][:Q_gen], exported via helper_model_results.jl's "Q_$agent" column - NOT
# the dispatched quantity), so Q_6G_Wind - 6G_Wind is exactly how much available wind went
# undispatched each MTU. `final_dispatch_decisions` should already be scoped to time_range (e.g.
# CalculateCaseIndicators' own return value) so this is just the sum, not a re-filter.
function WindCurtailed(final_dispatch_decisions)
	return sum(final_dispatch_decisions[!, Symbol("Q_6G_Wind")] .- final_dispatch_decisions[!, Symbol("6G_Wind")])
end

# Fresh per-case economic/agent indicators, computed directly from each case's own
# final_dispatch_decisions.xlsx + transactions.xlsx via MarketDataStorage.CalculateEconomicIndicators
# - there is no pre-aggregated multi-case economic_indicators.xlsx/agent_indicators.xlsx with a
# "Market Configuration" column to filter here (that shape only exists for
# ClearMarketComparisonForConfig runs), so each case's indicators are computed on demand instead.
# The storage SOC a run's analysis range opens with, as recorded in its opening_soc.yaml (the exported dispatch
# decisions are trimmed to the range, so they no longer hold it). `kind` is "total" or "energy", matching the
# dispatch table the indicators are computed from. `nothing` for a run that predates the file - the storage's
# SOC change is then reported as missing.
function LoadOpeningSOC(case_path, kind)
	path = joinpath(case_path, "opening_soc.yaml")
	isfile(path) || return nothing
	return get(YAML.load_file(path), kind, nothing)
end

function CalculateCaseIndicators(case_paths, case; agent_map=DEFAULT_AGENT_MAP, time_range=nothing, raw_dispatch_prefix=nothing, imbalance_agents::Union{Nothing,Tuple{String,String}}=nothing)
	# nothing: this case's own window from its experiment config (see ResolveTimeRange); the analysis
	# modules always pass their already-resolved range
	time_range = ResolveTimeRange(time_range, case_paths, [case])
	final_dispatch_decisions = LoadCaseFile(case_paths, case, "final_dispatch_decisions.xlsx")
	transactions = LoadCaseFile(case_paths, case, "transactions.xlsx")
	# older exports predate GetFinalDispatchDecisions carrying FinalAuctionPrice through - backfill
	# it from each MTU's own per-clearing RAW export in that case, discovering the prefix from the
	# RAW/ directory itself unless the caller supplied one. A fresh run's export already has the
	# column, so this (and the discovery) is skipped entirely for those.
	if !hasproperty(final_dispatch_decisions, :FinalAuctionPrice)
		prefix = raw_dispatch_prefix === nothing ? DiscoverRawDispatchPrefix(case_paths[case]) : raw_dispatch_prefix[case]
		MarketDataStorage.AddFinalAuctionPriceFromRAW!(final_dispatch_decisions, prefix)
	end
	return MarketDataStorage.CalculateEconomicIndicators(final_dispatch_decisions, transactions, agent_map, time_range; imbalance_agents=imbalance_agents, opening_soc=LoadOpeningSOC(case_paths[case], "total"))
end

# Same as CalculateCaseIndicators but for the energy markets only (see balancing_energy_split.jl): the
# energy-only final dispatch decisions (final_dispatch_decisions_energy.xlsx: per MTU, the last clearing that
# traded it as an energy MTU) and the Segment == "Energy" transactions. Returns the same named tuple, so
# callers can swap one for the other. Runs made before the balancing/energy split lack those inputs and throw.
const SEGMENT_COLUMN = "Segment"
const ENERGY_SEGMENT = "Energy"
function CalculateCaseEnergyIndicators(case_paths, case; agent_map=DEFAULT_AGENT_MAP, time_range=nothing, imbalance_agents::Union{Nothing,Tuple{String,String}}=nothing)
	time_range = ResolveTimeRange(time_range, case_paths, [case])
	transactions = LoadCaseFile(case_paths, case, "transactions.xlsx")
	hasproperty(transactions, SEGMENT_COLUMN) || throw("transactions of case \"$case\" have no \"$SEGMENT_COLUMN\" column - this run predates the balancing/energy split; rerun it")
	energy_transactions = transactions[transactions[!, SEGMENT_COLUMN] .== ENERGY_SEGMENT, :]
	isfile(joinpath(case_paths[case], "final_dispatch_decisions_energy.xlsx")) || throw("case \"$case\" has no final_dispatch_decisions_energy.xlsx - this run predates the balancing/energy split; rerun it")
	energy_final_dispatch_decisions = LoadCaseFile(case_paths, case, "final_dispatch_decisions_energy.xlsx")
	return MarketDataStorage.CalculateEconomicIndicators(energy_final_dispatch_decisions, energy_transactions, agent_map, time_range; imbalance_agents=imbalance_agents, opening_soc=LoadOpeningSOC(case_paths[case], "energy"))
end

# Mean FinalAuctionPrice over time_range of the energy-only final dispatch decisions
function LoadMeanEnergyFinalAuctionPrice(case_path, time_range)
	dd = LoadFile(joinpath(case_path, "final_dispatch_decisions_energy.xlsx"))
	dd = dd[time_range.start .<= dd.mtu .<= time_range.stop, :]
	return round(mean(dd.FinalAuctionPrice); digits=2)
end

end;
