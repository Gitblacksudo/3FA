"""
Módulo 4 — Compare
Pipeline completo: ingesta → features → inferencia → alerta.
Registra alertas del detector IA junto a las de Falco en el mismo timeline.
"""

import os
import csv
from datetime import datetime, timezone
from pathlib import Path

from ingest import stream_events
from features import WindowAggregator
from model import AnomalyDetector

# Rutas
RESULTS_PATH = os.environ.get(
    "RESULTS_PATH",
    r"C:\thesis\detector\results.csv"
)
MODEL_PATH = os.environ.get("MODEL_PATH", r"C:\thesis\detector\model.pkl")
THRESHOLD_PATH = os.environ.get(
    "THRESHOLD_PATH",
    r"C:\thesis\detector\threshold.pkl"
)

# Columnas del CSV de resultados
CSV_COLUMNS = [
    "timestamp",
    "window_start",
    "window_end",
    "n_events",
    "f_get", "f_list", "f_create", "f_delete",
    "f_sensitive", "f_errors", "f_unique",
    "score",
    "is_anomaly",
    "detector"
]


def init_results_csv(path: str) -> None:
    """Crea el CSV de resultados si no existe."""
    if not Path(path).exists():
        with open(path, "w", newline="", encoding="utf-8") as f:
            writer = csv.DictWriter(f, fieldnames=CSV_COLUMNS)
            writer.writeheader()
        print(f"[compare] CSV de resultados creado en {path}")


def write_result(path: str, row: dict) -> None:
    """Añade una fila al CSV de resultados."""
    with open(path, "a", newline="", encoding="utf-8") as f:
        writer = csv.DictWriter(f, fieldnames=CSV_COLUMNS)
        writer.writerow(row)


def run(sa_name: str = "victim-sa",
        train_mode: bool = False,
        n_train_windows: int = 20) -> None:
    """
    Pipeline principal.

    train_mode=True  → recoge ventanas de baseline y entrena el modelo.
    train_mode=False → carga el modelo y emite alertas en tiempo real.
    """
    aggregator = WindowAggregator()
    detector = AnomalyDetector()

    if train_mode:
        print(f"[compare] MODO ENTRENAMIENTO: recogiendo {n_train_windows} "
              f"ventanas de baseline para SA '{sa_name}'...")
        X_train = []
        window_count = 0

        for event in stream_events(sa_name=sa_name):
            features = aggregator.add(event)
            if features is not None:
                X_train.append(features)
                window_count += 1
                print(f"[compare] Ventana {window_count}/{n_train_windows} "
                      f"recogida.")
                if window_count >= n_train_windows:
                    break

        # Entrena y guarda
        import numpy as np
        detector.train(np.array(X_train))
        detector.save(MODEL_PATH, THRESHOLD_PATH)
        print("[compare] Entrenamiento completado. "
              "Ejecuta de nuevo sin --train para detectar anomalías.")
        return

    # Modo inferencia
    detector.load(MODEL_PATH, THRESHOLD_PATH)
    init_results_csv(RESULTS_PATH)

    print(f"[compare] MODO DETECCIÓN activo para SA '{sa_name}'")
    print(f"[compare] Umbral cargado: {detector.threshold:.4f}")
    print(f"[compare] Resultados en: {RESULTS_PATH}")
    print("-" * 70)

    window_start = None

    for event in stream_events(sa_name=sa_name):
        ts = event.get("requestReceivedTimestamp", "")

        if window_start is None:
            window_start = ts

        features = aggregator.add(event)

        if features is not None:
            is_anom, score = detector.is_anomaly(features)
            window_end = ts
            now = datetime.now(timezone.utc).isoformat()

            row = {
                "timestamp": now,
                "window_start": window_start,
                "window_end": window_end,
                "n_events": aggregator.last_window_n,
                "f_get":       round(float(features[0]), 4),
                "f_list":      round(float(features[1]), 4),
                "f_create":    round(float(features[2]), 4),
                "f_delete":    round(float(features[3]), 4),
                "f_sensitive": round(float(features[4]), 4),
                "f_errors":    round(float(features[5]), 4),
                "f_unique":    round(float(features[6]), 4),
                "score":       round(score, 4),
                "is_anomaly":  is_anom,
                "detector":    "IA"
            }

            write_result(RESULTS_PATH, row)
            window_start = ts

            status = "🚨 ANOMALÍA" if is_anom else "✅ normal  "
            print(f"[{window_end}] {status} | score={score:.4f} | "
                  f"sensitive={features[4]:.2f} list={features[1]:.2f} "
                  f"unique={features[6]:.2f}")


if __name__ == "__main__":
    import sys
    train = "--train" in sys.argv
    n_windows = 20
    if "--windows" in sys.argv:
        n_windows = int(sys.argv[sys.argv.index("--windows") + 1])
    run(train_mode=train, n_train_windows=n_windows)