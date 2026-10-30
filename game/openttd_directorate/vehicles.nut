/* tamago fork: road, water and air routes, plus fleet care.
 *
 * Rail goes through the guarded plan/apply/commission pipeline. These are single
 * commands that survey, build and commission one route each: stations, the road
 * (road routes), a depot, vehicles with orders. Each checks what it can before
 * spending (a road path, a water path, airport sites), keeps params.reserve in the
 * bank, removes what it built if a later step fails, and registers the route in
 * the route registry with its mode, so observe, verify and the routes table cover
 * it like a rail route. */

DIRECTORATE_VEHICLE_MAX_PER_ROUTE <- 8;
DIRECTORATE_ROAD_MAX_DISTANCE <- 160;      // tiles between stops; trucks are slow beyond this
DIRECTORATE_ROAD_EXPANSIONS <- 8000;
DIRECTORATE_WATER_EXPANSIONS <- 60000;
DIRECTORATE_SITE_TESTS <- 120;
DIRECTORATE_TOWN_STOP_RADIUS <- 8;

/* ---- shared ---------------------------------------------------------------- */

function D4_Min(a, b) { return a < b ? a : b; }
function D4_Max(a, b) { return a > b ? a : b; }

function D4_VehicleTypeLabel(vt) {
	if (vt == GSVehicle.VT_RAIL) return "rail";
	if (vt == GSVehicle.VT_ROAD) return "road";
	if (vt == GSVehicle.VT_WATER) return "water";
	if (vt == GSVehicle.VT_AIR) return "air";
	return "unknown";
}

function D4_IsPassengerLike(cargo_type) {
	return GSCargo.HasCargoClass(cargo_type, GSCargo.CC_PASSENGERS) || GSCargo.HasCargoClass(cargo_type, GSCargo.CC_MAIL);
}

function D4_Neighbours(tile) {
	local x = GSMap.GetTileX(tile), y = GSMap.GetTileY(tile);
	local out = [];
	foreach (d in [[1, 0], [-1, 0], [0, 1], [0, -1]]) {
		local n = GSMap.GetTileIndex(x + d[0], y + d[1]);
		if (GSMap.IsValidTile(n)) out.append(n);
	}
	return out;
}

/* Endpoint from params: {prefix}_industry_id or {prefix}_town_id. */
function D4_RouteEndpoint(params, prefix) {
	local ind = prefix + "_industry_id", town = prefix + "_town_id";
	if (D4_Has(params, ind) && typeof params[ind] == "integer") {
		if (!GSIndustry.IsValidIndustry(params[ind])) return { ok = false, error = D4_Error("invalid_industry", params[ind].tostring()) };
		return { ok = true, kind = "industry", id = params[ind], location = GSIndustry.GetLocation(params[ind]) };
	}
	if (D4_Has(params, town) && typeof params[town] == "integer") {
		if (!GSTown.IsValidTown(params[town])) return { ok = false, error = D4_Error("invalid_town", params[town].tostring()) };
		return { ok = true, kind = "town", id = params[town], location = GSTown.GetLocation(params[town]) };
	}
	return { ok = false, error = D4_Error("missing_endpoint", prefix + "_industry_id or " + prefix + "_town_id") };
}

/* Cargo for a route between two endpoints. Industries decide it; towns default to passengers. */
function D4_RouteCargo(source, destination, label) {
	if (source.kind == "industry" && destination.kind == "industry") return D4_PickRouteCargo(source.id, destination.id, label);
	local cargo = D4_CargoTypeByLabel(label != null && label != "" ? label : "PASS");
	if (cargo == null) return { ok = false, error = D4_Error("invalid_cargo_label", label == null ? "PASS" : label) };
	if (source.kind == "industry" && GSIndustry.GetLastMonthProduction(source.id, cargo) <= 0) return { ok = false, error = D4_Error("source_does_not_produce", D4_SafeCargoLabel(cargo)) };
	if (destination.kind == "industry" && GSIndustry.IsCargoAccepted(destination.id, cargo) == GSIndustry.CAS_NOT_ACCEPTED) return { ok = false, error = D4_Error("destination_does_not_accept", D4_SafeCargoLabel(cargo)) };
	return { ok = true, cargo_type = cargo, cargo_label = D4_SafeCargoLabel(cargo) };
}

/* Tiles a station at this endpoint could use, nearest to `toward` first. */
function D4_EndpointTiles(endpoint, role, cargo, radius, toward) {
	local tiles = null;
	if (endpoint.kind == "industry") {
		tiles = role == "source" ? GSTileList_IndustryProducing(endpoint.id, radius) : GSTileList_IndustryAccepting(endpoint.id, radius);
	} else {
		local x = GSMap.GetTileX(endpoint.location), y = GSMap.GetTileY(endpoint.location), r = DIRECTORATE_TOWN_STOP_RADIUS;
		tiles = GSTileList();
		tiles.AddRectangle(GSMap.GetTileIndex(D4_Max(1, x - r), D4_Max(1, y - r)), GSMap.GetTileIndex(D4_Min(GSMap.GetMapSizeX() - 2, x + r), D4_Min(GSMap.GetMapSizeY() - 2, y + r)));
	}
	/* Industries: the side facing the other end, for a short road. Towns: the centre, where the passengers are. */
	tiles.Valuate(GSTile.GetDistanceManhattanToTile, endpoint.kind == "town" ? endpoint.location : toward);
	tiles.Sort(GSList.SORT_BY_VALUE, GSList.SORT_ASCENDING);
	return tiles;
}

function D4_ServesEndpoint(tile, role, cargo, w, h, radius) {
	if (role == "source") return GSTile.GetCargoProduction(tile, cargo, w, h, radius) > 0;
	return GSTile.GetCargoAcceptance(tile, cargo, w, h, radius) >= 8;
}

/* The best buildable engine of a type for a cargo: most capacity x speed, then reliability. */
function D4_PickEngine(vehicle_type, cargo, accept) {
	local best = null, best_score = -1;
	foreach (e, _ in GSEngineList(vehicle_type)) {
		if (!GSEngine.IsBuildable(e)) continue;
		if (GSEngine.GetCargoType(e) != cargo && !GSEngine.CanRefitCargo(e, cargo)) continue;
		if (accept != null && !accept(e)) continue;
		local score = D4_Max(1, GSEngine.GetCapacity(e)) * D4_Max(1, GSEngine.GetMaxSpeed(e)) * (50 + GSEngine.GetReliability(e));
		if (score > best_score) { best = e; best_score = score; }
	}
	return best;
}

function D4_BuildRouteVehicles(depot, engine, cargo, source_tile, destination_tile, count, company_id, reserve) {
	local flags_src = D4_IsPassengerLike(cargo) ? GSOrder.OF_NONE : GSOrder.OF_FULL_LOAD_ANY;
	local flags_dst = D4_IsPassengerLike(cargo) ? GSOrder.OF_NONE : GSOrder.OF_UNLOAD;
	local built = [];
	for (local i = 0; i < count; i++) {
		local price = GSEngine.GetPrice(engine);
		if (!D4_EnsureCompanyFunds(company_id, price + reserve)) break;
		local v = null;
		if (built.len() > 0) v = GSVehicle.CloneVehicle(depot, built[0].vehicle_id, true);
		else if (GSEngine.GetCargoType(engine) == cargo) v = GSVehicle.BuildVehicle(depot, engine);
		else v = GSVehicle.BuildVehicleWithRefit(depot, engine, cargo);
		if (!GSVehicle.IsValidVehicle(v)) {
			if (built.len() == 0) return { ok = false, error = D4_Error("vehicle_build_failed", GSError.GetLastErrorString()) };
			break;
		}
		if (built.len() == 0) {
			if (!GSOrder.AppendOrder(v, source_tile, flags_src) || !GSOrder.AppendOrder(v, destination_tile, flags_dst)) {
				local err = GSError.GetLastErrorString();
				GSVehicle.SellVehicle(v);
				return { ok = false, error = D4_Error("orders_failed", err) };
			}
		}
		GSVehicle.StartStopVehicle(v);
		built.append({ vehicle_id = v, cost = price });
	}
	if (built.len() == 0) return { ok = false, error = D4_Error("insufficient_funds", GSEngine.GetPrice(engine).tostring()) };
	return { ok = true, vehicles = built };
}

function D4_RegisterModeRoute(registry, company_id, route_id, mode, source, destination, source_tile, destination_tile, cargo, depot, vehicles, build_cost) {
	local created = registry.Create(route_id, company_id, route_id, source_tile, destination_tile,
		source.kind == "industry" ? source.id : -1, destination.kind == "industry" ? destination.id : -1, cargo);
	if (!created.ok) return created;
	local route = created.route;
	route.mode <- mode;
	route.depot_tile <- depot;
	route.state = "commissioned";
	route.commissioned_tick = D4_Tick();
	route.health.topology_ok = true;
	route.health.orders_ok = true;
	route.economics.build_cost += build_cost;
	foreach (v in vehicles) D4_AssignVehicleToRoute(route, v.vehicle_id, v.cost);
	return { ok = true, route = registry.Summary(route) };
}

/* Undo a failed build and report the game's reason. */
function D4_FailBuild(built, code, detail) {
	local err = GSError.GetLastErrorString();
	D4_UndoBuilt(built);
	return { ok = false, error = D4_Error(code, detail + " (" + err + ")") };
}

/* Undo a failed build: newest first, best effort. */
function D4_UndoBuilt(built) {
	for (local i = built.len() - 1; i >= 0; i--) {
		local b = built[i];
		if (b.kind == "road") GSRoad.RemoveRoad(b.from, b.to);
		else if (b.kind == "road_station") GSRoad.RemoveRoadStation(b.tile);
		else if (b.kind == "road_depot") GSRoad.RemoveRoadDepot(b.tile);
		else if (b.kind == "dock") GSMarine.RemoveDock(b.tile);
		else if (b.kind == "water_depot") GSMarine.RemoveWaterDepot(b.tile);
		else if (b.kind == "airport") GSAirport.RemoveAirport(b.tile);
	}
}

function D4_CheckRouteId(registry, params) {
	if (!D4_Has(params, "route_id") || !D4_IsSafeIdentifier(params.route_id, 128)) return D4_Error("invalid_route_id", "route_id required");
	if (registry.Get(params.route_id) != null) return D4_Error("route_id_conflict", params.route_id);
	return null;
}

/* ---- road ------------------------------------------------------------------ */

function D4_TestRoadPiece(a, b) {
	local tm = GSTestMode();
	return GSRoad.BuildRoad(a, b);
}

function D4_TestRoadStop(tile, front, rv_type, drive_through) {
	local tm = GSTestMode();
	if (drive_through) return GSRoad.BuildDriveThroughRoadStation(tile, front, rv_type, GSStation.STATION_NEW);
	return GSRoad.BuildRoadStation(tile, front, rv_type, GSStation.STATION_NEW);
}

function D4_TestRoadDepot(tile, front) {
	local tm = GSTestMode();
	return GSRoad.BuildRoadDepot(tile, front);
}

function D4_IsRoadBlocked(tile) {
	return GSRail.IsLevelCrossingTile(tile) || GSRail.IsRailTile(tile) || GSRoad.IsRoadDepotTile(tile) || GSRoad.IsRoadStationTile(tile);
}

/* A stop site: a drive-through stop on a straight road, or a bay stop on free land
 * facing a tile the road can reach. Returns { tile, front, exits, drive_through }. */
function D4_FindRoadStop(endpoint, role, cargo, rv_type, toward) {
	local radius = GSStation.GetCoverageRadius(rv_type == GSRoad.ROADVEHTYPE_BUS ? GSStation.STATION_BUS_STOP : GSStation.STATION_TRUCK_STOP);
	local tested = 0;
	foreach (t, _ in D4_EndpointTiles(endpoint, role, cargo, radius, toward)) {
		if (tested >= DIRECTORATE_SITE_TESTS) break;
		if (GSTile.GetSlope(t) != GSTile.SLOPE_FLAT || !D4_ServesEndpoint(t, role, cargo, 1, 1, radius)) continue;
		local x = GSMap.GetTileX(t), y = GSMap.GetTileY(t);
		if (GSRoad.IsRoadTile(t) && !D4_IsRoadBlocked(t)) {
			foreach (axis in [[1, 0], [0, 1]]) {
				local a = GSMap.GetTileIndex(x + axis[0], y + axis[1]), b = GSMap.GetTileIndex(x - axis[0], y - axis[1]);
				if (!GSRoad.AreRoadTilesConnected(t, a) || !GSRoad.AreRoadTilesConnected(t, b)) continue;
				tested++;
				if (D4_TestRoadStop(t, a, rv_type, true)) return { tile = t, front = a, exits = [a, b], drive_through = true };
			}
		} else if (GSTile.IsBuildable(t)) {
			foreach (f in D4_Neighbours(t)) {
				if (!(GSTile.IsBuildable(f) || (GSRoad.IsRoadTile(f) && !D4_IsRoadBlocked(f)))) continue;
				tested++;
				if (D4_TestRoadStop(t, f, rv_type, false)) return { tile = t, front = f, exits = [f], drive_through = false };
				if (tested >= DIRECTORATE_SITE_TESTS) break;
			}
		}
	}
	return null;
}

/* A* from one stop's exits to the other's, over existing road and buildable land,
 * never across railway (no level crossings). Returns the tile path or null. */
function D4_FindRoadPath(start, goal, limit) {
	local queue = GSPriorityQueue();
	local came = {}, cost = {};
	local goal_exits = {};
	foreach (e in goal.exits) goal_exits[e] <- true;
	foreach (e in start.exits) {
		if (D4_IsRoadBlocked(e) && e != start.front) continue;
		came[e] <- start.tile;
		cost[e] <- 1;
		queue.Insert(e, GSMap.DistanceManhattan(e, goal.tile));
	}
	local expansions = 0;
	while (queue.Count() > 0 && expansions < limit) {
		local t = queue.Pop();
		expansions++;
		if (t in goal_exits) {
			local path = [goal.tile, t];
			while (came[t] != start.tile) { t = came[t]; path.append(t); }
			path.append(start.tile);
			path.reverse();
			return { path = path, expansions = expansions };
		}
		foreach (n in D4_Neighbours(t)) {
			if (n == start.tile || n == goal.tile || D4_IsRoadBlocked(n) || GSTile.IsWaterTile(n)) continue;
			local step = 0;
			if (GSRoad.IsRoadTile(n)) step = GSRoad.AreRoadTilesConnected(t, n) ? 1 : 2;
			else if (GSTile.IsBuildable(n)) step = GSTile.GetSlope(n) == GSTile.SLOPE_FLAT ? 3 : 5;
			else continue;
			local g = cost[t] + step;
			if (n in cost && cost[n] <= g) continue;
			if (step > 1 && !D4_TestRoadPiece(t, n)) continue;
			cost[n] <- g;
			came[n] <- t;
			queue.Insert(n, g + GSMap.DistanceManhattan(n, goal.tile));
		}
	}
	return { path = null, expansions = expansions };
}

function D4_BuildRoadRoute(store, company_id, params) {
	local registry = store.registry;
	local bad_id = D4_CheckRouteId(registry, params);
	if (bad_id != null) return { ok = false, error = bad_id };
	local source = D4_RouteEndpoint(params, "source");
	if (!source.ok) return source;
	local destination = D4_RouteEndpoint(params, "destination");
	if (!destination.ok) return destination;
	local cargo_pick = D4_RouteCargo(source, destination, D4_Has(params, "cargo_label") ? params.cargo_label : null);
	if (!cargo_pick.ok) return cargo_pick;
	local cargo = cargo_pick.cargo_type;
	local reserve = D4_ClampInt(D4_Has(params, "reserve") ? params.reserve : 0, 0, 0, 100000000);
	local count = D4_ClampInt(D4_Has(params, "vehicles") ? params.vehicles : 2, 2, 1, DIRECTORATE_VEHICLE_MAX_PER_ROUTE);
	if (GSMap.DistanceManhattan(source.location, destination.location) > DIRECTORATE_ROAD_MAX_DISTANCE) return { ok = false, error = D4_Error("too_far_for_road", DIRECTORATE_ROAD_MAX_DISTANCE.tostring() + " tiles max") };

	local mode = GSCompanyMode(company_id);
	if (!GSCompanyMode.IsValid()) return { ok = false, error = D4_Error("invalid_company", company_id.tostring()) };
	GSRoad.SetCurrentRoadType(GSRoad.ROADTYPE_ROAD);
	local rv_type = GSRoad.GetRoadVehicleTypeForCargo(cargo);
	local engine = D4_PickEngine(GSVehicle.VT_ROAD, cargo, function(e) { return GSEngine.GetRoadType(e) == GSRoad.ROADTYPE_ROAD; });
	if (engine == null) return { ok = false, error = D4_Error("no_road_vehicle_for_cargo", cargo_pick.cargo_label) };

	local a = D4_FindRoadStop(source, "source", cargo, rv_type, destination.location);
	if (a == null) return { ok = false, error = D4_Error("no_source_stop_site", "no flat tile near the source both serves it and can take a stop") };
	local b = D4_FindRoadStop(destination, "destination", cargo, rv_type, a.tile);
	if (b == null) return { ok = false, error = D4_Error("no_destination_stop_site", "no flat tile near the destination both serves it and can take a stop") };
	local limit = D4_ClampInt(D4_Has(params, "path_limit") ? params.path_limit : DIRECTORATE_ROAD_EXPANSIONS, DIRECTORATE_ROAD_EXPANSIONS, 100, 40000);
	local found = D4_FindRoadPath(a, b, limit);
	if (found.path == null) return { ok = false, error = D4_Error("no_road_path", "searched " + found.expansions + " tiles; try other industries or a larger path_limit"), source_stop = D4_FromTile(a.tile), destination_stop = D4_FromTile(b.tile) };
	local path = found.path;
	local new_pieces = 0;
	for (local i = 1; i + 2 < path.len(); i++) if (!GSRoad.AreRoadTilesConnected(path[i], path[i + 1])) new_pieces++;
	local estimate = new_pieces * GSRoad.GetBuildCost(GSRoad.ROADTYPE_ROAD, GSRoad.BT_ROAD) * 2 + 2 * GSRoad.GetBuildCost(GSRoad.ROADTYPE_ROAD, rv_type == GSRoad.ROADVEHTYPE_BUS ? GSRoad.BT_BUS_STOP : GSRoad.BT_TRUCK_STOP)
		+ GSRoad.GetBuildCost(GSRoad.ROADTYPE_ROAD, GSRoad.BT_DEPOT) + GSEngine.GetPrice(engine);
	if (D4_Has(params, "dry_run") && params.dry_run == true) {
		return { ok = true, payload = { dry_run = true, estimated_cost = estimate, road_tiles = path.len() - 2, new_road_pieces = new_pieces, engine = GSEngine.GetName(engine), cargo_label = cargo_pick.cargo_label, source_stop = D4_FromTile(a.tile), destination_stop = D4_FromTile(b.tile) } };
	}
	if (!D4_EnsureCompanyFunds(company_id, estimate + reserve)) return { ok = false, error = D4_Error("insufficient_funds", estimate.tostring() + " plus reserve " + reserve) };

	local money_before = GSCompany.GetBankBalance(company_id);
	local built = [];
	foreach (stop in [a, b]) {
		local ok = stop.drive_through ? GSRoad.BuildDriveThroughRoadStation(stop.tile, stop.front, rv_type, GSStation.STATION_NEW)
			: GSRoad.BuildRoadStation(stop.tile, stop.front, rv_type, GSStation.STATION_NEW);
		if (!ok) return D4_FailBuild(built, "stop_build_failed", "" + GSMap.GetTileX(stop.tile) + "," + GSMap.GetTileY(stop.tile));
		built.append({ kind = "road_station", tile = stop.tile });
	}
	for (local i = 0; i + 1 < path.len(); i++) {
		local p = path[i], q = path[i + 1];
		if (GSRoad.AreRoadTilesConnected(p, q)) continue;
		if (!GSRoad.BuildRoad(p, q)) return D4_FailBuild(built, "road_build_failed", "" + GSMap.GetTileX(q) + "," + GSMap.GetTileY(q));
		built.append({ kind = "road", from = p, to = q });
		if (D4_Camera != null) D4_Camera.Building(q);
	}
	local depot = null;
	for (local i = 1; i + 1 < path.len() && depot == null; i++) {
		foreach (d in D4_Neighbours(path[i])) {
			if (!GSTile.IsBuildable(d) || GSTile.GetSlope(d) != GSTile.SLOPE_FLAT || !D4_TestRoadDepot(d, path[i])) continue;
			if (!GSRoad.BuildRoadDepot(d, path[i])) continue;
			built.append({ kind = "road_depot", tile = d });
			if (!GSRoad.AreRoadTilesConnected(d, path[i]) && !GSRoad.BuildRoad(d, path[i])) return D4_FailBuild(built, "depot_road_failed", "");
			depot = d;
			break;
		}
	}
	if (depot == null) return D4_FailBuild(built, "no_depot_site", "no free flat tile beside the road");
	local fleet = D4_BuildRouteVehicles(depot, engine, cargo, a.tile, b.tile, count, company_id, reserve);
	if (!fleet.ok) { D4_UndoBuilt(built); return fleet; }
	local spent = money_before - GSCompany.GetBankBalance(company_id);
	local vehicle_cost = 0;
	foreach (v in fleet.vehicles) vehicle_cost += v.cost;
	local reg = D4_RegisterModeRoute(registry, company_id, params.route_id, "road", source, destination, a.tile, b.tile, cargo, depot, fleet.vehicles, spent - vehicle_cost);
	if (!reg.ok) return reg;
	return { ok = true, payload = { route = reg.route, mode = "road", cargo_label = cargo_pick.cargo_label, engine = GSEngine.GetName(engine),
		vehicles = fleet.vehicles.len(), cost = spent, road_tiles = path.len() - 2, new_road_pieces = new_pieces,
		source_stop = D4_FromTile(a.tile), destination_stop = D4_FromTile(b.tile), depot = D4_FromTile(depot) } };
}

/* ---- water ----------------------------------------------------------------- */

function D4_TestDock(tile) {
	local tm = GSTestMode();
	return GSMarine.BuildDock(tile, GSStation.STATION_NEW);
}

function D4_TestWaterDepot(top, front) {
	local tm = GSTestMode();
	return GSMarine.BuildWaterDepot(top, front);
}

/* The water tile a dock on this coast slope opens onto. */
function D4_DockWaterTile(tile) {
	local x = GSMap.GetTileX(tile), y = GSMap.GetTileY(tile), s = GSTile.GetSlope(tile);
	local d = s == GSTile.SLOPE_NE ? [1, 0] : s == GSTile.SLOPE_SW ? [-1, 0] : s == GSTile.SLOPE_SE ? [0, -1] : s == GSTile.SLOPE_NW ? [0, 1] : null;
	if (d == null) return null;
	local w = GSMap.GetTileIndex(x + d[0], y + d[1]);
	return GSMap.IsValidTile(w) && GSTile.IsWaterTile(w) ? w : null;
}

function D4_IsShipTile(t) {
	return GSTile.IsWaterTile(t) || GSMarine.IsBuoyTile(t) || GSMarine.IsLockTile(t) || GSMarine.IsCanalTile(t);
}

/* A dock site: an oil rig's own dock, or a coast slope in reach of the industry.
 * Returns { tile, water, existing }. */
function D4_FindDock(endpoint, role, cargo, toward) {
	if (endpoint.kind == "industry" && GSIndustry.HasDock(endpoint.id)) {
		local dock = GSIndustry.GetDockLocation(endpoint.id);
		foreach (n in D4_Neighbours(dock)) if (D4_IsShipTile(n)) return { tile = dock, water = n, existing = true };
	}
	local radius = GSStation.GetCoverageRadius(GSStation.STATION_DOCK);
	local tested = 0;
	foreach (t, _ in D4_EndpointTiles(endpoint, role, cargo, radius, toward)) {
		if (tested >= DIRECTORATE_SITE_TESTS) break;
		if (!GSTile.IsCoastTile(t) && GSTile.GetSlope(t) == GSTile.SLOPE_FLAT) continue;
		local water = D4_DockWaterTile(t);
		if (water == null || !D4_ServesEndpoint(t, role, cargo, 1, 1, radius)) continue;
		tested++;
		if (D4_TestDock(t)) return { tile = t, water = water, existing = false };
	}
	return null;
}

/* A* over water: can a ship sail from one dock to the other? */
function D4_FindWaterPath(from, to, limit) {
	local queue = GSPriorityQueue();
	local seen = {};
	seen[from] <- true;
	queue.Insert(from, GSMap.DistanceManhattan(from, to));
	local expansions = 0;
	while (queue.Count() > 0 && expansions < limit) {
		local t = queue.Pop();
		expansions++;
		if (t == to || GSMap.DistanceManhattan(t, to) <= 1) return { ok = true, expansions = expansions };
		foreach (n in D4_Neighbours(t)) {
			if (n in seen || !D4_IsShipTile(n) || !GSMarine.AreWaterTilesConnected(t, n)) continue;
			seen[n] <- true;
			queue.Insert(n, GSMap.DistanceManhattan(n, to));
		}
	}
	return { ok = false, expansions = expansions };
}

function D4_BuildShipRoute(store, company_id, params) {
	local registry = store.registry;
	local bad_id = D4_CheckRouteId(registry, params);
	if (bad_id != null) return { ok = false, error = bad_id };
	local source = D4_RouteEndpoint(params, "source");
	if (!source.ok) return source;
	local destination = D4_RouteEndpoint(params, "destination");
	if (!destination.ok) return destination;
	local cargo_pick = D4_RouteCargo(source, destination, D4_Has(params, "cargo_label") ? params.cargo_label : null);
	if (!cargo_pick.ok) return cargo_pick;
	local cargo = cargo_pick.cargo_type;
	local reserve = D4_ClampInt(D4_Has(params, "reserve") ? params.reserve : 0, 0, 0, 100000000);
	local count = D4_ClampInt(D4_Has(params, "vehicles") ? params.vehicles : 1, 1, 1, DIRECTORATE_VEHICLE_MAX_PER_ROUTE);

	local mode = GSCompanyMode(company_id);
	if (!GSCompanyMode.IsValid()) return { ok = false, error = D4_Error("invalid_company", company_id.tostring()) };
	local engine = D4_PickEngine(GSVehicle.VT_WATER, cargo, null);
	if (engine == null) return { ok = false, error = D4_Error("no_ship_for_cargo", cargo_pick.cargo_label) };
	local a = D4_FindDock(source, "source", cargo, destination.location);
	if (a == null) return { ok = false, error = D4_Error("no_source_dock_site", "no coast slope near the source serves it (docks need an inclined coast tile)") };
	local b = D4_FindDock(destination, "destination", cargo, a.tile);
	if (b == null) return { ok = false, error = D4_Error("no_destination_dock_site", "no coast slope near the destination serves it") };
	local sea = D4_FindWaterPath(a.water, b.water, DIRECTORATE_WATER_EXPANSIONS);
	if (!sea.ok) return { ok = false, error = D4_Error("no_water_path", "the two docks are not on connected water (searched " + sea.expansions + " tiles)") };
	local estimate = (a.existing ? 0 : 1) * GSMarine.GetBuildCost(GSMarine.BT_DOCK) + (b.existing ? 0 : 1) * GSMarine.GetBuildCost(GSMarine.BT_DOCK)
		+ GSMarine.GetBuildCost(GSMarine.BT_DEPOT) + GSEngine.GetPrice(engine);
	if (D4_Has(params, "dry_run") && params.dry_run == true) {
		return { ok = true, payload = { dry_run = true, estimated_cost = estimate, engine = GSEngine.GetName(engine), cargo_label = cargo_pick.cargo_label, source_dock = D4_FromTile(a.tile), destination_dock = D4_FromTile(b.tile), water_tiles_searched = sea.expansions } };
	}
	if (!D4_EnsureCompanyFunds(company_id, estimate + reserve)) return { ok = false, error = D4_Error("insufficient_funds", estimate.tostring() + " plus reserve " + reserve) };

	local money_before = GSCompany.GetBankBalance(company_id);
	local built = [];
	foreach (dock in [a, b]) {
		if (dock.existing) continue;
		if (!GSMarine.BuildDock(dock.tile, GSStation.STATION_NEW)) {
			local err = GSError.GetLastErrorString();
			D4_UndoBuilt(built);
			return { ok = false, error = D4_Error("dock_build_failed", err) };
		}
		built.append({ kind = "dock", tile = dock.tile });
		if (D4_Camera != null) D4_Camera.Building(dock.tile);
	}
	/* A depot needs two water tiles in a row with water in front, near the source dock. */
	local depot = null;
	local near = GSTileList();
	local wx = GSMap.GetTileX(a.water), wy = GSMap.GetTileY(a.water);
	near.AddRectangle(GSMap.GetTileIndex(D4_Max(1, wx - 8), D4_Max(1, wy - 8)), GSMap.GetTileIndex(D4_Min(GSMap.GetMapSizeX() - 2, wx + 8), D4_Min(GSMap.GetMapSizeY() - 2, wy + 8)));
	near.Valuate(GSTile.GetDistanceManhattanToTile, a.water);
	near.Sort(GSList.SORT_BY_VALUE, GSList.SORT_ASCENDING);
	foreach (t, _ in near) {
		if (!GSTile.IsWaterTile(t) || GSTile.GetSlope(t) != GSTile.SLOPE_FLAT || t == a.water) continue;
		foreach (f in D4_Neighbours(t)) {
			if (!GSTile.IsWaterTile(f) || !D4_TestWaterDepot(t, f)) continue;
			if (GSMarine.BuildWaterDepot(t, f)) { depot = t; break; }
		}
		if (depot != null) break;
	}
	if (depot == null) { D4_UndoBuilt(built); return { ok = false, error = D4_Error("no_water_depot_site", "no open water near the source dock for a depot") }; }
	built.append({ kind = "water_depot", tile = depot });
	local fleet = D4_BuildRouteVehicles(depot, engine, cargo, a.tile, b.tile, count, company_id, reserve);
	if (!fleet.ok) { D4_UndoBuilt(built); return fleet; }
	local spent = money_before - GSCompany.GetBankBalance(company_id);
	local vehicle_cost = 0;
	foreach (v in fleet.vehicles) vehicle_cost += v.cost;
	local reg = D4_RegisterModeRoute(registry, company_id, params.route_id, "water", source, destination, a.tile, b.tile, cargo, depot, fleet.vehicles, spent - vehicle_cost);
	if (!reg.ok) return reg;
	return { ok = true, payload = { route = reg.route, mode = "water", cargo_label = cargo_pick.cargo_label, engine = GSEngine.GetName(engine),
		vehicles = fleet.vehicles.len(), cost = spent, source_dock = D4_FromTile(a.tile), destination_dock = D4_FromTile(b.tile), depot = D4_FromTile(depot) } };
}

/* ---- air ------------------------------------------------------------------- */

function D4_TestAirport(tile, type) {
	local tm = GSTestMode();
	return GSAirport.BuildAirport(tile, type, GSStation.STATION_NEW);
}

/* The smallest airport this year offers that the plane can use safely. */
function D4_AirportTypeFor(plane_type) {
	local order = plane_type == GSAirport.PT_BIG_PLANE
		? [GSAirport.AT_LARGE, GSAirport.AT_METROPOLITAN, GSAirport.AT_INTERNATIONAL, GSAirport.AT_INTERCON]
		: [GSAirport.AT_SMALL, GSAirport.AT_COMMUTER, GSAirport.AT_LARGE, GSAirport.AT_METROPOLITAN, GSAirport.AT_INTERNATIONAL, GSAirport.AT_INTERCON];
	foreach (t in order) if (GSAirport.IsValidAirportType(t) && GSAirport.IsAirportInformationAvailable(t)) return t;
	return null;
}

function D4_FindAirportSite(town, cargo, type, toward) {
	local w = GSAirport.GetAirportWidth(type), h = GSAirport.GetAirportHeight(type), radius = GSAirport.GetAirportCoverageRadius(type);
	local x = GSMap.GetTileX(town.location), y = GSMap.GetTileY(town.location), r = 14;
	local tiles = GSTileList();
	tiles.AddRectangle(GSMap.GetTileIndex(D4_Max(1, x - r), D4_Max(1, y - r)), GSMap.GetTileIndex(D4_Min(GSMap.GetMapSizeX() - w - 1, x + r), D4_Min(GSMap.GetMapSizeY() - h - 1, y + r)));
	tiles.Valuate(GSTile.GetDistanceManhattanToTile, town.location);
	tiles.Sort(GSList.SORT_BY_VALUE, GSList.SORT_ASCENDING);
	local tested = 0, last_error = "no flat open area near the town";
	foreach (t, _ in tiles) {
		if (tested >= DIRECTORATE_SITE_TESTS) break;
		if (!GSTile.IsBuildableRectangle(t, w, h)) continue;
		if (GSTile.GetCargoAcceptance(t, cargo, w, h, radius) < 8) continue;
		tested++;
		if (D4_TestAirport(t, type)) return { tile = t, error = null };
		last_error = GSError.GetLastErrorString();
	}
	return { tile = null, error = last_error };
}

function D4_BuildAirRoute(store, company_id, params) {
	local registry = store.registry;
	local bad_id = D4_CheckRouteId(registry, params);
	if (bad_id != null) return { ok = false, error = bad_id };
	local source = D4_RouteEndpoint(params, "source");
	if (!source.ok) return source;
	local destination = D4_RouteEndpoint(params, "destination");
	if (!destination.ok) return destination;
	if (source.kind != "town" || destination.kind != "town") return { ok = false, error = D4_Error("air_needs_towns", "use source_town_id and destination_town_id") };
	if (source.id == destination.id) return { ok = false, error = D4_Error("same_town", source.id.tostring()) };
	local cargo_pick = D4_RouteCargo(source, destination, D4_Has(params, "cargo_label") ? params.cargo_label : "PASS");
	if (!cargo_pick.ok) return cargo_pick;
	local cargo = cargo_pick.cargo_type;
	local reserve = D4_ClampInt(D4_Has(params, "reserve") ? params.reserve : 0, 0, 0, 100000000);
	local count = D4_ClampInt(D4_Has(params, "vehicles") ? params.vehicles : 1, 1, 1, 4);

	local mode = GSCompanyMode(company_id);
	if (!GSCompanyMode.IsValid()) return { ok = false, error = D4_Error("invalid_company", company_id.tostring()) };
	/* Small planes first: they land anywhere; big planes need a large airport and crash on small ones. */
	local engine = D4_PickEngine(GSVehicle.VT_AIR, cargo, function(e) { return GSEngine.GetPlaneType(e) != GSAirport.PT_BIG_PLANE; });
	if (engine == null) engine = D4_PickEngine(GSVehicle.VT_AIR, cargo, null);
	if (engine == null) return { ok = false, error = D4_Error("no_aircraft_for_cargo", cargo_pick.cargo_label) };
	local type = D4_AirportTypeFor(GSEngine.GetPlaneType(engine));
	if (type == null) return { ok = false, error = D4_Error("no_airport_type_available", "") };
	local range = GSEngine.GetMaximumOrderDistance(engine);
	if (range > 0 && GSOrder.GetOrderDistance(GSVehicle.VT_AIR, source.location, destination.location) > range) return { ok = false, error = D4_Error("out_of_aircraft_range", GSEngine.GetName(engine)) };
	local a = D4_FindAirportSite(source, cargo, type, destination.location);
	if (a.tile == null) return { ok = false, error = D4_Error("no_source_airport_site", a.error) };
	local b = D4_FindAirportSite(destination, cargo, type, source.location);
	if (b.tile == null) return { ok = false, error = D4_Error("no_destination_airport_site", b.error) };
	local estimate = 2 * GSAirport.GetPrice(type) + GSEngine.GetPrice(engine);
	if (D4_Has(params, "dry_run") && params.dry_run == true) {
		return { ok = true, payload = { dry_run = true, estimated_cost = estimate, engine = GSEngine.GetName(engine), airport_type = type, source_airport = D4_FromTile(a.tile), destination_airport = D4_FromTile(b.tile), distance = GSMap.DistanceManhattan(a.tile, b.tile) } };
	}
	if (!D4_EnsureCompanyFunds(company_id, estimate + reserve)) return { ok = false, error = D4_Error("insufficient_funds", estimate.tostring() + " plus reserve " + reserve) };

	local money_before = GSCompany.GetBankBalance(company_id);
	local built = [];
	foreach (site in [a, b]) {
		if (!GSAirport.BuildAirport(site.tile, type, GSStation.STATION_NEW)) {
			local err = GSError.GetLastErrorString();
			D4_UndoBuilt(built);
			return { ok = false, error = D4_Error("airport_build_failed", err) };
		}
		built.append({ kind = "airport", tile = site.tile });
		if (D4_Camera != null) D4_Camera.Building(site.tile);
	}
	local hangar = GSAirport.GetHangarOfAirport(a.tile);
	local fleet = D4_BuildRouteVehicles(hangar, engine, cargo, a.tile, b.tile, count, company_id, reserve);
	if (!fleet.ok) { D4_UndoBuilt(built); return fleet; }
	local spent = money_before - GSCompany.GetBankBalance(company_id);
	local vehicle_cost = 0;
	foreach (v in fleet.vehicles) vehicle_cost += v.cost;
	local reg = D4_RegisterModeRoute(registry, company_id, params.route_id, "air", source, destination, a.tile, b.tile, cargo, hangar, fleet.vehicles, spent - vehicle_cost);
	if (!reg.ok) return reg;
	return { ok = true, payload = { route = reg.route, mode = "air", cargo_label = cargo_pick.cargo_label, engine = GSEngine.GetName(engine), airport_type = type,
		vehicles = fleet.vehicles.len(), cost = spent, source_airport = D4_FromTile(a.tile), destination_airport = D4_FromTile(b.tile) } };
}

/* ---- fleet ----------------------------------------------------------------- */

function D4_AddRouteVehicles(store, company_id, params) {
	if (!D4_Has(params, "route_id") || typeof params.route_id != "string") return { ok = false, error = D4_Error("invalid_route_id", "") };
	local route = store.registry.Get(params.route_id);
	if (route == null || route.company_id != company_id) return { ok = false, error = D4_Error("route_not_found", params.route_id) };
	if (!D4_Has(route, "mode") || route.mode == "rail") return { ok = false, error = D4_Error("rail_route", "add trains with the commission tool") };
	D4_ReconcileRoutes(store.registry, company_id);
	if (route.vehicles.len() == 0) return { ok = false, error = D4_Error("no_vehicle_to_copy", params.route_id) };
	local first = route.vehicles[0].vehicle_id;
	local count = D4_ClampInt(D4_Has(params, "count") ? params.count : 1, 1, 1, 4);
	if (route.vehicles.len() + count > DIRECTORATE_VEHICLE_MAX_PER_ROUTE) return { ok = false, error = D4_Error("route_full", DIRECTORATE_VEHICLE_MAX_PER_ROUTE.tostring() + " vehicles max") };
	local reserve = D4_ClampInt(D4_Has(params, "reserve") ? params.reserve : 0, 0, 0, 100000000);
	local mode = GSCompanyMode(company_id);
	if (!GSCompanyMode.IsValid()) return { ok = false, error = D4_Error("invalid_company", company_id.tostring()) };
	/* A model the game no longer sells cannot be cloned: build the best model on
	 * sale for the same job instead, sharing the route's orders. */
	local engine = GSVehicle.GetEngineType(first);
	if (!GSEngine.IsBuildable(engine)) {
		engine = D4_PickEngine(GSEngine.GetVehicleType(engine), route.cargo_type, D4_SameJobFilter(engine));
		if (engine == null) return { ok = false, error = D4_Error("vehicle_build_failed", "no model on sale for this route") };
	}
	local added = [];
	for (local i = 0; i < count; i++) {
		local price = GSEngine.GetPrice(engine);
		if (!D4_EnsureCompanyFunds(company_id, price + reserve)) break;
		local v = null;
		if (GSVehicle.GetEngineType(first) == engine) v = GSVehicle.CloneVehicle(route.depot_tile, first, true);
		else {
			v = GSEngine.GetCargoType(engine) == route.cargo_type ? GSVehicle.BuildVehicle(route.depot_tile, engine) : GSVehicle.BuildVehicleWithRefit(route.depot_tile, engine, route.cargo_type);
			if (GSVehicle.IsValidVehicle(v) && !GSOrder.ShareOrders(v, first)) {
				local err = GSError.GetLastErrorString();
				GSVehicle.SellVehicle(v);
				if (added.len() == 0) return { ok = false, error = D4_Error("orders_failed", err) };
				break;
			}
		}
		if (!GSVehicle.IsValidVehicle(v)) {
			if (added.len() == 0) return { ok = false, error = D4_Error("vehicle_build_failed", GSError.GetLastErrorString()) };
			break;
		}
		GSVehicle.StartStopVehicle(v);
		D4_AssignVehicleToRoute(route, v, price);
		added.append(v);
		first = v;
	}
	if (added.len() == 0) return { ok = false, error = D4_Error("insufficient_funds", GSEngine.GetPrice(engine).tostring() + " plus reserve " + reserve) };
	return { ok = true, payload = { route_id = route.route_id, added = added, vehicles = route.vehicles.len(), model = D4_StringOr(GSEngine.GetName(engine), "", 48) } };
}

/* ---- fleet care ------------------------------------------------------------ */

/* Autorenew and autoreplace build a new vehicle with a new id and sell the old
 * one, and the game later hands the freed id to an unrelated vehicle. So a
 * route's vehicles are found by what they do: a vehicle belongs to a route when
 * its first two orders go to the route's two stations, in that order. */
::D4_FleetCheckedTick <- {};
::D4_ReplaceCheckedMonth <- {};

function D4_StationKey(source_tile, destination_tile) {
	return GSStation.GetStationID(source_tile).tostring() + ">" + GSStation.GetStationID(destination_tile).tostring();
}

function D4_VehicleRouteKey(v) {
	if (GSOrder.GetOrderCount(v) < 2 || !GSOrder.IsGotoStationOrder(v, 0) || !GSOrder.IsGotoStationOrder(v, 1)) return null;
	return D4_StationKey(GSOrder.GetOrderDestination(v, 0), GSOrder.GetOrderDestination(v, 1));
}

/* Drop vehicles a route no longer has (sold, renewed, or an id now used by
 * another vehicle) and pick up the ones that took their place. Runs at most once
 * per game tick per company. */
function D4_ReconcileRoutes(registry, company_id) {
	local now = D4_Tick();
	if (company_id in ::D4_FleetCheckedTick && ::D4_FleetCheckedTick[company_id] == now) return;
	::D4_FleetCheckedTick[company_id] <- now;
	local mode = GSCompanyMode(company_id);
	if (!GSCompanyMode.IsValid()) return;
	local by_key = {};
	foreach (v, _ in GSVehicleList()) {
		local key = D4_VehicleRouteKey(v);
		if (key == null) continue;
		if (!(key in by_key)) by_key[key] <- [];
		by_key[key].append(v);
	}
	local claimed = {}, keys = {}, lost = {};
	foreach (id in registry.order) {
		if (!(id in registry.routes) || registry.routes[id].company_id != company_id) continue;
		local route = registry.routes[id];
		keys[id] <- D4_StationKey(route.source_station_tile, route.destination_station_tile);
		local kept = [];
		foreach (e in route.vehicles) {
			local v = e.vehicle_id;
			if (GSVehicle.IsValidVehicle(v) && !(v in claimed) && D4_VehicleRouteKey(v) == keys[id]) { kept.append(e); claimed[v] <- id; }
		}
		lost[id] <- route.vehicles.len() - kept.len();
		route.vehicles = kept;
	}
	/* Replacements go first to the routes that lost vehicles, then to the oldest
	 * route on the same pair of stations. */
	foreach (pass in [true, false]) {
		foreach (id in registry.order) {
			if (!(id in keys) || (pass && lost[id] <= 0)) continue;
			local key = keys[id];
			if (!(key in by_key)) continue;
			local route = registry.routes[id];
			foreach (v in by_key[key]) {
				if (v in claimed || route.vehicles.len() >= DIRECTORATE_M4_MAX_ROUTE_VEHICLES) continue;
				if (pass && lost[id] <= 0) break;
				route.vehicles.append({ vehicle_id = v, created_tick = now, build_cost = 0 });
				claimed[v] <- id;
				lost[id]--;
				registry.AddAlert(id, "info", "vehicle_adopted", v.tostring());
			}
		}
	}
	if (GSCompany.GetAutoRenewStatus(company_id)) {
		local month = GSDate.GetYear(GSDate.GetCurrentDate()) * 12 + GSDate.GetMonth(GSDate.GetCurrentDate());
		if (!(company_id in ::D4_ReplaceCheckedMonth) || ::D4_ReplaceCheckedMonth[company_id] != month) {
			::D4_ReplaceCheckedMonth[company_id] <- month;
			D4_ReplaceRetiredModels(registry, company_id);
		}
	}
}

/* Accept only engines that can do the old engine's job: same road type for road
 * vehicles, same plane size for aircraft (a big plane crashes on a small airport). */
function D4_SameJobFilter(old) {
	local vt = GSEngine.GetVehicleType(old);
	if (vt == GSVehicle.VT_AIR) return function(e) : (old) { return GSEngine.GetPlaneType(e) == GSEngine.GetPlaneType(old); };
	if (vt == GSVehicle.VT_ROAD) return function(e) : (old) { return GSEngine.GetRoadType(e) == GSEngine.GetRoadType(old); };
	return null;
}

/* Autorenew only rebuilds the same model, and a model the game no longer sells
 * cannot be rebuilt, so those vehicles age to 0% reliability. Point each retired
 * model at the best one on sale for the same job: the vehicles are then replaced
 * on their next depot visit. Trains are left alone (rail type and wagons). */
function D4_ReplaceRetiredModels(registry, company_id) {
	local mode = GSCompanyMode(company_id);
	if (!GSCompanyMode.IsValid()) return [];
	local done = [], seen = {};
	foreach (id, route in registry.routes) {
		if (route.company_id != company_id) continue;
		foreach (e in route.vehicles) {
			if (!GSVehicle.IsValidVehicle(e.vehicle_id)) continue;
			local old = GSVehicle.GetEngineType(e.vehicle_id);
			if (old in seen || GSEngine.IsBuildable(old)) continue;
			seen[old] <- true;
			local vt = GSEngine.GetVehicleType(old);
			if (vt == GSVehicle.VT_RAIL) continue;
			local next = D4_PickEngine(vt, route.cargo_type, D4_SameJobFilter(old));
			if (next == null) continue;
			if (GSGroup.GetEngineReplacement(GSGroup.GROUP_ALL, old) != next && !GSGroup.SetAutoReplace(GSGroup.GROUP_ALL, old, next)) continue;
			done.append({ from = D4_StringOr(GSEngine.GetName(old), "", 48), to = D4_StringOr(GSEngine.GetName(next), "", 48) });
		}
	}
	return done;
}

function D4_ListTowns(params) {
	local limit = D4_ClampInt(D4_Has(params, "limit") ? params.limit : 20, 20, 1, 64);
	local min_pop = D4_ClampInt(D4_Has(params, "min_population") ? params.min_population : 0, 0, 0, 1000000);
	local pass = D4_CargoTypeByLabel("PASS");
	local towns = GSTownList();
	towns.Valuate(GSTown.GetPopulation);
	towns.KeepAboveValue(min_pop - 1);
	towns.Sort(GSList.SORT_BY_VALUE, GSList.SORT_DESCENDING);
	local rows = [];
	foreach (t, pop in towns) {
		if (rows.len() >= limit) break;
		rows.append({ town_id = t, name = D4_StringOr(GSTown.GetName(t), "", 64), location = D4_FromTile(GSTown.GetLocation(t)), population = pop,
			passengers_last_month = pass == null ? 0 : GSTown.GetLastMonthProduction(t, pass),
			passengers_transported_pct = pass == null ? 0 : GSTown.GetLastMonthTransportedPercentage(t, pass) });
	}
	return { ok = true, payload = { towns = rows, count = rows.len() } };
}

function D4_ListCompanyVehicles(store, company_id, params) {
	local limit = D4_ClampInt(D4_Has(params, "limit") ? params.limit : 64, 64, 1, 128);
	D4_ReconcileRoutes(store.registry, company_id);
	local route_of = {};
	foreach (id, route in store.registry.routes) foreach (v in route.vehicles) route_of[v.vehicle_id] <- id;
	local mode = GSCompanyMode(company_id);
	if (!GSCompanyMode.IsValid()) return { ok = false, error = D4_Error("invalid_company", company_id.tostring()) };
	local rows = [];
	foreach (v, _ in GSVehicleList()) {
		if (rows.len() >= limit) break;
		rows.append({ vehicle_id = v, type = D4_VehicleTypeLabel(GSVehicle.GetVehicleType(v)), engine = D4_StringOr(GSEngine.GetName(GSVehicle.GetEngineType(v)), "", 48),
			route_id = v in route_of ? route_of[v] : null, state = GSVehicle.GetState(v), location = D4_FromTile(GSVehicle.GetLocation(v)),
			age_days = GSVehicle.GetAge(v), max_age_days = GSVehicle.GetMaxAge(v), reliability = GSVehicle.GetReliability(v),
			profit_last_year = GSVehicle.GetProfitLastYear(v), profit_this_year = GSVehicle.GetProfitThisYear(v), value = GSVehicle.GetCurrentValue(v) });
	}
	return { ok = true, payload = { vehicles = rows, count = rows.len(), states = "0 running, 1 stopped, 2 in depot, 3 at station, 4 broken down, 5 crashed" } };
}

function D4_SetAutoRenew(store, company_id, params) {
	local mode = GSCompanyMode(company_id);
	if (!GSCompanyMode.IsValid()) return { ok = false, error = D4_Error("invalid_company", company_id.tostring()) };
	local enabled = !D4_Has(params, "enabled") || params.enabled == true;
	if (!GSCompany.SetAutoRenewStatus(enabled)) return { ok = false, error = D4_Error("autorenew_failed", GSError.GetLastErrorString()) };
	if (D4_Has(params, "months_before") && typeof params.months_before == "integer") GSCompany.SetAutoRenewMonths(D4_ClampInt(params.months_before, 6, -12, 12));
	if (D4_Has(params, "min_money") && typeof params.min_money == "integer") GSCompany.SetAutoRenewMoney(D4_ClampInt(params.min_money, 0, 0, 100000000));
	local replacing = enabled ? D4_ReplaceRetiredModels(store.registry, company_id) : [];
	return { ok = true, payload = { enabled = GSCompany.GetAutoRenewStatus(company_id), months_before = GSCompany.GetAutoRenewMonths(company_id), min_money = GSCompany.GetAutoRenewMoney(company_id), replacing_retired_models = replacing } };
}

/* bridge.nut dispatch: command -> handler(store, company_id, params). */
DIRECTORATE_VEHICLE_COMMANDS <- {
	build_road_route = D4_BuildRoadRoute,
	build_ship_route = D4_BuildShipRoute,
	build_air_route = D4_BuildAirRoute,
	add_vehicle = D4_AddRouteVehicles,
	list_towns = function(store, company_id, params) { return D4_ListTowns(params); },
	list_vehicles = D4_ListCompanyVehicles,
	set_autorenew = D4_SetAutoRenew,
};
