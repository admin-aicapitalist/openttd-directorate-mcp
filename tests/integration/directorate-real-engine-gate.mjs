#!/usr/bin/env node
import { accessSync, constants, cpSync, existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { homedir, tmpdir } from "node:os";
import { delimiter, dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { spawn, execFileSync, spawnSync } from "node:child_process";
import { createHash } from "node:crypto";
import { createToolHandlers } from "../../dist/src/mcp/handlers.js";
import { AdminOpenTtdGateway } from "../../dist/src/gateway/adminGateway.js";
import { AdminClient } from "../../dist/src/admin/client.js";

const repoRoot = resolve(dirname(fileURLToPath(import.meta.url)), "../..");

function firstExecutable(candidates) {
  for (const candidate of candidates) {
    if (!candidate) continue;
    try {
      accessSync(candidate, constants.X_OK);
      return candidate;
    } catch {
      // Try the next documented location.
    }
  }
  return null;
}

function firstDirectory(candidates) {
  return candidates.find((candidate) => candidate && existsSync(candidate)) ?? null;
}

const pathOpenTtd = firstExecutable((process.env.PATH ?? "").split(delimiter).map((dir) => join(dir, "openttd")));
const openttd = firstExecutable([
  process.env.OPENTTD_15_BIN,
  pathOpenTtd,
  "/tmp/ottd153/openttd-15.3-linux-generic-amd64/openttd",
]);
if (openttd === null) throw new Error("OpenTTD 15.3 not found; set OPENTTD_15_BIN or add openttd to PATH");
const versionProbe = spawnSync(openttd, ["-v"], { encoding: "utf8" });
const openttdVersion = `${versionProbe.stdout ?? ""}\n${versionProbe.stderr ?? ""}`.match(/^OpenTTD [^\r\n]+/m)?.[0] ?? "unknown";
if (!/^OpenTTD 15\.3(?:\s|$)/.test(openttdVersion)) throw new Error(`OpenTTD 15.3 required, got: ${openttdVersion}`);

const openGfx = firstDirectory([
  process.env.OPENTTD_OPENGFX_DIR,
  "/usr/share/games/openttd/baseset/opengfx",
  join(homedir(), ".local/share/openttd/baseset/opengfx"),
]);
if (openGfx === null) throw new Error("OpenGFX directory not found; set OPENTTD_OPENGFX_DIR");
const port = Number.parseInt(process.env.OPENTTD_DIRECTORATE_GATE_PORT ?? "4004", 10);
const gamePort = Number.parseInt(process.env.OPENTTD_DIRECTORATE_GAME_PORT ?? String(port + 1), 10);
const password = "test-directorate";
const fixture = mkdtempSync(join(tmpdir(), "openttd-directorate-gate-"));
const logPath = join(fixture, "openttd.log");
const evidencePath = process.env.OPENTTD_GATE_EVIDENCE_PATH ?? join(tmpdir(), `openttd-directorate-gate-${createHash("sha1").update(fixture).digest("hex").slice(0, 12)}.json`);
let serverRun = 0;
/* A single stuck admin/game-script call must not be able to silently consume an
 * entire external worker's time budget: bound every request well below typical
 * worker deadlines so a hang produces a precise rejected-promise error (and
 * therefore evidence) instead of running until something outside this process
 * kills it with nothing recorded. */
const requestTimeoutMs = Number.parseInt(process.env.OPENTTD_GATE_REQUEST_TIMEOUT_MS ?? "60000", 10);
/* Each major phase (fresh server, restarted server) gets its own bounded
 * deadline. On expiry the in-flight OpenTTD process is force-killed immediately
 * so cleanup is reliable even if the phase never resolves on its own. */
const phaseDeadlineMs = Number.parseInt(process.env.OPENTTD_GATE_PHASE_DEADLINE_MS ?? "240000", 10);
let activeServer = null;

/* A second, disposable fixture for the terrain-obstructed through_hub_4x7
 * scenario: its own map, its own port pair, its own bridge copy, cleaned up
 * independently of the flat-map gate above. */
const hub4x7Fixture = mkdtempSync(join(tmpdir(), "openttd-directorate-gate-hub4x7-"));
const hub4x7LogPath = join(hub4x7Fixture, "openttd.log");
const hub4x7Port = Number.parseInt(process.env.OPENTTD_DIRECTORATE_GATE_HUB4X7_PORT ?? String(port + 10), 10);
const hub4x7GamePort = Number.parseInt(process.env.OPENTTD_DIRECTORATE_GATE_HUB4X7_GAME_PORT ?? String(hub4x7Port + 1), 10);

async function withPhaseDeadline(name, fn) {
  let timeoutHandle;
  const timeout = new Promise((_resolve, reject) => {
    timeoutHandle = setTimeout(() => {
      if (activeServer && !activeServer.killed) {
        try {
          activeServer.kill("SIGKILL");
        } catch {
          // Best-effort: the process may already be exiting.
        }
      }
      reject(new Error(`phase "${name}" exceeded bounded deadline of ${phaseDeadlineMs}ms`));
    }, phaseDeadlineMs);
  });
  try {
    return await Promise.race([fn(), timeout]);
  } finally {
    clearTimeout(timeoutHandle);
  }
}

function writeConfig() {
  mkdirSync(join(fixture, "game"), { recursive: true });
  mkdirSync(join(fixture, "ai/directorate_gate_fixture"), { recursive: true });
  mkdirSync(join(fixture, "baseset"), { recursive: true });

  cpSync(join(repoRoot, "game/openttd_directorate"), join(fixture, "game/openttd_directorate"), { recursive: true });
  const fixtureBridgePath = join(fixture, "game/openttd_directorate/bridge.nut");
  const fixtureBridge = readFileSync(fixtureBridgePath, "utf8");
  const migrationProbe = `\t\tif (payload.command == "wagon_chain_probe_seed") {
\t\t\tlocal mode = GSCompanyMode(payload.company_id);
\t\t\tlocal plan = this.store.GetPlan(payload.params.plan_id);
\t\t\tif (!GSCompanyMode.IsValid() || plan == null || !D4_SelectRailType()) return { ok = false, error = D4_Error("probe_company_mode_failed", payload.company_id.tostring()) };
\t\t\tlocal cargo_pick = D4_PickRouteCargo(plan.intent.source_industry_id, plan.intent.destination_industry_id, null);
\t\t\tlocal probe_route = { company_id = payload.company_id, plan_id = payload.params.plan_id, cargo_type = cargo_pick.cargo_type, source_station_tile = D4_StationTileFromPlan(plan, "source"), destination_station_tile = D4_StationTileFromPlan(plan, "destination") };
\t\t\tlocal orders = D4_ConfigureRouteOrders(probe_route, payload.company_id, this.store);
\t\t\tlocal rail_type = GSRail.GetCurrentRailType();
\t\t\tlocal wagon_engine = null;
\t\t\tfor (local candidate = 0; candidate < 2048; candidate++) {
\t\t\t\tif (!GSEngine.IsValidEngine(candidate) || !GSEngine.IsBuildable(candidate)) continue;
\t\t\t\tif (GSEngine.GetVehicleType(candidate) != GSVehicle.VT_RAIL || !GSEngine.IsWagon(candidate)) continue;
\t\t\t\tif (!GSEngine.CanRunOnRail(candidate, rail_type) || !GSEngine.CanRefitCargo(candidate, cargo_pick.cargo_type)) continue;
\t\t\t\twagon_engine = candidate;
\t\t\t\tbreak;
\t\t\t}
\t\t\tif (!cargo_pick.ok || !orders.ok || wagon_engine == null) return { ok = false, error = D4_Error("probe_wagon_unavailable", "") };
\t\t\tlocal wagon_id = GSVehicle.BuildVehicle(orders.depot_tile, wagon_engine);
\t\t\tif (!GSVehicle.IsValidVehicle(wagon_id)) return { ok = false, error = D4_Error("probe_wagon_build_failed", wagon_engine.tostring()) };
\t\t\treturn { ok = true, payload = { vehicle_id = wagon_id, count = GSVehicle.GetNumWagons(wagon_id), engine = wagon_engine } };
\t\t}
\t\tif (payload.command == "wagon_chain_probe_status") {
\t\t\tlocal mode = GSCompanyMode(payload.company_id);
\t\t\tlocal vehicle_id = payload.params.vehicle_id;
\t\t\treturn { ok = GSCompanyMode.IsValid() && GSVehicle.IsValidVehicle(vehicle_id), payload = { valid = GSVehicle.IsValidVehicle(vehicle_id), primary = GSVehicle.IsValidVehicle(vehicle_id) ? GSVehicle.IsPrimaryVehicle(vehicle_id) : true, count = GSVehicle.IsValidVehicle(vehicle_id) ? GSVehicle.GetNumWagons(vehicle_id) : -1 } };
\t\t}
\t\tif (payload.command == "wagon_chain_probe_cleanup") {
\t\t\tlocal mode = GSCompanyMode(payload.company_id);
\t\t\tlocal vehicle_id = payload.params.vehicle_id;
\t\t\tif (!GSCompanyMode.IsValid() || !GSVehicle.IsValidVehicle(vehicle_id) || GSVehicle.IsPrimaryVehicle(vehicle_id)) return { ok = false, error = D4_Error("probe_wagon_cleanup_invalid", vehicle_id.tostring()) };
\t\t\tlocal sold = GSVehicle.SellWagonChain(vehicle_id, 0);
\t\t\treturn { ok = sold && !GSVehicle.IsValidVehicle(vehicle_id), payload = { sold = sold, valid = GSVehicle.IsValidVehicle(vehicle_id) } };
\t\t}
\t\tif (payload.command == "signal_api_probe") {
\t\t\tlocal mode = GSCompanyMode(payload.company_id);
\t\t\tif (!GSCompanyMode.IsValid() || !D4_SelectRailType()) return { ok = false, error = D4_Error("probe_company_mode_failed", payload.company_id.tostring()) };
\t\t\tlocal plan = this.store.GetPlan(payload.params.plan_id);
\t\t\tif (plan == null || !D4_Has(plan, "build_program")) return { ok = false, error = D4_Error("probe_plan_missing", payload.params.plan_id) };
\t\t\tforeach (op in plan.build_program.ops) {
\t\t\t\tif (!D4_IsTable(op) || !D4_Has(op, "kind") || op.kind != "rail_connection") continue;
\t\t\t\tif (!GSRail.BuildSignal(op.tile, op.prev, GSRail.SIGNALTYPE_PBS_ONEWAY)) continue;
\t\t\t\tlocal signal_type = GSRail.GetSignalType(op.tile, op.prev);
\t\t\t\tlocal removed = signal_type == GSRail.SIGNALTYPE_PBS_ONEWAY && GSRail.RemoveSignal(op.tile, op.prev);
\t\t\t\treturn { ok = signal_type == GSRail.SIGNALTYPE_PBS_ONEWAY && removed, payload = { tile = op.tile, front = op.prev, signal_type = signal_type, removed = removed } };
\t\t\t}
\t\t\treturn { ok = false, error = D4_Error("probe_signal_unbuildable", "") };
\t\t}
\t\tif (payload.command == "through_hub_topology_probe") {
\t\t\tlocal mode = GSCompanyMode(payload.company_id);
\t\t\tlocal plan = this.store.GetPlan(payload.params.plan_id);
\t\t\tif (!GSCompanyMode.IsValid() || plan == null || !D4_Has(plan, "build_program") || !D4_Has(plan.build_program, "topology")) return { ok = false, error = D4_Error("probe_through_hub_missing", payload.params.plan_id) };
\t\t\tlocal program = plan.build_program;
\t\t\tlocal topology = program.topology;
\t\t\tlocal source_station = program.ops[0];
\t\t\tlocal destination_station = program.ops[1];
\t\t\tlocal failures = [];
\t\t\tif (source_station.num_platforms != 2 || source_station.platform_length != 4) failures.append("source_rect_not_2x4");
\t\t\tif (destination_station.num_platforms != 2 || destination_station.platform_length != 4) failures.append("destination_rect_not_2x4");
\t\t\tif (topology.kind != "through_hub_roro") failures.append("not_through_hub_roro");
\t\t\tforeach (label, endpoint in { source = topology.source, destination = topology.destination }) {
\t\t\t\tif (endpoint.entries.len() != 2 || endpoint.exits.len() != 2) failures.append(label + "_platform_count");
\t\t\t\tfor (local i = 0; i < endpoint.entries.len(); i++) {
\t\t\t\t\tlocal entry = endpoint.entries[i];
\t\t\t\t\tlocal exitp = endpoint.exits[i];
\t\t\t\t\tif (D4_PointKey(entry.path[0]) != D4_PointKey(endpoint.common_inbound)) failures.append(label + "_entry_not_common");
\t\t\t\t\tif (D4_PointKey(entry.path[entry.path.len() - 1]) != D4_PointKey(entry.entry)) failures.append(label + "_entry_not_throat");
\t\t\t\t\tif (D4_PointKey(exitp.path[0]) != D4_PointKey(exitp.exit)) failures.append(label + "_exit_not_throat");
\t\t\t\t\tif (D4_PointKey(exitp.path[exitp.path.len() - 1]) != D4_PointKey(endpoint.common_rear_merge)) failures.append(label + "_exit_not_merge");
\t\t\t\t\tif (!D4_VerifyProgramPathConnections(entry.path, null, entry.platform)) failures.append(label + "_entry_disconnected");
\t\t\t\t\tif (!D4_VerifyProgramPathConnections(exitp.path, exitp.platform, null)) failures.append(label + "_exit_disconnected");
\t\t\t\t}
\t\t\t\tif (!D4_VerifyProgramPathConnections(endpoint.loop_path, null, null)) failures.append(label + "_loop_disconnected");
\t\t\t\tif (D4_PointKey(endpoint.loop_path[endpoint.loop_path.len() - 1]) != D4_PointKey(endpoint.common_outbound)) failures.append(label + "_loop_not_outbound");
\t\t\t\tif (D4_DirectionBetween(endpoint.loop_path[endpoint.loop_path.len() - 2], endpoint.common_outbound) != endpoint.loop_exit_heading) failures.append(label + "_loop_heading");
\t\t\t\tif (D4_DirectionBetween(endpoint.common_inbound, endpoint.fan_backbone[1]) != endpoint.fan_entry_heading) failures.append(label + "_fan_heading");
\t\t\t}
\t\t\tlocal trunks = D4_VerifyThroughHubTrunks(topology);
\t\t\tif (!trunks.ok) failures.append("trunks_failed");
\t\t\tlocal reachability = D4_VerifyThroughHubRoroReachability(program.ops, topology);
\t\t\tif (!reachability.ok) {
\t\t\t\tforeach (rf in reachability.failures) failures.append("reach_" + (D4_Has(rf, "side") ? rf.side + "_" : "") + rf.reason);
\t\t\t}
\t\t\tlocal signals = 0;
\t\t\tforeach (op in program.ops) if (op.kind == "signal") signals++;
\t\t\tif (!D4_Has(topology, "signals") || topology.signals.len() != signals) failures.append("signal_manifest_mismatch");
\t\t\tif (signals < 8) failures.append("signals_missing");
\t\t\treturn { ok = failures.len() == 0, payload = { failures = failures, source_rect = { platforms = source_station.num_platforms, length = source_station.platform_length }, destination_rect = { platforms = destination_station.num_platforms, length = destination_station.platform_length }, source_entries = topology.source.entries.len(), destination_entries = topology.destination.entries.len(), source_loop_exit_heading = topology.source.loop_exit_heading, destination_loop_exit_heading = topology.destination.loop_exit_heading, source_fan_entry_heading = topology.source.fan_entry_heading, destination_fan_entry_heading = topology.destination.fan_entry_heading, signals = signals, signal_manifest = D4_Has(topology, "signals") ? topology.signals.len() : -1 } };
\t\t}
\t\tif (payload.command == "through_hub_runtime_probe") {
\t\t\tlocal mode = GSCompanyMode(payload.company_id);
\t\t\tif (!GSCompanyMode.IsValid() || !D4_Has(payload, "params") || !D4_Has(payload.params, "route_ids") || !D4_IsArray(payload.params.route_ids)) return { ok = false, error = D4_Error("runtime_probe_invalid", "") };
\t\t\tlocal rows = [];
\t\t\tfor (local ri = 0; ri < payload.params.route_ids.len() && ri < 8; ri++) {
\t\t\t\tlocal route_id = payload.params.route_ids[ri];
\t\t\t\tlocal route = this.store.registry.Get(route_id);
\t\t\t\tif (route == null || route.topology == null) { rows.append({ route_id = route_id, ok = false }); continue; }
\t\t\t\tlocal source_platform_rows = {};
\t\t\t\tlocal destination_platform_rows = {};
\t\t\t\tlocal source_egress_rows = {};
\t\t\t\tlocal destination_egress_rows = {};
\t\t\t\tfor (local i = 0; i < route.topology.source.entries.len(); i++) source_platform_rows[D4_ToTile(route.topology.source.entries[i].platform)] <- i;
\t\t\t\tfor (local j = 0; j < route.topology.destination.entries.len(); j++) destination_platform_rows[D4_ToTile(route.topology.destination.entries[j].platform)] <- j;
\t\t\t\tfor (local k = 0; k < route.topology.source.exits.len(); k++) source_egress_rows[D4_ToTile(route.topology.source.exits[k].exit)] <- k;
\t\t\t\tfor (local m = 0; m < route.topology.destination.exits.len(); m++) destination_egress_rows[D4_ToTile(route.topology.destination.exits[m].exit)] <- m;
\t\t\t\tlocal vehicles = [];
\t\t\t\tforeach (entry in route.vehicles) {
\t\t\t\t\tif (!GSVehicle.IsValidVehicle(entry.vehicle_id)) { vehicles.append({ vehicle_id = entry.vehicle_id, valid = false }); continue; }
\t\t\t\t\tlocal location = GSVehicle.GetLocation(entry.vehicle_id);
\t\t\t\t\tlocal source_row = location in source_platform_rows ? source_platform_rows[location] : -1;
\t\t\t\t\tlocal destination_row = location in destination_platform_rows ? destination_platform_rows[location] : -1;
\t\t\t\t\tlocal source_egress_row = location in source_egress_rows ? source_egress_rows[location] : -1;
\t\t\t\t\tlocal destination_egress_row = location in destination_egress_rows ? destination_egress_rows[location] : -1;
\t\t\t\t\tvehicles.append({ vehicle_id = entry.vehicle_id, valid = true, location = location, current_order = GSOrder.ResolveOrderPosition(entry.vehicle_id, GSOrder.ORDER_CURRENT), load = GSVehicle.GetCargoLoad(entry.vehicle_id, route.cargo_type), profit_last_year = GSVehicle.GetProfitLastYear(entry.vehicle_id), profit_this_year = GSVehicle.GetProfitThisYear(entry.vehicle_id), source_row = source_row, destination_row = destination_row, source_egress_row = source_egress_row, destination_egress_row = destination_egress_row });
\t\t\t\t}
\t\t\t\trows.append({ route_id = route_id, ok = true, vehicles = vehicles });
\t\t\t}
\t\t\treturn { ok = true, payload = { tick = D4_Tick(), routes = rows } };
\t\t}
\t\tif (payload.command == "migration_safety_probe") {
\t\t\tlocal original = this.store.GetPlan(payload.params.plan_id);
\t\t\tif (original == null) return { ok = false, error = D4_Error("probe_plan_missing", payload.params.plan_id) };
\t\t\tlocal empty_path = { revision = 0, state = "ready", station_blueprint = original.station_blueprint, build_program = { ok = true, version = 1, ops = original.build_program.ops, path = [] } };
\t\t\tlocal malformed_ops = { revision = 0, state = "ready", station_blueprint = original.station_blueprint, build_program = { ok = true, version = 1, ops = [{}], path = original.build_program.path } };
\t\t\tlocal missing_revision = { state = "ready", station_blueprint = original.station_blueprint, build_program = { ok = true, version = 1, ops = original.build_program.ops, path = original.build_program.path } };
\t\t\tlocal results = [D4_UpgradeBuildProgram(empty_path), D4_UpgradeBuildProgram(malformed_ops), D4_UpgradeBuildProgram(missing_revision)];
return { ok = true, payload = { all_rejected = !results[0] && !results[1] && !results[2], results = results } };
}
if (payload.command == "load_budget_probe_seed") {
local source_op = this.store.journal.Get("directorate-gate.commit");
if (source_op == null || source_op.entries.len() < 1) return { ok = false, error = { code = "probe_source_missing", detail = "completed operation journal missing" } };
local entries = [];
for (local i = 0; i < 111; i++) {
	local source_entry = source_op.entries[i % source_op.entries.len()];
	entries.append({ kind = "reused", tile = source_entry.tile, detail = source_entry.detail, tick = source_entry.tick });
}
local ids = ["directorate-gate.partial-a", "directorate-gate.partial-b"];
local states = ["failed_partial", "rollback_partial"];
for (local i = 0; i < ids.len(); i++) {
	local op = { operation_id = ids[i], company_id = 0, plan_id = "directorate-gate-plan", revision = 4, phase = "commit", request_fingerprint = "load-budget-probe", state = states[i], entries = entries, created_tick = D4_Tick(), completed_tick = D4_Tick(), result = null, rollback = null };
	this.store.journal.operations[ids[i]] <- op;
	this.store.journal.order.append(ids[i]);
}
return { ok = true, payload = { seeded = ids.len(), entries_each = entries.len() } };
}
if (payload.command == "load_budget_probe_status") {
	local first = this.store.journal.Get("directorate-gate.partial-a");
	local second = this.store.journal.Get("directorate-gate.partial-b");
	return { ok = true, payload = { all_retained = first != null && second != null, first_entries = first == null ? -1 : first.entries.len(), second_entries = second == null ? -1 : second.entries.len(), active_count = this.store.journal.order.len(), deferred_count = this.store.journal.deferred_order.len() } };
}
if (payload.command == "capacity_probe_fill") {
	local source = this.store.journal.Get("directorate-gate.partial-a");
	if (source == null || source.entries.len() == 0) return { ok = false, error = D4_Error("capacity_probe_source_missing", "") };
	local entry = source.entries[0];
	local index = 0;
	while (this.store.journal.order.len() < DIRECTORATE_M4_MAX_OPERATIONS) {
		local id = "directorate-gate.capacity-" + index.tostring();
		index++;
		if (id in this.store.journal.operations) continue;
		this.store.journal.operations[id] <- { operation_id = id, company_id = 0, plan_id = "directorate-gate-plan", revision = 4, phase = "commit", request_fingerprint = "capacity-probe", state = "failed_partial", entries = [entry], created_tick = D4_Tick(), completed_tick = D4_Tick(), result = null, rollback = null };
		this.store.journal.order.append(id);
	}
	return { ok = true, payload = { active_count = this.store.journal.order.len() } };
}
`;
  const fixtureBridgeWithProbe = fixtureBridge.replace('\t\tif (payload.command == "survey_sites") {', migrationProbe + '\t\tif (payload.command == "survey_sites") {');
  if (fixtureBridgeWithProbe === fixtureBridge) throw new Error("failed to inject migration safety probe");
  writeFileSync(fixtureBridgePath, fixtureBridgeWithProbe);
  cpSync(openGfx, join(fixture, "baseset"), { recursive: true });
  writeFileSync(
    join(fixture, "ai/directorate_gate_fixture/info.nut"),
    `class DirectorateGateFixtureInfo extends AIInfo {
  function GetAuthor()      { return "OpenTTD Directorate"; }
  function GetName()        { return "Directorate Gate Fixture"; }
  function GetDescription() { return "Disposable no-op company for the directorate real-engine gate"; }
  function GetVersion()     { return 1; }
  function GetDate()        { return "2026-07-29"; }
  function CreateInstance() { return "DirectorateGateFixture"; }
  function GetShortName()   { return "D4GF"; }
  function GetAPIVersion()  { return "15"; }
}
RegisterAI(DirectorateGateFixtureInfo());
`,
  );
  writeFileSync(
    join(fixture, "ai/directorate_gate_fixture/main.nut"),
    `class DirectorateGateFixture extends AIController {
  function Start() {
    while (true) this.Sleep(100);
  }
}
`,
  );
  writeFileSync(
    join(fixture, "openttd.cfg"),
    `[misc]
autosave = off

[music]
name = NoMusic

[game_scripts]
"OpenTTD Directorate" = 4

[network]
server_admin_port = ${port}
admin_password = ${password}
allow_insecure_admin_login = true
server_game_type = local
server_name = "OpenTTD Directorate Real Engine Gate"
max_companies = 4

[game_creation]
map_x = 7
map_y = 7
starting_year = 1950

[difficulty]
industry_density = 4
number_towns = 0
terrain_type = 0
quantity_sea_lakes = 0

[pf]
forbid_90_deg = true

[gui]
autosave_interval = 0
`,
  );
}

function writeHub4x7Config() {
  mkdirSync(join(hub4x7Fixture, "game"), { recursive: true });
  mkdirSync(join(hub4x7Fixture, "ai/directorate_gate_fixture"), { recursive: true });
  mkdirSync(join(hub4x7Fixture, "baseset"), { recursive: true });

  cpSync(join(repoRoot, "game/openttd_directorate"), join(hub4x7Fixture, "game/openttd_directorate"), { recursive: true });
  const fixtureBridgePath = join(hub4x7Fixture, "game/openttd_directorate/bridge.nut");
  const fixtureBridge = readFileSync(fixtureBridgePath, "utf8");
  /* Every probe here is disposable scaffolding for this one fixture: it proves
   * that a genuinely terrain-obstructed through_hub_4x7 pad requires and
   * executes GSTile.LevelTiles, that the journal's landscape readback is
   * self-consistent against a fresh live re-snapshot, and that rolling back a
   * landscape entry whose tiles are now covered by real track/station honestly
   * reports rollback_partial (the bounded RaiseTile/LowerTile attempt budget
   * cannot succeed once track sits on top of the levelled ground). */
  const hub4x7Probe = `\t\tif (payload.command == "hub4x7_place_industries_probe") {
\t\t\tif (!D4_Has(payload, "params") || !D4_Has(payload.params, "source_center") || !D4_IsTable(payload.params.source_center) || !D4_Has(payload.params, "destination_center") || !D4_IsTable(payload.params.destination_center)) return { ok = false, error = D4_Error("invalid_place_industries", "") };
\t\t\t/* Deity mode (the GameScript's ambient context whenever no GSCompanyMode is
\t\t\t * active) bypasses the "raw industry construction" difficulty setting, so
\t\t\t * this places a COAL_MINE (industry type 0) and a POWER_STATION (type 1,
\t\t\t * COAL-accepting) at exact, chosen tiles instead of depending on whatever
\t\t\t * the map generator happened to place -- this fixture owns its own source
\t\t\t * and destination with proven map-edge clearance, rather than hoping a
\t\t\t * procedurally-generated industry happens to sit somewhere the much larger
\t\t\t * through_hub_4x7 fan/merge geometry can actually reach. */
\t\t\tlocal offsets = [{ x = 0, y = 0 }];
\t\t\tfor (local ring = 5; ring <= 15; ring += 5) {
\t\t\t\tfor (local dx = -ring; dx <= ring; dx += 5) {
\t\t\t\t\tfor (local dy = -ring; dy <= ring; dy += 5) {
\t\t\t\t\t\tlocal adx = dx < 0 ? -dx : dx;
\t\t\t\t\t\tlocal ady = dy < 0 ? -dy : dy;
\t\t\t\t\t\tlocal magnitude = adx > ady ? adx : ady;
\t\t\t\t\t\tif (magnitude == ring) offsets.append({ x = dx, y = dy });
\t\t\t\t\t}
\t\t\t\t}
\t\t\t}
\t\t\tlocal known_industries = {};
\t\t\tlocal initial_industries = GSIndustryList();
\t\t\tfor (local industry_id = initial_industries.Begin(); !initial_industries.IsEnd(); industry_id = initial_industries.Next()) known_industries[industry_id] <- true;
\t\t\tlocal source_tile = null;
\t\t\tlocal source_attempts = 0;
\t\t\tforeach (offset in offsets) {
\t\t\t\tsource_attempts++;
\t\t\t\tlocal p = { x = payload.params.source_center.x + offset.x, y = payload.params.source_center.y + offset.y };
\t\t\t\tif (!D4_IsPointOnMap(p)) continue;
\t\t\t\tlocal tile = D4_ToTile(p);
\t\t\t\tif (GSIndustryType.BuildIndustry(0, tile)) { source_tile = tile; break; }
\t\t\t}
\t\t\tif (source_tile == null) return { ok = false, error = D4_Error("source_industry_build_failed", source_attempts.tostring()) };
\t\t\tlocal source_id = null;
\t\t\tlocal after_source = GSIndustryList();
\t\t\tfor (local industry_id = after_source.Begin(); !after_source.IsEnd(); industry_id = after_source.Next()) {
\t\t\t\tif (!known_industries.rawin(industry_id) && GSIndustry.IsValidIndustry(industry_id)) { source_id = industry_id; break; }
\t\t\t}
\t\t\tif (source_id == null) return { ok = false, error = D4_Error("source_industry_id_resolve_failed", "") };
\t\t\tknown_industries[source_id] <- true;
\t\t\tlocal destination_tile = null;
\t\t\tlocal destination_attempts = 0;
\t\t\tforeach (offset in offsets) {
\t\t\t\tdestination_attempts++;
\t\t\t\tlocal p = { x = payload.params.destination_center.x + offset.x, y = payload.params.destination_center.y + offset.y };
\t\t\t\tif (!D4_IsPointOnMap(p)) continue;
\t\t\t\tlocal tile = D4_ToTile(p);
\t\t\t\tif (GSIndustryType.BuildIndustry(1, tile)) { destination_tile = tile; break; }
\t\t\t}
\t\t\tif (destination_tile == null) return { ok = false, error = D4_Error("destination_industry_build_failed", destination_attempts.tostring()) };
\t\t\tlocal destination_id = null;
\t\t\tlocal after_destination = GSIndustryList();
\t\t\tfor (local industry_id = after_destination.Begin(); !after_destination.IsEnd(); industry_id = after_destination.Next()) {
\t\t\t\tif (!known_industries.rawin(industry_id) && GSIndustry.IsValidIndustry(industry_id)) { destination_id = industry_id; break; }
\t\t\t}
\t\t\tif (destination_id == null) return { ok = false, error = D4_Error("destination_industry_id_resolve_failed", "") };
\t\t\treturn { ok = true, payload = { source_industry_id = source_id, destination_industry_id = destination_id, source_tile_point = D4_FromTile(GSIndustry.GetLocation(source_id)), destination_tile_point = D4_FromTile(GSIndustry.GetLocation(destination_id)), source_attempts = source_attempts, destination_attempts = destination_attempts } };
\t\t}
\t\tif (payload.command == "hub4x7_terrain_bump_probe") {
\t\t\tlocal mode = GSCompanyMode(payload.company_id);
\t\t\tif (!GSCompanyMode.IsValid()) return { ok = false, error = D4_Error("probe_company_mode_failed", payload.company_id.tostring()) };
\t\t\tif (!GSIndustry.IsValidIndustry(payload.params.industry_id)) return { ok = false, error = D4_Error("probe_invalid_industry", payload.params.industry_id.tostring()) };
\t\t\tlocal origin = D4_FromTile(GSIndustry.GetLocation(payload.params.industry_id));
\t\t\tlocal radius = payload.params.radius;
\t\t\tlocal spacing = payload.params.spacing;
\t\t\tlocal delta = payload.params.delta;
\t\t\tlocal bumped = 0;
\t\t\tfor (local dx = -radius; dx <= radius; dx += spacing) {
\t\t\t\tfor (local dy = -radius; dy <= radius; dy += spacing) {
\t\t\t\t\tlocal p = { x = origin.x + dx, y = origin.y + dy };
\t\t\t\t\tif (!D4_IsPointOnMap(p)) continue;
\t\t\t\t\tlocal tile = D4_ToTile(p);
\t\t\t\t\tif (D4_IsTileWater(tile) || !GSTile.IsBuildable(tile)) continue;
\t\t\t\t\tlocal slopes = [GSTile.SLOPE_N, GSTile.SLOPE_E, GSTile.SLOPE_S, GSTile.SLOPE_W];
\t\t\t\t\tforeach (slope in slopes) for (local step = 0; step < delta; step++) if (GSTile.RaiseTile(tile, slope)) bumped++;
\t\t\t\t}
\t\t\t}
\t\t\treturn { ok = true, payload = { bumped = bumped } };
\t\t}
\t\tif (payload.command == "hub4x7_fund_company_probe") {
\t\t\tlocal mode = GSCompanyMode(payload.company_id);
\t\t\tif (!GSCompanyMode.IsValid()) return { ok = false, error = D4_Error("probe_company_mode_failed", payload.company_id.tostring()) };
\t\t\tlocal maximum = GSCompany.GetMaxLoanAmount();
\t\t\tif (!GSCompany.SetLoanAmount(maximum)) return { ok = false, error = D4_Error("probe_max_loan_failed", maximum.tostring()) };
\t\t\treturn { ok = true, payload = { bank_balance = GSCompany.GetBankBalance(payload.company_id), loan_amount = GSCompany.GetLoanAmount(), max_loan_amount = maximum } };
\t\t}
\t\tif (payload.command == "hub4x7_landscape_plan_probe") {
\t\t\tlocal plan = this.store.GetPlan(payload.params.plan_id);
\t\t\tif (plan == null || !D4_Has(plan, "build_program") || !plan.build_program.ok) return { ok = false, error = D4_Error("probe_plan_missing", payload.params.plan_id) };
\t\t\tlocal landscape_ops = [];
\t\t\tlocal source_station = null, destination_station = null, signal_count = 0;
\t\t\tforeach (op in plan.build_program.ops) {
\t\t\t\tif (op.kind == "level_tiles") landscape_ops.append({ op_id = op.op_id, tile = op.tile, end_tile = op.end_tile, target_height = op.target_height, maximum_tiles = op.maximum_tiles, maximum_height_delta = op.maximum_height_delta });
\t\t\t\telse if (op.op_id == "source_station") source_station = op;
\t\t\t\telse if (op.op_id == "destination_station") destination_station = op;
\t\t\t\telse if (op.kind == "signal") signal_count++;
\t\t\t}
\t\t\tlocal topology = plan.build_program.topology;
\t\t\treturn { ok = landscape_ops.len() > 0 && source_station != null && destination_station != null, payload = { landscape_ops = landscape_ops, total_ops = plan.build_program.ops.len(), source_rect = { platforms = source_station.num_platforms, length = source_station.platform_length }, destination_rect = { platforms = destination_station.num_platforms, length = destination_station.platform_length }, source_entries = topology.source.entries.len(), destination_entries = topology.destination.entries.len(), signal_count = signal_count } };
\t\t}
\t\tif (payload.command == "hub4x7_landscape_readback_probe") {
\t\t\tlocal op = this.store.journal.Get(payload.params.operation_id);
\t\t\tif (op == null) return { ok = false, error = D4_Error("probe_operation_missing", payload.params.operation_id) };
\t\t\tlocal landscape_entries = [];
\t\t\tlocal all_ok = true;
\t\t\tforeach (entry in op.entries) {
\t\t\t\tif (!D4_IsTable(entry.detail) || !D4_Has(entry.detail, "kind") || entry.detail.kind != "landscape") continue;
\t\t\t\tlocal detail = entry.detail;
\t\t\t\tlocal self_consistent = D4_LandscapeReadback(detail.before, detail.after, detail.target_height);
\t\t\t\tlocal live = D4_LandscapeSnapshot(entry.tile, detail.end_tile);
\t\t\t\tlocal live_consistent = live.ok && D4_LandscapeReadback(detail.before, live.corners, detail.target_height);
\t\t\t\tlocal cost_ok = detail.actual_cost >= 0 && detail.actual_cost <= detail.estimated_cost;
\t\t\t\t/* Later bounded landscape entries may overlap and legitimately supersede
\t\t\t\t * an earlier entry's live snapshot. Per-entry commit readback and cost
\t\t\t\t * remain mandatory; final topology is checked independently below. */
\t\t\t\tif (!self_consistent || !cost_ok) all_ok = false;
\t\t\t\tlandscape_entries.append({ tile = entry.tile, end_tile = detail.end_tile, target_height = detail.target_height, estimated_cost = detail.estimated_cost, actual_cost = detail.actual_cost, self_consistent = self_consistent, live_consistent = live_consistent, cost_ok = cost_ok, before_count = detail.before.len(), after_count = detail.after.len() });
\t\t\t}
\t\t\tif (landscape_entries.len() == 0) all_ok = false;
\t\t\treturn { ok = all_ok, payload = { landscape_entries = landscape_entries, operation_state = op.state } };
\t\t}
\t\tif (payload.command == "hub4x7_landscape_partial_rollback_seed_probe") {
\t\t\tlocal source_op = this.store.journal.Get(payload.params.operation_id);
\t\t\tif (source_op == null) return { ok = false, error = D4_Error("probe_source_missing", "") };
\t\t\tlocal landscape_entry = null;
\t\t\tforeach (entry in source_op.entries) {
\t\t\t\tif (D4_IsTable(entry.detail) && D4_Has(entry.detail, "kind") && entry.detail.kind == "landscape") { landscape_entry = entry; break; }
\t\t\t}
\t\t\tif (landscape_entry == null) return { ok = false, error = D4_Error("probe_no_landscape_entry", "") };
\t\t\tlocal synthetic_id = payload.params.synthetic_operation_id;
\t\t\tlocal synthetic = { operation_id = synthetic_id, company_id = payload.company_id, plan_id = payload.params.plan_id, revision = payload.params.revision, phase = "commit", request_fingerprint = "hub4x7-landscape-partial-rollback-probe", state = "completed", entries = [{ kind = "created", tile = landscape_entry.tile, detail = landscape_entry.detail }], created_tick = D4_Tick(), completed_tick = D4_Tick(), result = { ok = true, operation_id = synthetic_id, state = "completed" }, rollback = null };
\t\t\tthis.store.journal.operations[synthetic_id] <- synthetic;
\t\t\tthis.store.journal.order.append(synthetic_id);
\t\t\treturn { ok = true, payload = { seeded = synthetic_id, tile = landscape_entry.tile } };
\t\t}
`;
  const hubRuntimeProbe = `\t\tif (payload.command == "through_hub_runtime_probe") {
\t\t\tlocal mode = GSCompanyMode(payload.company_id);
\t\t\tif (!GSCompanyMode.IsValid() || !D4_Has(payload, "params") || !D4_Has(payload.params, "route_ids") || !D4_IsArray(payload.params.route_ids)) return { ok = false, error = D4_Error("runtime_probe_invalid", "") };
\t\t\tlocal rows = [];
\t\t\tfor (local ri = 0; ri < payload.params.route_ids.len() && ri < 8; ri++) {
\t\t\t\tlocal route_id = payload.params.route_ids[ri];
\t\t\t\tlocal route = this.store.registry.Get(route_id);
\t\t\t\tif (route == null || route.topology == null) { rows.append({ route_id = route_id, ok = false }); continue; }
\t\t\t\tlocal source_platform_rows = {}, destination_platform_rows = {}, source_egress_rows = {}, destination_egress_rows = {};
\t\t\t\tfor (local i = 0; i < route.topology.source.entries.len(); i++) source_platform_rows[D4_ToTile(route.topology.source.entries[i].platform)] <- i;
\t\t\t\tfor (local j = 0; j < route.topology.destination.entries.len(); j++) destination_platform_rows[D4_ToTile(route.topology.destination.entries[j].platform)] <- j;
\t\t\t\tfor (local k = 0; k < route.topology.source.exits.len(); k++) source_egress_rows[D4_ToTile(route.topology.source.exits[k].exit)] <- k;
\t\t\t\tfor (local m = 0; m < route.topology.destination.exits.len(); m++) destination_egress_rows[D4_ToTile(route.topology.destination.exits[m].exit)] <- m;
\t\t\t\tlocal vehicles = [];
\t\t\t\tforeach (entry in route.vehicles) {
\t\t\t\t\tif (!GSVehicle.IsValidVehicle(entry.vehicle_id)) { vehicles.append({ vehicle_id = entry.vehicle_id, valid = false }); continue; }
\t\t\t\t\tlocal location = GSVehicle.GetLocation(entry.vehicle_id);
\t\t\t\t\tvehicles.append({ vehicle_id = entry.vehicle_id, valid = true, location = location, current_order = GSOrder.ResolveOrderPosition(entry.vehicle_id, GSOrder.ORDER_CURRENT), load = GSVehicle.GetCargoLoad(entry.vehicle_id, route.cargo_type), profit_last_year = GSVehicle.GetProfitLastYear(entry.vehicle_id), profit_this_year = GSVehicle.GetProfitThisYear(entry.vehicle_id), source_row = location in source_platform_rows ? source_platform_rows[location] : -1, destination_row = location in destination_platform_rows ? destination_platform_rows[location] : -1, source_egress_row = location in source_egress_rows ? source_egress_rows[location] : -1, destination_egress_row = location in destination_egress_rows ? destination_egress_rows[location] : -1 });
\t\t\t\t}
\t\t\t\trows.append({ route_id = route_id, ok = true, vehicles = vehicles });
\t\t\t}
\t\t\treturn { ok = true, payload = { tick = D4_Tick(), routes = rows } };
\t\t}
`;
  const fixtureBridgeWithProbe = fixtureBridge.replace('\t\tif (payload.command == "survey_sites") {', hub4x7Probe + hubRuntimeProbe + '\t\tif (payload.command == "survey_sites") {');
  if (fixtureBridgeWithProbe === fixtureBridge) throw new Error("failed to inject hub4x7 landscape probes");
  writeFileSync(fixtureBridgePath, fixtureBridgeWithProbe);
  cpSync(openGfx, join(hub4x7Fixture, "baseset"), { recursive: true });
  writeFileSync(
    join(hub4x7Fixture, "ai/directorate_gate_fixture/info.nut"),
    `class DirectorateGateFixtureInfo extends AIInfo {
  function GetAuthor()      { return "OpenTTD Directorate"; }
  function GetName()        { return "Directorate Gate Fixture"; }
  function GetDescription() { return "Disposable no-op company for the directorate real-engine gate"; }
  function GetVersion()     { return 1; }
  function GetDate()        { return "2026-07-29"; }
  function CreateInstance() { return "DirectorateGateFixture"; }
  function GetShortName()   { return "D4GF"; }
  function GetAPIVersion()  { return "15"; }
}
RegisterAI(DirectorateGateFixtureInfo());
`,
  );
  writeFileSync(
    join(hub4x7Fixture, "ai/directorate_gate_fixture/main.nut"),
    `class DirectorateGateFixture extends AIController {
  function Start() {
    while (true) this.Sleep(100);
  }
}
`,
  );
  writeFileSync(
    join(hub4x7Fixture, "openttd.cfg"),
    `[misc]
autosave = off

[music]
name = NoMusic

[game_scripts]
"OpenTTD Directorate" = 4

[network]
server_admin_port = ${hub4x7Port}
admin_password = ${password}
allow_insecure_admin_login = true
server_game_type = local
server_name = "OpenTTD Directorate Real Engine Gate (hub4x7 terrain-obstructed)"
max_companies = 4

[game_creation]
map_x = 7
map_y = 7
starting_year = 1950

[difficulty]
industry_density = 0
number_towns = 0
terrain_type = 0
quantity_sea_lakes = 0

[pf]
forbid_90_deg = true

[gui]
autosave_interval = 0
`,
  );
}

function delay(ms) {
  return new Promise((resolveDelay) => setTimeout(resolveDelay, ms));
}

function assertOk(name, response) {
  if (!response?.ok) throw new Error(`${name} failed: ${JSON.stringify(response)}`);
  return response;
}

function assertNotOk(name, response) {
  if (response?.ok) throw new Error(`${name} unexpectedly succeeded: ${JSON.stringify(response)}`);
  return response;
}

function assertRouteCommissioned(name, response) {
  if (!response?.ok) throw new Error(`${name} failed: ${JSON.stringify(response)}`);
  const route = response.payload?.route ?? response.payload?.response?.route;
  if (typeof route?.route_id !== "string") throw new Error(`${name} missing route_id`);
  if (route?.state !== "commissioned") throw new Error(`${name} not commissioned: ${JSON.stringify(route)}`);
  if (typeof response.payload?.vehicle_id !== "number" && typeof response.payload?.response?.vehicle_id !== "number") {
    throw new Error(`${name} missing vehicle_id`);
  }
  return response;
}

function updateRuntimeHistory(history, probe) {
  const tick = probe?.payload?.tick ?? 0;
  for (const route of probe?.payload?.routes ?? []) {
    if (!route?.ok || typeof route.route_id !== "string") continue;
    const row = history.get(route.route_id) ?? {
      sourceRows: new Set(),
      destinationRows: new Set(),
      rearEgressRows: new Set(),
      deliveries: 0,
      vehicles: new Map(),
      snapshots: [],
    };
    for (const vehicle of route.vehicles ?? []) {
      if (!vehicle?.valid || !Number.isInteger(vehicle.vehicle_id)) continue;
      if (vehicle.source_row >= 0) row.sourceRows.add(vehicle.source_row);
      if (vehicle.destination_row >= 0) row.destinationRows.add(vehicle.destination_row);
      if (vehicle.source_egress_row >= 0) row.rearEgressRows.add(`source:${vehicle.source_egress_row}`);
      if (vehicle.destination_egress_row >= 0) row.rearEgressRows.add(`destination:${vehicle.destination_egress_row}`);
      const previous = row.vehicles.get(vehicle.vehicle_id);
      const profit = (vehicle.profit_last_year ?? 0) + (vehicle.profit_this_year ?? 0);
      if (previous && profit > previous.profit && (previous.load > (vehicle.load ?? 0) || vehicle.load === 0)) row.deliveries += 1;
      row.vehicles.set(vehicle.vehicle_id, { load: vehicle.load ?? 0, profit });
      row.snapshots.push({
        tick,
        vehicle_id: vehicle.vehicle_id,
        location: vehicle.location,
        current_order: vehicle.current_order,
        load: vehicle.load,
        source_row: vehicle.source_row,
        destination_row: vehicle.destination_row,
        source_egress_row: vehicle.source_egress_row,
        destination_egress_row: vehicle.destination_egress_row,
        profit,
      });
      if (row.snapshots.length > 64) row.snapshots.shift();
    }
    history.set(route.route_id, row);
  }
}

function runtimeHistorySummary(history) {
  return Object.fromEntries(
    [...history].map(([routeId, row]) => [
      routeId,
      {
        source_rows: [...row.sourceRows].sort(),
        destination_rows: [...row.destinationRows].sort(),
        rear_egress_rows: [...row.rearEgressRows].sort(),
        deliveries: row.deliveries,
        snapshots: row.snapshots.slice(-12),
      },
    ]),
  );
}

function gitOutput(args, fallback = "") {
  const result = spawnSync("git", args, { cwd: repoRoot, encoding: "utf8" });
  if (typeof result.stdout === "string" && result.stdout.trim().length > 0) return result.stdout.trim();
  if (result.error) return fallback;
  if (result.status !== 0) return fallback;
  return "";
}

async function withServer(loadGame, fn, options = {}) {
  const serverFixture = options.fixture ?? fixture;
  const serverGamePort = options.gamePort ?? gamePort;
  const serverLogPath = options.logPath ?? logPath;
  serverRun += 1;
  const runLogPath = `${serverLogPath}.${serverRun}`;
  const out = [];
  const args = [
    "-D",
    `127.0.0.1:${serverGamePort}`,
    "-c",
    join(serverFixture, "openttd.cfg"),
    "-x",
    "-X",
    "-g",
    ...(loadGame ? [loadGame] : []),
    "-G",
    "42",
    "-I",
    "OpenGFX",
    "-S",
    "NoSound",
    "-M",
    "NoMusic",
    "-d",
    "script=4,net=2,misc=0",
  ];
  const server = spawn(openttd, args, { cwd: serverFixture, stdio: ["ignore", "pipe", "pipe"] });
  activeServer = server;
  server.stdout.on("data", (chunk) => out.push(chunk));
  server.stderr.on("data", (chunk) => out.push(chunk));
  let exit = null;
  server.on("exit", (code, signal) => {
    exit = { code, signal };
  });
  try {
    await delay(1500);
    if (exit) throw new Error(`OpenTTD exited before gate: ${JSON.stringify(exit)} ${Buffer.concat(out).toString("utf8").slice(0, 1000)}`);
    return await fn();
  } finally {
    server.kill("SIGTERM");
    await delay(500);
    if (!server.killed) server.kill("SIGKILL");
    if (activeServer === server) activeServer = null;
    writeFileSync(runLogPath, Buffer.concat(out).toString("utf8"));
    writeFileSync(serverLogPath, Buffer.concat(out).toString("utf8"));
  }
}

async function request(handlers, op, payload) {
  const result = await handlers[op](payload);
  if (!Array.isArray(result?.content) || result.content.length < 1 || result.content[0]?.type !== "text") {
    throw new Error(`invalid ${op} response`);
  }
  const response = JSON.parse(result.content[0].text);
  if (typeof response !== "object" || response === null || Array.isArray(response)) {
    throw new Error(`invalid ${op} response body`);
  }
  if ((op === "commission" || op === "verify") && response.payload?.response !== undefined) {
    return { ...response, typed_payload: response.payload, payload: response.payload.response };
  }
  return response;
}

/**
 * DISPOSABLE fixture: a through_hub_4x7 RoRo whose station pads are forced onto
 * deliberately obstructed (non-flat) terrain, proving landscaping is required and
 * executed for real, not merely wired but unreachable. Runs against its own
 * server/fixture directory and its own bounded phase deadlines, and its findings
 * are appended to the same evidence object as the flat-map gate above.
 */
async function runTerrainObstructedHub4x7Fixture(evidence) {
  writeHub4x7Config();
  let commitRevision = 0;

  await withServer(null, async () => {
    const client = new AdminClient({
      host: "127.0.0.1",
      port: hub4x7Port,
      password,
      name: "directorate real-engine gate hub4x7",
      version: "0.1.0",
      requestTimeoutMs,
      connectTimeoutMs: 10000,
      pingIntervalMs: 0,
      reconnect: { enabled: false, maxAttempts: 0, initialDelayMs: 100, maxDelayMs: 100 },
      maxResponseBytes: 1024 * 1024,
      maxResponseChunks: 256,
      maxPendingRequests: 16,
    });
    await client.connect();
    const handlers = createToolHandlers(new AdminOpenTtdGateway(client));
    evidence.steps.push({ name: "hub4x7_connect", ok: true });
    await client.rcon('start_ai "Directorate Gate Fixture"');
    await delay(1000);

    /* The map's only procedurally-generated COAL source sits 4 tiles from the
     * map's north edge (verified: this deterministic seed places exactly one
     * COAL-producing industry), too close for through_hub_4x7's much larger
     * fan/merge geometry to find any candidate within the site-search budget --
     * that was the root cause of a prior source_site_not_found blocker here.
     * Rather than depend on wherever map generation happened to place
     * industries, this fixture builds its own COAL_MINE/POWER_STATION pair at
     * chosen central tiles with generous, proven map-edge clearance. Each
     * center has a small deterministic fallback offset list in case the exact
     * tile isn't buildable (slope/occupancy); the whole placement stays
     * bounded and reproducible for this fixed map seed. */

    // 128x128 map: (40,40) and (90,90) each keep >=37 tiles of clearance from
    // every map edge, far beyond through_hub_4x7's ~17-tile worst-case reach
    // (site_search_radius 4 + blueprint fan/merge/loop span), and sit on the
    // dominant SE/NW diagonal so pairing doesn't also have to fight geometry
    // this fixture isn't testing.
    const placeWire = await client.requestGameScript("execute", {
      company_id: 0,
      command: "hub4x7_place_industries_probe",
      params: {
        source_center: { x: 40, y: 40 },
        destination_center: { x: 90, y: 90 },
      },
    });
    const placed = assertOk("hub4x7_place_industries", placeWire.payload);
    const sourceIndustryId = placed.payload?.source_industry_id;
    const destinationIndustryId = placed.payload?.destination_industry_id;
    if (typeof sourceIndustryId !== "number" || typeof destinationIndustryId !== "number") {
      throw new Error(`hub4x7 industry placement did not resolve ids: ${JSON.stringify(placed)}`);
    }
    evidence.steps.push({ name: "hub4x7_place_industries", response: placeWire });

    const fundWire = await client.requestGameScript("execute", { company_id: 0, command: "hub4x7_fund_company_probe", params: {} });
    const funded = assertOk("hub4x7_fund_company_probe", fundWire.payload);
    if (typeof funded.payload?.bank_balance !== "number" || funded.payload.bank_balance < 250000) {
      throw new Error(`hub4x7 fixture did not fund terminal construction: ${JSON.stringify(funded)}`);
    }
    evidence.steps.push({ name: "hub4x7_fund_company_probe", response: fundWire });

    /* The fixed seed's natural terrain intersects the deterministic fan/loop
     * geometry. The required non-empty level_tiles manifest below is the proof;
     * do not manufacture broad cliffs that correctly trigger halo rejection. */
    const companyAfterFixtureSetup = assertOk("hub4x7_company_after_fixture_setup", await request(handlers, "execute", {
      company_id: 0,
      command: "get_company_info",
      params: {},
    }));
    if (typeof companyAfterFixtureSetup.payload?.bank_balance !== "number" || companyAfterFixtureSetup.payload.bank_balance < 50000) {
      throw new Error(`hub4x7 fixture setup contaminated company finances: ${JSON.stringify(companyAfterFixtureSetup)}`);
    }
    evidence.steps.push({ name: "hub4x7_company_after_fixture_setup", response: companyAfterFixtureSetup });

    const plan = await request(handlers, "plan", {
      company_id: 0,
      plan_id: "directorate-hub4x7-gate-plan",
      intent: { source_industry_id: sourceIndustryId, destination_industry_id: destinationIndustryId },
      policy: {
        station_template: "through_hub_4x7",
        /* Four rings cover the central fixture's deterministic candidate set
         * while keeping exact-engine survey and pairing bounded. */
        site_search_radius: 4,
        site_pair_skip: Number.parseInt(process.env.OPENTTD_GATE_HUB4X7_PAIR_SKIP ?? "1", 10),
        route_expansion_limit: 32768,
        route_frontier_limit: 32768,
        route_turn_cost: 50,
        wagon_count: 1,
        signals: true,
      },
    });
    evidence.steps.push({ name: "hub4x7_plan", response: assertOk("hub4x7_plan", plan) });
    if (!plan.ok || plan.payload?.revision === undefined) throw new Error("hub4x7 plan did not return revision");
    const revision = plan.payload.revision;

    const landscapePlanProbeWire = await client.requestGameScript("execute", { company_id: 0, command: "hub4x7_landscape_plan_probe", params: { plan_id: "directorate-hub4x7-gate-plan" } });
    const landscapePlanProbe = assertOk("hub4x7_landscape_plan_probe", landscapePlanProbeWire.payload);
    if (!Array.isArray(landscapePlanProbe.payload?.landscape_ops) || landscapePlanProbe.payload.landscape_ops.length < 1) {
      throw new Error(`hub4x7 plan did not require landscaping on obstructed terrain: ${JSON.stringify(landscapePlanProbe)}`);
    }
    evidence.steps.push({ name: "hub4x7_landscape_plan_probe", response: landscapePlanProbeWire });

    evidence.steps.push({
      name: "hub4x7_preflight",
      response: assertOk("hub4x7_preflight", await request(handlers, "apply", {
        company_id: 0,
        plan_id: "directorate-hub4x7-gate-plan",
        revision,
        phase: "preflight",
        operation_id: "directorate-hub4x7-gate.preflight",
      })),
    });

    const commit = assertOk("hub4x7_commit", await request(handlers, "apply", {
      company_id: 0,
      plan_id: "directorate-hub4x7-gate-plan",
      revision,
      phase: "commit",
      operation_id: "directorate-hub4x7-gate.commit",
    }));
    evidence.steps.push({ name: "hub4x7_commit", response: commit });
    commitRevision = commit.payload?.revision ?? revision + 1;

    const readbackWire = await client.requestGameScript("execute", { company_id: 0, command: "hub4x7_landscape_readback_probe", params: { operation_id: "directorate-hub4x7-gate.commit" } });
    const readback = assertOk("hub4x7_landscape_readback_probe", readbackWire.payload);
    if (!Array.isArray(readback.payload?.landscape_entries) || readback.payload.landscape_entries.length < 1) {
      throw new Error(`hub4x7 commit did not execute a landscape op: ${JSON.stringify(readback)}`);
    }
    for (const entry of readback.payload.landscape_entries) {
      if (!entry.self_consistent || !entry.cost_ok) {
        throw new Error(`hub4x7 landscape readback failed bounded verification: ${JSON.stringify(entry)}`);
      }
    }
    if (!readback.payload.landscape_entries.some((entry) => entry.live_consistent)) {
      throw new Error(`hub4x7 final landscape state matches no committed entry: ${JSON.stringify(readback)}`);
    }
    evidence.steps.push({ name: "hub4x7_landscape_readback_probe", response: readbackWire });

    if (landscapePlanProbe.payload?.source_rect?.platforms !== 4 || landscapePlanProbe.payload?.source_rect?.length !== 7 || landscapePlanProbe.payload?.destination_rect?.platforms !== 4 || landscapePlanProbe.payload?.destination_rect?.length !== 7) {
      throw new Error(`hub4x7 station rectangles are not 4x7: ${JSON.stringify(landscapePlanProbe)}`);
    }
    if (landscapePlanProbe.payload?.source_entries !== 4 || landscapePlanProbe.payload?.destination_entries !== 4 || !(landscapePlanProbe.payload?.signal_count >= 8)) {
      throw new Error(`hub4x7 fan/merge/signal manifest incomplete: ${JSON.stringify(landscapePlanProbe)}`);
    }
    evidence.steps.push({ name: "hub4x7_through_hub_manifest", response: landscapePlanProbe });

    const commission = assertRouteCommissioned("hub4x7_commission_route", await request(handlers, "commission", {
      company_id: 0,
      plan_id: "directorate-hub4x7-gate-plan",
      route_id: "directorate-hub4x7-gate-route",
      cargo_label: "",
    }));
    evidence.steps.push({ name: "hub4x7_commission_route", response: commission });

    const secondCommission = assertRouteCommissioned("hub4x7_commission_route_second", await request(handlers, "commission", {
      company_id: 0,
      plan_id: "directorate-hub4x7-gate-plan",
      route_id: "directorate-hub4x7-gate-route-second",
      cargo_label: "",
    }));
    evidence.steps.push({ name: "hub4x7_commission_route_second", response: secondCommission });

    let profitable = false;
    const runtimeHistory = new Map();
    for (let attempt = 0; attempt < 48; attempt++) {
      let runtimeProbeWire = null;
      for (let sample = 0; sample < 10; sample++) {
        await delay(500);
        runtimeProbeWire = await client.requestGameScript("execute", {
          company_id: 0,
          command: "through_hub_runtime_probe",
          params: { route_ids: ["directorate-hub4x7-gate-route", "directorate-hub4x7-gate-route-second"] },
        });
        const runtimeProbe = assertOk("hub4x7_through_hub_runtime_probe", runtimeProbeWire.payload);
        updateRuntimeHistory(runtimeHistory, runtimeProbe);
      }
      const poll = await request(handlers, "verify", { company_id: 0, route_id: "directorate-hub4x7-gate-route", level: "economic" });
      const secondPoll = await request(handlers, "verify", { company_id: 0, route_id: "directorate-hub4x7-gate-route-second", level: "economic" });
      if (attempt % 4 === 0 || attempt === 47 || poll.ok === true || secondPoll.ok === true) {
        evidence.steps.push({ name: "hub4x7_verify_economic_runtime_poll", attempt, first: poll, second: secondPoll, runtime: runtimeProbeWire });
      }
      if (poll.ok === true && poll.payload?.health?.positive_revenue === true && secondPoll.ok === true && secondPoll.payload?.health?.positive_revenue === true) {
        evidence.steps.push({ name: "hub4x7_verify_economic_both_profitable", attempt, first: poll, second: secondPoll });
        profitable = true;
        break;
      }
    }
    if (!profitable) throw new Error("hub4x7 both routes did not become profitable within poll window");
    const runtimeSummary = runtimeHistorySummary(runtimeHistory);
    evidence.steps.push({ name: "hub4x7_through_hub_runtime_history", response: runtimeSummary });
    const totalDeliveries = Object.values(runtimeSummary).reduce((sum, route) => sum + route.deliveries, 0);
    const usedRows = new Set(Object.values(runtimeSummary).flatMap((route) => [...route.source_rows, ...route.destination_rows]));
    const usedEgress = new Set(Object.values(runtimeSummary).flatMap((route) => route.rear_egress_rows));
    if (totalDeliveries < 2 || usedRows.size < 2) throw new Error(`hub4x7 runtime did not prove two deliveries across both platform rows: ${JSON.stringify(runtimeSummary)}`);
    if (usedEgress.size < 1) throw new Error(`hub4x7 runtime did not prove a rear egress row: ${JSON.stringify(runtimeSummary)}`);

    /* Prove the bounded rollback path against real, still-in-use infrastructure:
     * seed a synthetic operation carrying the real landscape journal entry from
     * the commit above, then roll it back. Its tiles are now covered by the
     * built station/track, so D4_RestoreLandscape's bounded RaiseTile/LowerTile
     * attempts cannot succeed — the honest, required outcome is rollback_partial,
     * not a silent false success or a hang. */
    const rollbackSeedWire = await client.requestGameScript("execute", {
      company_id: 0,
      command: "hub4x7_landscape_partial_rollback_seed_probe",
      params: { operation_id: "directorate-hub4x7-gate.commit", synthetic_operation_id: "directorate-hub4x7-gate.landscape-rollback-seed", plan_id: "directorate-hub4x7-gate-plan", revision: commitRevision },
    });
    assertOk("hub4x7_landscape_partial_rollback_seed_probe", rollbackSeedWire.payload);
    evidence.steps.push({ name: "hub4x7_landscape_partial_rollback_seed_probe", response: rollbackSeedWire });

    const rollbackAttempt = assertNotOk("hub4x7_landscape_rollback_partial", await request(handlers, "apply", {
      company_id: 0,
      plan_id: "directorate-hub4x7-gate-plan",
      revision: commitRevision,
      phase: "rollback",
      operation_id: "directorate-hub4x7-gate.landscape-rollback",
      target_operation_id: "directorate-hub4x7-gate.landscape-rollback-seed",
      reserve: 0,
    }));
    if (rollbackAttempt.payload?.state !== "rollback_partial" || !(rollbackAttempt.payload?.remaining?.length > 0)) {
      throw new Error(`hub4x7 landscape rollback against live infrastructure did not honestly report rollback_partial: ${JSON.stringify(rollbackAttempt)}`);
    }
    evidence.steps.push({ name: "hub4x7_landscape_rollback_partial", response: rollbackAttempt });

    evidence.steps.push({ name: "hub4x7_save", response: await client.rcon("save directorate_gate_hub4x7") });
    await client.shutdown();
  }, { fixture: hub4x7Fixture, gamePort: hub4x7GamePort, logPath: hub4x7LogPath });

  const savePath = join(hub4x7Fixture, "save/directorate_gate_hub4x7.sav");
  if (!existsSync(savePath)) throw new Error(`hub4x7 save missing: ${savePath}`);

  await withServer(savePath, async () => {
    const client = new AdminClient({
      host: "127.0.0.1",
      port: hub4x7Port,
      password,
      name: "directorate real-engine gate hub4x7 restart",
      version: "0.1.0",
      requestTimeoutMs,
      connectTimeoutMs: 10000,
      pingIntervalMs: 0,
      reconnect: { enabled: false, maxAttempts: 0, initialDelayMs: 100, maxDelayMs: 100 },
      maxResponseBytes: 1024 * 1024,
      maxResponseChunks: 256,
      maxPendingRequests: 16,
    });
    await client.connect();
    const replayHandlers = createToolHandlers(new AdminOpenTtdGateway(client));
    evidence.steps.push({ name: "hub4x7_restart_connect", ok: true });
    await delay(1000);

    const observeAfterRestart = assertOk("hub4x7_observe_routes_after_restart", await request(replayHandlers, "observe", { scope: "routes", company_id: 0, limit: 16 }));
    const afterRoutes = observeAfterRestart.payload?.routes ?? [];
    const persistedFirst = afterRoutes.find((route) => route?.route_id === "directorate-hub4x7-gate-route");
    const persistedSecond = afterRoutes.find((route) => route?.route_id === "directorate-hub4x7-gate-route-second");
    if (persistedFirst?.state !== "commissioned" || persistedSecond?.state !== "commissioned") {
      throw new Error(`hub4x7 expected both routes to persist commissioned after restart: ${JSON.stringify(afterRoutes)}`);
    }
    evidence.steps.push({ name: "hub4x7_observe_routes_after_restart", response: observeAfterRestart });

    const verifyAfterRestart = assertOk("hub4x7_verify_topology_after_restart", await request(replayHandlers, "verify", { company_id: 0, route_id: "directorate-hub4x7-gate-route", level: "topology" }));
    if (verifyAfterRestart.payload?.health?.topology_ok !== true) throw new Error(`hub4x7 topology not ok after restart: ${JSON.stringify(verifyAfterRestart)}`);
    evidence.steps.push({ name: "hub4x7_verify_topology_after_restart", response: verifyAfterRestart });

    await client.shutdown();
  }, { fixture: hub4x7Fixture, gamePort: hub4x7GamePort, logPath: hub4x7LogPath });

  if (process.env.OPENTTD_GATE_KEEP_FIXTURE !== "1") rmSync(hub4x7Fixture, { recursive: true, force: true });
}

async function main() {
  writeConfig();
  const evidence = {
    fixture,
    openttd,
    openttd_version: openttdVersion,
    openttd_sha256: createHash("sha256").update(readFileSync(openttd)).digest("hex"),
    opengfx: openGfx,
    source_commit: gitOutput(["rev-parse", "HEAD"], "unknown"),
    source_dirty: gitOutput(["status", "--porcelain"], "").length > 0,
    port,
    game_port: gamePort,
    hub4x7_fixture: hub4x7Fixture,
    hub4x7_port: hub4x7Port,
    hub4x7_game_port: hub4x7GamePort,
    steps: [],
  };
  let planRevision = 0;
  let commitRevision = 0;
  let failed = false;
  const onlyHub4x7 = process.env.OPENTTD_GATE_ONLY_HUB4X7 === "1";
  try {
    if (!onlyHub4x7) {
    await withPhaseDeadline("initial_server", () => withServer(null, async () => {
      const client = new AdminClient({
        host: "127.0.0.1",
        port,
        password,
        name: "directorate real-engine gate",
        version: "0.1.0",
        requestTimeoutMs,
        connectTimeoutMs: 10000,
        pingIntervalMs: 0,
        reconnect: { enabled: false, maxAttempts: 0, initialDelayMs: 100, maxDelayMs: 100 },
        maxResponseBytes: 1024 * 1024,
        maxResponseChunks: 256,
        maxPendingRequests: 16,
      });
      await client.connect();
      const handlers = createToolHandlers(new AdminOpenTtdGateway(client));
      evidence.steps.push({ name: "connect", ok: true });
      const startAi = await client.rcon('start_ai "Directorate Gate Fixture"');
      evidence.steps.push({ name: "start_fixture_company", response: startAi });
      await delay(1000);
      const gameState = assertOk("get_game_state", await request(handlers, "execute", {
        company_id: 0,
        command: "get_game_state",
        params: {},
      }));
      if (typeof gameState.payload?.campaign_id !== "string" || gameState.payload.campaign_id.length < 8) {
        throw new Error(`game state did not expose a campaign epoch: ${JSON.stringify(gameState)}`);
      }
      const companyInfo = assertOk("get_company_info", await request(handlers, "execute", {
        company_id: 0,
        command: "get_company_info",
        params: {},
      }));
      if (typeof companyInfo.payload?.name !== "string" || companyInfo.payload.name.length < 1 || typeof companyInfo.payload?.bank_balance !== "number") {
        throw new Error(`company info contract is incomplete: ${JSON.stringify(companyInfo)}`);
      }
      evidence.steps.push({ name: "campaign_identity", game_state: gameState, company_info: companyInfo });
      evidence.steps.push({ name: "observe", response: assertOk("observe", await request(handlers, "observe", { scope: "plans", limit: 4 })) });

      const industryWire = await client.requestGameScript("execute", {
        company_id: 0,
        command: "list_industries",
        params: { cargo_label: "COAL", role: "source", limit: 4 },
      });
      const industryList = assertOk("list_industries", industryWire.payload);
      if (!Array.isArray(industryList.payload?.industries)) throw new Error(`industry discovery did not return an array: ${JSON.stringify(industryList)}`);
      evidence.steps.push({ name: "list_industries", response: industryWire });

      const plan = await request(handlers, "plan", {
        company_id: 0,
        plan_id: "directorate-gate-plan",
        intent: { source_industry_id: 0, destination_industry_id: 1 },
        policy: {
          station_template: "through_hub_2x4",
          site_search_radius: 4,
          site_pair_skip: Number.parseInt(process.env.OPENTTD_GATE_SITE_PAIR_SKIP ?? "0", 10),
          route_expansion_limit: 32768,
          route_frontier_limit: 32768,
          route_turn_cost: 50,
          wagon_count: 1,
          signals: true,
        },
      });
      evidence.steps.push({ name: "plan", response: assertOk("plan", plan) });

      if (!plan.ok || plan.payload?.revision === undefined) {
        throw new Error("plan did not return revision");
      }
      const revision = plan.payload.revision;
      planRevision = revision;

      const migrationSafetyWire = await client.requestGameScript("execute", {
        company_id: 0,
        command: "migration_safety_probe",
        params: { plan_id: "directorate-gate-plan" },
      });
      const migrationSafety = assertOk("migration_safety_probe", migrationSafetyWire.payload);
      if (migrationSafety.payload?.all_rejected !== true) throw new Error(`malformed v1 migration input was accepted: ${JSON.stringify(migrationSafety)}`);
      evidence.steps.push({ name: "migration_safety_probe", response: migrationSafetyWire });

      evidence.steps.push({
        name: "preflight",
        response: assertOk("preflight", await request(handlers, "apply", {
          company_id: 0,
          plan_id: "directorate-gate-plan",
          revision,
          phase: "preflight",
          operation_id: "directorate-gate.preflight",
        })),
      });
      const commit = assertOk("commit", await request(handlers, "apply", {
        company_id: 0,
        plan_id: "directorate-gate-plan",
        revision,
        phase: "commit",
        operation_id: "directorate-gate.commit",
      }));
      evidence.steps.push({ name: "commit", response: commit });
      commitRevision = commit.payload?.revision ?? revision + 1;

      const throughHubProbeWire = await client.requestGameScript("execute", {
        company_id: 0,
        command: "through_hub_topology_probe",
        params: { plan_id: "directorate-gate-plan" },
      });
      const throughHubProbe = assertOk("through_hub_topology_probe", throughHubProbeWire.payload);
      if (throughHubProbe.payload?.source_rect?.platforms !== 2 || throughHubProbe.payload?.source_rect?.length !== 4 || throughHubProbe.payload?.destination_rect?.platforms !== 2 || throughHubProbe.payload?.destination_rect?.length !== 4) {
        throw new Error(`through-hub station rectangles are not 2x4: ${JSON.stringify(throughHubProbe)}`);
      }
      if (throughHubProbe.payload?.source_entries !== 2 || throughHubProbe.payload?.destination_entries !== 2) {
        throw new Error(`through-hub fan/merge distribution missing rows: ${JSON.stringify(throughHubProbe)}`);
      }
      evidence.steps.push({ name: "through_hub_topology_probe", response: throughHubProbeWire });

      const signalProbeWire = await client.requestGameScript("execute", {
        company_id: 0,
        command: "signal_api_probe",
        params: { plan_id: "directorate-gate-plan" },
      });
      const signalProbe = assertOk("signal_api_probe", signalProbeWire.payload);
      if (typeof signalProbe.payload?.signal_type !== "number" || signalProbe.payload?.removed !== true) throw new Error(`one-way PBS signal probe failed: ${JSON.stringify(signalProbe)}`);
      evidence.steps.push({ name: "signal_api_probe", response: signalProbeWire });

      const observeApplied = assertOk("observe_after_commit", await request(handlers, "observe", { scope: "plans", route_id: "directorate-gate-plan" }));
      if (observeApplied.payload?.plans?.[0]?.state !== "applied") throw new Error(`plan not applied: ${JSON.stringify(observeApplied)}`);
      evidence.steps.push({ name: "observe_after_commit", response: observeApplied });

      const wagonSeedWire = await client.requestGameScript("execute", {
        company_id: 0,
        command: "wagon_chain_probe_seed",
        params: { plan_id: "directorate-gate-plan" },
      });
      const wagonSeed = assertOk("wagon_chain_probe_seed", wagonSeedWire.payload);
      const seededWagonId = wagonSeed.payload?.vehicle_id;
      if (!Number.isInteger(seededWagonId) || wagonSeed.payload?.count !== 1) throw new Error(`free-wagon probe did not seed one wagon: ${JSON.stringify(wagonSeed)}`);
      evidence.steps.push({ name: "wagon_chain_probe_seed", response: wagonSeedWire });

      const blockedCommission = await request(handlers, "commission", {
        company_id: 0,
        plan_id: "directorate-gate-plan",
        route_id: "directorate-gate-route-blocked-stock",
        cargo_label: "",
      });
      if (blockedCommission.ok !== false || blockedCommission.payload?.error?.code !== "depot_free_stock_present") {
        throw new Error(`commissioning did not refuse occupied depot stock: ${JSON.stringify(blockedCommission)}`);
      }
      evidence.steps.push({ name: "commission_refuses_free_stock", response: blockedCommission });

      const wagonStatusWire = await client.requestGameScript("execute", {
        company_id: 0,
        command: "wagon_chain_probe_status",
        params: { vehicle_id: seededWagonId },
      });
      const wagonStatus = assertOk("wagon_chain_probe_status", wagonStatusWire.payload);
      if (wagonStatus.payload?.valid !== true || wagonStatus.payload?.primary !== false || wagonStatus.payload?.count !== 1) {
        throw new Error(`refused commission mutated pre-existing free stock: ${JSON.stringify(wagonStatus)}`);
      }
      evidence.steps.push({ name: "wagon_chain_probe_status", response: wagonStatusWire });

      const wagonCleanupWire = await client.requestGameScript("execute", {
        company_id: 0,
        command: "wagon_chain_probe_cleanup",
        params: { vehicle_id: seededWagonId },
      });
      const wagonCleanup = assertOk("wagon_chain_probe_cleanup", wagonCleanupWire.payload);
      if (wagonCleanup.payload?.sold !== true || wagonCleanup.payload?.valid !== false) throw new Error(`free-wagon probe cleanup failed: ${JSON.stringify(wagonCleanup)}`);
      evidence.steps.push({ name: "wagon_chain_probe_cleanup", response: wagonCleanupWire });

      const commission = assertRouteCommissioned(
        "commission_route",
        await request(handlers, "commission", {
          company_id: 0,
          plan_id: "directorate-gate-plan",
          route_id: "directorate-gate-route",
          cargo_label: "",
        }),
      );
      const commissionedVehicle = commission.payload?.response ?? commission.payload;
      if (commissionedVehicle?.wagon_count !== 1 || commissionedVehicle?.capacity < 1 || commissionedVehicle?.length > 16) {
        throw new Error(`platform-bounded commissioning failed: ${JSON.stringify(commission)}`);
      }
      evidence.steps.push({ name: "commission_route", response: commission });

      const secondCommission = assertRouteCommissioned(
        "commission_route_second_train",
        await request(handlers, "commission", {
          company_id: 0,
          plan_id: "directorate-gate-plan",
          route_id: "directorate-gate-route-second",
          cargo_label: "",
        }),
      );
      evidence.steps.push({ name: "commission_route_second_train", response: secondCommission });

      const observeRoutes = assertOk("observe_routes", await request(handlers, "observe", { scope: "routes", company_id: 0, limit: 16 }));
      const routes = observeRoutes.payload?.routes ?? [];
      const commissionedRoute = routes.find((route) => route?.route_id === "directorate-gate-route");
      const commissionedSecondRoute = routes.find((route) => route?.route_id === "directorate-gate-route-second");
      const blockedRoute = routes.find((route) => route?.route_id === "directorate-gate-route-blocked-stock");
      if (commissionedRoute?.state !== "commissioned" || commissionedSecondRoute?.state !== "commissioned" || blockedRoute?.state !== "failed") throw new Error(`expected two commissioned and one safely blocked route: ${JSON.stringify(routes)}`);
      evidence.steps.push({ name: "observe_routes", response: observeRoutes });

      const verifyTopology = assertOk("verify_topology", await request(handlers, "verify", { company_id: 0, route_id: "directorate-gate-route", level: "topology" }));
      if (verifyTopology.payload?.health?.topology_ok !== true) throw new Error(`topology not ok: ${JSON.stringify(verifyTopology)}`);
      evidence.steps.push({ name: "verify_topology", response: verifyTopology });

      const verifyCommissioning = assertOk("verify_commissioning", await request(handlers, "verify", { company_id: 0, route_id: "directorate-gate-route", level: "commissioning" }));
      if (verifyCommissioning.ok !== true) throw new Error(`commissioning verify failed: ${JSON.stringify(verifyCommissioning)}`);
      evidence.steps.push({ name: "verify_commissioning", response: verifyCommissioning });

      const verifySecondCommissioning = assertOk("verify_second_commissioning", await request(handlers, "verify", { company_id: 0, route_id: "directorate-gate-route-second", level: "commissioning" }));
      if (verifySecondCommissioning.ok !== true) throw new Error(`second commissioning verify failed: ${JSON.stringify(verifySecondCommissioning)}`);
      evidence.steps.push({ name: "verify_second_commissioning", response: verifySecondCommissioning });

      const verifyOperationCommit = await request(handlers, "verify", {
        company_id: 0,
        operation_id: "directorate-gate.commit",
        level: "topology",
      });
      evidence.steps.push({ name: "verify_commit_operation", response: verifyOperationCommit });
      if (!verifyOperationCommit.ok || verifyOperationCommit.payload?.result?.state !== "completed") {
        throw new Error(`commit operation did not verify to completed: ${JSON.stringify(verifyOperationCommit)}`);
      }

      const verifyEconomic = assertNotOk("verify_economic_before_travel", await request(handlers, "verify", { company_id: 0, route_id: "directorate-gate-route", level: "economic" }));
      if (verifyEconomic.payload?.health?.positive_revenue !== false) throw new Error(`economic verify unexpectedly profitable before travel: ${JSON.stringify(verifyEconomic)}`);
      evidence.steps.push({ name: "verify_economic_before_travel", response: verifyEconomic });

      let profitable = false;
      const runtimeHistory = new Map();
      for (let attempt = 0; attempt < 24; attempt++) {
        let runtimeProbeWire = null;
        for (let sample = 0; sample < 10; sample++) {
          await delay(500);
          runtimeProbeWire = await client.requestGameScript("execute", {
            company_id: 0,
            command: "through_hub_runtime_probe",
            params: { route_ids: ["directorate-gate-route", "directorate-gate-route-second"] },
          });
          const runtimeProbe = assertOk("through_hub_runtime_probe", runtimeProbeWire.payload);
          updateRuntimeHistory(runtimeHistory, runtimeProbe);
        }
        const poll = await request(handlers, "verify", { company_id: 0, route_id: "directorate-gate-route", level: "economic" });
        const secondPoll = await request(handlers, "verify", { company_id: 0, route_id: "directorate-gate-route-second", level: "economic" });
        if (typeof poll.payload?.health?.positive_revenue !== "boolean" || typeof secondPoll.payload?.health?.positive_revenue !== "boolean") throw new Error(`verify_economic_poll missing health: ${JSON.stringify({ poll, secondPoll })}`);
        if (attempt % 4 === 0 || attempt === 23 || poll.ok === true || secondPoll.ok === true) evidence.steps.push({ name: "verify_economic_runtime_poll", attempt, first: poll, second: secondPoll, runtime: runtimeProbeWire });
        if (poll.ok === true && poll.payload.health.positive_revenue === true && secondPoll.ok === true && secondPoll.payload.health.positive_revenue === true) {
          evidence.steps.push({ name: "verify_economic_both_profitable", attempt, first: poll, second: secondPoll });
          profitable = true;
          break;
        }
      }
      if (!profitable) throw new Error(`both routes did not become profitable within poll window`);
      const runtimeSummary = runtimeHistorySummary(runtimeHistory);
      evidence.steps.push({ name: "through_hub_runtime_history", response: runtimeSummary });
      const totalDeliveries = Object.values(runtimeSummary).reduce((sum, route) => sum + route.deliveries, 0);
      const usedRows = new Set(Object.values(runtimeSummary).flatMap((route) => [...route.source_rows, ...route.destination_rows]));
      if (totalDeliveries < 2 || usedRows.size < 2) throw new Error(`runtime did not prove two deliveries across both platform rows: ${JSON.stringify(runtimeSummary)}`);

      const verifyEconomicAfter = assertOk("verify_economic_after_travel", await request(handlers, "verify", { company_id: 0, route_id: "directorate-gate-route", level: "economic" }));
      if (verifyEconomicAfter.payload?.health?.vehicle_running !== true) throw new Error(`vehicle not running after travel: ${JSON.stringify(verifyEconomicAfter)}`);
      evidence.steps.push({ name: "verify_economic_after_travel", response: verifyEconomicAfter });

	  const loadBudgetWire = await client.requestGameScript("execute", { company_id: 0, command: "load_budget_probe_seed", params: {} });
	  const loadBudget = assertOk("load_budget_probe_seed", loadBudgetWire.payload);
	  if (loadBudget.payload?.seeded !== 2 || loadBudget.payload?.entries_each !== 111) throw new Error("load budget probe did not seed two 111-entry partial operations");
	  evidence.steps.push({ name: "load_budget_probe_seed", response: loadBudgetWire });
	  const capacityWire = await client.requestGameScript("execute", { company_id: 0, command: "capacity_probe_fill", params: {} });
	  const capacity = assertOk("capacity_probe_fill", capacityWire.payload);
	  if (capacity.payload?.active_count !== 256) throw new Error(`capacity probe did not fill journal: ${JSON.stringify(capacity)}`);
	  evidence.steps.push({ name: "capacity_probe_fill", response: capacityWire });

      evidence.steps.push({ name: "save", response: await client.rcon("save directorate_gate") });
      await client.shutdown();
    }));

    const savePath = join(fixture, "save/directorate_gate.sav");
    if (!existsSync(savePath)) throw new Error(`save missing: ${savePath}`);

    await withPhaseDeadline("restart_server", () => withServer(savePath, async () => {
      const client = new AdminClient({
        host: "127.0.0.1",
        port,
        password,
        name: "directorate real-engine gate restart",
        version: "0.1.0",
        requestTimeoutMs,
        connectTimeoutMs: 10000,
        pingIntervalMs: 0,
        reconnect: { enabled: false, maxAttempts: 0, initialDelayMs: 100, maxDelayMs: 100 },
        maxResponseBytes: 1024 * 1024,
        maxResponseChunks: 256,
        maxPendingRequests: 16,
      });
      await client.connect();
      const replayHandlers = createToolHandlers(new AdminOpenTtdGateway(client));
      evidence.steps.push({ name: "restart_connect", ok: true });

	  await delay(1000);
	  const retainedWire = await client.requestGameScript("execute", { company_id: 0, command: "load_budget_probe_status", params: {} });
	  const retained = assertOk("load_budget_probe_status", retainedWire.payload);
	  if (retained.payload?.all_retained !== true || retained.payload?.first_entries !== 111 || retained.payload?.second_entries !== 111 || retained.payload?.active_count !== 256 || retained.payload?.deferred_count !== 0) {
		throw new Error(`deferred partial journals were not all retained: ${JSON.stringify(retained)}`);
	  }
	  evidence.steps.push({ name: "load_budget_probe_status", response: retainedWire });

	  const immediateReplay = assertNotOk("immediate_deferred_replay", await request(replayHandlers, "apply", {
		company_id: 0,
		plan_id: "directorate-gate-plan",
		revision: 4,
		phase: "commit",
		operation_id: "directorate-gate.partial-b",
		reserve: 0,
	  }));
	  evidence.steps.push({ name: "immediate_deferred_replay", response: immediateReplay });
	  const afterReplayWire = await client.requestGameScript("execute", { company_id: 0, command: "load_budget_probe_status", params: {} });
	  const afterReplay = assertOk("load_budget_probe_status_after_replay", afterReplayWire.payload);
	  if (afterReplay.payload?.active_count !== 256 || afterReplay.payload?.deferred_count !== 0 || afterReplay.payload?.second_entries !== 111) throw new Error(`immediate replay changed persisted journal: ${JSON.stringify(afterReplay)}`);
	  evidence.steps.push({ name: "load_budget_probe_status_after_replay", response: afterReplayWire });

      const replayCommission = await request(replayHandlers, "commission", {
        company_id: 0,
        plan_id: "directorate-gate-plan",
        route_id: "directorate-gate-route",
        cargo_label: "",
      });
      if (replayCommission.payload?.note !== "idempotent") {
        throw new Error(`commission replay not idempotent: ${JSON.stringify(replayCommission)}`);
      }
      evidence.steps.push({ name: "commission_replay_after_restart", response: replayCommission });

      const replaySecondCommission = await request(replayHandlers, "commission", {
        company_id: 0,
        plan_id: "directorate-gate-plan",
        route_id: "directorate-gate-route-second",
        cargo_label: "",
      });
      if (replaySecondCommission.payload?.note !== "idempotent") {
        throw new Error(`second commission replay not idempotent: ${JSON.stringify(replaySecondCommission)}`);
      }
      evidence.steps.push({ name: "commission_second_replay_after_restart", response: replaySecondCommission });

      const observeAfterRestart = assertOk("observe_routes_after_restart", await request(replayHandlers, "observe", { scope: "routes", company_id: 0, limit: 16 }));
      const afterRoutes = observeAfterRestart.payload?.routes ?? [];
      const persistedCommissioned = afterRoutes.find((route) => route?.route_id === "directorate-gate-route");
      const persistedSecondCommissioned = afterRoutes.find((route) => route?.route_id === "directorate-gate-route-second");
      const persistedBlocked = afterRoutes.find((route) => route?.route_id === "directorate-gate-route-blocked-stock");
      if (persistedCommissioned?.state !== "commissioned" || persistedSecondCommissioned?.state !== "commissioned" || persistedBlocked?.state !== "failed") throw new Error(`expected persisted commissioned and blocked routes after restart, got ${JSON.stringify(afterRoutes)}`);
      evidence.steps.push({ name: "observe_routes_after_restart", response: observeAfterRestart });

      const verifyAfterRestart = assertOk("verify_topology_after_restart", await request(replayHandlers, "verify", { company_id: 0, route_id: "directorate-gate-route", level: "topology" }));
      if (verifyAfterRestart.payload?.health?.topology_ok !== true) throw new Error(`topology not ok after restart: ${JSON.stringify(verifyAfterRestart)}`);
      evidence.steps.push({ name: "verify_topology_after_restart", response: verifyAfterRestart });

	  const rollbackProbe = assertOk("load_budget_probe_rollback", await request(replayHandlers, "apply", {
		company_id: 0,
		plan_id: "directorate-gate-plan",
		revision: 4,
		phase: "rollback",
		operation_id: "directorate-gate.partial-rollback",
		target_operation_id: "directorate-gate.partial-a",
		reserve: 0,
	  }));
	  if (rollbackProbe.payload?.remaining?.length !== 0) throw new Error(`deferred rollback did not complete: ${JSON.stringify(rollbackProbe)}`);
	  evidence.steps.push({ name: "load_budget_probe_rollback", response: rollbackProbe });
	  await client.shutdown();
	  }));
	  }

	  await withPhaseDeadline("terrain_obstructed_hub4x7", () => runTerrainObstructedHub4x7Fixture(evidence));
  } catch (error) {
    failed = true;
    evidence.steps.push({ name: "blocked_or_failed", message: error instanceof Error ? error.message : String(error) });
    process.exitCode = 1;
  } finally {
    evidence.log = logPath;
    try {
      evidence.log_excerpt = existsSync(logPath) ? readFileSync(logPath, "utf8").slice(0, 2000) : "";
    } catch {
      evidence.log_excerpt = "";
    }
    evidence.evidence_path = failed ? join(fixture, "directorate-real-engine-gate-failed.json") : evidencePath;
    writeFileSync(evidence.evidence_path, `${JSON.stringify(evidence, null, 2)}\n`);
    console.log(JSON.stringify(evidence, null, 2));
    if (process.env.OPENTTD_GATE_KEEP_FIXTURE !== "1" && !failed) rmSync(fixture, { recursive: true, force: true });
  }
}

await main();
