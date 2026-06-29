"""
Generador de tráfico legítimo para entrenar el baseline del detector.
Simula el comportamiento normal de un microservicio que consulta
pods y configmaps periódicamente — sin tocar secrets ni roles.
"""

import subprocess
import time
import random

COMMANDS = [
    ["kubectl", "exec", "victim-pod", "--",
     "kubectl", "get", "pods", "-n", "default"],
    ["kubectl", "exec", "victim-pod", "--",
     "kubectl", "get", "configmaps", "-n", "default"],
    ["kubectl", "exec", "victim-pod", "--",
     "kubectl", "get", "pods", "-n", "kube-system"],
    ["kubectl", "exec", "victim-pod", "--",
     "kubectl", "get", "serviceaccounts", "-n", "default"],
]

def generate(duration_seconds: int = 1800, interval_seconds: float = 5.0):
    """
    Genera tráfico legítimo durante duration_seconds segundos.
    Por defecto 30 minutos — suficiente para 6 ventanas de 5 minutos.
    """
    print(f"[traffic] Generando tráfico legítimo durante "
          f"{duration_seconds // 60} minutos...")
    print(f"[traffic] Intervalo entre peticiones: {interval_seconds}s")
    print("[traffic] Ctrl+C para detener.\n")

    start = time.time()
    count = 0

    while time.time() - start < duration_seconds:
        cmd = random.choice(COMMANDS)
        try:
            subprocess.run(cmd, capture_output=True, timeout=10)
            count += 1
            elapsed = int(time.time() - start)
            print(f"[{elapsed:5}s] petición #{count}: {' '.join(cmd[-3:])}")
        except subprocess.TimeoutExpired:
            print("[traffic] timeout, continuando...")
        except Exception as e:
            print(f"[traffic] error: {e}")

        time.sleep(interval_seconds + random.uniform(-1, 1))

    print(f"\n[traffic] Completado: {count} peticiones en "
          f"{duration_seconds // 60} minutos.")

if __name__ == "__main__":
    import sys
    duration = int(sys.argv[1]) if len(sys.argv) > 1 else 1800
    generate(duration_seconds=duration)