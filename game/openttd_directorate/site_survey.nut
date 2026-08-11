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

/* Manhattan-distance ring around (0,0): every {dx,dy} with |dx|+|dy| == ring,
 * walked in a fixed deterministic order (dx ascending, +remainder before
 * -remainder). Ring 0 is the origin itself. */
function D4_RingOffsets(ring) {
	local offsets = [];
	if (ring == 0) {
		offsets.append({ dx = 0, dy = 0 });
		return offsets;
	}
	for (local dx = -ring; dx <= ring; dx++) {
		local remainder = ring - abs(dx);
		if (remainder == 0) {
			offsets.append({ dx = dx, dy = 0 });
		} else {
			offsets.append({ dx = dx, dy = remainder });
			offsets.append({ dx = dx, dy = -remainder });
		}
	}
	return offsets;
}

/* Insertion into a bounded, score-sorted (best-first) list capped at
 * DIRECTORATE_M4_MAX_SITES. O(DIRECTORATE_M4_MAX_SITES) per call, which is
 * fine since the cap is a small constant (4). */
function D4_InsertRankedCandidate(list, candidate) {
	local insert_at = list.len();
	list.append(candidate);
	while (insert_at > 0 && D4_SiteCompare(list[insert_at], list[insert_at - 1]) < 0) {
		local tmp = list[insert_at];
		list[insert_at] = list[insert_at - 1];
		list[insert_at - 1] = tmp;
		insert_at--;
	}
	if (list.len() > DIRECTORATE_M4_MAX_SITES) list.remove(list.len() - 1);
}

function D4_RotationHasFourFlat(list) {
	if (list.len() < DIRECTORATE_M4_MAX_SITES) return false;
	foreach (candidate in list) if (candidate.needs_landscaping) return false;
	return true;
}

/* Deterministic bounded nearest-first / ring-order branch-and-bound.
 *
 * Score is 1000 - cost/100 - w*h - d_origin*2 - sloped_station_tiles*50: for a
 * fixed rotation, w*h (footprint) is a per-rotation constant, cost is always 0
 * here (site scoring is deliberately command-free -- see D4_EvaluateSite), and
 * d_origin is exactly the Manhattan ring distance a candidate is discovered
 * at. So for a fixed rotation, the best score achievable by any candidate at
 * ring k or farther is bounded above by (1000 - w*h - 2*k), monotonically
 * non-increasing in k, since sloped_station_tiles*50 >= 0.
 *
 * Once a rotation has retained DIRECTORATE_M4_MAX_SITES candidates that are
 * all flat (needs_landscaping == false), its worst retained candidate sits at
 * some ring d <= the ring just completed, with score (1000 - w*h - 2*d). Any
 * unvisited farther ring k > d has bound (1000 - w*h - 2*k) < (1000 - w*h -
 * 2*d), so it can never outrank that worst retained candidate -- the
 * rotation's search can stop. A rotation that never reaches four flat
 * candidates keeps expanding rings all the way to the policy radius, so an
 * all-sloped area (landscaping required everywhere) is never abandoned early.
 */
function D4_SurveyStationSites(company_id, industry_id, role, blueprint_name, intent, policy) {
	local industry_location = D4_IndustryLocation(industry_id);
	if (industry_location == null) return { ok = false, error = D4_Error("invalid_industry", industry_id.tostring()) };
	local spread = D4_StationSpreadLimit();
	local catchment = D4_StationCatchmentRadius();
	local catchment_tiles = D4_IndustryCatchmentTiles(industry_id, role, catchment);
	if (catchment_tiles == null) return { ok = false, error = D4_Error("invalid_industry_role", role) };
	local rejected_reasons = {};
	local rejected_count = 0;
	local considered_ok_count = 0;
	local search_radius = D4_ClampInt(D4_Has(policy, "site_search_radius") ? policy.site_search_radius : 6, 6, 2, 16);
	local blueprint_overrides = {};
	if (blueprint_name == "single_shuttle_1xN") blueprint_overrides.platform_length <- D4_ClampInt(D4_Has(policy, "platform_length") ? policy.platform_length : 1, 1, 1, 7);
	local per_rotation = [[], [], [], []];
	local rotation_done = [false, false, false, false];
	for (local ring = 0; ring <= search_radius; ring++) {
		local offsets = D4_RingOffsets(ring);
		foreach (offset in offsets) {
			local origin = { x = industry_location.x + offset.dx, y = industry_location.y + offset.dy };
			if (!D4_IsPointOnMap(origin)) continue;
			for (local rotation = 0; rotation < 4; rotation++) {
				if (rotation_done[rotation]) continue;
				local bp = D4_BuildBlueprint(blueprint_name, rotation, origin, blueprint_overrides);
				if (!bp.ok) continue;
				local result = D4_EvaluateSite(company_id, industry_id, industry_location, bp, spread, catchment_tiles);
				if (result.ok) {
					considered_ok_count++;
					D4_InsertRankedCandidate(per_rotation[rotation], {
						origin = origin,
						rotation = rotation,
						blueprint = bp,
						score = result.score,
						reasons = result.reasons,
						cost = result.cost,
						needs_landscaping = result.needs_landscaping,
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
		local all_done = true;
		for (local rotation = 0; rotation < 4; rotation++) {
			if (!rotation_done[rotation] && D4_RotationHasFourFlat(per_rotation[rotation])) rotation_done[rotation] = true;
			if (!rotation_done[rotation]) all_done = false;
		}
		if (all_done) break;
	}
	local top = [];
	/* Preserve several ranked candidates for every cardinal orientation. A
	 * single candidate per rotation leaves no terrain alternative when the
	 * geometrically correct mirrored pair produces an unusable paired-lane
	 * offset. Interleave orientations so the bounded list stays balanced. */
	for (local rank = 0; rank < DIRECTORATE_M4_MAX_SITES && top.len() < DIRECTORATE_M4_MAX_SITES; rank++) {
		for (local rotation = 0; rotation < 4 && top.len() < DIRECTORATE_M4_MAX_SITES; rotation++) {
			if (rank < per_rotation[rotation].len()) top.append(per_rotation[rotation][rank]);
		}
	}
	return { ok = true, industry_id = industry_id, industry_location = industry_location, candidates = top, rejected = rejected_count + considered_ok_count - top.len(), rejected_reasons = rejected_reasons };
}

function D4_EvaluateSite(company_id, industry_id, industry_location, blueprint, spread, catchment_tiles) {
	local reasons = [];
	local failures = [];
	local cost = 0;
	local covered = false;
	local sloped_station_tiles = 0;
	local sloped_terminal_tiles = 0;
	foreach (tile in blueprint.tiles) {
		if (tile.kind == "station") {
			if (catchment_tiles.HasItem(D4_ToTile(tile.point))) covered = true;
			/* A sloped station tile is not an outright disqualification: bounded
			 * landscaping (D4_PrependBoundedLandscaping) can level the pad at
			 * compile time within a capped rectangle/height/cost envelope, and
			 * D4_StationOrDepotAlreadyBuildable/preflight are the authoritative
			 * gate on whether that is actually affordable and safe. Rejecting the
			 * candidate here would make every hilly site unreachable regardless
			 * of how small the required earthwork is, turning landscaping into
			 * dead code. Score it down instead so flatter sites still win when
			 * one is available. */
			if (GSTile.GetSlope(D4_ToTile(tile.point)) != GSTile.SLOPE_FLAT) sloped_station_tiles++;
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
	/* A 4x7 site's reserved terminal is larger than the station rectangle.
	 * Reject orientations whose deterministic fan/merge/loop already intersects
	 * an immutable tile, and strongly prefer terrain requiring less endpoint
	 * earthwork. This prevents an industry-adjacent station from winning while
	 * its common fan points straight through the industry. */
	if (blueprint.name == "through_hub_4x7") {
		local layout = D4_DeriveThroughHubEndpointLayout(blueprint);
		if (!layout.ok) failures.append("terminal_layout_invalid");
		else {
			local terminal_seen = {};
			local terminal_paths = [layout.fan_backbone, layout.merge_backbone, layout.loop_path];
			foreach (path in layout.fan_paths) terminal_paths.append(path);
			foreach (path2 in layout.merge_paths) terminal_paths.append(path2);
			foreach (path3 in terminal_paths) foreach (p3 in path3) {
				local pkey = D4_PointKey(p3); if (pkey in terminal_seen) continue; terminal_seen[pkey] <- true;
				if (!D4_IsPointOnMap(p3)) { failures.append("terminal_out_of_map"); continue; }
				local terminal_tile = D4_ToTile(p3), terminal_owner = GSTile.GetOwner(terminal_tile);
				if (D4_IsTileWater(terminal_tile) || (terminal_owner != GSCompany.COMPANY_INVALID && terminal_owner != company_id) || !GSTile.IsBuildable(terminal_tile)) { failures.append("terminal_envelope_blocked"); continue; }
				local vertex_offsets = [{ x=1, y=0 }, { x=0, y=1 }, { x=1, y=1 }];
				foreach (offset in vertex_offsets) {
					local vp = { x=p3.x + offset.x, y=p3.y + offset.y };
					if (!D4_IsPointOnMap(vp)) { failures.append("terminal_out_of_map"); continue; }
					local vt = D4_ToTile(vp), vo = GSTile.GetOwner(vt);
					if (D4_IsTileWater(vt) || (vo != GSCompany.COMPANY_INVALID && vo != company_id) || !GSTile.IsBuildable(vt)) failures.append("terminal_envelope_blocked");
				}
				if (GSTile.GetSlope(terminal_tile) != GSTile.SLOPE_FLAT) sloped_terminal_tiles++;
			}
		}
	}
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
	/* Penalise, but do not disqualify, a site whose pad needs landscaping. This
	 * keeps flat terrain preferred while still surfacing this candidate when the
	 * search radius has no flat alternative. */
	score -= sloped_station_tiles * 50;
	score -= sloped_terminal_tiles * 20;
	reasons.append("catchment_ok");
	reasons.append("throat_clear");
	reasons.append("ports_clear");
	if (sloped_station_tiles > 0) reasons.append("station_needs_landscaping");
	if (sloped_terminal_tiles > 0) reasons.append("terminal_needs_landscaping");
	return { ok = true, score = score, reasons = reasons, cost = cost, needs_landscaping = sloped_station_tiles > 0 };
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
