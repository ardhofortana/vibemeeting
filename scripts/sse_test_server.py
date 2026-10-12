import http.server, json, time, sys

EVENTS = [
  ("message_start", {"type":"message_start","message":{"model":"claude-haiku-5-5","usage":{"input_tokens":10,"cache_read_input_tokens":3000,"output_tokens":1}}}),
  ("content_block_start", {"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}),
  ("content_block_delta", {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Héllo — "}}),
  ("content_block_delta", {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"world."}}),
  ("message_delta", {"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":5}}),
  ("message_stop", {"type":"message_stop"}),
]

class H(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    def do_POST(self):
        body = self.rfile.read(int(self.headers.get("content-length", 0)))
        if self.headers.get("x-api-key") != "good":
            payload = json.dumps({"type":"error","error":{"type":"authentication_error","message":"invalid x-api-key"}}).encode()
            self.send_response(401); self.send_header("content-type","application/json"); self.send_header("content-length", str(len(payload))); self.end_headers(); self.wfile.write(payload); return
        req = json.loads(body)
        if not req.get("stream"):
            payload = json.dumps({"content":[],"usage":{"input_tokens":3,"cache_creation_input_tokens":2048,"output_tokens":0}}).encode()
            self.send_response(200); self.send_header("content-type","application/json"); self.send_header("content-length", str(len(payload))); self.end_headers(); self.wfile.write(payload); return
        raw = "".join(f"event: {n}\r\ndata: {json.dumps(d, ensure_ascii=False)}\r\n\r\n" for n, d in EVENTS).encode()
        self.send_response(200); self.send_header("content-type","text/event-stream"); self.send_header("transfer-encoding","chunked"); self.end_headers()
        # Split at awkward boundaries, including inside multibyte characters.
        i = 0; sizes = [7, 1, 33, 2, 64, 5]
        k = 0
        while i < len(raw):
            n = sizes[k % len(sizes)]; k += 1
            chunk = raw[i:i+n]; i += n
            self.wfile.write(b"%x\r\n" % len(chunk) + chunk + b"\r\n"); self.wfile.flush(); time.sleep(0.002)
        self.wfile.write(b"0\r\n\r\n"); self.wfile.flush()
    def log_message(self, *a): pass

srv = http.server.ThreadingHTTPServer(("127.0.0.1", int(sys.argv[1])), H)
srv.serve_forever()
