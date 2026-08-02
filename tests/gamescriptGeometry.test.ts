import assert from "node:assert/strict";
import test from "node:test";
import {
  DIR_NE,
  DIR_NW,
  DIR_SE,
  DIR_SW,
  adjacent,
  deriveCorridor,
  deriveThroughHubRoroGeometry,
  deriveThroughHubRoroPorts,
  directionBetween,
  directionName,
  forwardRight,
  isNinetyTurn,
  legalPrimitive,
  normalizeEndpoints,
  offset,
  rotateDirection,
  throughHubEndpointHeadings,
} from "../src/gamescript/geometry.js";

test("pure geometry direction rotations and offsets are deterministic", () => {
  assert.equal(directionName(DIR_NE), "NE");
  assert.equal(rotateDirection(DIR_NE, 1), DIR_SE);
  assert.equal(rotateDirection(DIR_NE, 2), DIR_SW);
  assert.equal(rotateDirection(DIR_NE, 3), DIR_NW);
  assert.deepEqual(offset({ x: 4, y: 5 }, DIR_SW, 3), { x: 1, y: 5 });
  assert.deepEqual(forwardRight({ x: 10, y: 20 }, DIR_NE, 3, 2), { x: 13, y: 22 });
  assert.equal(directionBetween({ x: 1, y: 1 }, { x: 1, y: 2 }), DIR_SE);
});

test("endpoint normalization and legality primitives reject unsafe turns", () => {
  assert.deepEqual(normalizeEndpoints({ x: 9, y: 1 }, { x: 2, y: 8 }), {
    start: { x: 2, y: 8 },
    goal: { x: 9, y: 1 },
    swapped: true,
  });
  assert.equal(legalPrimitive({ x: 1, y: 1 }, { x: 2, y: 1 }, { x: 3, y: 1 }), true);
  assert.equal(legalPrimitive({ x: 1, y: 1 }, { x: 2, y: 1 }, { x: 2, y: 2 }), true);
  assert.equal(isNinetyTurn({ x: 1, y: 1 }, { x: 2, y: 1 }, { x: 2, y: 2 }), true);
  assert.equal(legalPrimitive({ x: 1, y: 1 }, { x: 2, y: 1 }, { x: 1, y: 1 }), false);
});

test("paired corridor miters a legal turn without overlaps or gaps", () => {
  const corridor = deriveCorridor([
    { x: 120, y: 120 },
    { x: 121, y: 120 },
    { x: 122, y: 120 },
    { x: 123, y: 120 },
    { x: 124, y: 120 },
    { x: 124, y: 121 },
    { x: 124, y: 122 },
    { x: 124, y: 123 },
  ]);
  assert.equal(corridor.ok, true);
  assert.ok("lanes" in corridor);
  if (!("lanes" in corridor)) return;
  for (const lane of corridor.lanes) {
    for (let index = 1; index < lane.length; index += 1) assert.equal(adjacent(lane[index - 1]!, lane[index]!), true);
  }
});

test("paired one-way corridor derives lanes, throat ports, and conflicts", () => {
  const corridor = deriveCorridor(
    [
      { x: 10, y: 10 },
      { x: 11, y: 10 },
      { x: 12, y: 10 },
    ],
    1,
    "right",
  );
  assert.equal(corridor.ok, true);
  assert.deepEqual("lanes" in corridor ? corridor.lanes[0] : [], [
    { x: 10, y: 11 },
    { x: 11, y: 11 },
    { x: 12, y: 11 },
  ]);
  assert.deepEqual("ports" in corridor ? corridor.ports.merge_in : [], [
    { x: 10, y: 11 },
    { x: 10, y: 9 },
  ]);
});

test("paired corridor expands outer corners and contracts inner corners without loops", () => {
  const corridor = deriveCorridor(
    [
      { x: 120, y: 120 },
      { x: 121, y: 120 },
      { x: 122, y: 120 },
      { x: 123, y: 120 },
      { x: 124, y: 120 },
      { x: 124, y: 121 },
      { x: 124, y: 122 },
      { x: 124, y: 123 },
    ],
    1,
    "right",
  );
  assert.equal(corridor.ok, true);
  if (!("lanes" in corridor)) return;
  for (const lane of corridor.lanes) {
    assert.equal(new Set(lane.map((point) => `${point.x},${point.y}`)).size, lane.length);
    for (let index = 1; index < lane.length; index += 1) {
      assert.equal(Math.abs(lane[index]!.x - lane[index - 1]!.x) + Math.abs(lane[index]!.y - lane[index - 1]!.y), 1);
    }
  }
});

test("through-hub RoRo ports expose common inbound, all platforms, and common outbound under X/Y rotations", () => {
  assert.deepEqual(deriveThroughHubRoroPorts(2, 4, 0), {
    platformFront: [{ x: 0, y: 0 }, { x: 0, y: 1 }],
    platformRear: [{ x: 3, y: 0 }, { x: 3, y: 1 }],
    throatSw: [{ x: -1, y: 0 }, { x: -1, y: 1 }],
    throatNe: [{ x: 4, y: 0 }, { x: 4, y: 1 }],
    commonInbound: { x: -8, y: -5 },
    commonOutbound: { x: -8, y: -6 },
    commonRearMerge: { x: 6, y: -1 },
  });
  assert.deepEqual(deriveThroughHubRoroPorts(4, 7, 1, { x: 100, y: 200 }), {
    platformFront: [{ x: 100, y: 200 }, { x: 99, y: 200 }, { x: 98, y: 200 }, { x: 97, y: 200 }],
    platformRear: [{ x: 100, y: 206 }, { x: 99, y: 206 }, { x: 98, y: 206 }, { x: 97, y: 206 }],
    throatSw: [{ x: 100, y: 199 }, { x: 99, y: 199 }, { x: 98, y: 199 }, { x: 97, y: 199 }],
    throatNe: [{ x: 100, y: 207 }, { x: 99, y: 207 }, { x: 98, y: 207 }, { x: 97, y: 207 }],
    commonInbound: { x: 108, y: 187 },
    commonOutbound: { x: 109, y: 187 },
    commonRearMerge: { x: 101, y: 211 },
  });
});

function assertLegalPath(path: readonly { x: number; y: number }[], entry?: { x: number; y: number }, exit?: { x: number; y: number }) {
  assert.ok(path.length >= 2);
  for (let index = 0; index < path.length; index += 1) {
    const prev = index > 0 ? path[index - 1]! : entry;
    const next = index + 1 < path.length ? path[index + 1]! : exit;
    if (prev === undefined || next === undefined) continue;
    assert.equal(legalPrimitive(prev, path[index]!, next), true, `illegal triple at ${index}: ${JSON.stringify([prev, path[index], next])}`);
  }
}

test("through-hub RoRo deterministic fan, merge, and loop geometry is legal for 2x4 and 4x7 in all rotations", () => {
  for (const [platforms, length] of [[2, 4], [4, 7]] as const) {
    for (let rotation = 0; rotation < 4; rotation += 1) {
      const hub = deriveThroughHubRoroGeometry(platforms, length, rotation, { x: 50, y: 50 });
      assert.equal(hub.stationOverlap.length, 0);
      assert.equal(adjacent(hub.ports.commonInbound, hub.ports.commonOutbound), true);
      assert.equal(hub.fanPaths.length, platforms);
      assert.equal(hub.mergePaths.length, platforms);
      for (let row = 0; row < platforms; row += 1) {
        assert.deepEqual(hub.fanPaths[row]![0], hub.ports.commonInbound);
        assert.deepEqual(hub.fanPaths[row]!.at(-1), hub.ports.throatSw[row]);
        assert.deepEqual(hub.mergePaths[row]![0], hub.ports.throatNe[row]);
        assert.deepEqual(hub.mergePaths[row]!.at(-1), hub.ports.commonRearMerge);
        assertLegalPath(hub.fanPaths[row]!, undefined, hub.ports.platformFront[row]);
        assertLegalPath(hub.mergePaths[row]!, hub.ports.platformRear[row]);
      }
      assert.deepEqual(hub.loopPath[0], hub.ports.commonRearMerge);
      assert.deepEqual(hub.loopPath.at(-1), hub.ports.commonOutbound);
      assertLegalPath(hub.loopPath);
      assert.ok(hub.loopPath.length >= length + platforms + 2);
      assert.equal(new Set(hub.loopPath.map((point) => `${point.x},${point.y}`)).size, hub.loopPath.length);
      const fanMiter = hub.fanBackbone.slice(0, length * 2 + 1);
      const loopMiter = hub.loopPath.slice(1, length * 2 + 2);
      for (const miter of [fanMiter, loopMiter]) {
        const directions = miter.slice(1).map((point, index) => directionBetween(miter[index]!, point));
        assert.ok(directions.every((direction, index) => index === 0 || direction !== directions[index - 1]), "miter must alternate map axes instead of drawing an axis-aligned L");
      }
    }
  }
});

function dominantDirection(from: { x: number; y: number }, to: { x: number; y: number }) {
  const dx = to.x - from.x;
  const dy = to.y - from.y;
  if (Math.abs(dx) >= Math.abs(dy)) return dx >= 0 ? DIR_NE : DIR_SW;
  return dy >= 0 ? DIR_SE : DIR_NW;
}

test("through-hub endpoint headings reject the observed rotation0/rotation2 U-turn pair", () => {
  const source = deriveThroughHubRoroGeometry(2, 4, 0, { x: 14, y: 9 });
  const destination = deriveThroughHubRoroGeometry(2, 4, 2, { x: 38, y: 29 });
  const sourceHeadings = throughHubEndpointHeadings(2, 4, 0, { x: 14, y: 9 });
  const destinationHeadings = throughHubEndpointHeadings(2, 4, 2, { x: 38, y: 29 });

  assert.equal(sourceHeadings.loopExitHeading, DIR_SW);
  assert.equal(dominantDirection(source.ports.commonOutbound, destination.ports.commonInbound), DIR_NE);
  assert.notEqual(sourceHeadings.loopExitHeading, dominantDirection(source.ports.commonOutbound, destination.ports.commonInbound));
  assert.notEqual(destinationHeadings.loopExitHeading, dominantDirection(destination.ports.commonOutbound, source.ports.commonInbound));
});

test("through-hub endpoint headings pass a mirrored non-reversing pair", () => {
  const source = deriveThroughHubRoroGeometry(2, 4, 2, { x: 50, y: 50 });
  const destination = deriveThroughHubRoroGeometry(2, 4, 0, { x: 80, y: 52 });
  const sourceHeadings = throughHubEndpointHeadings(2, 4, 2, { x: 50, y: 50 });
  const destinationHeadings = throughHubEndpointHeadings(2, 4, 0, { x: 80, y: 52 });

  assert.equal(sourceHeadings.loopExitHeading, dominantDirection(source.ports.commonOutbound, destination.ports.commonInbound));
  assert.equal(destinationHeadings.loopExitHeading, dominantDirection(destination.ports.commonOutbound, source.ports.commonInbound));
  assert.equal(directionBetween(source.ports.commonInbound, source.fanBackbone[1]!), sourceHeadings.fanEntryHeading);
  assert.equal(directionBetween(destination.ports.commonInbound, destination.fanBackbone[1]!), destinationHeadings.fanEntryHeading);
});
