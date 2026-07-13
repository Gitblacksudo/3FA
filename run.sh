#!/usr/bin/env bash
#
# run.sh - Ejecuta el experimento Centinela de extremo a extremo:
#          cluster Kind + audit logging -> escenario victima -> Falco ->
#          entrenamiento del baseline -> deteccion en tiempo real + ataque ->
#          resultados en detector/results.csv.
#
# Requisitos: haber ejecutado ./setup.sh antes. Uso:
#
#     ./run.sh                 # baseline de 50 ventanas (fiel al experimento, ~25 min)
#     WINDOWS=10 ./run.sh      # demo rapida (~6 min)
#
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PY="$ROOT/detector/venv/bin/python"
CLUSTER=centinela
WINDOWS="${WINDOWS:-50}"
AUDIT_DIR="$ROOT/lab/audit-logs"

# setup.sh instala kind/kubectl/helm en ~/.local/bin; asegurar que este en el PATH
export PATH="$HOME/.local/bin:$PATH"

export AUDIT_LOG_PATH="$AUDIT_DIR/audit.log"
export MODEL_PATH="$ROOT/detector/model.pkl"
export THRESHOLD_PATH="$ROOT/detector/threshold.pkl"
export RESULTS_PATH="$ROOT/detector/results.csv"

info(){ printf '\033[1;34m[run]\033[0m %s\n' "$*"; }
have(){ command -v "$1" >/dev/null 2>&1; }

BG_PIDS=()
cleanup(){ info "Limpiando procesos en segundo plano..."; for p in "${BG_PIDS[@]:-}"; do kill "$p" 2>/dev/null || true; done; }
trap cleanup EXIT

[ -x "$PY" ] || { echo "ERROR: no existe $PY. Ejecuta ./setup.sh primero."; exit 1; }

# Verificar que las herramientas necesarias esten disponibles antes de empezar
missing=()
for c in docker kind kubectl helm; do have "$c" || missing+=("$c"); done
if [ "${#missing[@]}" -gt 0 ]; then
  echo "ERROR: no se encuentran estas herramientas: ${missing[*]}"
  echo "  1) Ejecuta ./setup.sh para instalarlas."
  echo "  2) Asegurate de que ~/.local/bin este en el PATH:"
  echo "       export PATH=\"\$HOME/.local/bin:\$PATH\""
  exit 1
fi
if ! docker info >/dev/null 2>&1; then
  echo "ERROR: Docker no esta operativo. Prueba, en orden:"
  echo "  - Arrancar el servicio:           sudo systemctl start docker"
  echo "  - Activar el grupo en la sesion:  newgrp docker   (o cierra y abre sesion / reinicia)"
  exit 1
fi
mkdir -p "$AUDIT_DIR"

# ---------------------------------------------------------------------------
# 1. kind-config con rutas Linux (generado dinamicamente)
# ---------------------------------------------------------------------------
# La politica de auditoria se monta desde un DIRECTORIO, no como fichero suelto:
# Docker sobre Linux convierte un bind-mount de fichero inexistente en un
# directorio vacio, lo que impide que arranque el API Server.
POLICY_DIR="$(mktemp -d)"
cp "$ROOT/lab/audit-policy.yaml" "$POLICY_DIR/audit-policy.yaml"
KCFG="$(mktemp)"
cat > "$KCFG" <<EOF
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
name: $CLUSTER
nodes:
  - role: control-plane
    kubeadmConfigPatches:
      - |
        kind: ClusterConfiguration
        apiServer:
          extraArgs:
            audit-log-path: /var/log/kubernetes/audit.log
            audit-policy-file: /etc/kubernetes/audit/audit-policy.yaml
            audit-log-maxage: "1"
            audit-log-maxbackup: "1"
            audit-log-maxsize: "100"
          extraVolumes:
            - name: audit-policy
              hostPath: /etc/kubernetes/audit
              mountPath: /etc/kubernetes/audit
              readOnly: true
              pathType: DirectoryOrCreate
            - name: audit-logs
              hostPath: /var/log/kubernetes
              mountPath: /var/log/kubernetes
              readOnly: false
              pathType: DirectoryOrCreate
    extraMounts:
      - hostPath: $POLICY_DIR
        containerPath: /etc/kubernetes/audit
        readOnly: true
      - hostPath: $AUDIT_DIR
        containerPath: /var/log/kubernetes
EOF

# ---------------------------------------------------------------------------
# 2. Crear (o reutilizar) el cluster
# ---------------------------------------------------------------------------
if kind get clusters 2>/dev/null | grep -qx "$CLUSTER"; then
  info "El cluster '$CLUSTER' ya existe; se reutiliza."
else
  info "Creando cluster Kind '$CLUSTER' con audit logging declarativo..."
  kind create cluster --config "$KCFG"
fi

# ---------------------------------------------------------------------------
# 3. Escenario victima (ServiceAccount + RBAC + pod)
# ---------------------------------------------------------------------------
info "Desplegando la identidad victima..."
kubectl apply -f "$ROOT/lab/lab-scenario.yaml"
kubectl wait --for=condition=Ready pod/victim-pod --timeout=120s

# ---------------------------------------------------------------------------
# 4. Falco (linea base, ruleset estandar)
# ---------------------------------------------------------------------------
if helm status falco -n falco >/dev/null 2>&1; then
  info "Falco ya instalado; se reutiliza."
else
  info "Instalando Falco (driver eBPF moderno, ruleset estandar)..."
  helm repo add falcosecurity https://falcosecurity.github.io/charts >/dev/null 2>&1 || true
  helm repo update >/dev/null
  helm install falco falcosecurity/falco -n falco --create-namespace \
    --set driver.kind=modern_ebpf --wait --timeout 5m
fi

# ---------------------------------------------------------------------------
# 5. Entrenamiento del baseline
# ---------------------------------------------------------------------------
rm -f "$MODEL_PATH" "$THRESHOLD_PATH"
info "Entrenando el baseline: $WINDOWS ventanas de 30 s (~$((WINDOWS*30/60)) min)..."
( cd "$ROOT/detector" && "$PY" -u compare.py --train --windows "$WINDOWS" ) &
TRAIN_PID=$!; BG_PIDS+=("$TRAIN_PID")
sleep 6   # deja que la ingesta se posicione al final del audit log
( cd "$ROOT/detector" && "$PY" -u generate_legit_traffic.py $((WINDOWS*35)) ) >/dev/null 2>&1 &
TRAFFIC_PID=$!; BG_PIDS+=("$TRAFFIC_PID")
wait "$TRAIN_PID"
kill "$TRAFFIC_PID" 2>/dev/null || true
[ -f "$MODEL_PATH" ] && info "Modelo entrenado y guardado (model.pkl, threshold.pkl)." \
                     || { echo "ERROR: el entrenamiento no genero el modelo."; exit 1; }

# ---------------------------------------------------------------------------
# 6. Deteccion en tiempo real + ataque
# ---------------------------------------------------------------------------
rm -f "$RESULTS_PATH"
info "Iniciando deteccion en tiempo real..."
( cd "$ROOT/detector" && "$PY" -u compare.py ) &
DETECT_PID=$!; BG_PIDS+=("$DETECT_PID")
sleep 6

info "Fase 1/3: trafico legitimo (baseline)..."
( cd "$ROOT/detector" && "$PY" -u generate_legit_traffic.py 60 ) >/dev/null 2>&1
sleep 5

info "Fase 2/3: ATAQUE de reconocimiento RBAC (90 s)..."
echo "  [attack] inicio (UTC): $(date -u +%FT%TZ)"
ATT_END=$(( $(date +%s) + 90 ))
while [ "$(date +%s)" -lt "$ATT_END" ]; do
  kubectl exec victim-pod -- kubectl get secrets -A         >/dev/null 2>&1 || true
  kubectl exec victim-pod -- kubectl get serviceaccounts -A >/dev/null 2>&1 || true
  kubectl exec victim-pod -- kubectl auth can-i --list      >/dev/null 2>&1 || true
  kubectl exec victim-pod -- kubectl get clusterroles       >/dev/null 2>&1 || true
  sleep 3
done
echo "  [attack] fin (UTC): $(date -u +%FT%TZ)"

info "Fase 3/3: retorno a la normalidad (cierra la ultima ventana)..."
( cd "$ROOT/detector" && "$PY" -u generate_legit_traffic.py 60 ) >/dev/null 2>&1
sleep 5
kill "$DETECT_PID" 2>/dev/null || true

# ---------------------------------------------------------------------------
# 7. Resultados
# ---------------------------------------------------------------------------
echo
info "===== Resultados del detector (results.csv) ====="
if have column; then
  column -s, -t "$RESULTS_PATH"
else
  cat "$RESULTS_PATH"
fi
echo
info "===== Ultimas alertas de Falco (linea base) ====="
kubectl logs -n falco -l app.kubernetes.io/instance=falco -c falco --tail 6 2>/dev/null || true
echo
info "Experimento completado."
info "Para eliminar el cluster:  kind delete cluster --name $CLUSTER"
