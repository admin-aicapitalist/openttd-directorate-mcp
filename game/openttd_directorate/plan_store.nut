class DirectorateM4PlanStore {
	plans = null;
	order = null;
	next_id = 0;
	journal = null;
	registry = null;
	deferred_plans = null;
	deferred_plan_order = null;
	campaign_id = null;
	campaign_started_date = 0;
	campaign_started_tick = 0;

	constructor() {
		this.plans = {};
		this.order = [];
		this.journal = DirectorateM4OperationJournal();
		this.registry = DirectorateM4RouteRegistry();
		this.deferred_plans = {};
		this.deferred_plan_order = [];
		this.campaign_id = D4_NewUUID();
		this.campaign_started_date = GSDate.GetCurrentDate();
		this.campaign_started_tick = D4_Tick();
	}

	function Save() {
		local saved_plans = this.plans;
		local saved_order = this.order;
		if (this.deferred_plan_order.len() > 0) {
			saved_plans = {};
			saved_order = [];
			foreach (id in this.deferred_plan_order) { if (id in this.deferred_plans) { saved_plans[id] <- this.deferred_plans[id]; saved_order.append(id); } }
			foreach (id in this.order) { if (id in this.plans) { saved_plans[id] <- this.plans[id]; saved_order.append(id); } }
		}
		return { plans = saved_plans, order = saved_order, next_id = this.next_id, journal = this.journal.Save(), registry = this.registry.Save(), campaign_id = this.campaign_id, campaign_started_date = this.campaign_started_date, campaign_started_tick = this.campaign_started_tick };
	}

	function Load(data) { this.BeginLoad(data); }

	function BeginLoad(data) {
		this.plans = {};
		this.order = [];
		this.deferred_plans = {};
		this.deferred_plan_order = [];
		this.journal = DirectorateM4OperationJournal();
		this.registry = DirectorateM4RouteRegistry();
		if (!D4_IsTable(data) || !("plans" in data) || !D4_IsTable(data.plans) || !("order" in data) || !D4_IsArray(data.order) || data.order.len() > DIRECTORATE_M4_MAX_PLANS) {
			GSLog.Warning("D4 M4 plan-store load rejected shape");
			return;
		}
		if (D4_Has(data, "campaign_id") && typeof data.campaign_id == "string" && data.campaign_id.len() >= 8 && data.campaign_id.len() <= 64) this.campaign_id = data.campaign_id;
		if (D4_Has(data, "campaign_started_date") && typeof data.campaign_started_date == "integer") this.campaign_started_date = data.campaign_started_date;
		if (D4_Has(data, "campaign_started_tick") && typeof data.campaign_started_tick == "integer") this.campaign_started_tick = data.campaign_started_tick;
		this.deferred_plans = data.plans;
		this.deferred_plan_order = data.order;
		if ("next_id" in data && typeof data.next_id == "integer") this.next_id = D4_ClampInt(data.next_id, 0, 0, 1000000000);
		if ("journal" in data) this.journal.Load(data.journal);
		if ("registry" in data) this.registry.BeginLoad(data.registry);
	}

	function HydrateOnePlan() {
		if (this.deferred_plan_order.len() == 0) return;
		local id = this.deferred_plan_order.pop();
		if (!(id in this.deferred_plans)) return;
		local plan = this.deferred_plans[id];
		delete this.deferred_plans[id];
		if (typeof id != "string" || id.len() < 1 || id.len() > 128 || id in this.plans) return;
		if (!this.IsPlanSafe(plan, true, false) || plan.plan_id != id) { GSLog.Warning("D4 M4 plan-store load rejected plan " + id); return; }
		if (D4_UpgradeBuildProgram(plan)) {
			plan.revision++;
			plan.updated_tick = D4_Tick();
			GSLog.Info("D4 M4 upgraded build program " + id + " to v" + DIRECTORATE_M4_BUILD_PROGRAM_VERSION);
		}
		if (D4_Has(plan, "build_program") && D4_IsTable(plan.build_program) && D4_Has(plan.build_program, "ok") && plan.build_program.ok && (!D4_Has(plan.build_program, "version") || !D4_IsAcceptedBuildProgramVersion(plan.build_program.version, false))) { GSLog.Warning("D4 M4 plan-store load rejected unmigrated plan " + id); return; }
		this.plans[id] <- plan;
		this.order.insert(0, id);
	}

	function GetPlan(plan_id) {
		if (plan_id in this.plans) {
			local plan = this.plans[plan_id];
			if (!this.IsPlanSafe(plan, false, true)) return null;
			return plan;
		}
		return null;
	}

	function Tick() {
		if (this.deferred_plan_order.len() > 0) { this.HydrateOnePlan(); return; }
		if (this.registry.HasDeferred()) { this.registry.HydrateOne(); return; }
		this.journal.HydrateOne();
		this.Retention();
	}

	function HasDeferredOperations() {
		return this.deferred_plan_order.len() > 0 || this.registry.HasDeferred() || this.journal.HasDeferred();
	}

	function CreateOrAdvance(company_id, intent, policy, requested_id, revision) {
		if (D4_ContainsForbiddenPlanningInput({ intent = intent, policy = policy }, 0)) {
			return { ok = false, error = D4_Error("forbidden_planning_input", "tile/path/waypoint inputs are rejected") };
		}
		local plan = null;
		if (requested_id != null && requested_id in this.plans) {
			plan = this.plans[requested_id];
			if (!this.IsPlanSafe(plan, false, true)) return { ok = false, error = D4_Error("unsafe_plan", requested_id) };
			local fence = this.RequireFence(plan, company_id, revision);
			if (!fence.ok) return fence;
			local requested_fingerprint = D4_StableFingerprint(company_id, intent, policy);
			if (requested_fingerprint != plan.precondition_fingerprint) return { ok = false, error = D4_Error("plan_input_mismatch", requested_id) };
			if (plan.state == "cancelled" || plan.state == "completed" || plan.state == "failed" || plan.state == "applied") return { ok = true, payload = this.Summary(plan) };
		} else {
			this.Retention();
			if (this.order.len() >= DIRECTORATE_M4_MAX_PLANS) return { ok = false, error = D4_Error("plan_capacity", DIRECTORATE_M4_MAX_PLANS.tostring()) };
			local id = requested_id;
			if (id == null || id == "") {
				this.next_id++;
				id = "plan-" + this.next_id;
			}
			if (!D4_IsValidPlanId(id)) return { ok = false, error = D4_Error("invalid_plan_id", "") };
			if (id in this.plans) return { ok = false, error = D4_Error("plan_exists", id) };
			local fingerprint = D4_StableFingerprint(company_id, intent, policy);
			plan = {
				plan_id = id,
				revision = 0,
				company_id = company_id,
				state = "ready",
				phase = "planning",
				policy = policy,
				intent = intent,
				created_tick = D4_Tick(),
				updated_tick = D4_Tick(),
				precondition_fingerprint = fingerprint,
				station_survey = null,
				source_site = null,
				destination_site = null,
				station_blueprint = { ok = false },
				destination_blueprint = { ok = false },
				outbound_trunk = { ok = false },
				return_trunk = { ok = false },
				depots = [],
				signals = [],
				build_program = { ok = false },
				cost = 0,
				operation_id = null,
			};
			this.plans[id] <- plan;
			this.order.append(id);
		}
		/* Station surveys use GSTestMode but still obey the company's cash gate.
		 * Keep a small, minimum-increment planning float for autonomous companies. */
		if (!D4_EnsureCompanyFunds(company_id, 10000)) return { ok = false, error = D4_Error("insufficient_planning_finance", "10000") };
		local result = this.AdvancePlan(plan);
		this.Retention();
		if (!result.ok) return result;
		return { ok = true, payload = this.Summary(plan) };
	}

	function AdvancePlan(plan) {
		if (plan.state != "ready" && plan.state != "planning") return { ok = true };
		if (!D4_Has(plan.intent, "source_industry_id") || !D4_Has(plan.intent, "destination_industry_id")) return { ok = false, error = D4_Error("missing_industry_ids", plan.plan_id) };
		local source_id = plan.intent.source_industry_id;
		local dest_id = plan.intent.destination_industry_id;
		local template = D4_StringOr(D4_Has(plan.policy, "station_template") ? plan.policy.station_template : null, "through_hub_4x7", 64);
		if (plan.phase == "planning") {
			GSLog.Info("D3 M4 planning source survey " + plan.plan_id);
			local source_survey = D4_SurveyStationSites(plan.company_id, source_id, "source", template, plan.intent, plan.policy);
			if (!source_survey.ok || source_survey.candidates.len() == 0) return { ok = false, error = D4_Error("source_site_not_found", source_id.tostring()), payload = { survey = source_survey } };
			GSLog.Info("D3 M4 planning destination survey " + plan.plan_id);
			local dest_survey = D4_SurveyStationSites(plan.company_id, dest_id, "destination", template, plan.intent, plan.policy);
			if (!dest_survey.ok || dest_survey.candidates.len() == 0) return { ok = false, error = D4_Error("destination_site_not_found", dest_id.tostring()), payload = { survey = dest_survey } };
			plan.station_survey = { source = source_survey, destination = dest_survey };
			/* Select orientation geometrically before invoking any yielding
			 * GSTestMode commands. Source and destination throats must face one
			 * another; otherwise the route endpoint continuation points through the
			 * back of the station and an open map is unsatisfiable. */
			local excluded_pairs = {};
			local pair = null;
			local pair_skip = D4_ClampInt(D4_Has(plan.policy, "site_pair_skip") ? plan.policy.site_pair_skip : 0, 0, 0, 15);
			/* Select a ranked alternative without running several yielding A* and
			 * preflight programs in one bridge request. Callers can advance the
			 * bounded site_pair_skip when a parallel lane is terrain-blocked. */
			for (local pair_rank = 0; pair_rank <= pair_skip; pair_rank++) {
				pair = D4_SelectBestSitePair(source_survey.candidates, dest_survey.candidates, excluded_pairs);
				if (pair == null) break;
				excluded_pairs[pair.source_index + ":" + pair.destination_index] <- true;
			}
			if (pair == null) return { ok = false, error = D4_Error("site_pair_orientation_not_found", plan.plan_id) };
			plan.source_site = pair.source;
			plan.destination_site = pair.destination;
			plan.station_blueprint = plan.source_site.blueprint;
			plan.destination_blueprint = plan.destination_site.blueprint;
			local candidate_program = D4_CompileBuildProgram(plan);
			local candidate_pf = candidate_program.ok ? D4_PreflightBuildProgram(candidate_program, plan.company_id, 0) : candidate_program;
			if (!candidate_program.ok || !candidate_pf.ok) return {
				ok = false,
				error = D4_Error("no_legal_site_pair", plan.plan_id),
				payload = {
					attempts = 1,
					pair_rank = pair_skip,
					source = { origin = plan.source_site.origin, rotation = plan.source_site.rotation },
					destination = { origin = plan.destination_site.origin, rotation = plan.destination_site.rotation },
					last_failure = candidate_pf,
				},
			};
			plan.build_program = candidate_program;
			plan.cost = candidate_pf.cost;
			plan.phase = "site_selected";
			plan.revision++;
			plan.updated_tick = D4_Tick();
		}
		if (plan.phase == "site_selected") {
			GSLog.Info("D3 M4 planning build program " + plan.plan_id);
			local program = D4_CompileBuildProgram(plan);
			if (!program.ok) return { ok = false, error = D4_Error("program_compile_failed", D4_Has(program, "error") ? program.error.detail : plan.plan_id), payload = { result = program } };
			plan.build_program = program;
			plan.outbound_trunk = { ok = true, tiles = program.path };
			plan.return_trunk = { ok = true, tiles = program.return_lane };
			plan.depots = [];
			plan.signals = [];
			plan.phase = "trunk_planned";
			plan.revision++;
			plan.updated_tick = D4_Tick();
		}
		if (plan.phase == "trunk_planned") {
			GSLog.Info("D3 M4 planning authoritative preflight " + plan.plan_id);
			if (!D4_Has(plan, "build_program") || !D4_IsTable(plan.build_program) || !plan.build_program.ok) {
				local rebuilt = D4_CompileBuildProgram(plan);
				if (!rebuilt.ok) return { ok = false, error = D4_Error("program_compile_failed", plan.plan_id), payload = { result = rebuilt } };
				plan.build_program = rebuilt;
			}
			local pf_program = D4_PreflightBuildProgram(plan.build_program, plan.company_id, 0);
			if (!pf_program.ok) return { ok = false, error = D4_Error("program_preflight_failed", plan.plan_id), payload = pf_program };
			plan.cost = pf_program.cost;
			plan.state = "ready";
			plan.phase = "ready";
			plan.revision++;
			plan.updated_tick = D4_Tick();
			GSLog.Info("D3 M4 plan ready " + plan.plan_id);
		}
		return { ok = true };
	}

	function Apply(company_id, plan_id, revision, phase, options) {
		local plan = this.GetPlan(plan_id);
		if (plan == null) return { ok = false, error = D4_Error("plan_not_found", plan_id) };
		if (plan.company_id != company_id) return { ok = false, error = D4_Error("company_mismatch", plan_id) };
		if (D4_Has(options, "operation_id")) {
			local existing = this.journal.Get(options.operation_id);
			if (existing != null) {
				local request_fingerprint = D4_ApplyRequestFingerprint(company_id, plan_id, revision, phase, options);
				local reuse = this.journal.ValidateReuse(existing, company_id, plan_id, revision, phase, request_fingerprint);
				if (!reuse.ok) return reuse;
				return this.journal.Replay(existing);
			}
		}
		if (plan.revision != revision) return { ok = false, error = D4_Error("revision_mismatch", plan.revision.tostring()) };
		if (phase == "preflight") return D4_RunApplyPhases(this, this.journal, company_id, plan_id, revision, phase, options);
		if (phase == "commit") {
			local fingerprint = D4_StableFingerprint(company_id, plan.intent, plan.policy);
			if (fingerprint != plan.precondition_fingerprint) return { ok = false, error = D4_Error("stale_fingerprint", plan_id) };
			local result = D4_RunApplyPhases(this, this.journal, company_id, plan_id, revision, phase, options);
			if (result.ok) {
				plan.state = "applied";
				plan.phase = "applied";
				plan.operation_id = result.operation_id;
				plan.revision++;
			}
			return result;
		}
		if (phase == "rollback") {
			local result = D4_RunApplyPhases(this, this.journal, company_id, plan_id, revision, phase, options);
			if (result.ok) {
				plan.state = "rolled_back";
				plan.phase = "rolled_back";
				plan.revision++;
				plan.updated_tick = D4_Tick();
			}
			return result;
		}
		return { ok = false, error = D4_Error("invalid_phase", phase) };
	}

	function Cancel(company_id, plan_id, revision) {
		local plan = this.GetPlan(plan_id);
		if (plan == null) return { ok = false, error = D4_Error("plan_not_found", plan_id) };
		local fence = this.RequireFence(plan, company_id, revision);
		if (!fence.ok) return fence;
		if (plan.state != "cancelled") {
			plan.state = "cancelled";
			plan.revision++;
			plan.updated_tick = D4_Tick();
			plan.phase = "cancelled";
		}
		return { ok = true, payload = this.Summary(plan) };
	}

	function Observe(request) {
		local limit = D4_ClampInt(D4_Has(request, "limit") ? request.limit : 64, 64, 1, 256);
		local scope = D4_Has(request, "scope") && typeof request.scope == "string" ? request.scope : "plans";
		local rows = [];
		if (scope == "routes") {
			return this.registry.Observe(request);
		}
		if (scope == "map") return { ok = true, payload = this.GameState() };
		if (scope == "company") {
			if (!D4_Has(request, "company_id")) return { ok = false, error = D4_Error("company_id_required", "company") };
			return D4_CompanySnapshot(request.company_id);
		}
		if (scope == "economy") {
			if (!D4_Has(request, "company_id")) return { ok = false, error = D4_Error("company_id_required", "economy") };
			local snapshot = D4_CompanySnapshot(request.company_id);
			if (!snapshot.ok) return snapshot;
			snapshot.payload.scope <- "economy";
			snapshot.payload.campaign_id <- this.campaign_id;
			return snapshot;
		}
		if (D4_Has(request, "route_id") && request.route_id in this.plans) {
			rows.append(this.Summary(this.plans[request.route_id]));
		} else {
			for (local i = this.order.len() - 1; i >= 0 && rows.len() < limit; i--) {
				local id = this.order[i];
				if (!(id in this.plans)) continue;
				local plan = this.plans[id];
				if (D4_Has(request, "company_id") && plan.company_id != request.company_id) continue;
				rows.append(this.Summary(plan));
			}
		}
		return { ok = true, payload = { scope = scope, plans = rows, campaign_id = this.campaign_id, tick = D4_Tick() } };
	}

	function GameState() {
		local current_date = GSDate.GetCurrentDate();
		return {
			scope = "map",
			campaign_id = this.campaign_id,
			campaign_started_date = this.campaign_started_date,
			campaign_started_tick = this.campaign_started_tick,
			current_date = current_date,
			current_year = GSDate.GetYear(current_date),
			map_size_x = GSMap.GetMapSizeX(),
			map_size_y = GSMap.GetMapSizeY(),
			tick = D4_Tick(),
		};
	}

	function Verify(company_id, plan_or_route_id, level, is_operation_id = false) {
		if (is_operation_id) return this.VerifyOperation(company_id, plan_or_route_id, level);
		local plan = this.GetPlan(plan_or_route_id);
		if (plan != null) {
			if (plan.company_id != company_id) return { ok = false, error = D4_Error("company_mismatch", plan_or_route_id) };
			return { ok = true, payload = { plan = this.Summary(plan), state = plan.state, operational = plan.state == "applied" } };
		}
		local route = this.registry.Get(plan_or_route_id);
		if (route != null) {
			local result = D4_VerifyRoute(this.registry, plan_or_route_id, company_id, level);
			return { ok = result.ok, payload = result, error = D4_Has(result, "error") ? result.error : null };
		}
		return { ok = false, error = D4_Error("route_or_plan_not_found", plan_or_route_id) };
	}

	function VerifyOperation(company_id, operation_id, level) {
		local op = this.journal.Get(operation_id);
		if (op == null) return { ok = false, error = D4_Error("operation_not_found", operation_id) };
		if (op.company_id != company_id) return { ok = false, error = D4_Error("company_mismatch", operation_id) };
		local result = this.journal.Replay(op);
		if (!result.ok) {
			if (result.state == "in_progress" || result.state == "created") {
				return { ok = false, payload = { operation_id = operation_id, state = result.state, level = level }, error = result.error };
			}
			return { ok = false, payload = { operation_id = operation_id, state = result.state }, error = result.error };
		}
		return { ok = true, payload = { operation_id = operation_id, level = level, state = result.state, result = result, replayed = true } };
	}

	function RequireFence(plan, company_id, revision) {
		if (plan.company_id != company_id) return { ok = false, error = D4_Error("company_mismatch", plan.plan_id) };
		if (revision != null && plan.revision != revision) return { ok = false, error = D4_Error("revision_mismatch", plan.revision.tostring()) };
		return { ok = true };
	}

	function Summary(plan) {
		local source_site = D4_Has(plan, "source_site") && plan.source_site != null ? { origin = plan.source_site.origin, rotation = plan.source_site.rotation, score = plan.source_site.score } : null;
		local dest_site = D4_Has(plan, "destination_site") && plan.destination_site != null ? { origin = plan.destination_site.origin, rotation = plan.destination_site.rotation, score = plan.destination_site.score } : null;
		return {
			plan_id = plan.plan_id,
			revision = plan.revision,
			company_id = plan.company_id,
			state = plan.state,
			phase = plan.phase,
			created_tick = plan.created_tick,
			updated_tick = plan.updated_tick,
			precondition_fingerprint = plan.precondition_fingerprint,
			cost = plan.cost,
			operation_id = D4_Has(plan, "operation_id") ? plan.operation_id : null,
			build_program_version = D4_Has(plan, "build_program") && D4_IsTable(plan.build_program) && D4_Has(plan.build_program, "version") ? plan.build_program.version : null,
			build_program_ops = D4_Has(plan, "build_program") && D4_IsTable(plan.build_program) && D4_Has(plan.build_program, "ops") ? plan.build_program.ops.len() : 0,
			source_site = source_site,
			destination_site = dest_site,
		};
	}

	function IsPlanSafe(plan, allow_legacy = false, validate_program = true) {
		if (!D4_IsTable(plan)) return false;
		if (!("plan_id" in plan) || typeof plan.plan_id != "string" || plan.plan_id.len() < 1 || plan.plan_id.len() > 128) return false;
		if (!D4_IsValidPlanId(plan.plan_id)) return false;
		if (!("company_id" in plan) || typeof plan.company_id != "integer") return false;
		if (!("state" in plan) || typeof plan.state != "string") return false;
		if (!("revision" in plan) || typeof plan.revision != "integer" || plan.revision < 0) return false;
		if (!("intent" in plan) || !D4_IsTable(plan.intent)) return false;
		if (!("policy" in plan) || !D4_IsTable(plan.policy)) return false;
		if (!("precondition_fingerprint" in plan) || typeof plan.precondition_fingerprint != "string") return false;
		if (plan.precondition_fingerprint != D4_StableFingerprint(plan.company_id, plan.intent, plan.policy)) return false;
		if (!("phase" in plan) || typeof plan.phase != "string") return false;
		if (!("created_tick" in plan) || typeof plan.created_tick != "integer") return false;
		if (!("updated_tick" in plan) || typeof plan.updated_tick != "integer") return false;
		if (!D4_Has(plan, "build_program")) plan.build_program <- { ok = false };
		if (D4_IsTable(plan.build_program) && D4_Has(plan.build_program, "ok") && plan.build_program.ok) {
			if (!D4_Has(plan.build_program, "version") || !D4_IsAcceptedBuildProgramVersion(plan.build_program.version, allow_legacy)) return false;
			if (!D4_Has(plan.build_program, "ops") || !D4_IsArray(plan.build_program.ops) || plan.build_program.ops.len() > DIRECTORATE_M4_MAX_OPERATION_ENTRIES) return false;
			if (!D4_Has(plan.build_program, "path") || !D4_IsArray(plan.build_program.path) || plan.build_program.path.len() < 2 || plan.build_program.path.len() > DIRECTORATE_M4_MAX_OPERATION_ENTRIES) return false;
			if (!D4_IsPointOnMap(plan.build_program.path[0]) || !D4_IsPointOnMap(plan.build_program.path[plan.build_program.path.len() - 1])) return false;
			if (D4_Has(plan.build_program, "return_lane")) {
				if (!D4_IsArray(plan.build_program.return_lane) || plan.build_program.return_lane.len() > DIRECTORATE_M4_MAX_OPERATION_ENTRIES) return false;

			}
			if (plan.build_program.version == DIRECTORATE_M4_BUILD_PROGRAM_VERSION && D4_IsThroughHubBlueprint(plan.station_blueprint) && (!D4_Has(plan.build_program, "topology") || !D4_IsSafeThroughHubTopology(plan.build_program.topology))) return false;
			if (validate_program) {
				local validation = D4_ValidateBuildProgram(plan.build_program.ops);
				if (!validation.ok) return false;
			}
		}
		return true;
	}

	function Retention() {
		local retention = GSController.GetSetting("retention_limit");
		retention = D4_ClampInt(retention, 64, 8, 256);
		local terminal_seen = 0;
		for (local i = this.order.len() - 1; i >= 0; i--) {
			local id = this.order[i];
			if (!(id in this.plans)) continue;
			local plan = this.plans[id];
			/* Failed or timed-out planning requests never crossed a revision fence
			 * and contain no reusable build program. Drop them before Save/Load can
			 * accumulate enough dead envelopes to exhaust OpenTTD's Load budget. */
			if (plan.revision == 0 && plan.phase == "planning" && (!D4_Has(plan, "build_program") || !D4_IsTable(plan.build_program) || !D4_Has(plan.build_program, "ok") || !plan.build_program.ok)) {
				delete this.plans[id];
				continue;
			}
			local state = plan.state;
			if (state == "applied" || state == "cancelled" || state == "failed") {
				terminal_seen++;
				if (terminal_seen > retention) delete this.plans[id];
			}
		}
		local compact = [];
		foreach (id in this.order) {
			if (id in this.plans) compact.append(id);
		}
		this.order = compact;
	}
}

function D4_IsAcceptedBuildProgramVersion(version, allow_legacy_v1) {
	return version == DIRECTORATE_M4_BUILD_PROGRAM_VERSION || version == 2 || (allow_legacy_v1 && version == 1);
}

function D4_BuildPairedTrunk(source_site, dest_site) {
	local start = D4_BlueprintPortLocation(source_site.blueprint, "throat_ne");
	if (start == null) start = D4_BlueprintPortLocation(source_site.blueprint, "throat");
	local goal = D4_BlueprintPortLocation(dest_site.blueprint, "throat_sw");
	if (goal == null) goal = D4_BlueprintPortLocation(dest_site.blueprint, "throat");
	if (start == null || goal == null) return { ok = false, error = D4_Error("missing_ports", "paired_trunk") };
	local outbound = D4_BuildBlueprint("paired_trunk", source_site.rotation, start, {});
	if (!outbound.ok) return { ok = false, error = outbound.error };
	local return_rot = D4_RotateDir(dest_site.rotation, 2);
	local returned = D4_BuildBlueprint("paired_trunk", return_rot, goal, {});
	if (!returned.ok) return { ok = false, error = returned.error };
	local depot = D4_BuildBlueprint("depot_siding", source_site.rotation, D4_Offset(start, source_site.rotation, 2), {});
	local signals = [];
	return { ok = true, outbound = outbound, return_trunk = returned, depot_siding = depot, signals = signals };
}

function D4_BlueprintPortLocation(blueprint, port_name) {
	if (!(port_name in blueprint.ports)) return null;
	local pts = blueprint.ports[port_name];
	if (pts.len() == 0) return null;
	return { x = pts[0].x, y = pts[0].y };
}
