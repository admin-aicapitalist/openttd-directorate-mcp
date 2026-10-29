/* tamago fork: a camera director for the live stream. It moves only the view
 * of the spectator client named DIRECTORATE_CAMERA_CLIENT (the viewer's
 * TamagoCam), never a player's. Scrolling a client is a deity command and
 * build code runs under a company, so a build records its path and the main
 * loop sweeps the camera along it right after; a newly commissioned vehicle is
 * the next shot; otherwise it tours running vehicles of every transport type,
 * re-centring on each one so the shot follows it. Other build code can call
 * D4_Camera.Building(tile). */

DIRECTORATE_CAMERA_CLIENT <- "TamagoCam";
DIRECTORATE_CAMERA_FIND_TICKS <- 222;       // look for the camera client again every 3 game days
DIRECTORATE_CAMERA_FOLLOW_TICKS <- 74;      // re-centre on the followed vehicle once a game day
DIRECTORATE_CAMERA_SHOT_TICKS <- 1110;      // 15 game days on one vehicle, about 30 s at normal speed
DIRECTORATE_CAMERA_SWEEP_TICKS <- 37;       // one step along a fresh build every half day
DIRECTORATE_CAMERA_BUILD_HOLD_TICKS <- 1110; // then stay on the finished site before touring
DIRECTORATE_CAMERA_BUILD_STEP_TILES <- 6;   // sweep points along a build are this far apart
DIRECTORATE_CAMERA_MAX_SWEEP <- 96;

D4_Camera <- null;

class DirectorateCamera {
	client = null;
	next_find = 0;
	focus = null;
	vehicle = null;
	last_type = -1;
	shot_end = 0;
	next_follow = 0;
	hold_until = 0;
	sweep = null;
	last_scroll = null;

	constructor() {
		this.sweep = [];
	}

	function Status() {
		local clients = [];
		foreach (c, _ in GSClientList()) clients.append({ id = c, name = GSClient.GetName(c) });
		return { client = this.client, clients = clients, focus = this.focus, vehicle = this.vehicle, sweep = this.sweep.len(),
			last_scroll = this.last_scroll, hold_until = this.hold_until, shot_end = this.shot_end, tick = D4_Tick() };
	}

	function Client() {
		if (this.client != null && GSClient.ResolveClientID(this.client) != GSClient.CLIENT_INVALID) return this.client;
		this.client = null;
		local now = D4_Tick();
		if (now < this.next_find || !GSGame.IsMultiplayer()) return null;
		this.next_find = now + DIRECTORATE_CAMERA_FIND_TICKS;
		foreach (c, _ in GSClientList()) {
			if (GSClient.GetName(c) == DIRECTORATE_CAMERA_CLIENT) { this.client = c; break; }
		}
		return this.client;
	}

	/* Deity context only: the main loop. */
	function Show(tile) {
		local client = this.Client();
		if (client == null || !GSMap.IsValidTile(tile)) return false;
		this.focus = tile;
		local ok = GSViewport.ScrollClientTo(client, tile);
		this.last_scroll = { tile = tile, ok = ok, error = ok ? null : GSError.GetLastErrorString() };
		return ok;
	}

	/* The build program built a piece at tile: add it to the sweep. */
	function Building(tile) {
		this.vehicle = null;
		local n = this.sweep.len();
		if (n > 0 && GSMap.DistanceManhattan(tile, this.sweep[n - 1]) < DIRECTORATE_CAMERA_BUILD_STEP_TILES) return;
		if (n >= DIRECTORATE_CAMERA_MAX_SWEEP) {
			local thinned = [];
			for (local i = 0; i < n; i += 2) thinned.append(this.sweep[i]);
			this.sweep = thinned;
		}
		this.sweep.append(tile);
	}

	/* A vehicle was just commissioned: its first trip is the next shot. */
	function Feature(vehicle_id) {
		if (!GSVehicle.IsValidVehicle(vehicle_id)) return;
		this.vehicle = vehicle_id;
		this.last_type = GSVehicle.GetVehicleType(vehicle_id);
		this.shot_end = D4_Tick() + DIRECTORATE_CAMERA_SHOT_TICKS;
		this.next_follow = 0;
		this.hold_until = 0;
	}

	function Tick() {
		local now = D4_Tick();
		if (now < this.next_follow || this.Client() == null) return;
		if (this.sweep.len() > 0) {
			this.Show(this.sweep.remove(0));
			this.next_follow = now + DIRECTORATE_CAMERA_SWEEP_TICKS;
			if (this.sweep.len() > 0) return;
			/* Sweep done: hold on the site, unless a vehicle was commissioned meanwhile. */
			if (this.vehicle == null) this.hold_until = now + DIRECTORATE_CAMERA_BUILD_HOLD_TICKS;
			else this.shot_end = now + DIRECTORATE_CAMERA_SHOT_TICKS;
			return;
		}
		if (now < this.hold_until) return;
		if (this.vehicle == null || now >= this.shot_end || !this.IsWatchable(this.vehicle)) {
			this.vehicle = this.NextVehicle();
			if (this.vehicle == null) return;
			this.shot_end = now + DIRECTORATE_CAMERA_SHOT_TICKS;
		}
		this.next_follow = now + DIRECTORATE_CAMERA_FOLLOW_TICKS;
		this.Show(GSVehicle.GetLocation(this.vehicle));
	}

	function IsWatchable(v) {
		if (!GSVehicle.IsValidVehicle(v)) return false;
		local state = GSVehicle.GetState(v);
		return state != GSVehicle.VS_STOPPED && state != GSVehicle.VS_CRASHED && state != GSVehicle.VS_INVALID;
	}

	/* A moving vehicle, preferring another transport type than the last shot
	 * and another vehicle than the current one; failing that, one loading at a
	 * station or broken down, so a young network with one train still shows it. */
	function NextVehicle() {
		local other_type = [];
		local same_type = [];
		local current = [];
		local idle = [];
		foreach (v, _ in GSVehicleList()) {
			if (GSVehicle.GetState(v) != GSVehicle.VS_RUNNING || GSVehicle.GetCurrentSpeed(v) <= 0) {
				if (this.IsWatchable(v) && GSVehicle.GetState(v) != GSVehicle.VS_IN_DEPOT) idle.append(v);
				continue;
			}
			if (v == this.vehicle) current.append(v);
			else if (GSVehicle.GetVehicleType(v) != this.last_type) other_type.append(v);
			else same_type.append(v);
		}
		local pool = other_type.len() > 0 ? other_type : same_type.len() > 0 ? same_type : current.len() > 0 ? current : idle;
		if (pool.len() == 0) return null;
		local v = pool[GSBase.RandRange(pool.len())];
		this.last_type = GSVehicle.GetVehicleType(v);
		return v;
	}
}
