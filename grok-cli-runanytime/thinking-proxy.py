#!/usr/bin/env python3
"""grok-thinking-proxy —— 剥离上游 SSE 流里缺 signature 的 thinking 块。

部分 Anthropic 兼容网关（实测：runanytime.hxi.me 的 grok-4.6）在流式
/v1/messages 里返回 {"type":"thinking"} 内容块，但不发 signature。
Grok CLI 把 signature 当必填字段，直连会报：

    serialization error: missing field `signature`

本代理只做协议修补，不改模型、不计费、不存密钥：

  1. 响应方向：丢弃 thinking / redacted_thinking 内容块，并把保留下来的
     内容块 index 重新编号成连续序列（event: 行与 data: 行成对处理）。
  2. 请求方向：剥掉 assistant 历史里的 thinking 块，避免回传给上游。

用法：

    python3 thinking-proxy.py
    # 默认 http://127.0.0.1:8899 → https://runanytime.hxi.me

再把 Grok CLI 的 grok-4.6 指到代理：

    base_url = "http://127.0.0.1:8899/v1"
    api_backend = "messages"

环境变量 PROXY_PORT / UPSTREAM_HOST 可覆盖默认值。详见同目录 README.md。
"""
import http.client
import http.server
import json
import os
import sys

UPSTREAM_HOST = os.environ.get("UPSTREAM_HOST", "runanytime.hxi.me")
PORT = int(os.environ.get("PROXY_PORT", "8899"))
DROP_TYPES = ("thinking", "redacted_thinking")
HOP_HEADERS = {"host", "content-length", "accept-encoding", "connection",
               "transfer-encoding"}

def strip_thinking_from_request(body):
    """剥掉 assistant 历史里的 thinking 块；无法解析或剥空时原样返回。"""
    try:
        payload = json.loads(body)
    except (ValueError, TypeError):
        return body
    changed = False
    for msg in payload.get("messages") or []:
        content = msg.get("content")
        if not isinstance(content, list):
            continue
        kept = [b for b in content
                if not (isinstance(b, dict) and b.get("type") in DROP_TYPES)]
        if kept and len(kept) != len(content):
            msg["content"] = kept
            changed = True
    return json.dumps(payload).encode() if changed else body


class ThinkingFilter:
    """按 content block 过滤 SSE 事件，并重排保留块的 index。"""

    def __init__(self):
        self.dropped = set()
        self.remap = {}
        self.next_index = 0

    def transform(self, event):
        """返回改写后的事件，None 表示整个事件丢弃。"""
        index = event.get("index")

        if event.get("type") == "content_block_start":
            block_type = (event.get("content_block") or {}).get("type")
            if block_type in DROP_TYPES:
                self.dropped.add(index)
                return None
            self.remap[index] = self.next_index
            self.next_index += 1

        if index is not None:
            if index in self.dropped:
                return None
            if index in self.remap:
                event["index"] = self.remap[index]
        return event


class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    server_version = "grok-thinking-proxy"

    def do_GET(self):
        self.relay("GET")

    def do_POST(self):
        self.relay("POST")

    def relay(self, method):
        length = int(self.headers.get("Content-Length") or 0)
        body = self.rfile.read(length) if length else b""
        if body:
            body = strip_thinking_from_request(body)

        headers = {k: v for k, v in self.headers.items()
                   if k.lower() not in HOP_HEADERS}
        if body:
            headers["Content-Length"] = str(len(body))

        try:
            conn = http.client.HTTPSConnection(UPSTREAM_HOST, 443, timeout=600)
            conn.request(method, self.path, body=body or None, headers=headers)
            upstream = conn.getresponse()
        except OSError as exc:
            print(f"[proxy] 上游连接失败: {exc}", file=sys.stderr)
            self.send_response(502)
            self.send_header("Content-Length", "0")
            self.end_headers()
            return

        if "text/event-stream" in (upstream.getheader("Content-Type") or "").lower():
            self.pump_sse(upstream)
        else:
            self.pump_plain(upstream)
        conn.close()

    def pump_sse(self, upstream):
        """逐事件转发 SSE，边读边写，不缓冲整个响应。"""
        self.send_response(upstream.status)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Cache-Control", "no-cache")
        self.send_header("Transfer-Encoding", "chunked")
        self.end_headers()

        flt = ThinkingFilter()
        block = []
        while True:
            raw = upstream.readline()
            if not raw:
                break
            line = raw.decode("utf-8", "replace").rstrip("\r\n")
            if line:
                block.append(line)
                continue
            self.write_chunk(self.render_event(block, flt))
            block = []
        if block:
            self.write_chunk(self.render_event(block, flt))
        self.write_terminator()

    @staticmethod
    def render_event(lines, flt):
        """整体保留、改写或丢弃一个 SSE 事件块。

        event: 行和 data: 行成对处理——丢 data 就一并丢掉 event，
        不会留下只有 event 没有 data 的畸形事件。
        """
        if not lines:
            return b""
        data_at = next((i for i, l in enumerate(lines)
                        if l.startswith("data:")), None)
        if data_at is None:
            return ("\n".join(lines) + "\n\n").encode()
        try:
            event = json.loads(lines[data_at][len("data:"):].strip())
        except ValueError:
            return ("\n".join(lines) + "\n\n").encode()
        kept = flt.transform(event)
        if kept is None:
            return b""
        lines = list(lines)
        lines[data_at] = "data: " + json.dumps(kept, ensure_ascii=False)
        return ("\n".join(lines) + "\n\n").encode()

    def write_chunk(self, payload):
        """写一个 chunk。payload 为空表示该事件被丢弃：什么都不写。

        注意不要在这里写 chunked 终止块——被丢弃的 thinking 事件会让流在
        第一个 thinking 块处提前结束，客户端只收到 message_start。
        """
        if not payload:
            return
        try:
            self.wfile.write(b"%x\r\n" % len(payload) + payload + b"\r\n")
            self.wfile.flush()
        except (BrokenPipeError, ConnectionResetError):
            pass

    def write_terminator(self):
        """上游读完后写 chunked 终止块，整个响应仅此一次。"""
        try:
            self.wfile.write(b"0\r\n\r\n")
            self.wfile.flush()
        except (BrokenPipeError, ConnectionResetError):
            pass

    def pump_plain(self, upstream):
        """非流式响应：整体读入，摘掉 content 里的 thinking 块后转发。"""
        data = upstream.read()
        content_type = upstream.getheader("Content-Type") or "application/json"
        if "json" in content_type.lower():
            data = self.filter_json_content(data)

        self.send_response(upstream.status)
        for key, value in upstream.getheaders():
            if key.lower() not in HOP_HEADERS and key.lower() != "content-type":
                self.send_header(key, value)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        try:
            self.wfile.write(data)
        except (BrokenPipeError, ConnectionResetError):
            pass

    @staticmethod
    def filter_json_content(data):
        try:
            payload = json.loads(data)
        except ValueError:
            return data
        content = payload.get("content")
        if not isinstance(content, list):
            return data
        kept = [b for b in content
                if not (isinstance(b, dict) and b.get("type") in DROP_TYPES)]
        if len(kept) == len(content):
            return data
        payload["content"] = kept
        return json.dumps(payload, ensure_ascii=False).encode()

    def log_message(self, fmt, *args):
        pass


def main():
    server = http.server.ThreadingHTTPServer(("127.0.0.1", PORT), Handler)
    print(f"[proxy] http://127.0.0.1:{PORT} → https://{UPSTREAM_HOST}",
          file=sys.stderr)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        server.shutdown()


if __name__ == "__main__":
    main()
