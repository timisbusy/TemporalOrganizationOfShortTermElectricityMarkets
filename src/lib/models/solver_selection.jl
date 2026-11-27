module SolverSelection

using HiGHS
using Gurobi

# What a config gets when it does not set optimizationModelConfig.solver / solver_method. HiGHS is license-free,
# so an experiment only needs a Gurobi license if it asks for Gurobi.
const DEFAULT_SOLVER = "highs"
const DEFAULT_SOLVER_METHOD = "simplex"

# Loading the Gurobi package needs no license; creating a Gurobi.Env() does. So the env is created on the first
# Gurobi solve rather than when this file is included, and every Gurobi model in the process then shares it.
# The lock matters for DegeneracyScan's parallel workers, which can reach the first Gurobi solve concurrently.
const _gurobi_env = Ref{Union{Nothing,Gurobi.Env}}(nothing)
const _gurobi_env_lock = ReentrantLock()

function gurobi_env()
    lock(_gurobi_env_lock) do
        if _gurobi_env[] === nothing
            try
                _gurobi_env[] = Gurobi.Env()
            catch e
                error("optimizationModelConfig.solver is \"gurobi\" but Gurobi could not be started - is a valid Gurobi license available? Set solver to \"highs\" to run without one. Gurobi reported: ", sprint(showerror, e))
            end
        end
        return _gurobi_env[]
    end
end

# solver / solver_method are chosen via data[:optimizationModelConfig]["solver"] / ["solver_method"], defaulting to the constants above
solver(data) = haskey(data, :optimizationModelConfig) && haskey(data[:optimizationModelConfig], "solver") ? lowercase(String(data[:optimizationModelConfig]["solver"])) : DEFAULT_SOLVER
solver_method(data) = haskey(data, :optimizationModelConfig) && haskey(data[:optimizationModelConfig], "solver_method") ? lowercase(String(data[:optimizationModelConfig]["solver_method"])) : DEFAULT_SOLVER_METHOD

function select_optimizer(solver::AbstractString)
    if solver == "gurobi"
        return () -> Gurobi.Optimizer(gurobi_env())
    elseif solver == "highs"
        return HiGHS.Optimizer
    else
        throw("unknown solver \"$solver\" in optimizationModelConfig - supported solvers are \"gurobi\" and \"highs\"")
    end
end

select_optimizer(data::AbstractDict) = select_optimizer(solver(data))

end;
