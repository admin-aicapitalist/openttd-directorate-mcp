import type { AdminClient } from "../admin/client.js";
import type {
  ApplyRequest,
  ChatRequest,
  ExecuteRequest,
  GatewayResponse,
  ObserveRequest,
  OpenTtdGateway,
  PlanRequest,
  RconRequest,
  VerifyRequest,
} from "./types.js";

export class AdminOpenTtdGateway implements OpenTtdGateway {
  public constructor(private readonly client: AdminClient) {}

  public async observe(request: ObserveRequest): Promise<GatewayResponse> {
    return this.forward("observe", request);
  }

  public async plan(request: PlanRequest): Promise<GatewayResponse> {
    return this.forward("plan", request);
  }

  public async apply(request: ApplyRequest): Promise<GatewayResponse> {
    return this.forward("apply", request);
  }

  public async verify(request: VerifyRequest): Promise<GatewayResponse> {
    return this.forward("verify", request);
  }

  public async execute(request: ExecuteRequest): Promise<GatewayResponse> {
    return this.forward("execute", request);
  }

  public async chat(request: ChatRequest): Promise<GatewayResponse> {
    const result = await this.client.chat(request.message);
    return {
      correlation_id: "admin-chat-unacknowledged",
      ok: false,
      payload: {
        correlated: result.correlated,
        note: "OpenTTD AdminChat has no protocol-level acknowledgement; this tool must not report success.",
      },
    };
  }

  public async rcon(request: RconRequest): Promise<GatewayResponse> {
    const response = await this.client.rcon(request.command);
    return { correlation_id: request.command, ok: true, payload: response };
  }

  public async shutdown(): Promise<void> {
    await this.client.shutdown();
  }

  private async forward(op: string, request: unknown): Promise<GatewayResponse> {
    const response = await this.client.requestGameScript(op, request);
    if (!isRecord(response.payload) || typeof response.payload.ok !== "boolean") {
      return {
        correlation_id: response.correlation_id,
        ok: false,
        payload: { error: "invalid_gamescript_response", detail: "Correlated GameScript response must contain an explicit boolean ok field" },
      };
    }
    return {
      correlation_id: response.correlation_id,
      ok: response.payload.ok,
      payload: "payload" in response.payload ? response.payload.payload : response.payload,
      error: "error" in response.payload ? response.payload.error : undefined,
    };
  }
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}
