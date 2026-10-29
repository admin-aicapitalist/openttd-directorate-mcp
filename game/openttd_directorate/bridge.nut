class DirectorateM4Bridge {
	store = null;
	replay = null;
	replay_order = null;

	constructor(store) {
		this.store = store;
		this.replay = {};
		this.replay_order = [];
	}

	function Poll() {
		local limit = D4_ClampInt(GSController.GetSetting("poll_limit"), 4, 1, 16);
		for (local i = 0; i < limit && GSEventController.IsEventWaiting(); i++) {
			local event = GSEventController.GetNextEvent();
			if (event == null || event.GetEventType() != GSEvent.ET_ADMIN_PORT) continue;
			local admin_event = GSEventAdminPort.Convert(event);
			if (admin_event == null) continue;
			this.Handle(admin_event.GetObject());
		}
	}

	function Handle(request) {
		local validation = this.ValidateEnvelope(request);
		if (!validation.ok) {
			this.Send("invalid", { ok = false, error = validation.error });
			return;
		}
		local id = request.request_id;
		local fingerprint = D4_BoundedFingerprint({ op = request.op, payload = request.payload });
		if (id in this.replay) {
			local cached = this.replay[id];
			if (cached.fingerprint != fingerprint) {
				this.SendPrepared({ request_id = id, ok = false, payload = {}, error = D4_Error("request_id_reuse_mismatch", id), protocol = DIRECTORATE_M4_PROTOCOL_VERSION });
				return;
			}
			this.SendPrepared(cached.response);
			return;
		}
		local response = this.Dispatch(id, request.op, request.payload);
		this.Remember(id, fingerprint, response);
		this.SendPrepared(response);
	}

	function ValidateEnvelope(request) {
		if (!D4_IsTable(request)) return { ok = false, error = D4_Error("invalid_envelope", "request must be table") };
		if (!("request_id" in request) || typeof request.request_id != "string" || request.request_id.len() < 1 || request.request_id.len() > 128) return { ok = false, error = D4_Error("invalid_request_id", "") };
		if (!("op" in request) || typeof request.op != "string" || request.op.len() < 1 || request.op.len() > 32) return { ok = false, error = D4_Error("invalid_op", "") };
		if (!("payload" in request) || !D4_IsTable(request.payload)) return { ok = false, error = D4_Error("invalid_payload", "payload must be table") };
		local bytes = D4_JsonEncode(request).len();
		if (bytes > DIRECTORATE_M4_MAX_REQUEST_BYTES) return { ok = false, error = D4_Error("request_too_large", bytes.tostring()) };
		return { ok = true };
	}

	function Dispatch(id, op, payload) {
		local result = null;
		if (op == "observe") result = this.store.Observe(payload);
		else if (op == "plan") result = this.HandlePlan(payload);
		else if (op == "apply") result = this.HandleApply(payload);
		else if (op == "verify") result = this.HandleVerify(payload);
		else if (op == "execute") result = this.HandleExecute(payload);
		else result = { ok = false, error = D4_Error("unknown_op", op) };
		if (!("payload" in result)) result.payload <- {};
		if (!("error" in result)) result.error <- null;
		return { request_id = id, ok = result.ok, payload = result.payload, error = result.error, protocol = DIRECTORATE_M4_PROTOCOL_VERSION };
	}

	function HandlePlan(payload) {
		if (!("company_id" in payload) || typeof payload.company_id != "integer") return { ok = false, error = D4_Error("invalid_company", "") };
		if (!("intent" in payload) || !D4_IsTable(payload.intent)) return { ok = false, error = D4_Error("invalid_intent", "") };
		local policy = D4_Has(payload, "policy") && D4_IsTable(payload.policy) ? payload.policy : {};
		local plan_id = D4_Has(payload, "plan_id") ? D4_StringOr(payload.plan_id, null, 128) : null;
		local revision = D4_Has(payload, "revision") && typeof payload.revision == "integer" ? payload.revision : null;
		return this.store.CreateOrAdvance(payload.company_id, payload.intent, policy, plan_id, revision);
	}

	function HandleApply(payload) {
		foreach (key, value in payload) {
			if (key != "company_id" && key != "plan_id" && key != "revision" && key != "phase" && key != "reserve" && key != "operation_id" && key != "target_operation_id") return { ok = false, error = D4_Error("invalid_apply_field", key) };
		}
		if (!("company_id" in payload) || typeof payload.company_id != "integer") return { ok = false, error = D4_Error("invalid_company", "") };
		if (!("plan_id" in payload) || typeof payload.plan_id != "string") return { ok = false, error = D4_Error("invalid_plan_id", "") };
		if (!("revision" in payload) || typeof payload.revision != "integer") return { ok = false, error = D4_Error("invalid_revision", "") };
		if (!("phase" in payload) || typeof payload.phase != "string") return { ok = false, error = D4_Error("invalid_phase", "") };
		if (D4_Has(payload, "reserve") && typeof payload.reserve != "integer") return { ok = false, error = D4_Error("invalid_reserve", "") };
		if (D4_Has(payload, "operation_id") && typeof payload.operation_id != "string") return { ok = false, error = D4_Error("invalid_operation_id", "") };
		if (D4_Has(payload, "target_operation_id") && typeof payload.target_operation_id != "string") return { ok = false, error = D4_Error("invalid_target_operation_id", "") };
		local options = {};
		if (D4_Has(payload, "reserve") && typeof payload.reserve == "integer") options.reserve <- payload.reserve;
		if (D4_Has(payload, "operation_id") && typeof payload.operation_id == "string") options.operation_id <- payload.operation_id;
		if (D4_Has(payload, "target_operation_id") && typeof payload.target_operation_id == "string") options.target_operation_id <- payload.target_operation_id;
		local result = this.store.Apply(payload.company_id, payload.plan_id, payload.revision, payload.phase, options);
		/* The bridge envelope owns the `payload` field. Apply internals return a
		 * rich operation result directly on both success and failure; always wrap
		 * it so failed_op, readback, verification, and rollback evidence survive
		 * Dispatch instead of being replaced by an empty payload. */
		return { ok = result.ok, payload = result, error = D4_Has(result, "error") ? result.error : null };
	}

	function HandleVerify(payload) {
		if (!("company_id" in payload) || typeof payload.company_id != "integer") return { ok = false, error = D4_Error("invalid_company", "") };
		local targets = 0;
		if (D4_Has(payload, "route_id")) {
			if (typeof payload.route_id != "string") return { ok = false, error = D4_Error("invalid_route_id", "") };
			targets++;
		}
		if (D4_Has(payload, "plan_id")) {
			if (typeof payload.plan_id != "string") return { ok = false, error = D4_Error("invalid_plan_id", "") };
			targets++;
		}
		if (D4_Has(payload, "operation_id")) {
			if (typeof payload.operation_id != "string") return { ok = false, error = D4_Error("invalid_operation_id", "") };
			targets++;
		}
		if (targets != 1) return { ok = false, error = D4_Error("invalid_verify_target", "exactly one target required") };
		local level = D4_Has(payload, "level") && typeof payload.level == "string" ? payload.level : "topology";
		if (D4_Has(payload, "route_id")) return this.store.Verify(payload.company_id, payload.route_id, level, false, true);
		if (D4_Has(payload, "plan_id")) return this.store.Verify(payload.company_id, payload.plan_id, level);
		return this.store.Verify(payload.company_id, payload.operation_id, level, true);
	}

	function HandleExecute(payload) {
		if (!("company_id" in payload) || typeof payload.company_id != "integer") return { ok = false, error = D4_Error("invalid_company", "") };
		if (!("command" in payload) || typeof payload.command != "string") return { ok = false, error = D4_Error("invalid_command", "") };
		if (payload.command == "inspect_plan_curves") {
			if (!("params" in payload) || !D4_IsTable(payload.params) || !("plan_id" in payload.params) || typeof payload.params.plan_id != "string") return { ok = false, error = D4_Error("invalid_curve_inspection", "") };
			local plan = this.store.GetPlan(payload.params.plan_id);
			if (plan == null || !D4_Has(plan, "build_program") || !D4_Has(plan.build_program, "ops")) return { ok = false, error = D4_Error("plan_not_found", payload.params.plan_id) };
			local outbound = [];
			local returned = [];
			local platform_length = null;
			local truncated = false;
			foreach (op in plan.build_program.ops) {
				if (D4_IsTable(op) && D4_Has(op, "kind") && op.kind == "station_rect" && D4_Has(op, "op_id") && op.op_id == "source_station" && D4_Has(op, "platform_length")) platform_length = op.platform_length;
				if (!D4_IsTable(op) || !D4_Has(op, "kind") || op.kind != "rail_connection" || !D4_Has(op, "op_id") || typeof op.op_id != "string" || !D4_Has(op, "tile")) continue;
				local target = null;
				if (op.op_id.find("rail.outbound.") == 0) target = outbound;
				else if (op.op_id.find("rail.return.") == 0) target = returned;
				if (target == null) continue;
				if (target.len() >= 256) { truncated = true; continue; }
				target.append(op.tile);
			}
			return { ok = true, payload = { plan_id = payload.params.plan_id, platform_length = platform_length, outbound = outbound, returned = returned, truncated = truncated } };
		}
		if (payload.command == "cancel_plan") {
			if (!("params" in payload) || !D4_IsTable(payload.params) || !("plan_id" in payload.params) || !("revision" in payload.params)) return { ok = false, error = D4_Error("invalid_cancel", "") };
			return this.store.Cancel(payload.company_id, payload.params.plan_id, payload.params.revision);
		}
		if (payload.command == "commission_route") {
			if (!("params" in payload) || !D4_IsTable(payload.params) || !("plan_id" in payload.params) || !("route_id" in payload.params)) return { ok = false, error = D4_Error("invalid_commission", "") };
			local options = {};
			if (D4_Has(payload.params, "cargo_label") && typeof payload.params.cargo_label == "string") options.cargo_label <- payload.params.cargo_label;
			local result = D4_CommissionRoute(this.store, this.store.registry, payload.company_id, payload.params.plan_id, payload.params.route_id, options);
			return { ok = result.ok, payload = result, error = D4_Has(result, "error") ? result.error : null };
		}
		if (payload.command == "list_industries") {
			if (!("params" in payload) || !D4_IsTable(payload.params) || !("cargo_label" in payload.params) || typeof payload.params.cargo_label != "string" || !("role" in payload.params) || typeof payload.params.role != "string") return { ok = false, error = D4_Error("invalid_industry_query", "") };
			local limit = D4_Has(payload.params, "limit") && typeof payload.params.limit == "integer" ? payload.params.limit : 32;
			return D4_ListIndustriesForCargo(payload.params.cargo_label, payload.params.role, limit);
		}
		if (payload.command == "survey_sites") {
			if (!("params" in payload) || !D4_IsTable(payload.params) || !("industry_id" in payload.params) || !("template" in payload.params)) return { ok = false, error = D4_Error("invalid_survey", "") };
			local policy = D4_Has(payload.params, "policy") && D4_IsTable(payload.params.policy) ? payload.params.policy : {};
			local role = D4_Has(payload.params, "role") ? payload.params.role : "source";
			return D4_SurveyStationSites(payload.company_id, payload.params.industry_id, role, payload.params.template, {}, policy);
		}
		/* tamago fork: let the operating agent borrow and repay like a player. The harness
		 * caps borrowing with params.max_fraction (share of the game's maximum loan). */
		if (payload.command == "loan_status" || payload.command == "set_loan") {
			local mode = GSCompanyMode(payload.company_id);
			if (!GSCompanyMode.IsValid()) return { ok = false, error = D4_Error("invalid_company", payload.company_id.tostring()) };
			local maximum = GSCompany.GetMaxLoanAmount();
			local interval = GSCompany.GetLoanInterval();
			if (payload.command == "set_loan") {
				if (!("params" in payload) || !D4_IsTable(payload.params) || !("amount" in payload.params) || typeof payload.params.amount != "integer") return { ok = false, error = D4_Error("invalid_loan_amount", "") };
				local fraction = D4_Has(payload.params, "max_fraction") && typeof payload.params.max_fraction == "integer" ? payload.params.max_fraction : 100;
				local cap = maximum / 100 * D4_ClampInt(fraction, 100, 0, 100);
				cap = cap - cap % interval;
				local target = D4_ClampInt(payload.params.amount, 0, 0, cap);
				target = ((target + interval - 1) / interval) * interval;
				if (target > cap) target = cap;
				if (target != GSCompany.GetLoanAmount() && !GSCompany.SetLoanAmount(target)) {
					return { ok = false, error = D4_Error("loan_change_refused", target.tostring()), payload = { loan = GSCompany.GetLoanAmount(), bank_balance = GSCompany.GetBankBalance(payload.company_id), allowed_max = cap } };
				}
			}
			return { ok = true, payload = { loan = GSCompany.GetLoanAmount(), bank_balance = GSCompany.GetBankBalance(payload.company_id), game_max_loan = maximum, interval = interval } };
		}
		/* tamago fork: give an already built exit-only depot siding its entry curve
		 * (see D4_DepotOperation), so trains can reach their service depot. */
		if (payload.command == "repair_depot_access") {
			if (!("params" in payload) || !D4_IsTable(payload.params) || !("plan_id" in payload.params) || typeof payload.params.plan_id != "string") return { ok = false, error = D4_Error("invalid_repair", "") };
			local plan = this.store.GetPlan(payload.params.plan_id);
			if (plan == null || plan.company_id != payload.company_id || !D4_Has(plan, "build_program") || !D4_Has(plan.build_program, "ops")) return { ok = false, error = D4_Error("plan_not_found", payload.params.plan_id) };
			local access = null;
			local depot = null;
			foreach (op in plan.build_program.ops) {
				if (!D4_IsTable(op) || !D4_Has(op, "op_id")) continue;
				if (op.op_id == "rail.depot_access.0") access = op;
				if (op.op_id == "depot.0") depot = op;
			}
			if (access == null || depot == null) return { ok = false, error = D4_Error("depot_not_in_plan", payload.params.plan_id) };
			local fx = GSMap.GetTileX(access.tile), fy = GSMap.GetTileY(access.tile);
			local entry = GSMap.GetTileIndex(2 * fx - GSMap.GetTileX(access.next), 2 * fy - GSMap.GetTileY(access.next));
			if (access.prev != depot.tile) return { ok = false, error = D4_Error("depot_not_exit_only", payload.params.plan_id) };
			local mode = GSCompanyMode(payload.company_id);
			if (!GSCompanyMode.IsValid()) return { ok = false, error = D4_Error("invalid_company", payload.company_id.tostring()) };
			if (!D4_SelectRailType()) return { ok = false, error = D4_Error("rail_type_unavailable", "") };
			local money_before = GSCompany.GetBankBalance(payload.company_id);
			if (!GSRail.AreTilesConnected(entry, access.tile, depot.tile) && !GSRail.BuildRail(entry, access.tile, depot.tile)) {
				return { ok = false, error = D4_Error("repair_failed", GSError.GetLastErrorString()) };
			}
			return { ok = true, payload = { plan_id = payload.params.plan_id, front = [fx, fy], connected = GSRail.AreTilesConnected(entry, access.tile, depot.tile), cost = money_before - GSCompany.GetBankBalance(payload.company_id) } };
		}
		/* tamago fork: read-only probe of the rail, signals and one train in a map
		 * rectangle, for diagnosing routes a train cannot reach. */
		if (payload.command == "inspect_area") {
			local p = D4_Has(payload, "params") && D4_IsTable(payload.params) ? payload.params : {};
			if (!D4_Has(p, "x0") || !D4_Has(p, "y0") || !D4_Has(p, "x1") || !D4_Has(p, "y1")) return { ok = false, error = D4_Error("invalid_area", "") };
			local dirs = [[1, 0], [-1, 0], [0, 1], [0, -1]];
			local tiles = [];
			for (local y = p.y0; y <= p.y1 && tiles.len() < 1500; y++) {
				for (local x = p.x0; x <= p.x1; x++) {
					local t = GSMap.GetTileIndex(x, y);
					if (!GSMap.IsValidTile(t) || (!GSRail.IsRailTile(t) && !GSRail.IsRailDepotTile(t))) continue;
					local e = { x = x, y = y, tracks = GSRail.GetRailTracks(t) };
					if (GSRail.IsRailStationTile(t)) e.station <- GSStation.GetStationID(t);
					if (GSRail.IsRailDepotTile(t)) {
						local f = GSRail.GetRailDepotFrontTile(t);
						e.depot_front <- [GSMap.GetTileX(f), GSMap.GetTileY(f)];
					}
					if (GSBridge.IsBridgeTile(t)) e.bridge <- true;
					if (GSTunnel.IsTunnelTile(t)) e.tunnel <- true;
					local signals = [];
					foreach (d in dirs) {
						local s = GSRail.GetSignalType(t, GSMap.GetTileIndex(x + d[0], y + d[1]));
						if (s != GSRail.SIGNALTYPE_NONE) signals.append([d[0], d[1], s]);
					}
					if (signals.len() > 0) e.signals <- signals;
					tiles.append(e);
				}
			}
			local vehicles = [];
			if (D4_Has(p, "vehicle_id") && GSVehicle.IsValidVehicle(p.vehicle_id)) {
				local v = p.vehicle_id;
				local loc = GSVehicle.GetLocation(v);
				local orders = [];
				for (local i = 0; i < GSOrder.GetOrderCount(v); i++) {
					local dst = GSOrder.GetOrderDestination(v, i);
					orders.append({ x = GSMap.GetTileX(dst), y = GSMap.GetTileY(dst), flags = GSOrder.GetOrderFlags(v, i) });
				}
				vehicles.append({ id = v, x = GSMap.GetTileX(loc), y = GSMap.GetTileY(loc), state = GSVehicle.GetState(v),
					speed = GSVehicle.GetCurrentSpeed(v), current = GSOrder.ResolveOrderPosition(v, GSOrder.ORDER_CURRENT), orders = orders });
			}
			return { ok = true, payload = { tiles = tiles, vehicles = vehicles } };
		}
		/* tamago fork: what the stream camera director is doing. */
		if (payload.command == "camera_status") return { ok = true, payload = D4_Camera == null ? {} : D4_Camera.Status() };
		return { ok = false, error = D4_Error("unknown_command", payload.command) };
	}

	function Remember(id, fingerprint, response) {
		this.replay[id] <- { fingerprint = fingerprint, response = response };
		this.replay_order.append(id);
		while (this.replay_order.len() > DIRECTORATE_M4_REPLAY_LIMIT) {
			local old = this.replay_order.remove(0);
			if (old in this.replay) delete this.replay[old];
		}
	}

	function SendPrepared(response) {
		local json = D4_JsonEncode(response);
		if (json.len() > DIRECTORATE_M4_MAX_RESPONSE_JSON_BYTES) {
			/* tamago fork: keep the real outcome and the scalar summary fields; only drop
			 * bulky detail. Reporting ok=false here made successful builds look failed. */
			local summary = { truncated = true, full_bytes = json.len() };
			if (D4_Has(response, "payload") && D4_IsTable(response.payload)) {
				foreach (key, value in response.payload) {
					local kind = typeof value;
					if (kind == "integer" || kind == "string" || kind == "bool" || kind == "float") summary[key] <- value;
				}
			}
			local compact = { request_id = response.request_id, ok = response.ok, payload = summary };
			if (D4_Has(response, "error")) compact.error <- response.error;
			response = compact;
			json = D4_JsonEncode(response);
		}
		local count = ((json.len() + DIRECTORATE_M4_CHUNK_BYTES - 1) / DIRECTORATE_M4_CHUNK_BYTES).tointeger();
		if (count < 1) count = 1;
		for (local i = 0; i < count; i++) {
			local start = i * DIRECTORATE_M4_CHUNK_BYTES;
			local end = start + DIRECTORATE_M4_CHUNK_BYTES;
			if (end > json.len()) end = json.len();
			local part = json.slice(start, end);
			GSAdmin.Send({ request_id = response.request_id, chunk_index = i, chunk_count = count, chunk = part });
		}
	}
}
