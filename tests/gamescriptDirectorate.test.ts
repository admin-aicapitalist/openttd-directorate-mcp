import assert from "node:assert/strict";
import { readFileSync, readdirSync } from "node:fs";
import { join } from "node:path";
import test from "node:test";

const gameDir = "game/openttd_directorate";

test("Stable GameScript package has required entry points and no prohibited paths", () => {
  const files = readdirSync(gameDir).filter((file) => file.endsWith(".nut"));
  assert.ok(files.includes("info.nut"));
  assert.ok(files.includes("main.nut"));
  const text = files.map((file) => readFileSync(join(gameDir, file), "utf8")).join("\n");
  assert.match(text, /RegisterGS\(OpenTTDDirectorateInfo\(\)\)/);
  assert.match(text, /class OpenTTDDirectorate extends GSController/);
});

test("Stable version constants fence save/load, protocol, and route bounds", () => {
  const source = readFileSync(join(gameDir, "version.nut"), "utf8");
  assert.match(source, /DIRECTORATE_M4_SAVE_VERSION/);
  assert.match(source, /DIRECTORATE_M4_PROTOCOL_VERSION/);
  assert.match(source, /DIRECTORATE_M4_MAX_ROUTES/);
  assert.match(source, /DIRECTORATE_M4_MAX_ROUTE_VEHICLES/);
  assert.match(source, /DIRECTORATE_M4_ROUTE_REGISTRY_VERSION/);
});

test("Route registry is persistent, bounded, and reports health/economics", () => {
  const registry = readFileSync(join(gameDir, "route_registry.nut"), "utf8");
  assert.match(registry, /class DirectorateM4RouteRegistry/);
  assert.match(registry, /function Save\(\)/);
  assert.match(registry, /function Load\(data\)/);
  assert.match(registry, /function Create\(/);
  assert.match(registry, /function Get\(/);
  assert.match(registry, /function Observe\(/);
  assert.match(registry, /function Summary\(/);
  assert.match(registry, /function AddAlert\(/);
  assert.match(registry, /function Retention\(/);
  assert.match(registry, /topology_ok/);
  assert.match(registry, /orders_ok/);
  assert.match(registry, /vehicle_running/);
  assert.match(registry, /positive_revenue/);
  assert.match(registry, /last_year_profit/);
  assert.match(registry, /this_year_profit/);
  assert.match(registry, /lifetime_profit/);
  assert.match(registry, /function D4_RouteRuntimeSnapshot\(route\)/);
  assert.match(registry, /GSOrder\.ResolveOrderPosition\(entry\.vehicle_id, GSOrder\.ORDER_CURRENT\)/);
  assert.match(registry, /GSVehicle\.GetCargoLoad\(entry\.vehicle_id, route\.cargo_type\)/);
  assert.match(registry, /GSStation\.GetCargoWaiting\(source_station_id, route\.cargo_type\)/);
  assert.match(registry, /GSIndustry\.GetLastMonthProduction\(route\.source_industry_id, route\.cargo_type\)/);
  assert.match(registry, /runtime = D4_RouteRuntimeSnapshot\(route\)/);
  assert.match(registry, /DIRECTORATE_M4_MAX_ROUTES/);
  assert.match(registry, /DIRECTORATE_M4_MAX_ROUTE_VEHICLES/);
  assert.match(registry, /"commissioned"/);
});

test("Commissioning workflow exercises topology, orders, vehicle, and verify levels", () => {
  const registry = readFileSync(join(gameDir, "route_registry.nut"), "utf8");
  const journal = readFileSync(join(gameDir, "operation_journal.nut"), "utf8");
  const util = readFileSync(join(gameDir, "util.nut"), "utf8");
  const program = readFileSync(join(gameDir, "build_program.nut"), "utf8");
  assert.match(registry, /function D4_CommissionRoute\(/);
  assert.match(registry, /function D4_VerifyRouteTopology\(/);
  assert.match(registry, /function D4_AreStationsConnectedByRail\(/);
  assert.match(registry, /guard\s*<\s*2048/);
  assert.match(registry, /function D4_ConfigureRouteOrders\(/);
  assert.match(registry, /function D4_BuildRouteVehicle\(/);
  assert.match(registry, /D4_EnsureCompanyFunds\(company_id, estimated_vehicle_cost\)/);
  assert.match(program, /enforce_funds = true/);
  assert.match(journal, /D4_PreflightBuildProgram\(plan\.build_program, company_id, reserve, false\)/);
  assert.match(journal, /D4_EnsureCompanyFunds\(company_id, reserve \+ quote\.cost\)/);
  assert.match(journal, /D4_CanAfford\(company_id, reserve, 0\)/);
  assert.match(util, /function D4_EnsureCompanyFunds\(/);
  assert.match(util, /GSCompanyMode\(company_id\)/);
  assert.match(util, /target > maximum_loan/);
  assert.match(util, /GSCompany\.SetLoanAmount\(target\)/);
  assert.match(registry, /function D4_UpdateRouteHealth\(/);
  assert.match(registry, /function D4_VerifyRoute\(/);
  assert.match(registry, /level == "topology"/);
  assert.match(registry, /level == "commissioning"/);
  assert.match(registry, /level == "economic"/);
  const failedReplayGuard = registry.indexOf('if (existing.state != "commissioned")');
  const idempotentSuccess = registry.indexOf('note = "idempotent"', failedReplayGuard);
  assert.ok(failedReplayGuard >= 0, "commission replay must reject non-commissioned routes");
  assert.ok(idempotentSuccess > failedReplayGuard, "idempotent success must occur only after the commissioned-state guard");
});

test("Journal load defers every recoverable partial mutation without dropping rollback state", () => {
  const journal = readFileSync(join(gameDir, "operation_journal.nut"), "utf8");
  const store = readFileSync(join(gameDir, "plan_store.nut"), "utf8");
  const registry = readFileSync(join(gameDir, "route_registry.nut"), "utf8");
  const main = readFileSync(join(gameDir, "main.nut"), "utf8");
  assert.match(journal, /deferred_operations/);
  assert.match(journal, /function HydrateOne\(\)/);
  assert.match(journal, /function HydrateById\(id\)/);
  assert.match(journal, /if \(id in this\.deferred_operations\) this\.HydrateById\(id\)/);
  assert.match(journal, /this\.order\.len\(\) \+ this\.deferred_order\.len\(\) >= DIRECTORATE_M4_MAX_OPERATIONS/);
  assert.match(journal, /this\.deferred_order\.pop\(\)/);
  assert.match(journal, /function NormalizeSettledRollback\(/);
  assert.match(journal, /if \(remaining\.len\(\) == 0\) op\.entries = \[\]/);
  assert.match(journal, /D4_IsSafeJournalEntry\(entry, op\.company_id, map_area\)/);
  assert.match(store, /this\.journal\.HydrateOne\(\)/);
  assert.match(store, /function BeginLoad\(data\)/);
  assert.match(store, /deferred_plans/);
  assert.match(store, /this\.registry\.HydrateOne\(\)/);
  assert.match(registry, /deferred_routes/);
  assert.match(registry, /function HydrateOne\(\)/);
  assert.match(store, /D4_EnsureCompanyFunds\(company_id, 10000\)/);
  assert.match(main, /pending_load/);
  assert.match(main, /this\.store\.BeginLoad\(this\.pending_load\)/);
  assert.doesNotMatch(main, /OpenTTDDirectorate::Load[\s\S]*this\.store\.Load\(data\.plans\)/);
  assert.match(main, /while \(this\.store\.HasDeferredOperations\(\)\)/);
  assert.ok(main.indexOf("this.store.Tick();", main.indexOf("while (true)")) < main.indexOf("this.bridge.Poll();", main.indexOf("while (true)")));
});

test("Plan load defers deep build-program validation until the plan is accessed", () => {
  const store = readFileSync(join(gameDir, "plan_store.nut"), "utf8");
  assert.match(store, /this\.IsPlanSafe\(plan, true, false\)/);
  assert.match(store, /function IsPlanSafe\(plan, allow_legacy = false, validate_program = true\)/);
  assert.match(store, /function D4_IsAcceptedBuildProgramVersion\(version, allow_legacy_v1\)/);
  assert.match(store, /version == DIRECTORATE_M4_BUILD_PROGRAM_VERSION \|\| version == 2 \|\| \(allow_legacy_v1 && version == 1\)/);
  assert.match(store, /if \(validate_program\) \{\s*local validation = D4_ValidateBuildProgram/s);
  assert.match(store, /if \(!this\.IsPlanSafe\(plan, false, true\)\) return null/);
  assert.match(store, /D4_Error\("unsafe_plan", requested_id\)/);
});

test("Build-program save/load fixtures pin v2 preservation, malformed v1 rejection, and current v3 topology", () => {
  const v2 = JSON.parse(readFileSync("tests/fixtures/build-program-v2-plan.json", "utf8"));
  const malformedV1 = JSON.parse(readFileSync("tests/fixtures/build-program-v1-malformed-plan.json", "utf8"));
  const v3 = JSON.parse(readFileSync("tests/fixtures/build-program-v3-through-hub-plan.json", "utf8"));
  assert.equal(v2.build_program.version, 2);
  assert.equal(v2.build_program.topology, undefined);
  assert.equal(v2.station_blueprint.name, "through_hub_4x7");
  assert.equal(malformedV1.build_program.version, 1);
  assert.deepEqual(malformedV1.build_program.path, []);
  assert.equal(v3.build_program.version, 3);
  assert.equal(v3.build_program.topology.kind, "through_hub_roro");

  const store = readFileSync(join(gameDir, "plan_store.nut"), "utf8");
  assert.match(store, /D4_IsAcceptedBuildProgramVersion\(plan\.build_program\.version, false\)/);
  assert.match(store, /D4_UpgradeBuildProgram\(plan\)/);
  assert.doesNotMatch(store, /program\.version = 3[\s\S]*topology <-/);
});

test("Plan store owns the route registry and exposes observe/verify routes", () => {
  const store = readFileSync(join(gameDir, "plan_store.nut"), "utf8");
  assert.match(store, /registry = DirectorateM4RouteRegistry\(\)/);
  assert.match(store, /registry = this\.registry\.Save\(\)/);
  assert.match(store, /this\.registry\.BeginLoad\(data\.registry\)/);
  assert.match(store, /scope == "routes"/);
  assert.match(store, /this\.registry\.Observe\(request\)/);
  assert.match(store, /D4_VerifyRoute\(this\.registry,/);
  assert.match(store, /function VerifyOperation\(/);
  assert.match(store, /this\.journal\.Get\(operation_id\)/);
  assert.match(store, /this\.journal\.Replay\(op\)/);
});

test("Bridge dispatches verify, commissioning, and bounded curve inspection", () => {
  const bridge = readFileSync(join(gameDir, "bridge.nut"), "utf8");
  assert.match(bridge, /op == "verify"/);
  assert.match(bridge, /payload\.command == "commission_route"/);
  assert.match(bridge, /payload\.command == "inspect_plan_curves"/);
  assert.match(bridge, /target\.len\(\) >= 256/);
  assert.match(bridge, /D4_CommissionRoute\(this\.store, this\.store\.registry,/);
  assert.match(bridge, /targets != 1/);
  assert.match(bridge, /this\.store\.Verify\(payload\.company_id, payload\.operation_id, level, true\)/);
});

test("Bridge preserves rich apply evidence on success and failure", () => {
  const bridge = readFileSync(join(gameDir, "bridge.nut"), "utf8");
  assert.match(bridge, /return \{ ok = result\.ok, payload = result, error = D4_Has\(result, "error"\) \? result\.error : null \};/);
  assert.doesNotMatch(bridge, /if \(!result\.ok\) return result;/);
});

test("Source uses bounded loops and explicit safety constants", () => {
  const source = readdirSync(gameDir)
    .filter((file) => file.endsWith(".nut"))
    .map((file) => readFileSync(join(gameDir, file), "utf8"))
    .join("\n");
  assert.match(source, /DIRECTORATE_M4_MAX_BLUEPRINT_TILES/);
  assert.match(source, /DIRECTORATE_M4_MAX_OPERATION_ENTRIES/);
  assert.match(source, /DIRECTORATE_M4_MAX_REQUEST_BYTES/);
  assert.match(source, /DIRECTORATE_M4_MAX_ROUTES/);
  assert.match(source, /DIRECTORATE_M4_MAX_ROUTE_VEHICLES/);
  assert.doesNotMatch(source, /while \(true\)[\s\S]*while \(true\)/);
});

test("Depot access joins the depot mouth to the route instead of duplicating straight track", () => {
	const program = readFileSync(join(gameDir, "build_program.nut"), "utf8");
	assert.match(program, /ops\.append\(depot\.access_op\)/);
	assert.match(program, /local access_prev = a/);
	assert.match(program, /local access_next = depot_point/);
	assert.match(program, /if \(access_mode == "exit_to_next"\)/);
	assert.match(program, /access_prev = depot_point/);
	assert.match(program, /access_next = next/);
	assert.match(program, /access_op\s*=\s*\{[^}]*kind\s*=\s*"rail_connection"[^}]*tile\s*=\s*D4_ToTile\(front\)[^}]*prev\s*=\s*D4_ToTile\(access_prev\)[^}]*next\s*=\s*D4_ToTile\(access_next\)/s);
	assert.doesNotMatch(program, /access\s*=\s*\[a,\s*front\]/);
	assert.match(program, /foreach \(return_point in paired\.return_lane\) occupied\[D4_PointKey\(return_point\)\] <- true/);
	assert.match(program, /if \(occupied != null && D4_PointKey\(depot_point\) in occupied\) continue/);
	assert.match(program, /D4_DirectionBetween\(prev2, a\) != dir/);
	assert.match(program, /D4_DirectionBetween\(front, next\) != dir/);
	assert.doesNotMatch(program, /local a = path\[1\]/);
});

test("Rollback ignores diagnostic journal records before validating rollback assets", () => {
  const journal = readFileSync(join(gameDir, "operation_journal.nut"), "utf8");
  const start = journal.indexOf("function D4_RollbackOperation");
  const skipDiagnostics = journal.indexOf('if (entry.kind != "created") continue;', start);
  const validateAsset = journal.indexOf("D4_IsSafeJournalEntry(entry, op.company_id, map_area)", start);
  assert.ok(skipDiagnostics > start);
  assert.ok(validateAsset > skipDiagnostics);
});

test("Single-shuttle routing uses the real station tiles as endpoint context", () => {
  const program = readFileSync(join(gameDir, "build_program.nut"), "utf8");
  const store = readFileSync(join(gameDir, "plan_store.nut"), "utf8");
  const version = readFileSync(join(gameDir, "version.nut"), "utf8");
  assert.match(program, /local source_entry = D4_NearestBlueprintPortPoint\(plan\.station_blueprint, "platform_body", start\)/);
  assert.match(program, /local destination_exit = D4_NearestBlueprintPortPoint\(plan\.destination_blueprint, "platform_body", goal\)/);
  assert.match(program, /D4_AppendLaneOperations\(ops, "outbound", route\.path, source_entry, destination_exit\)/);
  assert.match(program, /local prev = i > 0 \? path\[i - 1\] : \(entry_point != null \? entry_point/);
  assert.match(program, /local next = i \+ 1 < path\.len\(\) \? path\[i \+ 1\] : \(exit_point != null \? exit_point/);
  assert.match(program, /function D4_UpgradeBuildProgram\(plan\)/);
  assert.match(program, /first_rail\.prev = source_station\.tile/);
  assert.match(program, /last_rail\.next = destination_station\.tile/);
  assert.match(store, /if \(D4_UpgradeBuildProgram\(plan\)\)/);
  assert.match(version, /DIRECTORATE_M4_BUILD_PROGRAM_VERSION <- 3/);
  const gate = readFileSync("tests/integration/directorate-real-engine-gate.mjs", "utf8");
  assert.match(gate, /migration_safety_probe/);
  assert.match(gate, /all_rejected/);
  assert.match(gate, /load_budget_probe_seed/);
  assert.match(gate, /entries_each !== 111/);
});

test("Through-hub blueprint is populated in every definition table", () => {
  const blueprint = readFileSync(join(gameDir, "blueprint.nut"), "utf8");
  assert.match(blueprint, /local defs = \{/);
  assert.match(blueprint, /D4_SetupThroughHub\(defs, "through_hub_4x7", 4, 7\);/);
  assert.match(blueprint, /D4_SetupThroughHub\(defs, "through_hub_2x4", 2, 4\);\s*return defs;/);
  assert.match(blueprint, /function D4_SetupThroughHub\(defs, name, num_platforms, platform_length\)/);
  assert.match(blueprint, /defs\[name\]\.tiles = tiles;/);
  assert.match(blueprint, /ports\.throat_ne\.append\(\{ x = platform_length, y = y \}\)/);
  assert.match(blueprint, /ports\.throat_sw\.append\(\{ x = -1, y = y \}\)/);
  assert.match(blueprint, /platform_front/);
  assert.match(blueprint, /platform_rear/);
  assert.match(blueprint, /ports\.common_inbound = \[\{ x = -num_platforms - 2, y = -1 \}\]/);
  assert.match(blueprint, /ports\.common_outbound = \[\{ x = -num_platforms - 2, y = -2 \}\]/);
  assert.match(blueprint, /ports\.common_rear_merge = \[\{ x = platform_length \+ num_platforms, y = -1 \}\]/);
  assert.doesNotMatch(blueprint, /ports\.throat_ne\.append\(\{ x = x, y = -1 \}\)/);
  assert.doesNotMatch(blueprint, /function D4_SetupThroughHub\(\)\s*\{\s*local defs = D4_GetBlueprintDefinitions\(\)/);
  assert.doesNotMatch(blueprint, /\nD4_SetupThroughHub\(\);/);
});

test("Station spread reads the live OpenTTD game setting", () => {
  const survey = readFileSync(join(gameDir, "site_survey.nut"), "utf8");
  assert.match(survey, /GSGameSettings\.IsValid\("station\.station_spread"\)/);
  assert.match(survey, /GSGameSettings\.GetValue\("station\.station_spread"\)/);
  assert.doesNotMatch(survey, /GSController\.GetSetting\("station_spread"\)/);
});

test("Paired corridors emit bounded one-way PBS signals while staged single track stays unsignalled", () => {
  const program = readFileSync(join(gameDir, "build_program.nut"), "utf8");
  assert.match(program, /signals_enabled = paired_mode/);
  assert.match(program, /D4_AppendLaneSignals\(ops, "outbound", route\.path/);
  assert.match(program, /D4_AppendLaneSignals\(ops, "return", paired\.return_lane/);
  assert.match(program, /signal_type = GSRail\.SIGNALTYPE_PBS_ONEWAY/);
  assert.match(program, /front = D4_ToTile\(path\[i - 1\]\)/);
  assert.match(program, /incoming != outgoing/);
  assert.match(program, /op\.kind == "signal" && op\.tile in tested_rails && !GSRail\.IsRailTile\(op\.tile\)/);
  assert.match(program, /commit performs authoritative signal readback/);
  assert.match(program, /initial_single_track/);
  assert.match(program, /paired_mode = !single_shuttle && !initial_single_track/);
});

test("Paired corridor connects through-hub endpoints through common fan and merge topology", () => {
  const program = readFileSync(join(gameDir, "build_program.nut"), "utf8");
  assert.match(program, /function D4_CompileThroughHubRoroProgram/);
  assert.match(program, /D4_BlueprintPortLocation\(plan\.station_blueprint, "common_inbound"\)/);
  assert.match(program, /D4_BlueprintPortLocation\(plan\.station_blueprint, "common_outbound"\)/);
  assert.match(program, /D4_AppendThroughHubEndpoint\(ops, "source"/);
  assert.match(program, /D4_AppendThroughHubEndpoint\(ops, "destination"/);
  assert.match(program, /function D4_DeriveThroughHubEndpointLayout/);
  assert.match(program, /local entry = layout\.throat_sw\[i\]/);
  assert.match(program, /local exitp = layout\.throat_ne\[i\]/);
  assert.match(program, /D4_AppendUniqueLaneOperations\(ops, prefix \+ "\.loop", layout\.loop_path/);
  assert.match(program, /foreach \(side_turns in \[1, 3\]\)/);
  assert.match(program, /D4_DeriveProgramLanes\(outbound\.path, side_turns\)/);
  assert.match(program, /through_hub_paired_lane_endpoint_mismatch/);
  assert.match(program, /through_hub_source_exit_heading_mismatch/);
  assert.match(program, /through_hub_destination_exit_heading_mismatch/);
  assert.match(program, /source_manifest\.manifest\.loop_exit_heading/);
  assert.match(program, /dest_manifest\.manifest\.fan_entry_heading, 4, 50, turn_clearance, true\)/);
  assert.match(program, /local turn_clearance = source_manifest\.manifest\.platform_length/);
  assert.match(program, /maximum consist envelope/);
  assert.match(program, /if \(!outbound\.ok && turn_clearance > 3\)/);
  assert.match(program, /fan_entry_heading, 4, 50, 3, true\)/);
  assert.match(program, /curve_clearance_relaxed = curve_clearance_relaxed/);
  assert.match(program, /function D4_HasBuildablePairedLane/);
  assert.match(program, /function D4_BuildTwoTurnCenterline/);
  assert.match(program, /D4_BuildTwoTurnCenterline\(start, goal, company_id, required_start_dir, min_turn_run, require_paired_lane\)/);
  assert.match(program, /local approach = D4_Offset\(goal, D4_RotateDir\(required_goal_dir, 2\), min_turn_run\)/);
  assert.match(program, /local prefix = D4_BuildLegalCenterline\(start, approach, company_id, policy, required_start_dir, required_goal_dir, max_turns, turn_cost_override, 0, false\)/);
  assert.match(program, /function D4_ValidateCenterlineCandidate/);
  assert.match(program, /turning && min_turn_run > 0 && node\.run < min_turn_run/);
  assert.match(program, /node\.point\.x == goal\.x && node\.point\.y == goal\.y && \(min_turn_run <= 0 \|\| node\.run >= min_turn_run\)/);
  assert.match(program, /turns = child_turns, run = child_run/);
  assert.match(program, /D4_DepotOperation\(returned\.return_lane, occupied, true, "exit_to_next"\)/);
  assert.doesNotMatch(program, /local returned = D4_BuildLegalCenterline\(dest_out, source_in/);
  assert.match(program, /kind = "through_hub_roro"/);
  assert.match(program, /signals = D4_ProgramSignalManifest\(ops\)/);
  assert.match(program, /fingerprint = D4_BoundedFingerprint\(\{ topology = topology/);
  assert.match(program, /function D4_SelectBestSitePair\(source_candidates, destination_candidates, excluded = null\)/);
  assert.match(program, /pair_key in excluded/);
  assert.match(program, /source_layout\.loop_exit_heading != source_to_destination/);
  assert.match(program, /function D4_VerifyThroughHubEndpointTopology/);
  assert.match(program, /function D4_IsSafeThroughHubTopology/);
  assert.match(program, /function D4_IsSafeSignalManifest/);
  assert.match(program, /entry_not_common_inbound/);
  assert.match(program, /entry_not_adjacent_platform/);
  assert.match(program, /entry_platform_duplicate/);
  assert.match(program, /exit_not_common_rear_merge/);
  assert.match(program, /exit_not_adjacent_platform/);
  assert.match(program, /exit_platform_duplicate/);
  assert.match(program, /loop_not_common_outbound/);
  assert.match(program, /loop_exit_heading_mismatch/);
  assert.match(program, /fan_entry_heading_mismatch/);
  assert.match(program, /function D4_VerifyThroughHubTrunks/);
  assert.match(program, /outbound_not_source_common_exit/);
  assert.match(program, /return_not_source_common_entry/);
  assert.match(program, /signal_missing_or_wrong_facing/);
  assert.doesNotMatch(program, /rail\.prev == station\.tile/);
  assert.doesNotMatch(program, /rail\.next == station\.tile/);
});

test("Commissioning rejects occupied depots and bounds a fresh consist to the station", () => {
  const routes = readFileSync(join(gameDir, "route_registry.nut"), "utf8");
  assert.match(routes, /function D4_HasFreeWagonStockAtDepot\(depot_tile\)/);
  assert.match(routes, /GSVehicleList\(\)/);
  assert.match(routes, /GSVehicle\.IsPrimaryVehicle\(vehicle_id\)/);
  assert.match(routes, /GSVehicle\.IsStoppedInDepot\(vehicle_id\)/);
  assert.match(routes, /GSEngine\.CanRunOnRail\(candidate, rail_type\)/);
  assert.match(routes, /depot_free_stock_present/);
  assert.match(routes, /MoveWagon\(wagon_id, 0, vehicle_id, destination_wagon\)/);
  assert.match(routes, /SellWagonChain\(wagon_id, 0\)/);
  assert.match(routes, /wagon_build_failed/);
  assert.match(routes, /wagon_move_failed/);
  assert.match(routes, /consist_length > platform_units/);
  assert.match(routes, /built_wagons < 1 \|\| GSVehicle\.GetCapacity/);
  assert.match(routes, /reused_wagons/);
  assert.match(routes, /function D4_ListIndustriesForCargo/);
  const bridge = readFileSync(join(gameDir, "bridge.nut"), "utf8");
  assert.match(bridge, /payload\.command == "list_industries"/);
});

test("Plan retention prunes failed planning envelopes before they exhaust Load", () => {
  const store = readFileSync(join(gameDir, "plan_store.nut"), "utf8");
  assert.match(store, /plan\.revision == 0 && plan\.phase == "planning"/);
  assert.match(store, /delete this\.plans\[id\]/);
  assert.match(store, /exhaust OpenTTD's Load budget/);
});

test("Station survey uses authoritative producer and acceptor catchment tiles", () => {
  const survey = readFileSync(join(gameDir, "site_survey.nut"), "utf8");
  const store = readFileSync(join(gameDir, "plan_store.nut"), "utf8");
  assert.match(survey, /GSTileList_IndustryProducing\(industry_id, catchment\)/);
  assert.match(survey, /GSTileList_IndustryAccepting\(industry_id, catchment\)/);
  assert.match(survey, /catchment_tiles\.HasItem\(D4_ToTile\(tile\.point\)\)/);
  assert.doesNotMatch(survey, /abs\(tile\.point\.x - industry_location\.x\) \+ abs\(tile\.point\.y - industry_location\.y\)/);
  assert.match(store, /D4_SurveyStationSites\(plan\.company_id, source_id, "source", template/);
  assert.match(store, /D4_SurveyStationSites\(plan\.company_id, dest_id, "destination", template/);
  assert.match(store, /site_pair_skip/);
  assert.match(store, /pair_rank <= pair_skip/);
});

test("Planning input rejects tile lists and path inputs", () => {
  const util = readFileSync(join(gameDir, "util.nut"), "utf8");
  const store = readFileSync(join(gameDir, "plan_store.nut"), "utf8");
  assert.match(util, /D4_ContainsForbiddenPlanningInput/);
  assert.match(util, /"tile"/);
  assert.match(util, /"tiles"/);
  assert.match(util, /"path"/);
  assert.match(util, /"waypoints"/);
  assert.match(store, /D4_ContainsForbiddenPlanningInput/);
});

test("Operation journal keeps durable idempotent request/replay contracts", () => {
  const journal = readFileSync(join(gameDir, "operation_journal.nut"), "utf8");
  assert.match(journal, /class DirectorateM4OperationJournal/);
  assert.match(journal, /function D4_ApplyRequestFingerprint/);
  assert.match(journal, /function D4_RunApplyPhases/);
  assert.match(journal, /request_fingerprint/);
  assert.match(journal, /function ValidateReuse/);
  assert.match(journal, /function Replay/);
  assert.match(journal, /operation_phase_mismatch/);
  assert.match(journal, /operation_request_mismatch/);
  assert.match(journal, /operation_id_required/);
  assert.match(journal, /target_operation_id_required/);
});

test("Main Save/Load keeps plan and registry envelope version", () => {
  const main = readFileSync(join(gameDir, "main.nut"), "utf8");
  assert.match(main, /DIRECTORATE_M4_SAVE_VERSION/);
  assert.match(main, /this\.store\.Save\(\)/);
  assert.match(main, /data\.version == DIRECTORATE_M4_SAVE_VERSION/);
  assert.match(main, /this\.pending_load = data\.plans/);
  assert.match(main, /this\.store\.BeginLoad\(this\.pending_load\)/);
});

test("TS contracts expose commission request and bounded verify schema", () => {
  const types = readFileSync("src/gateway/types.ts", "utf8");
  const schemas = readFileSync("src/mcp/schemas.ts", "utf8");
  assert.match(types, /interface CommissionRequest/);
  assert.match(schemas, /boundedOperationId/);
  assert.match(schemas, /commissionSchema/);
  assert.match(schemas, /verifySchema/);
  assert.match(schemas, /verify requires exactly one of route_id, plan_id, or operation_id/);
  assert.match(schemas, /level: z\.enum\(\["topology", "commissioning", "economic"\]\)/);
});

test("Camera director moves only the stream camera client, sweeping builds and following vehicles", () => {
  const director = readFileSync(join(gameDir, "director.nut"), "utf8");
  const main = readFileSync(join(gameDir, "main.nut"), "utf8");
  const journal = readFileSync(join(gameDir, "operation_journal.nut"), "utf8");
  const registry = readFileSync(join(gameDir, "route_registry.nut"), "utf8");
  assert.match(director, /DIRECTORATE_CAMERA_CLIENT <- "TamagoCam"/);
  assert.match(director, /GSViewport\.ScrollClientTo\(client, tile\)/);
  assert.doesNotMatch(director, /ScrollEveryoneTo|ScrollCompanyClientsTo/);
  assert.doesNotMatch(director, /GSCompanyMode\(/);
  assert.match(director, /this\.sweep\.append\(tile\)/);
  assert.match(main, /require\("director\.nut"\)/);
  assert.match(main, /::D4_Camera\.Tick\(\)/);
  assert.match(journal, /if \(!built\.reused && D4_Camera != null\) D4_Camera\.Building\(program_op\.tile\)/);
  assert.match(registry, /D4_Camera\.Feature\(vehicle_id\)/);
});
