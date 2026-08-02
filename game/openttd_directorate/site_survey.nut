function D4_StationSpreadLimit() {
	if (GSGameSettings.IsValid("station.station_spread")) {
		local spread = GSGameSettings.GetValue("station.station_spread");
		if (typeof spread == "integer") return D4_ClampInt(spread, DIRECTORATE_M4_MAX_STATION_SPREAD, 4, 64);
	}
	return DIRECTORATE_M4_MAX_STATION_SPREAD;
}

function D4_StationCatchmentRadius() {
	return GSStation.GetCoverageRadius(GSStation.STATION_TRAIN);
}

function D4_IndustryLocation(industry_id) {
	if (!GSIndustry.IsValidIndustry(industry_id)) return null;
	local tile = GSIndustry.GetLocation(industry_id);
	local p = D4_FromTile(tile);
	if (!D4_IsPointOnMap(p)) return null;
	return p;
}

function D4_IndustryCatchmentTiles(industry_id, role, catchment) {
	if (role == "source") return GSTileList_IndustryProducing(industry_id, catchment);
	if (role == "destination") return GSTileList_IndustryAccepting(industry_id, catchment);
	return null;
}

function D4_SurveyStationSites(company_id, industry_id, role, blueprint_name, intent, policy) {
	local industry_location = D4_IndustryLocation(industry_id);
	if (industry_location == null) return { ok = false, error = D4_Error("invalid_industry", industry_id.tostring()) };
	local spread = D4_StationSpreadLimit();
	local catchment = D4_StationCatchmentRadius();
	local catchment_tiles = D4_IndustryCatchmentTiles(industry_id, role, catchment);
	if (catchment_tiles == null) return { ok = false, error = D4_Error("invalid_industry_role", role) };
	local candidates = [];
	local rejected_reasons = {};
	local rejected_count = 0;
	local search_radius = D4_ClampInt(D4_Has(policy, "site_search_radius") ? policy.site_search_radius : 6, 6, 2, 16);
	for (local dx = -search_radius; dx <= search_radius; dx++) {
		for (local dy = -search_radius; dy <= search_radius; dy++) {
			local origin = { x = industry_location.x + dx, y = industry_location.y + dy };
			if (!D4_IsPointOnMap(origin)) continue;
			for (local rotation = 0; rotation < 4; rotation++) {
				local blueprint_overrides = {};
				if (blueprint_name == "single_shuttle_1xN") blueprint_overrides.platform_length <- D4_ClampInt(D4_Has(policy, "platform_length") ? policy.platform_length : 1, 1, 1, 7);
				local bp = D4_BuildBlueprint(blueprint_name, rotation, origin, blueprint_overrides);
				if (!bp.ok) continue;
				local result = D4_EvaluateSite(company_id, industry_id, industry_location, bp, spread, catchment_tiles);
				if (result.ok) {
					candidates.append({
						origin = origin,
						rotation = rotation,
						blueprint = bp,
						score = result.score,
						reasons = result.reasons,
						cost = result.cost,
					});
				} else {
					rejected_count++;
					if (D4_Has(result, "reasons") && D4_IsArray(result.reasons)) {
						foreach (reason in result.reasons) {
							if (!(reason in rejected_reasons)) rejected_reasons[reason] <- 0;
							rejected_reasons[reason]++;
						}
					}
				}
			}
		}
	}
	candidates.sort(D4_SiteCompare);
	local top = [];
	/* Preserve several ranked candidates for every cardinal orientation. A
	 * single candidate per rotation leaves no terrain alternative when the
	 * geometrically correct mirrored pair produces an unusable paired-lane
	 * offset. Interleave orientations so the bounded list stays balanced. */
	for (local rank = 0; rank < 4 && top.len() < DIRECTORATE_M4_MAX_SITES; rank++) {
		for (local rotation = 0; rotation < 4 && top.len() < DIRECTORATE_M4_MAX_SITES; rotation++) {
			local seen_for_rotation = 0;
			for (local i = 0; i < candidates.len(); i++) {
				if (candidates[i].rotation != rotation) continue;
				if (seen_for_rotation == rank) { top.append(candidates[i]); break; }
				seen_for_rotation++;
			}
		}
	}
	return { ok = true, industry_id = industry_id, industry_location = industry_location, candidates = top, rejected = rejected_count + candidates.len() - top.len(), rejected_reasons = rejected_reasons };
}

function D4_EvaluateSite(company_id, industry_id, industry_location, blueprint, spread, catchment_tiles) {
	local reasons = [];
	local failures = [];
	local cost = 0;
	local covered = false;
	foreach (tile in blueprint.tiles) {
		if (tile.kind == "station") {
			if (catchment_tiles.HasItem(D4_ToTile(tile.point))) covered = true;
			/* Rail station commands require a level platform; a buildable slope is
			 * not an executable station site.  Reject it during survey rather than
			 * blocking the bridge with repeated failed test commands. */
			if (GSTile.GetSlope(D4_ToTile(tile.point)) != GSTile.SLOPE_FLAT) failures.append("station_slope");
		}
	}
	if (!covered) failures.append("catchment_miss");
	local bounds = D4_BlueprintBounds(blueprint);
	local w = bounds.max_x - bounds.min_x + 1;
	local h = bounds.max_y - bounds.min_y + 1;
	if (w > spread || h > spread) failures.append("station_spread");
	local throat_ok = true;
	local platform_throat_clear = true;
	foreach (p in blueprint.required_clear) {
		local tile = D4_ToTile(p);
		if (!GSMap.IsValidTile(tile)) { failures.append("out_of_map"); continue; }
		if (D4_IsTileWater(tile)) { failures.append("water"); continue; }
		local owner = GSTile.GetOwner(tile);
		if (owner != GSCompany.COMPANY_INVALID && owner != company_id) { failures.append("rival_owner"); continue; }
		if (!GSTile.IsBuildable(tile) && !D4_PointInList(p, blueprint.allowed_existing)) { failures.append("not_buildable"); continue; }
		if (GSRail.IsRailStationTile(tile) || GSRail.IsRailDepotTile(tile)) { platform_throat_clear = false; failures.append("station_in_reserve"); }
	}
	if (!platform_throat_clear) failures.append("throat_blocked");
	local ports_clear = true;
	foreach (port_name, port_tiles in blueprint.ports) {
		if (port_name == "platform_body") continue;
		foreach (p in port_tiles) {
			if (!D4_IsPointOnMap(p)) { ports_clear = false; break; }
			local tile = D4_ToTile(p);
			local owner = GSTile.GetOwner(tile);
			if (owner != GSCompany.COMPANY_INVALID && owner != company_id) { ports_clear = false; break; }
		}
	}
	if (!ports_clear) failures.append("corridor_port_blocked");
	if (failures.len() > 0) return { ok = false, score = 0, reasons = failures };
	/* Candidate enumeration is deliberately command-free. Running GSTestMode
	 * construction for every candidate yields once per command and can stall the
	 * bridge for minutes. The selected source/destination blueprints receive the
	 * authoritative real-engine preflight in AdvancePlan. */
	local score = 1000;
	score -= cost / 100;
	score -= w * h;
	local d_origin = abs(industry_location.x - blueprint.origin.x) + abs(industry_location.y - blueprint.origin.y);
	score -= d_origin * 2;
	reasons.append("catchment_ok");
	reasons.append("throat_clear");
	reasons.append("ports_clear");
	return { ok = true, score = score, reasons = reasons, cost = cost };
}

function D4_PointInList(point, list) {
	foreach (p in list) if (p.x == point.x && p.y == point.y) return true;
	return false;
}

function D4_SiteCompare(a, b) {
	if (a.score > b.score) return -1;
	if (a.score < b.score) return 1;
	if (a.cost < b.cost) return -1;
	if (a.cost > b.cost) return 1;
	return 0;
}

function D4_GetSiteFingerprint(survey, pick_index) {
	if (survey == null || !survey.ok || pick_index >= survey.candidates.len()) return "";
	local c = survey.candidates[pick_index];
	return survey.industry_id + ":" + c.origin.x + "," + c.origin.y + ":" + c.rotation;
}
