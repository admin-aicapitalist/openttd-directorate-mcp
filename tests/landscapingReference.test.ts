import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { join } from "node:path";
import test from "node:test";

/**
 * These are executable JS mirrors of the bounded-landscaping decision logic added
 * to game/openttd_directorate/build_program.nut and operation_journal.nut. Squirrel
 * cannot run inside this Node test process, so the mirrors are exercised directly
 * (real assertions on behavior, not just regex-on-source), and each mirror's key
 * ordering/formula is cross-checked against a literal excerpt of the .nut source so
 * the two cannot silently drift apart. This is the same "reference model" pattern
 * used by tests/m3OperationJournalReference.test.ts for the operation journal.
 */

const gameDir = "game/openttd_directorate";

// Real OpenTTD GSTile enum values (script/api/script_tile.hpp). Corner is an
// ordinal (W, S, E, N = 0..3); Slope is an independent bitmask (W=1, S=2, E=4,
// N=8). The two are not interchangeable, which is exactly what the historical bug
// in D4_RestoreLandscape got wrong.
const GSTILE_CORNER = { W: 0, S: 1, E: 2, N: 3 } as const;
const GSTILE_SLOPE = { W: 1, S: 2, E: 4, N: 8 } as const;
type CornerLabel = keyof typeof GSTILE_CORNER;

class MockTile {
  // Indexed by real Corner ordinal (0=W, 1=S, 2=E, 3=N).
  private heights: [number, number, number, number];
  constructor(w: number, s: number, e: number, n: number) {
    this.heights = [w, s, e, n];
  }
  getCornerHeight(cornerOrdinal: number): number {
    const h = this.heights[cornerOrdinal];
    if (h === undefined) throw new Error(`corner ordinal out of range: ${cornerOrdinal}`);
    return h;
  }
  // Faithful to the real command: a Slope bitmask, any combination of the four
  // single-corner bits. delta is +1 for RaiseTile, -1 for LowerTile.
  private applySlope(slopeBits: number, delta: number): boolean {
    if (slopeBits <= 0 || slopeBits > (GSTILE_SLOPE.W | GSTILE_SLOPE.S | GSTILE_SLOPE.E | GSTILE_SLOPE.N)) return false;
    if (slopeBits & GSTILE_SLOPE.W) this.heights[GSTILE_CORNER.W] += delta;
    if (slopeBits & GSTILE_SLOPE.S) this.heights[GSTILE_CORNER.S] += delta;
    if (slopeBits & GSTILE_SLOPE.E) this.heights[GSTILE_CORNER.E] += delta;
    if (slopeBits & GSTILE_SLOPE.N) this.heights[GSTILE_CORNER.N] += delta;
    return true;
  }
  raiseTile(slopeBits: number): boolean {
    return this.applySlope(slopeBits, 1);
  }
  lowerTile(slopeBits: number): boolean {
    return this.applySlope(slopeBits, -1);
  }
  snapshot(): Record<CornerLabel, number> {
    return { W: this.heights[0], S: this.heights[1], E: this.heights[2], N: this.heights[3] };
  }
}

// D4_LandscapeSnapshot always builds record.h as [N, E, S, W].
const SNAPSHOT_ORDER: CornerLabel[] = ["N", "E", "S", "W"];

/** Fixed mirror of D4_RestoreLandscape: maps each snapshot index through both the
 * Corner and Slope enums correctly before reading/writing. */
function restoreLandscapeFixed(tile: MockTile, targets: [number, number, number, number], maxSteps = 768): boolean {
  const cornerEnumOrder = SNAPSHOT_ORDER.map((c) => GSTILE_CORNER[c]);
  const slopeEnumOrder = SNAPSHOT_ORDER.map((c) => GSTILE_SLOPE[c]);
  let steps = 0;
  for (let i = 0; i < 4; i++) {
    const cornerEnum = cornerEnumOrder[i]!;
    const slopeEnum = slopeEnumOrder[i]!;
    const target = targets[i]!;
    while (tile.getCornerHeight(cornerEnum) !== target && steps < maxSteps) {
      const current = tile.getCornerHeight(cornerEnum);
      const ok = current < target ? tile.raiseTile(slopeEnum) : tile.lowerTile(slopeEnum);
      if (!ok) return false;
      steps++;
    }
    if (tile.getCornerHeight(cornerEnum) !== target) return false;
  }
  return true;
}

/** Historical mirror of the pre-fix D4_RestoreLandscape: reuses the raw loop index
 * 0..3 as both the Corner argument and the Slope argument. */
function restoreLandscapeHistoricalBug(tile: MockTile, targets: [number, number, number, number], maxSteps = 768): boolean {
  let steps = 0;
  for (let i = 0; i < 4; i++) {
    const target = targets[i]!;
    while (tile.getCornerHeight(i) !== target && steps < maxSteps) {
      const current = tile.getCornerHeight(i);
      const ok = current < target ? tile.raiseTile(i) : tile.lowerTile(i);
      if (!ok) return false;
      steps++;
    }
    if (tile.getCornerHeight(i) !== target) return false;
  }
  return true;
}

test("fixed corner/slope restore mirror converges every corner to its exact original height", () => {
  const original = { N: 4, E: 6, S: 2, W: 8 };
  const tile = new MockTile(original.W, original.S, original.E, original.N);
  // Flatten it first, as GSTile.LevelTiles would before a rollback needs to undo it.
  const flattened = new MockTile(4, 4, 4, 4);
  const targets: [number, number, number, number] = [original.N, original.E, original.S, original.W];
  assert.equal(restoreLandscapeFixed(flattened, targets), true);
  assert.deepEqual(flattened.snapshot(), original);
});

test("fixed corner/slope restore mirror is a no-op when already at target and stays within its step budget", () => {
  const tile = new MockTile(1, 1, 1, 1);
  const targets: [number, number, number, number] = [1, 1, 1, 1];
  assert.equal(restoreLandscapeFixed(tile, targets, 0), true);
});

test("historical corner-as-slope restore bug corrupts or fails to restore distinct corner heights", () => {
  const original = { N: 4, E: 6, S: 2, W: 8 };
  const flattened = new MockTile(4, 4, 4, 4);
  const targets: [number, number, number, number] = [original.N, original.E, original.S, original.W];
  const ok = restoreLandscapeHistoricalBug(flattened, targets);
  // The buggy path either can never converge (returns false, so the journal
  // entry would honestly surface as rollback_partial) or, worse, "succeeds" while
  // leaving the tile at the wrong heights. Either way it must not silently
  // reproduce the original per-corner heights the way the fixed mirror does.
  if (ok) {
    assert.notDeepEqual(flattened.snapshot(), original);
  } else {
    assert.equal(ok, false);
  }
});

test("operation_journal.nut restores corners through the real Corner and Slope enums, not a shared raw index", () => {
  const journal = readFileSync(join(gameDir, "operation_journal.nut"), "utf8");
  assert.match(journal, /local corner_order = \[GSTile\.CORNER_N, GSTile\.CORNER_E, GSTile\.CORNER_S, GSTile\.CORNER_W\];/);
  assert.match(journal, /local slope_order = \[GSTile\.SLOPE_N, GSTile\.SLOPE_E, GSTile\.SLOPE_S, GSTile\.SLOPE_W\];/);
  assert.match(journal, /GSTile\.RaiseTile\(record\.tile, slope\)/);
  assert.match(journal, /GSTile\.LowerTile\(record\.tile, slope\)/);
  // The historical bug passed the bare loop index to both calls; make sure that
  // shape does not reappear.
  assert.doesNotMatch(journal, /GSTile\.RaiseTile\(record\.tile, corner\)/);
  assert.doesNotMatch(journal, /GSTile\.GetCornerHeight\(record\.tile, i\)/);
});

type CornerRecord = { tile: number; h: [number, number, number, number]; inner: boolean; owned: [boolean, boolean, boolean, boolean] };

/** Mirrors D4_LandscapeSnapshot's [N,E,S,W] physical-corner ownership mask. */
function cornerOwnedMask(x: number, y: number, minX: number, maxX: number, minY: number, maxY: number): [boolean, boolean, boolean, boolean] {
  const coordinates = [[x, y], [x, y + 1], [x + 1, y + 1], [x + 1, y]];
  return coordinates.map(([cx, cy]) => cx! >= minX && cx! <= maxX && cy! >= minY && cy! <= maxY) as [boolean, boolean, boolean, boolean];
}

function cornerReadback(before: CornerRecord[], after: CornerRecord[], target: number): boolean {
  if (before.length !== after.length) return false;
  return before.every((record, i) => record.tile === after[i]!.tile && record.inner === after[i]!.inner && record.owned.every((owned, c) =>
    owned === after[i]!.owned[c] && (owned ? after[i]!.h[c] === target : after[i]!.h[c] === record.h[c]),
  ));
}

test("landscape readback owns shared physical corners without granting the whole halo tile", () => {
  assert.deepEqual(cornerOwnedMask(10, 10, 10, 11, 10, 11), [true, true, true, true]);
  assert.deepEqual(cornerOwnedMask(10, 9, 10, 11, 10, 11), [false, true, true, false], "y-1 halo shares E/S corners");
  assert.deepEqual(cornerOwnedMask(9, 10, 10, 11, 10, 11), [false, false, true, true], "x-1 halo shares S/W corners");
  assert.deepEqual(cornerOwnedMask(9, 9, 10, 11, 10, 11), [false, false, true, false], "diagonal halo shares one physical corner");
  assert.deepEqual(cornerOwnedMask(11, 11, 10, 11, 10, 11), [true, false, false, false], "far inner tile owns only its selected north vertex");

  const before: CornerRecord[] = [{ tile: 9, h: [4, 4, 3, 4], inner: false, owned: [false, false, true, false] }];
  const valid: CornerRecord[] = [{ tile: 9, h: [4, 4, 2, 4], inner: false, owned: [false, false,true, false] }];
  const leaked: CornerRecord[] = [{ tile: 9, h: [3, 4, 2, 4], inner: false, owned: [false, false, true, false] }];
  assert.equal(cornerReadback(before, valid, 2), true, "shared halo corner may reach target");
  assert.equal(cornerReadback(before, leaked, 2), false, "genuinely halo-only corner must not change");
});

type OrientationSnapshot = { start: number; target: number; maxDelta: number; boundaryDelta: number };

/** Mirrors D4_SelectLandscapeOrientation's fail-closed target selection. */
function selectLandscapeOrientation(candidates: OrientationSnapshot[]): OrientationSnapshot | null {
  const safe = candidates.filter((candidate) => candidate.maxDelta <= 2 && candidate.boundaryDelta <= 1);
  safe.sort((a, b) => (a.maxDelta * 16 + a.boundaryDelta) - (b.maxDelta * 16 + b.boundaryDelta) || a.start - b.start);
  return safe[0] ?? null;
}

test("landscape orientation lowers an isolated bump instead of propagating into the halo", () => {
  const selected = selectLandscapeOrientation([
    { start: 5919, target: 3, maxDelta: 2, boundaryDelta: 2 },
    { start: 6177, target: 1, maxDelta: 2, boundaryDelta: 0 },
  ]);
  assert.deepEqual(selected, { start: 6177, target: 1, maxDelta: 2, boundaryDelta: 0 });
  assert.equal(selectLandscapeOrientation([{ start: 1, target: 4, maxDelta: 2, boundaryDelta: 2 }]), null, "unbounded collateral must fail closed");
});

test("GameScript snapshots and journal sanitization require four explicit corner-ownership flags", () => {
  const program = readFileSync(join(gameDir, "build_program.nut"), "utf8");
  const journal = readFileSync(join(gameDir, "operation_journal.nut"), "utf8");
  assert.match(program, /corners\.append\(\{ tile=tile, h=hs, inner=inner, owned=owned \}\)/);
  assert.match(program, /if \(after\[i\]\.owned\[c\] && after\[i\]\.h\[c\] != target\) return \{ reason = "owned_not_target"/);
  assert.match(program, /if \(!after\[i\]\.owned\[c\] && before\[i\]\.h\[c\] != after\[i\]\.h\[c\]\) return \{ reason = "halo_only_changed"/);
  assert.match(program, /function D4_SelectLandscapeOrientation\(rect\)/);
  assert.match(program, /if \(delta > 1\) boundary_ok = false;/);
  assert.match(journal, /record\.owned\.len\(\) != 4/);
  assert.match(journal, /foreach \(owned in record\.owned\) if \(typeof owned != "bool"\) return false;/);
});

// --- Landscape footprint / deferred-preflight-verification logic ---

type FootprintOp =
  | { kind: "station_rect"; tile: number; end_tile: number }
  | { kind: "rail_connection"; tile: number; prev: number; next: number }
  | { kind: "depot"; tile: number; front: number };

/** Mirrors D4_LandscapeFootprintSet. */
function landscapeFootprintSet(landscapeOpsHalos: number[][]): Set<number> {
  const set = new Set<number>();
  for (const halo of landscapeOpsHalos) for (const tile of halo) set.add(tile);
  return set;
}

/** Mirrors D4_OpTouchesFootprint. */
function opTouchesFootprint(op: FootprintOp, footprint: Set<number>): boolean {
  if (op.kind === "station_rect") return footprint.has(op.tile) || footprint.has(op.end_tile);
  if (op.kind === "rail_connection") return footprint.has(op.tile) || footprint.has(op.prev) || footprint.has(op.next);
  if (op.kind === "depot") return footprint.has(op.tile) || footprint.has(op.front);
  return false;
}

test("footprint containment defers exactly the ops geometrically touching a pending landscape rectangle", () => {
  const footprint = landscapeFootprintSet([[100, 101, 102, 150, 151, 152]]);

  // A station rectangle whose origin is landscaped must defer.
  assert.equal(opTouchesFootprint({ kind: "station_rect", tile: 101, end_tile: 999 }, footprint), true);
  // A station rectangle entirely outside the footprint must not defer.
  assert.equal(opTouchesFootprint({ kind: "station_rect", tile: 500, end_tile: 501 }, footprint), false);

  // A rail_connection whose "prev" is the real (landscaped) station tile defers,
  // even though its own tile and next are untouched mainline track.
  assert.equal(opTouchesFootprint({ kind: "rail_connection", tile: 700, prev: 151, next: 701 }, footprint), true);
  // A rail_connection fully outside the footprint on all three of its primitive
  // tiles must not defer — this is the fix for the prior broad-flattening bug,
  // where every track tile in the whole route was force-tested against terrain
  // that had already changed underneath it.
  assert.equal(opTouchesFootprint({ kind: "rail_connection", tile: 700, prev: 699, next: 701 }, footprint), false);

  // A depot whose front tile abuts the footprint defers.
  assert.equal(opTouchesFootprint({ kind: "depot", tile: 900, front: 152 }, footprint), true);
  assert.equal(opTouchesFootprint({ kind: "depot", tile: 900, front: 901 }, footprint), false);
});

type RailOp = { kind: "rail_connection"; op_id: string; prev: number; tile: number; next: number };

/** Mirrors the role gate in D4_IsLandscapeEligibleGeometricRail. */
function eligibleGeometricRail(op: RailOp): boolean {
  return /\.fan\.|\.merge\.|\.loop\.|\.turnback\./.test(op.op_id) || op.op_id.startsWith("rail.depot_access.");
}

/** Mirrors D4_GeometricRailRectangle for a row-major map of width 128. */
function geometricRailRectangle(op: RailOp, width = 128) {
  const points = [op.prev, op.tile, op.next].map((tile) => ({ x: tile % width, y: Math.floor(tile / width) }));
  return {
    minX: Math.min(...points.map((p) => p.x)), maxX: Math.max(...points.map((p) => p.x)) + 1,
    minY: Math.min(...points.map((p) => p.y)), maxY: Math.max(...points.map((p) => p.y)) + 1,
  };
}

test("precision grading admits only failed through-hub/depot geometric rail roles, never A* corridor rail", () => {
  const fan: RailOp = { kind: "rail_connection", op_id: "rail.source.fan.0.1", prev: 322, tile: 323, next: 451 };
  const merge: RailOp = { kind: "rail_connection", op_id: "rail.destination.merge.1.2", prev: 7077, tile: 7078, next: 7206 };
  const loop: RailOp = { kind: "rail_connection", op_id: "rail.source.loop.3", prev: 719, tile: 591, next: 590 };
  const access: RailOp = { kind: "rail_connection", op_id: "rail.depot_access.0", prev: 100, tile: 101, next: 229 };
  const corridor: RailOp = { kind: "rail_connection", op_id: "rail.outbound.12", prev: 100, tile: 101, next: 102 };
  for (const op of [fan, merge, loop, access]) assert.equal(eligibleGeometricRail(op), true, op.op_id);
  assert.equal(eligibleGeometricRail(corridor), false, "A* corridor is already GSTestMode-proven and must never be landscaped");

  const box = geometricRailRectangle(fan);
  assert.deepEqual(box, { minX: 66, maxX: 68, minY: 2, maxY: 4 }, "fan envelope includes east/south boundary vertices for complete rail-tile slopes");
});

test("build_program.nut gates rail landscaping on exact failed GSTestMode, role, and immutable halo safety", () => {
  const program = readFileSync(join(gameDir, "build_program.nut"), "utf8");
  const landscapingFn = program.slice(program.indexOf("function D4_IsLandscapeEligibleGeometricRail"), program.indexOf("function D4_LandscapeEstimate"));
  assert.match(landscapingFn, /id\.find\("\.fan\."\)/);
  assert.match(landscapingFn, /id\.find\("\.merge\."\)/);
  assert.match(landscapingFn, /id\.find\("\.loop\."\)/);
  assert.match(landscapingFn, /id\.find\("\.turnback\."\)/);
  assert.match(landscapingFn, /id\.find\("rail\.depot_access\."\) == 0/);
  assert.match(landscapingFn, /if \(D4_RailConnectionAlreadyBuildable\(op, company_id\)\) continue;/);
  assert.match(landscapingFn, /local unsafe_tile = D4_LandscapeUnsafeOwnedTile\(before, company_id\)/);
  assert.match(program, /function D4_LandscapeUnsafeOwnedTile\(snapshot, company_id\)/);
  assert.match(landscapingFn, /Merge only overlapping inner rectangles/);
  assert.doesNotMatch(landscapingFn, /rail\.outbound/);
  assert.doesNotMatch(landscapingFn, /rail\.return/);
  assert.match(program, /function D4_RailConnectionAlreadyBuildable\(op, company_id\)/);
  assert.match(program, /return GSRail\.BuildRail\(op\.prev, op\.tile, op\.next\);/);
  assert.match(program, /function D4_TileInsideLandscapeRectangles\(tile, rectangles\)/);
  assert.match(program, /function D4_RailOperationTouchesLandscapeRectangles\(op, rectangles\)/);
  assert.match(program, /D4_TileInsideLandscapeRectangles\(op\.prev, rectangles\).*D4_TileInsideLandscapeRectangles\(op\.tile, rectangles\).*D4_TileInsideLandscapeRectangles\(op\.next, rectangles\)/s);
  assert.match(program, /local p = D4_FromTile\(tile\);/);
  assert.doesNotMatch(program, /D4_ToPoint/);
  assert.match(program, /function D4_LandscapeFootprintSet\(ops\)/);
  assert.match(program, /function D4_OpTouchesFootprint\(op, footprint\)/);

  const preflightFn = program.slice(program.indexOf("function D4_PreflightBuildProgram"), program.indexOf("function D4_ExecuteProgramOperation"));
  assert.match(preflightFn, /local footprint = D4_LandscapeFootprintSet\(program\.ops\);/);
  assert.match(preflightFn, /if \(op\.kind != "level_tiles" && D4_OpTouchesFootprint\(op, footprint\)\) \{/);
  assert.match(preflightFn, /cost \+= D4_ConservativeOperationCost\(op\);/);
});

// --- Site survey no longer hard-rejects a landscape-fixable sloped pad ---

/** Mirrors the fixed D4_EvaluateSite: a sloped station tile is a scoring
 * penalty, not an outright disqualification, since bounded landscaping can
 * level it later at compile time. */
function evaluateSiteScore(baseScore: number, slopedStationTiles: number): { ok: true; score: number; needsLandscaping: boolean } {
  return { ok: true, score: baseScore - slopedStationTiles * 50, needsLandscaping: slopedStationTiles > 0 };
}

test("site scoring mirror penalises but never disqualifies a sloped station candidate", () => {
  const flat = evaluateSiteScore(1000, 0);
  assert.equal(flat.ok, true);
  assert.equal(flat.needsLandscaping, false);
  assert.equal(flat.score, 1000);

  const sloped = evaluateSiteScore(1000, 3);
  assert.equal(sloped.ok, true);
  assert.equal(sloped.needsLandscaping, true);
  assert.equal(sloped.score, 850);
  // A flat candidate must still outrank an otherwise-identical sloped one.
  assert.ok(flat.score > sloped.score);
});

test("site_survey.nut scores sloped station pads down instead of rejecting the whole candidate", () => {
  const survey = readFileSync(join(gameDir, "site_survey.nut"), "utf8");
  const evaluateFn = survey.slice(survey.indexOf("function D4_EvaluateSite"), survey.indexOf("function D4_PointInList"));
  // The historical behavior hard-rejected any non-flat station tile, which
  // made D4_PrependBoundedLandscaping's station_rect path unreachable through
  // the normal site-search-driven plan flow: survey would simply steer away
  // from (or entirely fail to find) any site that needed it.
  assert.doesNotMatch(evaluateFn, /failures\.append\("station_slope"\)/);
  assert.match(evaluateFn, /sloped_station_tiles\+\+/);
  assert.match(evaluateFn, /score -= sloped_station_tiles \* 50;/);
  assert.match(evaluateFn, /if \(sloped_station_tiles > 0\) reasons\.append\("station_needs_landscaping"\);/);
});

// --- D4_SurveyStationSites: bounded nearest-first / ring-order branch-and-bound ---

/**
 * Executable JS mirror of the ring-order search added to D4_SurveyStationSites
 * in site_survey.nut. D4_EvaluateSite itself is not reproduced (it is real
 * GSTile terrain/ownership logic that cannot run outside the game) -- instead
 * `evaluate(offset, rotation, ring)` is an injectable stand-in for its {ok,
 * score, cost, needsLandscaping} contract, letting these tests drive
 * synthetic terrain (obstacles, uniform slope, etc.) through the identical
 * search/stop mirror and assert on the resulting candidate sets and how much
 * of the search space was actually visited.
 */

type SurveyCandidate = { dx: number; dy: number; rotation: number; score: number; cost: number; needsLandscaping: boolean };
type EvaluateResult = { ok: boolean; score?: number; cost?: number; needsLandscaping?: boolean };

/** Mirrors D4_RingOffsets: every {dx,dy} with |dx|+|dy| == ring, ring 0 == origin. */
function ringOffsets(ring: number): { dx: number; dy: number }[] {
  if (ring === 0) return [{ dx: 0, dy: 0 }];
  const offsets: { dx: number; dy: number }[] = [];
  for (let dx = -ring; dx <= ring; dx++) {
    const remainder = ring - Math.abs(dx);
    if (remainder === 0) offsets.push({ dx, dy: 0 });
    else {
      offsets.push({ dx, dy: remainder });
      offsets.push({ dx, dy: -remainder });
    }
  }
  return offsets;
}

/** Mirrors D4_SiteCompare. */
function siteCompare(a: SurveyCandidate, b: SurveyCandidate): number {
  if (a.score > b.score) return -1;
  if (a.score < b.score) return 1;
  if (a.cost < b.cost) return -1;
  if (a.cost > b.cost) return 1;
  return 0;
}

/** Mirrors D4_InsertRankedCandidate. */
function insertRankedCandidate(list: SurveyCandidate[], candidate: SurveyCandidate, cap: number): void {
  let i = list.length;
  list.push(candidate);
  while (i > 0 && siteCompare(list[i]!, list[i - 1]!) < 0) {
    const tmp = list[i]!;
    list[i] = list[i - 1]!;
    list[i - 1] = tmp;
    i--;
  }
  if (list.length > cap) list.pop();
}

/** Mirrors D4_RotationHasFourFlat. */
function rotationHasFourFlat(list: SurveyCandidate[], cap: number): boolean {
  if (list.length < cap) return false;
  return list.every((c) => !c.needsLandscaping);
}

/** Mirrors the ring-walking body of D4_SurveyStationSites (the part downstream
 * of D4_EvaluateSite), including the per-rotation early-stop check performed
 * once per completed ring. */
function surveyRingSearch(opts: {
  searchRadius: number;
  cap: number;
  rotations?: number;
  evaluate: (offset: { dx: number; dy: number }, rotation: number, ring: number) => EvaluateResult;
}) {
  const rotationCount = opts.rotations ?? 4;
  const perRotation: SurveyCandidate[][] = Array.from({ length: rotationCount }, () => []);
  const rotationDone = new Array(rotationCount).fill(false);
  const visited: { ring: number; dx: number; dy: number; rotation: number }[] = [];
  let ringsScanned = 0;
  for (let ring = 0; ring <= opts.searchRadius; ring++) {
    ringsScanned = ring + 1;
    for (const offset of ringOffsets(ring)) {
      for (let rotation = 0; rotation < rotationCount; rotation++) {
        if (rotationDone[rotation]) continue;
        visited.push({ ring, dx: offset.dx, dy: offset.dy, rotation });
        const result = opts.evaluate(offset, rotation, ring);
        if (result.ok) {
          insertRankedCandidate(
            perRotation[rotation]!,
            { dx: offset.dx, dy: offset.dy, rotation, score: result.score!, cost: result.cost ?? 0, needsLandscaping: result.needsLandscaping ?? false },
            opts.cap,
          );
        }
      }
    }
    let allDone = true;
    for (let rotation = 0; rotation < rotationCount; rotation++) {
      if (!rotationDone[rotation] && rotationHasFourFlat(perRotation[rotation]!, opts.cap)) rotationDone[rotation] = true;
      if (!rotationDone[rotation]) allDone = false;
    }
    if (allDone) break;
  }
  return { perRotation, visited, ringsScanned };
}

// Flat-everywhere score function matching D4_EvaluateSite's formula for a
// fixed w*h and cost of 0: score = 1000 - w*h - manhattan(offset) * 2 - (needsLandscaping ? 50 : 0) * slopedTileCount.
function flatScore(offset: { dx: number; dy: number }, wh: number): number {
  return 1000 - wh - (Math.abs(offset.dx) + Math.abs(offset.dy)) * 2;
}

test("survey ring search is deterministic: identical terrain produces identical ranked candidates every run", () => {
  const evaluate = (offset: { dx: number; dy: number }) => ({ ok: true, score: flatScore(offset, 28), needsLandscaping: false });
  const first = surveyRingSearch({ searchRadius: 6, cap: 4, evaluate });
  const second = surveyRingSearch({ searchRadius: 6, cap: 4, evaluate });
  assert.deepEqual(first.perRotation, second.perRotation);
  // Every rotation's retained list is sorted best (nearest) first.
  for (const list of first.perRotation) {
    for (let i = 1; i < list.length; i++) assert.ok(list[i - 1]!.score >= list[i]!.score);
  }
});

test("survey ring search stops each rotation as soon as four flat candidates are retained, without scanning the full policy radius", () => {
  const evaluate = (offset: { dx: number; dy: number }) => ({ ok: true, score: flatScore(offset, 28), needsLandscaping: false });
  const result = surveyRingSearch({ searchRadius: 16, cap: 4, evaluate });
  // All flat and nearby: every rotation should be satisfied within the first
  // few rings, long before the 16-ring policy radius is exhausted.
  assert.ok(result.ringsScanned < 5, `expected an early stop, scanned ${result.ringsScanned} rings`);
  for (const list of result.perRotation) {
    assert.equal(list.length, 4);
    assert.ok(list.every((c) => !c.needsLandscaping));
  }
});

test("survey ring search falls back past a blocked near ring to find flat candidates further out (obstacle fallback)", () => {
  // Every candidate within Manhattan distance 2 is obstructed (ok: false);
  // flat ground only exists from ring 3 outward.
  const evaluate = (offset: { dx: number; dy: number }) => {
    const distance = Math.abs(offset.dx) + Math.abs(offset.dy);
    if (distance <= 2) return { ok: false };
    return { ok: true, score: flatScore(offset, 28), needsLandscaping: false };
  };
  const result = surveyRingSearch({ searchRadius: 8, cap: 4, evaluate });
  for (const list of result.perRotation) {
    assert.equal(list.length, 4);
    for (const candidate of list) {
      const distance = Math.abs(candidate.dx) + Math.abs(candidate.dy);
      assert.ok(distance > 2, `candidate at distance ${distance} should have been obstructed`);
    }
  }
  // The obstructed near rings were actually visited (and rejected), not skipped.
  const visitedNear = result.visited.filter((v) => Math.abs(v.dx) + Math.abs(v.dy) <= 2);
  assert.ok(visitedNear.length > 0);
});

test("survey ring search never stops early when every candidate needs landscaping, continuing to the full policy radius", () => {
  const evaluate = (offset: { dx: number; dy: number }) => ({ ok: true, score: flatScore(offset, 28) - 50, needsLandscaping: true });
  const searchRadius = 6;
  const result = surveyRingSearch({ searchRadius, cap: 4, evaluate });
  // No rotation ever satisfies the four-flat stop condition, so every ring up
  // to and including the policy radius must have been scanned.
  assert.equal(result.ringsScanned, searchRadius + 1);
  for (const list of result.perRotation) {
    assert.equal(list.length, 4);
    assert.ok(list.every((c) => c.needsLandscaping));
    // Even though nothing stopped the search, the nearest sloped candidates
    // still win the bounded top-4 (score is still monotonic in distance).
    for (let i = 1; i < list.length; i++) assert.ok(list[i - 1]!.score >= list[i]!.score);
  }
});

/* ---------------------------------------------------------------------------
 * D4_SelectBestSitePair through-hub heading admissibility (geometry.nut's
 * 4-direction diamond: DIR_NE=0, DIR_SE=1, DIR_SW=2, DIR_NW=3, each pair of
 * adjacent directions a legal 45-degree miter, opposite directions a U-turn).
 * ------------------------------------------------------------------------- */

const DIR_NE = 0, DIR_SE = 1, DIR_SW = 2, DIR_NW = 3;

/** Mirrors D4_RotateDir. */
function rotateDir(dir: number, turns: number): number {
  return ((dir + turns) % 4 + 4) % 4;
}

/** Mirrors D4_DominantDirection. */
function dominantDirection(from: { x: number; y: number }, to: { x: number; y: number }): number {
  const dx = to.x - from.x;
  const dy = to.y - from.y;
  if (dx === 0 && dy === 0) return -1;
  if (Math.abs(dx) >= Math.abs(dy)) return dx >= 0 ? DIR_NE : DIR_SW;
  return dy >= 0 ? DIR_SE : DIR_NW;
}

/** Mirrors D4_Offset. */
function offsetPoint(p: { x: number; y: number }, dir: number, count: number): { x: number; y: number } {
  const dx = dir === DIR_NE ? 1 : dir === DIR_SW ? -1 : 0;
  const dy = dir === DIR_SE ? 1 : dir === DIR_NW ? -1 : 0;
  return { x: p.x + dx * count, y: p.y + dy * count };
}

function pointKey(p: { x: number; y: number }): string {
  return `${p.x},${p.y}`;
}

interface ThroughHubEndpoint {
  throat: { x: number; y: number };
  platform: { x: number; y: number };
  loopExitHeading: number;
  fanEntryHeading: number;
}

/** Mirrors the through_pair branch of D4_SelectBestSitePair: reject only an
 * exact U-turn, penalise (but admit) a perpendicular exit, and validate the
 * fan/merge port offset against each endpoint's own heading rather than the
 * travel direction toward the other site. */
function admitThroughHubPair(source: ThroughHubEndpoint, destination: ThroughHubEndpoint): { ok: boolean; orientationPenalty: number; reason?: string } {
  const sourceToDestination = dominantDirection(source.throat, destination.throat);
  const destinationToSource = dominantDirection(destination.throat, source.throat);
  if (source.loopExitHeading === rotateDir(sourceToDestination, 2)) return { ok: false, orientationPenalty: 0, reason: "source_reversal" };
  if (destination.loopExitHeading === rotateDir(destinationToSource, 2)) return { ok: false, orientationPenalty: 0, reason: "destination_reversal" };
  let orientationPenalty = 0;
  if (source.loopExitHeading !== sourceToDestination) orientationPenalty += 100000;
  if (destination.loopExitHeading !== destinationToSource) orientationPenalty += 100000;
  let pairedPorts = false;
  for (const sideTurns of [1, 3]) {
    const sourceSide = rotateDir(source.loopExitHeading, sideTurns);
    const destinationSide = rotateDir(destination.fanEntryHeading, sideTurns);
    if (
      pointKey(offsetPoint(source.throat, sourceSide, 1)) === pointKey(source.platform) &&
      pointKey(offsetPoint(destination.throat, destinationSide, 1)) === pointKey(destination.platform)
    ) {
      pairedPorts = true;
    }
  }
  if (!pairedPorts) return { ok: false, orientationPenalty, reason: "paired_ports" };
  return { ok: true, orientationPenalty };
}

/** The buggy pre-fix version of the same port check: it validated the fan/merge
 * offset against the travel direction toward the other site instead of each
 * endpoint's own heading. This only ever happened to hold when loop_exit_heading
 * already equaled the travel direction exactly -- i.e. it was tautological under
 * the old hard equality gate, and would have silently broken a perpendicular
 * admission if the equality gate were relaxed without also fixing this check. */
function pairedPortsUsingTravelDirection(source: ThroughHubEndpoint, destination: ThroughHubEndpoint): boolean {
  const sourceToDestination = dominantDirection(source.throat, destination.throat);
  for (const sideTurns of [1, 3]) {
    const side = rotateDir(sourceToDestination, sideTurns);
    if (
      pointKey(offsetPoint(source.throat, side, 1)) === pointKey(source.platform) &&
      pointKey(offsetPoint(destination.throat, side, 1)) === pointKey(destination.platform)
    ) {
      return true;
    }
  }
  return false;
}

// Builds a physically-consistent through-hub endpoint the way
// D4_DeriveThroughHubEndpointLayout's rotation always does: the platform port
// sits exactly one tile from the throat, offset by rotateDir(relevantHeading, 3)
// -- loop_exit_heading for an outbound (source-side) throat, fan_entry_heading
// for an inbound (destination-side) throat -- verified empirically against the
// real rotation math for every rotation 0..3 and several platform geometries.
function buildEndpoint(throat: { x: number; y: number }, loopExitHeading: number, isSourceSide: boolean): ThroughHubEndpoint {
  const fanEntryHeading = rotateDir(loopExitHeading, 2);
  const relevantHeading = isSourceSide ? loopExitHeading : fanEntryHeading;
  const platform = offsetPoint(throat, rotateDir(relevantHeading, 3), 1);
  return { throat, platform, loopExitHeading, fanEntryHeading };
}

test("through-hub site pairing rejects only an exact U-turn exit heading", () => {
  const sourceThroat = { x: 75, y: 4 };
  const destinationThroat = { x: 76, y: 9 }; // dx=1, dy=5 -> dominant DIR_SE
  const dominant = dominantDirection(sourceThroat, destinationThroat);
  assert.equal(dominant, DIR_SE);
  const reversalHeading = rotateDir(dominant, 2);
  assert.equal(reversalHeading, DIR_NW);
  const source = buildEndpoint(sourceThroat, reversalHeading, true);
  const destination = buildEndpoint(destinationThroat, rotateDir(dominant, 2), false);
  const result = admitThroughHubPair(source, destination);
  assert.equal(result.ok, false);
  assert.equal(result.reason, "source_reversal");
});

test("through-hub site pairing admits a map-edge-constrained perpendicular exit with a penalty instead of rejecting it", () => {
  // Reproduces the real gate blocker: source sits near a map edge and only
  // rotations exposing DIR_NE/DIR_SW loop_exit_headings survive, but the
  // dominant direction toward the destination is DIR_SE -- exactly perpendicular
  // to both, never equal, and never their reversal (DIR_NW) either.
  const sourceThroat = { x: 75, y: 4 };
  const destinationThroat = { x: 76, y: 9 };
  const dominant = dominantDirection(sourceThroat, destinationThroat);
  assert.equal(dominant, DIR_SE);
  for (const edgeRotationHeading of [DIR_NE, DIR_SW]) {
    assert.notEqual(edgeRotationHeading, dominant);
    assert.notEqual(edgeRotationHeading, rotateDir(dominant, 2));
    const source = buildEndpoint(sourceThroat, edgeRotationHeading, true);
    const destination = buildEndpoint(destinationThroat, rotateDir(dominant, 2), false);
    const result = admitThroughHubPair(source, destination);
    assert.equal(result.ok, true, `rotation exposing ${edgeRotationHeading} should be admitted`);
    assert.equal(result.orientationPenalty, 100000, "only the source endpoint's heading mismatches the dominant direction");
  }
});

test("through-hub site pairing scores a direct dominant-heading pair strictly better than a perpendicular one", () => {
  const sourceThroat = { x: 75, y: 4 };
  const destinationThroat = { x: 76, y: 9 };
  const dominant = dominantDirection(sourceThroat, destinationThroat);
  const destination = buildEndpoint(destinationThroat, rotateDir(dominant, 2), false);
  const direct = admitThroughHubPair(buildEndpoint(sourceThroat, dominant, true), destination);
  const perpendicular = admitThroughHubPair(buildEndpoint(sourceThroat, DIR_NE, true), destination);
  assert.equal(direct.ok, true);
  assert.equal(direct.orientationPenalty, 0);
  assert.equal(perpendicular.ok, true);
  assert.ok(perpendicular.orientationPenalty > direct.orientationPenalty);
});

test("paired-port validity must be checked against each endpoint's own heading, not the travel direction", () => {
  // buildEndpoint always produces a physically-valid port offset relative to
  // the endpoint's OWN heading (this is a fixed blueprint-rotation invariant,
  // not something that depends on where the other site is). For a
  // perpendicular pair the fixed (correct) check must still accept it, while
  // the old travel-direction-relative check -- only ever tautologically
  // correct when loop_exit_heading already equalled the travel direction --
  // must reject it, proving the two changes had to land together.
  const sourceThroat = { x: 75, y: 4 };
  const destinationThroat = { x: 76, y: 9 };
  const dominant = dominantDirection(sourceThroat, destinationThroat);
  const source = buildEndpoint(sourceThroat, DIR_NE, true);
  const destination = buildEndpoint(destinationThroat, rotateDir(dominant, 2), false);
  assert.equal(admitThroughHubPair(source, destination).ok, true);
  assert.equal(pairedPortsUsingTravelDirection(source, destination), false);
});

test("build_program.nut implements the reversal-only-reject, endpoint-relative admissible heading rule this mirror models", () => {
  const program = readFileSync(join(gameDir, "build_program.nut"), "utf8");
  const fn = program.slice(program.indexOf("function D4_SelectBestSitePair"), program.indexOf("function D4_NearestBlueprintPortPoint"));
  assert.match(fn, /if \(source_layout\.loop_exit_heading == D4_RotateDir\(source_to_destination, 2\)\) continue;/);
  assert.match(fn, /if \(destination_layout\.loop_exit_heading == D4_RotateDir\(destination_to_source, 2\)\) continue;/);
  assert.match(fn, /if \(source_layout\.loop_exit_heading != source_to_destination\) orientation_penalty \+= 100000;/);
  assert.match(fn, /if \(destination_layout\.loop_exit_heading != destination_to_source\) orientation_penalty \+= 100000;/);
  assert.match(fn, /local source_side = D4_RotateDir\(source_layout\.loop_exit_heading, side_turns\);/);
  assert.match(fn, /local destination_side = D4_RotateDir\(destination_layout\.fan_entry_heading, side_turns\);/);
  assert.match(fn, /if \(!paired_ports\) continue;/);
  // The old hard equality gate must be gone -- it's no longer a `continue`.
  assert.doesNotMatch(fn, /if \(source_layout\.loop_exit_heading != source_to_destination\) continue;/);
  assert.doesNotMatch(fn, /if \(destination_layout\.loop_exit_heading != destination_to_source\) continue;/);
});

test("site_survey.nut implements the ring-order branch-and-bound this mirror models", () => {
  const survey = readFileSync(join(gameDir, "site_survey.nut"), "utf8");
  assert.match(survey, /function D4_RingOffsets\(ring\)/);
  assert.match(survey, /function D4_InsertRankedCandidate\(list, candidate\)/);
  assert.match(survey, /function D4_RotationHasFourFlat\(list\)/);
  assert.match(survey, /if \(list\.len\(\) < DIRECTORATE_M4_MAX_SITES\) return false;/);
  assert.match(survey, /foreach \(candidate in list\) if \(candidate\.needs_landscaping\) return false;/);
  const surveyFn = survey.slice(survey.indexOf("function D4_SurveyStationSites"), survey.indexOf("function D4_EvaluateSite"));
  // Ring loop bounded by the policy radius, not an unbounded/brute-force square.
  assert.match(surveyFn, /for \(local ring = 0; ring <= search_radius; ring\+\+\)/);
  assert.match(surveyFn, /local offsets = D4_RingOffsets\(ring\);/);
  assert.match(surveyFn, /if \(rotation_done\[rotation\]\) continue;/);
  // Per-rotation early stop is only evaluated once per completed ring, and an
  // all-sloped rotation is never marked done.
  assert.match(surveyFn, /if \(!rotation_done\[rotation\] && D4_RotationHasFourFlat\(per_rotation\[rotation\]\)\) rotation_done\[rotation\] = true;/);
  assert.match(surveyFn, /if \(all_done\) break;/);
  assert.match(surveyFn, /needs_landscaping = result\.needs_landscaping,/);
});
