class DirectorateM4OperationJournal {
	operations = null;
	order = null;
	deferred_operations = null;
	deferred_order = null;

	constructor() {
		this.operations = {};
		this.order = [];
		this.deferred_operations = {};
		this.deferred_order = [];
	}

	function Save() {
		if (this.deferred_order.len() == 0) return { operations = this.operations, order = this.order };
		local saved_operations = {};
		local saved_order = [];
		foreach (id in this.order) { if (id in this.operations) { saved_operations[id] <- this.operations[id]; saved_order.append(id); } }
		foreach (id in this.deferred_order) { if (id in this.deferred_operations) { saved_operations[id] <- this.deferred_operations[id]; saved_order.append(id); } }
		return { operations = saved_operations, order = saved_order };
	}

	function Load(data) {
		if (!D4_IsTable(data) || !("operations" in data) || !D4_IsTable(data.operations)) {
			this.operations = {};
			this.order = [];
			this.deferred_operations = {};
			this.deferred_order = [];
			return;
		}
		this.operations = {};
		this.order = [];
		/* Load() has a very small instruction budget. Keep the bounded raw
		 * envelope by reference and validate one operation per game tick before
		 * the bridge accepts requests. */
		if (!D4_Has(data, "order") || !D4_IsArray(data.order) || data.order.len() > DIRECTORATE_M4_MAX_OPERATIONS) {
			this.deferred_operations = {};
			this.deferred_order = [];
			return;
		}
		this.deferred_operations = data.operations;
		this.deferred_order = data.order;
	}

	function NormalizeSettledRollback(id, op) {
		if (!D4_IsTable(op) || !D4_Has(op, "state") || (op.state != "failed_partial" && op.state != "rollback_partial")) return false;
		if (!D4_Has(op, "rollback") || !D4_IsTable(op.rollback) || !D4_Has(op.rollback, "remaining") || !D4_IsArray(op.rollback.remaining) || op.rollback.remaining.len() != 0) return false;
		op.state = "rolled_back";
		op.entries = [];
		op.result = { ok = true, operation_id = id, state = "rolled_back", remaining = [] };
		if (!this.IsPersistedOperationSafe(id, op)) return true;
		this.operations[id] <- op;
		this.order.append(id);
		return true;
	}

	function IsDeferredPartialEnvelope(id, op) {
		if (!D4_IsTable(op) || !D4_Has(op, "operation_id") || op.operation_id != id) return false;
		if (!D4_Has(op, "state") || (op.state != "failed_partial" && op.state != "rollback_partial")) return false;
		return D4_Has(op, "entries") && D4_IsArray(op.entries) && op.entries.len() <= DIRECTORATE_M4_MAX_OPERATION_ENTRIES;
	}

	function HydrateOne() {
		if (this.deferred_order.len() == 0) return;
		local id = this.deferred_order.pop();
		if (!(id in this.deferred_operations)) return;
		local op = this.deferred_operations[id];
		delete this.deferred_operations[id];
		if (id in this.operations) return;
		if (!D4_IsValidOperationId(id)) return;
		if (this.NormalizeSettledRollback(id, op)) return;
		if (!this.IsPersistedOperationSafe(id, op)) return;
		this.operations[id] <- op;
		this.order.append(id);
	}

	function HasDeferred() {
		return this.deferred_order.len() > 0;
	}

	function HydrateById(id) {
		if (!(id in this.deferred_operations)) return;
		local op = this.deferred_operations[id];
		delete this.deferred_operations[id];
		for (local i = 0; i < this.deferred_order.len(); i++) {
			if (this.deferred_order[i] == id) { this.deferred_order.remove(i); break; }
		}
		if (id in this.operations || !D4_IsValidOperationId(id)) return;
		if (this.NormalizeSettledRollback(id, op)) return;
		if (!this.IsPersistedOperationSafe(id, op)) return;
		this.operations[id] <- op;
		this.order.append(id);
	}

	function Create(operation_id, company_id, plan_id, revision, phase, request_fingerprint) {
		if (!D4_IsValidOperationId(operation_id)) return null;
		this.Retention();
		if (this.order.len() + this.deferred_order.len() >= DIRECTORATE_M4_MAX_OPERATIONS) return null;
		local op = {
			operation_id = operation_id,
			company_id = company_id,
			plan_id = plan_id,
			revision = revision,
			phase = phase,
			request_fingerprint = request_fingerprint,
			state = "created",
			entries = [],
			created_tick = D4_Tick(),
			completed_tick = 0,
			result = null,
			rollback = null,
		};
		this.operations[operation_id] <- op;
		this.order.append(operation_id);
		return op;
	}

	function Get(id) {
		if (id in this.deferred_operations) this.HydrateById(id);
		if (id in this.operations) return this.operations[id];
		return null;
	}

	function Record(op, kind, tile_or_point, detail) {
		if (op == null) return false;
		if (op.entries.len() >= DIRECTORATE_M4_MAX_OPERATION_ENTRIES) return false;
		local entry = {
			kind = kind,
			tile = tile_or_point,
			detail = detail,
			tick = D4_Tick(),
		};
		op.entries.append(entry);
		return true;
	}

	function MarkState(op, state, result) {
		if (op == null) return;
		op.state = state;
		op.completed_tick = D4_Tick();
		op.result = result;
	}

	function MarkFailedPartial(op, result) {
		this.MarkState(op, "failed_partial", result);
	}

	function MarkRolledBack(op, remaining) {
		if (op == null) return;
		op.state = remaining.len() == 0 ? "rolled_back" : "rollback_partial";
		op.completed_tick = D4_Tick();
		op.rollback = { remaining = remaining, tick = D4_Tick() };
		op.result = { ok = remaining.len() == 0, operation_id = op.operation_id, state = op.state, remaining = remaining };
		if (remaining.len() == 0) op.entries = [];
	}

	function ValidateReuse(op, company_id, plan_id, revision, phase, request_fingerprint) {
		if (op.company_id != company_id) return { ok = false, error = D4_Error("operation_company_mismatch", op.operation_id) };
		if (op.plan_id != plan_id) return { ok = false, error = D4_Error("operation_plan_mismatch", op.operation_id) };
		if (op.revision != revision) return { ok = false, error = D4_Error("operation_revision_mismatch", op.operation_id) };
		if (op.phase != phase) return { ok = false, error = D4_Error("operation_phase_mismatch", op.phase) };
		if (!D4_Has(op, "request_fingerprint") || op.request_fingerprint != request_fingerprint) return { ok = false, error = D4_Error("operation_request_mismatch", op.operation_id) };
		return { ok = true };
	}

	function Replay(op) {
		if (op.state == "preflighted" || op.state == "completed" || op.state == "rolled_back") {
			if (op.result != null) return D4_ReplayResult(op.result, op.operation_id, op.state);
			return { ok = true, operation_id = op.operation_id, state = op.state, note = "idempotent" };
		}
		if (op.state == "failed_partial") {
			local remaining = D4_Has(op, "rollback") && op.rollback != null && D4_Has(op.rollback, "remaining") ? op.rollback.remaining : [];
			return { ok = false, error = D4_Error("operation_failed_partial", op.operation_id), operation_id = op.operation_id, state = "failed_partial", rollback = op.rollback, remaining = remaining };
		}
		if (op.state == "rollback_partial") {
			local rem = D4_Has(op, "rollback") && op.rollback != null && D4_Has(op.rollback, "remaining") ? op.rollback.remaining : [];
			return { ok = false, error = D4_Error("rollback_partial", op.operation_id), operation_id = op.operation_id, state = "rollback_partial", rollback = op.rollback, remaining = rem };
		}
		return { ok = false, error = D4_Error("operation_not_terminal", op.state), operation_id = op.operation_id, state = op.state };
	}

	function IsPersistedOperationSafe(id, op) {
		if (!D4_IsTable(op)) return false;
		if (!D4_IsValidOperationId(id)) return false;
		if (!("operation_id" in op) || op.operation_id != id) return false;
		if (!("company_id" in op) || typeof op.company_id != "integer") return false;
		if (!("plan_id" in op) || !D4_IsValidPlanId(op.plan_id)) return false;
		if (!("revision" in op) || typeof op.revision != "integer" || op.revision < 0) return false;
		if (!("phase" in op) || !D4_IsApplyPhase(op.phase)) return false;
		if (!("request_fingerprint" in op) || typeof op.request_fingerprint != "string" || op.request_fingerprint.len() > 64) return false;
		if (!("state" in op) || !D4_IsOperationState(op.state)) return false;
		if (!("entries" in op) || !D4_IsArray(op.entries) || op.entries.len() > DIRECTORATE_M4_MAX_OPERATION_ENTRIES) return false;
		if (op.state != "failed_partial" && op.state != "rollback_partial") {
			local safe_entries = [];
			local map_area = GSMap.GetMapSizeX() * GSMap.GetMapSizeY();
			foreach (entry in op.entries) {
				if (!D4_IsSafeJournalEntry(entry, op.company_id, map_area)) return false;
				safe_entries.append(entry);
			}
			op.entries = safe_entries;
		}
		if (!D4_Has(op, "created_tick") || typeof op.created_tick != "integer") op.created_tick <- 0;
		if (!D4_Has(op, "completed_tick") || typeof op.completed_tick != "integer") op.completed_tick <- 0;
		if (!D4_Has(op, "result")) op.result <- null;
		if (!D4_Has(op, "rollback")) op.rollback <- null;
		/* Historical commit results duplicated every journal entry in created[];
		 * compact that replay-only copy before recursive save-value validation. */
		if (D4_IsTable(op.result) && (op.state == "completed" || op.state == "preflighted" || op.state == "rolled_back")) {
			local compact_result = {};
			if (D4_Has(op.result, "ok")) compact_result.ok <- op.result.ok;
			if (D4_Has(op.result, "operation_id")) compact_result.operation_id <- op.result.operation_id;
			if (D4_Has(op.result, "state")) compact_result.state <- op.result.state;
			if (D4_Has(op.result, "cost")) compact_result.cost <- op.result.cost;
			if (D4_Has(op.result, "mutation")) compact_result.mutation <- op.result.mutation;
			if (D4_Has(op.result, "reserve")) compact_result.reserve <- op.result.reserve;
			if (D4_Has(op.result, "note")) compact_result.note <- op.result.note;
			if (D4_Has(op.result, "topology")) compact_result.topology <- op.result.topology;
			if (D4_Has(op.result, "remaining")) compact_result.remaining <- op.result.remaining;
			op.result = compact_result;
		} else if (op.state == "failed_partial" || op.state == "rollback_partial") op.result = null;
		if (!D4_IsBoundedSaveValue(op.result) || !D4_IsBoundedSaveValue(op.rollback)) return false;
		return true;
	}

	function Retention() {
		local compact = [];
		foreach (id in this.order) if (id in this.operations) compact.append(id);
		this.order = compact;
		while (this.order.len() + this.deferred_order.len() >= DIRECTORATE_M4_MAX_OPERATIONS) {
			local removed = false;
			for (local i = 0; i < this.order.len(); i++) {
				local old = this.order[i];
				if (!(old in this.operations)) {
					this.order.remove(i);
					removed = true;
					break;
				}
				local state = this.operations[old].state;
				if (state == "preflighted" || state == "rolled_back") {
					delete this.operations[old];
					this.order.remove(i);
					removed = true;
					break;
				}
			}
			if (!removed) break;
		}
	}
}

function D4_ApplyRequestFingerprint(company_id, plan_id, revision, phase, options) {
	return D4_BoundedFingerprint({ company_id = company_id, plan_id = plan_id, revision = revision, phase = phase, options = options });
}

function D4_RunApplyPhases(store, journal, company_id, plan_id, revision, phase, options) {
	local plan = store.GetPlan(plan_id);
	if (plan == null) return { ok = false, error = D4_Error("plan_not_found", plan_id) };
	if (plan.company_id != company_id) return { ok = false, error = D4_Error("company_mismatch", plan_id) };
	if (plan.revision != revision) return { ok = false, error = D4_Error("revision_mismatch", revision.tostring()) };
	local reserve = D4_ClampInt(D4_Has(options, "reserve") ? options.reserve : GSController.GetSetting("reserve_default"), 50000, 0, 10000000);
	local mode = GSCompanyMode(company_id);
	if (!GSCompanyMode.IsValid()) return { ok = false, error = D4_Error("invalid_company", company_id.tostring()) };
	if (!D4_SelectRailType()) return { ok = false, error = D4_Error("rail_type_unavailable", company_id.tostring()) };
	if (!D4_IsApplyPhase(phase)) return { ok = false, error = D4_Error("invalid_phase", phase) };
	if (!D4_Has(options, "operation_id")) return { ok = false, error = D4_Error("operation_id_required", phase) };
	local operation_id = options.operation_id;
	if (!D4_IsValidOperationId(operation_id)) return { ok = false, error = D4_Error("invalid_operation_id", "") };
	local request_fingerprint = D4_ApplyRequestFingerprint(company_id, plan_id, revision, phase, options);
	if (phase == "rollback") return D4_RunRollbackRequest(journal, company_id, plan_id, revision, operation_id, options, request_fingerprint);
	local existing = journal.Get(operation_id);
	if (existing != null) {
		local reuse = journal.ValidateReuse(existing, company_id, plan_id, revision, phase, request_fingerprint);
		if (!reuse.ok) return reuse;
		return journal.Replay(existing);
	}
	local op = journal.Create(operation_id, company_id, plan_id, revision, phase, request_fingerprint);
	if (op == null) return { ok = false, error = D4_Error("operation_capacity", DIRECTORATE_M4_MAX_OPERATIONS.tostring()) };
	if (phase == "preflight") {
		local result = D4_PreflightOperation(plan, store, journal, company_id, reserve, op);
		return result;
	}
	if (phase == "commit") {
		local result = D4_CommitOperation(plan, store, journal, company_id, reserve, op);
		return result;
	}
	return { ok = false, error = D4_Error("invalid_phase", phase) };
}

function D4_RunRollbackRequest(journal, company_id, plan_id, revision, operation_id, options, request_fingerprint) {
	if (!D4_Has(options, "target_operation_id")) return { ok = false, error = D4_Error("target_operation_id_required", operation_id) };
	local target_id = options.target_operation_id;
	if (!D4_IsValidOperationId(target_id)) return { ok = false, error = D4_Error("invalid_target_operation_id", "") };
	if (target_id == operation_id) return { ok = false, error = D4_Error("rollback_requires_distinct_operation_id", operation_id) };
	local existing_rollback = journal.Get(operation_id);
	if (existing_rollback != null) {
		local rollback_reuse = journal.ValidateReuse(existing_rollback, company_id, plan_id, revision, "rollback", request_fingerprint);
		if (!rollback_reuse.ok) return rollback_reuse;
		if (existing_rollback.state == "rollback_partial") {
			local target_retry = journal.Get(target_id);
			if (target_retry == null) return { ok = false, error = D4_Error("operation_not_found", target_id) };
			local retry_result = D4_RollbackOperation(journal, target_retry);
			local retry_done = { ok = retry_result.ok, operation_id = operation_id, state = retry_result.ok ? "rolled_back" : "rollback_partial", target_operation_id = target_id, rollback = retry_result, remaining = retry_result.remaining };
			journal.MarkState(existing_rollback, retry_done.state, retry_done);
			return retry_done;
		}
		return journal.Replay(existing_rollback);
	}
	local target = journal.Get(target_id);
	if (target == null) return { ok = false, error = D4_Error("operation_not_found", target_id) };
	if (target.company_id != company_id) return { ok = false, error = D4_Error("operation_company_mismatch", target_id) };
	if (target.plan_id != plan_id) return { ok = false, error = D4_Error("operation_plan_mismatch", target_id) };
	if (target.phase != "commit") return { ok = false, error = D4_Error("operation_phase_mismatch", target.phase) };
	if (target.state == "rolled_back") {
		local already_op = journal.Create(operation_id, company_id, plan_id, revision, "rollback", request_fingerprint);
		if (already_op == null) return { ok = false, error = D4_Error("operation_capacity", DIRECTORATE_M4_MAX_OPERATIONS.tostring()) };
		local already_rollback = { ok = true, operation_id = target_id, remaining = [] };
		local already_done = { ok = true, operation_id = operation_id, state = "rolled_back", target_operation_id = target_id, rollback = already_rollback, remaining = [], note = "target_already_rolled_back" };
		journal.MarkState(already_op, "rolled_back", already_done);
		return already_done;
	}
	if (target.state != "completed" && target.state != "failed_partial" && target.state != "rollback_partial") {
		return { ok = false, error = D4_Error("operation_not_rollbackable", target.state), operation_id = target_id, state = target.state };
	}
	local rollback_op = journal.Create(operation_id, company_id, plan_id, revision, "rollback", request_fingerprint);
	if (rollback_op == null) return { ok = false, error = D4_Error("operation_capacity", DIRECTORATE_M4_MAX_OPERATIONS.tostring()) };
	rollback_op.state = "in_progress";
	local result = D4_RollbackOperation(journal, target);
	local state = result.ok ? "rolled_back" : "rollback_partial";
	local done = { ok = result.ok, operation_id = operation_id, state = state, target_operation_id = target_id, rollback = result, remaining = result.remaining };
	journal.MarkState(rollback_op, state, done);
	return done;
}

function D4_PreflightOperation(plan, store, journal, company_id, reserve, op) {
	if (!D4_Has(plan, "build_program") || !D4_IsTable(plan.build_program) || !plan.build_program.ok) {
		local empty = { ok = false, error = D4_Error("empty_plan", plan.plan_id), operation_id = op.operation_id, state = "failed_partial" };
		journal.MarkFailedPartial(op, empty);
		return empty;
	}
	local pf = D4_PreflightBuildProgram(plan.build_program, company_id, reserve, false);
	if (!pf.ok) {
		journal.Record(op, "preflight_failure", 0, pf);
		local failed = { ok = false, error = pf.error, operation_id = op.operation_id, state = "failed_partial", failed_op = D4_Has(pf, "failed_op") ? pf.failed_op : "", failure = D4_Has(pf, "failure") ? pf.failure : pf, cost = D4_Has(pf, "cost") ? pf.cost : 0, reserve = reserve, mutation = false };
		journal.MarkFailedPartial(op, failed);
		return failed;
	}
	local done = {
		ok = true,
		operation_id = op.operation_id,
		state = "preflighted",
		cost = pf.cost,
		reserve = reserve,
		affordable = pf.affordable,
		mutation = false,
	};
	journal.MarkState(op, "preflighted", done);
	return done;
}

function D4_CommitOperation(plan, store, journal, company_id, reserve, op) {
	local total_cost = 0;
	local created = [];
	local reused = [];
	local fingerprint = D4_StableFingerprint(company_id, plan.intent, plan.policy);
	if (fingerprint != plan.precondition_fingerprint) {
		local stale = { ok = false, error = D4_Error("stale_fingerprint", plan.plan_id), operation_id = op.operation_id, state = "failed_partial" };
		journal.MarkFailedPartial(op, stale);
		return stale;
	}
	if (!D4_Has(plan, "build_program") || !D4_IsTable(plan.build_program) || !plan.build_program.ok || plan.build_program.ops.len() == 0) {
		local empty = { ok = false, error = D4_Error("empty_plan", plan.plan_id), operation_id = op.operation_id, state = "failed_partial" };
		journal.MarkFailedPartial(op, empty);
		return empty;
	}
	local quote = D4_PreflightBuildProgram(plan.build_program, company_id, reserve, false);
	if (!quote.ok) {
		journal.Record(op, "preflight_failure", 0, quote);
		local invalid = { ok = false, error = quote.error, operation_id = op.operation_id, state = "failed_partial", failure = quote, remaining = [] };
		journal.MarkFailedPartial(op, invalid);
		return invalid;
	}
	if (!D4_EnsureCompanyFunds(company_id, reserve + quote.cost)) {
		local finance = { ok = false, error = D4_Error("insufficient_finance_capacity", quote.cost.tostring()), operation_id = op.operation_id, state = "failed_partial", remaining = [] };
		journal.MarkFailedPartial(op, finance);
		return finance;
	}
	local pf_program = D4_PreflightBuildProgram(plan.build_program, company_id, reserve);
	if (!pf_program.ok) {
		journal.Record(op, "preflight_failure", 0, pf_program);
		local pf_failed = { ok = false, error = pf_program.error, operation_id = op.operation_id, state = "failed_partial", failure = pf_program, remaining = [] };
		journal.MarkFailedPartial(op, pf_failed);
		return pf_failed;
	}
	op.state = "in_progress";
	foreach (program_op in plan.build_program.ops) {
		if (!D4_CanAfford(company_id, reserve, 0)) {
			journal.Record(op, "finance_failure", program_op.tile, { cost = total_cost, reserve = reserve });
			local rollback_result = D4_RollbackOperation(journal, op);
			local failed = { ok = false, error = D4_Error("insufficient_funds", program_op.op_id), operation_id = op.operation_id, state = op.state, failed_op = program_op.op_id, rollback = rollback_result, remaining = rollback_result.remaining };
			return failed;
		}
		local built = D4_ExecuteProgramOperation(program_op, company_id, false);
		if (!built.ok) {
			journal.Record(op, "build_failure", program_op.tile, built.failure);
			local rollback_result2 = D4_RollbackOperation(journal, op);
			local failed2 = { ok = false, error = D4_Error("build_failed", program_op.op_id), operation_id = op.operation_id, state = op.state, failed_op = program_op.op_id, failure = built.failure, rollback = rollback_result2, remaining = rollback_result2.remaining };
			return failed2;
		}
		total_cost += built.cost;
		local entry_kind = built.reused ? "reused" : "created";
		if (!journal.Record(op, entry_kind, program_op.tile, built.detail)) {
			local rollback_result3 = D4_RollbackOperation(journal, op);
			local failed3 = { ok = false, error = D4_Error("journal_capacity", program_op.op_id), operation_id = op.operation_id, state = op.state, failed_op = program_op.op_id, rollback = rollback_result3, remaining = rollback_result3.remaining };
			return failed3;
		}
		/* Keep full reversible evidence in the journal, but never echo hundreds of
		 * corner snapshots through the bounded GameScript response channel. */
		local item = { kind = built.detail.kind, tile = program_op.tile, op_id = program_op.op_id };
		if (built.reused) reused.append(item); else created.append(item);
	}
	local verified = D4_VerifyProgramTopology(plan.build_program, company_id);
	if (!verified.ok) {
		local rollback_result4 = D4_RollbackOperation(journal, op);
		local failed4 = { ok = false, error = D4_Error("topology_verify_failed", plan.plan_id), operation_id = op.operation_id, state = op.state, verification = verified, rollback = rollback_result4, remaining = rollback_result4.remaining };
		return failed4;
	}
	local done = {
		ok = true,
		operation_id = op.operation_id,
		state = "completed",
		cost = total_cost,
		created = created,
		reused = reused,
		topology = verified,
	};
	journal.MarkState(op, "completed", done);
	return done;
}

function D4_RollbackOperation(journal, op) {
	if (op == null) return { ok = false, error = D4_Error("operation_not_found", "") };
	local mode = GSCompanyMode(op.company_id);
	if (!GSCompanyMode.IsValid()) return { ok = false, error = D4_Error("invalid_company", op.company_id.tostring()), operation_id = op.operation_id };
	local remaining = [];
	local map_area = GSMap.GetMapSizeX() * GSMap.GetMapSizeY();
	for (local i = op.entries.len() - 1; i >= 0; i--) {
		local entry = op.entries[i];
		/* Diagnostic entries describe failures and are not rollback assets. Skip
		 * them before applying the stricter asset-detail validator. */
		if (!D4_IsTable(entry) || !D4_Has(entry, "kind") || typeof entry.kind != "string") { remaining.append({ kind = "malformed", tile = -1 }); continue; }
		if (entry.kind != "created") continue;
		if (!D4_IsSafeJournalEntry(entry, op.company_id, map_area)) { remaining.append({ kind = "malformed", tile = -1 }); continue; }
		if (typeof entry.tile != "integer") continue;
		local tile = entry.tile;
		local detail = entry.detail;
		local removed = D4_RemoveJournalledAsset(tile, detail, op.company_id);
		if (!removed) remaining.append({ tile = tile, kind = D4_Has(detail, "kind") ? detail.kind : "unknown" });
	}
	journal.MarkRolledBack(op, remaining);
	return { ok = remaining.len() == 0, operation_id = op.operation_id, remaining = remaining };
}

function D4_ReplayResult(result, operation_id, state) {
	local copy = {};
	if (!D4_IsTable(result)) return { ok = true, operation_id = operation_id, state = state, note = "idempotent" };
	foreach (k, v in result) {
		if (k != "operation_id" && k != "state" && k != "note") copy[k] <- v;
	}
	copy.operation_id <- operation_id;
	copy.state <- state;
	copy.note <- "idempotent";
	return copy;
}

function D4_IsApplyPhase(phase) {
	return phase == "preflight" || phase == "commit" || phase == "rollback";
}

function D4_IsOperationState(state) {
	return state == "created" || state == "preflighted" || state == "in_progress" || state == "completed" || state == "failed_partial" || state == "rolled_back" || state == "rollback_partial";
}

function D4_IsValidOperationId(id) {
	return D4_IsSafeIdentifier(id, DIRECTORATE_M4_MAX_OPERATION_ID_LEN);
}

function D4_IsValidPlanId(id) {
	return D4_IsSafeIdentifier(id, 128);
}

function D4_IsSafeIdentifier(id, max_len) {
	if (typeof id != "string" || id.len() < 1 || id.len() > max_len) return false;
	for (local i = 0; i < id.len(); i++) {
		local ch = id.slice(i, i + 1);
		local ok = (ch >= "a" && ch <= "z") || (ch >= "A" && ch <= "Z") || (ch >= "0" && ch <= "9") || ch == "-" || ch == "_" || ch == "." || ch == ":";
		if (!ok) return false;
	}
	return true;
}

function D4_IsSafeJournalEntry(entry, company_id, map_area = null) {
	if (!D4_IsTable(entry)) return false;
	if (map_area == null) map_area = GSMap.GetMapSizeX() * GSMap.GetMapSizeY();
	if (!("kind" in entry) || typeof entry.kind != "string") return false;
	if (!("tile" in entry) || typeof entry.tile != "integer" || entry.tile < 0 || entry.tile >= map_area) return false;
	if (!("detail" in entry) || !D4_IsTable(entry.detail)) return false;
	if (!D4_IsSafeJournalDetail(entry.detail, map_area)) return false;
	if (D4_Has(entry, "tick") && typeof entry.tick != "integer") return false;
	return true;
}

function D4_IsSafeJournalDetail(detail, map_area = null) {
	if (map_area == null) map_area = GSMap.GetMapSizeX() * GSMap.GetMapSizeY();
	if (!("kind" in detail) || typeof detail.kind != "string") return false;
	if (detail.kind != "station" && detail.kind != "depot" && detail.kind != "rail" && detail.kind != "signal" && detail.kind != "landscape") return false;
	if (detail.kind == "landscape") {
		if (!D4_Has(detail, "before") || !D4_IsArray(detail.before) || !D4_Has(detail, "after") || !D4_IsArray(detail.after) || detail.before.len() < 1 || detail.before.len() > 512 || detail.after.len() != detail.before.len()) return false;
		foreach (record in detail.before) if (!D4_IsSafeLandscapeCornerRecord(record, map_area)) return false;
		foreach (record2 in detail.after) if (!D4_IsSafeLandscapeCornerRecord(record2, map_area)) return false;
	}
	if (D4_Has(detail, "phase") && typeof detail.phase != "string") return false;
	if (D4_Has(detail, "front") && (typeof detail.front != "integer" || detail.front < 0 || detail.front >= map_area)) return false;
	if (D4_Has(detail, "station_end") && (typeof detail.station_end != "integer" || detail.station_end < 0 || detail.station_end >= map_area)) return false;
	if (D4_Has(detail, "track") && typeof detail.track != "integer") return false;
	if (D4_Has(detail, "prev") && (typeof detail.prev != "integer" || detail.prev < 0 || detail.prev >= map_area)) return false;
	if (D4_Has(detail, "next") && (typeof detail.next != "integer" || detail.next < 0 || detail.next >= map_area)) return false;
	if (D4_Has(detail, "signal_type") && typeof detail.signal_type != "integer") return false;
	if (D4_Has(detail, "dir") && typeof detail.dir != "integer") return false;
	return true;
}

function D4_JournalDetailForTile(tile, phase_name) {
	local detail = { kind = tile.kind, phase = phase_name };
	if (tile.kind == "rail") detail.track <- D4_TrackForDirection(tile.data.dir);
	if (tile.kind == "station") {
		detail.track <- D4_StationDirectionForRailTrack(tile.data.dir);
		local end_point = null;
		if (detail.track == GSRail.RAILTRACK_NW_SE) {
			end_point = { x = tile.point.x + tile.data.num_platforms - 1, y = tile.point.y + tile.data.platform_length - 1 };
		} else {
			end_point = { x = tile.point.x + tile.data.platform_length - 1, y = tile.point.y + tile.data.num_platforms - 1 };
		}
		detail.station_end <- D4_ToTile(end_point);
	}
	if (tile.kind == "depot" || tile.kind == "signal") detail.front <- D4_ToTile(D4_Offset(tile.point, tile.data.dir, 1));
	if (D4_Has(tile.data, "dir")) detail.dir <- tile.data.dir;
	return detail;
}

function D4_TileHasCompatibleAsset(tile, company_id, kind) {
	if (!GSMap.IsValidTile(tile)) return false;
	if (GSTile.GetOwner(tile) != company_id) return false;
	if (kind == "station") return GSRail.IsRailStationTile(tile);
	if (kind == "depot") return GSRail.IsRailDepotTile(tile);
	if (kind == "rail") return GSRail.IsRailTile(tile) && !GSRail.IsRailStationTile(tile) && !GSRail.IsRailWaypointTile(tile);
	if (kind == "signal") return GSRail.IsRailTile(tile);
	return false;
}

function D4_IsSafeLandscapeCornerRecord(record, map_area) {
	if (!D4_IsTable(record) || !D4_Has(record, "tile") || typeof record.tile != "integer" || record.tile < 0 || record.tile >= map_area || !D4_Has(record, "h") || !D4_IsArray(record.h) || record.h.len() != 4 || !D4_Has(record, "inner") || typeof record.inner != "bool" || !D4_Has(record, "owned") || !D4_IsArray(record.owned) || record.owned.len() != 4) return false;
	foreach (height in record.h) if (typeof height != "integer" || height < 0 || height > 255) return false;
	foreach (owned in record.owned) if (typeof owned != "bool") return false;
	return true;
}

/* record.h is built by D4_LandscapeSnapshot in [N, E, S, W] order. GSTile.Corner is
 * a distinct, differently-ordered enum from GSTile.Slope (RaiseTile/LowerTile's
 * argument is a Slope bitmask, not a Corner ordinal), so the index must be mapped
 * through both tables rather than reused as a raw integer for either call. */
function D4_RestoreLandscape(detail) {
	local corner_order = [GSTile.CORNER_N, GSTile.CORNER_E, GSTile.CORNER_S, GSTile.CORNER_W];
	local slope_order = [GSTile.SLOPE_N, GSTile.SLOPE_E, GSTile.SLOPE_S, GSTile.SLOPE_W];
	local steps = 0;
	foreach (record in detail.before) for (local i = 0; i < 4; i++) {
		local corner = corner_order[i], slope = slope_order[i], target = record.h[i];
		while (GSTile.GetCornerHeight(record.tile, corner) != target && steps < DIRECTORATE_M4_MAX_LANDSCAPE_RESTORE_STEPS) {
			local current = GSTile.GetCornerHeight(record.tile, corner);
			if (current < target) { if (!GSTile.RaiseTile(record.tile, slope)) return false; } else { if (!GSTile.LowerTile(record.tile, slope)) return false; }
			steps++;
		}
		if (GSTile.GetCornerHeight(record.tile, corner) != target) return false;
	}
	return true;
}

function D4_RemoveJournalledAsset(tile, detail, company_id) {
	if (!GSMap.IsValidTile(tile) || !D4_IsTable(detail) || !D4_Has(detail, "kind")) return false;
	/* Terrain becomes unowned after later assets are removed; restoration is guarded
	 * by a sanitised exact before snapshot, not current ownership. */
	if (detail.kind == "landscape") return D4_RestoreLandscape(detail);
	if (GSTile.GetOwner(tile) != company_id) return false;
	if (detail.kind == "station") {
		if (!GSRail.IsRailStationTile(tile) || !D4_Has(detail, "station_end") || !GSMap.IsValidTile(detail.station_end)) return false;
		return GSRail.RemoveRailStationTileRectangle(tile, detail.station_end, false);
	}
	if (detail.kind == "depot") {
		if (!GSRail.IsRailDepotTile(tile) || !D4_Has(detail, "front") || !GSMap.IsValidTile(detail.front)) return false;
		if (GSRail.GetRailDepotFrontTile(tile) != detail.front) return false;
		return GSTile.DemolishTile(tile);
	}
	if (detail.kind == "rail") {
		if (!GSRail.IsRailTile(tile) || GSRail.IsRailStationTile(tile) || GSRail.IsRailWaypointTile(tile)) return false;
		if (D4_Has(detail, "prev") && D4_Has(detail, "next") && !GSRail.AreTilesConnected(detail.prev, tile, detail.next)) return false;
		if (D4_Has(detail, "prev") && D4_Has(detail, "next")) return GSRail.RemoveRail(detail.prev, tile, detail.next);
		if (!D4_Has(detail, "track")) return false;
		return GSRail.RemoveRailTrack(tile, detail.track);
	}
	if (detail.kind == "signal") {
		if (!GSRail.IsRailTile(tile) || !D4_Has(detail, "front")) return false;
		if (GSRail.GetSignalType(tile, detail.front) == GSRail.SIGNALTYPE_NONE) return false;
		if (D4_Has(detail, "signal_type") && GSRail.GetSignalType(tile, detail.front) != detail.signal_type) return false;
		return GSRail.RemoveSignal(tile, detail.front);
	}
	return false;
}

function D4_GetApplyPhases(plan) {
	local phases = [];
	if (D4_Has(plan, "station_blueprint") && plan.station_blueprint.ok) {
		phases.append({ name = "station", tiles = D4_CloneTiles(plan.station_blueprint.tiles) });
	}
	if (D4_Has(plan, "destination_blueprint") && plan.destination_blueprint.ok) {
		phases.append({ name = "destination_station", tiles = D4_CloneTiles(plan.destination_blueprint.tiles) });
	}
	if (D4_Has(plan, "outbound_trunk") && plan.outbound_trunk.ok) {
		phases.append({ name = "outbound_trunk", tiles = D4_CloneTiles(plan.outbound_trunk.tiles) });
	}
	if (D4_Has(plan, "return_trunk") && plan.return_trunk.ok) {
		phases.append({ name = "return_trunk", tiles = D4_CloneTiles(plan.return_trunk.tiles) });
	}
	if (D4_Has(plan, "signals") && plan.signals.len() > 0) {
		phases.append({ name = "signals", tiles = D4_CloneTiles(plan.signals) });
	}
	if (D4_Has(plan, "depots") && plan.depots.len() > 0) {
		phases.append({ name = "depots", tiles = D4_CloneTiles(plan.depots) });
	}
	return phases;
}

function D4_CloneTiles(tiles) {
	local out = [];
	foreach (tile in tiles) out.append(tile);
	return out;
}
