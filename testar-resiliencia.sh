#!/usr/bin/env bash
# ==============================================================================
# testar-resiliencia.sh
# Script autônomo para executar EXCLUSIVAMENTE o teste de persistência e
# resiliência a falhas do Longhorn em um cluster Kubernetes já existente.
#
# Não baixa nem recria VMs, não reinstala o Kubernetes nem o Longhorn.
#
# Uso:
#   ./testar-resiliencia.sh
# ==============================================================================
set -euo pipefail

MASTER_NAME="master"
WORKER1_NAME="worker1"
WORKER2_NAME="worker2"

# Cores para formatação
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
RED='\033[0;31m'
BOLD='\033[1m'
NC='\033[0m'

START_TIME=$(date +%s)

echo -e "${CYAN}${BOLD}"
echo "========================================================================"
echo "    TESTE AUTOMATIZADO DE RESILIÊNCIA E PERSISTÊNCIA DO LONGHORN        "
echo "                (Execução em Cluster Pré-existente)                     "
echo "========================================================================"
echo -e "${NC}"

# 1. Validação do Cluster Existente
echo -e "${BLUE}>>> Verificando status e conectividade das instâncias virtuais...${NC}"
for vm in "$MASTER_NAME" "$WORKER1_NAME" "$WORKER2_NAME"; do
    if ! multipass info "$vm" &>/dev/null; then
        echo -e "${RED}[ERRO] Instância '$vm' não encontrada. É necessário um cluster ativo para execução do teste.${NC}"
        exit 1
    fi
    STATE=$(multipass info "$vm" | awk '/State:/ {print $2}')
    if [[ "$STATE" != "Running" ]]; then
        echo -e "${BLUE}>>> Instância '$vm' inativa. Inicializando...${NC}"
        multipass start "$vm"
    fi
done

# Verificar se o kubectl responde no master
if ! multipass exec "$MASTER_NAME" -- kubectl get nodes &>/dev/null; then
    echo -e "${RED}[ERRO] A API do Kubernetes no nó '$MASTER_NAME' está inacessível.${NC}"
    exit 1
fi

echo -e "${GREEN}[OK] Conectividade com a API do cluster estabelecida.${NC}"
multipass exec "$MASTER_NAME" -- kubectl get nodes -o wide

# 2. Limpar workloads de testes anteriores (se houver)
echo -e "\n${BLUE}>>> Excluindo recursos remanescentes de execuções anteriores...${NC}"
multipass exec "$MASTER_NAME" -- bash -c "
    kubectl delete deployment app-persistente --ignore-not-found &>/dev/null || true
    kubectl delete pod -l app=app-persistente --force --grace-period=0 &>/dev/null || true
"

# 3. Criação dos Manifestos do Teste (PVC + Deployment)
echo -e "${BLUE}>>> Gerando manifestos de validação no nó '$MASTER_NAME'...${NC}"
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

echo -e "${BLUE}>>> Aplicando PersistentVolumeClaim (PVC)...${NC}"
multipass exec "$MASTER_NAME" -- kubectl apply -f /tmp/pvc.yaml

echo -e "${BLUE}>>> Implantando workload de teste (NGINX) com volume persistente...${NC}"
multipass exec "$MASTER_NAME" -- kubectl apply -f /tmp/app.yaml
multipass exec "$MASTER_NAME" -- kubectl rollout status deployment/app-persistente --timeout=360s

ORIGINAL_POD=$(multipass exec "$MASTER_NAME" -- kubectl get pod -l app=app-persistente --field-selector status.phase=Running -o jsonpath='{.items[0].metadata.name}')
ACTIVE_WORKER=$(multipass exec "$MASTER_NAME" -- kubectl get pod "$ORIGINAL_POD" -o jsonpath='{.spec.nodeName}')
echo -e "${GREEN}[OK] Pod '$ORIGINAL_POD' operacional no nó: ${YELLOW}$ACTIVE_WORKER${NC}"

# 4. Gravação de identificador no volume persistente
TEST_TOKEN="POC_LONGHORN_PERSISTENCE_TOKEN_$(date +%s)_$RANDOM"
echo -e "${BLUE}>>> Gravando identificador único no volume persistente: ${YELLOW}$TEST_TOKEN${NC}"
multipass exec "$MASTER_NAME" -- kubectl exec "$ORIGINAL_POD" -- sh -c "echo '$TEST_TOKEN' > /usr/share/nginx/html/index.html"

# Confirmar leitura inicial
INITIAL_READ=$(multipass exec "$MASTER_NAME" -- kubectl exec "$ORIGINAL_POD" -- cat /usr/share/nginx/html/index.html | tr -d '\r\n')
if [[ "$INITIAL_READ" != "$TEST_TOKEN" ]]; then
    echo -e "${RED}[ERRO] Falha na validação de escrita inicial no volume! Conteúdo lido: '$INITIAL_READ'${NC}"
    exit 1
fi
echo -e "${GREEN}[OK] Persistência inicial validada com sucesso.${NC}"

# 5. Injeção de falha: Interrupção não programada do nó ativo
echo -e "\n${YELLOW}========================================================================${NC}"
echo -e "${YELLOW}>>> Injetando falha: Interrupção não programada do nó '$ACTIVE_WORKER'...${NC}"
echo -e "${YELLOW}========================================================================${NC}"
multipass stop "$ACTIVE_WORKER"

# Confirmar que a VM está realmente parada antes de prosseguir
echo -e "${BLUE}>>> Confirmando desligamento da instância '$ACTIVE_WORKER'...${NC}"
for i in {1..20}; do
    VM_STATE=$(multipass info "$ACTIVE_WORKER" 2>/dev/null | awk '/State:/ {print $2}' || echo "")
    if [[ "$VM_STATE" == "Stopped" ]]; then
        echo -e "${GREEN}[OK] Instância '$ACTIVE_WORKER' confirmada como inativa.${NC}"
        break
    fi
    if (( i == 20 )); then
        echo -e "${RED}[ERRO] Instância '$ACTIVE_WORKER' não parou no tempo esperado. Estado atual: '$VM_STATE'${NC}"
        exit 1
    fi
    sleep 3
done

echo -e "${BLUE}>>> Aguardando reconciliação do plano de controle...${NC}"
sleep 15

# 6. Mitigação da proteção de Multi-Attach do Longhorn
echo -e "${BLUE}>>> Removendo pod no nó inativo para liberação do lock de montagem (VolumeAttachment)...${NC}"
multipass exec "$MASTER_NAME" -- kubectl delete pod "$ORIGINAL_POD" --force --grace-period=0 2>/dev/null || true

# 7. Aguardar realocação do Pod no nó restante
echo -e "${BLUE}>>> Aguardando realocação do pod no nó operacional restante...${NC}"
NEW_POD=""
for i in {1..90}; do
    POD_CANDIDATE=$(multipass exec "$MASTER_NAME" -- kubectl get pod -l app=app-persistente --field-selector status.phase=Running -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
    if [[ -n "$POD_CANDIDATE" && "$POD_CANDIDATE" != "$ORIGINAL_POD" ]]; then
        POD_NODE=$(multipass exec "$MASTER_NAME" -- kubectl get pod "$POD_CANDIDATE" -o jsonpath='{.spec.nodeName}' 2>/dev/null || echo "")
        if [[ -n "$POD_NODE" && "$POD_NODE" != "$ACTIVE_WORKER" ]]; then
            NEW_POD="$POD_CANDIDATE"
            break
        fi
    fi
    if (( i % 5 == 0 )); then
        echo -e "Aguardando desanexação/anexação do volume CSI e inicialização do Pod... (${i}/90)"
    fi
    sleep 3
done

if [[ -z "$NEW_POD" ]]; then
    echo -e "${RED}[ERRO] Tempo limite excedido durante a realocação do pod no nó sobrevivente.${NC}"
    multipass start "$ACTIVE_WORKER" || true
    exit 1
fi

SURVIVING_WORKER=$(multipass exec "$MASTER_NAME" -- kubectl get pod "$NEW_POD" -o jsonpath='{.spec.nodeName}')
echo -e "${GREEN}[OK] Pod realocado com êxito ('$NEW_POD') no nó: ${YELLOW}$SURVIVING_WORKER${NC}"

# 8. Validação da integridade dos dados pós-failover
echo -e "${BLUE}>>> Validando integridade dos dados persistidos no pod realocado...${NC}"
RECOVERED_DATA=$(multipass exec "$MASTER_NAME" -- kubectl exec "$NEW_POD" -- cat /usr/share/nginx/html/index.html | tr -d '\r\n')

echo -e "Identificador gravado originalmente: ${YELLOW}$TEST_TOKEN${NC}"
echo -e "Identificador recuperado pós-failover: ${GREEN}$RECOVERED_DATA${NC}"

if [[ "$RECOVERED_DATA" == "$TEST_TOKEN" ]]; then
    echo -e "\n${GREEN}========================================================================${NC}"
    echo -e "${GREEN}[SUCESSO] TESTE DE RESILIÊNCIA E ALTA DISPONIBILIDADE CONCLUÍDO.${NC}"
    echo -e "${GREEN}A replicação síncrona do Longhorn garantiu a consistência e integridade dos volumes.${NC}"
    echo -e "${GREEN}========================================================================${NC}"
else
    echo -e "\n${RED}[ERRO] Divergência de integridade detectada entre o dado original e o recuperado.${NC}"
    multipass start "$ACTIVE_WORKER" || true
    exit 1
fi

# 9. Restaurar o nó desligado e normalizar o cluster
echo -e "${BLUE}>>> Reinicializando nó '$ACTIVE_WORKER' para restaurar a topologia original...${NC}"
multipass start "$ACTIVE_WORKER"
echo -e "${BLUE}>>> Aguardando transição de todos os nós para a condição 'Ready'...${NC}"
multipass exec "$MASTER_NAME" -- kubectl wait --for=condition=Ready nodes --all --timeout=180s

END_TIME=$(date +%s)
DURATION=$((END_TIME - START_TIME))
MINUTES=$((DURATION / 60))
SECONDS=$((DURATION % 60))

echo -e "\n${CYAN}${BOLD}"
echo "========================================================================"
echo "    TESTE DE RESILIÊNCIA CONCLUÍDO EM ${MINUTES}m ${SECONDS}s           "
echo "========================================================================"
echo -e "${NC}"
