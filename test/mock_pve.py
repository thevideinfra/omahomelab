#!/usr/bin/env python3
"""Tiny fake Proxmox VE API for testing omaprox. Not a faithful PVE, just the
endpoints the plugin touches, with the same auth header and response shapes.

usage: mock_pve.py --port N [--cert C --key K] [--log FILE] [--delay SECS]
"""
import argparse
import json
import re
import ssl
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

TOKEN = "root@pam!omarchy=11111111-2222-3333-4444-555555555555"

GB = 1024 ** 3
RESOURCES = [
    {"type": "node", "id": "node/pve1", "node": "pve1", "status": "online",
     "cpu": 0.12, "maxcpu": 8, "mem": 12 * GB, "maxmem": 32 * GB, "uptime": 987654},
    {"type": "node", "id": "node/pve2", "node": "pve2", "status": "offline"},
    {"type": "qemu", "id": "qemu/100", "vmid": 100, "name": "web", "node": "pve1",
     "status": "running", "cpu": 0.05, "maxcpu": 2, "mem": 2 * GB, "maxmem": 4 * GB,
     "uptime": 3700, "tags": "prod;web", "template": 0},
    {"type": "qemu", "id": "qemu/101", "vmid": 101, "name": "db", "node": "pve1",
     "status": "stopped", "cpu": 0, "maxcpu": 4, "mem": 0, "maxmem": 8 * GB, "template": 0},
    {"type": "qemu", "id": "qemu/102", "vmid": 102, "name": "ubuntu-template", "node": "pve1",
     "status": "stopped", "template": 1},
    {"type": "lxc", "id": "lxc/200", "vmid": 200, "name": "pihole", "node": "pve1",
     "status": "running", "cpu": 0.01, "maxcpu": 1, "mem": 128 * 1024 ** 2,
     "maxmem": GB, "uptime": 86400 * 5 + 3600},
    {"type": "lxc", "id": "lxc/201", "vmid": 201, "name": "backup-target", "node": "pve1",
     "status": "running", "lock": "backup", "maxmem": GB, "mem": GB // 4, "uptime": 60},
    {"type": "storage", "id": "storage/pve1/local", "storage": "local", "node": "pve1",
     "status": "available", "disk": 20 * GB, "maxdisk": 100 * GB},
    {"type": "storage", "id": "storage/pve1/local-lvm", "storage": "local-lvm", "node": "pve1",
     "status": "available", "disk": 92 * GB, "maxdisk": 100 * GB},
    {"type": "storage", "id": "storage/pve1/nfs", "storage": "nfs", "node": "pve1",
     "status": "available", "shared": 1, "disk": 300 * GB, "maxdisk": 1000 * GB},
    {"type": "storage", "id": "storage/pve2/nfs", "storage": "nfs", "node": "pve2",
     "status": "available", "shared": 1, "disk": 300 * GB, "maxdisk": 1000 * GB},
]

KNOWN = {("pve1", "qemu", 100), ("pve1", "qemu", 101), ("pve1", "lxc", 200), ("pve1", "lxc", 201)}

STATUS_RE = re.compile(r"^/api2/json/nodes/([\w.-]+)/(qemu|lxc)/(\d+)/status/(\w+)$")
SNAP_RE = re.compile(r"^/api2/json/nodes/([\w.-]+)/(qemu|lxc)/(\d+)/snapshot$")
SPICE_RE = re.compile(r"^/api2/json/nodes/([\w.-]+)/(qemu|lxc)/(\d+)/spiceproxy$")


def make_handler(log_path, delay):
    class Handler(BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"

        def log_message(self, *args):  # silence
            pass

        def _record(self, body):
            if not log_path:
                return
            with open(log_path, "a") as fh:
                fh.write(json.dumps({
                    "method": self.command, "path": self.path, "body": body,
                    "auth_ok": self.headers.get("Authorization") == "PVEAPIToken=" + TOKEN,
                    "content_length": self.headers.get("Content-Length"),
                }) + "\n")

        def _reply(self, code, payload, reason=None):
            raw = json.dumps(payload).encode()
            self.send_response(code, reason)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(raw)))
            self.end_headers()
            self.wfile.write(raw)

        def _handle(self):
            length = int(self.headers.get("Content-Length") or 0)
            body = self.rfile.read(length).decode() if length else ""
            self._record(body)
            if delay:
                time.sleep(delay)
            if self.headers.get("Authorization") != "PVEAPIToken=" + TOKEN:
                return self._reply(401, {"data": None}, "No ticket")

            if self.command == "GET" and self.path == "/api2/json/cluster/resources":
                return self._reply(200, {"data": RESOURCES})

            m = STATUS_RE.match(self.path)
            if self.command == "POST" and m:
                node, typ, vmid, op = m.group(1), m.group(2), int(m.group(3)), m.group(4)
                if (node, typ, vmid) not in KNOWN:
                    return self._reply(500, {"data": None},
                                       "Configuration file 'nodes/%s/%s-server/%d.conf' does not exist" % (node, typ, vmid))
                if op == "start" and vmid == 100:
                    return self._reply(500, {"data": None}, "VM 100 already running")
                return self._reply(200, {"data": "UPID:%s:0000ABCD:00001234:65000000:qm%s:%d:root@pam!omarchy:" % (node, op, vmid)})

            m = SNAP_RE.match(self.path)
            if self.command == "POST" and m:
                if "snapname=omaprox-" not in body:
                    return self._reply(400, {"data": None}, "snapname missing")
                return self._reply(200, {"data": "UPID:%s:snapshot" % m.group(1)})

            m = SPICE_RE.match(self.path)
            if self.command == "POST" and m:
                if int(m.group(3)) != 100:
                    return self._reply(500, {"data": None}, "no spice port")
                return self._reply(200, {"data": {
                    "type": "spice", "title": "VM 100 - web", "host": "pvespiceproxy:65000000:100:pve1::abcdef",
                    "proxy": "http://pve1:3128", "tls-port": 61000, "password": "one-time-ticket",
                    "ca": "-----BEGIN CERTIFICATE-----\\nMIIB\\n-----END CERTIFICATE-----\\n",
                    "delete-this-file": 1, "release-cursor": "Ctrl+Alt+R",
                    "toggle-fullscreen": "Shift+F11", "secure-attention": "Ctrl+Alt+Ins",
                }})

            return self._reply(404, {"data": None}, "Not Found")

        do_GET = do_POST = _handle

    return Handler


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, required=True)
    ap.add_argument("--cert")
    ap.add_argument("--key")
    ap.add_argument("--log")
    ap.add_argument("--delay", type=float, default=0)
    args = ap.parse_args()
    srv = ThreadingHTTPServer(("127.0.0.1", args.port), make_handler(args.log, args.delay))
    if args.cert:
        ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        ctx.load_cert_chain(args.cert, args.key)
        srv.socket = ctx.wrap_socket(srv.socket, server_side=True)
    srv.serve_forever()


if __name__ == "__main__":
    main()
