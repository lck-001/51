#!/usr/bin/env node

const gatewayBaseUrl = (process.env.HIVE_GATEWAY_URL || "http://127.0.0.1:8088").replace(/\/+$/, "");

const sessionCache = {
  sessionId: "",
  expiresAt: 0,
};

// MCP 客户端能看到的工具清单；真正的 SQL 安全边界仍在 Hive Gateway 服务端。
const tools = [
  {
    name: "list_hive_databases",
    description: "List Hive databases available to the configured Hive user.",
    inputSchema: { type: "object", properties: {}, additionalProperties: false },
  },
  {
    name: "list_hive_tables",
    description: "List Hive tables in a database available to the configured Hive user.",
    inputSchema: {
      type: "object",
      properties: {
        database: { type: "string" },
      },
      required: ["database"],
      additionalProperties: false,
    },
  },
  {
    name: "check_hive_sql",
    description: "Check Hive SQL safety and normalized limit. Only SELECT or WITH SELECT is allowed.",
    inputSchema: {
      type: "object",
      properties: {
        sql: { type: "string" },
        limit: { type: "integer", minimum: 1, default: 500 },
        session_id: { type: "string", default: "" },
      },
      required: ["sql"],
      additionalProperties: false,
    },
  },
  {
    name: "execute_hive_select",
    description: "Execute a controlled Hive SELECT query with limit, timeout, and concurrency checks.",
    inputSchema: {
      type: "object",
      properties: {
        sql: { type: "string" },
        limit: { type: "integer", minimum: 1, default: 500 },
        timeout_seconds: { type: "integer", minimum: 1, default: 300 },
        session_id: { type: "string", default: "" },
      },
      required: ["sql"],
      additionalProperties: false,
    },
  },
  {
    name: "search_hive_resources",
    description: "Search warehouse DDL, DML, SLA result tables, and user profile resources.",
    inputSchema: {
      type: "object",
      properties: {
        keyword: { type: "string" },
        domain: { type: "string", default: "" },
        limit: { type: "integer", minimum: 1, default: 20 },
      },
      required: ["keyword"],
      additionalProperties: false,
    },
  },
  {
    name: "get_hive_table_schema",
    description: "Get table schema and partition metadata before generating SQL.",
    inputSchema: {
      type: "object",
      properties: {
        database: { type: "string" },
        table: { type: "string" },
      },
      required: ["database", "table"],
      additionalProperties: false,
    },
  },
];

function loadCredentials() {
  // 企业客户端统一通过 MCP 配置 env 明文传入 Hive 账号密码，降低员工配置复杂度。
  const username = (process.env.HIVE_USER || process.env.HIVE_USERNAME || "").trim();
  const password = process.env.HIVE_PASSWORD || "";
  if (!username || !password) {
    throw new Error("Missing Hive credentials. Set HIVE_USER/HIVE_PASSWORD in MCP env.");
  }
  return { username, password };
}

async function gatewayPost(apiPath, payload) {
  const response = await fetch(`${gatewayBaseUrl}${apiPath}`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify(payload),
  });
  const text = await response.text();
  let data;
  try {
    data = text ? JSON.parse(text) : {};
  } catch (error) {
    throw new Error(`Gateway returned non-JSON HTTP ${response.status}: ${text}`);
  }
  if (!response.ok) {
    throw new Error(`Gateway HTTP ${response.status}: ${JSON.stringify(data)}`);
  }
  return data;
}

async function gatewayGet(apiPath) {
  const response = await fetch(`${gatewayBaseUrl}${apiPath}`);
  const text = await response.text();
  let data;
  try {
    data = text ? JSON.parse(text) : {};
  } catch (error) {
    throw new Error(`Gateway returned non-JSON HTTP ${response.status}: ${text}`);
  }
  if (!response.ok) {
    throw new Error(`Gateway HTTP ${response.status}: ${JSON.stringify(data)}`);
  }
  return data;
}

async function localSessionId() {
  // session 在 MCP Server 进程内缓存，避免每次查询都调用 /api/login。
  const now = Math.floor(Date.now() / 1000);
  if (sessionCache.sessionId && sessionCache.expiresAt - 60 > now) {
    return sessionCache.sessionId;
  }

  const loginResult = await gatewayPost("/api/login", loadCredentials());
  sessionCache.sessionId = String(loginResult.session_id);
  sessionCache.expiresAt = Number(loginResult.expires_at || now + 3600);
  return sessionCache.sessionId;
}

async function resolveSessionId(sessionId) {
  return sessionId || localSessionId();
}

async function callTool(name, args = {}) {
  // Node MCP 包只做协议转换，不直接连接 Hive。
  if (name === "list_hive_databases") {
    return gatewayPost("/api/hive/databases", { session_id: await resolveSessionId("") });
  }
  if (name === "list_hive_tables") {
    return gatewayPost("/api/hive/tables", {
      session_id: await resolveSessionId(""),
      database: args.database,
    });
  }
  if (name === "check_hive_sql") {
    return gatewayPost("/api/sql/validate", {
      session_id: await resolveSessionId(args.session_id || ""),
      sql: args.sql,
      limit: args.limit || 500,
    });
  }
  if (name === "execute_hive_select") {
    return gatewayPost("/api/sql/execute", {
      session_id: await resolveSessionId(args.session_id || ""),
      sql: args.sql,
      limit: args.limit || 500,
      timeout_seconds: args.timeout_seconds || 300,
    });
  }
  if (name === "search_hive_resources") {
    const payload = { keyword: args.keyword, limit: args.limit || 20 };
    if (args.domain) {
      payload.domain = args.domain;
    }
    return gatewayPost("/api/assets/search", payload);
  }
  if (name === "get_hive_table_schema") {
    return gatewayPost("/api/assets/table", { database: args.database, table: args.table });
  }
  throw new Error(`Unknown tool: ${name}`);
}

function writeMessage(message) {
  const body = JSON.stringify(message);
  if (lineJsonMode) {
    process.stdout.write(`${body}\n`);
    return;
  }
  // MCP stdio 使用 Content-Length 帧格式，不能直接逐行输出 JSON。
  process.stdout.write(`Content-Length: ${Buffer.byteLength(body, "utf8")}\r\n\r\n${body}`);
}

function writeResult(id, result) {
  writeMessage({ jsonrpc: "2.0", id, result });
}

function writeError(id, code, message) {
  writeMessage({ jsonrpc: "2.0", id, error: { code, message } });
}

async function handleRequest(message) {
  if (!Object.prototype.hasOwnProperty.call(message, "id")) {
    return;
  }

  try {
    if (message.method === "initialize") {
      writeResult(message.id, {
        protocolVersion: message.params?.protocolVersion || "2024-11-05",
        capabilities: { tools: {} },
        serverInfo: { name: "@51talk/hive-mcp-server", version: "0.1.5" },
      });
      return;
    }
    if (message.method === "tools/list") {
      writeResult(message.id, { tools });
      return;
    }
    if (message.method === "tools/call") {
      const result = await callTool(message.params?.name, message.params?.arguments || {});
      writeResult(message.id, {
        content: [{ type: "text", text: JSON.stringify(result, null, 2) }],
      });
      return;
    }
    writeError(message.id, -32601, `Method not found: ${message.method}`);
  } catch (error) {
    writeResult(message.id, {
      content: [{ type: "text", text: error instanceof Error ? error.message : String(error) }],
      isError: true,
    });
  }
}

let inputBuffer = Buffer.alloc(0);
let lineJsonMode = false;

process.stdin.on("data", (chunk) => {
  inputBuffer = Buffer.concat([inputBuffer, chunk]);

  while (true) {
    const trimmedStart = inputBuffer.toString("utf8", 0, Math.min(inputBuffer.length, 32)).trimStart();
    if (trimmedStart.startsWith("{")) {
      const newlineIndex = inputBuffer.indexOf("\n");
      if (newlineIndex === -1) {
        return;
      }
      const line = inputBuffer.slice(0, newlineIndex).toString("utf8").trim();
      inputBuffer = inputBuffer.slice(newlineIndex + 1);
      if (!line) {
        continue;
      }
      lineJsonMode = true;
      try {
        void handleRequest(JSON.parse(line));
      } catch (error) {
        writeError(null, -32700, error instanceof Error ? error.message : String(error));
      }
      continue;
    }

    let separator = "\r\n\r\n";
    let separatorIndex = inputBuffer.indexOf(separator);
    if (separatorIndex === -1) {
      separator = "\n\n";
      separatorIndex = inputBuffer.indexOf(separator);
    }
    if (separatorIndex === -1) {
      return;
    }

    const header = inputBuffer.slice(0, separatorIndex).toString("utf8");
    const match = /content-length:\s*(\d+)/i.exec(header);
    if (!match) {
      inputBuffer = inputBuffer.slice(separatorIndex + separator.length);
      continue;
    }

    const bodyLength = Number(match[1]);
    const bodyStart = separatorIndex + separator.length;
    const bodyEnd = bodyStart + bodyLength;
    if (inputBuffer.length < bodyEnd) {
      return;
    }

    const body = inputBuffer.slice(bodyStart, bodyEnd).toString("utf8");
    inputBuffer = inputBuffer.slice(bodyEnd);

    try {
      void handleRequest(JSON.parse(body));
    } catch (error) {
      writeError(null, -32700, error instanceof Error ? error.message : String(error));
    }
  }
});

process.stdin.resume();
