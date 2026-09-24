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
echo "                       (Apenas Fase de Testes)                          "
echo "========================================================================"
echo -e "${NC}"

# 1. Validação do Cluster Existente
echo -e "${BLUE}>>> Verificando se as VMs existem e estão operacionais...${NC}"
for vm in "$MASTER_NAME" "$WORKER1_NAME" "$WORKER2_NAME"; do
    if ! multipass info "$vm" &>/dev/null; then
        echo -e "${RED}[ERRO] A VM '$vm' não foi encontrada. O cluster precisa estar criado para rodar este teste.${NC}"
        exit 1
    fi
    STATE=$(multipass info "$vm" | awk '/State:/ {print $2}')
    if [[ "$STATE" != "Running" ]]; then
        echo -e "${BLUE}>>> VM '$vm' está parada. Iniciando...${NC}"
        multipass start "$vm"
    fi
done

# Verificar se o kubectl responde no master
if ! multipass exec "$MASTER_NAME" -- kubectl get nodes &>/dev/null; then
    echo -e "${RED}[ERRO] O cluster Kubernetes no nó '$MASTER_NAME' não está respondendo.${NC}"
    exit 1
fi

echo -e "${GREEN}[OK] Cluster Kubernetes verificado e pronto para o teste.${NC}"
multipass exec "$MASTER_NAME" -- kubectl get nodes -o wide

# 2. Limpar workloads de testes anteriores (se houver)
echo -e "\n${BLUE}>>> Limpando eventuais testes anteriores...${NC}"
multipass exec "$MASTER_NAME" -- bash -c "
    kubectl delete deployment app-persistente --ignore-not-found &>/dev/null || true
    kubectl delete pod -l app=app-persistente --force --grace-period=0 &>/dev/null || true
"

# 3. Criação dos Manifestos do Teste (PVC + Deployment)
echo -e "${BLUE}>>> Criando manifestos de teste no nó '$MASTER_NAME'...${NC}"
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

echo -e "${BLUE}>>> Fazendo deploy da aplicação NGINX com volume persistente...${NC}"
multipass exec "$MASTER_NAME" -- kubectl apply -f /tmp/app.yaml
multipass exec "$MASTER_NAME" -- kubectl rollout status deployment/app-persistente --timeout=360s

ORIGINAL_POD=$(multipass exec "$MASTER_NAME" -- kubectl get pod -l app=app-persistente --field-selector status.phase=Running -o jsonpath='{.items[0].metadata.name}')
ACTIVE_WORKER=$(multipass exec "$MASTER_NAME" -- kubectl get pod "$ORIGINAL_POD" -o jsonpath='{.spec.nodeName}')
echo -e "${GREEN}[OK] Pod '$ORIGINAL_POD' operacional no nó: ${YELLOW}$ACTIVE_WORKER${NC}"

# 4. Gravação de dado exclusivo no volume persistente
TEST_TOKEN="POC_LONGHORN_PERSISTENCE_TOKEN_$(date +%s)_$RANDOM"
echo -e "${BLUE}>>> Gravando token exclusivo no volume persistente: ${YELLOW}$TEST_TOKEN${NC}"
multipass exec "$MASTER_NAME" -- kubectl exec "$ORIGINAL_POD" -- sh -c "echo '$TEST_TOKEN' > /usr/share/nginx/html/index.html"

# Confirmar leitura inicial
INITIAL_READ=$(multipass exec "$MASTER_NAME" -- kubectl exec "$ORIGINAL_POD" -- cat /usr/share/nginx/html/index.html | tr -d '\r\n')
if [[ "$INITIAL_READ" != "$TEST_TOKEN" ]]; then
    echo -e "${RED}[ERRO] Falha ao gravar dados iniciais no volume! Lido: '$INITIAL_READ'${NC}"
    exit 1
fi
echo -e "${GREEN}[OK] Leitura inicial confirmada com sucesso.${NC}"

# 5. Simulação de falha catastrófica: Desligar a VM do Worker ativo
echo -e "\n${YELLOW}========================================================================${NC}"
echo -e "${YELLOW}>>> SIMULANDO FALHA CATASTRÓFICA: Desligando nó trabalhador '$ACTIVE_WORKER'...${NC}"
echo -e "${YELLOW}========================================================================${NC}"
multipass stop "$ACTIVE_WORKER"

echo -e "${BLUE}>>> Nó '$ACTIVE_WORKER' desligado. Aguardando detecção pelo Kubernetes...${NC}"
sleep 15

# 6. Mitigação da proteção de Multi-Attach do Longhorn
echo -e "${BLUE}>>> Forçando exclusão do pod antigo para liberar a trava do volume...${NC}"
multipass exec "$MASTER_NAME" -- kubectl delete pod "$ORIGINAL_POD" --force --grace-period=0 2>/dev/null || true

# 7. Aguardar subida do novo Pod no nó sobrevivente
echo -e "${BLUE}>>> Aguardando novo Pod ser instanciado no nó trabalhador sobrevivente...${NC}"
NEW_POD=""
for i in {1..90}; do
    POD_CANDIDATE=$(multipass exec "$MASTER_NAME" -- kubectl get pod -l app=app-persistente --field-selector status.phase=Running -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
    if [[ -n "$POD_CANDIDATE" && "$POD_CANDIDATE" != "$ORIGINAL_POD" ]]; then
        NEW_POD="$POD_CANDIDATE"
        break
    fi
    if (( i % 5 == 0 )); then
        echo -e "Aguardando transferência do volume e Pod ficar 'Running'... (${i}/90)"
    fi
    sleep 3
done

if [[ -z "$NEW_POD" ]]; then
    echo -e "${RED}[ERRO] Timeout aguardando novo Pod no nó sobrevivente!${NC}"
    multipass start "$ACTIVE_WORKER" || true
    exit 1
fi

SURVIVING_WORKER=$(multipass exec "$MASTER_NAME" -- kubectl get pod "$NEW_POD" -o jsonpath='{.spec.nodeName}')
echo -e "${GREEN}[OK] Novo Pod '$NEW_POD' operacional no nó sobrevivente: ${YELLOW}$SURVIVING_WORKER${NC}"

# 8. Validação da integridade dos dados pós-queda
echo -e "${BLUE}>>> Verificando integridade dos dados no novo Pod...${NC}"
RECOVERED_DATA=$(multipass exec "$MASTER_NAME" -- kubectl exec "$NEW_POD" -- cat /usr/share/nginx/html/index.html | tr -d '\r\n')

echo -e "Dado original gravado:     ${YELLOW}$TEST_TOKEN${NC}"
echo -e "Dado recuperado pós-queda:   ${GREEN}$RECOVERED_DATA${NC}"

if [[ "$RECOVERED_DATA" == "$TEST_TOKEN" ]]; then
    echo -e "\n${GREEN}========================================================================${NC}"
    echo -e "${GREEN}[SUCESSO] TESTE DE RESILIÊNCIA CONCLUÍDO COM SUCESSO TOTAL!${NC}"
    echo -e "${GREEN}O Longhorn manteve os dados íntegros após a queda forçada do nó.${NC}"
    echo -e "${GREEN}========================================================================${NC}"
else
    echo -e "\n${RED}[ERRO] Os dados recuperados diferem do original gravado!${NC}"
    multipass start "$ACTIVE_WORKER" || true
    exit 1
fi

# 9. Restaurar o nó desligado e normalizar o cluster
echo -e "${BLUE}>>> Restaurando o nó '$ACTIVE_WORKER' para normalizar o cluster...${NC}"
multipass start "$ACTIVE_WORKER"
echo -e "${BLUE}>>> Aguardando nós retornarem ao status 'Ready'...${NC}"
multipass exec "$MASTER_NAME" -- kubectl wait --for=condition=Ready nodes --all --timeout=180s

END_TIME=$(date +%s)
DURATION=$((END_TIME - START_TIME))
MINUTES=$((DURATION / 60))
SECONDS=$((DURATION % 60))

echo -e "\n${CYAN}${BOLD}"
echo "========================================================================"
echo "    TESTE DE RESILIÊNCIA FINALIZADO COM ÊXITO EM ${MINUTES}m ${SECONDS}s! "
echo "========================================================================"
echo -e "${NC}"
