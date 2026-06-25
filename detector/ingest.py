"""
Módulo 1 — Ingesta
Lee el audit log del API Server en tiempo real y filtra eventos por ServiceAccount.
"""

import json
import time
import os

AUDIT_LOG_PATH = os.environ.get(
    "AUDIT_LOG_PATH",
    r"C:\thesis\lab\audit-logs\audit.log"
)

TARGET_SA = os.environ.get("TARGET_SA", "victim-sa")


def tail_log(path: str):
    """Sigue el fichero evitando duplicados al reemplazarse el fichero."""
    lines_seen = 0
    while True:
        try:
            with open(path, "r", encoding="utf-8") as f:
                all_lines = f.readlines()
            new_lines = all_lines[lines_seen:]
            for line in new_lines:
                line = line.strip()
                if line:
                    yield line
            lines_seen = len(all_lines)
        except FileNotFoundError:
            pass
        time.sleep(0.5)


def parse_event(line: str) -> dict | None:
    """Parsea una línea JSON del audit log."""
    try:
        event = json.loads(line)
        if event.get("kind") != "Event":
            return None
        # Solo ResponseComplete para evitar duplicados
        if event.get("stage") != "ResponseComplete":
            return None
        return event
    except json.JSONDecodeError:
        return None


def is_target_sa(event: dict, sa_name: str) -> bool:
    """Comprueba si el evento pertenece a la ServiceAccount objetivo."""
    username = event.get("user", {}).get("username", "")
    return f":{sa_name}" in username


def stream_events(sa_name: str = TARGET_SA, log_path: str = AUDIT_LOG_PATH):
    """Generador: emite eventos del audit log filtrados por SA."""
    print(f"[ingest] Monitorizando SA: {sa_name}")
    print(f"[ingest] Leyendo log: {log_path}")
    for line in tail_log(log_path):
        event = parse_event(line)
        if event and is_target_sa(event, sa_name):
            yield event


if __name__ == "__main__":
    seen_ids = set()
    for ev in stream_events():
        audit_id = ev.get("auditID", "")
        if audit_id in seen_ids:
            continue
        seen_ids.add(audit_id)
        verb = ev.get("verb", "")
        resource = ev.get("objectRef", {}).get("resource", "")
        ns = ev.get("objectRef", {}).get("namespace", "")
        ts = ev.get("requestReceivedTimestamp", "")
        print(f"[{ts}] {verb:10} {resource:20} ns={ns}")