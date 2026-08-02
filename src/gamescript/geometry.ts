export type Direction = 0 | 1 | 2 | 3;

export interface Point {
  readonly x: number;
  readonly y: number;
}

export const DIR_NE = 0;
export const DIR_SE = 1;
export const DIR_SW = 2;
export const DIR_NW = 3;

const names = ["NE", "SE", "SW", "NW"] as const;

export function directionName(direction: Direction): string {
  return names[direction];
}

export function rotateDirection(direction: Direction, turns: number): Direction {
  return (((direction + turns) % 4) + 4) % 4 as Direction;
}

export function rightDirection(direction: Direction): Direction {
  return rotateDirection(direction, 1);
}

export function leftDirection(direction: Direction): Direction {
  return rotateDirection(direction, 3);
}

export function offset(point: Point, direction: Direction, count = 1): Point {
  switch (direction) {
    case DIR_NE:
      return { x: point.x + count, y: point.y };
    case DIR_SE:
      return { x: point.x, y: point.y + count };
    case DIR_SW:
      return { x: point.x - count, y: point.y };
    case DIR_NW:
      return { x: point.x, y: point.y - count };
  }
}

export function forwardRight(point: Point, direction: Direction, forward: number, right: number): Point {
  return offset(offset(point, direction, forward), rightDirection(direction), right);
}

export function adjacent(a: Point, b: Point): boolean {
  return Math.abs(a.x - b.x) + Math.abs(a.y - b.y) === 1;
}

export function directionBetween(a: Point, b: Point): Direction | undefined {
  const dx = b.x - a.x;
  const dy = b.y - a.y;
  if (dx === 1 && dy === 0) return DIR_NE;
  if (dx === 0 && dy === 1) return DIR_SE;
  if (dx === -1 && dy === 0) return DIR_SW;
  if (dx === 0 && dy === -1) return DIR_NW;
  return undefined;
}

export function normalizeEndpoints(a: Point, b: Point): { start: Point; goal: Point; swapped: boolean } {
  if (a.x < b.x || (a.x === b.x && a.y <= b.y)) return { start: a, goal: b, swapped: false };
  return { start: b, goal: a, swapped: true };
}

export function legalPrimitive(prev: Point, tile: Point, next: Point): boolean {
  if (!adjacent(prev, tile) || !adjacent(tile, next)) return false;
  const d1 = directionBetween(prev, tile);
  const d2 = directionBetween(tile, next);
  if (d1 === undefined || d2 === undefined) return false;
  return d1 === d2 || d2 !== rotateDirection(d1, 2);
}

export function isNinetyTurn(prev: Point, tile: Point, next: Point): boolean {
  const d1 = directionBetween(prev, tile);
  const d2 = directionBetween(tile, next);
  return d1 === undefined || d2 === undefined || d2 === rightDirection(d1) || d2 === leftDirection(d1);
}

export function deriveCorridor(centerline: readonly Point[], spacing = 1, handedness: "left" | "right" = "right") {
  if (centerline.length < 2 || centerline.length > 1024) return { ok: false, error: "invalid_centerline" as const };
  const side = handedness === "left" ? -spacing : spacing;
  const laneA: Point[] = [];
  const laneB: Point[] = [];
  const seen = new Set<string>();
  const conflicts: string[] = [];
  const append = (lane: Point[], point: Point) => {
    if (lane.at(-1)?.x === point.x && lane.at(-1)?.y === point.y) return;
    const key = `${point.x},${point.y}`;
    if (seen.has(key)) conflicts.push(key);
    seen.add(key);
    lane.push(point);
  };
  const appendAt = (index: number, laneSide: number, lane: Point[]) => {
    const incoming = index > 0 ? directionBetween(centerline[index - 1]!, centerline[index]!) : undefined;
    const outgoing = index + 1 < centerline.length ? directionBetween(centerline[index]!, centerline[index + 1]!) : undefined;
    if (incoming === undefined && outgoing === undefined) return false;
    if (incoming === undefined) {
      append(lane, offset(centerline[index]!, rightDirection(outgoing!), laneSide));
      return true;
    }
    if (outgoing === undefined || incoming === outgoing) {
      append(lane, offset(centerline[index]!, rightDirection(incoming), laneSide));
      return true;
    }
    if (outgoing === rotateDirection(incoming, 2)) return false;
    const turnRight = outgoing === rightDirection(incoming);
    const inside = (turnRight && laneSide > 0) || (!turnRight && laneSide < 0);
    const incomingPoint = offset(centerline[index]!, rightDirection(incoming), laneSide);
    const outgoingPoint = offset(centerline[index]!, rightDirection(outgoing), laneSide);
    const corner = offset(incomingPoint, rightDirection(outgoing), laneSide);
    if (inside) {
      append(lane, corner);
    } else {
      append(lane, incomingPoint);
      append(lane, corner);
      append(lane, outgoingPoint);
    }
    return true;
  };
  for (let i = 0; i < centerline.length; i += 1) {
    if (!appendAt(i, side, laneA) || !appendAt(i, -side, laneB)) return { ok: false, error: "non_adjacent_centerline" as const };
  }
  return {
    ok: conflicts.length === 0,
    lanes: [laneA, laneB] as const,
    ports: { merge_in: [laneA[0], laneB[0]], split_out: [laneA.at(-1), laneB.at(-1)], handedness, spacing },
    conflicts,
  };
}

export function rotatePoint(point: Point, rotation: number, origin: Point = { x: 0, y: 0 }): Point {
  const turns = ((rotation % 4) + 4) % 4;
  const dx = point.x;
  const dy = point.y;
  if (turns === 1) return { x: origin.x - dy, y: origin.y + dx };
  if (turns === 2) return { x: origin.x - dx, y: origin.y - dy };
  if (turns === 3) return { x: origin.x + dy, y: origin.y - dx };
  return { x: origin.x + dx, y: origin.y + dy };
}

export function deriveThroughHubRoroPorts(numPlatforms: number, platformLength: number, rotation = 0, origin: Point = { x: 0, y: 0 }) {
  return deriveThroughHubRoroGeometry(numPlatforms, platformLength, rotation, origin).ports;
}

export function throughHubEndpointHeadings(numPlatforms: number, platformLength: number, rotation = 0, origin: Point = { x: 0, y: 0 }) {
  const hub = deriveThroughHubRoroGeometry(numPlatforms, platformLength, rotation, origin);
  return {
    loopExitHeading: directionBetween(hub.loopPath.at(-2)!, hub.ports.commonOutbound),
    fanEntryHeading: directionBetween(hub.ports.commonInbound, hub.fanBackbone[1]!),
  };
}

function appendPoint(path: Point[], point: Point) {
  const last = path.at(-1);
  if (last?.x === point.x && last.y === point.y) return;
  path.push(point);
}

function pathKeys(paths: readonly (readonly Point[])[]) {
  return new Set(paths.flat().map((point) => `${point.x},${point.y}`));
}

export function deriveThroughHubRoroGeometry(numPlatforms: number, platformLength: number, rotation = 0, origin: Point = { x: 0, y: 0 }) {
  const curveClearance = platformLength;
  const platformFront: Point[] = [];
  const platformRear: Point[] = [];
  const throatSw: Point[] = [];
  const throatNe: Point[] = [];
  const join: Point[] = [];
  const mergeJoin: Point[] = [];
  for (let track = 0; track < numPlatforms; track += 1) {
    platformFront.push(rotatePoint({ x: 0, y: track }, rotation, origin));
    platformRear.push(rotatePoint({ x: platformLength - 1, y: track }, rotation, origin));
    throatSw.push(rotatePoint({ x: -1, y: track }, rotation, origin));
    throatNe.push(rotatePoint({ x: platformLength, y: track }, rotation, origin));
    join.push(rotatePoint({ x: -numPlatforms - 1 + track, y: track }, rotation, origin));
    mergeJoin.push(rotatePoint({ x: platformLength + numPlatforms - 1 - track, y: track }, rotation, origin));
  }
  const commonInbound = rotatePoint({ x: -numPlatforms - 2 - curveClearance, y: -1 - curveClearance }, rotation, origin);
  const commonOutbound = rotatePoint({ x: -numPlatforms - 2 - curveClearance, y: -2 - curveClearance }, rotation, origin);
  const commonRearMerge = rotatePoint({ x: platformLength + numPlatforms, y: -1 }, rotation, origin);
  const fanBackbone: Point[] = [];
  appendPoint(fanBackbone, commonInbound);
  for (let step = curveClearance - 1; step >= 0; step -= 1) {
    appendPoint(fanBackbone, rotatePoint({ x: -numPlatforms - 2 - step, y: -2 - step }, rotation, origin));
    appendPoint(fanBackbone, rotatePoint({ x: -numPlatforms - 2 - step, y: -1 - step }, rotation, origin));
  }
  for (let index = 0; index < numPlatforms; index += 1) {
    if (index === 0) {
      appendPoint(fanBackbone, rotatePoint({ x: -numPlatforms - 1, y: -1 }, rotation, origin));
      appendPoint(fanBackbone, rotatePoint({ x: -numPlatforms - 1, y: 0 }, rotation, origin));
    } else {
      appendPoint(fanBackbone, rotatePoint({ x: -numPlatforms - 1 + index, y: index - 1 }, rotation, origin));
      appendPoint(fanBackbone, rotatePoint({ x: -numPlatforms - 1 + index, y: index }, rotation, origin));
    }
  }
  const mergeBackbone: Point[] = [];
  for (let index = numPlatforms - 1; index >= 0; index -= 1) {
    if (index === numPlatforms - 1) appendPoint(mergeBackbone, mergeJoin[index]!);
    if (index > 0) {
      appendPoint(mergeBackbone, rotatePoint({ x: platformLength + numPlatforms - index, y: index }, rotation, origin));
      appendPoint(mergeBackbone, rotatePoint({ x: platformLength + numPlatforms - index, y: index - 1 }, rotation, origin));
    } else {
      appendPoint(mergeBackbone, rotatePoint({ x: platformLength + numPlatforms, y: 0 }, rotation, origin));
      appendPoint(mergeBackbone, commonRearMerge);
    }
  }
  const fanPaths = Array.from({ length: numPlatforms }, (_, row) => {
    const path: Point[] = [];
    for (const point of fanBackbone) {
      appendPoint(path, point);
      if (point.x === join[row]!.x && point.y === join[row]!.y) break;
    }
    for (let x = -numPlatforms + row; x <= -1; x += 1) appendPoint(path, rotatePoint({ x, y: row }, rotation, origin));
    return path;
  });
  const mergePaths = Array.from({ length: numPlatforms }, (_, row) => {
    const path: Point[] = [];
    for (let x = platformLength; x <= platformLength + numPlatforms - 1 - row; x += 1) appendPoint(path, rotatePoint({ x, y: row }, rotation, origin));
    let onBackbone = false;
    for (const point of mergeBackbone) {
      if (point.x === mergeJoin[row]!.x && point.y === mergeJoin[row]!.y) onBackbone = true;
      if (onBackbone) appendPoint(path, point);
    }
    return path;
  });
  const loopPath: Point[] = [commonRearMerge, rotatePoint({ x: platformLength + numPlatforms, y: -2 }, rotation, origin)];
  for (let step = 1; step <= curveClearance; step += 1) {
    appendPoint(loopPath, rotatePoint({ x: platformLength + numPlatforms - step, y: -1 - step }, rotation, origin));
    appendPoint(loopPath, rotatePoint({ x: platformLength + numPlatforms - step, y: -2 - step }, rotation, origin));
  }
  for (let x = platformLength + numPlatforms - curveClearance - 1; x >= -numPlatforms - 2 - curveClearance; x -= 1) {
    appendPoint(loopPath, rotatePoint({ x, y: -2 - curveClearance }, rotation, origin));
  }
  const station = new Set<string>();
  for (let y = 0; y < numPlatforms; y += 1) {
    for (let x = 0; x < platformLength; x += 1) station.add(`${rotatePoint({ x, y }, rotation, origin).x},${rotatePoint({ x, y }, rotation, origin).y}`);
  }
  const fanMergeLoop = pathKeys([...fanPaths, ...mergePaths, loopPath]);
  const overlap = [...station].filter((key) => fanMergeLoop.has(key));
  const envelope: Point[] = [];
  for (let x = -numPlatforms - 2 - curveClearance; x <= platformLength + numPlatforms; x += 1) {
    for (let y = -2 - curveClearance; y <= numPlatforms; y += 1) envelope.push(rotatePoint({ x, y }, rotation, origin));
  }
  return {
    ports: { platformFront, platformRear, throatSw, throatNe, commonInbound, commonOutbound, commonRearMerge },
    join,
    mergeJoin,
    fanBackbone,
    mergeBackbone,
    fanPaths,
    mergePaths,
    loopPath,
    envelope,
    stationOverlap: overlap,
  };
}
