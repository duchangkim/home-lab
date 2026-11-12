"""OpenWebUI 설정 동기화.

desired.json에 적힌 설정을 OpenWebUI 관리 API로 적용한다.
- 각 섹션은 현재 설정을 읽은 뒤 desired 값만 덮어써서 다시 저장한다(적지 않은 항목은 유지).
- 문자열 값 "$env:NAME"은 같은 이름의 환경변수 값으로 바꾼다(시크릿은 Sealed Secret에서 주입).
- models 항목은 모델 엔트리(이름·설명·숨김·공개 범위)를 만들거나 갱신한다. 프로필 이미지 등 UI에서 바꾼 다른 메타데이터는 유지한다.
  name을 생략하면 현재 이름(없으면 id)을 쓰고, public이 false면 공개 읽기 권한을 건드리지 않는다.
- system_prompt.files에 적은 파일(같은 ConfigMap)을 이어 붙여 models 항목 전체의 시스템 프롬프트로 쓴다.
  모델 항목에 "system_prompt": false를 주면 그 모델의 시스템 프롬프트는 건드리지 않는다.
- web 항목은 웹검색 설정(관리자 > 설정 > 웹 검색)에서 적은 키만 갱신한다.
표준 라이브러리만 사용한다.
"""

import json
import os
import sys
import time
import urllib.error
import urllib.request

BASE_URL = os.environ.get("OWUI_URL", "http://openwebui.default.svc.cluster.local:8080").rstrip("/")
API_KEY = os.environ["OWUI_API_KEY"]
DESIRED_PATH = os.environ.get("DESIRED_PATH", "/config/desired.json")
CONFIG_DIR = os.path.dirname(DESIRED_PATH)
PUBLIC_READ = [{"principal_type": "user", "principal_id": "*", "permission": "read"}]


def resolve(value):
    if isinstance(value, str) and value.startswith("$env:"):
        name = value[len("$env:"):]
        if name not in os.environ:
            sys.exit(f"환경변수 {name}가 없습니다")
        return os.environ[name]
    if isinstance(value, dict):
        return {k: resolve(v) for k, v in value.items()}
    if isinstance(value, list):
        return [resolve(v) for v in value]
    return value


def call(method, path, body=None):
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(
        BASE_URL + path,
        data=data,
        method=method,
        headers={"Authorization": f"Bearer {API_KEY}", "Content-Type": "application/json"},
    )
    try:
        with urllib.request.urlopen(req, timeout=60) as resp:
            raw = resp.read()
            return resp.status, json.loads(raw) if raw else None
    except urllib.error.HTTPError as err:
        return err.code, err.read().decode(errors="replace")[:500]


def must(method, path, body=None):
    status, result = call(method, path, body)
    if status != 200:
        sys.exit(f"{method} {path} 실패: {status} {result}")
    return result


def wait_ready(timeout=300):
    deadline = time.time() + timeout
    while time.time() < deadline:
        try:
            with urllib.request.urlopen(BASE_URL + "/health", timeout=5) as resp:
                if resp.status == 200:
                    return
        except Exception:
            pass
        time.sleep(5)
    sys.exit("OpenWebUI가 준비되지 않았습니다")


def merge_section(name, get_path, post_path, desired):
    current = must("GET", get_path)
    changed = {k: v for k, v in desired.items() if current.get(k) != v}
    if not changed:
        print(f"[{name}] 변경 없음")
        return
    must("POST", post_path, {**current, **desired})
    print(f"[{name}] 갱신: {', '.join(sorted(changed))}")


def sync_openai(desired):
    conns = desired["connections"]
    body = {
        "ENABLE_OPENAI_API": desired.get("enable", True),
        "OPENAI_API_BASE_URLS": [c["url"] for c in conns],
        "OPENAI_API_KEYS": [c["key"] for c in conns],
        "OPENAI_API_CONFIGS": {str(i): c.get("config", {}) for i, c in enumerate(conns)},
    }
    current = must("GET", "/openai/config")
    if all(current.get(k) == v for k, v in body.items()):
        print("[openai] 변경 없음")
        return
    must("POST", "/openai/config/update", body)
    print(f"[openai] 연결 {len(conns)}개 갱신: {', '.join(c['url'] for c in conns)}")


def load_system_prompt(spec):
    parts = []
    for name in spec.get("files", []):
        with open(os.path.join(CONFIG_DIR, name), encoding="utf-8") as f:
            parts.append(f.read().strip())
    return "\n\n".join(parts)


def sync_models(models, system_prompt=None):
    for m in models:
        use_prompt = system_prompt and m.get("system_prompt", True)
        mid = m["id"]
        public = m.get("public", True)
        status, current = call("GET", f"/api/v1/models/model?id={urllib.request.quote(mid)}")
        if status == 200 and current:
            meta = {**(current.get("meta") or {}), **m.get("meta", {})}
            params = dict(current.get("params") or {})
            if use_prompt:
                params["system"] = system_prompt
            form = {
                "id": mid,
                "base_model_id": current.get("base_model_id"),
                "name": m.get("name") or current.get("name") or mid,
                "meta": meta,
                "params": params,
                "is_active": m.get("is_active", True),
            }
            if (
                current.get("name") != form["name"]
                or current.get("meta") != meta
                or (current.get("params") or {}) != params
                or current.get("is_active") != form["is_active"]
            ):
                must("POST", f"/api/v1/models/model/update?id={urllib.request.quote(mid)}", form)
                print(f"[models] 갱신: {mid}")
            grants = {(g["principal_type"], g["principal_id"], g["permission"]) for g in current.get("access_grants") or []}
            if public and ("user", "*", "read") not in grants:
                must(
                    "POST",
                    "/api/v1/models/model/access/update",
                    {"id": mid, "access_grants": [*current.get("access_grants", []), *PUBLIC_READ]},
                )
                print(f"[models] 공개 읽기 권한 추가: {mid}")
        else:
            must(
                "POST",
                "/api/v1/models/create",
                {
                    "id": mid,
                    "base_model_id": None,
                    "name": m.get("name") or mid,
                    "meta": m.get("meta", {}),
                    "params": {"system": system_prompt} if use_prompt else {},
                    "access_grants": PUBLIC_READ if public else [],
                    "is_active": m.get("is_active", True),
                },
            )
            print(f"[models] 생성: {mid}")


def sync_web(desired):
    current = must("GET", "/api/v1/retrieval/config").get("web") or {}
    changed = {k: v for k, v in desired.items() if current.get(k) != v}
    if not changed:
        print("[web] 변경 없음")
        return
    # WebConfig는 보낸 키만 저장한다(exclude_unset).
    must("POST", "/api/v1/retrieval/config/update", {"web": changed})
    print(f"[web] 갱신: {', '.join(sorted(changed))}")


def main():
    desired = resolve(json.load(open(DESIRED_PATH)))
    wait_ready()
    if "openai" in desired:
        sync_openai(desired["openai"])
    if "models" in desired:
        prompt = load_system_prompt(desired["system_prompt"]) if "system_prompt" in desired else None
        sync_models(desired["models"], prompt)
    if "model_defaults" in desired:
        merge_section("model_defaults", "/api/v1/configs/models", "/api/v1/configs/models", desired["model_defaults"])
    if "web" in desired:
        sync_web(desired["web"])
    if "images" in desired:
        merge_section("images", "/api/v1/images/config", "/api/v1/images/config/update", desired["images"])
    if "tasks" in desired:
        merge_section("tasks", "/api/v1/tasks/config", "/api/v1/tasks/config/update", desired["tasks"])
    print("완료")


if __name__ == "__main__":
    main()
