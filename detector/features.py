"""
Módulo 2 — Feature engineering
Convierte eventos del audit log en vectores numéricos por ventana de 5 minutos.
"""

from collections import defaultdict
from datetime import datetime, timezone
import numpy as np

WINDOW_SECONDS = 30  # medio minuto
KNOWN_VERBS = ["get", "list", "watch", "create", "update", "patch", "delete"]
SENSITIVE_RESOURCES = ["secrets", "serviceaccounts", "roles", "rolebindings",
                       "clusterroles", "clusterrolebindings"]


def parse_ts(ts_str: str) -> datetime:
    """Convierte timestamp ISO8601 a datetime UTC."""
    return datetime.fromisoformat(ts_str.replace("Z", "+00:00"))


def events_to_features(events: list[dict]) -> np.ndarray | None:
    """
    Convierte una lista de eventos de una ventana en un vector de 7 features.
    Devuelve None si la ventana está vacía.
    """
    if not events:
        return None

    n = len(events)

    # Feature 1-7: frecuencias relativas de verbos
    verb_counts = defaultdict(int)
    for ev in events:
        verb_counts[ev.get("verb", "")] += 1

    f_get    = verb_counts["get"] / n
    f_list   = verb_counts["list"] / n
    f_create = verb_counts["create"] / n
    f_delete = (verb_counts["delete"] + verb_counts["patch"] +
                verb_counts["update"]) / n

    # Feature 5: fracción de accesos a recursos sensibles
    sensitive_count = sum(
        1 for ev in events
        if ev.get("objectRef", {}).get("resource", "") in SENSITIVE_RESOURCES
    )
    f_sensitive = sensitive_count / n

    # Feature 6: fracción de respuestas de error (4xx)
    error_count = sum(
        1 for ev in events
        if str(ev.get("responseStatus", {}).get("code", 200)).startswith("4")
    )
    f_errors = error_count / n

    # Feature 7: cardinalidad de recursos únicos accedidos
    unique_resources = len(set(
        ev.get("objectRef", {}).get("resource", "")
        for ev in events
        if ev.get("objectRef", {})
    ))
    f_unique = min(unique_resources / 10.0, 1.0)  # normalizado a [0,1]

    return np.array([f_get, f_list, f_create, f_delete,
                     f_sensitive, f_errors, f_unique])


class WindowAggregator:
    """
    Acumula eventos y emite vectores de features por ventana deslizante.
    """

    def __init__(self, window_seconds: int = WINDOW_SECONDS):
        self.window_seconds = window_seconds
        self.buffer: list[dict] = []
        self.window_start: datetime | None = None

    def add(self, event: dict) -> np.ndarray | None:
        """
        Añade un evento al buffer.
        Devuelve un vector de features si la ventana se ha completado.
        """
        ts = parse_ts(event.get("requestReceivedTimestamp", ""))

        if self.window_start is None:
            self.window_start = ts

        elapsed = (ts - self.window_start).total_seconds()

        if elapsed >= self.window_seconds:
            # Ventana completada: calcular features y resetear
            features = events_to_features(self.buffer)
            self.buffer = [event]
            self.window_start = ts
            return features
        else:
            self.buffer.append(event)
            return None

    def flush(self) -> np.ndarray | None:
        """Fuerza el cálculo con los eventos actuales del buffer."""
        return events_to_features(self.buffer)


if __name__ == "__main__":
    # Prueba rápida con eventos sintéticos
    test_events = [
        {"verb": "list", "objectRef": {"resource": "secrets"},
         "responseStatus": {"code": 200},
         "requestReceivedTimestamp": "2026-06-25T16:00:00Z"},
        {"verb": "list", "objectRef": {"resource": "pods"},
         "responseStatus": {"code": 200},
         "requestReceivedTimestamp": "2026-06-25T16:01:00Z"},
        {"verb": "get", "objectRef": {"resource": "serviceaccounts"},
         "responseStatus": {"code": 200},
         "requestReceivedTimestamp": "2026-06-25T16:02:00Z"},
        {"verb": "create", "objectRef": {"resource": "roles"},
         "responseStatus": {"code": 403},
         "requestReceivedTimestamp": "2026-06-25T16:03:00Z"},
    ]

    vec = events_to_features(test_events)
    labels = ["f_get", "f_list", "f_create", "f_delete",
              "f_sensitive", "f_errors", "f_unique"]
    print("Vector de features de prueba:")
    for label, val in zip(labels, vec):
        print(f"  {label:15} = {val:.3f}")