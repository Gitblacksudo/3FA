"""
Módulo 1 — Ingesta
Lee el audit log del API Server en tiempo real y filtra eventos por ServiceAccount.
"""

import json
import time
import os

AUDIT_LOG_PATH = os.environ.get(
    "AUDIT_LOG_PATH",
    # Ruta por defecto dentro del contenedor Kind
    "/var/lib/containerd/io.containerd.snapshotter.v1.overlayfs/snapshots/124/fs/var/log/audit.log"
)

TARGET_SA = os.environ.get("TARGET_SA", "victim-sa")


def tail_log(path: str):
    """Sigue el fichero de log en tiempo real."""
    last_size = 0
    while True:
        try:
            current_size = os.path.getsize(path)
            if current_size < last_size:
                # El fichero fue reemplazado, empezamos desde el principio
                last_size = 0
            if current_size > last_size:
                with open(path, "r", encoding="utf-8") as f:
                    f.seek(last_size)
                    for line in f:
                        line = line.strip()
                        if line:
                            yield line
                    last_size = f.tell()
        except FileNotFoundError:
            pass
        time.sleep(0.5)


def parse_event(line: str) -> dict | None:
    """Parsea una línea JSON del audit log. Devuelve None si no es válida."""
    try:
        event = json.loads(line)
        if event.get("kind") != "Event":
            return None
        return event
    except json.JSONDecodeError:
        return None


def is_target_sa(event: dict, sa_name: str) -> bool:
    """Comprueba si el evento pertenece a la ServiceAccount objetivo."""
    username = event.get("user", {}).get("username", "")
    return f"serviceaccount:{sa_name}" in username or \
           username.endswith(f":{sa_name}")


def stream_events(sa_name: str = TARGET_SA, log_path: str = AUDIT_LOG_PATH):
    """Generador: emite eventos del audit log filtrados por SA."""
    print(f"[ingest] Monitorizando SA: {sa_name}")
    print(f"[ingest] Leyendo log: {log_path}")
    for line in tail_log(log_path):
        event = parse_event(line)
        if event and is_target_sa(event, sa_name):
            yield event


if __name__ == "__main__":
    # Prueba rápida: imprime los eventos de victim-sa en tiempo real
    for ev in stream_events():
        verb = ev.get("verb", "")
        resource = ev.get("objectRef", {}).get("resource", "")
        ns = ev.get("objectRef", {}).get("namespace", "")
        user = ev.get("user", {}).get("username", "")
        ts = ev.get("requestReceivedTimestamp", "")
        print(f"[{ts}] {verb:10} {resource:20} ns={ns:15} user={user}")