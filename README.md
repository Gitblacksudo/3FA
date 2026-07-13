# Centinela — Detección de anomalías sobre ServiceAccounts de Kubernetes

Detector de anomalías comportamentales **no supervisado** que analiza los *audit logs*
del API Server de Kubernetes para identificar **movimiento lateral por abuso de
ServiceAccount** (enumeración de *secrets*, RBAC, etc.). Entrena un modelo *Isolation
Forest* sobre el comportamiento legítimo de cada identidad y marca como anomalía las
ventanas que se desvían del patrón aprendido. Se evalúa frente a **Falco** (con su
*ruleset* estándar) como línea base.

> Trabajo Fin de Máster — Máster en Ciberseguridad, Universidad Complutense de Madrid (UCM).

## Requisitos

| Herramienta | Comprobar con |
|-------------|---------------|
| Docker      | `docker --version` |
| Kind        | `kind version` |
| kubectl     | `kubectl version --client` |
| Helm        | `helm version` |
| Python 3.12+ | `python3 --version` |

`setup.sh` instala automáticamente **kind**, **kubectl** y **helm** si faltan; para
**Docker** y **Python** indica cómo instalarlos.

## Instalación y ejecución (Linux)

```bash
git clone https://github.com/Gitblacksudo/3FA
cd 3FA
chmod +x setup.sh run.sh
./setup.sh      # verifica/instala requisitos y crea el entorno del detector
./run.sh        # levanta el laboratorio y ejecuta el experimento completo (~25 min)
```

Para una **demostración rápida** (~6 min) con un baseline reducido:

```bash
WINDOWS=10 ./run.sh
```

Al terminar, `run.sh` muestra el contenido de `detector/results.csv` (las ventanas
evaluadas con su veredicto) y las últimas alertas de Falco. Para eliminar el clúster:

```bash
kind delete cluster --name centinela
```

## Estructura

```
3FA/
├── setup.sh          # Prepara el entorno (requisitos + venv del detector)
├── run.sh            # Ejecuta el experimento de extremo a extremo
├── lab/              # Laboratorio: cluster Kind, RBAC víctima, Falco, ataque
└── detector/         # Detector de anomalías (Python)
```

- `detector/ingest.py` — lee el audit log y filtra por ServiceAccount.
- `detector/features.py` — 7 *features* por ventana de 30 s.
- `detector/model.py` — Isolation Forest + umbral (percentil 5).
- `detector/compare.py` — *pipeline* de entrenamiento (`--train`) y detección.

## Notas

- Pensado para **Linux**; funciona igualmente en una VM Linux o en WSL2.
- Falco usa el driver `modern_ebpf` (requiere kernel con BTF). Si no estuviera
  disponible, cambiar a `--set driver.kind=ebpf` en `run.sh`.
