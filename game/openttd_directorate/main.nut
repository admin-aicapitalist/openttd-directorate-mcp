require("version.nut");
require("util.nut");
require("json.nut");
require("geometry.nut");
require("blueprint.nut");
require("site_survey.nut");
require("route_planner.nut");
require("build_program.nut");
require("operation_journal.nut");
require("plan_store.nut");
require("route_registry.nut");
require("bridge.nut");
require("director.nut");

class OpenTTDDirectorate extends GSController {
	bridge = null;
	store = null;
	pending_load = null;

	function Start();
	function Save();
	function Load(version, data);
}

function OpenTTDDirectorate::Start() {
	if (this.store == null) this.store = DirectorateM4PlanStore();
	if (this.bridge == null) this.bridge = DirectorateM4Bridge(this.store);
	if (::D4_Camera == null) ::D4_Camera = DirectorateCamera();
	if (this.pending_load != null) {
		this.store.BeginLoad(this.pending_load);
		this.pending_load = null;
	}
	while (this.store.HasDeferredOperations()) {
		this.store.Tick();
		GSController.Sleep(1);
	}
	while (true) {
		this.store.Tick();
		this.bridge.Poll();
		::D4_Camera.Tick();
		GSController.Sleep(1);
	}
}

function OpenTTDDirectorate::Save() {
	GSLog.Info("D4 M4 save plans=" + (this.store == null ? "null" : this.store.order.len().tostring()));
	return {
		version = DIRECTORATE_M4_SAVE_VERSION,
		plans = this.store.Save(),
	};
}

function OpenTTDDirectorate::Load(version, data) {
	GSLog.Info("D4 M4 load callback version=" + version.tostring() + " data=" + (data == null ? "null" : "present"));
	this.store = DirectorateM4PlanStore();
	this.pending_load = null;
	if (data != null && "version" in data && data.version == DIRECTORATE_M4_SAVE_VERSION && "plans" in data) {
		/* OpenTTD's Load callback cannot yield and has a tiny instruction budget.
		 * Retain the raw envelope by reference; Start hydrates one bounded record
		 * per tick before polling the external bridge. */
		this.pending_load = data.plans;
		GSLog.Info("D4 M4 load envelope deferred");
	} else {
		GSLog.Warning("D4 M4 load rejected envelope");
	}
	this.bridge = DirectorateM4Bridge(this.store);
}
