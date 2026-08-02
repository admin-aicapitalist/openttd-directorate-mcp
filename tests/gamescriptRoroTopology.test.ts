import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";
import {
  DIR_NE,
  DIR_SE,
  DIR_SW,
  DIR_NW,
  adjacent,
  deriveThroughHubRoroGeometry,
  directionBetween,
  legalPrimitive,
} from "../src/gamescript/geometry.js";

type Point = { x: number; y: number };
type Primitive = { prev: string; tile: string; next: string };

const key = (p: Point) => `${p.x},${p.y}`;

function reverse(dir: 0 | 1 | 2 | 3): 0 | 1 | 2 | 3 {
  return ((dir + 2) % 4) as 0 | 1 | 2 | 3;
}

function stepInDirection(point: Point, dir: 0 | 1 | 2 | 3): Point {
  if (dir === DIR_NE) return { x: point.x + 1, y: point.y };
  if (dir === DIR_SE) return { x: point.x, y: point.y + 1 };
  if (dir === DIR_SW) return { x: point.x - 1, y: point.y };
  return { x: point.x, y: point.y - 1 };
}

function collectPrimitives(
  paths: readonly (readonly Point[])[],
  entryExit: { entry?: Point | undefined; exit?: Point | undefined }[],
) {
  const seen = new Set<string>();
  const primitives: Primitive[] = [];
  paths.forEach((path, index) => {
    if (path.length < 2) return;
    const meta = entryExit[index] ?? {};
    for (let i = 0; i < path.length; i += 1) {
      let prev = i > 0 ? path[i - 1]! : meta.entry;
      let next = i + 1 < path.length ? path[i + 1]! : meta.exit;
      if (prev === undefined) {
        const outDir = directionBetween(path[i]!, path[i + 1]!);
        if (outDir === undefined) continue;
        prev = stepInDirection(path[i]!, reverse(outDir));
      }
      if (next === undefined) {
        const inDir = directionBetween(path[i - 1]!, path[i]!);
        if (inDir === undefined) continue;
        next = stepInDirection(path[i]!, inDir);
      }
      const k = `${key(prev)}|${key(path[i]!)}|${key(next)}`;
      if (seen.has(k)) continue;
      seen.add(k);
      assert.equal(legalPrimitive(prev, path[i]!, next), true, `illegal emitted primitive at path ${index}/${i}`);
      primitives.push({ prev: key(prev), tile: key(path[i]!), next: key(next) });
    }
  });
  return primitives;
}

function forwardReachable(primitives: readonly Primitive[], startEdge: { from: string; to: string }, goalTiles: ReadonlySet<string>) {
  const outgoing = new Map<string, Set<string>>();
  for (const p of primitives) {
    const arc = `${p.prev}->${p.tile}`;
    const successor = `${p.tile}->${p.next}`;
    let bucket = outgoing.get(arc);
    if (!bucket) {
      bucket = new Set();
      outgoing.set(arc, bucket);
    }
    bucket.add(successor);
  }
  const seed = `${startEdge.from}->${startEdge.to}`;
  const visitedArcs = new Set<string>([seed]);
  const queue: string[] = [seed];
  const visitedTiles = new Set<string>([startEdge.to]);
  while (queue.length > 0) {
    const arc = queue.shift()!;
    const next = outgoing.get(arc);
    if (!next) continue;
    for (const succ of next) {
      if (visitedArcs.has(succ)) continue;
      visitedArcs.add(succ);
      const tile = succ.split("->")[1]!;
      visitedTiles.add(tile);
      queue.push(succ);
    }
  }
  const missing = [...goalTiles].filter((tile) => !visitedTiles.has(tile));
  return { visitedTiles, missing };
}

function stationInternalPrimitives(platformFront: readonly Point[], platformRear: readonly Point[]) {
  const primitives: Primitive[] = [];
  for (let row = 0; row < platformFront.length; row += 1) {
    const front = platformFront[row]!;
    const rear = platformRear[row]!;
    const dx = rear.x - front.x;
    const dy = rear.y - front.y;
    const steps = Math.abs(dx) + Math.abs(dy);
    const stepX = steps === 0 ? 0 : dx / steps;
    const stepY = steps === 0 ? 0 : dy / steps;
    const forward = directionBetween(front, { x: front.x + stepX, y: front.y + stepY });
    assert.notEqual(forward, undefined, "platform axis must be a cardinal direction");
    const path: Point[] = [];
    for (let i = 0; i <= steps; i += 1) path.push({ x: front.x + stepX * i, y: front.y + stepY * i });
    for (let i = 0; i < path.length; i += 1) {
      const prev = i > 0 ? path[i - 1]! : { x: front.x - stepX, y: front.y - stepY };
      const next = i + 1 < path.length ? path[i + 1]! : { x: rear.x + stepX, y: rear.y + stepY };
      primitives.push({ prev: key(prev), tile: key(path[i]!), next: key(next) });
    }
  }
  return primitives;
}

function assertRoroGraph(numPlatforms: number, platformLength: number, rotation: 0 | 1 | 2 | 3, origin: Point) {
  const hub = deriveThroughHubRoroGeometry(numPlatforms, platformLength, rotation, origin);
  const inboundEntryExit = hub.fanPaths.map((_, row) => ({
    entry: undefined,
    exit: hub.ports.platformFront[row]!,
  }));
  const outboundEntryExit = hub.mergePaths.map((_, row) => ({
    entry: hub.ports.platformRear[row]!,
    exit: undefined,
  }));
  const loopEntryExit = [{ entry: undefined, exit: undefined }];
  const fanPrimitives = collectPrimitives(hub.fanPaths, inboundEntryExit);
  const mergePrimitives = collectPrimitives(hub.mergePaths, outboundEntryExit);
  const loopPrimitives = collectPrimitives([hub.loopPath], loopEntryExit);
  const platformPrimitives = stationInternalPrimitives(hub.ports.platformFront, hub.ports.platformRear);

  const commonInbound = hub.ports.commonInbound;
  const commonOutbound = hub.ports.commonOutbound;
  const commonRearMerge = hub.ports.commonRearMerge;

  const emittedFanEntries = fanPrimitives.filter((p) => p.tile === key(commonInbound));
  assert.equal(
    new Set(emittedFanEntries.map((p) => p.next)).size,
    1,
    `commonInbound must have exactly one forward successor (rejects per-lane trunk identity)`,
  );
  const fanFirstSuccessor = emittedFanEntries[0]!.next;

  const emittedMergeSinks = mergePrimitives.filter((p) => p.tile === key(commonRearMerge));
  assert.equal(
    new Set(emittedMergeSinks.map((p) => p.prev)).size,
    1,
    `commonRearMerge must have exactly one forward predecessor (rejects per-lane fan-in identity)`,
  );

  const fanTiles = new Set(fanPrimitives.map((p) => p.tile));
  const backboneShared = hub.fanBackbone.slice(0, 2).map(key);
  for (const b of backboneShared) {
    assert.ok(fanTiles.has(b), `shared fan backbone tile ${b} must appear in fan primitives`);
  }

  const inbound = forwardReachable(
    [...fanPrimitives, ...platformPrimitives, ...mergePrimitives, ...loopPrimitives],
    { from: key(commonInbound), to: fanFirstSuccessor },
    new Set(hub.ports.platformFront.map(key)),
  );
  assert.deepEqual(
    inbound.missing,
    [],
    `every platform_front must be forward-reachable from ONE commonInbound: missing ${inbound.missing.join(",")}`,
  );

  for (let row = 0; row < numPlatforms; row += 1) {
    const rear = hub.ports.platformRear[row]!;
    const throatNe = hub.ports.throatNe[row]!;
    const outbound = forwardReachable(
      [...mergePrimitives, ...loopPrimitives],
      { from: key(rear), to: key(throatNe) },
      new Set([key(commonRearMerge)]),
    );
    assert.deepEqual(
      outbound.missing,
      [],
      `platform_rear[${row}] must reach commonRearMerge forward-only`,
    );
  }

  const loopStart = hub.loopPath[1]!;
  const loop = forwardReachable(loopPrimitives, { from: key(commonRearMerge), to: key(loopStart) }, new Set([key(commonOutbound)]));
  assert.deepEqual(loop.missing, [], `loopPath must reach commonOutbound forward-only`);

  for (let row = 0; row < numPlatforms; row += 1) {
    const front = hub.ports.platformFront[row]!;
    const rear = hub.ports.platformRear[row]!;
    const throatSw = hub.ports.throatSw[row]!;
    const throatNe = hub.ports.throatNe[row]!;
    const forwardAxis = directionBetween(throatSw, front);
    assert.notEqual(forwardAxis, undefined);
    assert.equal(directionBetween(rear, throatNe), forwardAxis, `row ${row} exit heading must match forward axis (no reverse)`);
  }

  const inboundAdjacent = hub.fanPaths.map((path) => key((path[1] ?? path[0])!));
  assert.equal(new Set(inboundAdjacent).size, 1, `every fan path must share the first hop from commonInbound (no per-lane trunk)`);
  const rearAdjacent = hub.mergePaths.map((path) => key((path[path.length - 2] ?? path[0])!));
  assert.equal(new Set(rearAdjacent).size, 1, `every merge path must share the last hop into commonRearMerge (no per-lane fan-in)`);
}

test("through-hub RoRo emitted primitives form a single-source fan reaching every platform", () => {
  for (const [platforms, length] of [[2, 4], [4, 7]] as const) {
    for (const rotation of [0, 1, 2, 3] as const) {
      assertRoroGraph(platforms, length, rotation, { x: 60 + rotation * 5, y: 80 + rotation * 5 });
    }
  }
});

test("through-hub RoRo emitted primitives form a single-sink merge collecting every platform", () => {
  for (const [platforms, length] of [[2, 4], [4, 7]] as const) {
    for (const rotation of [0, 1, 2, 3] as const) {
      const hub = deriveThroughHubRoroGeometry(platforms, length, rotation, { x: 120, y: 140 });
      const mergePrimitives = collectPrimitives(
        hub.mergePaths,
        hub.mergePaths.map((_, row) => ({ entry: hub.ports.platformRear[row]!, exit: undefined })),
      );
      const commonRearMerge = hub.ports.commonRearMerge;
      const reachedFromEachPlatform = hub.ports.platformRear.map((rear, row) => {
        const throat = hub.ports.throatNe[row]!;
        const reach = forwardReachable(mergePrimitives, { from: key(rear), to: key(throat) }, new Set([key(commonRearMerge)]));
        return reach.missing.length === 0;
      });
      assert.ok(reachedFromEachPlatform.every(Boolean), `every platform_rear must reach commonRearMerge in ${platforms}x${length} rotation ${rotation}`);
    }
  }
});

test("through-hub RoRo trunk primitives cannot masquerade as N per-platform lanes", () => {
  const hub = deriveThroughHubRoroGeometry(4, 7, 0, { x: 200, y: 250 });
  const fanPrimitives = collectPrimitives(
    hub.fanPaths,
    hub.fanPaths.map((_, row) => ({ entry: undefined, exit: hub.ports.platformFront[row]! })),
  );
  const outgoingFromCommonInbound = new Set(
    fanPrimitives.filter((p) => p.tile === key(hub.ports.commonInbound)).map((p) => p.next),
  );
  assert.equal(outgoingFromCommonInbound.size, 1);
  const outgoingSuccessor = [...outgoingFromCommonInbound][0]!;
  const sharedTile = fanPrimitives.filter((p) => p.tile === outgoingSuccessor);
  assert.ok(sharedTile.length >= 1, `shared fan first hop must exist`);
  const distinctNexts = new Set(sharedTile.map((p) => p.next));
  assert.ok(
    distinctNexts.size <= 2,
    `first shared hop out of commonInbound must not fan into ${hub.ports.platformFront.length} directions (would indicate per-lane trunks)`,
  );
});

test("Squirrel derivation mirrors TypeScript backbone/join geometry (no divergence between planner and blueprint)", () => {
  const squirrel = readFileSync("game/openttd_directorate/build_program.nut", "utf8");
  assert.match(squirrel, /D4_AppendUniqueLaneOperations\(ops, prefix \+ "\.fan\." \+ i, fan, null, front, emitted_rails\)/);
  assert.match(squirrel, /D4_AppendUniqueLaneOperations\(ops, prefix \+ "\.merge\." \+ i, merge, rear, null, emitted_rails\)/);
  assert.match(squirrel, /D4_AppendUniqueLaneOperations\(ops, prefix \+ "\.loop", layout\.loop_path/);
  assert.match(squirrel, /D4_AppendPointIfNew\(fan_backbone, common_inbound\);/);
  assert.match(squirrel, /for \(local entry_step = platform_length - 1; entry_step >= 0; entry_step--\)/);
  assert.match(squirrel, /D4_AppendPointIfNew\(fan_backbone, D4_RotateBlueprintPoint\(blueprint, \{ x = -platform_count - 1, y = -1 \}\)\);/);
  assert.match(squirrel, /D4_AppendPointIfNew\(fan_backbone, D4_RotateBlueprintPoint\(blueprint, \{ x = -platform_count - 1, y = 0 \}\)\);/);
  assert.match(squirrel, /if \(D4_PointKey\(fan_backbone\[fi\]\) == D4_PointKey\(join\[row\]\)\) break;/);
  assert.match(squirrel, /if \(m == platform_count - 1\) D4_AppendPointIfNew\(merge_backbone, merge_join\[m\]\);/);
  assert.match(squirrel, /D4_AppendPointIfNew\(merge_backbone, common_rear_merge\);/);
  assert.match(squirrel, /local loop_path = \[common_rear_merge, D4_RotateBlueprintPoint\(blueprint, \{ x = platform_length \+ platform_count, y = -2 \}\)\];/);
  assert.match(squirrel, /for \(local loop_step = 1; loop_step <= platform_length; loop_step\+\+\)/);
  assert.match(squirrel, /D4_BuildLegalCenterline\(source_out, dest_in, plan\.company_id, plan\.policy, source_manifest\.manifest\.loop_exit_heading, dest_manifest\.manifest\.fan_entry_heading, 4, 50, turn_clearance, true, dest_out, source_in, dest_manifest\.manifest\.loop_exit_heading, source_manifest\.manifest\.fan_entry_heading\)/);
});

test("through-hub endpoint manifest emits per-row entries whose paths originate at ONE commonInbound", () => {
  const build = readFileSync("game/openttd_directorate/build_program.nut", "utf8");
  assert.match(build, /if \(D4_PointKey\(entry\.path\[0\]\) != D4_PointKey\(endpoint\.common_inbound\)\) failures\.append\(\{ op_id = prefix, reason = "entry_not_common_inbound" \}\);/);
  assert.match(build, /if \(D4_Has\(endpoint, "common_rear_merge"\) && D4_PointKey\(exitp\.path\[exitp\.path\.len\(\) - 1\]\) != D4_PointKey\(endpoint\.common_rear_merge\)\) failures\.append\(\{ op_id = prefix, reason = "exit_not_common_rear_merge" \}\);/);
  assert.match(build, /function D4_VerifyThroughHubRoroReachability/);
  assert.match(build, /reachability_platform_front_unreachable/);
  assert.match(build, /reachability_platform_rear_unreachable/);
  assert.match(build, /reachability_common_outbound_unreachable/);
});
