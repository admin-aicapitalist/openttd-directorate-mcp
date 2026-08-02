function D4_IsTable(value) {
	return typeof value == "table";
}

function D4_IsArray(value) {
	return typeof value == "array";
}

function D4_Has(value, key) {
	return D4_IsTable(value) && key in value;
}

function D4_ClampInt(value, fallback_value, min_value, max_value) {
	if (typeof value != "integer") return fallback_value;
	if (value < min_value) return min_value;
	if (value > max_value) return max_value;
	return value;
}

function D4_StringOr(value, fallback_value, max_len) {
	if (typeof value != "string") return fallback_value;
	if (value.len() > max_len) return value.slice(0, max_len);
	return value;
}

function D4_Tick() {
	return GSController.GetTick();
}

function D4_Error(code, detail) {
	local d = "";
	if (detail != null) d = D4_StringOr(detail.tostring(), "", DIRECTORATE_M4_MAX_ERROR_LEN);
	return { code = code, detail = d };
}

function D4_StableFingerprint(company_id, intent, policy) {
	return D4_BoundedFingerprint({ company_id = company_id, intent = intent, policy = policy });
}

function D4_BoundedFingerprint(value) {
	local stable = D4_StableString(value);
	local hash1 = 17;
	local hash2 = 29;
	for (local i = 0; i < stable.len(); i++) {
		local ch = stable[i];
		hash1 = (hash1 * 131 + ch) % 2147483629;
		hash2 = (hash2 * 137 + ch) % 2147483587;
	}
	return "d4h1:" + stable.len() + ":" + hash1 + ":" + hash2;
}

function D4_StableString(value) {
	local t = typeof value;
	if (value == null) return "null";
	if (t == "integer" || t == "float" || t == "bool") return value.tostring();
	if (t == "string") return "\"" + value + "\"";
	if (t == "array") {
		local out = "[";
		for (local i = 0; i < value.len() && i < 128; i++) {
			if (i > 0) out += ",";
			out += D4_StableString(value[i]);
		}
		return out + "]";
	}
	if (t == "table") {
		local keys = [];
		foreach (k, v in value) keys.append(k.tostring());
		keys.sort();
		local out = "{";
		for (local i = 0; i < keys.len() && i < 128; i++) {
			if (i > 0) out += ",";
			local k = keys[i];
			out += k + ":" + D4_StableString(value[k]);
		}
		return out + "}";
	}
	return t;
}

function D4_IsBoundedSaveValue(value, depth = 0) {
	if (depth > 8) return false;
	if (value == null) return true;
	local t = typeof value;
	if (t == "integer" || t == "float" || t == "bool") return true;
	if (t == "string") return value.len() <= 254;
	if (t == "array") {
		if (value.len() > DIRECTORATE_M4_MAX_OPERATION_ENTRIES) return false;
		foreach (child in value) if (!D4_IsBoundedSaveValue(child, depth + 1)) return false;
		return true;
	}
	if (t == "table") {
		local count = 0;
		foreach (key, child in value) {
			count++;
			if (count > 128 || typeof key != "string" || key.len() > 64 || !D4_IsBoundedSaveValue(child, depth + 1)) return false;
		}
		return true;
	}
	return false;
}

function D4_NewUUID() {
	local chars = "0123456789abcdef";
	local out = "";
	for (local i = 0; i < 16; i++) {
		local n = GSBase.Rand() % 16;
		out += chars.slice(n, n + 1);
	}
	return out;
}

function D4_ContainsForbiddenPlanningInput(value, depth) {
	if (depth > 12) return false;
	if (D4_IsArray(value)) {
		for (local i = 0; i < value.len() && i < 128; i++) {
			if (D4_ContainsForbiddenPlanningInput(value[i], depth + 1)) return true;
		}
		return false;
	}
	if (!D4_IsTable(value)) return false;
	foreach (k, child in value) {
		local key = k.tostring();
		if (key == "tile" || key == "tiles" || key == "tile_list" || key == "tileList" || key == "path" || key == "waypoints" || key == "route_tiles") return true;
		if (D4_ContainsForbiddenPlanningInput(child, depth + 1)) return true;
	}
	return false;
}

function D4_TileOwnerMatchesOrUnowned(tile, company_id) {
	if (!GSMap.IsValidTile(tile)) return false;
	local owner = GSTile.GetOwner(tile);
	if (owner == GSCompany.COMPANY_INVALID) return true;
	return owner == company_id;
}

function D4_IsTileBuildable(tile, company_id) {
	if (!GSMap.IsValidTile(tile)) return false;
	if (!GSTile.IsBuildable(tile)) return false;
	return D4_TileOwnerMatchesOrUnowned(tile, company_id);
}

function D4_IsTileWater(tile) {
	if (!GSMap.IsValidTile(tile)) return false;
	return GSTile.IsWaterTile(tile) || GSTile.IsSeaTile(tile) || GSTile.IsRiverTile(tile) || GSTile.IsCoastTile(tile);
}

function D4_GetCompanyBalance(company_id) {
	return GSCompany.GetBankBalance(company_id);
}

function D4_CompanySnapshot(company_id) {
	local mode = GSCompanyMode(company_id);
	if (!GSCompanyMode.IsValid()) return { ok = false, error = D4_Error("company_not_found", company_id) };
	return {
		ok = true,
		payload = {
			scope = "company",
			company_id = company_id,
			name = GSCompany.GetName(company_id),
			bank_balance = GSCompany.GetBankBalance(company_id),
			loan_amount = GSCompany.GetLoanAmount(),
			max_loan_amount = GSCompany.GetMaxLoanAmount(),
			loan_interval = GSCompany.GetLoanInterval(),
			tick = D4_Tick(),
		},
	};
}

function D4_CanAfford(company_id, reserve, cost_estimate) {
	local balance = D4_GetCompanyBalance(company_id);
	if (balance < reserve + cost_estimate) return false;
	return true;
}

function D4_IsValidCargoType(cargo_type) {
	return typeof cargo_type == "integer" && cargo_type >= 0 && cargo_type < DIRECTORATE_M4_MAX_CARGO_TYPES && GSCargo.IsValidCargo(cargo_type);
}

function D4_SafeCargoLabel(cargo_type) {
	if (!D4_IsValidCargoType(cargo_type)) return "";
	local label = GSCargo.GetCargoLabel(cargo_type);
	return D4_StringOr(label, "", 8);
}

function D4_EngineMatchesCargo(engine_id, cargo_type) {
	if (!GSEngine.IsValidEngine(engine_id)) return false;
	if (!D4_IsValidCargoType(cargo_type)) return false;
	if (GSEngine.GetVehicleType(engine_id) != GSVehicle.VT_RAIL) return false;
	if (GSEngine.IsWagon(engine_id)) return false;
	return GSEngine.CanRefitCargo(engine_id, cargo_type) || GSEngine.GetCargoType(engine_id) == cargo_type;
}

function D4_FindBuildableRailEngine(cargo_type, rail_type) {
	if (!D4_IsValidCargoType(cargo_type)) return null;
	local count = 0;
	for (local engine_id = 0; engine_id < 2048 && count < 512; engine_id++) {
		if (!GSEngine.IsValidEngine(engine_id)) continue;
		if (!GSEngine.IsBuildable(engine_id)) continue;
		if (GSEngine.GetVehicleType(engine_id) != GSVehicle.VT_RAIL) continue;
		if (GSEngine.IsWagon(engine_id)) continue;
		if (!GSEngine.CanRunOnRail(engine_id, rail_type)) continue;
		if (!GSEngine.HasPowerOnRail(engine_id, rail_type)) continue;
		if (!D4_EngineMatchesCargo(engine_id, cargo_type)) continue;
		return engine_id;
	}
	/* Fallback: ignore cargo compatibility so a train can be built and then
	 * refitted; OpenTTD base sets have few pre-1960 engines and strict cargo
	 * matching may yield none in a 1950 start. */
	for (local engine_id = 0; engine_id < 2048 && count < 512; engine_id++) {
		if (!GSEngine.IsValidEngine(engine_id)) continue;
		if (!GSEngine.IsBuildable(engine_id)) continue;
		if (GSEngine.GetVehicleType(engine_id) != GSVehicle.VT_RAIL) continue;
		if (GSEngine.IsWagon(engine_id)) continue;
		if (!GSEngine.CanRunOnRail(engine_id, rail_type)) continue;
		if (!GSEngine.HasPowerOnRail(engine_id, rail_type)) continue;
		return engine_id;
	}
	return null;
}

function D4_SelectRailType() {
	local current = GSRail.GetCurrentRailType();
	if (GSRail.IsRailTypeAvailable(current) && GSRail.CanBuildRailtype(current)) return true;
	for (local rt = 0; rt < 128; rt++) {
		if (!GSRail.IsRailTypeAvailable(rt)) continue;
		if (!GSRail.CanBuildRailtype(rt)) continue;
		if (GSRail.SetCurrentRailType(rt)) return true;
	}
	return false;
}

function D4_EnsureCompanyFunds(company_id, required) {
	local mode = GSCompanyMode(company_id);
	if (!GSCompanyMode.IsValid()) return false;
	if (GSCompany.GetBankBalance(company_id) >= required) return true;
	local current_loan = GSCompany.GetLoanAmount();
	local maximum_loan = GSCompany.GetMaxLoanAmount();
	local interval = GSCompany.GetLoanInterval();
	if (current_loan < 0 || maximum_loan < current_loan || interval <= 0) return false;
	local deficit = required - GSCompany.GetBankBalance(company_id);
	local increments = (deficit + interval - 1) / interval;
	local target = current_loan + increments * interval;
	if (target > maximum_loan) target = maximum_loan;
	if (target <= current_loan || !GSCompany.SetLoanAmount(target)) return false;
	return GSCompany.GetBankBalance(company_id) >= required;
}
