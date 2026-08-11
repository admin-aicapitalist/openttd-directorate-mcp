export interface GatewayResponse<TPayload = unknown> {
  readonly correlation_id: string;
  readonly ok: boolean;
  readonly payload: TPayload;
  readonly error?: unknown;
}

export interface ObserveRequest {
  readonly scope: "map" | "company" | "plans" | "routes" | "economy";
  readonly company_id?: number | undefined;
  readonly route_id?: string | undefined;
  readonly limit: number;
}

export interface PlanRequest {
  readonly intent: Record<string, unknown>;
  readonly company_id: number;
  readonly policy: Record<string, unknown>;
  readonly plan_id?: string | undefined;
  readonly revision?: number | undefined;
}

export interface ApplyRequest {
  readonly company_id: number;
  readonly plan_id: string;
  readonly revision: number;
  readonly phase: "preflight" | "commit" | "rollback";
  readonly operation_id: string;
  readonly target_operation_id?: string | undefined;
  readonly reserve?: number | undefined;
}

export interface CommissionRequest {
  readonly company_id: number;
  readonly plan_id: string;
  readonly route_id: string;
  readonly cargo_label?: string | undefined;
}

export interface VerifyRequest {
  readonly company_id: number;
  readonly route_id?: string | undefined;
  readonly plan_id?: string | undefined;
  readonly operation_id?: string | undefined;
  readonly level: "topology" | "commissioning" | "economic";
}

export interface ExecuteRequest {
  readonly command: string;
  readonly company_id: number;
  readonly params: Record<string, unknown>;
}

export interface ChatRequest {
  readonly message: string;
}

export interface RconRequest {
  readonly command: string;
}

export interface OpenTtdGateway {
  observe(request: ObserveRequest): Promise<GatewayResponse>;
  plan(request: PlanRequest): Promise<GatewayResponse>;
  apply(request: ApplyRequest): Promise<GatewayResponse>;
  verify(request: VerifyRequest): Promise<GatewayResponse>;
  execute(request: ExecuteRequest): Promise<GatewayResponse>;
  chat(request: ChatRequest): Promise<GatewayResponse>;
  rcon(request: RconRequest): Promise<GatewayResponse>;
  shutdown?(): Promise<void>;
}
