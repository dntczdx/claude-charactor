#!/usr/bin/env node
// 克劳德大小姐 · MCP 服务器
// Claude 桌面版通过 stdio 调用这里的 notify 工具；本服务器把事件转发给桌宠 app（本机 HTTP），
// 如果是提问，就长轮询等用户在气泡里的回答，再作为工具结果交还给 Claude。

import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import { z } from "zod";

const BASE = (process.env.CLAUDEGIRL_URL || "http://127.0.0.1:47333").replace(/\/$/, "");
// 这个 MCP 服务器被哪只桌宠用：claude（默认）或 codex；由安装脚本通过环境变量设置
const AGENT = (process.env.PET_AGENT || "claude").toLowerCase() === "codex" ? "codex" : "claude";
const PET_NAME = AGENT === "codex" ? "GPT 龙娘" : "克劳德大小姐";
// Claude 桌面版大约 60s 会掐断工具调用，所以最多等 48s
const WAIT_SECONDS = Math.min(Math.max(Number(process.env.CLAUDEGIRL_WAIT || 48), 5), 55);

function text(t) {
  return { content: [{ type: "text", text: t }] };
}

async function postJSON(path, body, timeoutMs = 3000) {
  const r = await fetch(BASE + path, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify(body),
    signal: AbortSignal.timeout(timeoutMs),
  });
  if (!r.ok) throw new Error(`HTTP ${r.status}`);
  return r.json();
}

async function waitAnswer(id, seconds) {
  const r = await fetch(`${BASE}/wait?id=${encodeURIComponent(id)}&timeout=${seconds}`, {
    signal: AbortSignal.timeout((seconds + 8) * 1000),
  });
  if (!r.ok) throw new Error(`HTTP ${r.status}`);
  return r.json();
}

const server = new McpServer(
  { name: AGENT === "codex" ? "codex-girl" : "claude-girl", version: "0.2.0" },
  {
    instructions:
      `桌面上有一只叫「${PET_NAME}」的桌宠，替用户盯着所有对话。` +
      "先在对话里正常写完完整的回复，notify 只是最后附带的通知摘要，绝不能用 notify 代替回复正文。" +
      "回复写完后的最后一步调用 notify：topic 是这条对话的主题（几个字，前后保持一致），" +
      "headline 是一句话结论，points 最多三条要点。如果你需要用户做决定，填 question，能给选项就给 options（2–4 个）；" +
      "工具会把用户在气泡里的回答直接返回给你。出错或被卡住时 kind 填 error。",
  }
);

server.registerTool(
  "notify",
  {
    title: "通知桌面上的克劳德大小姐",
    description:
      "把这一轮回复的结论通知给桌面上的桌宠，用户不盯着 Claude 窗口也能看到。" +
      "顺序必须是：先在对话里写完完整的回复，再调用它；它只是已写回复的摘要，绝不能代替回复。" +
      "对话里还没有正文时调用会被拒绝（返回 ⚠️），届时请先写回复再调。" +
      "如果附带 question（可加 options），工具会等用户在气泡里点选项或打字，" +
      "并把回答作为结果返回；等不到会返回提示，届时请结束本轮，用户稍后的回答会以新消息到达。",
    inputSchema: {
      topic: z.string().min(1).max(40).describe("这条对话的主题，几个字；同一对话每次保持一致，例如「登录页表单校验」"),
      headline: z.string().min(1).max(80).describe("一句话结论，例如「登录页校验改好了，3 个测试全过」"),
      points: z.array(z.string().max(80)).max(3).optional().describe("最多三条要点，每条一行"),
      question: z.string().max(120).optional().describe("需要用户决定的问题；没有就不填"),
      options: z.array(z.string().max(40)).min(2).max(4).optional().describe("问题的候选答案，2–4 个，第一个放推荐项"),
      kind: z.enum(["done", "ask", "error"]).optional().describe("done 完成（默认）、ask 需要回答、error 出错"),
    },
  },
  async (args) => {
    const isQuestion = Boolean(args.question || (args.options && args.options.length > 0));
    const payload = {
      topic: args.topic,
      headline: args.headline,
      points: args.points || [],
      question: args.question || undefined,
      options: args.options || undefined,
      needs_input: isQuestion && !(args.options && args.options.length > 0),
      kind: args.kind || (isQuestion ? "ask" : "done"),
      agent: AGENT,
    };

    let res;
    try {
      res = await postJSON("/notify", payload);
      console.error(`[claude-girl] notify topic=${payload.topic} kind=${payload.kind} id=${res && res.id}`);
    } catch (e) {
      console.error(`[claude-girl] notify 失败: ${e && e.message}`);
      return text(`（桌宠 app 没在运行或没连上 ${BASE}，这次没通知到；不影响你继续。）`);
    }

    if (res && res.rejected) {
      console.error(`[claude-girl] notify 被拒：对话正文只有 ${res.replyChars} 字`);
      return text(
        `⚠️ 这次通知没有发出：对话里还没有写回复（桌宠只看到 ${res.replyChars} 字正文），` +
          "而通知里却带着结论。用户看的是对话，不是通知。请现在先在对话里写出完整的回复，写完之后再调用一次 notify。"
      );
    }

    if (!isQuestion) {
      return text(`已通知${PET_NAME}。（这只是通知；如果完整回复还没写在对话里，请现在写出来。）`);
    }

    try {
      console.error(`[claude-girl] wait id=${res.id} ${WAIT_SECONDS}s`);
      const w = await waitAnswer(res.id, WAIT_SECONDS);
      console.error(`[claude-girl] wait 结果 ${JSON.stringify(w)}`);
      if (w && w.answered && typeof w.answer === "string" && w.answer.trim()) {
        return text(`用户在气泡里回答：${w.answer.trim()}\n请据此直接继续，不必再确认。`);
      }
    } catch (e) {
      console.error(`[claude-girl] wait 异常: ${e && e.message}`);
    }
    return text(
      "用户暂时没在气泡里回答。请结束这一轮回复，用一两句话说明你在等什么；" +
        "用户稍后的回答会由大小姐帮忙填进这条对话，作为新消息到达。"
    );
  }
);

const transport = new StdioServerTransport();
await server.connect(transport);
