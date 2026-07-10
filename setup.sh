#!/usr/bin/env bash
#
# setup.sh - Verifica e instala los requisitos del laboratorio Centinela y
#            configura el entorno Python del detector.
#
# Pensado para Linux (Debian/Ubuntu). kind, kubectl y helm se instalan en
# ~/.local/bin sin privilegios; Docker y Python requieren acción del usuario
# (se indican los comandos). Uso:
#
#     ./setup.sh
#
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

info(){ printf '\033[1;34m[setup]\033[0m %s\n' "$*"; }
ok(){   printf '  \033[1;32m✓\033[0m %s\n' "$*"; }
warn(){ printf '  \033[1;33m!\033[0m %s\n' "$*"; }
have(){ command -v "$1" >/dev/null 2>&1; }

ARCH=amd64
LOCALBIN="$HOME/.local/bin"
mkdir -p "$LOCALBIN"
export PATH="$LOCALBIN:$PATH"

# ---------------------------------------------------------------------------
# 1. Verificacion de requisitos
# ---------------------------------------------------------------------------
info "Verificando requisitos..."
MISSING=()
for c in docker kind kubectl helm python3; do
  if have "$c"; then ok "$c ($(command -v "$c"))"; else warn "$c: NO encontrado"; MISSING+=("$c"); fi
done

# ---------------------------------------------------------------------------
# 2. Instalacion de los que falten (sin privilegios: ~/.local/bin)
# ---------------------------------------------------------------------------
install_kind(){
  info "Instalando kind en $LOCALBIN..."
  curl -fsSLo "$LOCALBIN/kind" "https://kind.sigs.k8s.io/dl/v0.24.0/kind-linux-${ARCH}"
  chmod +x "$LOCALBIN/kind"; ok "kind instalado"
}
install_kubectl(){
  info "Instalando kubectl en $LOCALBIN..."
  local v; v="$(curl -fsSL https://dl.k8s.io/release/stable.txt)"
  curl -fsSLo "$LOCALBIN/kubectl" "https://dl.k8s.io/release/${v}/bin/linux/${ARCH}/kubectl"
  chmod +x "$LOCALBIN/kubectl"; ok "kubectl instalado ($v)"
}
install_helm(){
  info "Instalando helm en $LOCALBIN..."
  curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 \
    | HELM_INSTALL_DIR="$LOCALBIN" USE_SUDO=false bash >/dev/null
  ok "helm instalado"
}

for c in "${MISSING[@]}"; do
  case "$c" in
    kind)    install_kind ;;
    kubectl) install_kubectl ;;
    helm)    install_helm ;;
    docker)  warn "Instala Docker Engine: https://docs.docker.com/engine/install/"
             warn "  y anade tu usuario al grupo docker:  sudo usermod -aG docker \$USER  (requiere reiniciar sesion)";;
    python3) warn "Instala Python 3.12+:  sudo apt update && sudo apt install -y python3 python3-venv python3-pip";;
  esac
done

# ---------------------------------------------------------------------------
# 3. Comprobar que Docker esta operativo
# ---------------------------------------------------------------------------
if have docker; then
  if docker info >/dev/null 2>&1; then ok "docker operativo"
  else warn "docker instalado pero no accesible (arranca el servicio o revisa el grupo 'docker')"; fi
fi

# ---------------------------------------------------------------------------
# 4. Entorno Python del detector
# ---------------------------------------------------------------------------
if have python3; then
  info "Creando el entorno virtual del detector..."
  python3 -m venv "$ROOT/detector/venv"
  "$ROOT/detector/venv/bin/pip" install --quiet --upgrade pip
  "$ROOT/detector/venv/bin/pip" install --quiet "scikit-learn>=1.5" "pandas>=2.2" "numpy>=1.26" "watchdog>=4.0"
  ok "venv listo en detector/venv con scikit-learn, pandas, numpy y watchdog"
else
  warn "Sin python3 no se puede crear el venv; instalalo y vuelve a ejecutar ./setup.sh"
fi

# ---------------------------------------------------------------------------
# 5. Directorio de audit logs
# ---------------------------------------------------------------------------
mkdir -p "$ROOT/lab/audit-logs"; ok "directorio lab/audit-logs preparado"

echo
info "Setup finalizado."
if [ "${#MISSING[@]}" -gt 0 ]; then
  warn "Requisitos que faltaban: ${MISSING[*]}. Revisa los avisos de arriba."
fi
case ":$PATH:" in
  *":$LOCALBIN:"*) : ;;
  *) warn "Anade ~/.local/bin al PATH:  export PATH=\"\$HOME/.local/bin:\$PATH\"";;
esac
info "Cuando todo este en verde, lanza:  ./run.sh"
