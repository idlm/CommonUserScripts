#!/usr/bin/env python3
"""thinking-proxy 过滤逻辑的离线验证。"""
import importlib.util
import json
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("tp", HERE / "thinking-proxy.py")
tp = importlib.util.module_from_spec(spec)
spec.loader.exec_module(tp)

# 复刻 relay 的真实事件序列：index 0 是缺 signature 的 thinking，
# 后面跟 text(1) 和 tool_use(2)。
RAW = [
    ("message_start", {"type": "message_start", "message": {"role": "assistant"}}),
    ("content_block_start", {"type": "content_block_start", "index": 0,
                             "content_block": {"type": "thinking", "thinking": ""}}),
    ("content_block_delta", {"type": "content_block_delta", "index": 0,
                             "delta": {"type": "thinking_delta", "thinking": "The"}}),
    ("content_block_stop", {"type": "content_block_stop", "index": 0}),
    ("content_block_start", {"type": "content_block_start", "index": 1,
                             "content_block": {"type": "text", "text": ""}}),
    ("content_block_delta", {"type": "content_block_delta", "index": 1,
                             "delta": {"type": "text_delta", "text": "Hi"}}),
    ("content_block_stop", {"type": "content_block_stop", "index": 1}),
    ("content_block_start", {"type": "content_block_start", "index": 2,
                             "content_block": {"type": "tool_use", "id": "t1",
                                               "name": "read_file", "input": {}}}),
    ("content_block_stop", {"type": "content_block_stop", "index": 2}),
    ("message_delta", {"type": "message_delta", "delta": {"stop_reason": "tool_use"}}),
    ("message_stop", {"type": "message_stop"}),
]

flt = tp.ThinkingFilter()
emitted = []
for name, payload in RAW:
    lines = [f"event: {name}", "data: " + json.dumps(payload)]
    out = tp.Handler.render_event(lines, flt)
    if out:
        emitted.append(out.decode())

joined = "".join(emitted)
failures = []

# 1) thinking 块的三个事件必须全部消失
if "thinking" in joined:
    failures.append("thinking 内容仍出现在输出里")

# 2) 不能留下孤立的 event: 行（每个 event: 必须紧跟 data:）
for chunk in [c for c in joined.split("\n\n") if c.strip()]:
    rows = chunk.split("\n")
    if rows[0].startswith("event:") and not any(r.startswith("data:") for r in rows):
        failures.append(f"孤立的 event 行: {rows[0]}")

# 3) 保留下来的 content block index 必须是从 0 开始的连续序列
seen = []
for chunk in [c for c in joined.split("\n\n") if c.strip()]:
    for row in chunk.split("\n"):
        if row.startswith("data:"):
            ev = json.loads(row[5:])
            if ev.get("type") == "content_block_start":
                seen.append(ev["index"])
if seen != list(range(len(seen))):
    failures.append(f"index 未重排为连续序列: {seen}")

# 4) text 与 tool_use 两个块都要保留
if '"type":"text"' not in joined.replace(" ", ""):
    failures.append("text 块丢失")
if "tool_use" not in joined:
    failures.append("tool_use 块丢失")

# 5) 请求方向：assistant 历史里的 thinking 块要被剥掉
req = json.dumps({"model": "grok-4.6", "messages": [
    {"role": "user", "content": "1+1?"},
    {"role": "assistant", "content": [
        {"type": "thinking", "thinking": "math", "signature": "AAAA"},
        {"type": "text", "text": "2"}]},
]}).encode()
got = json.loads(tp.strip_thinking_from_request(req))
kinds = [b["type"] for b in got["messages"][1]["content"]]
if kinds != ["text"]:
    failures.append(f"请求方向剥离失败: {kinds}")

# 6) 非流式响应：content 里的 thinking 块要被摘掉
resp = json.dumps({"content": [
    {"type": "thinking", "thinking": "x"},
    {"type": "text", "text": "2"}]}).encode()
got = json.loads(tp.Handler.filter_json_content(resp))
if [b["type"] for b in got["content"]] != ["text"]:
    failures.append("非流式过滤失败")

# 7) 写出方向：被丢弃的事件不能提前写 chunked 终止块。
#    回归的是真实故障——thinking 块一被丢，客户端就只收到 message_start。
class FakeWfile:
    def __init__(self):
        self.buf = bytearray()

    def write(self, data):
        self.buf += data

    def flush(self):
        pass


writer = tp.Handler.__new__(tp.Handler)   # 不跑 __init__，无需真 socket
writer.wfile = FakeWfile()
flt2 = tp.ThinkingFilter()
for name, payload in RAW:
    lines = [f"event: {name}", "data: " + json.dumps(payload)]
    writer.write_chunk(tp.Handler.render_event(lines, flt2))
writer.write_terminator()
wire = bytes(writer.wfile.buf)

terminator = b"0\r\n\r\n"
if wire.count(terminator) != 1:
    failures.append(f"chunked 终止块出现 {wire.count(terminator)} 次，应为 1 次")
if not wire.endswith(terminator):
    failures.append("终止块不在流尾部，说明流被提前结束")
if b"message_stop" not in wire:
    failures.append("message_stop 没有写出，流在中途被截断")

print(f"保留事件数: {len(emitted)} / 原始 {len(RAW)}   content block index: {seen}")
print(f"写出字节数: {len(wire)}   终止块: {'尾部唯一一个' if wire.endswith(terminator) and wire.count(terminator) == 1 else '异常'}")
if failures:
    print("失败:")
    for f in failures:
        print("  -", f)
    sys.exit(1)
print("全部 7 项断言通过")
