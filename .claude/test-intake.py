"""Stand-ins for .claude/test-intake.sh: a plain-text IMAP server and Discord's
REST API, both reading what they serve from files in DIR on every request, so
the test adds mail and messages by writing files.

  python3 test-intake.py imap PORT DIR      DIR/mail/<uid>.eml; password in DIR/imap-password
  python3 test-intake.py discord PORT DIR   DIR/discord.json (a list of messages); token in DIR/discord-token

Each logs what it was asked to DIR/<kind>.log.
"""
import http.server
import json
import os
import re
import socketserver
import sys
import urllib.parse

kind, port, d = sys.argv[1], int(sys.argv[2]), sys.argv[3]
VALIDITY = 7


def log(line):
    with open(os.path.join(d, kind + ".log"), "a") as f:
        f.write(line + "\n")


def mail():
    folder = os.path.join(d, "mail")
    out = {}
    for name in os.listdir(folder):
        if name.endswith(".eml"):
            with open(os.path.join(folder, name), "rb") as f:
                out[int(name[:-4])] = f.read()
    return dict(sorted(out.items()))


def args(s):
    out = []
    for q, bare in re.findall(r'"((?:[^"\\]|\\.)*)"|(\S+)', s):
        out.append(re.sub(r'\\(.)', r'\1', q) if q else bare)
    return out


class Imap(socketserver.StreamRequestHandler):
    def send(self, text):
        self.wfile.write(text if isinstance(text, bytes) else text.encode())

    def handle(self):
        self.send("* OK fake IMAP ready\r\n")
        authed = False
        while True:
            line = self.rfile.readline()
            if not line:
                return
            line = line.decode().rstrip("\r\n")
            tag, _, rest = line.partition(" ")
            cmd = rest.split(" ")[0].upper()
            log(re.sub(r"(LOGIN \S+ ).*", r"\1***", line))
            msgs = mail()
            if cmd == "CAPABILITY":
                self.send(f"* CAPABILITY IMAP4rev1\r\n{tag} OK done\r\n")
            elif cmd == "LOGIN":
                a = args(rest)
                want = open(os.path.join(d, "imap-password")).read().strip()
                if a[2] == want:
                    authed = True
                    self.send(f"{tag} OK logged in\r\n")
                else:
                    self.send(f"{tag} NO [AUTHENTICATIONFAILED] wrong password\r\n")
            elif not authed:
                self.send(f"{tag} BAD log in first\r\n")
            elif cmd == "STATUS":
                nxt = max(msgs, default=0) + 1
                self.send(f'* STATUS "INBOX" (UIDVALIDITY {VALIDITY} UIDNEXT {nxt})\r\n{tag} OK done\r\n')
            elif cmd in ("SELECT", "EXAMINE"):
                self.send(f"* {len(msgs)} EXISTS\r\n* OK [UIDVALIDITY {VALIDITY}] ok\r\n{tag} OK [READ-WRITE] done\r\n")
            elif rest.upper().startswith("UID SEARCH UID "):
                lo = int(rest.split()[-1].split(":")[0])
                found = [u for u in msgs if u >= lo]
                if not found and msgs:
                    found = [max(msgs)]  # n:* always takes in the highest
                self.send(f"* SEARCH {' '.join(map(str, found))}\r\n{tag} OK done\r\n")
            elif rest.upper().startswith("UID FETCH "):
                uid = int(rest.split()[2])
                if uid not in msgs:
                    self.send(f"{tag} OK nothing\r\n")
                    continue
                body = msgs[uid]
                seq = list(msgs).index(uid) + 1
                part = re.search(r"BODY\[\]<(\d+)\.(\d+)>", rest)
                label = "BODY[]"
                if part:  # a partial fetch: BODY[]<start.length>
                    start, length = int(part.group(1)), int(part.group(2))
                    body, label = body[start:start + length], f"BODY[]<{start}>"
                self.send(f"* {seq} FETCH (UID {uid} {label} {{{len(body)}}}\r\n".encode() + body + b")\r\n" + f"{tag} OK done\r\n".encode())
            elif cmd == "LOGOUT":
                self.send(f"* BYE\r\n{tag} OK bye\r\n")
                return
            else:
                self.send(f"{tag} BAD unknown\r\n")


class Discord(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def reply(self, code, body=None):
        data = json.dumps(body).encode() if body is not None else b""
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def authed(self):
        want = "Bot " + open(os.path.join(d, "discord-token")).read().strip()
        if self.headers.get("Authorization") != want:
            self.reply(401, {"message": "401: Unauthorized", "code": 0})
            return False
        return True

    def do_GET(self):
        log("GET " + self.path)
        if not self.authed():
            return
        u = urllib.parse.urlparse(self.path)
        q = urllib.parse.parse_qs(u.query)
        parts = u.path.strip("/").split("/")
        if len(parts) == 2 and parts[0] == "channels":
            return self.reply(200, {"id": parts[1], "guild_id": "555"})
        if len(parts) == 3 and parts[2] == "messages":
            msgs = json.load(open(os.path.join(d, "discord.json")))
            msgs.sort(key=lambda m: int(m["id"]))
            limit = int(q.get("limit", ["50"])[0])
            if "after" in q:
                after = int(q["after"][0])
                msgs = [m for m in msgs if int(m["id"]) > after][:limit]
            else:
                msgs = msgs[-limit:]
            return self.reply(200, list(reversed(msgs)))  # newest first, as Discord does
        self.reply(404, {"message": "Unknown"})

    def do_PUT(self):
        log("PUT " + self.path)
        if not self.authed():
            return
        self.reply(204)


socketserver.TCPServer.allow_reuse_address = True
if kind == "imap":
    socketserver.ThreadingTCPServer(("127.0.0.1", port), Imap).serve_forever()
else:
    http.server.ThreadingHTTPServer(("127.0.0.1", port), Discord).serve_forever()
