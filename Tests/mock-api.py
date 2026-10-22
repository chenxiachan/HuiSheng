import http.server, json, socketserver, sys, time
class Server(socketserver.ThreadingMixIn, http.server.HTTPServer):
    daemon_threads = True
class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *_): pass
    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
        content = '\n'.join(m['content'] for m in body['messages'])
        assert '机密' not in content and '其他材料' not in content
        mode = body['model']
        if mode == 'unauthorized':
            self.send_response(401); self.end_headers(); return
        if mode == 'redirect':
            self.send_response(307); self.send_header('Location', '/should-not-follow'); self.end_headers(); return
        if self.path != '/v1/chat/completions':
            raise AssertionError('Must not follow redirect')
        self.send_response(200); self.send_header('Content-Type', 'text/event-stream'); self.end_headers()
        def event(value):
            payload = 'data: ' + json.dumps(value, ensure_ascii=False) + '\r\n\r\n'
            # Deliberately split UTF-8 characters across writes.
            data = payload.encode()
            for i in range(0, len(data), 5): self.wfile.write(data[i:i+5]); self.wfile.flush()
        try:
            if mode == 'slow': time.sleep(1)
            for text in ['星期五', '交付。', '[[1]]']:
                event({'choices':[{'delta':{'content':text},'finish_reason':None}]})
            if mode == 'incomplete': return
            if mode == 'server-error': event({'error':{'message':'private error'}}); return
            event({'choices':[{'delta':{},'finish_reason':'length' if mode == 'length' else 'stop'}]})
            self.wfile.write(b'data: [DONE]\n\n')
        except (BrokenPipeError, ConnectionResetError): pass
server = Server(('127.0.0.1', 0), Handler)
with open(sys.argv[1], 'w') as f: f.write(str(server.server_port))
server.serve_forever()
