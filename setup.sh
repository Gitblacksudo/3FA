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

# Instala curl (necesario para descargar kind/kubectl/helm) si no esta presente
ensure_curl(){
  have curl && return 0
  warn "curl no encontrado; intentando instalarlo con el gestor de paquetes..."
  if   have apt-get; then sudo apt-get update -y && sudo apt-get install -y curl
  elif have dnf;     then sudo dnf install -y curl
  elif have yum;     then sudo yum install -y curl
  elif have zypper;  then sudo zypper install -y curl
  elif have pacman;  then sudo pacman -Sy --noconfirm curl
  else warn "No pude instalar curl automaticamente; instalalo a mano (p. ej. sudo apt install curl)"; return 1; fi
  have curl && ok "curl instalado"
}

# Instala el paquete venv/ensurepip de Python si no esta disponible
ensure_venv(){
  python3 -c "import ensurepip" >/dev/null 2>&1 && return 0
  local pyver; pyver="$(python3 -c 'import sys;print(f"{sys.version_info.major}.{sys.version_info.minor}")' 2>/dev/null)"
  warn "El modulo venv (ensurepip) no esta disponible; intentando instalar python${pyver}-venv..."
  if   have apt-get; then sudo apt-get update -y && { sudo apt-get install -y "python${pyver}-venv" || sudo apt-get install -y python3-venv; }
  elif have dnf;     then sudo dnf install -y python3-venv || true
  elif have yum;     then sudo yum install -y python3-venv || true
  elif have zypper;  then sudo zypper install -y python3-venv || true
  else warn "Instala manualmente el paquete venv de tu Python (p. ej. sudo apt install python${pyver}-venv)"; fi
  python3 -c "import ensurepip" >/dev/null 2>&1 && ok "modulo venv disponible"
}

# Instala y activa Docker si no esta disponible
ensure_docker(){
  if ! have docker; then
    info "Instalando Docker..."
    if   have apt-get; then sudo apt-get update -y && sudo apt-get install -y docker.io
    elif have dnf;     then sudo dnf install -y docker
    elif have yum;     then sudo yum install -y docker
    elif have zypper;  then sudo zypper install -y docker
    elif have pacman;  then sudo pacman -Sy --noconfirm docker
    elif have curl;    then curl -fsSL https://get.docker.com | sudo sh
    else warn "No pude instalar Docker; hazlo desde https://docs.docker.com/engine/install/"; return 1; fi
  fi
  # Arrancar y habilitar el servicio
  if have systemctl; then sudo systemctl enable --now docker >/dev/null 2>&1 || sudo systemctl start docker >/dev/null 2>&1 || true; fi
  # Anadir el usuario al grupo docker (para usar docker sin sudo)
  if ! id -nG "$USER" 2>/dev/null | grep -qw docker; then
    sudo usermod -aG docker "$USER" 2>/dev/null || true
    # 'newgrp' activa el grupo sin reiniciar; en Ubuntu minimalista esta en util-linux-extra
    if ! have newgrp && have apt-get; then sudo apt-get install -y util-linux-extra >/dev/null 2>&1 || true; fi
    DOCKER_GROUP_PENDING=1
    warn "Se anadio '$USER' al grupo docker: ejecuta 'newgrp docker' (o cierra y abre sesion) antes de ./run.sh"
  fi
  if docker info >/dev/null 2>&1; then ok "docker operativo"; else warn "docker instalado; reinicia la sesion para usarlo sin sudo"; fi
}

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

# Si hay que descargar herramientas (kind/kubectl/helm), asegurar curl primero
for c in "${MISSING[@]}"; do
  case "$c" in kind|kubectl|helm) ensure_curl || true; break ;; esac
done

for c in "${MISSING[@]}"; do
  case "$c" in
    kind)    install_kind ;;
    kubectl) install_kubectl ;;
    helm)    install_helm ;;
    docker)  ensure_docker || true ;;
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
  ensure_venv || true
  rm -rf "$ROOT/detector/venv"
  if python3 -m venv "$ROOT/detector/venv"; then
    "$ROOT/detector/venv/bin/pip" install --quiet --upgrade pip
    "$ROOT/detector/venv/bin/pip" install --quiet "scikit-learn>=1.5" "pandas>=2.2" "numpy>=1.26" "watchdog>=4.0"
    ok "venv listo en detector/venv con scikit-learn, pandas, numpy y watchdog"
  else
    warn "No se pudo crear el venv. Instala el paquete venv de tu Python (p. ej. sudo apt install python3-venv) y reejecuta ./setup.sh"
  fi
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
if [ "${DOCKER_GROUP_PENDING:-0}" = "1" ]; then
  warn "IMPORTANTE: cierra y abre sesion (o ejecuta 'newgrp docker') para que el grupo docker tenga efecto, luego lanza ./run.sh"
else
  info "Cuando todo este en verde, lanza:  ./run.sh"
fi
