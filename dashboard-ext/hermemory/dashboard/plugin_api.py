"""HerMemory dashboard backend: vault files, health checks, export.

Mounted by the Hermes dashboard at /api/plugins/hermemory/.
Everything is scoped to the vault memory directory; path traversal is rejected
and every write keeps a timestamped backup next to the file.
"""
from __future__ import annotations

import datetime as _dt
import os
import pathlib
import shutil
import subprocess
import zipfile

from fastapi import APIRouter, HTTPException
from pydantic import BaseModel

router = APIRouter()

CORE_FILES = ("AGENTS.md", "SOUL.md", "USER.md", "MEMORY.md")


def _home() -> pathlib.Path:
    return pathlib.Path(os.environ.get("HERMES_HOME") or (pathlib.Path.home() / ".hermes"))


def _vault() -> pathlib.Path:
    env = os.environ.get("HERMEMORY_VAULT_DIR")
    if env:
        return pathlib.Path(env).expanduser()
    return pathlib.Path.home() / "vault" / "HerMemory" / "memory"


def _safe(rel: str) -> pathlib.Path:
    root = _vault().resolve()
    target = (root / rel).resolve()
    if target != root and root not in target.parents:
        raise HTTPException(status_code=400, detail="path escapes the vault")
    return target


class WriteBody(BaseModel):
    path: str
    content: str


@router.get("/files")
def list_files():
    root = _vault()
    if not root.is_dir():
        return {"root": str(root), "exists": False, "files": []}
    out = []
    for p in sorted(root.rglob("*.md")):
        st = p.stat()
        out.append({
            "path": str(p.relative_to(root)).replace(os.sep, "/"),
            "size": st.st_size,
            "mtime": int(st.st_mtime),
        })
    return {"root": str(root), "exists": True, "files": out}


@router.get("/file")
def read_file(path: str):
    target = _safe(path)
    if not target.is_file():
        raise HTTPException(status_code=404, detail="no such file")
    return {"path": path, "content": target.read_text(encoding="utf-8", errors="replace")}


@router.post("/file")
def write_file(body: WriteBody):
    target = _safe(body.path)
    if target.suffix != ".md":
        raise HTTPException(status_code=400, detail="only .md files")
    target.parent.mkdir(parents=True, exist_ok=True)
    if target.exists():
        stamp = _dt.datetime.now().strftime("%Y%m%d-%H%M%S")
        shutil.copy2(target, target.with_name(target.name + f".bak-{stamp}"))
    tmp = target.with_name(target.name + ".hm-tmp")
    tmp.write_text(body.content, encoding="utf-8")
    os.replace(tmp, target)
    return {"ok": True, "path": body.path, "bytes": len(body.content.encode("utf-8"))}


def _hermes_version() -> str:
    try:
        exe = pathlib.Path.home() / ".local" / "bin" / "hermes"
        out = subprocess.run([str(exe), "--version"], capture_output=True, text=True, timeout=15)
        first = (out.stdout or "").strip().splitlines()
        return first[0] if first else "unknown"
    except Exception as exc:  # noqa: BLE001
        return f"unavailable ({exc.__class__.__name__})"


@router.get("/health")
def health():
    root = _vault()
    checks = []
    checks.append({"name": "记忆库目录", "ok": root.is_dir(), "detail": str(root)})
    for name in CORE_FILES:
        p = root / name
        checks.append({"name": f"{name}", "ok": p.is_file(), "detail": "存在" if p.is_file() else "缺失"})
    writable = False
    try:
        probe = root / ".hm-write-probe"
        probe.write_text("ok", encoding="utf-8")
        probe.unlink()
        writable = True
    except Exception:  # noqa: BLE001
        writable = False
    checks.append({"name": "记忆库可写", "ok": writable, "detail": "" if writable else "只读或无权限"})
    try:
        free_gb = round(shutil.disk_usage(root if root.exists() else pathlib.Path.home()).free / 1e9, 1)
        checks.append({"name": "磁盘剩余", "ok": free_gb >= 1.0, "detail": f"{free_gb} GB"})
    except Exception:  # noqa: BLE001
        pass
    home = _home()
    gw = home / "gateway.pid"
    checks.append({"name": "网关进程", "ok": gw.is_file(), "detail": str(gw) if gw.is_file() else "未运行（微信不会回复）"})
    checks.append({"name": "内核版本", "ok": True, "detail": _hermes_version()})
    return {"ok": all(c["ok"] for c in checks), "checks": checks}


@router.post("/export")
def export():
    root = _vault()
    if not root.is_dir():
        raise HTTPException(status_code=404, detail="记忆库目录不存在")
    stamp = _dt.datetime.now().strftime("%Y%m%d-%H%M")
    out = pathlib.Path.home() / "vault" / f"HerMemory-{stamp}.zip"
    home = _home()
    with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED) as zf:
        for p in root.rglob("*"):
            if p.is_file():
                zf.write(p, "memory/" + str(p.relative_to(root)).replace(os.sep, "/"))
        cfg = home / "config.yaml"
        if cfg.is_file():
            lines = []
            for line in cfg.read_text(encoding="utf-8", errors="replace").splitlines():
                low = line.lower()
                if any(k in low for k in ("api_key", "token", "secret", "password")):
                    continue
                lines.append(line)
            zf.writestr("config.yaml", "\n".join(lines) + "\n")
    return {"ok": True, "path": str(out), "size": out.stat().st_size}
