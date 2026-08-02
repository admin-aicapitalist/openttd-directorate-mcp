function D4_StationDirectionForRailTrack(dir) {
	if (dir == DIR_NE || dir == DIR_SW) return GSRail.RAILTRACK_NW_SE;
	return GSRail.RAILTRACK_NE_SW;
}

function D4_BlueprintTile(point, kind, data) {
	return { point = point, kind = kind, data = data };
}

function D4_RotateBlueprintTile(tile, blueprint_origin, rotation, target_origin) {
	local dx = tile.point.x - blueprint_origin.x;
	local dy = tile.point.y - blueprint_origin.y;
	local rx = dx;
	local ry = dy;
	local r = ((rotation % 4) + 4) % 4;
	if (r == 0) { rx = dx; ry = dy; }
	else if (r == 1) { rx = -dy; ry = dx; }
	else if (r == 2) { rx = -dx; ry = -dy; }
	else { rx = dy; ry = -dx; }
	local rotated_point = { x = target_origin.x + rx, y = target_origin.y + ry };
	local rotated_dir = D4_Has(tile.data, "dir") && tile.data.dir != null ? D4_RotateDir(tile.data.dir, rotation) : null;
	local rotated_in = D4_Has(tile.data, "in_dir") && tile.data.in_dir != null ? D4_RotateDir(tile.data.in_dir, rotation) : null;
	local rotated_out = D4_Has(tile.data, "out_dir") && tile.data.out_dir != null ? D4_RotateDir(tile.data.out_dir, rotation) : null;
	local rotated_data = {};
	foreach (k, v in tile.data) {
		if (k == "dir") rotated_data[k] <- rotated_dir;
		else if (k == "in_dir") rotated_data[k] <- rotated_in;
		else if (k == "out_dir") rotated_data[k] <- rotated_out;
		else if (k == "point") rotated_data[k] <- rotated_point;
		else rotated_data[k] <- v;
	}
	return D4_BlueprintTile(rotated_point, tile.kind, rotated_data);
}

function D4_BuildBlueprint(name, rotation, origin, overrides) {
	local defs = D4_GetBlueprintDefinitions();
	if (!(name in defs)) return { ok = false, error = D4_Error("unknown_blueprint", name) };
	local raw = defs[name];
	local tiles = [];
	local ports = {};
	local required_clear = [];
	local allowed_existing = [];
	local max_count = D4_ClampInt(D4_Has(overrides, "max_tiles") ? overrides.max_tiles : DIRECTORATE_M4_MAX_BLUEPRINT_TILES, DIRECTORATE_M4_MAX_BLUEPRINT_TILES, 1, DIRECTORATE_M4_MAX_BLUEPRINT_TILES);
	foreach (tile in raw.tiles) {
		if (tiles.len() >= max_count) return { ok = false, error = D4_Error("blueprint_too_large", name) };
		tiles.append(D4_RotateBlueprintTile(tile, raw.origin, rotation, origin));
	}
	foreach (k, port in raw.ports) {
		local rotated = [];
		foreach (p in port) {
			local dx = p.x - raw.origin.x;
			local dy = p.y - raw.origin.y;
			local rx = dx;
			local ry = dy;
			local r = ((rotation % 4) + 4) % 4;
			if (r == 1) { rx = -dy; ry = dx; }
			else if (r == 2) { rx = -dx; ry = -dy; }
			else if (r == 3) { rx = dy; ry = -dx; }
			rotated.append({ x = origin.x + rx, y = origin.y + ry });
		}
		ports[k] <- rotated;
	}
	foreach (p in raw.required_clear) {
		local dx = p.x - raw.origin.x;
		local dy = p.y - raw.origin.y;
		local rx = dx;
		local ry = dy;
		local r = ((rotation % 4) + 4) % 4;
		if (r == 1) { rx = -dy; ry = dx; }
		else if (r == 2) { rx = -dx; ry = -dy; }
		else if (r == 3) { rx = dy; ry = -dx; }
		required_clear.append({ x = origin.x + rx, y = origin.y + ry });
	}
	foreach (p in raw.allowed_existing) {
		local dx = p.x - raw.origin.x;
		local dy = p.y - raw.origin.y;
		local rx = dx;
		local ry = dy;
		local r = ((rotation % 4) + 4) % 4;
		if (r == 1) { rx = -dy; ry = dx; }
		else if (r == 2) { rx = -dx; ry = -dy; }
		else if (r == 3) { rx = dy; ry = -dx; }
		allowed_existing.append({ x = origin.x + rx, y = origin.y + ry });
	}
	return {
		ok = true,
		name = name,
		rotation = rotation,
		origin = origin,
		tiles = tiles,
		ports = ports,
		required_clear = required_clear,
		allowed_existing = allowed_existing,
		station_id = raw.station_id,
		station_name = raw.station_name,
	};
}

function D4_GetBlueprintDefinitions() {
	local defs = {
		single_shuttle_1xN = {
			origin = { x = 0, y = 0 },
			station_name = "single_shuttle_1xN",
			station_id = GSStation.STATION_NEW,
			tiles = [
				D4_BlueprintTile({ x = 0, y = 0 }, "station", { num_platforms = 1, platform_length = 1, dir = DIR_NE }),
				D4_BlueprintTile({ x = 0, y = 1 }, "rail", { dir = DIR_NE }),
				D4_BlueprintTile({ x = 0, y = 2 }, "depot", { dir = DIR_NE, in_dir = DIR_NE, out_dir = DIR_NE }),
			],
			required_clear = [{ x = 0, y = 0 }, { x = 0, y = 1 }, { x = 0, y = 2 }],
			allowed_existing = [],
			ports = {
				platform_body = [{ x = 0, y = 0 }],
				throat = [{ x = 0, y = 1 }],
				depot_mouth = [{ x = 0, y = 2 }],
			},
		},
		terminus_2xN = {
			origin = { x = 0, y = 0 },
			station_name = "terminus_2xN",
			station_id = GSStation.STATION_NEW,
			tiles = [
				D4_BlueprintTile({ x = 0, y = 0 }, "station", { num_platforms = 2, platform_length = 1, dir = DIR_NE }),
				D4_BlueprintTile({ x = 0, y = 1 }, "rail", { dir = DIR_NE }),
				D4_BlueprintTile({ x = -1, y = 1 }, "rail", { dir = DIR_NE }),
				D4_BlueprintTile({ x = 1, y = 1 }, "rail", { dir = DIR_NE }),
				D4_BlueprintTile({ x = 0, y = 2 }, "depot", { dir = DIR_NE, in_dir = DIR_NE, out_dir = DIR_NE }),
			],
			required_clear = [
				{ x = 0, y = 0 }, { x = 1, y = 0 },
				{ x = -1, y = 1 }, { x = 0, y = 1 }, { x = 1, y = 1 }, { x = 2, y = 1 },
				{ x = 0, y = 2 }, { x = 1, y = 2 },
			],
			allowed_existing = [],
			ports = {
				platform_body = [{ x = 0, y = 0 }, { x = 1, y = 0 }],
				throat = [{ x = -1, y = 1 }, { x = 0, y = 1 }, { x = 1, y = 1 }],
				depot_mouth = [{ x = 0, y = 2 }],
			},
		},
		through_hub_4x7 = {
			origin = { x = 0, y = 0 },
			station_name = "through_hub_4x7",
			station_id = GSStation.STATION_NEW,
			tiles = [],
			required_clear = [],
			allowed_existing = [],
			ports = {},
		},
		through_hub_2x4 = {
			origin = { x = 0, y = 0 },
			station_name = "through_hub_2x4",
			station_id = GSStation.STATION_NEW,
			tiles = [],
			required_clear = [],
			allowed_existing = [],
			ports = {},
		},
		paired_trunk = {
			origin = { x = 0, y = 0 },
			station_name = "paired_trunk",
			station_id = GSStation.STATION_NEW,
			tiles = [
				D4_BlueprintTile({ x = 0, y = 0 }, "rail", { dir = DIR_NE }),
				D4_BlueprintTile({ x = 0, y = 1 }, "rail", { dir = DIR_NE }),
			],
			required_clear = [{ x = 0, y = 0 }, { x = 0, y = 1 }],
			allowed_existing = [],
			ports = {
				outbound_main = [{ x = 0, y = 0 }],
				return_main = [{ x = 0, y = 1 }],
			},
		},
		split_merge_throat = {
			origin = { x = 0, y = 0 },
			station_name = "split_merge_throat",
			station_id = GSStation.STATION_NEW,
			tiles = [
				D4_BlueprintTile({ x = 0, y = 0 }, "rail", { dir = DIR_NE }),
				D4_BlueprintTile({ x = 1, y = 0 }, "rail", { dir = DIR_SE }),
				D4_BlueprintTile({ x = 0, y = 1 }, "rail", { dir = DIR_NE }),
				D4_BlueprintTile({ x = 1, y = 1 }, "signal", { dir = DIR_SE, signal_type = GSRail.SIGNALTYPE_PBS }),
			],
			required_clear = [{ x = 0, y = 0 }, { x = 1, y = 0 }, { x = 0, y = 1 }, { x = 1, y = 1 }],
			allowed_existing = [],
			ports = {
				merge_in = [{ x = 0, y = 0 }, { x = 0, y = 1 }],
				split_out = [{ x = 1, y = 0 }],
			},
		},
		depot_siding = {
			origin = { x = 0, y = 0 },
			station_name = "depot_siding",
			station_id = GSStation.STATION_NEW,
			tiles = [
				D4_BlueprintTile({ x = 0, y = 0 }, "rail", { dir = DIR_NE }),
				D4_BlueprintTile({ x = 0, y = 1 }, "rail", { dir = DIR_NE }),
				D4_BlueprintTile({ x = 1, y = 1 }, "depot", { dir = DIR_NE, in_dir = DIR_NE, out_dir = DIR_NE }),
			],
			required_clear = [{ x = 0, y = 0 }, { x = 0, y = 1 }, { x = 1, y = 1 }],
			allowed_existing = [{ x = 0, y = 0 }, { x = 0, y = 1 }],
			ports = {
				main = [{ x = 0, y = 0 }],
				depot_mouth = [{ x = 1, y = 1 }],
			},
		},
		feeder_join = {
			origin = { x = 0, y = 0 },
			station_name = "feeder_join",
			station_id = GSStation.STATION_NEW,
			tiles = [
				D4_BlueprintTile({ x = 0, y = 0 }, "rail", { dir = DIR_NE }),
				D4_BlueprintTile({ x = 1, y = 0 }, "rail", { dir = DIR_SE }),
				D4_BlueprintTile({ x = 1, y = 1 }, "rail", { dir = DIR_SE }),
				D4_BlueprintTile({ x = 0, y = 1 }, "rail", { dir = DIR_SW }),
			],
			required_clear = [{ x = 0, y = 0 }, { x = 1, y = 0 }, { x = 1, y = 1 }, { x = 0, y = 1 }],
			allowed_existing = [{ x = 0, y = 0 }],
			ports = {
				feeder_port = [{ x = 1, y = 1 }],
				main = [{ x = 0, y = 0 }],
			},
		},
	};
	D4_SetupThroughHub(defs, "through_hub_4x7", 4, 7);
	D4_SetupThroughHub(defs, "through_hub_2x4", 2, 4);
	return defs;
}

function D4_SetupThroughHub(defs, name, num_platforms, platform_length) {
	local tiles = [];
	local required = [];
	local ports = {
		platform_body = [],
		platform_front = [],
		platform_rear = [],
		throat_ne = [],
		throat_sw = [],
		common_inbound = [],
		common_outbound = [],
		common_rear_merge = [],
		feeder_port = [],
	};
	for (local track = 0; track < num_platforms; track++) {
		for (local cell = 0; cell < platform_length; cell++) {
			local x = cell;
			local y = track;
			tiles.append(D4_BlueprintTile({ x = x, y = y }, "station", { num_platforms = 1, platform_length = 1, dir = DIR_NE }));
			ports.platform_body.append({ x = x, y = y });
			if (cell == 0) ports.platform_front.append({ x = x, y = y });
			if (cell == platform_length - 1) ports.platform_rear.append({ x = x, y = y });
		}
	}
	/* Station tracks run along the platform-length axis. Through throats must
	 * continue that axis at each platform end; the old top/bottom ports were
	 * perpendicular to the station tracks and produced trains parked against
	 * the side of an otherwise "connected" station. */
	for (local y = 0; y < num_platforms; y++) {
		ports.throat_ne.append({ x = platform_length, y = y });
		ports.throat_sw.append({ x = -1, y = y });
		required.append({ x = platform_length, y = y });
		required.append({ x = -1, y = y });
	}
	ports.common_inbound = [{ x = -num_platforms - 2 - platform_length, y = -1 - platform_length }];
	ports.common_outbound = [{ x = -num_platforms - 2 - platform_length, y = -2 - platform_length }];
	ports.common_rear_merge = [{ x = platform_length + num_platforms, y = -1 }];
	/* Reserve the physical RoRo geometry, not its entire bounding rectangle.
	 * The rectangular reserve rejected valid mirrored sites whenever the
	 * serviced industry sat beside an otherwise unused corner of the envelope. */
	for (local station_y = 0; station_y < num_platforms; station_y++) {
		for (local station_x = 0; station_x < platform_length; station_x++) D4_AppendRequiredPoint(required, { x = station_x, y = station_y });
	}
	/* Shared mitered entry, diagonal fan and each horizontal platform branch. */
	D4_AppendRequiredPoint(required, { x = -num_platforms - 2 - platform_length, y = -1 - platform_length });
	for (local entry_step = platform_length - 1; entry_step >= 0; entry_step--) {
		D4_AppendRequiredPoint(required, { x = -num_platforms - 2 - entry_step, y = -2 - entry_step });
		D4_AppendRequiredPoint(required, { x = -num_platforms - 2 - entry_step, y = -1 - entry_step });
	}
	for (local fan_row = 0; fan_row < num_platforms; fan_row++) {
		if (fan_row == 0) {
			D4_AppendRequiredPoint(required, { x = -num_platforms - 1, y = -1 });
			D4_AppendRequiredPoint(required, { x = -num_platforms - 1, y = 0 });
		} else {
			D4_AppendRequiredPoint(required, { x = -num_platforms - 1 + fan_row, y = fan_row - 1 });
			D4_AppendRequiredPoint(required, { x = -num_platforms - 1 + fan_row, y = fan_row });
		}
		for (local fan_x = -num_platforms + fan_row; fan_x <= -1; fan_x++) D4_AppendRequiredPoint(required, { x = fan_x, y = fan_row });
	}
	/* Horizontal rear branches converge onto the shared diagonal merger. */
	for (local merge_row = 0; merge_row < num_platforms; merge_row++) {
		for (local merge_x = platform_length; merge_x <= platform_length + num_platforms - 1 - merge_row; merge_x++) D4_AppendRequiredPoint(required, { x = merge_x, y = merge_row });
	}
	for (local merge_backbone_row = num_platforms - 1; merge_backbone_row > 0; merge_backbone_row--) {
		D4_AppendRequiredPoint(required, { x = platform_length + num_platforms - merge_backbone_row, y = merge_backbone_row });
		D4_AppendRequiredPoint(required, { x = platform_length + num_platforms - merge_backbone_row, y = merge_backbone_row - 1 });
	}
	D4_AppendRequiredPoint(required, { x = platform_length + num_platforms, y = 0 });
	D4_AppendRequiredPoint(required, { x = platform_length + num_platforms, y = -1 });
	/* Rear turnback: alternating map-axis steps are a visually straight 45-degree
	 * miter. The old pure y-run followed by pure x-run was the slowing 90. */
	D4_AppendRequiredPoint(required, { x = platform_length + num_platforms, y = -2 });
	for (local loop_step = 1; loop_step <= platform_length; loop_step++) {
		D4_AppendRequiredPoint(required, { x = platform_length + num_platforms - loop_step, y = -1 - loop_step });
		D4_AppendRequiredPoint(required, { x = platform_length + num_platforms - loop_step, y = -2 - loop_step });
	}
	for (local loop_x = platform_length + num_platforms - platform_length - 1; loop_x >= -num_platforms - 2 - platform_length; loop_x--) D4_AppendRequiredPoint(required, { x = loop_x, y = -2 - platform_length });
	ports.feeder_port = [{ x = -1, y = 0 }, { x = -1, y = num_platforms - 1 }];
	foreach (feeder in ports.feeder_port) D4_AppendRequiredPoint(required, feeder);
	defs[name].tiles = tiles;
	defs[name].required_clear = required;
	defs[name].allowed_existing = [];
	defs[name].ports = ports;
}

function D4_AppendRequiredPoint(required, point) {
	foreach (existing in required) {
		if (existing.x == point.x && existing.y == point.y) return;
	}
	required.append(point);
}

function D4_PreflightBlueprint(blueprint, company_id, test_only) {
	if (!blueprint.ok) return { ok = false, error = blueprint.error };
	local mode = GSCompanyMode(company_id);
	if (!GSCompanyMode.IsValid()) return { ok = false, error = D4_Error("invalid_company", company_id.tostring()) };
	if (!D4_SelectRailType()) return { ok = false, error = D4_Error("rail_type_unavailable", company_id.tostring()) };
	local failures = [];
	local cost = 0;
	foreach (p in blueprint.required_clear) {
		local tile = D4_ToTile(p);
		if (!D4_IsTileBuildable(tile, company_id)) {
			local owner = GSTile.GetOwner(tile);
			local reason = owner == company_id ? "not_buildable" : "rival_owner";
			failures.append({ reason = reason, point = p, tile = tile });
		}
	}
	if (failures.len() > 0) return { ok = false, error = D4_Error("blueprint_site_blocked", blueprint.name), failures = failures };
	foreach (tile in blueprint.tiles) {
		local result = D4_PreflightTile(tile, company_id, test_only);
		if (!result.ok) {
			failures.append(result.failure);
			continue;
		}
		cost += result.cost;
	}
	if (failures.len() > 0) return { ok = false, error = D4_Error("blueprint_preflight_failed", blueprint.name), failures = failures, cost = cost };
	return { ok = true, cost = cost, mutation = !test_only };
}

function D4_PreflightTile(tile, company_id, test_only) {
	local tm = GSTestMode();
	local tile_index = D4_ToTile(tile.point);
	if (!GSMap.IsValidTile(tile_index)) return { ok = false, failure = { reason = "out_of_map", point = tile.point } };
	if (tile.kind == "station") {
		local dir = D4_StationDirectionForRailTrack(tile.data.dir);
		if (!GSRail.BuildRailStation(tile_index, dir, tile.data.num_platforms, tile.data.platform_length, GSStation.STATION_NEW)) {
			return { ok = false, failure = { reason = "station_build_failed", point = tile.point, dir = tile.data.dir } };
		}
		return { ok = true, cost = GSRail.GetBuildCost(GSRail.GetCurrentRailType(), GSRail.BT_STATION) };
	}
	if (tile.kind == "depot") {
		local front = D4_ToTile(D4_Offset(tile.point, tile.data.dir, 1));
		if (!GSRail.BuildRailDepot(tile_index, front)) {
			return { ok = false, failure = { reason = "depot_build_failed", point = tile.point } };
		}
		return { ok = true, cost = GSRail.GetBuildCost(GSRail.GetCurrentRailType(), GSRail.BT_DEPOT) };
	}
	if (tile.kind == "rail") {
		local track = D4_TrackForDirection(tile.data.dir);
		if (!GSRail.BuildRailTrack(tile_index, track)) {
			return { ok = false, failure = { reason = "track_build_failed", point = tile.point, dir = tile.data.dir } };
		}
		return { ok = true, cost = GSRail.GetBuildCost(GSRail.GetCurrentRailType(), GSRail.BT_TRACK) };
	}
	if (tile.kind == "signal") {
		local front = D4_ToTile(D4_Offset(tile.point, tile.data.dir, 1));
		if (!GSRail.BuildSignal(tile_index, front, tile.data.signal_type)) {
			return { ok = false, failure = { reason = "signal_build_failed", point = tile.point } };
		}
		return { ok = true, cost = GSRail.GetBuildCost(GSRail.GetCurrentRailType(), GSRail.BT_SIGNAL) };
	}
	return { ok = false, failure = { reason = "unknown_tile_kind", point = tile.point, kind = tile.kind } };
}

function D4_ApplyBlueprintTile(tile, company_id) {
	local tile_index = D4_ToTile(tile.point);
	if (tile.kind == "station") {
		local dir = D4_StationDirectionForRailTrack(tile.data.dir);
		return GSRail.BuildRailStation(tile_index, dir, tile.data.num_platforms, tile.data.platform_length, GSStation.STATION_NEW);
	}
	if (tile.kind == "depot") {
		local front = D4_ToTile(D4_Offset(tile.point, tile.data.dir, 1));
		return GSRail.BuildRailDepot(tile_index, front);
	}
	if (tile.kind == "rail") {
		local track = D4_TrackForDirection(tile.data.dir);
		return GSRail.BuildRailTrack(tile_index, track);
	}
	if (tile.kind == "signal") {
		local front = D4_ToTile(D4_Offset(tile.point, tile.data.dir, 1));
		return GSRail.BuildSignal(tile_index, front, tile.data.signal_type);
	}
	return false;
}

function D4_SelectRailType() {
	local rail_types = GSRailTypeList();
	if (rail_types.IsEmpty()) return false;
	local rail_type = rail_types.Begin();
	if (rail_types.IsEnd()) return false;
	GSRail.SetCurrentRailType(rail_type);
	return GSRail.GetCurrentRailType() == rail_type;
}

function D4_BlueprintCentroid(blueprint) {
	if (!blueprint.ok || blueprint.tiles.len() == 0) return { x = blueprint.origin.x, y = blueprint.origin.y };
	local sx = 0;
	local sy = 0;
	foreach (t in blueprint.tiles) { sx += t.point.x; sy += t.point.y; }
	return { x = sx / blueprint.tiles.len(), y = sy / blueprint.tiles.len() };
}

function D4_BlueprintBounds(blueprint) {
	if (!blueprint.ok || blueprint.tiles.len() == 0) return { min_x = blueprint.origin.x, min_y = blueprint.origin.y, max_x = blueprint.origin.x, max_y = blueprint.origin.y };
	local min_x = blueprint.tiles[0].point.x;
	local min_y = blueprint.tiles[0].point.y;
	local max_x = min_x;
	local max_y = min_y;
	foreach (t in blueprint.tiles) {
		if (t.point.x < min_x) min_x = t.point.x;
		if (t.point.y < min_y) min_y = t.point.y;
		if (t.point.x > max_x) max_x = t.point.x;
		if (t.point.y > max_y) max_y = t.point.y;
	}
	return { min_x = min_x, min_y = min_y, max_x = max_x, max_y = max_y };
}
