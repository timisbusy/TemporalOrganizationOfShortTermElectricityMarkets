module HelperMtuLock

export LockedMTUCount, LockedMTURange

# How many MTUs at the start of a clearing's optimization window are locked (the balancing market of the clearing).
#
# A market states it directly with :lockedMTUs (market config: `lockedMTUs` in yaml, "Locked MTUs" in the MarketSequence
# sheet of the Excel variant): 0 locks nothing, 1 the first MTU, N the first N MTUs. Configurations that predate it
# state the same thing through the experiment's restrict_mtu1_trading flag and the market's :overrideMTU1Restriction,
# which means 1 or 0. Stating both ways at once, and disagreeing, is an error rather than a silent precedence.
function LockedMTUCount(data, market)
	legacy = haskey(data, :optimizationModelConfig) && get(data[:optimizationModelConfig], "restrict_mtu1_trading", false) == true &&
		!get(market, :overrideMTU1Restriction, false) ? 1 : 0

	locked = get(market, :lockedMTUs, nothing)
	if locked === nothing
		count = legacy
	else
		(locked isa Integer && locked >= 0) || error("lockedMTUs of market $(get(market, :name, "?")) must be a non-negative integer, got $(repr(locked))")
		count = Int(locked)
		restricted = haskey(data, :optimizationModelConfig) && get(data[:optimizationModelConfig], "restrict_mtu1_trading", false) == true
		# the legacy flags only conflict if they ask for a lock the market's own count contradicts
		if restricted && !get(market, :overrideMTU1Restriction, false) && count == 0
			error("market $(get(market, :name, "?")) sets lockedMTUs = 0 but the experiment sets restrict_mtu1_trading: true; remove one of them or set overrideMTU1Restriction: true on the market")
		end
	end

	window = get(market, :optimizationWindow, nothing)
	window === nothing || count <= window || error("market $(get(market, :name, "?")) locks $count MTUs but its optimization window is only $window MTUs long")
	return count
end

# The locked MTUs of a clearing whose window starts at `start_at_period`, or nothing if none are locked.
LockedMTURange(count::Integer, start_at_period::Integer) = count > 0 ? (start_at_period:(start_at_period + count - 1)) : nothing

end
