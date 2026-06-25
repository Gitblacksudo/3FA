"""
Módulo 3 — Modelo de detección de anomalías
Extended Isolation Forest entrenado sobre el comportamiento baseline de la SA.
"""

import numpy as np
import pickle
import os
from sklearn.ensemble import IsolationForest

MODEL_PATH = os.environ.get("MODEL_PATH", r"C:\thesis\detector\model.pkl")
THRESHOLD_PATH = os.environ.get("THRESHOLD_PATH",
                                r"C:\thesis\detector\threshold.pkl")

# Hiperparámetros del modelo
N_ESTIMATORS = 100
MAX_SAMPLES = 256
CONTAMINATION = 0.05
RANDOM_STATE = 42


class AnomalyDetector:
    """
    Detector de anomalías basado en Isolation Forest.
    Un modelo por ServiceAccount.
    """

    def __init__(self):
        self.model = IsolationForest(
            n_estimators=N_ESTIMATORS,
            max_samples=MAX_SAMPLES,
            contamination=CONTAMINATION,
            random_state=RANDOM_STATE
        )
        self.threshold = None
        self.is_trained = False

    def train(self, X: np.ndarray) -> None:
        """
        Entrena el modelo sobre el conjunto de baseline (comportamiento legítimo).
        Calcula el umbral como el percentil 5 de los scores de entrenamiento
        (iForest devuelve scores negativos: más negativo = más anómalo).
        """
        if len(X) < MAX_SAMPLES:
            print(f"[model] AVISO: solo {len(X)} ventanas de entrenamiento. "
                  f"Se recomiendan al menos {MAX_SAMPLES}.")

        self.model.fit(X)
        scores = self.model.score_samples(X)
        # Umbral: percentil 5 (el 5% más anómalo del baseline)
        self.threshold = np.percentile(scores, 5)
        self.is_trained = True
        print(f"[model] Modelo entrenado con {len(X)} ventanas.")
        print(f"[model] Umbral de anomalía: {self.threshold:.4f}")

    def score(self, x: np.ndarray) -> float:
        """
        Calcula el score de anomalía de un vector.
        Score más negativo = más anómalo.
        """
        if not self.is_trained:
            raise RuntimeError("El modelo no ha sido entrenado.")
        return float(self.model.score_samples(x.reshape(1, -1))[0])

    def is_anomaly(self, x: np.ndarray) -> tuple[bool, float]:
        """
        Devuelve (es_anomalía, score).
        True si el score está por debajo del umbral.
        """
        s = self.score(x)
        return s < self.threshold, s

    def save(self, model_path: str = MODEL_PATH,
             threshold_path: str = THRESHOLD_PATH) -> None:
        """Guarda el modelo y el umbral en disco."""
        with open(model_path, "wb") as f:
            pickle.dump(self.model, f)
        with open(threshold_path, "wb") as f:
            pickle.dump(self.threshold, f)
        print(f"[model] Modelo guardado en {model_path}")

    def load(self, model_path: str = MODEL_PATH,
             threshold_path: str = THRESHOLD_PATH) -> None:
        """Carga el modelo y el umbral desde disco."""
        with open(model_path, "rb") as f:
            self.model = pickle.load(f)
        with open(threshold_path, "rb") as f:
            self.threshold = pickle.load(f)
        self.is_trained = True
        print(f"[model] Modelo cargado desde {model_path}")


if __name__ == "__main__":
    np.random.seed(42)

    # Baseline realista: SA que principalmente hace get/list
    # sobre pods y configmaps, raramente toca secrets
    X_train = np.column_stack([
        np.random.beta(5, 2, 300),   # f_get: alto
        np.random.beta(4, 2, 300),   # f_list: alto
        np.random.beta(1, 9, 300),   # f_create: muy bajo
        np.random.beta(1, 9, 300),   # f_delete: muy bajo
        np.random.beta(1, 8, 300),   # f_sensitive: bajo
        np.random.beta(1, 9, 300),   # f_errors: muy bajo
        np.random.beta(2, 5, 300),   # f_unique: moderado
    ])
    # Normalizar filas a [0,1]
    X_train = X_train / X_train.sum(axis=1, keepdims=True)

    detector = AnomalyDetector()
    detector.train(X_train)

    # Ventana legítima: parecida al baseline
    x_normal = np.array([0.5, 0.35, 0.05, 0.0, 0.1, 0.0, 0.2])
    x_normal = x_normal / x_normal.sum()
    anomaly, score = detector.is_anomaly(x_normal)
    print(f"\nVentana NORMAL  → score={score:.4f} | anomalía={anomaly}")

    # Ventana de ataque: muchos list, muchos sensibles, errores, alta cardinalidad
    x_attack = np.array([0.05, 0.55, 0.15, 0.05, 0.8, 0.25, 0.7])
    x_attack = x_attack / x_attack.sum()
    anomaly, score = detector.is_anomaly(x_attack)
    print(f"Ventana ATAQUE  → score={score:.4f} | anomalía={anomaly}")

    detector.save()
