"""bulkup 트래커 웹앱 서버 — Python 표준 라이브러리만 사용한다.

데이터는 DATA_DIR(PVC)의 JSON·텍스트 파일에만 있고, 이 저장소에는 앱 코드만 있다.

접근 제어 (앱 자체 인증 없이 두 경로만 허용, 그 밖은 거부)
  - 127.0.0.1/::1 에서 온 요청 = kubectl port-forward(SSH로 클러스터 관리 권한을 가진 쪽) → 전체 권한
  - 그 밖의 요청 = Traefik 경유 → Cloudflare Access JWT(Cf-Access-Jwt-Assertion)를 서명·aud·iss·exp까지 검증
    · 설정(CF_ACCESS_TEAM_DOMAIN, CF_ACCESS_AUD)이 없으면 전부 거부한다(fail closed)
    · 폰은 읽기 + progress/results 쓰기만. 처방·분석·대시보드 쓰기는 로컬 전용
    · 쓰기는 X-Bulkup 헤더를 요구한다(교차 출처 요청은 사전 요청에서 막힌다)
  - /healthz 만 인증 없이 응답한다(본문 "ok")
"""

import base64
import hashlib
import hmac
import json
import os
import re
import sys
import tempfile
import threading
import time
import urllib.request
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

DATA_DIR = os.environ.get("DATA_DIR", "/data")
APP_DIR = os.environ.get("APP_DIR", os.path.dirname(os.path.abspath(__file__)))
PORT = int(os.environ.get("PORT", "8080"))
TEAM_DOMAIN = os.environ.get("CF_ACCESS_TEAM_DOMAIN", "").strip()
ACCESS_AUD = os.environ.get("CF_ACCESS_AUD", "").strip()
CERTS_URL = os.environ.get("CF_ACCESS_CERTS_URL") or (
    "https://%s/cdn-cgi/access/certs" % TEAM_DOMAIN if TEAM_DOMAIN else ""
)

MAX_BODY = 2 * 1024 * 1024
ID_RE = re.compile(r"^[A-Za-z0-9_-]{1,64}$")
DATE_RE = re.compile(r"^\d{4}-\d{2}-\d{2}$")
LOCAL_PEERS = {"127.0.0.1", "::1", "::ffff:127.0.0.1"}
KINDS = ("plans", "progress", "results", "analysis", "dashboard")


# ---------------------------------------------------------------- 저장소

def path_for(kind, ident, ext):
    return os.path.join(DATA_DIR, kind, ident + ext)


def write_atomic(path, data):
    """임시 파일에 쓰고 fsync 후 os.replace — 파드가 죽어도 반쯤 쓴 파일이 남지 않는다."""
    d = os.path.dirname(path)
    fd, tmp = tempfile.mkstemp(dir=d, prefix=".tmp-")
    try:
        with os.fdopen(fd, "wb") as f:
            f.write(data)
            f.flush()
            os.fsync(f.fileno())
        os.replace(tmp, path)
    except BaseException:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise


def read_bytes(path):
    try:
        with open(path, "rb") as f:
            return f.read()
    except FileNotFoundError:
        return None


def read_json(path):
    b = read_bytes(path)
    return None if b is None else json.loads(b)


def dump(obj):
    return json.dumps(obj, ensure_ascii=False, indent=2).encode("utf-8")


def now_iso():
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


# ---------------------------------------------------------------- Cloudflare Access JWT (RS256)

_SHA256_DIGEST_INFO = bytes.fromhex("3031300d060960864801650304020105000420")


def _b64url(s):
    if isinstance(s, str):
        s = s.encode("ascii")
    return base64.urlsafe_b64decode(s + b"=" * (-len(s) % 4))


def _rsa_pkcs1_sha256_verify(n, e, msg, sig):
    k = (n.bit_length() + 7) // 8
    if len(sig) != k:
        return False
    s = int.from_bytes(sig, "big")
    if s >= n:
        return False
    em = pow(s, e, n).to_bytes(k, "big")
    t = _SHA256_DIGEST_INFO + hashlib.sha256(msg).digest()
    pad = k - len(t) - 3
    if pad < 8:
        return False
    return hmac.compare_digest(em, b"\x00\x01" + b"\xff" * pad + b"\x00" + t)


class AccessVerifier:
    def __init__(self, certs_url, aud, issuer):
        self.certs_url, self.aud, self.issuer = certs_url, aud, issuer
        self.keys, self.fetched_at, self.failed_at, self.lock = {}, 0.0, 0.0, threading.Lock()

    @property
    def configured(self):
        return bool(self.certs_url and self.aud and self.issuer)

    def _refresh(self, force=False):
        with self.lock:
            age = time.time() - self.fetched_at
            if self.keys and age < 3600 and not force:
                return
            if force and age < 60:
                return  # 모르는 kid로 인한 재조회는 분당 1회로 제한
            if time.time() - self.failed_at < 30:
                raise RuntimeError("certs fetch backoff")
            req = urllib.request.Request(self.certs_url, headers={"User-Agent": "bulkup"})
            try:
                with urllib.request.urlopen(req, timeout=5) as r:
                    doc = json.loads(r.read())
            except Exception:
                self.failed_at = time.time()
                raise
            keys = {}
            for k in doc.get("keys", []):
                if k.get("kty") == "RSA" and k.get("kid"):
                    keys[k["kid"]] = (int.from_bytes(_b64url(k["n"]), "big"), int.from_bytes(_b64url(k["e"]), "big"))
            self.keys, self.fetched_at = keys, time.time()

    def verify(self, token):
        """유효하면 claims, 아니면 None."""
        if not self.configured or not token:
            return None
        try:
            h64, p64, s64 = token.split(".")
            header = json.loads(_b64url(h64))
            claims = json.loads(_b64url(p64))
            sig = _b64url(s64)
        except (ValueError, TypeError):
            return None
        if header.get("alg") != "RS256" or not header.get("kid"):
            return None
        try:
            self._refresh()
            if header["kid"] not in self.keys:
                self._refresh(force=True)
        except Exception as ex:  # 갱신 실패 — 이미 받아 둔 키가 있으면 그것으로만 검증, 없으면 거부
            log("access certs fetch failed: %s" % ex)
            if not self.keys:
                return None
        key = self.keys.get(header["kid"])
        if not key or not _rsa_pkcs1_sha256_verify(key[0], key[1], (h64 + "." + p64).encode("ascii"), sig):
            return None
        now = time.time()
        aud = claims.get("aud")
        auds = aud if isinstance(aud, list) else [aud]
        if self.aud not in auds or claims.get("iss") != self.issuer:
            return None
        if not isinstance(claims.get("exp"), (int, float)) or claims["exp"] < now - 30:
            return None
        if isinstance(claims.get("nbf"), (int, float)) and claims["nbf"] > now + 60:
            return None
        return claims


VERIFIER = AccessVerifier(CERTS_URL, ACCESS_AUD, "https://%s" % TEAM_DOMAIN if TEAM_DOMAIN else "")


def log(msg):
    sys.stderr.write("%s %s\n" % (now_iso(), msg))


# ---------------------------------------------------------------- 정적 파일

def load_index():
    with open(os.path.join(APP_DIR, "index.html"), "rb") as f:
        html = f.read()
    # 인라인 스크립트는 해시로만 허용한다(주입된 마크업 안의 스크립트·이벤트 속성은 실행되지 않는다)
    hashes = []
    for m in re.finditer(rb"<script>(.*?)</script>", html, re.S):
        hashes.append("'sha256-%s'" % base64.b64encode(hashlib.sha256(m.group(1)).digest()).decode())
    csp = (
        "default-src 'none'; script-src %s; style-src 'unsafe-inline'; img-src 'self' data:; "
        "connect-src 'self'; base-uri 'none'; form-action 'none'; frame-ancestors 'none'" % " ".join(hashes)
    )
    return html, csp


INDEX_HTML, INDEX_CSP = load_index()
DASHBOARD_CSP = (
    "default-src 'none'; script-src 'unsafe-inline' https://cdn.jsdelivr.net; style-src 'unsafe-inline'; "
    "img-src 'self' data:; base-uri 'none'; form-action 'none'; frame-ancestors 'none'"
)


# ---------------------------------------------------------------- 요청 처리

class HTTPError(Exception):
    def __init__(self, status, msg):
        super().__init__(msg)
        self.status, self.msg = status, msg


class Handler(BaseHTTPRequestHandler):
    server_version = "bulkup"
    sys_version = ""
    protocol_version = "HTTP/1.1"

    # --- 응답
    def _send(self, status, body=b"", ctype="application/json; charset=utf-8", extra=None):
        self.send_response(status)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Content-Type-Options", "nosniff")
        self.send_header("Referrer-Policy", "no-referrer")
        self.send_header("X-Frame-Options", "DENY")
        for k, v in (extra or {}).items():
            self.send_header(k, v)
        if self.close_connection:
            self.send_header("Connection", "close")
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(body)

    def _json(self, status, obj):
        self._send(status, dump(obj))

    def log_message(self, fmt, *args):
        log("%s %s" % (self.address_string(), fmt % args))

    # --- 인증
    def _who(self):
        peer = self.client_address[0]
        if peer in LOCAL_PEERS:
            return "local"
        if VERIFIER.verify(self.headers.get("Cf-Access-Jwt-Assertion", "")):
            return "user"
        return None

    def _body(self, ctype_required="application/json"):
        ctype = (self.headers.get("Content-Type") or "").split(";")[0].strip().lower()
        if ctype != ctype_required:
            raise HTTPError(415, "Content-Type must be %s" % ctype_required)
        try:
            n = int(self.headers.get("Content-Length", "0"))
        except ValueError:
            raise HTTPError(411, "bad Content-Length")
        if n <= 0 or n > MAX_BODY:
            raise HTTPError(413, "body size must be 1..%d" % MAX_BODY)
        return self.rfile.read(n)

    def _json_body(self):
        try:
            obj = json.loads(self._body())
        except (ValueError, UnicodeDecodeError):
            raise HTTPError(400, "invalid JSON")
        if not isinstance(obj, dict):
            raise HTTPError(400, "JSON object required")
        return obj

    def _dispatch(self):
        url = urlparse(self.path)
        parts = [p for p in url.path.split("/") if p]
        method = self.command
        if method in ("GET", "HEAD") and url.path == "/healthz":
            return self._send(200, b"ok", "text/plain; charset=utf-8")

        who = self._who()
        if who is None:
            raise HTTPError(403, "forbidden")
        write = method in ("PUT", "POST", "DELETE")
        if write and who != "local" and self.headers.get("X-Bulkup") != "1":
            raise HTTPError(403, "missing X-Bulkup header")

        def ident(i):
            if len(parts) <= i or not ID_RE.match(parts[i]):
                raise HTTPError(400, "bad id")
            return parts[i]

        def local_only():
            if who != "local":
                raise HTTPError(403, "local only")

        if method in ("GET", "HEAD") and url.path == "/":
            return self._send(200, INDEX_HTML, "text/html; charset=utf-8", {"Content-Security-Policy": INDEX_CSP})
        if method in ("GET", "HEAD") and url.path == "/dashboard":
            b = read_bytes(path_for("dashboard", "index", ".html"))
            if b is None:
                raise HTTPError(404, "no dashboard yet")
            return self._send(200, b, "text/html; charset=utf-8", {"Content-Security-Policy": DASHBOARD_CSP})
        if len(parts) < 2 or parts[0] != "api":
            raise HTTPError(404, "not found")

        res = parts[1]
        if res == "plans":
            if len(parts) == 2 and method == "GET":
                return self._json(200, {"plans": list_plans()})
            i = ident(2)
            if method == "GET":
                return self._get_file(path_for("plans", i, ".json"))
            if method == "PUT":
                local_only()
                plan = self._json_body()
                if plan.get("plan_version") != 1 or plan.get("id") != i:
                    raise HTTPError(400, "plan_version 1 and matching id required")
                write_atomic(path_for("plans", i, ".json"), dump(plan))
                return self._json(200, {"ok": True, "id": i})
        elif res == "progress":
            i = ident(2)
            if method == "GET":
                return self._get_file(path_for("progress", i, ".json"))
            if method == "PUT":
                body = self._json_body()
                if not isinstance(body.get("saved_at"), (int, float)) or "data" not in body:
                    raise HTTPError(400, "{saved_at, data} required")
                if read_bytes(path_for("plans", i, ".json")) is None:
                    raise HTTPError(404, "unknown plan")
                body["received_at"] = now_iso()
                write_atomic(path_for("progress", i, ".json"), dump(body))
                return self._json(200, {"ok": True, "saved_at": body["saved_at"]})
        elif res == "results":
            if len(parts) == 2 and method == "GET":
                since = (parse_qs(url.query).get("since") or [""])[0]
                if since and not DATE_RE.match(since):
                    raise HTTPError(400, "since must be YYYY-MM-DD")
                return self._json(200, {"results": list_results(since)})
            i = ident(2)
            if method == "GET":
                return self._get_file(path_for("results", i, ".json"))
            if method == "POST":
                result = self._json_body()
                if result.get("schema_version") != 2 or not DATE_RE.match(str(result.get("date", ""))):
                    raise HTTPError(400, "schema_version 2 result with date required")
                if read_bytes(path_for("plans", i, ".json")) is None:
                    raise HTTPError(404, "unknown plan")
                p = path_for("results", i, ".json")
                prev = read_bytes(p)
                if prev is not None:  # 두 번 누르기 등 — 이전 판 보존
                    write_atomic(p + ".bak", prev)
                write_atomic(p, dump({"id": i, "completed_at": now_iso(), "data": result}))
                return self._json(200, {"ok": True, "id": i, "replaced": prev is not None})
        elif res == "analysis":
            i = ident(2)
            if method == "GET":
                b = read_bytes(path_for("analysis", i, ".md"))
                if b is None:
                    raise HTTPError(404, "no analysis")
                return self._send(200, b, "text/markdown; charset=utf-8")
            if method == "PUT":
                local_only()
                write_atomic(path_for("analysis", i, ".md"), self._body("text/markdown"))
                return self._json(200, {"ok": True, "id": i})
        elif res == "dashboard" and len(parts) == 2 and method == "PUT":
            local_only()
            write_atomic(path_for("dashboard", "index", ".html"), self._body("text/html"))
            return self._json(200, {"ok": True})
        raise HTTPError(404 if method == "GET" else 405, "not found")

    def _get_file(self, path):
        b = read_bytes(path)
        if b is None:
            raise HTTPError(404, "not found")
        return self._send(200, b)

    def _handle(self):
        try:
            self._dispatch()
        except HTTPError as e:
            self.close_connection = True  # 읽지 않은 본문이 다음 요청으로 섞이지 않게
            self._json(e.status, {"error": e.msg})
        except Exception as e:  # 내부 오류 내용은 로그에만
            log("error %s %s: %r" % (self.command, self.path, e))
            self.close_connection = True
            self._json(500, {"error": "internal error"})

    do_GET = do_HEAD = do_PUT = do_POST = do_DELETE = _handle


def list_plans():
    out = []
    d = os.path.join(DATA_DIR, "plans")
    for name in os.listdir(d):
        if not name.endswith(".json") or name.startswith("."):
            continue
        i = name[:-5]
        try:
            p = read_json(os.path.join(d, name))
        except ValueError:
            continue
        res = read_json(path_for("results", i, ".json")) if os.path.exists(path_for("results", i, ".json")) else None
        prog = path_for("progress", i, ".json")
        out.append({
            "id": i,
            "date": p.get("meta", {}).get("date"),
            "slot": p.get("meta", {}).get("slot"),
            "title": p.get("title"),
            "has_progress": os.path.exists(prog),
            "completed_at": res.get("completed_at") if res else None,
            "has_analysis": os.path.exists(path_for("analysis", i, ".md")),
        })
    out.sort(key=lambda x: (x["date"] or "", x["id"]), reverse=True)
    return out


def list_results(since):
    out = []
    d = os.path.join(DATA_DIR, "results")
    for name in sorted(os.listdir(d)):
        if not name.endswith(".json") or name.startswith("."):
            continue
        try:
            r = read_json(os.path.join(d, name))
        except ValueError:
            continue
        if since and str(r.get("data", {}).get("date", "")) < since:
            continue
        out.append(r)
    return out


def main():
    for k in KINDS:
        os.makedirs(os.path.join(DATA_DIR, k), exist_ok=True)
    if not VERIFIER.configured:
        log("WARNING: Cloudflare Access 설정 없음 — 로컬(port-forward) 외 요청은 모두 거부")
    srv = ThreadingHTTPServer(("0.0.0.0", PORT), Handler)
    srv.daemon_threads = True
    log("listening on :%d data=%s" % (PORT, DATA_DIR))
    srv.serve_forever()


if __name__ == "__main__":
    main()
