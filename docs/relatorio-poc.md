# Relatório de Progresso: Prova-de-Conceito (PoC) Kubernetes e Longhorn

## 1. Visão Geral
Este documento apresenta o status técnico detalhado e os resultados da Prova-de-Conceito (PoC) que validou o funcionamento e gerenciamento prático de um sistema de armazenamento robusto integrando Kubernetes e Longhorn.

## 2. Arquitetura e Especificações Configuradas
De acordo com os requisitos definidos e o ambiente criado via Multipass, a topologia atual provisionada é composta por:
- **Sistema Operacional:** Ubuntu 22.04 LTS
- **Topologia:** 3 Nós no total (1 Control-Plane chamado `master` e 2 Workers chamados `worker1` e `worker2`).
- **Recursos por Nó:** 2 vCPUs, 4 GB de RAM, 40 GB de Disco.
- **Estratégia de Armazenamento (Longhorn):** Optou-se pela utilização de um disco único expandido (40 GB) por VM, atendendo plenamente aos requisitos do Longhorn para utilização do diretório padrão `/var/lib/longhorn`. Isso simplificou a alocação no Multipass, sem a necessidade de gerenciar discos virtuais secundários.

## 3. Status das Tarefas (Pipeline de Progresso)

### Fase 1: Preparação e Infraestrutura do Cluster
* **T.1.1: Configuração dos nós do cluster** - **[CONCLUÍDO]**
  * Swap desativado, parâmetros de Kernel e rede (`overlay`, `br_netfilter`, `sysctl`) ajustados em todos os 3 nós.
  * Runtime de containers (`containerd`) e ferramentas Kubernetes (`kubeadm`, `kubelet`, `kubectl` v1.29) instalados.
* **T.1.2: Inicialização e instalação do cluster Kubernetes** - **[CONCLUÍDO]**
  * O cluster foi inicializado com sucesso via `kubeadm init` no nó `master`.
  * Um problema inicial de "connection refused" ao reiniciar as VMs foi diagnosticado e os serviços do `kubelet` reestabelecidos, permitindo que os nós `worker1` e `worker2` realizassem o `kubeadm join` com êxito.
* **T.1.3: Configuração da rede do cluster e verificação de conectividade** - **[CONCLUÍDO]**
  * O plugin de rede Flannel foi implantado via manifesto YAML.
  * Todos os 3 nós alcançaram o status de `Ready` e comunicação plena no cluster.

### Fase 2: Deploy e Configuração do Longhorn
* **T.2.1: Preparação dos nós para o Longhorn** - **[CONCLUÍDO]**
  * Instalação e habilitação das dependências de disco (`open-iscsi` e `nfs-common`) nos workers e no master (`iscsid` operando normalmente).
* **T.2.2: Instalação e configuração do Longhorn** - **[CONCLUÍDO]**
  * Namespace `longhorn-system` criado e sistema Longhorn instalado utilizando Helm. 
  * Todos os pods e microserviços de gerenciamento e persistência atingiram o status de `Running`.
* **T.2.3: Configuração da StorageClass padrão e testes de provisionamento** - **[CONCLUÍDO]**
  * StorageClass `longhorn` definida como o padrão (`default`) do cluster.
  * Criação de um PersistentVolumeClaim (PVC) de teste com 1Gi de espaço, validando o provisionamento automático e seu status final em `Bound`.

### Fase 3: Validação, Gestão e Resiliência
* **T.3.1: Deploy de cargas de trabalho de teste** - **[CONCLUÍDO]**
  * Um Deployment simples do NGINX (`app-persistente`) foi executado, montando com sucesso o volume persistente provido pelo Longhorn.
  * Foram gerados e gravados dados dentro do volume persistente (arquivo `index.html` com a data atual).
* **T.3.2: Testes de resiliência e simulação de falha de nós** - **[CONCLUÍDO]**
  * **Cenário validado:** O nó trabalhador (`worker1`) que mantinha o Pod em execução foi intencionalmente desligado da rede (simulação de desastre/falha física).
  * **Recuperação:** O Kubernetes reconheceu o nó inativo e planejou a subida do pod para o nó trabalhador sobrevivente. Após a liberação do lock de volume (`Multi-Attach error` - um mecanismo de segurança do Kubernetes/Longhorn superado de forma rápida e manual com a exclusão forçada do pod desatualizado), a aplicação ressurgiu íntegra no novo nó.
  * **Prova de Persistência:** A leitura do arquivo dentro do novo Pod instanciado validou inequivocamente que os dados originais foram mantidos **100% intactos**, atestando o funcionamento da resiliência de dados do cluster.
* **T.3.3: Estabelecimento de rotinas de monitoramento e backup do sistema de armazenamento** - **[CONCLUÍDO]**
  * O monitoramento da saúde e do uso de disco dos volumes foi validado de forma nativa através do próprio painel do Longhorn.
  * A proteção dos dados (Backup) foi automatizada através de Recurring Jobs, estabelecendo uma rotina de Snapshots diários (Cron `0 0 * * *`) com política de retenção de 7 dias e vinculada ao volume principal.

## 4. Conclusão e Entrega da PoC
A infraestrutura atingiu **100% de sucesso** em todos os marcos estipulados na modelagem inicial. A integração entre Kubernetes e Longhorn provou-se altamente funcional, distribuída e resiliente, suportando perfeitamente a queda de nós sem corrupção ou perda de dados.

---

## Documentos Relacionados

- [Visão Geral e Conceitos](visao-geral.md)
- [Guia Prático Passo a Passo](guia-completo.md)
