class DirectorateM4RouteRegistry {
	routes = null;
	order = null;
	alerts = null;
	deferred_routes = null;
	deferred_order = null;
	deferred_alerts = null;

	constructor() {
		this.routes = {};
		this.order = [];
		this.alerts = [];
		this.deferred_routes = {};
		this.deferred_order = [];
		this.deferred_alerts = [];
	}

	function Save() {
		if (!this.HasDeferred()) return { routes = this.routes, order = this.order, alerts = this.alerts };
		local saved_routes = {};
		local saved_order = [];
		foreach (id in this.deferred_order) { if (id in this.deferred_routes) { saved_routes[id] <- this.deferred_routes[id]; saved_order.append(id); } }
		foreach (id in this.order) { if (id in this.routes) { saved_routes[id] <- this.routes[id]; saved_order.append(id); } }
		local saved_alerts = [];
		foreach (alert in this.deferred_alerts) saved_alerts.append(alert);
		foreach (alert in this.alerts) saved_alerts.append(alert);
		return { routes = saved_routes, order = saved_order, alerts = saved_alerts };
	}

	function Load(data) { this.BeginLoad(data); }

	function BeginLoad(data) {
		this.routes = {};
		this.order = [];
		this.alerts = [];
		this.deferred_routes = {};
		this.deferred_order = [];
		this.deferred_alerts = [];
		if (!D4_IsTable(data) || !D4_Has(data, "routes") || !D4_IsTable(data.routes) || !D4_Has(data, "order") || !D4_IsArray(data.order) || data.order.len() > DIRECTORATE_M4_MAX_ROUTES) return;
		this.deferred_routes = data.routes;
		this.deferred_order = data.order;
		if (D4_Has(data, "alerts") && D4_IsArray(data.alerts) && data.alerts.len() <= 256) this.deferred_alerts = data.alerts;
	}

	function HydrateOne() {
		if (this.deferred_order.len() > 0) {
			local id = this.deferred_order.pop();
			if (!(id in this.deferred_routes)) return;
			local route = this.deferred_routes[id];
			delete this.deferred_routes[id];
			if (typeof id != "string" || id.len() < 1 || id.len() > 128 || id in this.routes || !this.IsRouteSafe(route)) return;
			this.routes[id] <- route;
			this.order.insert(0, id);
			return;
		}
		if (this.deferred_alerts.len() > 0) {
			local alert = this.deferred_alerts.pop();
			if (D4_IsTable(alert)) this.alerts.insert(0, alert);
		}
	}

	function HasDeferred() {
		return this.deferred_order.len() > 0 || this.deferred_alerts.len() > 0;
	}

	function Create(route_id, company_id, plan_id, source_station_tile, destination_station_tile, source_industry_id, destination_industry_id, cargo_type) {
		if (!D4_IsSafeIdentifier(route_id, 128)) return { ok = false, error = D4_Error("invalid_route_id", "") };
		if (!D4_IsValidCargoType(cargo_type)) return { ok = false, error = D4_Error("invalid_cargo_type", cargo_type.tostring()) };
		this.Retention();
		if (this.order.len() >= DIRECTORATE_M4_MAX_ROUTES) return { ok = false, error = D4_Error("route_capacity", DIRECTORATE_M4_MAX_ROUTES.tostring()) };
		local existing = route_id in this.routes ? this.routes[route_id] : null;
		if (existing != null && existing.company_id == company_id && existing.cargo_type == cargo_type && existing.plan_id == plan_id) {
			return { ok = true, route = existing, note = "idempotent" };
		}
		if (existing != null) return { ok = false, error = D4_Error("route_id_conflict", route_id) };
		local route = {
			route_id = route_id,
			company_id = company_id,
			plan_id = plan_id,
			cargo_type = cargo_type,
			cargo_label = D4_SafeCargoLabel(cargo_type),
			source_station_tile = source_station_tile,
			destination_station_tile = destination_station_tile,
			source_industry_id = source_industry_id,
			destination_industry_id = destination_industry_id,
			vehicles = [],
			state = "planned",
			commissioned_tick = 0,
			created_tick = D4_Tick(),
			updated_tick = D4_Tick(),
			health = {
				topology_ok = false,
				orders_ok = false,
				vehicle_running = false,
				positive_revenue = false,
				last_check_tick = 0,
			},
			economics = {
				build_cost = 0,
				running_cost = 0,
				last_year_profit = 0,
				this_year_profit = 0,
				lifetime_profit = 0,
			},
			topology = null,
		};
		this.routes[route_id] <- route;
		this.order.append(route_id);
		return { ok = true, route = route };
	}

	function Get(route_id) {
		if (route_id in this.routes) return this.routes[route_id];
		return null;
	}

	function Observe(request) {
		local limit = D4_ClampInt(D4_Has(request, "limit") ? request.limit : 64, 64, 1, 256);
		local rows = [];
		for (local i = this.order.len() - 1; i >= 0 && rows.len() < limit; i--) {
			local id = this.order[i];
			if (!(id in this.routes)) continue;
			local route = this.routes[id];
			if (D4_Has(request, "company_id") && route.company_id != request.company_id) continue;
			rows.append(this.Summary(route));
		}
		return { ok = true, payload = { routes = rows, alerts = this.RecentAlerts(limit), tick = D4_Tick() } };
	}

	function Summary(route) {
		return {
			route_id = route.route_id,
			company_id = route.company_id,
			plan_id = route.plan_id,
			state = route.state,
			cargo_type = route.cargo_type,
			cargo_label = route.cargo_label,
			vehicles = route.vehicles.len(),
			health = route.health,
			economics = route.economics,
			created_tick = route.created_tick,
			updated_tick = route.updated_tick,
		};
	}

	function RecentAlerts(limit) {
		local out = [];
		for (local i = this.alerts.len() - 1; i >= 0 && out.len() < limit; i--) out.append(this.alerts[i]);
		return out;
	}

	function AddAlert(route_id, level, code, detail) {
		local alert = { route_id = route_id, level = level, code = code, detail = D4_StringOr(detail.tostring(), "", DIRECTORATE_M4_MAX_ERROR_LEN), tick = D4_Tick() };
		this.alerts.append(alert);
		if (this.alerts.len() > 256) this.alerts.remove(0);
		return alert;
	}

	function IsRouteSafe(route) {
		if (!D4_IsTable(route)) return false;
		if (!("route_id" in route) || typeof route.route_id != "string" || route.route_id.len() < 1 || route.route_id.len() > 128) return false;
		if (!("company_id" in route) || typeof route.company_id != "integer") return false;
		if (!("plan_id" in route) || typeof route.plan_id != "string" || route.plan_id.len() > 128) return false;
		if (!("cargo_type" in route) || typeof route.cargo_type != "integer" || route.cargo_type < 0 || route.cargo_type >= DIRECTORATE_M4_MAX_CARGO_TYPES) return false;
		if (!("vehicles" in route) || !D4_IsArray(route.vehicles) || route.vehicles.len() > DIRECTORATE_M4_MAX_ROUTE_VEHICLES) return false;
		if (!("state" in route) || typeof route.state != "string" || !D4_IsRouteState(route.state)) return false;
		if (!("created_tick" in route) || typeof route.created_tick != "integer") route.created_tick <- 0;
		if (!("updated_tick" in route) || typeof route.updated_tick != "integer") route.updated_tick <- 0;
		if (!("commissioned_tick" in route) || typeof route.commissioned_tick != "integer") route.commissioned_tick <- 0;
		if (!("health" in route) || !D4_IsTable(route.health)) route.health <- { topology_ok = false, orders_ok = false, vehicle_running = false, positive_revenue = false, last_check_tick = 0 };
		if (!("economics" in route) || !D4_IsTable(route.economics)) route.economics <- { build_cost = 0, running_cost = 0, last_year_profit = 0, this_year_profit = 0, lifetime_profit = 0 };
		if (!("topology" in route)) route.topology <- null;
		if (route.topology != null && !D4_IsSafeThroughHubTopology(route.topology)) return false;
		local safe_vehicles = [];
		foreach (v in route.vehicles) {
			if (D4_IsTable(v) && typeof v.vehicle_id == "integer" && typeof v.created_tick == "integer") safe_vehicles.append(v);
		}
		route.vehicles = safe_vehicles;
		return true;
	}

	function Retention() {
		local compact = [];
		foreach (id in this.order) if (id in this.routes) compact.append(id);
		this.order = compact;
		while (this.order.len() >= DIRECTORATE_M4_MAX_ROUTES) {
			local removed = false;
			for (local i = 0; i < this.order.len(); i++) {
				local old = this.order[i];
				if (!(old in this.routes)) {
					this.order.remove(i);
					removed = true;
					break;
				}
				if (this.routes[old].state == "decommissioned") {
					delete this.routes[old];
					this.order.remove(i);
					removed = true;
					break;
				}
			}
			if (!removed) break;
		}
	}
}

function D4_IsRouteState(state) {
	return state == "planned" || state == "commissioning" || state == "commissioned" || state == "decommissioned" || state == "failed";
}

function D4_StationTileFromPlan(plan, which) {
	if (!D4_IsTable(plan) || !D4_Has(plan, "build_program") || !D4_IsTable(plan.build_program) || !plan.build_program.ok) return null;
	foreach (op in plan.build_program.ops) {
		if (op.kind == "station_rect") {
			if (which == "source" && op.op_id == "source_station") return op.tile;
			if (which == "destination" && op.op_id == "destination_station") return op.tile;
		}
	}
	return null;
}

function D4_CargoTypeByLabel(label) {
	if (typeof label != "string" || label.len() < 1 || label.len() > 8) return null;
	local normalized = label.tolower();
	for (local cargo = 0; cargo < DIRECTORATE_M4_MAX_CARGO_TYPES; cargo++) {
		if (!GSCargo.IsValidCargo(cargo)) continue;
		local candidate = GSCargo.GetCargoLabel(cargo);
		if (candidate != null && candidate.tolower() == normalized) return cargo;
	}
	return null;
}

function D4_ListIndustriesForCargo(cargo_label, role, limit) {
	local cargo_type = D4_CargoTypeByLabel(cargo_label);
	if (cargo_type == null) return { ok = false, error = D4_Error("invalid_cargo_label", cargo_label) };
	if (role != "source" && role != "destination") return { ok = false, error = D4_Error("invalid_industry_role", role) };
	local bounded_limit = D4_ClampInt(limit, 32, 1, 64);
	local industries = role == "source" ? GSIndustryList_CargoProducing(cargo_type) : GSIndustryList_CargoAccepting(cargo_type);
	local rows = [];
	for (local industry_id = industries.Begin(); !industries.IsEnd() && rows.len() < bounded_limit; industry_id = industries.Next()) {
		if (!GSIndustry.IsValidIndustry(industry_id)) continue;
		local point = D4_FromTile(GSIndustry.GetLocation(industry_id));
		rows.append({
			industry_id = industry_id,
			name = D4_StringOr(GSIndustry.GetName(industry_id), "", 128),
			location = point,
			production = role == "source" ? GSIndustry.GetLastMonthProduction(industry_id, cargo_type) : 0,
			transported = role == "source" ? GSIndustry.GetLastMonthTransported(industry_id, cargo_type) : 0,
		});
	}
	return { ok = true, payload = { cargo_type = cargo_type, cargo_label = D4_SafeCargoLabel(cargo_type), role = role, industries = rows, count = rows.len(), truncated = !industries.IsEnd() } };
}

function D4_CargoProducedAtIndustry(industry_id) {
	if (!GSIndustry.IsValidIndustry(industry_id)) return [];
	local produced = [];
	for (local cargo = 0; cargo < DIRECTORATE_M4_MAX_CARGO_TYPES; cargo++) {
		if (!GSCargo.IsValidCargo(cargo)) continue;
		if (GSIndustry.GetLastMonthProduction(industry_id, cargo) > 0) produced.append(cargo);
	}
	return produced;
}

function D4_PickRouteCargo(source_industry_id, destination_industry_id, requested_label) {
	local produced = D4_CargoProducedAtIndustry(source_industry_id);
	if (produced.len() == 0) return { ok = false, error = D4_Error("no_produced_cargo", source_industry_id.tostring()) };
	local chosen = produced[0];
	if (requested_label != null && requested_label != "") {
		local normalized = requested_label.tolower();
		foreach (cargo in produced) {
			local label = GSCargo.GetCargoLabel(cargo);
			if (label != null && label.tolower() == normalized) { chosen = cargo; break; }
		}
	}
	if (!GSCargo.IsValidCargo(chosen)) return { ok = false, error = D4_Error("invalid_cargo", chosen.tostring()) };
	if (GSIndustry.IsCargoAccepted(destination_industry_id, chosen) == GSIndustry.CAS_NOT_ACCEPTED) {
		return { ok = false, error = D4_Error("destination_does_not_accept", GSCargo.GetCargoLabel(chosen)), produced = produced };
	}
	return { ok = true, cargo_type = chosen, cargo_label = D4_SafeCargoLabel(chosen), produced = produced };
}

function D4_AssignVehicleToRoute(route, vehicle_id, build_cost) {
	if (route.vehicles.len() >= DIRECTORATE_M4_MAX_ROUTE_VEHICLES) return { ok = false, error = D4_Error("vehicle_capacity", route.route_id) };
	if (!GSVehicle.IsValidVehicle(vehicle_id)) return { ok = false, error = D4_Error("invalid_vehicle", vehicle_id.tostring()) };
	if (GSVehicle.GetOwner(vehicle_id) != route.company_id) return { ok = false, error = D4_Error("vehicle_company_mismatch", vehicle_id.tostring()) };
	route.vehicles.append({ vehicle_id = vehicle_id, created_tick = D4_Tick(), build_cost = build_cost });
	route.economics.build_cost += build_cost;
	route.updated_tick = D4_Tick();
	if (D4_Camera != null) D4_Camera.Feature(vehicle_id);
	return { ok = true, vehicle_id = vehicle_id };
}

function D4_CommissionRoute(plan_store, registry, company_id, plan_id, route_id, options) {
	local plan = plan_store.GetPlan(plan_id);
	if (plan == null) return { ok = false, error = D4_Error("plan_not_found", plan_id) };
	if (plan.company_id != company_id) return { ok = false, error = D4_Error("company_mismatch", plan_id) };
	if (plan.state != "applied") return { ok = false, error = D4_Error("plan_not_applied", plan.state) };
	local source_tile = D4_StationTileFromPlan(plan, "source");
	local dest_tile = D4_StationTileFromPlan(plan, "destination");
	if (source_tile == null || dest_tile == null) return { ok = false, error = D4_Error("missing_station_tiles", plan_id) };
	if (!GSRail.IsRailStationTile(source_tile) || !GSRail.IsRailStationTile(dest_tile)) return { ok = false, error = D4_Error("stations_not_built", plan_id) };
	local requested_label = D4_Has(options, "cargo_label") ? options.cargo_label : null;
	local cargo_pick = D4_PickRouteCargo(plan.intent.source_industry_id, plan.intent.destination_industry_id, requested_label);
	if (!cargo_pick.ok) return cargo_pick;
	local existing = registry.Get(route_id);
	if (existing != null) {
		if (existing.company_id != company_id || existing.plan_id != plan_id || existing.cargo_type != cargo_pick.cargo_type) {
			return { ok = false, error = D4_Error("route_id_conflict", route_id) };
		}
		if (existing.state != "commissioned") {
			return { ok = false, error = D4_Error("route_not_commissioned", existing.state), state = existing.state };
		}
		return { ok = true, route = registry.Summary(existing), note = "idempotent" };
	}
	local created = registry.Create(route_id, company_id, plan_id, source_tile, dest_tile, plan.intent.source_industry_id, plan.intent.destination_industry_id, cargo_pick.cargo_type);
	if (!created.ok) return created;
	local route = created.route;
	if (D4_Has(plan.build_program, "topology")) route.topology = plan.build_program.topology;
	route.state = "commissioning";
	local topology = D4_VerifyRouteTopology(route, company_id);
	route.health.topology_ok = topology.ok;
	if (!topology.ok) {
		route.state = "failed";
		registry.AddAlert(route_id, "error", "topology_failed", topology.failures.len().tostring());
		return { ok = false, error = D4_Error("topology_failed", route_id), topology = topology };
	}
	local orders = D4_ConfigureRouteOrders(route, company_id, plan_store);
	if (!orders.ok) {
		route.state = "failed";
		registry.AddAlert(route_id, "error", "orders_failed", orders.error.code);
		return { ok = false, error = orders.error };
	}
	route.health.orders_ok = true;
	local vehicle = D4_BuildRouteVehicle(route, company_id, plan_store);
	if (!vehicle.ok) {
		route.state = "failed";
		registry.AddAlert(route_id, "error", "vehicle_build_failed", vehicle.error.code);
		return { ok = false, error = vehicle.error };
	}
	D4_AssignVehicleToRoute(route, vehicle.vehicle_id, vehicle.build_cost);
	local mode2 = GSCompanyMode(route.company_id);
	if (GSCompanyMode.IsValid() && !GSVehicle.StartStopVehicle(vehicle.vehicle_id)) {
		registry.AddAlert(route_id, "warning", "vehicle_start_failed", vehicle.vehicle_id.tostring());
	}
	route.state = "commissioned";
	route.commissioned_tick = D4_Tick();
	route.updated_tick = D4_Tick();
	return { ok = true, route = registry.Summary(route), vehicle_id = vehicle.vehicle_id, cargo_type = cargo_pick.cargo_type, wagon_count = vehicle.wagon_count, reused_wagons = vehicle.reused_wagons, length = vehicle.length, capacity = vehicle.capacity };
}

function D4_VerifyRouteTopology(route, company_id) {
	local failures = [];
	if (!GSRail.IsRailStationTile(route.source_station_tile) || GSTile.GetOwner(route.source_station_tile) != company_id) failures.append({ reason = "source_station_missing", tile = route.source_station_tile });
	if (!GSRail.IsRailStationTile(route.destination_station_tile) || GSTile.GetOwner(route.destination_station_tile) != company_id) failures.append({ reason = "destination_station_missing", tile = route.destination_station_tile });
	local connected = D4_AreStationsConnectedByRail(route.source_station_tile, route.destination_station_tile, company_id);
	if (!connected) failures.append({ reason = "stations_not_connected" });
	if (D4_Has(route, "topology") && route.topology != null && D4_IsTable(route.topology) && D4_Has(route.topology, "kind") && route.topology.kind == "through_hub_roro") {
		local source = D4_VerifyThroughHubEndpointTopology(route.topology.source, "source");
		if (!source.ok) {
			foreach (f in source.failures) failures.append(f);
		}
		local destination = D4_VerifyThroughHubEndpointTopology(route.topology.destination, "destination");
		if (!destination.ok) {
			foreach (f2 in destination.failures) failures.append(f2);
		}
		local trunks = D4_VerifyThroughHubTrunks(route.topology);
		if (!trunks.ok) {
			foreach (f3 in trunks.failures) failures.append(f3);
		}
	}
	return { ok = failures.len() == 0, failures = failures };
}

function D4_AreStationsConnectedByRail(source_tile, destination_tile, company_id) {
	if (!GSRail.IsRailStationTile(source_tile) || !GSRail.IsRailStationTile(destination_tile)) return false;
	local source = D4_FromTile(source_tile);
	local dest = D4_FromTile(destination_tile);
	local frontier = [source];
	local visited = {};
	visited[D4_PointKey(source)] <- true;
	local guard = 0;
	while (frontier.len() > 0 && guard < 2048) {
		guard++;
		local current = frontier.remove(0);
		if (current.x == dest.x && current.y == dest.y) return true;
		for (local dir = 0; dir < 4; dir++) {
			local next = D4_Offset(current, dir, 1);
			if (!D4_IsPointOnMap(next)) continue;
			local nkey = D4_PointKey(next);
			if (nkey in visited) continue;
			local tile = D4_ToTile(next);
			if (!GSMap.IsValidTile(tile)) continue;
			if (GSTile.GetOwner(tile) != company_id) continue;
			if (!GSRail.IsRailTile(tile) && !GSRail.IsRailStationTile(tile) && !GSRail.IsRailDepotTile(tile)) continue;
			visited[nkey] <- true;
			frontier.append(next);
		}
	}
	return false;
}

function D4_FindRouteDepotTile(plan) {
	if (!D4_IsTable(plan) || !D4_Has(plan, "build_program") || !D4_IsTable(plan.build_program) || !plan.build_program.ok) return null;
	foreach (op in plan.build_program.ops) {
		if (op.kind == "depot" && GSMap.IsValidTile(op.tile)) return op.tile;
	}
	return null;
}

function D4_ConfigureRouteOrders(route, company_id, plan_store) {
	local plan = plan_store.GetPlan(route.plan_id);
	if (plan == null) return { ok = false, error = D4_Error("plan_not_found", route.route_id) };
	local depot_tile = D4_FindRouteDepotTile(plan);
	if (depot_tile == null || !GSRail.IsRailDepotTile(depot_tile) || GSTile.GetOwner(depot_tile) != company_id) return { ok = false, error = D4_Error("depot_missing", route.route_id) };
	local mode = GSCompanyMode(company_id);
	if (!GSCompanyMode.IsValid()) return { ok = false, error = D4_Error("invalid_company", company_id.tostring()) };
	if (!D4_SelectRailType()) return { ok = false, error = D4_Error("rail_type_unavailable", company_id.tostring()) };
	return { ok = true, depot_tile = depot_tile, source_tile = route.source_station_tile, destination_tile = route.destination_station_tile };
}

function D4_RoutePlatformLength(plan) {
	if (!D4_IsTable(plan) || !D4_Has(plan, "build_program") || !D4_IsTable(plan.build_program) || !D4_Has(plan.build_program, "ops")) return 1;
	foreach (op in plan.build_program.ops) {
		if (D4_IsTable(op) && D4_Has(op, "op_id") && op.op_id == "source_station" && D4_Has(op, "platform_length") && typeof op.platform_length == "integer") return op.platform_length;
	}
	return 1;
}

function D4_HasFreeWagonStockAtDepot(depot_tile) {
	local vehicles = GSVehicleList();
	for (local vehicle_id = vehicles.Begin(); !vehicles.IsEnd(); vehicle_id = vehicles.Next()) {
		if (!GSVehicle.IsValidVehicle(vehicle_id) || GSVehicle.IsPrimaryVehicle(vehicle_id)) continue;
		if (GSVehicle.GetVehicleType(vehicle_id) != GSVehicle.VT_RAIL) continue;
		if (GSVehicle.IsStoppedInDepot(vehicle_id) && GSVehicle.GetLocation(vehicle_id) == depot_tile) return true;
	}
	return false;
}

function D4_BuildRouteVehicle(route, company_id, plan_store) {
	local plan = plan_store.GetPlan(route.plan_id);
	if (plan == null) return { ok = false, error = D4_Error("plan_not_found", route.route_id) };
	local orders = D4_ConfigureRouteOrders(route, company_id, plan_store);
	if (!orders.ok) return { ok = false, error = orders.error };
	local mode = GSCompanyMode(company_id);
	if (!GSCompanyMode.IsValid()) return { ok = false, error = D4_Error("invalid_company", company_id.tostring()) };
	if (!D4_SelectRailType()) return { ok = false, error = D4_Error("rail_type_unavailable", company_id.tostring()) };
	local rail_type = GSRail.GetCurrentRailType();
	local engine_id = D4_FindBuildableRailEngine(route.cargo_type, rail_type);
	if (engine_id == null) return { ok = false, error = D4_Error("no_suitable_engine", route.cargo_type.tostring()) };
	local wagon_engine = null;
	for (local candidate = 0; candidate < 2048; candidate++) {
		if (!GSEngine.IsValidEngine(candidate) || !GSEngine.IsBuildable(candidate)) continue;
		if (GSEngine.GetVehicleType(candidate) != GSVehicle.VT_RAIL || !GSEngine.IsWagon(candidate)) continue;
		if (!GSEngine.CanRunOnRail(candidate, rail_type)) continue;
		if (!GSEngine.CanRefitCargo(candidate, route.cargo_type)) continue;
		wagon_engine = candidate;
		break;
	}
	if (wagon_engine == null) return { ok = false, error = D4_Error("no_suitable_wagon", route.cargo_type.tostring()) };
	local target_wagons = D4_ClampInt(D4_Has(plan.policy, "wagon_count") ? plan.policy.wagon_count : 1, 1, 1, 12);
	if (D4_HasFreeWagonStockAtDepot(orders.depot_tile)) return { ok = false, error = D4_Error("depot_free_stock_present", orders.depot_tile.tostring()) };
	local estimated_vehicle_cost = GSEngine.GetPrice(engine_id) + GSEngine.GetPrice(wagon_engine) * target_wagons;
	if (!D4_EnsureCompanyFunds(company_id, estimated_vehicle_cost)) return { ok = false, error = D4_Error("insufficient_commission_funds", estimated_vehicle_cost.tostring()) };
	local vehicle_id = GSVehicle.BuildVehicle(orders.depot_tile, engine_id);
	if (!GSVehicle.IsValidVehicle(vehicle_id)) return { ok = false, error = D4_Error("vehicle_build_failed", engine_id.tostring()) };
	local build_cost = GSEngine.GetPrice(engine_id);
	local built_wagons = 0;
	local platform_units = D4_RoutePlatformLength(plan) * 16;
	for (local index = 0; index < target_wagons; index++) {
		local wagon_id = GSVehicle.BuildVehicle(orders.depot_tile, wagon_engine);
		if (!GSVehicle.IsValidVehicle(wagon_id)) {
			GSVehicle.SellVehicle(vehicle_id);
			return { ok = false, error = D4_Error("wagon_build_failed", wagon_engine.tostring()) };
		}
		local destination_wagon = GSVehicle.GetNumWagons(vehicle_id) - 1;
		if (!GSVehicle.MoveWagon(wagon_id, 0, vehicle_id, destination_wagon)) {
			GSVehicle.SellWagonChain(wagon_id, 0);
			GSVehicle.SellVehicle(vehicle_id);
			return { ok = false, error = D4_Error("wagon_move_failed", wagon_id.tostring() + ":0") };
		}
		local consist_length = GSVehicle.GetLength(vehicle_id);
		if (consist_length > platform_units) {
			GSVehicle.SellVehicle(vehicle_id);
			return { ok = false, error = D4_Error("platform_too_short", consist_length.tostring() + ":" + platform_units.tostring()) };
		}
		if (!GSVehicle.RefitVehicle(vehicle_id, route.cargo_type)) {
			GSVehicle.SellVehicle(vehicle_id);
			return { ok = false, error = D4_Error("vehicle_refit_failed", route.cargo_type.tostring()) };
		}
		built_wagons++;
		build_cost += GSEngine.GetPrice(wagon_engine);
	}
	if (built_wagons < 1 || GSVehicle.GetCapacity(vehicle_id, route.cargo_type) < 1) {
		GSVehicle.SellVehicle(vehicle_id);
		return { ok = false, error = D4_Error("wagon_assembly_failed", built_wagons.tostring()) };
	}
	local flags_source = GSOrder.OF_FULL_LOAD;
	local flags_dest = GSOrder.OF_UNLOAD;
	if (!GSOrder.AppendOrder(vehicle_id, route.source_station_tile, flags_source)) {
		GSVehicle.SellVehicle(vehicle_id);
		return { ok = false, error = D4_Error("append_source_order_failed", vehicle_id.tostring()) };
	}
	if (!GSOrder.AppendOrder(vehicle_id, route.destination_station_tile, flags_dest)) {
		GSVehicle.SellVehicle(vehicle_id);
		return { ok = false, error = D4_Error("append_destination_order_failed", vehicle_id.tostring()) };
	}
	if (!GSOrder.AppendOrder(vehicle_id, orders.depot_tile, GSOrder.OF_SERVICE_IF_NEEDED | GSOrder.OF_NON_STOP_INTERMEDIATE)) {
		GSOrder.RemoveOrder(vehicle_id, 0);
		GSVehicle.SellVehicle(vehicle_id);
		return { ok = false, error = D4_Error("append_depot_order_failed", vehicle_id.tostring()) };
	}
	return { ok = true, vehicle_id = vehicle_id, build_cost = build_cost, wagon_count = built_wagons, reused_wagons = 0, length = GSVehicle.GetLength(vehicle_id), capacity = GSVehicle.GetCapacity(vehicle_id, route.cargo_type) };
}

function D4_UpdateRouteHealth(route) {
	local topology = D4_VerifyRouteTopology(route, route.company_id);
	route.health.topology_ok = topology.ok;
	local orders_ok = true;
	foreach (v in route.vehicles) {
		if (!GSVehicle.IsValidVehicle(v.vehicle_id)) continue;
		if (GSOrder.GetOrderCount(v.vehicle_id) < 2) { orders_ok = false; break; }
	}
	route.health.orders_ok = orders_ok && route.vehicles.len() > 0;
	local running = false;
	local profit_total = 0;
	local last_year = 0;
	local this_year = 0;
	foreach (v in route.vehicles) {
		if (!GSVehicle.IsValidVehicle(v.vehicle_id)) continue;
		if (GSVehicle.GetState(v.vehicle_id) == GSVehicle.VS_RUNNING || GSVehicle.GetState(v.vehicle_id) == GSVehicle.VS_AT_STATION) running = true;
		local p_last = GSVehicle.GetProfitLastYear(v.vehicle_id);
		local p_this = GSVehicle.GetProfitThisYear(v.vehicle_id);
		last_year += p_last;
		this_year += p_this;
		profit_total += p_last + p_this;
	}
	route.health.vehicle_running = running;
	route.health.positive_revenue = profit_total > 0;
	route.economics.last_year_profit = last_year;
	route.economics.this_year_profit = this_year;
	route.economics.lifetime_profit = profit_total;
	route.health.last_check_tick = D4_Tick();
	return { topology_ok = topology.ok, orders_ok = route.health.orders_ok, vehicle_running = running, positive_revenue = profit_total > 0 };
}

function D4_RouteRuntimeSnapshot(route) {
	local vehicles = [];
	foreach (entry in route.vehicles) {
		if (!GSVehicle.IsValidVehicle(entry.vehicle_id)) {
			vehicles.append({ vehicle_id = entry.vehicle_id, valid = false });
			continue;
		}
		local order_destinations = [];
		local order_count = GSOrder.GetOrderCount(entry.vehicle_id);
		for (local i = 0; i < order_count && i < 16; i++) order_destinations.append(GSOrder.GetOrderDestination(entry.vehicle_id, i));
		vehicles.append({
			vehicle_id = entry.vehicle_id,
			valid = true,
			state = GSVehicle.GetState(entry.vehicle_id),
			location = GSVehicle.GetLocation(entry.vehicle_id),
			current_order = GSOrder.ResolveOrderPosition(entry.vehicle_id, GSOrder.ORDER_CURRENT),
			order_destinations = order_destinations,
			cargo_load = GSVehicle.GetCargoLoad(entry.vehicle_id, route.cargo_type),
			cargo_capacity = GSVehicle.GetCapacity(entry.vehicle_id, route.cargo_type),
			profit_last_year = GSVehicle.GetProfitLastYear(entry.vehicle_id),
			profit_this_year = GSVehicle.GetProfitThisYear(entry.vehicle_id),
		});
	}
	local source_station_id = GSStation.GetStationID(route.source_station_tile);
	local destination_station_id = GSStation.GetStationID(route.destination_station_tile);
	return {
		tick = D4_Tick(),
		vehicles = vehicles,
		source = {
			station_id = source_station_id,
			station_tile = route.source_station_tile,
			cargo_waiting = GSStation.IsValidStation(source_station_id) ? GSStation.GetCargoWaiting(source_station_id, route.cargo_type) : -1,
			cargo_rating = GSStation.IsValidStation(source_station_id) ? GSStation.GetCargoRating(source_station_id, route.cargo_type) : -1,
			industry_id = route.source_industry_id,
			last_month_production = GSIndustry.IsValidIndustry(route.source_industry_id) ? GSIndustry.GetLastMonthProduction(route.source_industry_id, route.cargo_type) : -1,
			last_month_transported = GSIndustry.IsValidIndustry(route.source_industry_id) ? GSIndustry.GetLastMonthTransported(route.source_industry_id, route.cargo_type) : -1,
		},
		destination = {
			station_id = destination_station_id,
			station_tile = route.destination_station_tile,
			cargo_waiting = GSStation.IsValidStation(destination_station_id) ? GSStation.GetCargoWaiting(destination_station_id, route.cargo_type) : -1,
			industry_id = route.destination_industry_id,
		},
	};
}

function D4_VerifyRoute(registry, route_id, company_id, level) {
	local route = registry.Get(route_id);
	if (route == null) return { ok = false, error = D4_Error("route_not_found", route_id) };
	if (route.company_id != company_id) return { ok = false, error = D4_Error("company_mismatch", route_id) };
	local health = D4_UpdateRouteHealth(route);
	if (level == "topology") return { ok = health.topology_ok, health = health };
	if (level == "commissioning") return { ok = health.topology_ok && health.orders_ok && route.state == "commissioned", health = health };
	if (level == "economic") {
		local result = health.topology_ok && health.orders_ok && health.vehicle_running && health.positive_revenue;
		if (!result && health.positive_revenue == false) registry.AddAlert(route_id, "warning", "not_yet_profitable", "revenue_check_pending");
		return { ok = result, health = health, economics = route.economics, runtime = D4_RouteRuntimeSnapshot(route) };
	}
	return { ok = false, error = D4_Error("invalid_level", level) };
}
