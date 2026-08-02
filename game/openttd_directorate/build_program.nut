function D4_CompileBuildProgram(plan) {
	if (!D4_IsTable(plan) || !D4_Has(plan, "source_site") || !D4_Has(plan, "destination_site")) return { ok = false, error = D4_Error("program_missing_sites", "") };
	local ops = [];
	local source_station = D4_StationRectOperation("source_station", plan.station_blueprint, GSStation.STATION_NEW);
	if (!source_station.ok) return source_station;
	ops.append(source_station.op);
	local destination_station = D4_StationRectOperation("destination_station", plan.destination_blueprint, source_station.op.destination_station);
	if (!destination_station.ok) return destination_station;
	ops.append(destination_station.op);

	local start = D4_BlueprintPortLocation(plan.station_blueprint, "throat_ne");
	if (start == null) start = D4_BlueprintPortLocation(plan.station_blueprint, "throat");
	local goal = D4_BlueprintPortLocation(plan.destination_blueprint, "throat_sw");
	if (goal == null) goal = D4_BlueprintPortLocation(plan.destination_blueprint, "throat");
	if (start == null || goal == null) return { ok = false, error = D4_Error("program_missing_throats", "") };

	local single_shuttle = D4_Has(plan.station_blueprint, "name") && plan.station_blueprint.name == "single_shuttle_1xN";
	local initial_single_track = D4_Has(plan.policy, "initial_single_track") && plan.policy.initial_single_track == true;
	local paired_mode = !single_shuttle && !initial_single_track;
	if (paired_mode && D4_IsThroughHubBlueprint(plan.station_blueprint) && D4_IsThroughHubBlueprint(plan.destination_blueprint)) {
		return D4_CompileThroughHubRoroProgram(plan, source_station.op, destination_station.op);
	}
	/* The centerline starts on the throat tile, not the station tile.  For a
	 * shuttle, preserve the actual station tiles as the predecessor/successor
	 * context in the emitted endpoint primitives.  Apply preflight tests those
	 * exact primitives before any mutation. */
	local source_entry = D4_NearestBlueprintPortPoint(plan.station_blueprint, "platform_body", start);
	local destination_exit = D4_NearestBlueprintPortPoint(plan.destination_blueprint, "platform_body", goal);
	if (source_entry == null || destination_exit == null) return { ok = false, error = D4_Error("program_missing_station_entries", "") };
	local required_start_dir = D4_DirectionBetween(source_entry, start);
	local required_goal_dir = D4_DirectionBetween(goal, destination_exit);
	if (required_start_dir < 0 || required_goal_dir < 0) return { ok = false, error = D4_Error("program_invalid_station_heading", "") };
	local bootstrap_curve_run = single_shuttle ? D4_ClampInt(D4_Has(plan.policy, "minimum_curve_run") ? plan.policy.minimum_curve_run : 3, 3, 3, 12) : 0;
	local route = D4_BuildLegalCenterline(start, goal, plan.company_id, plan.policy, required_start_dir, required_goal_dir, single_shuttle ? 4 : -1, single_shuttle ? 50 : -1, bootstrap_curve_run, false);
	if (!route.ok) return route;
	local paired = { ok = true, return_lane = [] };
	local destination_return_entry = null;
	local source_return_exit = null;
	local return_endpoint_diagnostics = "";
	if (paired_mode) {
		/* The selected outbound platform can put the adjacent station platform on
		 * either side after rotation. Try both bounded offsets and retain the one
		 * whose reversed lane has legal endpoints at both station footprints. */
		foreach (side_turns in [1, 3]) {
			local candidate = D4_DeriveProgramLanes(route.path, side_turns);
			if (!candidate.ok) continue;
			local candidate_destination_entry = D4_SelectLanePlatformEndpoint(plan.destination_blueprint, candidate.return_lane[0], candidate.return_lane[1], true);
			local candidate_source_exit = D4_SelectLanePlatformEndpoint(plan.station_blueprint, candidate.return_lane[candidate.return_lane.len() - 1], candidate.return_lane[candidate.return_lane.len() - 2], false);
			return_endpoint_diagnostics += "side=" + side_turns + ":" + D4_PointKey(candidate.return_lane[0]) + ">" + D4_PointKey(candidate.return_lane[candidate.return_lane.len() - 1]) + ":dest=" + (candidate_destination_entry != null) + ":source=" + (candidate_source_exit != null) + ";";
			if (candidate_destination_entry == null || candidate_source_exit == null) continue;
			paired = candidate;
			destination_return_entry = candidate_destination_entry;
			source_return_exit = candidate_source_exit;
			break;
		}
		if (destination_return_entry == null || source_return_exit == null) return { ok = false, error = D4_Error("program_return_station_endpoint_missing", return_endpoint_diagnostics) };
	}
	if (!D4_AppendLaneOperations(ops, "outbound", route.path, source_entry, destination_exit)) return { ok = false, error = D4_Error("program_invalid_outbound", "") };
	if (paired_mode) {
		/* D4_DeriveProgramLanes returns the second track in destination-to-source
		 * order, so its station endpoints are deliberately reversed. */
		if (!D4_AppendLaneOperations(ops, "return", paired.return_lane, destination_return_entry, source_return_exit)) return { ok = false, error = D4_Error("program_invalid_return", "") };
	}

	/* A paired return lane occupies the outbound route's right-hand shoulder.
	 * Keep an explicit occupancy set so the depot siding chooses the clear
	 * shoulder instead of colliding with rail that this same program creates. */
	local occupied = {};
	foreach (route_point in route.path) occupied[D4_PointKey(route_point)] <- true;
	foreach (return_point in paired.return_lane) occupied[D4_PointKey(return_point)] <- true;
	local depot = D4_DepotOperation(route.path, occupied);
	if (depot.ok) {
		ops.append(depot.access_op);
		ops.append(depot.op);
	}

	local signals_enabled = paired_mode && D4_Has(plan.policy, "signals") && plan.policy.signals == true;
	if (signals_enabled) {
		local signal_spacing = D4_ClampInt(D4_Has(plan.policy, "signal_spacing") ? plan.policy.signal_spacing : 8, 8, 4, 16);
		local excluded_signals = {};
		if (depot.ok) excluded_signals[depot.op.front] <- true;
		local outbound_signals = D4_AppendLaneSignals(ops, "outbound", route.path, signal_spacing, excluded_signals);
		local return_signals = D4_AppendLaneSignals(ops, "return", paired.return_lane, signal_spacing, excluded_signals);
		if (outbound_signals < 2 || return_signals < 2) return { ok = false, error = D4_Error("program_signal_spacing_unusable", outbound_signals.tostring() + ":" + return_signals.tostring()) };
	}

	local validation = D4_ValidateBuildProgram(ops);
	if (!validation.ok) return validation;
	return {
		ok = true,
		version = DIRECTORATE_M4_BUILD_PROGRAM_VERSION,
		fingerprint = D4_BoundedFingerprint({ source = start, goal = goal, source_entry = source_entry, destination_exit = destination_exit, count = ops.len(), path = route.path, ret = paired.return_lane }),
		ops = ops,
		path = route.path,
		return_lane = paired.return_lane,
	};
}

function D4_AppendLaneSignals(ops, prefix, path, spacing, excluded) {
	if (!D4_IsArray(ops) || !D4_IsArray(path) || path.len() < 8) return 0;
	local count = 0;
	local last_index = 0;
	for (local i = spacing; i + 2 < path.len(); i++) {
		if (i - last_index < spacing) continue;
		local incoming = D4_DirectionBetween(path[i - 1], path[i]);
		local outgoing = D4_DirectionBetween(path[i], path[i + 1]);
		if (incoming < 0 || incoming != outgoing) continue;
		local tile = D4_ToTile(path[i]);
		if (excluded != null && tile in excluded) continue;
		ops.append({
			op_id = "signal." + prefix + "." + count,
			kind = "signal",
			tile = tile,
			point = path[i],
			/* A signal faces the tile from which the permitted train approaches. */
			front = D4_ToTile(path[i - 1]),
			front_point = path[i - 1],
			signal_type = GSRail.SIGNALTYPE_PBS_ONEWAY,
		});
		last_index = i;
		count++;
	}
	return count;
}

function D4_IsThroughHubBlueprint(blueprint) {
	return D4_IsTable(blueprint) && D4_Has(blueprint, "name") && (blueprint.name == "through_hub_2x4" || blueprint.name == "through_hub_4x7");
}

function D4_CompileThroughHubRoroProgram(plan, source_station, destination_station) {
	local ops = [source_station, destination_station];
	local source_in = D4_BlueprintPortLocation(plan.station_blueprint, "common_inbound");
	local source_out = D4_BlueprintPortLocation(plan.station_blueprint, "common_outbound");
	local dest_in = D4_BlueprintPortLocation(plan.destination_blueprint, "common_inbound");
	local dest_out = D4_BlueprintPortLocation(plan.destination_blueprint, "common_outbound");
	if (source_in == null || source_out == null || dest_in == null || dest_out == null) return { ok = false, error = D4_Error("program_missing_common_ports", "") };
	local emitted_rails = {};
	local source_manifest = D4_AppendThroughHubEndpoint(ops, "source", plan.station_blueprint, source_in, source_out, plan.company_id, plan.policy, emitted_rails);
	if (!source_manifest.ok) return source_manifest;
	local dest_manifest = D4_AppendThroughHubEndpoint(ops, "destination", plan.destination_blueprint, dest_in, dest_out, plan.company_id, plan.policy, emitted_rails);
	if (!dest_manifest.ok) return dest_manifest;
	local source_to_dest = D4_DominantDirection(source_out, dest_in);
	local dest_to_source = D4_DominantDirection(dest_out, source_in);
	if (source_manifest.manifest.loop_exit_heading != source_to_dest) return { ok = false, error = D4_Error("through_hub_source_exit_heading_mismatch", D4_DirName(source_manifest.manifest.loop_exit_heading) + ":" + D4_DirName(source_to_dest)) };
	if (dest_manifest.manifest.loop_exit_heading != dest_to_source) return { ok = false, error = D4_Error("through_hub_destination_exit_heading_mismatch", D4_DirName(dest_manifest.manifest.loop_exit_heading) + ":" + D4_DirName(dest_to_source)) };
	/* The platform length is the maximum consist envelope for this route. Keep
	 * every pair of mainline 45-degree transitions at least that far apart so a
	 * full-length train cannot occupy both curve primitives simultaneously. */
	local turn_clearance = source_manifest.manifest.platform_length;
	if (dest_manifest.manifest.platform_length > turn_clearance) turn_clearance = dest_manifest.manifest.platform_length;
	local outbound = D4_BuildLegalCenterline(source_out, dest_in, plan.company_id, plan.policy, source_manifest.manifest.loop_exit_heading, dest_manifest.manifest.fan_entry_heading, 4, 50, turn_clearance, true, dest_out, source_in, dest_manifest.manifest.loop_exit_heading, source_manifest.manifest.fan_entry_heading);
	local curve_clearance_relaxed = false;
	/* Terrain may make the full consist envelope impossible. Only then permit a
	 * short paired 45-left/45-right trajectory correction; three tiles is the
	 * minimum at which the offset lane miters remain valid. */
	if (!outbound.ok && turn_clearance > 3) {
		outbound = D4_BuildLegalCenterline(source_out, dest_in, plan.company_id, plan.policy, source_manifest.manifest.loop_exit_heading, dest_manifest.manifest.fan_entry_heading, 4, 50, 3, true, dest_out, source_in, dest_manifest.manifest.loop_exit_heading, source_manifest.manifest.fan_entry_heading);
		curve_clearance_relaxed = outbound.ok;
	}
	if (!outbound.ok) return outbound;
	local returned = null;
	local lane_diagnostics = "";
	foreach (side_turns in [1, 3]) {
		local candidate = D4_DeriveProgramLanes(outbound.path, side_turns);
		if (!candidate.ok) {
			local candidate_error = D4_Has(candidate, "error") && D4_IsTable(candidate.error) ? candidate.error : null;
			lane_diagnostics += "side=" + side_turns + ":derive_failed:" + (candidate_error != null && D4_Has(candidate_error, "code") ? candidate_error.code : "unknown") + ":" + (candidate_error != null && D4_Has(candidate_error, "detail") ? candidate_error.detail : "") + ";";
			continue;
		}
		local start_ok = D4_PointKey(candidate.return_lane[0]) == D4_PointKey(dest_out);
		local end_ok = D4_PointKey(candidate.return_lane[candidate.return_lane.len() - 1]) == D4_PointKey(source_in);
		local start_heading = D4_DirectionBetween(candidate.return_lane[0], candidate.return_lane[1]);
		local end_heading = D4_DirectionBetween(candidate.return_lane[candidate.return_lane.len() - 2], candidate.return_lane[candidate.return_lane.len() - 1]);
		local start_heading_ok = start_heading == dest_manifest.manifest.loop_exit_heading;
		local end_heading_ok = end_heading == source_manifest.manifest.fan_entry_heading;
		local rail_buildable = D4_ValidateCenterlineCandidate(candidate.return_lane, plan.company_id, dest_manifest.manifest.loop_exit_heading);
		lane_diagnostics += "side=" + side_turns + ":" + D4_PointKey(candidate.return_lane[0]) + ">" + D4_PointKey(candidate.return_lane[candidate.return_lane.len() - 1]) + ":h=" + start_heading + ">" + end_heading + ":rail=" + rail_buildable + ";";
		if (start_ok && end_ok && start_heading_ok && end_heading_ok && rail_buildable) { returned = candidate; break; }
	}
	if (returned == null) {
		local path_diagnostics = D4_PathRunDiagnostics(outbound.path);
		return { ok = false, error = D4_Error("through_hub_paired_lane_endpoint_mismatch", lane_diagnostics + "path=" + path_diagnostics) };
	}
	if (!D4_AppendUniqueLaneOperations(ops, "outbound", outbound.path, null, null, emitted_rails)) return { ok = false, error = D4_Error("program_invalid_outbound", "") };
	if (!D4_AppendUniqueLaneOperations(ops, "return", returned.return_lane, null, null, emitted_rails)) return { ok = false, error = D4_Error("program_invalid_return", "") };
	local occupied = {};
	foreach (p0 in outbound.path) occupied[D4_PointKey(p0)] <- true;
	foreach (p1 in returned.return_lane) {
		local key = D4_PointKey(p1);
		if (key in occupied) return { ok = false, error = D4_Error("return_lane_self_crossing", key) };
		occupied[key] <- true;
	}
	D4_MarkBlueprintEnvelopeOccupied(occupied, plan.station_blueprint);
	D4_MarkBlueprintEnvelopeOccupied(occupied, plan.destination_blueprint);
	local depot = D4_DepotOperation(returned.return_lane, occupied, true, "exit_to_next");
	if (depot.ok) {
		ops.append(depot.access_op);
		ops.append(depot.op);
	}
	local signals_enabled = true;
	if (signals_enabled) {
		local signal_spacing = D4_ClampInt(D4_Has(plan.policy, "signal_spacing") ? plan.policy.signal_spacing : 8, 8, 4, 16);
		local excluded_signals = {};
		if (depot.ok) excluded_signals[depot.op.front] <- true;
		D4_AppendThroughHubEndpointSignals(ops, "source", source_manifest.manifest);
		D4_AppendThroughHubEndpointSignals(ops, "destination", dest_manifest.manifest);
		D4_AppendLaneSignals(ops, "source.inbound", source_manifest.inbound_path, 4, excluded_signals);
		D4_AppendLaneSignals(ops, "source.outbound", source_manifest.outbound_path, 4, excluded_signals);
		D4_AppendLaneSignals(ops, "destination.inbound", dest_manifest.inbound_path, 4, excluded_signals);
		D4_AppendLaneSignals(ops, "destination.outbound", dest_manifest.outbound_path, 4, excluded_signals);
		local outbound_signals = D4_AppendLaneSignals(ops, "outbound", outbound.path, signal_spacing, excluded_signals);
		local return_signals = D4_AppendLaneSignals(ops, "return", returned.return_lane, signal_spacing, excluded_signals);
		if (outbound.path.len() >= signal_spacing + 3 && outbound_signals < 1) return { ok = false, error = D4_Error("program_signal_spacing_unusable", "outbound") };
		if (returned.return_lane.len() >= signal_spacing + 3 && return_signals < 1) return { ok = false, error = D4_Error("program_signal_spacing_unusable", "return") };
	}
	local validation = D4_ValidateBuildProgram(ops);
	if (!validation.ok) return validation;
	local topology = {
		kind = "through_hub_roro",
		source = source_manifest.manifest,
		destination = dest_manifest.manifest,
		outbound = outbound.path,
		return_lane = returned.return_lane,
		curve_clearance_tiles = curve_clearance_relaxed ? 3 : turn_clearance,
		curve_clearance_relaxed = curve_clearance_relaxed,
		signals = D4_ProgramSignalManifest(ops),
	};
	/* Prove the emitted rail primitives collapse into a single-source fan and a
	 * single-sink merge before the plan is ever committed. Any regression to
	 * per-platform trunk identity fails here rather than in-game. */
	local reachability = D4_VerifyThroughHubRoroReachability(ops, topology);
	if (!reachability.ok) {
		local reason = reachability.failures.len() > 0 && D4_Has(reachability.failures[0], "reason") ? reachability.failures[0].reason : "reachability_unknown";
		return { ok = false, error = D4_Error("through_hub_reachability_broken", reason) };
	}
	return {
		ok = true,
		version = DIRECTORATE_M4_BUILD_PROGRAM_VERSION,
		fingerprint = D4_BoundedFingerprint({ topology = topology, count = ops.len(), source_out = source_out, dest_in = dest_in, dest_out = dest_out, source_in = source_in }),
		ops = ops,
		path = outbound.path,
		return_lane = returned.return_lane,
		topology = topology,
	};
}

function D4_AppendThroughHubEndpoint(ops, prefix, blueprint, common_inbound, common_outbound, company_id, policy, emitted_rails) {
	if (!D4_Has(blueprint, "ports") || !("platform_front" in blueprint.ports) || !("platform_rear" in blueprint.ports) || !("throat_sw" in blueprint.ports) || !("throat_ne" in blueprint.ports) || blueprint.ports.platform_front.len() != blueprint.ports.platform_rear.len() || blueprint.ports.platform_front.len() != blueprint.ports.throat_sw.len() || blueprint.ports.platform_rear.len() != blueprint.ports.throat_ne.len()) return { ok = false, error = D4_Error("through_hub_ports_missing", prefix) };
	local layout = D4_DeriveThroughHubEndpointLayout(blueprint);
	if (!layout.ok) return layout;
	local platform_count = layout.platform_count;
	if (platform_count < 2) return { ok = false, error = D4_Error("through_hub_platform_count", prefix) };
	local entries = [];
	local exits = [];
	for (local i = 0; i < platform_count; i++) {
		local front = layout.platform_front[i];
		local rear = layout.platform_rear[i];
		local entry = layout.throat_sw[i];
		local exitp = layout.throat_ne[i];
		local entry_dir = D4_DirectionBetween(entry, front);
		local exit_dir = D4_DirectionBetween(rear, exitp);
		if (entry_dir < 0 || exit_dir < 0) return { ok = false, error = D4_Error("through_hub_platform_heading", prefix + "." + i) };
		local fan = layout.fan_paths[i];
		local merge = layout.merge_paths[i];
		if (!D4_AppendUniqueLaneOperations(ops, prefix + ".fan." + i, fan, null, front, emitted_rails)) return { ok = false, error = D4_Error("through_hub_fan_invalid", prefix + "." + i) };
		if (!D4_AppendUniqueLaneOperations(ops, prefix + ".merge." + i, merge, rear, null, emitted_rails)) return { ok = false, error = D4_Error("through_hub_merge_invalid", prefix + "." + i) };
		entries.append({ platform = front, entry = entry, join = layout.join[i], path = fan });
		exits.append({ platform = rear, exit = exitp, join = layout.merge_join[i], path = merge });
	}
	if (!D4_AppendUniqueLaneOperations(ops, prefix + ".loop", layout.loop_path, null, null, emitted_rails)) return { ok = false, error = D4_Error("through_hub_loop_invalid", prefix) };
	return {
		ok = true,
		inbound_path = layout.fan_backbone,
		outbound_path = layout.loop_path,
		manifest = {
			common_inbound = common_inbound,
			common_outbound = common_outbound,
			common_rear_merge = layout.common_rear_merge,
			fan_backbone = layout.fan_backbone,
			merge_backbone = layout.merge_backbone,
			loop_path = layout.loop_path,
			loop_exit_heading = layout.loop_exit_heading,
			fan_entry_heading = layout.fan_entry_heading,
			platform_count = platform_count,
			platform_length = layout.platform_length,
			entries = entries,
			exits = exits,
		},
	};
}

function D4_RotateBlueprintPoint(blueprint, p) {
	local dx = p.x;
	local dy = p.y;
	local rx = dx;
	local ry = dy;
	local r = ((blueprint.rotation % 4) + 4) % 4;
	if (r == 1) { rx = -dy; ry = dx; }
	else if (r == 2) { rx = -dx; ry = -dy; }
	else if (r == 3) { rx = dy; ry = -dx; }
	return { x = blueprint.origin.x + rx, y = blueprint.origin.y + ry };
}

function D4_DeriveThroughHubEndpointLayout(blueprint) {
	local platform_count = blueprint.ports.throat_sw.len();
	local platform_length = abs(blueprint.ports.throat_ne[0].x - blueprint.ports.throat_sw[0].x) + abs(blueprint.ports.throat_ne[0].y - blueprint.ports.throat_sw[0].y) - 1;
	if (platform_length < 1) return { ok = false, error = D4_Error("through_hub_length_invalid", blueprint.name) };
	local common_inbound = D4_RotateBlueprintPoint(blueprint, { x = -platform_count - 2 - platform_length, y = -1 - platform_length });
	local common_outbound = D4_RotateBlueprintPoint(blueprint, { x = -platform_count - 2 - platform_length, y = -2 - platform_length });
	local common_rear_merge = D4_RotateBlueprintPoint(blueprint, { x = platform_length + platform_count, y = -1 });
	local platform_front = [], platform_rear = [], throat_sw = [], throat_ne = [], join = [], merge_join = [];
	local fan_paths = [], merge_paths = [];
	local fan_backbone = [];
	local merge_backbone = [];
	for (local i = 0; i < platform_count; i++) {
		platform_front.append(D4_RotateBlueprintPoint(blueprint, { x = 0, y = i }));
		platform_rear.append(D4_RotateBlueprintPoint(blueprint, { x = platform_length - 1, y = i }));
		throat_sw.append(D4_RotateBlueprintPoint(blueprint, { x = -1, y = i }));
		throat_ne.append(D4_RotateBlueprintPoint(blueprint, { x = platform_length, y = i }));
		join.append(D4_RotateBlueprintPoint(blueprint, { x = -platform_count - 1 + i, y = i }));
		merge_join.append(D4_RotateBlueprintPoint(blueprint, { x = platform_length + platform_count - 1 - i, y = i }));
	}
	D4_AppendPointIfNew(fan_backbone, common_inbound);
	for (local entry_step = platform_length - 1; entry_step >= 0; entry_step--) {
		D4_AppendPointIfNew(fan_backbone, D4_RotateBlueprintPoint(blueprint, { x = -platform_count - 2 - entry_step, y = -2 - entry_step }));
		D4_AppendPointIfNew(fan_backbone, D4_RotateBlueprintPoint(blueprint, { x = -platform_count - 2 - entry_step, y = -1 - entry_step }));
	}
	for (local b = 0; b < platform_count; b++) {
		if (b == 0) {
			D4_AppendPointIfNew(fan_backbone, D4_RotateBlueprintPoint(blueprint, { x = -platform_count - 1, y = -1 }));
			D4_AppendPointIfNew(fan_backbone, D4_RotateBlueprintPoint(blueprint, { x = -platform_count - 1, y = 0 }));
		} else {
			D4_AppendPointIfNew(fan_backbone, D4_RotateBlueprintPoint(blueprint, { x = -platform_count - 1 + b, y = b - 1 }));
			D4_AppendPointIfNew(fan_backbone, D4_RotateBlueprintPoint(blueprint, { x = -platform_count - 1 + b, y = b }));
		}
	}
	for (local m = platform_count - 1; m >= 0; m--) {
		if (m == platform_count - 1) D4_AppendPointIfNew(merge_backbone, merge_join[m]);
		if (m > 0) {
			D4_AppendPointIfNew(merge_backbone, D4_RotateBlueprintPoint(blueprint, { x = platform_length + platform_count - m, y = m }));
			D4_AppendPointIfNew(merge_backbone, D4_RotateBlueprintPoint(blueprint, { x = platform_length + platform_count - m, y = m - 1 }));
		} else {
			D4_AppendPointIfNew(merge_backbone, D4_RotateBlueprintPoint(blueprint, { x = platform_length + platform_count, y = 0 }));
			D4_AppendPointIfNew(merge_backbone, common_rear_merge);
		}
	}
	for (local row = 0; row < platform_count; row++) {
		local fan = [];
		for (local fi = 0; fi < fan_backbone.len(); fi++) {
			D4_AppendPointIfNew(fan, fan_backbone[fi]);
			if (D4_PointKey(fan_backbone[fi]) == D4_PointKey(join[row])) break;
		}
		for (local x = -platform_count + row; x <= -1; x++) D4_AppendPointIfNew(fan, D4_RotateBlueprintPoint(blueprint, { x = x, y = row }));
		fan_paths.append(fan);
		local merge = [];
		for (local mx = platform_length; mx <= platform_length + platform_count - 1 - row; mx++) D4_AppendPointIfNew(merge, D4_RotateBlueprintPoint(blueprint, { x = mx, y = row }));
		local on_backbone = false;
		for (local bi = 0; bi < merge_backbone.len(); bi++) {
			if (D4_PointKey(merge_backbone[bi]) == D4_PointKey(merge_join[row])) on_backbone = true;
			if (on_backbone) D4_AppendPointIfNew(merge, merge_backbone[bi]);
		}
		merge_paths.append(merge);
	}
	local loop_path = [common_rear_merge, D4_RotateBlueprintPoint(blueprint, { x = platform_length + platform_count, y = -2 })];
	for (local loop_step = 1; loop_step <= platform_length; loop_step++) {
		D4_AppendPointIfNew(loop_path, D4_RotateBlueprintPoint(blueprint, { x = platform_length + platform_count - loop_step, y = -1 - loop_step }));
		D4_AppendPointIfNew(loop_path, D4_RotateBlueprintPoint(blueprint, { x = platform_length + platform_count - loop_step, y = -2 - loop_step }));
	}
	for (local lx = platform_length + platform_count - platform_length - 1; lx >= -platform_count - 2 - platform_length; lx--) D4_AppendPointIfNew(loop_path, D4_RotateBlueprintPoint(blueprint, { x = lx, y = -2 - platform_length }));
	local loop_exit_heading = D4_DirectionBetween(loop_path[loop_path.len() - 2], common_outbound);
	local fan_entry_heading = fan_backbone.len() > 1 ? D4_DirectionBetween(common_inbound, fan_backbone[1]) : -1;
	if (loop_exit_heading < 0 || fan_entry_heading < 0) return { ok = false, error = D4_Error("through_hub_endpoint_heading_invalid", blueprint.name) };
	return { ok = true, platform_count = platform_count, platform_length = platform_length, common_inbound = common_inbound, common_outbound = common_outbound, common_rear_merge = common_rear_merge, platform_front = platform_front, platform_rear = platform_rear, throat_sw = throat_sw, throat_ne = throat_ne, join = join, merge_join = merge_join, fan_backbone = fan_backbone, merge_backbone = merge_backbone, loop_path = loop_path, loop_exit_heading = loop_exit_heading, fan_entry_heading = fan_entry_heading, fan_paths = fan_paths, merge_paths = merge_paths };
}

function D4_PathRunDiagnostics(path) {
	if (!D4_IsArray(path) || path.len() < 2) return "empty";
	local result = D4_PointKey(path[0]) + ":";
	local active = D4_DirectionBetween(path[0], path[1]);
	local run = 1;
	for (local i = 2; i < path.len(); i++) {
		local direction = D4_DirectionBetween(path[i - 1], path[i]);
		if (direction == active) { run++; continue; }
		result += active + "x" + run + ",";
		active = direction;
		run = 1;
	}
	return result + active + "x" + run + ":" + D4_PointKey(path[path.len() - 1]);
}

function D4_AppendPointIfNew(path, point) {
	if (path.len() > 0 && D4_PointKey(path[path.len() - 1]) == D4_PointKey(point)) return;
	path.append(point);
}

function D4_RailOpKey(prev, tile, next) {
	return prev + ":" + tile + ":" + next;
}

function D4_AppendUniqueLaneOperations(ops, prefix, path, entry_point, exit_point, emitted) {
	if (!D4_IsArray(path) || path.len() < 2) return false;
	for (local i = 0; i < path.len(); i++) {
		local prev = i > 0 ? path[i - 1] : (entry_point != null ? entry_point : D4_Offset(path[i], D4_RotateDir(D4_DirectionBetween(path[i], path[i + 1]), 2), 1));
		local next = i + 1 < path.len() ? path[i + 1] : (exit_point != null ? exit_point : D4_Offset(path[i], D4_DirectionBetween(path[i - 1], path[i]), 1));
		if (!D4_IsPointOnMap(prev) || !D4_IsPointOnMap(next) || !D4_IsLegalPrimitive(prev, path[i], next)) return false;
		local key = D4_RailOpKey(D4_ToTile(prev), D4_ToTile(path[i]), D4_ToTile(next));
		if (key in emitted) continue;
		emitted[key] <- true;
		ops.append({ op_id = "rail." + prefix + "." + i, kind = "rail_connection", tile = D4_ToTile(path[i]), point = path[i], prev = D4_ToTile(prev), prev_point = prev, next = D4_ToTile(next), next_point = next });
	}
	return true;
}

function D4_AppendThroughHubEndpointSignals(ops, prefix, manifest) {
	if (!D4_IsTable(manifest) || !D4_Has(manifest, "entries") || !D4_IsArray(manifest.entries) || !D4_Has(manifest, "exits") || !D4_IsArray(manifest.exits)) return 0;
	local count = 0;
	for (local i = 0; i < manifest.entries.len(); i++) {
		local entry = manifest.entries[i];
		if (!D4_Has(entry, "path") || !D4_IsArray(entry.path) || entry.path.len() < 1 || !D4_Has(entry, "platform")) continue;
		local tile_point = entry.path[entry.path.len() - 1];
		local front_point = entry.path.len() > 1 ? entry.path[entry.path.len() - 2] : D4_Offset(tile_point, D4_RotateDir(D4_DirectionBetween(tile_point, entry.platform), 2), 1);
		ops.append({ op_id = "signal." + prefix + ".entry." + i, kind = "signal", tile = D4_ToTile(tile_point), point = tile_point, front = D4_ToTile(front_point), front_point = front_point, signal_type = GSRail.SIGNALTYPE_PBS_ONEWAY });
		count++;
	}
	for (local j = 0; j < manifest.exits.len(); j++) {
		local exitp = manifest.exits[j];
		if (!D4_Has(exitp, "path") || !D4_IsArray(exitp.path) || exitp.path.len() < 1 || !D4_Has(exitp, "platform")) continue;
		local tile_point2 = exitp.path[0];
		ops.append({ op_id = "signal." + prefix + ".exit." + j, kind = "signal", tile = D4_ToTile(tile_point2), point = tile_point2, front = D4_ToTile(exitp.platform), front_point = exitp.platform, signal_type = GSRail.SIGNALTYPE_PBS_ONEWAY });
		count++;
	}
	return count;
}

function D4_ProgramSignalManifest(ops) {
	local signals = [];
	foreach (op in ops) {
		if (!D4_IsTable(op) || !D4_Has(op, "kind") || op.kind != "signal") continue;
		signals.append({ op_id = op.op_id, tile = op.tile, point = op.point, front = op.front, front_point = op.front_point, signal_type = op.signal_type });
	}
	return signals;
}

function D4_MarkBlueprintEnvelopeOccupied(occupied, blueprint) {
	if (occupied == null || !D4_IsTable(blueprint) || !D4_Has(blueprint, "required_clear") || !D4_IsArray(blueprint.required_clear)) return;
	foreach (point in blueprint.required_clear) occupied[D4_PointKey(point)] <- true;
}

/* Upgrade persisted v1 programs without rerunning the bounded A* planner.
 * Ready single-shuttle plans receive the same endpoint operands emitted by a
 * fresh v2 compile; terminal plans retain their historical operations. */
function D4_UpgradeBuildProgram(plan) {
	if (!D4_IsTable(plan) || !D4_Has(plan, "build_program") || !D4_IsTable(plan.build_program) || !plan.build_program.ok) return false;
	if (!D4_Has(plan, "revision") || typeof plan.revision != "integer" || plan.revision < 0 || !D4_Has(plan, "state") || typeof plan.state != "string") return false;
	local program = plan.build_program;
	if (!D4_Has(program, "version") || program.version != 1 || !D4_Has(program, "ops") || !D4_IsArray(program.ops) || !D4_Has(program, "path") || !D4_IsArray(program.path) || program.path.len() < 2) return false;
	if (D4_Has(program, "return_lane") && !D4_IsArray(program.return_lane)) return false;
	if (!D4_IsPointOnMap(program.path[0]) || !D4_IsPointOnMap(program.path[program.path.len() - 1])) return false;
	local source_entry = null;
	local destination_exit = null;
	local single_shuttle = D4_Has(plan, "station_blueprint") && D4_IsTable(plan.station_blueprint) && D4_Has(plan.station_blueprint, "name") && plan.station_blueprint.name == "single_shuttle_1xN";
	if (!single_shuttle) return false;
	if ((plan.state == "ready" || plan.state == "planning") && single_shuttle) {
		local last_index = program.path.len() + 1;
		if (program.path.len() < 2 || program.ops.len() <= last_index) return false;
		local source_station = program.ops[0];
		local destination_station = program.ops[1];
		local first_rail = program.ops[2];
		local last_rail = program.ops[last_index];
		if (!D4_IsTable(source_station) || !D4_IsTable(destination_station) || !D4_IsTable(first_rail) || !D4_IsTable(last_rail) || !D4_Has(source_station, "op_id") || !D4_Has(source_station, "tile") || !D4_Has(source_station, "point") || !D4_Has(destination_station, "op_id") || !D4_Has(destination_station, "tile") || !D4_Has(destination_station, "point") || !D4_Has(first_rail, "op_id") || !D4_Has(last_rail, "op_id")) return false;
		if (source_station.op_id != "source_station" || destination_station.op_id != "destination_station" || first_rail.op_id != "rail.outbound.0" || last_rail.op_id != "rail.outbound." + (program.path.len() - 1).tostring()) return false;
		source_entry = source_station.point;
		destination_exit = destination_station.point;
		first_rail.prev = source_station.tile;
		first_rail.prev_point = source_entry;
		last_rail.next = destination_station.tile;
		last_rail.next_point = destination_exit;
	}
	local previous_fingerprint = D4_Has(program, "fingerprint") && typeof program.fingerprint == "string" ? program.fingerprint : "v1";
	program.version = DIRECTORATE_M4_BUILD_PROGRAM_VERSION;
	/* Load() has a strict instruction budget. Revision fencing plus the prior
	 * fingerprint and rewritten endpoint operands identify this migration
	 * without recursively hashing the persisted path/return lane again. */
	program.fingerprint = D4_BoundedFingerprint({ previous = previous_fingerprint, version = DIRECTORATE_M4_BUILD_PROGRAM_VERSION, source = program.path[0], goal = program.path[program.path.len() - 1], source_entry = source_entry, destination_exit = destination_exit, count = program.ops.len() });
	return true;
}

function D4_SelectBestSitePair(source_candidates, destination_candidates, excluded = null) {
	local best = null;
	local best_score = null;
	local source_limit = source_candidates.len() < DIRECTORATE_M4_MAX_SITES ? source_candidates.len() : DIRECTORATE_M4_MAX_SITES;
	local destination_limit = destination_candidates.len() < DIRECTORATE_M4_MAX_SITES ? destination_candidates.len() : DIRECTORATE_M4_MAX_SITES;
	for (local si = 0; si < source_limit; si++) {
		for (local di = 0; di < destination_limit; di++) {
			local pair_key = si + ":" + di;
			if (excluded != null && pair_key in excluded) continue;
			local source = source_candidates[si];
			local destination = destination_candidates[di];
			local through_pair = D4_IsThroughHubBlueprint(source.blueprint) && D4_IsThroughHubBlueprint(destination.blueprint);
			local source_throat = through_pair ? D4_BlueprintPortLocation(source.blueprint, "common_outbound") : D4_BlueprintPortLocation(source.blueprint, "throat_ne");
			if (source_throat == null) source_throat = D4_BlueprintPortLocation(source.blueprint, "throat");
			local destination_throat = through_pair ? D4_BlueprintPortLocation(destination.blueprint, "common_inbound") : D4_BlueprintPortLocation(destination.blueprint, "throat_sw");
			if (destination_throat == null) destination_throat = D4_BlueprintPortLocation(destination.blueprint, "throat");
			if (source_throat == null || destination_throat == null) continue;
			local source_platform = through_pair ? D4_BlueprintPortLocation(source.blueprint, "common_inbound") : D4_NearestBlueprintPortPoint(source.blueprint, "platform_body", source_throat);
			local destination_platform = through_pair ? D4_BlueprintPortLocation(destination.blueprint, "common_outbound") : D4_NearestBlueprintPortPoint(destination.blueprint, "platform_body", destination_throat);
			if (source_platform == null || destination_platform == null) continue;
			local source_to_destination = D4_DominantDirection(source_throat, destination_throat);
			local destination_to_source = D4_DominantDirection(destination_throat, source_throat);
			local source_out = through_pair ? source_to_destination : D4_DirectionBetween(source_platform, source_throat);
			local destination_out = through_pair ? destination_to_source : D4_DirectionBetween(destination_platform, destination_throat);
			if (source_out < 0 || destination_out < 0 || source_to_destination < 0 || destination_to_source < 0) continue;
			local source_layout = null;
			local destination_layout = null;
			if (through_pair) {
				source_layout = D4_DeriveThroughHubEndpointLayout(source.blueprint);
				destination_layout = D4_DeriveThroughHubEndpointLayout(destination.blueprint);
				if (!source_layout.ok || !destination_layout.ok) continue;
				if (source_layout.loop_exit_heading != source_to_destination) continue;
				if (destination_layout.loop_exit_heading != destination_to_source) continue;
			}
			local distance = abs(destination_throat.x - source_throat.x) + abs(destination_throat.y - source_throat.y);
			local orientation_penalty = 0;
			if (through_pair) {
				local paired_ports = false;
				foreach (side_turns in [1, 3]) {
					local side = D4_RotateDir(source_to_destination, side_turns);
					if (D4_PointKey(D4_Offset(source_throat, side, 1)) == D4_PointKey(source_platform) && D4_PointKey(D4_Offset(destination_throat, side, 1)) == D4_PointKey(destination_platform)) paired_ports = true;
				}
				if (!paired_ports) continue;
			} else {
				if (source_out != source_to_destination) orientation_penalty += 100000;
				if (destination_out != destination_to_source) orientation_penalty += 100000;
			}
			local score = orientation_penalty + distance * 100 - source.score - destination.score + si + di;
			if (best == null || score < best_score) {
				best = { source = source, destination = destination, score = score, source_index = si, destination_index = di };
				best_score = score;
			}
		}
	}
	return best;
}

function D4_NearestBlueprintPortPoint(blueprint, port_name, target) {
	if (!D4_Has(blueprint, "ports") || !(port_name in blueprint.ports) || blueprint.ports[port_name].len() == 0) return null;
	local points = blueprint.ports[port_name];
	local best = points[0];
	local best_distance = abs(best.x - target.x) + abs(best.y - target.y);
	for (local i = 1; i < points.len(); i++) {
		local distance = abs(points[i].x - target.x) + abs(points[i].y - target.y);
		if (distance < best_distance) { best = points[i]; best_distance = distance; }
	}
	return best;
}

function D4_SelectLanePlatformEndpoint(blueprint, lane_tile, lane_neighbor, is_entry) {
	if (!D4_IsTable(blueprint) || !D4_Has(blueprint, "ports") || !("platform_body" in blueprint.ports)) return null;
	foreach (point in blueprint.ports.platform_body) {
		if (!D4_IsAdjacent(point, lane_tile)) continue;
		local legal = is_entry ? D4_IsLegalPrimitive(point, lane_tile, lane_neighbor) : D4_IsLegalPrimitive(lane_neighbor, lane_tile, point);
		if (legal) return point;
	}
	return null;
}

function D4_DominantDirection(from, to) {
	local dx = to.x - from.x;
	local dy = to.y - from.y;
	if (dx == 0 && dy == 0) return -1;
	if (abs(dx) >= abs(dy)) return dx >= 0 ? DIR_NE : DIR_SW;
	return dy >= 0 ? DIR_SE : DIR_NW;
}

function D4_StationRectOperation(op_id, blueprint, destination_station) {
	if (!D4_IsTable(blueprint) || !blueprint.ok) return { ok = false, error = D4_Error("invalid_station_blueprint", op_id) };
	/* A station rectangle is derived from station tiles only.  Blueprint throat,
	 * depot and reserve tiles are deliberately not part of this command. */
	local station_tiles = [];
	foreach (item in blueprint.tiles) if (item.kind == "station") station_tiles.append(item.point);
	if (station_tiles.len() == 0) return { ok = false, error = D4_Error("station_tiles_missing", op_id) };
	local min_x = station_tiles[0].x, max_x = min_x, min_y = station_tiles[0].y, max_y = min_y;
	foreach (p in station_tiles) { if (p.x < min_x) min_x = p.x; if (p.x > max_x) max_x = p.x; if (p.y < min_y) min_y = p.y; if (p.y > max_y) max_y = p.y; }
	local width = max_x - min_x + 1, height = max_y - min_y + 1;
	if (width * height != station_tiles.len() || width < 1 || height < 1 || width > DIRECTORATE_M4_MAX_STATION_SPREAD || height > DIRECTORATE_M4_MAX_STATION_SPREAD) return { ok = false, error = D4_Error("invalid_station_footprint", op_id) };
	local origin = { x = min_x, y = min_y }, endp = { x = max_x, y = max_y };
	local direction = width >= height ? GSRail.RAILTRACK_NE_SW : GSRail.RAILTRACK_NW_SE;
	local num_platforms = direction == GSRail.RAILTRACK_NE_SW ? height : width;
	local platform_length = direction == GSRail.RAILTRACK_NE_SW ? width : height;
	return { ok = true, op = { op_id = op_id, kind = "station_rect", tile = D4_ToTile(origin), point = origin, end_tile = D4_ToTile(endp), end_point = endp, direction = direction, num_platforms = num_platforms, platform_length = platform_length, destination_station = destination_station } };
}

function D4_HasBuildablePairedLane(path, company_id, expected_start = null, expected_end = null, expected_start_heading = -1, expected_end_heading = -1) {
	foreach (side_turns in [1, 3]) {
		local candidate = D4_DeriveProgramLanes(path, side_turns);
		if (!candidate.ok || candidate.return_lane.len() < 2) continue;
		local start_heading = D4_DirectionBetween(candidate.return_lane[0], candidate.return_lane[1]);
		local end_heading = D4_DirectionBetween(candidate.return_lane[candidate.return_lane.len() - 2], candidate.return_lane[candidate.return_lane.len() - 1]);
		if (expected_start != null && D4_PointKey(candidate.return_lane[0]) != D4_PointKey(expected_start)) continue;
		if (expected_end != null && D4_PointKey(candidate.return_lane[candidate.return_lane.len() - 1]) != D4_PointKey(expected_end)) continue;
		if (expected_start_heading >= 0 && start_heading != expected_start_heading) continue;
		if (expected_end_heading >= 0 && end_heading != expected_end_heading) continue;
		local validation_heading = expected_start_heading >= 0 ? expected_start_heading : start_heading;
		if (validation_heading >= 0 && D4_ValidateCenterlineCandidate(candidate.return_lane, company_id, validation_heading)) return true;
	}
	return false;
}

function D4_BuildTwoTurnCenterline(start, goal, company_id, heading, min_run, require_paired_lane = false, paired_start = null, paired_end = null, paired_start_heading = -1, paired_end_heading = -1) {
	local horizontal = heading == DIR_NE || heading == DIR_SW;
	local forward_delta = horizontal ? goal.x - start.x : goal.y - start.y;
	local forward_step = heading == DIR_NE || heading == DIR_SE ? 1 : -1;
	local cross_delta = horizontal ? goal.y - start.y : goal.x - start.x;
	local cross_span = abs(cross_delta);
	/* A true visual 45-degree transition is a staircase of alternating map-axis
	 * steps. A pure cross-axis run between forward runs draws a slowing 90. */
	if (forward_delta * forward_step < min_run * 2 + cross_span) return { ok = false, error = D4_Error("dogleg_forward_span", forward_delta.tostring()) };
	if (cross_delta != 0 && cross_span < min_run) return { ok = false, error = D4_Error("dogleg_cross_span", cross_delta.tostring()) };
	local forward_span = abs(forward_delta);
	for (local first_run = min_run; first_run <= forward_span - cross_span - min_run; first_run++) {
		local path = [start];
		local bend_value = (horizontal ? start.x : start.y) + forward_step * first_run;
		if (!D4_AppendAxisTo(path, horizontal ? "x" : "y", bend_value)) continue;
		if (!D4_AppendMiteredShift(path, horizontal, horizontal ? goal.y : goal.x, forward_step)) continue;
		if (!D4_AppendAxisTo(path, horizontal ? "x" : "y", horizontal ? goal.x : goal.y)) continue;
		if (D4_ValidateCenterlineCandidate(path, company_id, heading) && (!require_paired_lane || D4_HasBuildablePairedLane(path, company_id, paired_start, paired_end, paired_start_heading, paired_end_heading))) return { ok = true, path = path };
	}
	return { ok = false, error = D4_Error("dogleg_not_found", D4_PointKey(start) + "->" + D4_PointKey(goal)) };
}

function D4_AppendMiteredShift(path, horizontal, cross_target, forward_step) {
	if (!D4_IsArray(path) || path.len() < 1 || (forward_step != 1 && forward_step != -1)) return false;
	local guard = 0;
	while ((horizontal ? path[path.len() - 1].y : path[path.len() - 1].x) != cross_target && guard < 384) {
		local last = path[path.len() - 1];
		local cross = horizontal ? last.y : last.x;
		local cross_step = cross < cross_target ? 1 : -1;
		local shifted = { x = last.x, y = last.y };
		if (horizontal) shifted.y += cross_step; else shifted.x += cross_step;
		D4_AppendPointIfNew(path, shifted);
		local advanced = { x = shifted.x, y = shifted.y };
		if (horizontal) advanced.x += forward_step; else advanced.y += forward_step;
		D4_AppendPointIfNew(path, advanced);
		guard++;
	}
	return (horizontal ? path[path.len() - 1].y : path[path.len() - 1].x) == cross_target;
}

function D4_AppendAxisTo(path, axis, target) {
	if (!D4_IsArray(path) || path.len() < 1 || (axis != "x" && axis != "y")) return false;
	local guard = 0;
	while ((axis == "x" ? path[path.len() - 1].x : path[path.len() - 1].y) != target && guard < 384) {
		local last = path[path.len() - 1];
		local current = axis == "x" ? last.x : last.y;
		local next = { x = last.x, y = last.y };
		if (axis == "x") next.x = current < target ? current + 1 : current - 1;
		else next.y = current < target ? current + 1 : current - 1;
		D4_AppendPointIfNew(path, next);
		guard++;
	}
	return (axis == "x" ? path[path.len() - 1].x : path[path.len() - 1].y) == target;
}

function D4_ValidateCenterlineCandidate(path, company_id, required_heading) {
	if (!D4_IsArray(path) || path.len() < 2) return false;
	if (D4_DirectionBetween(path[0], path[1]) != required_heading || D4_DirectionBetween(path[path.len() - 2], path[path.len() - 1]) != required_heading) return false;
	for (local i = 0; i < path.len(); i++) {
		local prev = i > 0 ? path[i - 1] : D4_Offset(path[i], D4_RotateDir(required_heading, 2), 1);
		local next = i + 1 < path.len() ? path[i + 1] : D4_Offset(path[i], required_heading, 1);
		if (!D4_IsPointOnMap(prev) || !D4_IsPointOnMap(next) || !D4_IsLegalPrimitive(prev, path[i], next) || !D4_TestProgramRailPiece(prev, path[i], next, company_id)) return false;
	}
	return true;
}

function D4_BuildLegalCenterline(start, goal, company_id, policy, required_start_dir = -1, required_goal_dir = -1, max_turns = -1, turn_cost_override = -1, min_turn_run = 0, require_paired_lane = false, paired_start = null, paired_end = null, paired_start_heading = -1, paired_end_heading = -1) {
	/* Paired RoRo endpoints normally face the same cardinal direction. Test the
	 * complete bounded family of two-turn doglegs first: unlike generic A*, this
	 * guarantees enough straight approach at both ends for a parallel mitered
	 * lane and costs only O(distance squared) test-mode rail probes. */
	if (min_turn_run > 0 && required_start_dir >= 0 && required_start_dir == required_goal_dir) {
		local dogleg = D4_BuildTwoTurnCenterline(start, goal, company_id, required_start_dir, min_turn_run, require_paired_lane, paired_start, paired_end, paired_start_heading, paired_end_heading);
		if (dogleg.ok) return dogleg;
		/* Reserve the final straight before generic search. The unconstrained A*
		 * previously reached the goal with a one-tile corrective miter; routing to
		 * a shifted approach point makes the required terminal run structural. */
		local approach = D4_Offset(goal, D4_RotateDir(required_goal_dir, 2), min_turn_run);
		if (!D4_IsPointOnMap(approach)) return dogleg;
		local prefix = D4_BuildLegalCenterline(start, approach, company_id, policy, required_start_dir, required_goal_dir, max_turns, turn_cost_override, 0, false);
		if (!prefix.ok) return prefix;
		local combined = [];
		foreach (point in prefix.path) D4_AppendPointIfNew(combined, point);
		for (local tail = min_turn_run - 1; tail >= 0; tail--) D4_AppendPointIfNew(combined, D4_Offset(goal, D4_RotateDir(required_goal_dir, 2), tail));
		if (!D4_ValidateCenterlineCandidate(combined, company_id, required_goal_dir)) return { ok = false, error = D4_Error("approach_extension_unbuildable", D4_PointKey(approach)) };
		if (require_paired_lane && !D4_HasBuildablePairedLane(combined, company_id, paired_start, paired_end, paired_start_heading, paired_end_heading)) return { ok = false, error = D4_Error("paired_extension_unbuildable", D4_PointKey(approach)) };
		return { ok = true, path = combined };
	}
	/* Bounded clean-room A* adapted from the accepted M2 planner. Every
	 * candidate primitive is tested by OpenTTD; no client-supplied path is
	 * accepted and no map mutation occurs. */
	local max_len = D4_ClampInt(D4_Has(policy, "path_limit") ? policy.path_limit : 160, 160, 8, 384);
	local expansion_limit = D4_ClampInt(D4_Has(policy, "route_expansion_limit") ? policy.route_expansion_limit : 768, 768, 32, 32768);
	local frontier_limit = D4_ClampInt(D4_Has(policy, "route_frontier_limit") ? policy.route_frontier_limit : 4096, 4096, 128, 32768);
	local initial_dir = required_start_dir >= 0 ? required_start_dir : (abs(goal.x - start.x) >= abs(goal.y - start.y) ? (goal.x >= start.x ? DIR_NE : DIR_SW) : (goal.y >= start.y ? DIR_SE : DIR_NW));
	local initial_h = (abs(goal.x - start.x) + abs(goal.y - start.y)) * 10;
	local track_run_state = min_turn_run > 0;
	local track_turn_state = max_turns >= 0;
	local seed = { point = start, dir = initial_dir, g = 0, cost = initial_h, index = 0, parent_index = -1, steps = 0, turns = 0, run = 0 };
	local route_turn_cost = turn_cost_override >= 0 ? D4_ClampInt(turn_cost_override, 5, 0, 100) : D4_ClampInt(D4_Has(policy, "route_turn_cost") ? policy.route_turn_cost : 5, 5, 0, 100);
	local frontier = [seed];
	local nodes = [seed];
	local visited = {};
	local best_g = {};
	best_g[D4_PointKey(start) + ":" + initial_dir + (track_run_state ? ":r0" : "") + (track_turn_state ? ":t0" : "")] <- 0;
	local expansions = 0;
	local rejected_bounds = 0;
	local rejected_primitive = 0;
	local rejected_rail = 0;
	local rejected_endpoint = 0;
	while (frontier.len() > 0 && expansions < expansion_limit) {
		local node = D4_ProgramPopBest(frontier);
		local run_state = min_turn_run > 0 && node.run < min_turn_run ? node.run : min_turn_run;
		local key = D4_PointKey(node.point) + ":" + node.dir + (track_run_state ? ":r" + run_state : "") + (track_turn_state ? ":t" + node.turns : "");
		if (key in visited) continue;
		visited[key] <- true;
		expansions++;
		if (node.point.x == goal.x && node.point.y == goal.y && (min_turn_run <= 0 || node.run >= min_turn_run)) return D4_ProgramReconstruct(nodes, node, max_len);
		if (node.steps >= max_len) continue;
		local dirs = D4_ProgramDirections(node.dir, node.point, goal);
		foreach (dir in dirs) {
			local turning = dir != node.dir;
			if (node.steps == 0 && required_start_dir >= 0 && dir != required_start_dir) continue;
			if (dir == D4_RotateDir(node.dir, 2)) continue;
			if (max_turns >= 0 && turning && node.turns >= max_turns) continue;
			if (turning && min_turn_run > 0 && node.run < min_turn_run) continue;
			local next = D4_Offset(node.point, dir, 1);
			if (!D4_IsPointOnMap(next) || !GSMap.IsValidTile(D4_ToTile(next))) { rejected_bounds++; continue; }
			local child_turns = node.turns + (turning ? 1 : 0);
			local child_run = turning ? 1 : node.run + 1;
			local child_run_state = min_turn_run > 0 && child_run < min_turn_run ? child_run : min_turn_run;
			local nkey = D4_PointKey(next) + ":" + dir + (track_run_state ? ":r" + child_run_state : "") + (track_turn_state ? ":t" + child_turns : "");
			if (nkey in visited) continue;
			local prev = node.parent_index >= 0 ? nodes[node.parent_index].point : D4_Offset(node.point, D4_RotateDir(dir, 2), 1);
			if (!D4_IsPointOnMap(prev) || !D4_IsLegalPrimitive(prev, node.point, next)) { rejected_primitive++; continue; }
			if (!D4_TestProgramRailPiece(prev, node.point, next, company_id)) { rejected_rail++; continue; }
			if (next.x == goal.x && next.y == goal.y) {
				if (required_goal_dir >= 0 && dir != required_goal_dir) { rejected_endpoint++; continue; }
				local continuation = D4_Offset(next, dir, 1);
				if (!D4_IsPointOnMap(continuation) || !D4_TestProgramRailPiece(node.point, next, continuation, company_id)) { rejected_endpoint++; continue; }
			}
			local turn_cost = dir == node.dir ? 0 : route_turn_cost;
			local heuristic = (abs(goal.x - next.x) + abs(goal.y - next.y)) * 10;
			/* Keep the accumulated path cost separate from the heuristic. Adding the
			 * heuristic to node.cost on every generation compounds it once per hop,
			 * turning A* into a strongly greedy search that exhausts its bounded
			 * frontier on otherwise trivial routes. */
			local child_g = node.g + 10 + turn_cost;
			/* Do not let multiple worse paths to the same directed/run state consume
			 * the bounded node budget before the best candidate is popped. */
			if (nkey in best_g && best_g[nkey] <= child_g) continue;
			best_g[nkey] <- child_g;
			if (nodes.len() >= frontier_limit) continue;
			local child = { point = next, dir = dir, g = child_g, cost = child_g + heuristic, index = nodes.len(), parent_index = node.index, steps = node.steps + 1, turns = child_turns, run = child_run };
			nodes.append(child);
			D4_ProgramPushBest(frontier, child);
		}
	}
	return { ok = false, error = D4_Error("route_not_found", start.x + "," + start.y + "->" + goal.x + "," + goal.y + ":e=" + expansions + ":n=" + nodes.len() + ":b=" + rejected_bounds + ":p=" + rejected_primitive + ":r=" + rejected_rail + ":z=" + rejected_endpoint) };
}

function D4_TestProgramRailPiece(prev, tile, next, company_id) {
	if (!D4_IsPointOnMap(prev) || !D4_IsPointOnMap(tile) || !D4_IsPointOnMap(next)) return false;
	local mode = GSCompanyMode(company_id);
	if (!GSCompanyMode.IsValid() || !D4_SelectRailType()) return false;
	local tm = GSTestMode();
	return GSRail.BuildRail(D4_ToTile(prev), D4_ToTile(tile), D4_ToTile(next));
}

function D4_ProgramDirections(current, point, goal) {
	local raw = [];
	if (goal.x >= point.x) raw.append(DIR_NE); else raw.append(DIR_SW);
	if (goal.y >= point.y) raw.append(DIR_SE); else raw.append(DIR_NW);
	raw.append(current);
	raw.append(D4_LeftDir(current));
	raw.append(D4_RightDir(current));
	local dirs = [];
	foreach (dir in raw) {
		local duplicate = false;
		foreach (seen in dirs) if (seen == dir) duplicate = true;
		if (!duplicate) dirs.append(dir);
	}
	return dirs;
}

function D4_ProgramNodeBefore(a, b) {
	return a.cost < b.cost || (a.cost == b.cost && (a.point.x < b.point.x || (a.point.x == b.point.x && (a.point.y < b.point.y || (a.point.y == b.point.y && a.dir < b.dir)))));
}

function D4_ProgramPushBest(frontier, node) {
	frontier.append(node);
	local index = frontier.len() - 1;
	while (index > 0) {
		local parent_index = (index - 1) / 2;
		if (!D4_ProgramNodeBefore(frontier[index], frontier[parent_index])) break;
		local swap = frontier[parent_index];
		frontier[parent_index] = frontier[index];
		frontier[index] = swap;
		index = parent_index;
	}
}

function D4_ProgramPopBest(frontier) {
	local value = frontier[0];
	local last = frontier[frontier.len() - 1];
	frontier.remove(frontier.len() - 1);
	if (frontier.len() == 0) return value;
	frontier[0] = last;
	local index = 0;
	local heap_guard = 0;
	while (index < frontier.len() && heap_guard < 64) {
		heap_guard++;
		local left = index * 2 + 1;
		if (left >= frontier.len()) break;
		local right = left + 1;
		local best = left;
		if (right < frontier.len() && D4_ProgramNodeBefore(frontier[right], frontier[left])) best = right;
		if (!D4_ProgramNodeBefore(frontier[best], frontier[index])) break;
		local swap = frontier[index];
		frontier[index] = frontier[best];
		frontier[best] = swap;
		index = best;
	}
	return value;
}

function D4_ProgramReconstruct(nodes, node, max_len) {
	local rev = [];
	local cursor = node.index;
	local guard = 0;
	while (cursor >= 0 && cursor < nodes.len() && guard <= max_len) {
		rev.append(nodes[cursor].point);
		cursor = nodes[cursor].parent_index;
		guard++;
	}
	local path = [];
	for (local i = rev.len() - 1; i >= 0; i--) path.append(rev[i]);
	if (path.len() < 2) return { ok = false, error = D4_Error("route_reconstruct_failed", "") };
	return { ok = true, path = path };
}

function D4_ProgramLaneAppend(lane, point) {
	if (lane.len() > 0 && D4_PointKey(lane[lane.len() - 1]) == D4_PointKey(point)) return;
	lane.append(point);
}

function D4_DeriveProgramLanes(path, side_turns = 1) {
	/* Adapted from accepted M2's mitered corridor construction.  A simple
	 * perpendicular offset breaks at corners; the miter inserts the turn cells
	 * needed for a real adjacent rail path. */
	if (!D4_IsArray(path) || path.len() < 2) return { ok = false, error = D4_Error("invalid_centerline", "") };
	local lane = [];
	for (local i = 0; i < path.len(); i++) {
		local incoming = i == 0 ? D4_DirectionBetween(path[0], path[1]) : D4_DirectionBetween(path[i - 1], path[i]);
		local outgoing = i + 1 == path.len() ? incoming : D4_DirectionBetween(path[i], path[i + 1]);
		if (incoming < 0 || outgoing < 0 || outgoing == D4_RotateDir(incoming, 2)) return { ok = false, error = D4_Error("invalid_centerline_turn", i.tostring()) };
		local side_in = D4_RotateDir(incoming, side_turns);
		local side_out = D4_RotateDir(outgoing, side_turns);
		if (incoming == outgoing) {
			D4_ProgramLaneAppend(lane, D4_Offset(path[i], side_in, 1));
		} else {
			local inside = outgoing == side_in;
			if (!inside) D4_ProgramLaneAppend(lane, D4_Offset(path[i], side_in, 1));
			D4_ProgramLaneAppend(lane, D4_Offset(D4_Offset(path[i], side_in, 1), side_out, 1));
			if (!inside) D4_ProgramLaneAppend(lane, D4_Offset(path[i], side_out, 1));
		}
	}
	local seen = {};
	foreach (p0 in path) seen[D4_PointKey(p0)] <- true;
	for (local j = 0; j < lane.len(); j++) {
		if (!D4_IsPointOnMap(lane[j])) return { ok = false, error = D4_Error("return_lane_out_of_map", j.tostring()) };
		if (D4_PointKey(lane[j]) in seen) return { ok = false, error = D4_Error("return_lane_overlap", j.tostring()) };
		if (j > 0 && !D4_IsAdjacent(lane[j - 1], lane[j])) return { ok = false, error = D4_Error("return_lane_non_adjacent", j.tostring()) };
	}
	local reverse = [];
	for (local k = lane.len() - 1; k >= 0; k--) reverse.append(lane[k]);
	return { ok = true, return_lane = reverse };
}

function D4_AppendLaneOperations(ops, prefix, path, entry_point, exit_point) {
	if (!D4_IsArray(path) || path.len() < 2) return false;
	for (local i = 0; i < path.len(); i++) {
		local prev = i > 0 ? path[i - 1] : (entry_point != null ? entry_point : D4_Offset(path[i], D4_RotateDir(D4_DirectionBetween(path[i], path[i + 1]), 2), 1));
		local next = i + 1 < path.len() ? path[i + 1] : (exit_point != null ? exit_point : D4_Offset(path[i], D4_DirectionBetween(path[i - 1], path[i]), 1));
		if (!D4_IsPointOnMap(prev) || !D4_IsPointOnMap(next) || !D4_IsLegalPrimitive(prev, path[i], next)) return false;
		ops.append({ op_id = "rail." + prefix + "." + i, kind = "rail_connection", tile = D4_ToTile(path[i]), point = path[i], prev = D4_ToTile(prev), prev_point = prev, next = D4_ToTile(next), next_point = next });
	}
	return true;
}

function D4_DepotOperation(path, occupied = null, prefer_tail = false, access_mode = "join_from_prev") {
	if (!D4_IsArray(path) || path.len() < 8) return { ok = false };
	/* Put the siding on a proven straight run with clearance on both sides of
	 * the junction. The old fixed path[2] placement could sit immediately after
	 * a centerline turn; trains then oscillated between depot and mouth despite
	 * successful static rail readback. */
	local first = prefer_tail ? path.len() - 3 : 4;
	local last = prefer_tail ? 4 : path.len() - 3;
	local step = prefer_tail ? -1 : 1;
	for (local i = first; (prefer_tail ? i >= last : i <= last); i += step) {
		local prev2 = path[i - 2];
		local a = path[i - 1];
		local front = path[i];
		local next = path[i + 1];
		local dir = D4_DirectionBetween(a, front);
		if (dir < 0 || D4_DirectionBetween(prev2, a) != dir || D4_DirectionBetween(front, next) != dir) continue;
		local sides = [D4_RightDir(dir), D4_RotateDir(D4_RightDir(dir), 2)];
		foreach (side in sides) {
			local depot_point = D4_Offset(front, side, 1);
			if (!D4_IsPointOnMap(depot_point)) continue;
			if (occupied != null && D4_PointKey(depot_point) in occupied) continue;
			local access_prev = a;
			local access_next = depot_point;
			if (access_mode == "exit_to_next") {
				access_prev = depot_point;
				access_next = next;
			}
			if (!D4_IsLegalPrimitive(access_prev, front, access_next)) continue;
			local access_op = { op_id = "rail.depot_access.0", kind = "rail_connection", tile = D4_ToTile(front), point = front, prev = D4_ToTile(access_prev), prev_point = access_prev, next = D4_ToTile(access_next), next_point = access_next };
			return { ok = true, access_op = access_op, op = { op_id = "depot.0", kind = "depot", tile = D4_ToTile(depot_point), point = depot_point, front = D4_ToTile(front), front_point = front } };
		}
	}
	return { ok = false };
}

function D4_ValidateBuildProgram(ops) {
	if (!D4_IsArray(ops) || ops.len() < 1 || ops.len() > DIRECTORATE_M4_MAX_OPERATION_ENTRIES) return { ok = false, error = D4_Error("invalid_program_size", "") };
	local station_count = 0;
	local seen = {};
	local map_area = GSMap.GetMapSizeX() * GSMap.GetMapSizeY();
	foreach (op in ops) {
		if (!D4_IsTable(op) || !("kind" in op) || typeof op.kind != "string" || !("op_id" in op) || typeof op.op_id != "string" || op.op_id.len() < 1 || op.op_id.len() > 128 || !("tile" in op) || typeof op.tile != "integer" || op.tile < 0 || op.tile >= map_area) return { ok = false, error = D4_Error("invalid_program_operation", "") };
		if (op.kind == "station_rect") {
			if (!("end_tile" in op) || typeof op.end_tile != "integer" || op.end_tile < 0 || op.end_tile >= map_area || !("direction" in op) || typeof op.direction != "integer" || !("num_platforms" in op) || typeof op.num_platforms != "integer" || op.num_platforms < 1 || !("platform_length" in op) || typeof op.platform_length != "integer" || op.platform_length < 1 || !("destination_station" in op) || typeof op.destination_station != "integer") return { ok = false, error = D4_Error("invalid_station_operation", op.op_id) };
			station_count++;
		}
		else if (op.kind == "rail_connection") {
			if (!("prev" in op) || typeof op.prev != "integer" || op.prev < 0 || op.prev >= map_area || !("next" in op) || typeof op.next != "integer" || op.next < 0 || op.next >= map_area) return { ok = false, error = D4_Error("invalid_rail_connection", op.op_id) };
		} else if (op.kind == "depot") {
			if (!("front" in op) || typeof op.front != "integer" || op.front < 0 || op.front >= map_area || op.front == op.tile) return { ok = false, error = D4_Error("invalid_depot_front", op.op_id) };
		} else if (op.kind == "signal") {
			if (!("front" in op) || typeof op.front != "integer" || op.front < 0 || op.front >= map_area || !("signal_type" in op) || typeof op.signal_type != "integer") return { ok = false, error = D4_Error("invalid_signal_front", op.op_id) };
		} else return { ok = false, error = D4_Error("unknown_program_operation", op.kind) };
		local key = op.kind == "station_rect" ? "station:" + op.tile : op.kind + ":" + op.tile;
		if (key in seen && op.kind != "rail_connection") return { ok = false, error = D4_Error("program_overlap", key) };
		seen[key] <- true;
	}
	if (station_count != 2) return { ok = false, error = D4_Error("program_station_count", station_count.tostring()) };
	return { ok = true };
}

function D4_PreflightBuildProgram(program, company_id, reserve, enforce_funds = true) {
	local cost = 0;
	local mode = GSCompanyMode(company_id);
	if (!GSCompanyMode.IsValid()) return { ok = false, error = D4_Error("invalid_company", company_id.tostring()) };
	if (!D4_SelectRailType()) return { ok = false, error = D4_Error("rail_type_unavailable", company_id.tostring()) };
	local tm = GSTestMode();
	local tested_rails = {};
	foreach (op in program.ops) {
		/* GSTestMode validates each command without retaining prior mutations.
		 * A signal planned on rail from this same transaction therefore cannot
		 * be tested with BuildSignal yet; its rail primitive was already tested,
		 * and commit performs authoritative signal readback after creating it. */
		if (op.kind == "signal" && op.tile in tested_rails && !GSRail.IsRailTile(op.tile)) {
			cost += GSRail.GetBuildCost(GSRail.GetCurrentRailType(), GSRail.BT_SIGNAL);
			if (enforce_funds && !D4_CanAfford(company_id, reserve, cost)) return { ok = false, error = D4_Error("insufficient_funds", op.op_id), failed_op = op.op_id, cost = cost, reserve = reserve, mutation = false };
			continue;
		}
		local result = D4_ExecuteProgramOperation(op, company_id, true);
		if (!result.ok) return { ok = false, error = D4_Error("preflight_failed", op.op_id), failed_op = op.op_id, failure = result.failure, cost = cost, mutation = false };
		cost += result.cost;
		if (op.kind == "rail_connection") tested_rails[op.tile] <- true;
		if (enforce_funds && !D4_CanAfford(company_id, reserve, cost)) return { ok = false, error = D4_Error("insufficient_funds", op.op_id), failed_op = op.op_id, cost = cost, reserve = reserve, mutation = false };
	}
	return { ok = true, cost = cost, reserve = reserve, affordable = D4_CanAfford(company_id, reserve, cost), mutation = false };
}

function D4_ExecuteProgramOperation(op, company_id, test_only) {
	if (op.kind == "station_rect") {
		if (GSRail.IsRailStationTile(op.tile) && GSTile.GetOwner(op.tile) == company_id) return { ok = true, reused = true, cost = 0, detail = D4_ReadbackProgramOperation(op, company_id, "station") };
		if (!GSRail.BuildRailStation(op.tile, op.direction, op.num_platforms, op.platform_length, op.destination_station)) return { ok = false, failure = { reason = "station_build_failed", op_id = op.op_id, tile = op.tile } };
		return { ok = true, reused = false, cost = GSRail.GetBuildCost(GSRail.GetCurrentRailType(), GSRail.BT_STATION), detail = D4_ReadbackProgramOperation(op, company_id, "station") };
	}
	if (op.kind == "rail_connection") {
		if (GSRail.AreTilesConnected(op.prev, op.tile, op.next) && GSTile.GetOwner(op.tile) == company_id) return { ok = true, reused = true, cost = 0, detail = D4_ReadbackProgramOperation(op, company_id, "rail") };
		if (!GSRail.BuildRail(op.prev, op.tile, op.next)) return { ok = false, failure = { reason = "rail_build_failed", op_id = op.op_id, tile = op.tile, prev = op.prev, next = op.next } };
		if (!test_only && !GSRail.AreTilesConnected(op.prev, op.tile, op.next)) return { ok = false, failure = { reason = "rail_readback_failed", op_id = op.op_id, tile = op.tile } };
		return { ok = true, reused = false, cost = GSRail.GetBuildCost(GSRail.GetCurrentRailType(), GSRail.BT_TRACK), detail = D4_ReadbackProgramOperation(op, company_id, "rail") };
	}
	if (op.kind == "depot") {
		if (GSRail.IsRailDepotTile(op.tile) && GSTile.GetOwner(op.tile) == company_id && GSRail.GetRailDepotFrontTile(op.tile) == op.front) return { ok = true, reused = true, cost = 0, detail = D4_ReadbackProgramOperation(op, company_id, "depot") };
		if (!GSRail.BuildRailDepot(op.tile, op.front)) return { ok = false, failure = { reason = "depot_build_failed", op_id = op.op_id, tile = op.tile, front = op.front } };
		if (!test_only && (!GSRail.IsRailDepotTile(op.tile) || GSRail.GetRailDepotFrontTile(op.tile) != op.front)) return { ok = false, failure = { reason = "depot_readback_failed", op_id = op.op_id, tile = op.tile } };
		return { ok = true, reused = false, cost = GSRail.GetBuildCost(GSRail.GetCurrentRailType(), GSRail.BT_DEPOT), detail = D4_ReadbackProgramOperation(op, company_id, "depot") };
	}
	if (op.kind == "signal") {
		if (GSRail.GetSignalType(op.tile, op.front) == op.signal_type) return { ok = true, reused = true, cost = 0, detail = D4_ReadbackProgramOperation(op, company_id, "signal") };
		if (!GSRail.BuildSignal(op.tile, op.front, op.signal_type)) return { ok = false, failure = { reason = "signal_build_failed", op_id = op.op_id, tile = op.tile, front = op.front } };
		if (!test_only && GSRail.GetSignalType(op.tile, op.front) != op.signal_type) return { ok = false, failure = { reason = "signal_readback_failed", op_id = op.op_id, tile = op.tile } };
		return { ok = true, reused = false, cost = GSRail.GetBuildCost(GSRail.GetCurrentRailType(), GSRail.BT_SIGNAL), detail = D4_ReadbackProgramOperation(op, company_id, "signal") };
	}
	return { ok = false, failure = { reason = "unknown_program_operation", kind = op.kind } };
}

function D4_ReadbackProgramOperation(op, company_id, rollback_kind) {
	local detail = { kind = rollback_kind, op_id = op.op_id };
	if (op.kind == "station_rect") {
		detail.station_end <- op.end_tile;
		detail.direction <- op.direction;
		detail.num_platforms <- op.num_platforms;
		detail.platform_length <- op.platform_length;
	}
	if (op.kind == "rail_connection") {
		detail.prev <- op.prev;
		detail.next <- op.next;
	}
	if (op.kind == "depot") detail.front <- op.front;
	if (op.kind == "signal") {
		detail.front <- op.front;
		detail.signal_type <- op.signal_type;
	}
	return detail;
}

function D4_PointInStationRect(point, station) {
	if (!D4_IsTable(point) || !D4_IsTable(station) || !D4_Has(station, "point") || !D4_Has(station, "end_point")) return false;
	local min_x = station.point.x < station.end_point.x ? station.point.x : station.end_point.x;
	local max_x = station.point.x > station.end_point.x ? station.point.x : station.end_point.x;
	local min_y = station.point.y < station.end_point.y ? station.point.y : station.end_point.y;
	local max_y = station.point.y > station.end_point.y ? station.point.y : station.end_point.y;
	return point.x >= min_x && point.x <= max_x && point.y >= min_y && point.y <= max_y;
}

function D4_VerifyProgramTopology(program, company_id) {
	local failures = [];
	local stations = [];
	local rails = [];
	foreach (op in program.ops) {
		if (op.kind == "station_rect") {
			stations.append(op);
			if (!GSRail.IsRailStationTile(op.tile) || GSTile.GetOwner(op.tile) != company_id) failures.append({ op_id = op.op_id, reason = "station_missing", tile = op.tile });
		} else if (op.kind == "rail_connection") {
			rails.append(op);
			if (!GSRail.AreTilesConnected(op.prev, op.tile, op.next)) failures.append({ op_id = op.op_id, reason = "rail_disconnected", tile = op.tile, prev = op.prev, next = op.next });
		} else if (op.kind == "depot" && (!GSRail.IsRailDepotTile(op.tile) || GSRail.GetRailDepotFrontTile(op.tile) != op.front)) failures.append({ op_id = op.op_id, reason = "depot_mismatch", tile = op.tile, front = op.front });
		else if (op.kind == "signal" && GSRail.GetSignalType(op.tile, op.front) != op.signal_type) failures.append({ op_id = op.op_id, reason = "signal_mismatch", tile = op.tile, front = op.front });
	}
	if (D4_Has(program, "topology") && D4_IsTable(program.topology) && D4_Has(program.topology, "kind") && program.topology.kind == "through_hub_roro") {
		local source = D4_VerifyThroughHubEndpointTopology(program.topology.source, "source");
		if (!source.ok) {
			foreach (f in source.failures) failures.append(f);
		}
		local destination = D4_VerifyThroughHubEndpointTopology(program.topology.destination, "destination");
		if (!destination.ok) {
			foreach (f2 in destination.failures) failures.append(f2);
		}
		local trunks = D4_VerifyThroughHubTrunks(program.topology);
		if (!trunks.ok) {
			foreach (f3 in trunks.failures) failures.append(f3);
		}
		local reachability = D4_VerifyThroughHubRoroReachability(program.ops, program.topology);
		if (!reachability.ok) {
			foreach (f4 in reachability.failures) failures.append(f4);
		}
		return { ok = failures.len() == 0, failures = failures, source = source, destination = destination, trunks = trunks, reachability = reachability };
	}

	/* A route is not topologically complete merely because its stations and
	 * internal rail primitives exist. Prove each station endpoint participates
	 * in an engine-confirmed rail primitive at the throat. */
	local station_connections = [];
	foreach (station in stations) {
		local connected = false;
		local rail_op_id = null;
		foreach (rail in rails) {
			if (D4_Has(rail, "prev_point") && D4_PointInStationRect(rail.prev_point, station) && GSRail.AreTilesConnected(rail.prev, rail.tile, rail.next)) {
				connected = true;
				rail_op_id = rail.op_id;
				break;
			}
			if (D4_Has(rail, "next_point") && D4_PointInStationRect(rail.next_point, station) && GSRail.AreTilesConnected(rail.prev, rail.tile, rail.next)) {
				connected = true;
				rail_op_id = rail.op_id;
				break;
			}
		}
		station_connections.append({ station_op_id = station.op_id, station_tile = station.tile, rail_op_id = rail_op_id, connected = connected });
		if (!connected) failures.append({ op_id = station.op_id, reason = "station_not_connected", tile = station.tile });
	}
	return { ok = failures.len() == 0, failures = failures, station_connections = station_connections };
}

function D4_IsSafeThroughHubTopology(topology) {
	if (!D4_IsTable(topology) || !D4_Has(topology, "kind") || topology.kind != "through_hub_roro") return false;
	if (!D4_Has(topology, "source") || !D4_Has(topology, "destination") || !D4_Has(topology, "outbound") || !D4_Has(topology, "return_lane") || !D4_Has(topology, "signals")) return false;
	if (!D4_IsSafeThroughHubEndpoint(topology.source) || !D4_IsSafeThroughHubEndpoint(topology.destination)) return false;
	return D4_IsSafePointPath(topology.outbound, 2, DIRECTORATE_M4_MAX_OPERATION_ENTRIES) && D4_IsSafePointPath(topology.return_lane, 2, DIRECTORATE_M4_MAX_OPERATION_ENTRIES) && D4_IsSafeSignalManifest(topology.signals);
}

function D4_IsSafeThroughHubEndpoint(endpoint) {
	if (!D4_IsTable(endpoint) || !D4_Has(endpoint, "common_inbound") || !D4_Has(endpoint, "common_outbound") || !D4_Has(endpoint, "common_rear_merge") || !D4_IsPointOnMap(endpoint.common_inbound) || !D4_IsPointOnMap(endpoint.common_outbound) || !D4_IsPointOnMap(endpoint.common_rear_merge)) return false;
	if (!D4_Has(endpoint, "fan_backbone") || !D4_IsSafePointPath(endpoint.fan_backbone, 2, DIRECTORATE_M4_MAX_OPERATION_ENTRIES)) return false;
	if (!D4_Has(endpoint, "merge_backbone") || !D4_IsSafePointPath(endpoint.merge_backbone, 2, DIRECTORATE_M4_MAX_OPERATION_ENTRIES)) return false;
	if (!D4_Has(endpoint, "loop_path") || !D4_IsSafePointPath(endpoint.loop_path, 2, DIRECTORATE_M4_MAX_OPERATION_ENTRIES)) return false;
	if (!D4_Has(endpoint, "loop_exit_heading") || typeof endpoint.loop_exit_heading != "integer" || !D4_Has(endpoint, "fan_entry_heading") || typeof endpoint.fan_entry_heading != "integer") return false;
	if (D4_DirectionBetween(endpoint.loop_path[endpoint.loop_path.len() - 2], endpoint.common_outbound) != endpoint.loop_exit_heading) return false;
	if (D4_DirectionBetween(endpoint.common_inbound, endpoint.fan_backbone[1]) != endpoint.fan_entry_heading) return false;
	if (!D4_Has(endpoint, "platform_count") || typeof endpoint.platform_count != "integer" || endpoint.platform_count < 2 || endpoint.platform_count > 16) return false;
	if (!D4_Has(endpoint, "entries") || !D4_Has(endpoint, "exits") || !D4_IsArray(endpoint.entries) || !D4_IsArray(endpoint.exits) || endpoint.entries.len() != endpoint.platform_count || endpoint.entries.len() != endpoint.exits.len()) return false;
	local entry_rows = {};
	local exit_rows = {};
	foreach (entry in endpoint.entries) {
		if (!D4_IsTable(entry) || !D4_Has(entry, "platform") || !D4_IsPointOnMap(entry.platform) || !D4_Has(entry, "entry") || !D4_IsPointOnMap(entry.entry) || !D4_Has(entry, "path") || !D4_IsSafePointPath(entry.path, 1, DIRECTORATE_M4_MAX_OPERATION_ENTRIES)) return false;
		if (!D4_IsAdjacent(entry.entry, entry.platform)) return false;
		if (D4_PointKey(entry.path[0]) != D4_PointKey(endpoint.common_inbound)) return false;
		if (D4_PointKey(entry.path[entry.path.len() - 1]) != D4_PointKey(entry.entry)) return false;
		local ekey = D4_PointKey(entry.platform);
		if (ekey in entry_rows) return false;
		entry_rows[ekey] <- true;
	}
	foreach (exitp in endpoint.exits) {
		if (!D4_IsTable(exitp) || !D4_Has(exitp, "platform") || !D4_IsPointOnMap(exitp.platform) || !D4_Has(exitp, "exit") || !D4_IsPointOnMap(exitp.exit) || !D4_Has(exitp, "path") || !D4_IsSafePointPath(exitp.path, 1, DIRECTORATE_M4_MAX_OPERATION_ENTRIES)) return false;
		if (!D4_IsAdjacent(exitp.exit, exitp.platform)) return false;
		if (D4_PointKey(exitp.path[0]) != D4_PointKey(exitp.exit)) return false;
		if (D4_PointKey(exitp.path[exitp.path.len() - 1]) != D4_PointKey(endpoint.common_rear_merge)) return false;
		local xkey = D4_PointKey(exitp.platform);
		if (xkey in exit_rows) return false;
		exit_rows[xkey] <- true;
	}
	return true;
}

function D4_IsSafeSignalManifest(signals) {
	if (!D4_IsArray(signals) || signals.len() < 1 || signals.len() > DIRECTORATE_M4_MAX_OPERATION_ENTRIES) return false;
	local seen = {};
	local map_area = GSMap.GetMapSizeX() * GSMap.GetMapSizeY();
	foreach (signal in signals) {
		if (!D4_IsTable(signal) || !D4_Has(signal, "op_id") || typeof signal.op_id != "string" || signal.op_id.len() < 1 || signal.op_id.len() > 128) return false;
		if (!D4_Has(signal, "tile") || typeof signal.tile != "integer" || signal.tile < 0 || signal.tile >= map_area) return false;
		if (!D4_Has(signal, "front") || typeof signal.front != "integer" || signal.front < 0 || signal.front >= map_area || signal.front == signal.tile) return false;
		if (!D4_Has(signal, "signal_type") || typeof signal.signal_type != "integer") return false;
		local key = signal.tile + ":" + signal.front;
		if (key in seen) return false;
		seen[key] <- true;
	}
	return true;
}

function D4_IsSafePointPath(path, min_len, max_len) {
	if (!D4_IsArray(path) || path.len() < min_len || path.len() > max_len) return false;
	foreach (p in path) {
		if (!D4_IsPointOnMap(p)) return false;
	}
	return true;
}

function D4_VerifyThroughHubEndpointTopology(endpoint, prefix) {
	local failures = [];
	if (!D4_IsTable(endpoint) || !D4_Has(endpoint, "common_inbound") || !D4_Has(endpoint, "common_outbound") || !D4_Has(endpoint, "entries") || !D4_Has(endpoint, "exits") || !D4_IsArray(endpoint.entries) || !D4_IsArray(endpoint.exits) || endpoint.entries.len() < 2 || endpoint.entries.len() != endpoint.exits.len()) return { ok = false, failures = [{ op_id = prefix, reason = "through_hub_manifest_invalid" }] };
	if (!D4_Has(endpoint, "common_rear_merge") || !D4_Has(endpoint, "loop_path") || !D4_IsArray(endpoint.loop_path) || endpoint.loop_path.len() < 2) failures.append({ op_id = prefix, reason = "local_loop_missing" });
	local platform_count = D4_Has(endpoint, "platform_count") && typeof endpoint.platform_count == "integer" ? endpoint.platform_count : endpoint.entries.len();
	if (endpoint.entries.len() != platform_count || endpoint.exits.len() != platform_count) failures.append({ op_id = prefix, reason = "platform_rows_not_covered" });
	local entry_rows = {};
	local exit_rows = {};
	foreach (entry in endpoint.entries) {
		if (!D4_Has(entry, "path") || !D4_IsArray(entry.path) || entry.path.len() < 1) { failures.append({ op_id = prefix, reason = "entry_path_missing" }); continue; }
		if (!D4_VerifyProgramPathConnections(entry.path, null, entry.platform)) failures.append({ op_id = prefix, reason = "entry_unreachable", point = D4_Has(entry, "platform") ? entry.platform : null });
		if (D4_PointKey(entry.path[0]) != D4_PointKey(endpoint.common_inbound)) failures.append({ op_id = prefix, reason = "entry_not_common_inbound" });
		if (!D4_Has(entry, "entry") || D4_PointKey(entry.path[entry.path.len() - 1]) != D4_PointKey(entry.entry)) failures.append({ op_id = prefix, reason = "entry_not_axis_throat" });
		if (!D4_Has(entry, "entry") || !D4_Has(entry, "platform") || !D4_IsAdjacent(entry.entry, entry.platform)) failures.append({ op_id = prefix, reason = "entry_not_adjacent_platform" });
		if (D4_Has(entry, "platform")) {
			local ekey = D4_PointKey(entry.platform);
			if (ekey in entry_rows) failures.append({ op_id = prefix, reason = "entry_platform_duplicate", point = entry.platform });
			entry_rows[ekey] <- true;
		}
	}
	foreach (exitp in endpoint.exits) {
		if (!D4_Has(exitp, "path") || !D4_IsArray(exitp.path) || exitp.path.len() < 1) { failures.append({ op_id = prefix, reason = "exit_path_missing" }); continue; }
		if (!D4_VerifyProgramPathConnections(exitp.path, exitp.platform, null)) failures.append({ op_id = prefix, reason = "exit_unreachable", point = D4_Has(exitp, "platform") ? exitp.platform : null });
		if (!D4_Has(exitp, "exit") || D4_PointKey(exitp.path[0]) != D4_PointKey(exitp.exit)) failures.append({ op_id = prefix, reason = "exit_not_axis_throat" });
		if (D4_Has(endpoint, "common_rear_merge") && D4_PointKey(exitp.path[exitp.path.len() - 1]) != D4_PointKey(endpoint.common_rear_merge)) failures.append({ op_id = prefix, reason = "exit_not_common_rear_merge" });
		if (!D4_Has(exitp, "exit") || !D4_Has(exitp, "platform") || !D4_IsAdjacent(exitp.exit, exitp.platform)) failures.append({ op_id = prefix, reason = "exit_not_adjacent_platform" });
		if (D4_Has(exitp, "platform")) {
			local xkey = D4_PointKey(exitp.platform);
			if (xkey in exit_rows) failures.append({ op_id = prefix, reason = "exit_platform_duplicate", point = exitp.platform });
			exit_rows[xkey] <- true;
		}
	}
	if (D4_Has(endpoint, "loop_path") && D4_IsArray(endpoint.loop_path) && endpoint.loop_path.len() >= 2) {
		if (!D4_VerifyProgramPathConnections(endpoint.loop_path, null, null)) failures.append({ op_id = prefix, reason = "local_loop_disconnected" });
		if (D4_Has(endpoint, "common_rear_merge") && D4_PointKey(endpoint.loop_path[0]) != D4_PointKey(endpoint.common_rear_merge)) failures.append({ op_id = prefix, reason = "loop_not_common_rear_merge" });
		if (D4_PointKey(endpoint.loop_path[endpoint.loop_path.len() - 1]) != D4_PointKey(endpoint.common_outbound)) failures.append({ op_id = prefix, reason = "loop_not_common_outbound" });
		if (!D4_Has(endpoint, "loop_exit_heading") || D4_DirectionBetween(endpoint.loop_path[endpoint.loop_path.len() - 2], endpoint.common_outbound) != endpoint.loop_exit_heading) failures.append({ op_id = prefix, reason = "loop_exit_heading_mismatch" });
		if (!D4_Has(endpoint, "fan_entry_heading") || !D4_Has(endpoint, "fan_backbone") || !D4_IsArray(endpoint.fan_backbone) || endpoint.fan_backbone.len() < 2 || D4_DirectionBetween(endpoint.common_inbound, endpoint.fan_backbone[1]) != endpoint.fan_entry_heading) failures.append({ op_id = prefix, reason = "fan_entry_heading_mismatch" });
	}
	return { ok = failures.len() == 0, failures = failures, platform_count = endpoint.entries.len() };
}

function D4_VerifyThroughHubTrunks(topology) {
	local failures = [];
	if (!D4_Has(topology, "outbound") || !D4_IsArray(topology.outbound) || topology.outbound.len() < 2 || !D4_Has(topology, "return_lane") || !D4_IsArray(topology.return_lane) || topology.return_lane.len() < 2) return { ok = false, failures = [{ reason = "trunk_paths_missing" }] };
	if (D4_PointKey(topology.outbound[0]) != D4_PointKey(topology.source.common_outbound)) failures.append({ reason = "outbound_not_source_common_exit" });
	if (D4_PointKey(topology.outbound[topology.outbound.len() - 1]) != D4_PointKey(topology.destination.common_inbound)) failures.append({ reason = "outbound_not_destination_common_entry" });
	if (D4_PointKey(topology.return_lane[0]) != D4_PointKey(topology.destination.common_outbound)) failures.append({ reason = "return_not_destination_common_exit" });
	if (D4_PointKey(topology.return_lane[topology.return_lane.len() - 1]) != D4_PointKey(topology.source.common_inbound)) failures.append({ reason = "return_not_source_common_entry" });
	if (D4_DirectionBetween(topology.outbound[0], topology.outbound[1]) != topology.source.loop_exit_heading) failures.append({ reason = "outbound_source_heading_mismatch" });
	if (D4_DirectionBetween(topology.outbound[topology.outbound.len() - 2], topology.outbound[topology.outbound.len() - 1]) != topology.destination.fan_entry_heading) failures.append({ reason = "outbound_destination_heading_mismatch" });
	if (D4_DirectionBetween(topology.return_lane[0], topology.return_lane[1]) != topology.destination.loop_exit_heading) failures.append({ reason = "return_destination_heading_mismatch" });
	if (D4_DirectionBetween(topology.return_lane[topology.return_lane.len() - 2], topology.return_lane[topology.return_lane.len() - 1]) != topology.source.fan_entry_heading) failures.append({ reason = "return_source_heading_mismatch" });
	local seen = {};
	foreach (p0 in topology.outbound) seen[D4_PointKey(p0)] <- true;
	foreach (p1 in topology.return_lane) {
		if (D4_PointKey(p1) in seen) failures.append({ reason = "return_lane_self_crossing", point = p1 });
	}
	if (!D4_VerifyProgramPathConnections(topology.outbound, null, null)) failures.append({ reason = "outbound_trunk_disconnected" });
	if (!D4_VerifyProgramPathConnections(topology.return_lane, null, null)) failures.append({ reason = "return_trunk_disconnected" });
	local signals = D4_VerifyThroughHubSignals(topology);
	if (!signals.ok) {
		foreach (failure in signals.failures) failures.append(failure);
	}
	return { ok = failures.len() == 0, failures = failures };
}

function D4_VerifyThroughHubSignals(topology) {
	local failures = [];
	if (!D4_Has(topology, "signals") || !D4_IsArray(topology.signals) || topology.signals.len() < 1) return { ok = false, failures = [{ reason = "signal_manifest_missing" }] };
	foreach (signal in topology.signals) {
		if (!D4_IsTable(signal) || !D4_Has(signal, "tile") || !D4_Has(signal, "front") || !D4_Has(signal, "signal_type")) {
			failures.append({ reason = "signal_manifest_invalid" });
			continue;
		}
		if (GSRail.GetSignalType(signal.tile, signal.front) != signal.signal_type) failures.append({ reason = "signal_missing_or_wrong_facing", tile = signal.tile, front = signal.front });
	}
	return { ok = failures.len() == 0, failures = failures };
}

function D4_VerifyProgramPathConnections(path, entry_point, exit_point) {
	for (local i = 0; i < path.len(); i++) {
		local prev = i > 0 ? path[i - 1] : entry_point;
		local next = i + 1 < path.len() ? path[i + 1] : exit_point;
		if (prev == null || next == null) continue;
		if (!GSRail.AreTilesConnected(D4_ToTile(prev), D4_ToTile(path[i]), D4_ToTile(next))) return false;
	}
	return true;
}

/* Assemble a directed reachability graph purely from the emitted rail_connection
 * primitives and prove that ONE commonInbound tile reaches every platform_front,
 * every platform_rear reaches ONE commonRearMerge, and the loop reaches the
 * shared commonOutbound. Rejects any regression to per-platform trunks even
 * when the individual paths and headings look right in isolation. */
function D4_ThroughHubRoroReachability(ops, topology) {
	local outgoing = {};
	local prefix_source = "rail.source.";
	local prefix_dest = "rail.destination.";
	foreach (op in ops) {
		if (!D4_IsTable(op) || op.kind != "rail_connection" || !D4_Has(op, "op_id")) continue;
		local id = op.op_id;
		local source_match = id.len() >= prefix_source.len() && id.slice(0, prefix_source.len()) == prefix_source;
		local destination_match = id.len() >= prefix_dest.len() && id.slice(0, prefix_dest.len()) == prefix_dest;
		if (!source_match && !destination_match) continue;
		if (!D4_Has(op, "prev_point") || !D4_Has(op, "point") || !D4_Has(op, "next_point")) continue;
		local arc = D4_PointKey(op.prev_point) + ">" + D4_PointKey(op.point);
		local succ = D4_PointKey(op.point) + ">" + D4_PointKey(op.next_point);
		if (!(arc in outgoing)) outgoing[arc] <- {};
		outgoing[arc][succ] <- true;
	}
	local platform_forward = {};
	foreach (endpoint in [topology.source, topology.destination]) {
		if (!D4_IsTable(endpoint) || !D4_Has(endpoint, "entries") || !D4_Has(endpoint, "exits")) continue;
		for (local i = 0; i < endpoint.entries.len(); i++) {
			local entry = endpoint.entries[i];
			local exitp = endpoint.exits[i];
			if (!D4_IsTable(entry) || !D4_IsTable(exitp) || !D4_Has(entry, "entry") || !D4_Has(entry, "platform") || !D4_Has(exitp, "platform") || !D4_Has(exitp, "exit")) continue;
			local forward = D4_DirectionBetween(entry.entry, entry.platform);
			if (forward < 0 || D4_DirectionBetween(exitp.platform, exitp.exit) != forward) continue;
			local a = entry.entry;
			local b = entry.platform;
			local station_guard = 0;
			while (D4_PointKey(b) != D4_PointKey(exitp.platform) && station_guard < 64) {
				station_guard++;
				local next = D4_Offset(b, forward, 1);
				local arc = D4_PointKey(a) + ">" + D4_PointKey(b);
				local succ = D4_PointKey(b) + ">" + D4_PointKey(next);
				if (!(arc in outgoing)) outgoing[arc] <- {};
				outgoing[arc][succ] <- true;
				a = b;
				b = next;
			}
			if (D4_PointKey(b) == D4_PointKey(exitp.platform)) {
				local rear_arc = D4_PointKey(a) + ">" + D4_PointKey(b);
				local rear_succ = D4_PointKey(b) + ">" + D4_PointKey(exitp.exit);
				if (!(rear_arc in outgoing)) outgoing[rear_arc] <- {};
				outgoing[rear_arc][rear_succ] <- true;
			}
			platform_forward[D4_PointKey(entry.platform)] <- forward;
		}
	}
	return { outgoing = outgoing, platform_forward = platform_forward };
}

function D4_ForwardReachTiles(graph, start_arc) {
	local visited_arcs = {};
	visited_arcs[start_arc] <- true;
	local queue = [start_arc];
	local visited_tiles = {};
	local head = start_arc.find(">");
	if (head != null) visited_tiles[start_arc.slice(head + 1)] <- true;
	local guard = 0;
	while (queue.len() > 0 && guard < 4096) {
		guard++;
		local arc = queue[0];
		queue.remove(0);
		if (!(arc in graph.outgoing)) continue;
		foreach (succ, _ in graph.outgoing[arc]) {
			if (succ in visited_arcs) continue;
			visited_arcs[succ] <- true;
			local sep = succ.find(">");
			if (sep != null) visited_tiles[succ.slice(sep + 1)] <- true;
			queue.append(succ);
		}
	}
	return visited_tiles;
}

function D4_VerifyThroughHubRoroReachability(ops, topology) {
	local failures = [];
	if (!D4_IsTable(topology) || !D4_Has(topology, "source") || !D4_Has(topology, "destination")) return { ok = false, failures = [{ reason = "reachability_topology_missing" }] };
	local graph = D4_ThroughHubRoroReachability(ops, topology);
	foreach (endpoint_pair in [{ endpoint = topology.source, side = "source" }, { endpoint = topology.destination, side = "destination" }]) {
		local endpoint = endpoint_pair.endpoint;
		local side = endpoint_pair.side;
		if (!D4_IsTable(endpoint) || !D4_Has(endpoint, "common_inbound") || !D4_Has(endpoint, "common_rear_merge") || !D4_Has(endpoint, "common_outbound") || !D4_Has(endpoint, "fan_backbone") || !D4_IsArray(endpoint.fan_backbone) || endpoint.fan_backbone.len() < 2 || !D4_Has(endpoint, "loop_path") || !D4_IsArray(endpoint.loop_path) || endpoint.loop_path.len() < 2) {
			failures.append({ reason = "reachability_endpoint_manifest_missing", side = side });
			continue;
		}
		local inbound_arc = D4_PointKey(endpoint.common_inbound) + ">" + D4_PointKey(endpoint.fan_backbone[1]);
		local reached = D4_ForwardReachTiles(graph, inbound_arc);
		foreach (entry in endpoint.entries) {
			if (!D4_Has(entry, "platform")) continue;
			local pkey = D4_PointKey(entry.platform);
			if (!(pkey in reached)) failures.append({ reason = "reachability_platform_front_unreachable", side = side, point = entry.platform });
		}
		foreach (exitp in endpoint.exits) {
			if (!D4_Has(exitp, "platform")) continue;
			local rear = exitp.platform;
			local forward = D4_DirectionBetween(rear, exitp.exit);
			if (forward < 0) { failures.append({ reason = "reachability_platform_axis_invalid", side = side, point = rear }); continue; }
			local rear_arc = D4_PointKey(D4_Offset(rear, D4_RotateDir(forward, 2), 1)) + ">" + D4_PointKey(rear);
			local from_rear = D4_ForwardReachTiles(graph, rear_arc);
			if (!(D4_PointKey(endpoint.common_rear_merge) in from_rear)) failures.append({ reason = "reachability_platform_rear_unreachable", side = side, point = rear });
		}
		local loop_arc = D4_PointKey(endpoint.common_rear_merge) + ">" + D4_PointKey(endpoint.loop_path[1]);
		local loop_reached = D4_ForwardReachTiles(graph, loop_arc);
		if (!(D4_PointKey(endpoint.common_outbound) in loop_reached)) failures.append({ reason = "reachability_common_outbound_unreachable", side = side });
	}
	return { ok = failures.len() == 0, failures = failures };
}
