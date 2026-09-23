# Investigação e Getting Started: Longhorn

**Autores:** Mariana Ferrão Chuquel, Diogo Mainart Monteiro, Marcelo Caggiani Luizelli

---

## Introdução

No atual panorama da infraestrutura de Tecnologia da Informação, a orquestração precisa de recursos computacionais e de armazenamento consolidou-se, de maneira irrefutável, como um pilar estratégico imprescindível para viabilizar operações altamente escaláveis e resilientes. Concomitantemente, à medida que a sofisticação das demandas tecnológicas se expande exponencialmente, a implementação de mecanismos automatizados para a gestão desses recursos torna-se uma exigência peremptória. Sob esta ótica, a automação não se limita a uma conveniência técnica, mas configura-se como um fator determinante para assegurar a continuidade e a integridade dos serviços em ambientes computacionais de alto desempenho.

Nesse cenário, o Kubernetes consolidou-se como a plataforma padrão para a orquestração de ambientes modernos, possuindo como principais qualidades a robustez, a alta versatilidade e a capacidade de suportar vastas infraestruturas. Seus propósitos centrais incluem a coordenação eficiente de microsserviços, a automação completa da gestão de recursos e a garantia de continuidade operacional. Ademais, o sistema atua fundamentalmente para execução de arquiteturas complexas, permitindo que componentes sejam integrados de maneira coesa, assegurando a estabilidade e a escalabilidade necessárias para suportar demandas computacionais elevadas.

Todavia, apesar de sua vasta compatibilidade e ampla adoção, esses sistemas apresentam algumas limitações técnicas que não podem ser negligenciadas. Dentre elas, destacam-se a curva de aprendizado acentuada — refletindo seu elevado grau de abstração —, a complexidade no gerenciamento e manutenção cotidiana, além da escassez de documentação apropriada para o suporte a tarefas complexas. Consequentemente, tais limitações frequentemente inviabilizam a manutenção e o aprimoramento dos sistemas existentes, dado que a dificuldade em compreender estruturas complexas e, por vezes, desconectadas, torna o processo oneroso.

Diante desse cenário, diversos frameworks foram desenvolvidos com o intuito de mitigar tais entraves, facilitando o gerenciamento de arquiteturas implementadas via Kubernetes ao fornecer dashboards centralizados para o controle de operações, monitoramento contínuo e aplicação de políticas rigorosas de segurança e redundância. Uma dessas plataformas é o **Rancher**, que possui diversas ferramentas que visam auxiliar no gerenciamento de ecossistemas. Paralelamente, o **Longhorn** emerge como um sistema cloud-native essencial, projetado especificamente para a distribuição eficiente de armazenamento via blocos dentro desse ecossistema Kubernetes. Portanto, com base nessa premissa, o objetivo primordial deste documento é especificar a criação de uma prova-de-conceito (PoC) que demonstre o funcionamento e o gerenciamento prático de um sistema de armazenamento robusto, integrando Kubernetes e Longhorn.

---

---

## Questões Norteadoras da PoC

**1. Como garantir armazenamento persistente e distribuído no Kubernetes sem depender de storage proprietário de nuvem?**
> **R:** Utilizando o **Longhorn**, uma solução cloud-native open-source de armazenamento em blocos (incubada pela CNCF), que gerencia réplicas síncronas entre os nós do cluster de forma transparente e distribuída.

**2. Como o sistema reage diante da queda física de um nó com volume em uso?**
> **R:** O Kubernetes detecta o nó inativo e reprograma a carga de trabalho no nó sobrevivente. O Longhorn garante que os dados permaneçam acessíveis por meio da réplica ativa, exigindo apenas a liberação da trava de segurança do pod antigo (*Multi-Attach protection*) para anexação imediata no novo nó.

**3. Qual foi a abordagem de armazenamento adotada para viabilizar o ambiente de teste local?**
> **R:** Utilização de instâncias virtuais Multipass com um disco único de 40 GB por VM, permitindo que o Longhorn utilize nativamente o diretório `/var/lib/longhorn` sem a complexidade de formatar e montar discos secundários.

---

## Estrutura do Pipeline de Tarefas

* **Fase 1: Preparação e Infraestrutura do Cluster**
  * `T.1.1`: Configuração dos nós (swapoff, módulos do kernel, containerd e ferramentas K8s v1.29).
  * `T.1.2`: Bootstrap do control-plane via `kubeadm init` e conexão dos nós trabalhadores (`kubeadm join`).
  * `T.1.3`: Configuração da malha de rede com CNI Flannel e verificação do status `Ready`.

* **Fase 2: Deploy e Configuração do Longhorn**
  * `T.2.1`: Habilitação das dependências de disco (`open-iscsi` e `nfs-common`) em todos os nós.
  * `T.2.2`: Instalação do Longhorn via Helm (2 réplicas por volume).
  * `T.2.3`: Definição da StorageClass padrão e validação de PersistentVolumeClaim (PVC).

* **Fase 3: Validação, Gestão e Resiliência**
  * `T.3.1`: Deploy de carga de trabalho persistente (NGINX) com validação de escrita.
  * `T.3.2`: Teste de resiliência e failover com desligamento forçado de nó.
  * `T.3.3`: Configuração de rotinas de monitoramento e snapshots no Longhorn.

---

## Navegação da Documentação

- [Guia Passo a Passo de Implementação](guia-completo.md): Comandos e instruções detalhadas de execução.
- [Relatório de Execução da PoC](relatorio-poc.md): Status consolidado de validação e métricas de entrega.
