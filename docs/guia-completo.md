# Guia Completo de Implementação: Kubernetes + Longhorn PoC

> **Objetivo:** Criar uma Prova-de-Conceito funcional de um cluster Kubernetes com armazenamento persistente distribuído via Longhorn, com alta disponibilidade e resiliência a falhas.
> **Ambiente Base:** Este guia reflete os exatos passos executados e validados utilizando **Multipass** para provisionamento das máquinas virtuais com disco unificado.

---

## Fase 0 — Criação da Infraestrutura (Multipass)

Em vez de configurar discos extras complexos, optou-se por utilizar um disco único expandido (40GB) por VM para simplificar a prova de conceito.

No seu terminal (host), crie as 3 VMs (Ubuntu 22.04) executando:
```bash
multipass launch 22.04 --name master --cpus 2 --memory 4G --disk 40G
multipass launch 22.04 --name worker1 --cpus 2 --memory 4G --disk 40G
multipass launch 22.04 --name worker2 --cpus 2 --memory 4G --disk 40G
```
Para acessar cada VM, utilize o comando `multipass shell <nome-da-vm>`.

---

## Fase 1 — Preparação e Infraestrutura do Cluster

### T.1.1 — Configuração dos Nós (em TODOS os nós: master, worker1, worker2)

**1. Desativar swap (obrigatório para o Kubernetes):**
```bash
sudo swapoff -a
sudo sed -i '/ swap / s/^\(.*\)$/#\1/g' /etc/fstab
```

**2. Configurar módulos de kernel necessários:**
```bash
cat <<EOF | sudo tee /etc/modules-load.d/k8s.conf
overlay
br_netfilter
EOF

sudo modprobe overlay
sudo modprobe br_netfilter
```

**3. Configurar parâmetros de rede do kernel:**
```bash
cat <<EOF | sudo tee /etc/sysctl.d/k8s.conf
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF

sudo sysctl --system
```

**4. Instalar o container runtime (containerd):**
```bash
sudo apt-get update
sudo apt-get install -y containerd

sudo mkdir -p /etc/containerd
containerd config default | sudo tee /etc/containerd/config.toml

# Habilitar SystemdCgroup
sudo sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml

sudo systemctl restart containerd
sudo systemctl enable containerd
```

**5. Instalar kubeadm, kubelet e kubectl (Versão homologada: v1.29):**
```bash
sudo apt-get update
sudo apt-get install -y apt-transport-https ca-certificates curl gpg

curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.29/deb/Release.key | \
  sudo gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg

echo 'deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v1.29/deb/ /' | \
  sudo tee /etc/apt/sources.list.d/kubernetes.list

sudo apt-get update
sudo apt-get install -y kubelet kubeadm kubectl
sudo apt-mark hold kubelet kubeadm kubectl
```

---

### T.1.2 — Inicialização do Cluster Kubernetes

**1. Inicializar o control-plane (somente no nó `master`):**
```bash
sudo kubeadm init \
  --pod-network-cidr=10.244.0.0/16 \
  --apiserver-advertise-address=$(hostname -I | awk '{print $1}')
```

**2. Configurar o `kubectl` para o usuário atual (no `master`):**
```bash
mkdir -p $HOME/.kube
sudo cp -i /etc/kubernetes/admin.conf $HOME/.kube/config
sudo chown $(id -u):$(id -g) $HOME/.kube/config
```

**3. Gerar comando de Join e conectar os workers:**
Caso não tenha salvo o comando exibido no final do `kubeadm init`, rode na `master`:
```bash
sudo kubeadm token create --print-join-command
```
Copie a saída (`sudo kubeadm join ...`) e execute-a nos terminais do **worker1** e **worker2**.

---

### T.1.3 — Configuração da Rede do Cluster

**1. Instalar o plugin de rede Flannel (no `master`):**
```bash
kubectl apply -f https://github.com/flannel-io/flannel/releases/latest/download/kube-flannel.yml
```

**2. Verificar que todos os nós estão `Ready` (no `master`):**
```bash
kubectl get nodes
```

[OK] **Critério de conclusão da Fase 1:** `kubectl get nodes` mostra os 3 nós (`master`, `worker1`, `worker2`) com status `Ready`.

---

## Fase 2 — Deploy e Configuração do Longhorn

### T.2.1 — Preparação dos Nós para o Longhorn (em TODOS os nós)

**1. Instalar dependências obrigatórias para os discos virtuais:**
```bash
sudo apt-get install -y open-iscsi nfs-common
sudo systemctl enable iscsid
sudo systemctl start iscsid
```

> **Nota sobre Armazenamento:** Na configuração de PoC com Multipass, o disco unificado de 40GB é suficiente. O Longhorn utilizará nativamente o diretório padrão `/var/lib/longhorn` usando o espaço livre do sistema operacional. Não é necessário formatar discos extras.

---

### T.2.2 — Instalação do Longhorn via Helm (no `master`)

**1. Instalar o Helm:**
```bash
curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
```

**2. Instalar o Longhorn configurado para 2 réplicas:**
```bash
helm repo add longhorn https://charts.longhorn.io
helm repo update

kubectl create namespace longhorn-system

helm install longhorn longhorn/longhorn \
  --namespace longhorn-system \
  --set defaultSettings.defaultReplicaCount=2
```

**3. Aguardar todos os pods do Longhorn subirem:**
```bash
kubectl -n longhorn-system get pods -w
```
Aguarde até que os status saiam de `ContainerCreating` para `Running`.

**4. Acessar o dashboard do Longhorn (port-forward):**
Para acessar a interface visual a partir do seu navegador:
```bash
kubectl -n longhorn-system port-forward --address 0.0.0.0 svc/longhorn-frontend 8080:80
```
Acesse em: `http://<IP-DO-MASTER>:8080` (A porta 8080 será redirecionada para o Longhorn).

---

### T.2.3 — Configuração da StorageClass e Teste de Volume

**1. Tornar o Longhorn a StorageClass padrão:**
```bash
kubectl patch storageclass longhorn \
  -p '{"metadata": {"annotations":{"storageclass.kubernetes.io/is-default-class":"true"}}}'
```

**2. Criar um PVC de teste (1GB):**
```bash
cat <<EOF | kubectl apply -f -
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
EOF
```
**3. Verificar se o volume foi criado:**
```bash
kubectl get pvc longhorn-pvc-teste
```
O status deve ir para `Bound`.

[OK] **Critério de conclusão da Fase 2:** PVC com status `Bound` e dashboard do Longhorn acessível e operante.

---

## Fase 3 — Validação, Gestão e Resiliência

### T.3.1 — Deploy de Workload com Armazenamento Persistente

**1. Criar um Pod (NGINX) que escreve dados no volume do Longhorn:**
```bash
cat <<EOF | kubectl apply -f -
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
EOF
```

**2. Escrever e validar dados no volume:**
```bash
POD=$(kubectl get pod -l app=app-persistente --field-selector status.phase=Running -o jsonpath='{.items[0].metadata.name}')

# Escrever dados
kubectl exec $POD -- sh -c 'echo "Dados persistentes da PoC Longhorn - $(date)" > /usr/share/nginx/html/index.html'

# Ler dados
kubectl exec $POD -- cat /usr/share/nginx/html/index.html
```

---

### T.3.2 — Teste de Resiliência (Simulação de Falha de Nó e Multi-Attach)

**1. Identificar em qual worker o pod está rodando:**
```bash
kubectl get pod -l app=app-persistente -o wide
```
*(Anote o nome do worker listado na coluna `NODE`).*

**2. Simular falha grave do nó desligando a VM (Ex: worker1):**
No terminal do **seu computador host**, execute:
```bash
multipass stop worker1
```

**3. Observar a tentativa de migração do Pod (no master):**
```bash
kubectl get pods -o wide
```
Você notará que o Pod no nó caído ficará em estado `Terminating`, e um novo Pod será criado no nó sobrevivente (`worker2`), ficando preso em `ContainerCreating`.

**4. Resolver o travamento de volume (Segurança do Longhorn):**
Ao executar `kubectl describe pod -l app=app-persistente`, você verá o erro `Multi-Attach error`. Isso ocorre porque o Kubernetes travou o volume para proteger contra corrupção, aguardando o nó morto responder.
**Solução:** Force a exclusão do Pod antigo que ficou preso no nó offline:
```bash
kubectl delete pod <NOME-DO-POD-ANTIGO-EM-TERMINATING> --force --grace-period=0
```
Isso liberará imediatamente a trava do disco para o novo nó.

**5. Verificar que os dados foram preservados no novo pod:**
Aguarde o novo pod ir para `Running` e execute a leitura:
```bash
POD=$(kubectl get pod -l app=app-persistente --field-selector status.phase=Running -o jsonpath='{.items[0].metadata.name}')
kubectl exec $POD -- cat /usr/share/nginx/html/index.html
```
> O conteúdo escrito anteriormente continuará lá. **Isso comprova a resiliência do Longhorn (Recuperação de Desastres bem sucedida).**

---

### T.3.3 — Monitoramento e Backup (Opcional - Próximos Passos)
A PoC pode ser estendida configurando backups automáticos diretamente no Dashboard do Longhorn via S3 ou NFS (Settings → Backup Target) e agendando *Recurring Jobs* de snapshots.

---

## Checklist Final de Entrega

| Item | Descrição | Status |
|------|-----------|-----------|
| [OK] | Criação de 3 VMs via Multipass com disco unificado | **Concluído** |
| [OK] | Cluster Kubernetes com 1 master + 2 workers em estado `Ready` | **Concluído** |
| [OK] | Plugin de rede Flannel instalado e funcional | **Concluído** |
| [OK] | Longhorn instalado via Helm e pods operacionais | **Concluído** |
| [OK] | Dashboard do Longhorn acessível e port-forward configurado | **Concluído** |
| [OK] | StorageClass `longhorn` definida como padrão e PVC `Bound` | **Concluído** |
| [OK] | Workload NGINX de teste escrevendo e lendo no volume persistente | **Concluído** |
| [OK] | Simulação de queda de nó, mitigação do "Multi-Attach" e verificação da preservação total dos dados no nó sobrevivente | **Concluído** |

---

## Dicas Importantes da PoC

> [!TIP]
> **Multipass** provou ser a ferramenta mais ágil e simplificada para provisionar este laboratório localmente. A alocação de um único disco de 40GB evita a necessidade de formatar `/dev/sdb` e automatiza a configuração do Longhorn no path default.

> [!NOTE]
> O Longhorn foi configurado propositalmente com `replicas: 2`. Como só existem 2 workers aptos a armazenar dados, quando um nó cai, o volume passa para o status `Degraded` até que o nó volte ou a réplica excluída seja reconstruída manualmente pela UI.

> [!WARNING]
> O erro `Multi-Attach error` não é um defeito, mas um **mecanismo de proteção** indispensável. O Kubernetes impede que dois nós gravem no mesmo volume distribuído se não tiver certeza que o nó antigo soltou o arquivo (o que não ocorre em desligamentos forçados). A deleção forçada (`--force`) comprova a tomada manual de controle.

---

## Documentos Relacionados

- [Visão Geral e Conceitos](visao-geral.md)
- [Relatório de Execução da PoC](relatorio-poc.md)
