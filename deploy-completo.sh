#!/usr/bin/env bash
# ==============================================================================
# deploy-completo.sh
# Script ÚNICO e AUTO-CONTIDO para Automação do Kubernetes + Longhorn PoC
#
# Não possui dependências externas de arquivos.
# Cria as VMs no Multipass, inicializa o K8s, instala o Longhorn e executa o
# teste de persistência e resiliência a falhas de ponta a ponta.
#
# Uso:
#   ./deploy-completo.sh            # Executa todo o provisionamento e testes
#   ./deploy-completo.sh --cleanup  # Remove e limpa todas as VMs criadas
# ==============================================================================
set -euo pipefail

# ------------------------------------------------------------------------------
# 1. Parâmetros Configuráveis (Ajuste caso a máquina tenha menos recursos)
# ------------------------------------------------------------------------------
MASTER_NAME="master"
WORKER1_NAME="worker1"
WORKER2_NAME="worker2"

VM_CPUS="2"
VM_MEMORY="4G"
VM_DISK="40G"
UBUNTU_RELEASE="22.04"

K8S_VERSION="1.29"
POD_NETWORK_CIDR="10.244.0.0/16"
LONGHORN_REPLICAS="2"

# Cores para formatação
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
RED='\033[0;31m'
BOLD='\033[1m'
NC='\033[0m'

VMS=("$MASTER_NAME" "$WORKER1_NAME" "$WORKER2_NAME")

# ------------------------------------------------------------------------------
# 2. Modo de Limpeza (--cleanup)
# ------------------------------------------------------------------------------
if [[ "${1:-}" == "--cleanup" || "${1:-}" == "-c" ]]; then
    echo -e "${RED}${BOLD}>>> Modo de Limpeza Ativado!${NC}"
    echo -e "As seguintes VMs serão excluídas e expurgadas: ${YELLOW}${VMS[*]}${NC}"
    read -rp "Confirma a destruição das VMs? (s/N): " CONFIRM
    if [[ ! "$CONFIRM" =~ ^[sS]$ ]]; then
        echo "Operação cancelada."
        exit 0
    fi
    for vm in "${VMS[@]}"; do
        if multipass info "$vm" &> /dev/null; then
            echo "Removendo '$vm'..."
            multipass delete "$vm"
        fi
    done
    echo "Expurgando VMs..."
    multipass purge
    echo -e "${GREEN}[OK] Ambiente limpo com sucesso!${NC}"
    multipass list
    exit 0
fi

START_TIME=$(date +%s)

echo -e "${CYAN}${BOLD}"
echo "========================================================================"
echo "    AUTOMAÇÃO COMPLETA: KUBERNETES + LONGHORN DISTRIBUTED STORAGE POC   "
echo "                       (Script Único Auto-Contido)                      "
echo "========================================================================"
echo -e "${NC}"
echo -e "Nós a provisionar: ${BOLD}$MASTER_NAME, $WORKER1_NAME, $WORKER2_NAME${NC}"
echo -e "Recursos por nó:  ${BOLD}${VM_CPUS} CPUs | ${VM_MEMORY} RAM | ${VM_DISK} Disco${NC}"
echo -e "Versão do K8s:    ${BOLD}v$K8S_VERSION${NC}"
echo -e "CNI:              ${BOLD}Flannel ($POD_NETWORK_CIDR)${NC}"
echo -e "Armazenamento:    ${BOLD}Longhorn ($LONGHORN_REPLICAS réplicas)${NC}"
echo "------------------------------------------------------------------------"

# ------------------------------------------------------------------------------
# 3. Pré-requisitos do Host (Detecção e Instalação Automática do Multipass)
# ------------------------------------------------------------------------------
if ! command -v multipass &> /dev/null; then
    echo -e "${YELLOW}>>> Multipass não encontrado no sistema. Instalando automaticamente...${NC}"

    if ! command -v snap &> /dev/null; then
        echo -e "${BLUE}>>> Instalando snapd...${NC}"
        if command -v apt-get &> /dev/null; then
            sudo apt-get update && sudo apt-get install -y snapd
        elif command -v dnf &> /dev/null; then
            sudo dnf install -y snapd
            sudo ln -s /var/lib/snapd/snap /snap || true
        else
            echo -e "${RED}[ERRO] Não foi possível instalar o snapd automaticamente. Instale o snap manualmente.${NC}"
            exit 1
        fi
    fi

    echo -e "${BLUE}>>> Instalando o Multipass via snap...${NC}"
    sudo snap install multipass
fi

# Aguardar o daemon do Multipass inicializar
echo -e "${BLUE}>>> Verificando comunicação com o serviço do Multipass...${NC}"
for i in {1..20}; do
    if multipass list &> /dev/null; then
        break
    fi
    echo "Aguardando o serviço do Multipass inicializar... (${i}/20)"
    sleep 2
done

if ! multipass list &> /dev/null; then
    echo -e "${RED}[ERRO] O serviço do Multipass não está respondendo.${NC}"
    echo -e "Tente reiniciar o serviço com: ${YELLOW}sudo snap restart multipass${NC}"
    exit 1
fi
echo -e "${GREEN}[OK] Multipass instalado e operante.${NC}"

# Diretório temporário para gerar cloud-init e manifestos (apagado ao encerrar)
TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT

# ------------------------------------------------------------------------------
# 4. Geração Embutida do Cloud-Init
# ------------------------------------------------------------------------------
CLOUD_INIT_FILE="$TMP_DIR/cloud-init.yaml"
cat << 'EOF' > "$CLOUD_INIT_FILE"
#cloud-config

write_files:
  - path: /etc/modules-load.d/k8s.conf
    owner: root:root
    permissions: '0644'
    content: |
      overlay
      br_netfilter

  - path: /etc/sysctl.d/k8s.conf
    owner: root:root
    permissions: '0644'
    content: |
      net.bridge.bridge-nf-call-iptables  = 1
      net.bridge.bridge-nf-call-ip6tables = 1
      net.ipv4.ip_forward                 = 1

packages:
  - apt-transport-https
  - ca-certificates
  - curl
  - gpg
  - containerd
  - open-iscsi
  - nfs-common

runcmd:
  # Desativar swap
  - swapoff -a
  - sed -i '/ swap / s/^\(.*\)$/#\1/g' /etc/fstab

  # Carregar módulos e aplicar sysctl
  - modprobe overlay
  - modprobe br_netfilter
  - sysctl --system

  # Configurar containerd
  - mkdir -p /etc/containerd
  - containerd config default > /etc/containerd/config.toml
  - sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml
  - systemctl restart containerd
  - systemctl enable containerd

  # Repositório Kubernetes v1.29 e instalação dos binários
  - mkdir -p /etc/apt/keyrings
  - curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.29/deb/Release.key | gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
  - echo 'deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v1.29/deb/ /' > /etc/apt/sources.list.d/kubernetes.list
  - apt-get update
  - apt-get install -y kubelet kubeadm kubectl
  - apt-mark hold kubelet kubeadm kubectl

  # Ativar serviço iSCSI para o Longhorn
  - systemctl enable --now iscsid
EOF

# ------------------------------------------------------------------------------
# 5. [Fase 0] Criação das Máquinas Virtuais no Multipass
# ------------------------------------------------------------------------------
echo -e "\n${BLUE}=== [1/4] Provisionando Máquinas Virtuais no Multipass ===${NC}"
for vm in "${VMS[@]}"; do
    if multipass info "$vm" &> /dev/null; then
        echo -e "${YELLOW}[AVISO] A VM '$vm' já existe. Pulando criação.${NC}"
    else
        echo -e "${GREEN}>>> Lançando VM '$vm' ($VM_CPUS CPUs, $VM_MEMORY RAM, $VM_DISK Disco)...${NC}"
        multipass launch "$UBUNTU_RELEASE" \
            --name "$vm" \
            --cpus "$VM_CPUS" \
            --memory "$VM_MEMORY" \
            --disk "$VM_DISK" \
            --cloud-init "$CLOUD_INIT_FILE"
    fi
done

echo -e "${BLUE}>>> Aguardando a conclusão do Cloud-Init em todas as VMs...${NC}"
for vm in "${VMS[@]}"; do
    echo -e "Aguardando '$vm'..."
    multipass exec "$vm" -- cloud-init status --wait
    echo -e "${GREEN}[OK] '$vm' provisionada.${NC}"
done

# ------------------------------------------------------------------------------
# 6. [Fase 1] Inicialização do Kubernetes e Malha de Rede
# ------------------------------------------------------------------------------
echo -e "\n${BLUE}=== [2/4] Inicializando Cluster Kubernetes ===${NC}"

ALREADY_INIT=$(multipass exec "$MASTER_NAME" -- bash -c "test -f /etc/kubernetes/admin.conf && echo 'yes' || echo 'no'")
if [[ "$ALREADY_INIT" == "yes" ]]; then
    echo -e "${YELLOW}[AVISO] Control-Plane já inicializado no nó '$MASTER_NAME'.${NC}"
else
    echo -e "${BLUE}>>> Executando kubeadm init no nó '$MASTER_NAME'...${NC}"
    multipass exec "$MASTER_NAME" -- sudo kubeadm init \
        --pod-network-cidr="$POD_NETWORK_CIDR" \
        --apiserver-advertise-address="$(multipass exec "$MASTER_NAME" -- bash -c "hostname -I | awk '{print \$1}'")"

    # Configura kubeconfig
    multipass exec "$MASTER_NAME" -- bash -c "mkdir -p \$HOME/.kube && sudo cp -f /etc/kubernetes/admin.conf \$HOME/.kube/config && sudo chown \$(id -u):\$(id -g) \$HOME/.kube/config"
fi

echo -e "${BLUE}>>> Aplicando plugin de rede Flannel...${NC}"
multipass exec "$MASTER_NAME" -- kubectl apply -f https://github.com/flannel-io/flannel/releases/latest/download/kube-flannel.yml

echo -e "${BLUE}>>> Gerando token de join para conectar os workers...${NC}"
JOIN_CMD=$(multipass exec "$MASTER_NAME" -- sudo kubeadm token create --print-join-command)

WORKERS=("$WORKER1_NAME" "$WORKER2_NAME")
for worker in "${WORKERS[@]}"; do
    IS_JOINED=$(multipass exec "$worker" -- bash -c "test -f /etc/kubernetes/kubelet.conf && echo 'yes' || echo 'no'")
    if [[ "$IS_JOINED" == "yes" ]]; then
        echo -e "${YELLOW}[AVISO] Nó '$worker' já conectado ao cluster.${NC}"
    else
        echo -e "${GREEN}>>> Conectando nó '$worker' ao cluster...${NC}"
        multipass exec "$worker" -- sudo bash -c "$JOIN_CMD"
    fi
done

echo -e "${BLUE}>>> Aguardando todos os nós atingirem o status 'Ready'...${NC}"
multipass exec "$MASTER_NAME" -- kubectl wait --for=condition=Ready nodes --all --timeout=300s
echo -e "${GREEN}[OK] Cluster Kubernetes 100% operacional!${NC}"
multipass exec "$MASTER_NAME" -- kubectl get nodes -o wide

# ------------------------------------------------------------------------------
# 7. [Fase 2] Instalação do Longhorn via Helm
# ------------------------------------------------------------------------------
echo -e "\n${BLUE}=== [3/4] Instalando e Configurando o Longhorn ===${NC}"

HELM_INSTALLED=$(multipass exec "$MASTER_NAME" -- bash -c "command -v helm &>/dev/null && echo 'yes' || echo 'no'")
if [[ "$HELM_INSTALLED" == "no" ]]; then
    echo -e "${BLUE}>>> Instalando Helm no master...${NC}"
    multipass exec "$MASTER_NAME" -- bash -c "curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash"
fi

echo -e "${BLUE}>>> Adicionando repositório do Longhorn...${NC}"
multipass exec "$MASTER_NAME" -- bash -c "helm repo add longhorn https://charts.longhorn.io && helm repo update"

LH_INSTALLED=$(multipass exec "$MASTER_NAME" -- bash -c "helm status longhorn -n longhorn-system &>/dev/null && echo 'yes' || echo 'no'")
if [[ "$LH_INSTALLED" == "no" ]]; then
    echo -e "${BLUE}>>> Instalando Longhorn via Helm (Réplicas: $LONGHORN_REPLICAS)...${NC}"
    multipass exec "$MASTER_NAME" -- bash -c "
        helm install longhorn longhorn/longhorn \
          --namespace longhorn-system \
          --create-namespace \
          --set defaultSettings.defaultReplicaCount=$LONGHORN_REPLICAS
    "
fi

echo -e "${BLUE}>>> Aguardando componentes do Longhorn ficarem operacionais (rollout)...${NC}"
multipass exec "$MASTER_NAME" -- kubectl -n longhorn-system rollout status daemonset/longhorn-manager --timeout=400s
multipass exec "$MASTER_NAME" -- kubectl -n longhorn-system rollout status deployment/longhorn-driver-deployer --timeout=400s

echo -e "${BLUE}>>> Definindo StorageClass 'longhorn' como padrão...${NC}"
multipass exec "$MASTER_NAME" -- kubectl patch storageclass longhorn \
    -p '{"metadata": {"annotations":{"storageclass.kubernetes.io/is-default-class":"true"}}}'
echo -e "${GREEN}[OK] Longhorn configurado como StorageClass padrão.${NC}"

# ------------------------------------------------------------------------------
# 8. [Fase 3] Teste de Persistência e Failover / Resiliência
# ------------------------------------------------------------------------------
echo -e "\n${BLUE}=== [4/4] Executando Teste Automatizado de Persistência e Resiliência ===${NC}"

# Criação dos manifestos no nó master
multipass exec "$MASTER_NAME" -- bash -c 'cat << "EOF" > /tmp/pvc.yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: longhorn-pvc-teste
spec:
  accessModes:
    - ReadWriteOnce
  storageClassName: longhorn
  resources:
    requests:
      storage: 1Gi
EOF'

multipass exec "$MASTER_NAME" -- bash -c 'cat << "EOF" > /tmp/app.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: app-persistente
spec:
  replicas: 1
  selector:
    matchLabels:
      app: app-persistente
  template:
    metadata:
      labels:
        app: app-persistente
    spec:
      containers:
      - name: app
        image: nginx:alpine
        volumeMounts:
        - name: storage
          mountPath: /usr/share/nginx/html
      volumes:
      - name: storage
        persistentVolumeClaim:
          claimName: longhorn-pvc-teste
EOF'

echo -e "${BLUE}>>> Criando PVC de teste...${NC}"
multipass exec "$MASTER_NAME" -- kubectl apply -f /tmp/pvc.yaml

echo -e "${BLUE}>>> Aguardando PVC atingir status 'Bound'...${NC}"
for i in {1..30}; do
    STATUS=$(multipass exec "$MASTER_NAME" -- kubectl get pvc longhorn-pvc-teste -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
    if [[ "$STATUS" == "Bound" ]]; then
        echo -e "${GREEN}[OK] PVC vinculado (Bound).${NC}"
        break
    fi
    sleep 2
done

echo -e "${BLUE}>>> Fazendo deploy do NGINX persistente...${NC}"
multipass exec "$MASTER_NAME" -- kubectl apply -f /tmp/app.yaml
multipass exec "$MASTER_NAME" -- kubectl rollout status deployment/app-persistente --timeout=180s

ORIGINAL_POD=$(multipass exec "$MASTER_NAME" -- kubectl get pod -l app=app-persistente --field-selector status.phase=Running -o jsonpath='{.items[0].metadata.name}')
ACTIVE_WORKER=$(multipass exec "$MASTER_NAME" -- kubectl get pod "$ORIGINAL_POD" -o jsonpath='{.spec.nodeName}')
echo -e "${GREEN}>>> Pod '$ORIGINAL_POD' rodando no nó: ${YELLOW}$ACTIVE_WORKER${NC}"

# Gravação de dado exclusivo
TEST_TOKEN="POC_LONGHORN_PERSISTENCE_TOKEN_$(date +%s)_$RANDOM"
echo -e "${BLUE}>>> Gravando token exclusivo no volume persistente: ${YELLOW}$TEST_TOKEN${NC}"
multipass exec "$MASTER_NAME" -- kubectl exec "$ORIGINAL_POD" -- sh -c "echo '$TEST_TOKEN' > /usr/share/nginx/html/index.html"

# Confirmar leitura inicial
INITIAL_READ=$(multipass exec "$MASTER_NAME" -- kubectl exec "$ORIGINAL_POD" -- cat /usr/share/nginx/html/index.html | tr -d '\r\n')
if [[ "$INITIAL_READ" != "$TEST_TOKEN" ]]; then
    echo -e "${RED}[ERRO] Falha ao gravar dados iniciais no volume!${NC}"
    exit 1
fi
echo -e "${GREEN}[OK] Leitura inicial validada com sucesso.${NC}"

# Simulação de queda forçada do worker
echo -e "\n${YELLOW}===============================================================${NC}"
echo -e "${YELLOW}>>> SIMULANDO FALHA CATASTRÓFICA: Desligando nó '$ACTIVE_WORKER'...${NC}"
echo -e "${YELLOW}===============================================================${NC}"
multipass stop "$ACTIVE_WORKER"

echo -e "${BLUE}>>> Nó '$ACTIVE_WORKER' desligado. Aguardando detecção pelo Kubernetes...${NC}"
sleep 15

# Liberação da trava de segurança do Longhorn (Multi-Attach protection)
echo -e "${BLUE}>>> Forçando exclusão do pod no nó morto para destravar o volume...${NC}"
multipass exec "$MASTER_NAME" -- kubectl delete pod "$ORIGINAL_POD" --force --grace-period=0 2>/dev/null || true

# Aguardar subida do novo Pod no outro worker
echo -e "${BLUE}>>> Aguardando novo Pod ser instanciado no worker sobrevivente...${NC}"
NEW_POD=""
for i in {1..45}; do
    POD_CANDIDATE=$(multipass exec "$MASTER_NAME" -- kubectl get pod -l app=app-persistente --field-selector status.phase=Running -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
    if [[ -n "$POD_CANDIDATE" && "$POD_CANDIDATE" != "$ORIGINAL_POD" ]]; then
        NEW_POD="$POD_CANDIDATE"
        break
    fi
    sleep 3
done

if [[ -z "$NEW_POD" ]]; then
    echo -e "${RED}[ERRO] Timeout aguardando novo Pod no nó sobrevivente!${NC}"
    multipass start "$ACTIVE_WORKER" || true
    exit 1
fi

SURVIVING_WORKER=$(multipass exec "$MASTER_NAME" -- kubectl get pod "$NEW_POD" -o jsonpath='{.spec.nodeName}')
echo -e "${GREEN}[OK] Novo Pod '$NEW_POD' operacional no nó: ${YELLOW}$SURVIVING_WORKER${NC}"

# Validação do conteúdo
echo -e "${BLUE}>>> Verificando integridade dos dados pós-queda...${NC}"
RECOVERED_DATA=$(multipass exec "$MASTER_NAME" -- kubectl exec "$NEW_POD" -- cat /usr/share/nginx/html/index.html | tr -d '\r\n')

echo -e "Dado original gravado:     ${YELLOW}$TEST_TOKEN${NC}"
echo -e "Dado recuperado pós-queda:   ${GREEN}$RECOVERED_DATA${NC}"

if [[ "$RECOVERED_DATA" == "$TEST_TOKEN" ]]; then
    echo -e "\n${GREEN}========================================================================${NC}"
    echo -e "${GREEN}[SUCESSO] TESTE DE RESILIÊNCIA CONCLUÍDO COM SUCESSO TOTAL!${NC}"
    echo -e "${GREEN}O Longhorn manteve os dados íntegros após a queda forçada do nó.${NC}"
    echo -e "${GREEN}========================================================================${NC}"
else
    echo -e "${RED}[ERRO] Os dados recuperados diferem do original gravado!${NC}"
    multipass start "$ACTIVE_WORKER" || true
    exit 1
fi

# Restaurar o nó desligado
echo -e "${BLUE}>>> Restaurando o nó '$ACTIVE_WORKER' para normalizar o cluster...${NC}"
multipass start "$ACTIVE_WORKER"
echo -e "${BLUE}>>> Aguardando nós retornarem ao status 'Ready'...${NC}"
multipass exec "$MASTER_NAME" -- kubectl wait --for=condition=Ready nodes --all --timeout=180s

END_TIME=$(date +%s)
DURATION=$((END_TIME - START_TIME))
MINUTES=$((DURATION / 60))
SECONDS=$((DURATION % 60))

MASTER_IP=$(multipass info "$MASTER_NAME" | grep IPv4 | awk '{print $2}')

echo -e "\n${CYAN}${BOLD}"
echo "========================================================================"
echo "                PIPELINE EXECUTADO COM SUCESSO TOTAL!                   "
echo "========================================================================"
echo -e "${NC}"
echo -e "Tempo total: ${BOLD}${MINUTES}m ${SECONDS}s${NC}"
echo ""
echo -e "${BOLD}Acessos e Comandos Úteis:${NC}"
echo -e "1. Acessar o nó Master:          ${YELLOW}multipass shell $MASTER_NAME${NC}"
echo -e "2. Listar pods do cluster:       ${YELLOW}multipass exec $MASTER_NAME -- kubectl get pods -A${NC}"
echo -e "3. Acessar o Dashboard Longhorn: ${YELLOW}multipass exec $MASTER_NAME -- kubectl -n longhorn-system port-forward --address 0.0.0.0 svc/longhorn-frontend 8080:80${NC}"
echo -e "   Abra no navegador do host:    ${CYAN}http://$MASTER_IP:8080${NC}"
echo -e "4. Limpar e destruir o cluster:  ${RED}./deploy-completo.sh --cleanup${NC}"
echo "========================================================================"
