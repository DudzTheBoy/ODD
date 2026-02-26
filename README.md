# 📞 Modelo de Score de Probabilidade de Contato

### Brasilseg – Inteligência de Contactabilidade

**Versão:** 3.1  
**Última atualização:** 2026-02-26  
**Autor:** Equipe de Planejamento MIS  
**Ambiente:** SQL Server (MSSQL) / Python (pandas + pyodbc)  
**Arquivo SQL:** `SCORE_PROBABILIDADE_CONTATO_v3.1.sql`

---

## Sumário

1. [Objetivo](#1-objetivo)
2. [Premissas e Princípios](#2-premissas-e-princípios)
3. [Arquitetura Geral](#3-arquitetura-geral)
4. [Fonte de Dados](#4-fonte-de-dados)
5. [Granularidade da Análise](#5-granularidade-da-análise)
6. [Métricas por Telefone — Definições Detalhadas](#6-métricas-por-telefone--definições-detalhadas)
7. [Métricas por Cliente (Global) — Definições Detalhadas](#7-métricas-por-cliente-global--definições-detalhadas)
8. [Score Telefone — Composição (70%)](#8-score-telefone--composição-70)
9. [Score Cliente — Composição (30%)](#9-score-cliente--composição-30)
10. [Score Final — Cálculo e Pesos Efetivos](#10-score-final--cálculo-e-pesos-efetivos)
11. [Interpretação Operacional](#11-interpretação-operacional)
12. [Tratamento de Nulls e Edge Cases](#12-tratamento-de-nulls-e-edge-cases)
13. [Filtros e Escopo Temporal](#13-filtros-e-escopo-temporal)
14. [Glossário Completo de Campos](#14-glossário-completo-de-campos)
15. [Diagramas de Fluxo](#15-diagramas-de-fluxo)
16. [Exemplos Práticos de Cálculo](#16-exemplos-práticos-de-cálculo)
17. [Aplicação Operacional](#17-aplicação-operacional)
18. [Dependências Técnicas](#18-dependências-técnicas)
19. [Limitações Conhecidas](#19-limitações-conhecidas)
20. [Evoluções Futuras](#20-evoluções-futuras)
21. [Changelog](#21-changelog)

---

## 1. Objetivo

Este modelo tem como objetivo criar um **indicador numérico (0 a 100)** que estima a probabilidade de se estabelecer um contato telefônico efetivo com um cliente, considerando um número de telefone específico.

### Pergunta que o modelo responde:

> **"Dado este cliente e este número de telefone, qual a probabilidade de conseguirmos falar com ele?"**

### O que o modelo **NÃO** faz:

| Não faz                              | Motivo                                                              |
| ------------------------------------ | ------------------------------------------------------------------- |
| Prever conversão ou venda            | O foco é contactabilidade, não resultado comercial de venda         |
| Diferenciar por produto              | O cliente não sabe qual produto será ofertado ao atender            |
| Recomendar horário ideal de contato  | Não há variável de horário no modelo atual                          |
| Substituir modelo de propensão       | Complementa — prioriza a discagem, não a oferta                    |

### Valor de negócio:

- **Redução de custo operacional:** menos tentativas desperdiçadas em números improdutivos
- **Aumento de eficiência da operação:** priorização inteligente da fila de discagem
- **Melhoria da experiência do cliente:** menos ligações desnecessárias, redução de fadiga
- **Otimização do discador:** melhor aproveitamento das posições de atendimento (PA)

---

## 2. Premissas e Princípios

### 2.1 Premissa Fundamental: Comportamento Estrutural

Quando o telefone toca, o cliente vê:

> **"Brasilseg está ligando"**

Ele **não sabe** qual produto está sendo ofertado. Portanto:

- A probabilidade de atendimento é um **comportamento estrutural** do par (cliente × telefone)
- O histórico de atendimento passado é o melhor preditor do comportamento futuro
- Separação por campanha **não é necessária** para medir chance de contato

### 2.2 Premissa de Composição — Modelo Híbrido em Dois Níveis (Simétrico)

O modelo opera em **dois níveis hierárquicos** combinados, ambos com a **mesma estrutura de 3 componentes:**

| Camada           | Peso   | O que captura                                           |
| ---------------- | ------ | ------------------------------------------------------- |
| 📱 **Telefone**  | **70%**| Eficiência daquele número específico para gerar contato  |
| 👤 **Cliente**   | **30%**| Comportamento estrutural, recência e fadiga global       |

**Justificativa dos pesos:**
- **70% Telefone:** O número discado é o fator mais determinante. Um celular pessoal ativo tem comportamento radicalmente diferente de um fixo antigo.
- **30% Cliente:** Corrige para o comportamento do indivíduo. Mesmo um bom número terá desempenho ruim se o cliente sistematicamente rejeita ligações da Brasilseg.

### Sub-composição do Score Telefone:

| Componente                    | Peso interno | O que captura                            |
| ----------------------------- | ------------ | ---------------------------------------- |
| `answer_rate_tel`             | 60%          | Eficiência histórica de atendimento       |
| Recência (`dias_desde_ultima`)| 20%          | Quanto tempo de "descanso" o número teve  |
| (1 - Fadiga) (`attempts_30d`) | 20%          | Pressão recente neste número              |

### Sub-composição do Score Cliente (v3.1 — atualizada):

| Componente                                | Peso interno | O que captura                                  |
| ----------------------------------------- | ------------ | ---------------------------------------------- |
| `answer_rate_cli`                         | 60%          | Comportamento estrutural de atendimento         |
| Recência global (`dias_desde_ultima_cli`) | 20%          | Quanto tempo de "descanso" o cliente teve       |
| (1 - Fadiga global) (`attempts_30d_cli`)  | 20%          | Saturação global em todos os telefones          |

> **Evolução v3.1:** Ambas as camadas agora possuem a **mesma estrutura simétrica** de 3 componentes (60% eficiência + 20% recência + 20% anti-fadiga), tornando o modelo mais coerente e incluindo o efeito de "descanso" do cliente como fator de probabilidade.

### 2.3 Premissa de Blindagem

Todas as divisões e médias são protegidas contra:
- Divisão por zero (`NULLIF` + `ISNULL`)
- Registros sem conexão (`CASE WHEN ... ELSE 0`)
- Clientes sem histórico (retornam score base, nunca NULL)

### 2.4 Premissa de Granularidade

O modelo opera no nível `(Cliente_id, Numero_Telefone)`. Um mesmo cliente pode ter **vários registros** — um para cada número de telefone distinto no histórico de ligações.

---

## 3. Arquitetura Geral

O modelo é construído com **CTEs (Common Table Expressions)** em três etapas:

```
┌─────────────────────────────────────────────────────┐
│           CTE 1: metricas_telefone                   │
│         (agrega por Cliente_id + Numero_Telefone)    │
│                                                      │
│  ├── Contagens (attempts, answered, cpc)             │
│  ├── Taxas (answer_rate_tel, cpc_rate_tel)           │
│  ├── Datas (primeira, última, dias desde)            │
│  ├── Janela 30d (attempts_30d_tel, answered_30d_tel) │
│  ├── Diversidade (campanhas, mailings)               │
│  └── Duração média conectado                         │
├─────────────────────────────────────────────────────┤
│           CTE 2: metricas_cliente                    │
│         (agrega por Cliente_id — visão global)       │
│                                                      │
│  ├── Contagens globais (soma de todos os telefones)  │
│  ├── answer_rate_cli (taxa global)                   │
│  ├── dias_desde_ultima_cli (mín. entre telefones)    │
│  ├── attempts_30d_cli (soma global)                  │
│  └── qtd_telefones_cli                               │
├─────────────────────────────────────────────────────┤
│           SELECT FINAL                               │
│         (JOIN telefone × cliente)                    │
│                                                      │
│  Calcula:                                            │
│  ├── score_telefone  (0 a 1)  ─── peso 70%          │
│  │    ├── 60% answer_rate_tel                        │
│  │    ├── 20% recência_tel                           │
│  │    └── 20% (1 - fadiga_tel)                       │
│  ├── score_cliente   (0 a 1)  ─── peso 30%          │
│  │    ├── 60% answer_rate_cli                        │
│  │    ├── 20% recência_cli         ← NOVO v3.1      │
│  │    └── 20% (1 - fadiga_cli)                       │
│  ├── score_final     (0 a 100)                      │
│  └── classificacao_score (A/B/C/D/E)                │
└─────────────────────────────────────────────────────┘
```

---

## 4. Fonte de Dados

### 4.1 Tabela Principal: `ligacao`

Contém o registro de **todas as tentativas de ligação** realizadas pelo discador.

| Campo               | Tipo     | Descrição                                                  |
| ------------------- | -------- | ---------------------------------------------------------- |
| `Ligacao_Cod`       | INT (PK) | Código único da ligação (usado para contagem)              |
| `Cliente_id`        | INT (FK) | Identificador do cliente                                   |
| `Numero_Telefone`   | VARCHAR  | Número discado                                             |
| `Dt_Ligacao`        | DATETIME | Data/hora da tentativa de ligação                          |
| `Conectado`         | BIT      | 1 = ligação conectada (atendida); 0 = não conectada        |
| `Duracao_Conectado` | INT      | Duração em segundos da parte conectada da ligação          |
| `Tipo_Processo_id`  | INT (FK) | Tipo de processo (usado para determinar CPC via JOIN)      |
| `Campanha_id`       | INT (FK) | Identificador da campanha que originou a ligação           |
| `Mailing_id`        | INT (FK) | Identificador do mailing que originou a ligação            |

### 4.2 Tabela Auxiliar: `configuracao_aux`

Contém configurações auxiliares do sistema, usada para **determinar se um contato conectado é CPC** (Contato com a Pessoa Certa).

| Campo              | Tipo | Descrição                                         |
| ------------------ | ---- | ------------------------------------------------- |
| `tlv_registro_id`  | INT  | Código do tipo de processo (FK para ligação)       |
| `campo_aux_id`     | INT  | Identificador do campo auxiliar de configuração    |

**Condição de JOIN:**

```sql
LEFT JOIN configuracao_aux cpc
    ON cpc.tlv_registro_id = l.Tipo_Processo_id
   AND cpc.campo_aux_id = 2126
```

- O `campo_aux_id = 2126` é o identificador fixo que marca tipos de processo considerados como **CPC**
- Quando o JOIN resulta em `cpc.tlv_registro_id IS NOT NULL`, a ligação conectada é classificada como CPC
- Quando resulta em `NULL`, a ligação conectada foi atendida mas **não** pela pessoa certa

### 4.3 Lógica de Classificação CPC

```
Ligação feita
    │
    ├── Conectado = 0  →  Não atendida (apenas tentativa)
    │
    └── Conectado = 1  →  Atendida
            │
            ├── cpc.tlv_registro_id IS NOT NULL  →  CPC (Contato com Pessoa Certa)
            │
            └── cpc.tlv_registro_id IS NULL      →  Contato genérico (atendeu terceiro)
```

---

## 5. Granularidade da Análise

### Nível de agregação: `(Cliente_id, Numero_Telefone)`

Cada linha do resultado representa **um par único** de cliente + telefone.

| Cenário                                           | Registros gerados |
| ------------------------------------------------- | ----------------- |
| Cliente A com 1 telefone                           | 1 registro        |
| Cliente A com 3 telefones                          | 3 registros       |
| Cliente A (tel 1) + Cliente B (tel 1, mesmo número)| 2 registros       |

**Implicação prática:** O score é **específico por número**. O mesmo cliente pode ter:
- Telefone principal com score 85 (celular pessoal)
- Telefone secundário com score 12 (telefone antigo)

Isso permite que a operação escolha **qual número discar** para cada cliente.

---

## 6. Métricas por Telefone — Definições Detalhadas

Todas as métricas abaixo são calculadas na **CTE `metricas_telefone`**, agregando no nível `(Cliente_id, Numero_Telefone)`.

---

### 6.1 `total_attempts_tel`

```sql
COUNT(l.Ligacao_Cod)
```

**Definição:** Número total de tentativas de ligação realizadas para aquele número do cliente.

**Inclui:** Todas as ligações — atendidas, não atendidas, caídas, ocupadas, sem resposta.

**Interpretação:**
| Valor     | Leitura                                                        |
| --------- | -------------------------------------------------------------- |
| 1-5       | Baixa exposição — número pouco explorado                       |
| 6-20      | Exposição moderada — amostra suficiente para análise           |
| 21-50     | Alta exposição — padrão de atendimento já é robusto            |
| > 50      | Número altamente trabalhado — avaliar fadiga e produtividade   |

**Uso no modelo:** Denominador da `answer_rate_tel`. Quanto maior, mais confiável é a taxa.

---

### 6.2 `total_answered_tel`

```sql
SUM(CASE WHEN l.Conectado = 1 THEN 1 ELSE 0 END)
```

**Definição:** Número de ligações **efetivamente conectadas** naquele número.

**Nota:** Inclui CPC e contatos com terceiros.

---

### 6.3 `total_cpc_tel`

```sql
SUM(CASE WHEN l.Conectado = 1 AND cpc.tlv_registro_id IS NOT NULL THEN 1 ELSE 0 END)
```

**Definição:** Ligações conectadas E classificadas como CPC (Contato com a Pessoa Certa) naquele número.

**Hierarquia invariável:**

```
total_attempts_tel ≥ total_answered_tel ≥ total_cpc_tel
```

---

### 6.4 `answer_rate_tel`

```sql
ISNULL(
    CAST(SUM(CASE WHEN l.Conectado = 1 THEN 1 ELSE 0 END) AS FLOAT)
    / NULLIF(COUNT(l.Ligacao_Cod), 0),
0)
```

**Fórmula:** `total_answered_tel / total_attempts_tel`

**Range:** 0.0 a 1.0

**É a métrica mais importante do modelo — contribui com 42% do score final.**

**Interpretação:**

| Taxa       | Classificação  | Ação recomendada                              |
| ---------- | -------------- | --------------------------------------------- |
| > 0.40     | Excelente      | Prioridade máxima de discagem                 |
| 0.20–0.40  | Boa            | Número confiável, manter na fila              |
| 0.05–0.20  | Fraca          | Avaliar custo-benefício de insistir            |
| < 0.05     | Crítica        | Considerar depreciação ou remoção do número   |

**Proteções:**
- `NULLIF(..., 0)` evita divisão por zero
- `ISNULL(..., 0)` garante retorno 0 em vez de NULL

---

### 6.5 `cpc_rate_tel`

```sql
ISNULL(
    CAST(SUM(...CPC...) AS FLOAT) / NULLIF(SUM(...CONNECTED...), 0),
0)
```

**Fórmula:** `total_cpc_tel / total_answered_tel`

**ATENÇÃO:** Denominador é `total_answered_tel` (não `total_attempts_tel`).

**O que mede:** Quando conseguimos conectar neste número, qual a proporção em que falamos com a pessoa certa?

| Taxa     | Significado                                              |
| -------- | -------------------------------------------------------- |
| > 0.80   | Número pessoal — quase sempre quem atende é o titular    |
| 0.50–0.80| Compartilhado, mas frequentemente atende o titular       |
| 0.20–0.50| Alto risco de terceiro atender                           |
| < 0.20   | Provavelmente número comercial ou de terceiro            |

**Uso atual:** Métrica informativa/analítica exposta no resultado. Não participa diretamente do cálculo do score, mas é essencial para análise de qualidade do contato.

---

### 6.6 `primeira_ligacao_tel` / `ultima_ligacao_tel`

```sql
MIN(l.Dt_Ligacao)  -- primeira
MAX(l.Dt_Ligacao)  -- última
```

**Uso:** Contextual e analítico. A `ultima_ligacao_tel` é base para `dias_desde_ultima_tel`.

---

### 6.7 `dias_desde_ultima_tel`

```sql
DATEDIFF(DAY, MAX(l.Dt_Ligacao), GETDATE())
```

**Definição:** Dias corridos entre a última tentativa neste número e a data de execução.

**Impacto direto no score_telefone (peso 20% — componente de recência):**

| Dias  | Faixa               | Fator de recência | Significado                               |
| ----- | ------------------- | ----------------- | ----------------------------------------- |
| ≥ 60  | Descanso longo      | 1.0               | Número "descansado", máxima disponibilidade|
| 30–59 | Descanso moderado   | 0.7               | Período razoável desde último contato      |
| 14–29 | Contato recente     | 0.5               | Alguma chance de fadiga                    |
| < 14  | Contato muito recente| 0.3              | Maior risco de não atender                 |

---

### 6.8 `attempts_30d_tel`

```sql
SUM(CASE WHEN l.Dt_Ligacao >= DATEADD(DAY, -30, GETDATE()) THEN 1 ELSE 0 END)
```

**Definição:** Tentativas de ligação nos últimos 30 dias **neste telefone específico**.

**Impacto direto no score_telefone (peso 20% — componente de fadiga):**

| Tentativas 30d | Fator de fadiga | (1 - fadiga) | Significado                          |
| --------------- | --------------- | ------------ | ------------------------------------ |
| ≥ 6             | 1.0             | **0.0**      | Número saturado, fadiga máxima        |
| 4–5             | 0.7             | **0.3**      | Pressão alta                          |
| 2–3             | 0.4             | **0.6**      | Pressão moderada                      |
| 0–1             | 0.0             | **1.0**      | Sem pressão recente                   |

---

### 6.9 `answered_30d_tel`

Ligações conectadas nos últimos 30 dias neste número. **Métrica informativa** — não participa do cálculo do score.

---

### 6.10 `distinct_campaigns` / `distinct_mailings`

Quantidade de campanhas e mailings distintos. **Métricas informativas** para análise de amplitude.

---

### 6.11 `avg_duracao_conectado_tel`

```sql
ISNULL(AVG(CASE WHEN l.Conectado = 1 THEN l.Duracao_Conectado END), 0)
```

**Definição:** Duração média (segundos) das ligações conectadas neste número.

**Uso atual:** Métrica informativa. **Não participa diretamente do score**, mas é exposta para análise de qualidade do contato.

| Duração (seg) | Significado                                              |
| ------------- | -------------------------------------------------------- |
| ≥ 60          | Conversas substanciais                                    |
| 30–59         | Conversas curtas mas engajadas                            |
| 10–29         | Contatos breves, possivelmente transferências              |
| < 10          | Desligamento rápido, pouco engajamento                    |

---

## 7. Métricas por Cliente (Global) — Definições Detalhadas

Calculadas na **CTE `metricas_cliente`**, agregando **todos os telefones** de um mesmo `Cliente_id`.

---

### 7.1 `total_attempts_cli`

```sql
SUM(total_attempts_tel)
```

**Definição:** Total de tentativas de ligação feitas para o cliente em **todos os seus números**.

**O que mede:** Pressão global acumulada sobre o cliente.

---

### 7.2 `total_answered_cli`

```sql
SUM(total_answered_tel)
```

**Definição:** Total de ligações conectadas do cliente em todos os números.

---

### 7.3 `total_cpc_cli`

```sql
SUM(total_cpc_tel)
```

**Definição:** Total de CPCs do cliente em todos os números.

---

### 7.4 `answer_rate_cli`

```sql
ISNULL(
    CAST(SUM(total_answered_tel) AS FLOAT) / NULLIF(SUM(total_attempts_tel), 0),
0)
```

**Fórmula:** `total_answered_cli / total_attempts_cli`

**O que mede:** **Comportamento estrutural do cliente.** Independente do número, o cliente costuma atender a Brasilseg?

**Peso efetivo no score final:** 18% (0.60 × 0.30 × 100)

**Perfis típicos:**

| answer_rate_cli | Perfil do cliente                                    |
| --------------- | ---------------------------------------------------- |
| > 0.35          | Cliente receptivo — costuma atender ligações           |
| 0.15–0.35       | Cliente seletivo — atende às vezes                     |
| 0.05–0.15       | Cliente arredio — raramente atende                     |
| < 0.05          | Cliente bloqueador — quase nunca atende                |

**Por que importa:** Um telefone novo (sem histórico) de um cliente que sempre atende tem chance diferente de um telefone novo de um cliente que nunca atende. O score_cliente captura essa diferença.

---

### 7.5 `dias_desde_ultima_cli`

```sql
MIN(dias_desde_ultima_tel)
```

**Definição:** Dias desde a última tentativa de contato com o cliente em **qualquer** telefone.

**Usa `MIN`** porque basta ter sido acionado em um telefone recentemente para considerar contato recente.

**Impacto direto no score_cliente (peso 20% — componente de recência global):**

| Dias  | Faixa               | Fator de recência | Significado                                    |
| ----- | ------------------- | ----------------- | ---------------------------------------------- |
| ≥ 60  | Descanso longo      | 1.0               | Cliente "descansado", máxima disponibilidade    |
| 30–59 | Descanso moderado   | 0.7               | Período razoável desde último contato           |
| 14–29 | Contato recente     | 0.5               | Alguma chance de o cliente estar saturado        |
| < 14  | Contato muito recente| 0.3              | Maior risco de rejeição por excesso de contato  |

> **Novo na v3.1:** Esta métrica agora participa diretamente do cálculo do score_cliente, usando as mesmas faixas do nível telefone. Isso garante que clientes que não são contactados há mais tempo recebam um bônus de probabilidade.

- Peso efetivo no score final: **6%** (0.20 × 0.30 × 100)

---

### 7.6 `attempts_30d_cli`

```sql
SUM(attempts_30d_tel)
```

**Definição:** Total de tentativas nos últimos 30 dias em **todos os telefones** do cliente.

**Impacto direto no score_cliente (peso 20% — componente de fadiga global):**

| Tentativas 30d (global) | Fator de fadiga | (1 - fadiga) | Significado                        |
| ------------------------ | --------------- | ------------ | ---------------------------------- |
| ≥ 12                     | 1.0             | **0.0**      | Cliente saturado, fadiga máxima     |
| 8–11                     | 0.7             | **0.3**      | Pressão alta                        |
| 4–7                      | 0.4             | **0.6**      | Pressão moderada                    |
| 0–3                      | 0.0             | **1.0**      | Sem pressão significativa           |

> **Nota:** Os thresholds do cliente (4/8/12) são **mais altos** que os do telefone (2/4/6) porque a fadiga global é a soma de todos os telefones. Um cliente com 3 telefones e 2 tentativas cada não está tão saturado quanto um telefone com 6 tentativas diretas.

---

### 7.7 `qtd_telefones_cli`

```sql
COUNT(*)
```

**Definição:** Quantidade de telefones distintos do cliente no histórico.

**Uso:** Métrica informativa. Clientes com mais telefones oferecem mais opções de contato.

---

## 8. Score Telefone — Composição (70%)

### Fórmula:

```sql
score_telefone = (0.60 × answer_rate_tel)
              + (0.20 × fator_recencia_tel)
              + (0.20 × (1 - fator_fadiga_tel))
```

### Componentes:

#### 8.1 Componente 1: answer_rate_tel (60%)

Diretamente a taxa de atendimento do número. Quanto mais atende, melhor.

- Range: 0.0 a 1.0
- Peso efetivo no score final: **42%** (0.60 × 0.70 × 100)

#### 8.2 Componente 2: Recência (20%)

```sql
fator_recencia_tel = CASE
    WHEN dias_desde_ultima_tel >= 60 THEN 1.0
    WHEN dias_desde_ultima_tel >= 30 THEN 0.7
    WHEN dias_desde_ultima_tel >= 14 THEN 0.5
    ELSE 0.3
END
```

Números com mais "descanso" recebem score maior. A lógica é baseada em **degraus** (não linear):

| Faixa (dias)    | Valor | Razão                                  |
| --------------- | ----- | -------------------------------------- |
| ≥ 60            | 1.0   | Suficientemente descansado              |
| 30–59           | 0.7   | Bom intervalo                           |
| 14–29           | 0.5   | Intervalo aceitável                     |
| < 14            | 0.3   | Contato muito recente, nunca zero       |

**Por que nunca zero?** Mesmo um contato recente pode ser bem-sucedido. Zero eliminaria completamente a contribuição de recência, o que seria excessivamente pessimista.

- Peso efetivo no score final: **14%** (0.20 × 0.70 × 100)

#### 8.3 Componente 3: (1 - Fadiga) (20%)

```sql
fator_fadiga_tel = CASE
    WHEN attempts_30d_tel >= 6 THEN 1.0
    WHEN attempts_30d_tel >= 4 THEN 0.7
    WHEN attempts_30d_tel >= 2 THEN 0.4
    ELSE 0.0
END

componente_fadiga = 1.0 - fator_fadiga_tel
```

A penalização por fadiga é **subtraída de 1** para que menos pressão = mais score.

| attempts_30d_tel | fator_fadiga | (1 - fadiga) | Efeito                    |
| ---------------- | ------------ | ------------ | ------------------------- |
| 0–1              | 0.0          | **1.0**      | Score cheio               |
| 2–3              | 0.4          | **0.6**      | Penalização leve           |
| 4–5              | 0.7          | **0.3**      | Penalização forte          |
| ≥ 6              | 1.0          | **0.0**      | Score zerado neste componente |

- Peso efetivo no score final: **14%** (0.20 × 0.70 × 100)

### Tabela completa — Todos os cenários do score_telefone:

O score_telefone varia entre **0.06** (pior caso teórico) e **1.00** (melhor caso).

| answer_rate | recência | fadiga tel | score_telefone |
| ----------- | -------- | ---------- | -------------- |
| 0.50        | ≥60d (1.0) | 0 tent (1.0) | **0.70**    |
| 0.50        | <14d (0.3) | ≥6 tent (0.0)| **0.36**    |
| 0.30        | 30d (0.7)  | 3 tent (0.6) | **0.44**    |
| 0.10        | ≥60d (1.0) | 0 tent (1.0) | **0.46**    |
| 0.00        | <14d (0.3) | ≥6 tent (0.0)| **0.06**    |
| 1.00        | ≥60d (1.0) | 0 tent (1.0) | **1.00**    |

---

## 9. Score Cliente — Composição (30%)

### Fórmula (v3.1 — atualizada):

```sql
score_cliente = (0.60 × answer_rate_cli)
             + (0.20 × fator_recencia_cli)
             + (0.20 × (1 - fator_fadiga_cli))
```

> **Evolução v3.1:** A fórmula anterior era `0.70 × answer_rate_cli + 0.30 × (1 - fadiga)`. A nova versão inclui o fator de recência global do cliente, tornando a estrutura simétrica à do score_telefone.

### Componentes:

#### 9.1 Componente 1: answer_rate_cli (60%)

Taxa global de atendimento do cliente em todos os telefones.

- Range: 0.0 a 1.0
- Peso efetivo no score final: **18%** (0.60 × 0.30 × 100)

**Por que 60%?** O comportamento estrutural do cliente é a informação mais valiosa no nível de cliente. Um cliente que historicamente atende em 40% das tentativas tem esse padrão independente do número.

#### 9.2 Componente 2: Recência global (20%) — NOVO v3.1

```sql
fator_recencia_cli = CASE
    WHEN dias_desde_ultima_cli >= 60 THEN 1.0
    WHEN dias_desde_ultima_cli >= 30 THEN 0.7
    WHEN dias_desde_ultima_cli >= 14 THEN 0.5
    ELSE 0.3
END
```

Clientes que não são contactados há mais tempo recebem um bônus no score. As faixas são **idênticas** às do nível telefone:

| Faixa (dias)    | Valor | Significado                                          |
| --------------- | ----- | ---------------------------------------------------- |
| ≥ 60            | 1.0   | Cliente descansado, máxima probabilidade de atender   |
| 30–59           | 0.7   | Intervalo razoável                                    |
| 14–29           | 0.5   | Contato recente, algum risco de saturação             |
| < 14            | 0.3   | Contato muito recente em pelo menos um telefone       |

**Justificativa:** Mesmo que o score_telefone já capture a recência do número específico, a recência global do cliente captura um efeito diferente — a **disposição geral do cliente** em atender. Um cliente que não é contactado há 60 dias (em nenhum telefone) está mais propenso a atender do que um que recebeu ligações ontem em outro número.

- Peso efetivo no score final: **6%** (0.20 × 0.30 × 100)

> **Nota:** Embora o peso efetivo de 6% pareça baixo, em cenários onde recência_tel e recência_cli divergem significativamente (ex.: telefone novo de um cliente muito trabalhado), esse componente tem impacto perceptível.

#### 9.3 Componente 3: (1 - Fadiga global) (20%)

```sql
fator_fadiga_cli = CASE
    WHEN attempts_30d_cli >= 12 THEN 1.0
    WHEN attempts_30d_cli >= 8  THEN 0.7
    WHEN attempts_30d_cli >= 4  THEN 0.4
    ELSE 0.0
END

componente_fadiga_cli = 1.0 - fator_fadiga_cli
```

| attempts_30d_cli | fator_fadiga | (1 - fadiga) | Efeito                         |
| ---------------- | ------------ | ------------ | ------------------------------ |
| 0–3              | 0.0          | **1.0**      | Score cheio                    |
| 4–7              | 0.4          | **0.6**      | Penalização leve                |
| 8–11             | 0.7          | **0.3**      | Penalização forte               |
| ≥ 12             | 1.0          | **0.0**      | Score zerado neste componente  |

- Peso efetivo no score final: **6%** (0.20 × 0.30 × 100)

### Tabela completa — Todos os cenários do score_cliente:

O score_cliente varia entre **0.06** (pior caso teórico) e **1.00** (melhor caso).

| answer_rate_cli | recência_cli | fadiga_cli     | score_cliente |
| --------------- | ------------ | -------------- | ------------- |
| 0.50            | ≥60d (1.0)   | 0 tent (1.0)   | **0.70**     |
| 0.50            | <14d (0.3)   | ≥12 tent (0.0) | **0.36**     |
| 0.30            | 30d (0.7)    | 5 tent (0.6)   | **0.44**     |
| 0.10            | ≥60d (1.0)   | 0 tent (1.0)   | **0.46**     |
| 0.00            | <14d (0.3)   | ≥12 tent (0.0) | **0.06**     |
| 1.00            | ≥60d (1.0)   | 0 tent (1.0)   | **1.00**     |

**Exemplo de impacto da camada cliente (v3.1):**

Imagine dois telefones com `answer_rate_tel = 0.30`, `dias_desde_ultima_tel = 45`, `attempts_30d_tel = 1`:

| Cenário           | answer_rate_cli | dias_desde_cli | attempts_30d_cli | score_cliente | Efeito no final |
| ----------------- | --------------- | -------------- | ---------------- | ------------- | --------------- |
| Cliente receptivo | 0.45            | 45             | 2                | 0.61          | +18.3 pontos    |
| Cliente arredio   | 0.05            | 3              | 10               | 0.12          | +3.6 pontos     |

Diferença de **≈15 pontos** no score final, mesmo com o mesmo telefone!

---

## 10. Score Final — Cálculo e Pesos Efetivos

### Fórmula:

```
Score_Final = (0.70 × Score_Telefone + 0.30 × Score_Cliente) × 100
```

### Desdobramento completo (v3.1):

```
Score_Final = 100 × [
    0.70 × (
        0.60 × answer_rate_tel                    ← 42% peso efetivo
      + 0.20 × fator_recencia_tel                 ← 14% peso efetivo
      + 0.20 × (1 - fator_fadiga_tel)             ← 14% peso efetivo
    )
  + 0.30 × (
        0.60 × answer_rate_cli                    ← 18% peso efetivo
      + 0.20 × fator_recencia_cli                 ←  6% peso efetivo  ← NOVO v3.1
      + 0.20 × (1 - fator_fadiga_cli)             ←  6% peso efetivo
    )
]
```

### Mapa de pesos efetivos (v3.1):

| #  | Variável                | Camada   | Peso interno | Peso camada | **Peso efetivo** | Δ vs v3.0  |
| -- | ----------------------- | -------- | ------------ | ----------- | ---------------- | ---------- |
| 1  | `answer_rate_tel`       | Telefone | 60%          | 70%         | **42.0%**        | =          |
| 2  | `fator_recencia_tel`    | Telefone | 20%          | 70%         | **14.0%**        | =          |
| 3  | `(1-fadiga_tel)`        | Telefone | 20%          | 70%         | **14.0%**        | =          |
| 4  | `answer_rate_cli`       | Cliente  | 60%          | 30%         | **18.0%**        | era 21.0%  |
| 5  | `fator_recencia_cli`    | Cliente  | 20%          | 30%         | **6.0%**         | **NOVO**   |
| 6  | `(1-fadiga_cli)`        | Cliente  | 20%          | 30%         | **6.0%**         | era 9.0%   |
|    |                         |          |              | **TOTAL:**  | **100.0%**       |            |

> **Comparação v3.0 → v3.1:** O `answer_rate_cli` perdeu 3 p.p. (de 21% para 18%) e a fadiga_cli perdeu 3 p.p. (de 9% para 6%) para acomodar os 6% do novo componente de recência. A camada telefone permanece inalterada.

### Range:

| Mínimo | Máximo | Unidade |
| ------ | ------ | ------- |
| 0      | 100    | Pontos  |

### Classificação automática (na query):

```sql
CASE
    WHEN score_final >= 80 THEN 'A - Alta Probabilidade'
    WHEN score_final >= 60 THEN 'B - Boa Probabilidade'
    WHEN score_final >= 40 THEN 'C - Moderada'
    WHEN score_final >= 20 THEN 'D - Baixa'
    ELSE 'E - Muito Baixa'
END AS classificacao_score
```

---

## 11. Interpretação Operacional

### 11.1 Faixas de Score

| Score    | Class. | Cor       | Ação recomendada                                      |
| -------- | ------ | --------- | ----------------------------------------------------- |
| 80 – 100 | A      | 🟢 Verde  | Prioridade máxima de discagem                         |
| 60 – 79  | B      | 🟡 Amarelo| Incluir na fila com prioridade                        |
| 40 – 59  | C      | 🟠 Laranja| Avaliar custo-benefício; considerar canal alternativo |
| 20 – 39  | D      | 🔴 Verm.  | Baixa prioridade; usar apenas se fila estiver vazia   |
| 0 – 19   | E      | ⚫ Crítico | Considerar exclusão temporária ou permanente          |

### 11.2 Perfis Típicos de Número

| Perfil                        | answer_rate_tel | answer_rate_cli | fadiga | Score aprox. |
| ----------------------------- | --------------- | --------------- | ------ | ------------ |
| Celular principal, ativo      | 0.45            | 0.40            | baixa  | 75–90        |
| Celular secundário            | 0.20            | 0.35            | média  | 40–55        |
| Fixo residencial              | 0.15            | 0.30            | baixa  | 35–50        |
| Número antigo, sem resposta   | 0.02            | 0.10            | alta   | 5–15         |
| Número novo, sem histórico    | 0.00            | 0.40            | baixa  | 18–22*       |

*Números sem histórico próprio se beneficiam do score_cliente (se o cliente é receptivo). Isso é uma vantagem da arquitetura de dois níveis.

### 11.3 Uso na Priorização de Discagem

```sql
SELECT *
FROM resultado_score
WHERE classificacao_score IN ('A - Alta Probabilidade', 'B - Boa Probabilidade')
ORDER BY score_final DESC
```

| Capacidade da PA | Corte sugerido | Classes incluídas |
| ---------------- | -------------- | ----------------- |
| Baixa (poucas PA)| ≥ 70          | A                 |
| Média            | ≥ 50          | A + B parcial     |
| Alta (muitas PA) | ≥ 30          | A + B + C         |
| Campanha massiva | ≥ 20          | A + B + C + D     |

---

## 12. Tratamento de Nulls e Edge Cases

### 12.1 Divisão por Zero

| Métrica            | Situação de risco          | Proteção aplicada                        | Resultado |
| ------------------ | -------------------------- | ---------------------------------------- | --------- |
| `answer_rate_tel`  | `total_attempts_tel = 0`   | `NULLIF(COUNT(...), 0)` + `ISNULL(..., 0)` | 0.0    |
| `cpc_rate_tel`     | `total_answered_tel = 0`   | `NULLIF(SUM(...), 0)` + `ISNULL(..., 0)`   | 0.0    |
| `answer_rate_cli`  | `total_attempts_cli = 0`   | `NULLIF(SUM(...), 0)` + `ISNULL(..., 0)`   | 0.0    |

### 12.2 Médias com Dados Ausentes

| Métrica                    | Situação               | Proteção               | Resultado |
| -------------------------- | ---------------------- | ---------------------- | --------- |
| `avg_duracao_conectado_tel`| Nenhuma conexão        | `ISNULL(AVG(...), 0)`  | 0         |

### 12.3 Score Final

Todos os componentes são protegidos. O `score_final` **nunca será NULL**. Valor mínimo possível = **0**.

### 12.4 Edge Cases

| Caso                                        | Comportamento                                                  |
| ------------------------------------------- | -------------------------------------------------------------- |
| Cliente com 0 tentativas                     | Não aparece no resultado (filtrado pelo GROUP BY)               |
| Tel com 1 tentativa, não atendida            | answer_rate_tel=0, score ≈ (recência + fadiga) × 14 + cli × 30|
| Tel com 1 tentativa, atendida + CPC          | answer_rate_tel=1, score alto (se cliente também bom)          |
| Cliente com 1 telefone                       | answer_rate_cli = answer_rate_tel (métricas idênticas)          |
| `Duracao_Conectado` NULL em ligação conectada| AVG ignora NULLs, não afeta o cálculo                          |
| Telefone compartilhado entre 2 clientes      | Tratado como 2 registros independentes (granularidade inclui Cliente_id) |

---

## 13. Filtros e Escopo Temporal

### 13.1 Filtro Principal

```sql
WHERE l.Dt_Ligacao >= '2026-02-10'
```

**Impacto:** Limita a análise a ligações a partir de 10/fev/2026.

**Recomendação de evolução:**
```sql
WHERE l.Dt_Ligacao >= DATEADD(MONTH, -6, GETDATE())
```

### 13.2 Janela de 30 Dias

```sql
l.Dt_Ligacao >= DATEADD(DAY, -30, GETDATE())
```

Janela **deslizante** calculada dinamicamente a cada execução.

---

## 14. Glossário Completo de Campos

### Campos retornados no SELECT final:

| Campo                        | Camada   | Tipo    | Range     | Descrição                                        |
| ---------------------------- | -------- | ------- | --------- | ------------------------------------------------ |
| `Cliente_id`                 | —        | INT     | —         | FK do cliente                                    |
| `Numero_Telefone`            | —        | VARCHAR | —         | Número discado                                   |
| `total_attempts_tel`         | Telefone | INT     | ≥ 1       | Total de tentativas no telefone                  |
| `total_answered_tel`         | Telefone | INT     | 0 a N     | Total de conexões no telefone                    |
| `total_cpc_tel`              | Telefone | INT     | 0 a N     | Total de CPC no telefone                         |
| `answer_rate_tel`            | Telefone | FLOAT   | 0.0–1.0   | Taxa de atendimento do telefone                  |
| `cpc_rate_tel`               | Telefone | FLOAT   | 0.0–1.0   | Taxa de CPC sobre conexões do telefone           |
| `primeira_ligacao_tel`       | Telefone | DATETIME| —         | Data da primeira tentativa                       |
| `ultima_ligacao_tel`         | Telefone | DATETIME| —         | Data da última tentativa                         |
| `dias_desde_ultima_tel`      | Telefone | INT     | ≥ 0       | Dias desde última tentativa no telefone          |
| `attempts_30d_tel`           | Telefone | INT     | 0 a N     | Tentativas 30d no telefone                       |
| `answered_30d_tel`           | Telefone | INT     | 0 a N     | Conexões 30d no telefone                         |
| `distinct_campaigns`         | Telefone | INT     | ≥ 1       | Campanhas distintas                              |
| `distinct_mailings`          | Telefone | INT     | ≥ 1       | Mailings distintos                               |
| `avg_duracao_conectado_tel`  | Telefone | FLOAT   | ≥ 0       | Duração média conectada (seg)                    |
| `total_attempts_cli`         | Cliente  | INT     | ≥ 1       | Total tentativas global                          |
| `total_answered_cli`         | Cliente  | INT     | 0 a N     | Total conexões global                            |
| `total_cpc_cli`              | Cliente  | INT     | 0 a N     | Total CPC global                                 |
| `answer_rate_cli`            | Cliente  | FLOAT   | 0.0–1.0   | Taxa de atendimento global                       |
| `dias_desde_ultima_cli`      | Cliente  | INT     | ≥ 0       | Dias desde último contato global                 |
| `attempts_30d_cli`           | Cliente  | INT     | 0 a N     | Tentativas 30d global                            |
| `answered_30d_cli`           | Cliente  | INT     | 0 a N     | Conexões 30d global                              |
| `qtd_telefones_cli`          | Cliente  | INT     | ≥ 1       | Quantidade de telefones do cliente               |
| `score_telefone`             | Score    | FLOAT   | 0.0–1.0   | Score de eficiência do número                    |
| `score_cliente`              | Score    | FLOAT   | 0.0–1.0   | Score de comportamento do cliente                |
| `score_final`                | Score    | FLOAT   | 0–100     | **Score final de probabilidade de contato**      |
| `classificacao_score`        | Score    | VARCHAR | A/B/C/D/E | Classificação textual                            |

---

## 15. Diagramas de Fluxo

### 15.1 Fluxo de Dados

```
┌──────────┐     LEFT JOIN     ┌──────────────────┐
│ ligacao  │◄──────────────────│ configuracao_aux  │
│          │  ON Tipo_Processo  │ (campo_aux=2126) │
└────┬─────┘                   └──────────────────┘
     │
     │  WHERE Dt_Ligacao >= '2026-02-10'
     │
     ▼
┌────────────────────────────────┐
│  CTE 1: metricas_telefone      │
│  GROUP BY (Cliente_id, Tel)    │
│                                │
│  ► answer_rate_tel             │
│  ► dias_desde_ultima_tel       │
│  ► attempts_30d_tel            │
│  ► cpc_rate_tel                │
│  ► avg_duracao_conectado_tel   │
└──────────┬─────────────────────┘
           │
     ┌─────┴─────┐
     │           │
     ▼           ▼
┌──────────┐  ┌─────────────────────┐
│ (passa   │  │ CTE 2: metricas_cli  │
│  direto) │  │ GROUP BY Cliente_id  │
│          │  │                      │
│          │  │ ► answer_rate_cli    │
│          │  │ ► dias_desde_ult_cli │
│          │  │ ► attempts_30d_cli   │
│          │  │ ► qtd_telefones_cli  │
└────┬─────┘  └──────────┬──────────┘
     │                   │
     ▼                   ▼
┌────────────────────────────────┐
│    SELECT FINAL (JOIN)         │
│    tel.Cliente_id = cli.       │
│                                │
│  ► score_telefone   (0–1)      │
│    60% answer + 20% rec + 20% │
│    (1-fad)                     │
│  ► score_cliente    (0–1)      │
│    60% answer + 20% rec + 20% │
│    (1-fad)        ← SIMÉTRICO │
│  ► score_final      (0–100)    │
│  ► classificacao    (A-E)      │
└────────────────────────────────┘
```

### 15.2 Composição do Score Final (v3.1)

```
score_final (0-100) = 100 × [
│
├── 70% ─── score_telefone
│           ├── 60% ── answer_rate_tel ──────── total_answered_tel / total_attempts_tel
│           ├── 20% ── fator_recencia_tel ───── f(dias_desde_ultima_tel) [0.3–1.0]
│           └── 20% ── (1 - fadiga_tel) ────── 1 - f(attempts_30d_tel) [0.0–1.0]
│
└── 30% ─── score_cliente
            ├── 60% ── answer_rate_cli ──────── total_answered_cli / total_attempts_cli
            ├── 20% ── fator_recencia_cli ───── f(dias_desde_ultima_cli) [0.3–1.0]  ← NOVO v3.1
            └── 20% ── (1 - fadiga_cli) ────── 1 - f(attempts_30d_cli) [0.0–1.0]
]
```

> **Simetria v3.1:** Ambas as camadas possuem a mesma estrutura de 3 componentes (60/20/20), facilitando a interpretação e manutenção do modelo.

---

## 16. Exemplos Práticos de Cálculo

### Exemplo 1: Cliente receptivo, celular principal, sem fadiga

| Métrica                   | Valor  | Camada   |
| ------------------------- | ------ | -------- |
| answer_rate_tel           | 0.50   | Telefone |
| dias_desde_ultima_tel     | 45     | Telefone |
| attempts_30d_tel          | 1      | Telefone |
| answer_rate_cli           | 0.42   | Cliente  |
| dias_desde_ultima_cli     | 45     | Cliente  |
| attempts_30d_cli          | 3      | Cliente  |

**Cálculo:**

```
Score Telefone:
  = (0.60 × 0.50)  +  (0.20 × 0.7)  +  (0.20 × (1 - 0.0))
  =  0.30           +   0.14          +   0.20
  =  0.64

Score Cliente (v3.1):
  = (0.60 × 0.42)  +  (0.20 × 0.7)  +  (0.20 × (1 - 0.0))
  =  0.252          +   0.14          +   0.20
  =  0.592

Score Final:
  = (0.70 × 0.64  +  0.30 × 0.592) × 100
  = (0.448 + 0.178) × 100
  = 62.6  →  Classificação B (Boa Probabilidade)
```

---

### Exemplo 2: Número improdutivo de cliente arredio, alta fadiga

| Métrica                   | Valor  | Camada   |
| ------------------------- | ------ | -------- |
| answer_rate_tel           | 0.03   | Telefone |
| dias_desde_ultima_tel     | 5      | Telefone |
| attempts_30d_tel          | 7      | Telefone |
| answer_rate_cli           | 0.08   | Cliente  |
| dias_desde_ultima_cli     | 2      | Cliente  |
| attempts_30d_cli          | 14     | Cliente  |

**Cálculo:**

```
Score Telefone:
  = (0.60 × 0.03)  +  (0.20 × 0.3)  +  (0.20 × (1 - 1.0))
  =  0.018          +   0.06          +   0.00
  =  0.078

Score Cliente (v3.1):
  = (0.60 × 0.08)  +  (0.20 × 0.3)  +  (0.20 × (1 - 1.0))
  =  0.048          +   0.06          +   0.00
  =  0.108

Score Final:
  = (0.70 × 0.078  +  0.30 × 0.108) × 100
  = (0.055 + 0.032) × 100
  = 8.7  →  Classificação E (Muito Baixa)
```

---

### Exemplo 3: Número novo, cliente receptivo (benefício da camada cliente)

| Métrica                   | Valor  | Camada   |
| ------------------------- | ------ | -------- |
| answer_rate_tel           | 0.00   | Telefone |
| dias_desde_ultima_tel     | 2      | Telefone |
| attempts_30d_tel          | 1      | Telefone |
| answer_rate_cli           | 0.45   | Cliente  |
| dias_desde_ultima_cli     | 2      | Cliente  |
| attempts_30d_cli          | 3      | Cliente  |

**Cálculo:**

```
Score Telefone:
  = (0.60 × 0.00)  +  (0.20 × 0.3)  +  (0.20 × (1 - 0.0))
  =  0.00           +   0.06          +   0.20
  =  0.26

Score Cliente (v3.1):
  = (0.60 × 0.45)  +  (0.20 × 0.3)  +  (0.20 × (1 - 0.0))
  =  0.27           +   0.06          +   0.20
  =  0.53

Score Final:
  = (0.70 × 0.26  +  0.30 × 0.53) × 100
  = (0.182 + 0.159) × 100
  = 34.1  →  Classificação D (Baixa)
```

**Leitura:** Sem a camada cliente, este número teria ~18 pontos. A camada cliente adicionou ~16 pontos porque o cliente é receptivo.

---

### Exemplo 4: Mesmo telefone, dois clientes diferentes

Demonstra como a camada cliente diferencia o mesmo padrão de telefone:

| Métrica              | Cliente A (receptivo)  | Cliente B (arredio)    |
| -------------------- | ---------------------- | ---------------------- |
| answer_rate_tel      | 0.25                   | 0.25                   |
| dias_desde_ultima_tel| 30                     | 30                     |
| attempts_30d_tel     | 2                      | 2                      |
| **answer_rate_cli**  | **0.40**               | **0.05**               |
| **dias_desde_ult_cli**| **30**                | **3**                  |
| **attempts_30d_cli** | **4**                  | **9**                  |

```
                     Cliente A                    Cliente B
Score Telefone:      0.39                         0.39       (idênticos)

Score Cliente (v3.1):
  A: (0.60×0.40) + (0.20×0.7) + (0.20×0.6) = 0.24 + 0.14 + 0.12 = 0.50
  B: (0.60×0.05) + (0.20×0.3) + (0.20×0.3) = 0.03 + 0.06 + 0.06 = 0.15

Score Final:        (0.70×0.39+0.30×0.50)×100   (0.70×0.39+0.30×0.15)×100
                   = 42.3                        = 31.8
Classificação:       C (Moderada)                 D (Baixa)
```

**Diferença de ~10.5 pontos** — e uma mudança de classificação — por causa do comportamento histórico e recência do cliente.

---

### Exemplo 5 (NOVO v3.1): Impacto isolado da recência do cliente

Demonstra como a recência global do cliente afeta o score quando tudo mais é igual:

| Métrica              | Cenário A (desc. longo) | Cenário B (cont. recente) |
| -------------------- | ----------------------- | ------------------------- |
| answer_rate_tel      | 0.30                    | 0.30                      |
| dias_desde_ultima_tel| 40                      | 40                        |
| attempts_30d_tel     | 0                       | 0                         |
| answer_rate_cli      | 0.30                    | 0.30                      |
| **dias_desde_ult_cli**| **65**                 | **5**                     |
| attempts_30d_cli     | 0                       | 0                         |

```
Score Telefone (igual em ambos):
  = (0.60 × 0.30) + (0.20 × 0.7) + (0.20 × 1.0)
  = 0.18 + 0.14 + 0.20 = 0.52

Score Cliente A: (0.60 × 0.30) + (0.20 × 1.0) + (0.20 × 1.0)
              = 0.18 + 0.20 + 0.20 = 0.58

Score Cliente B: (0.60 × 0.30) + (0.20 × 0.3) + (0.20 × 1.0)
              = 0.18 + 0.06 + 0.20 = 0.44

Score Final A: (0.70 × 0.52 + 0.30 × 0.58) × 100 = 53.8  →  C (Moderada)
Score Final B: (0.70 × 0.52 + 0.30 × 0.44) × 100 = 49.6  →  C (Moderada)

Δ = 4.2 pontos — apenas por recência do cliente
```

**Leitura:** O componente de recência_cli sozinho pode contribuir com até ~4 pontos de diferença. Em cenários limítrofes (perto de 40, 60 ou 80), isso pode mudar a classificação.

---

## 17. Aplicação Operacional

### 17.1 Fluxo de Uso

```
1. Execução da query (diária ou sob demanda)
         │
         ▼
2. Resultado com score_final + classificação
         │
         ▼
3. Filtro por classificação (A, B, C...)
         │
         ▼
4. ORDER BY score_final DESC
         │
         ▼
5. Alimentação do discador / envio HSM
         │
         ▼
6. Monitoramento de hit rate por faixa
         │
         ▼
7. Retroalimentação e ajuste de pesos (futuro)
```

### 17.2 Integração com HSM Prestamista

O modelo complementa o processo HSM via `MTE_RESUMO`:

1. Query de score gera probabilidade de contato por (Cliente, Telefone)
2. Score de contato + Score de propensão (produto) = Score combinado
3. Score combinado prioriza envio de HSM WhatsApp

### 17.3 KPIs de Acompanhamento

| KPI                     | Fórmula                                    | Meta     |
| ----------------------- | ------------------------------------------ | -------- |
| Hit rate classe A       | % contatos efetivos em score ≥ 80          | > 40%    |
| Hit rate classe E       | % contatos efetivos em score < 20          | < 8%     |
| Lift A/E                | Hit rate classe A / Hit rate classe E       | > 5×     |
| Redução tentativas      | Tentativas atuais / Tentativas pré-modelo  | > 25%    |

---

## 18. Dependências Técnicas

### 18.1 Infraestrutura

| Componente       | Tecnologia                | Versão mínima |
| ---------------- | ------------------------- | ------------- |
| Banco de dados   | Microsoft SQL Server      | 2016+         |
| Driver           | ODBC Driver for SQL Server| 17+           |
| Linguagem        | Python                    | 3.8+          |
| Libs Python      | pandas, pyodbc, sqlalchemy| pandas ≥ 1.3  |

### 18.2 Tabelas e Campos

| Tabela              | Campos utilizados                                                                   |
| ------------------- | ----------------------------------------------------------------------------------- |
| `ligacao`           | Ligacao_Cod, Cliente_id, Numero_Telefone, Dt_Ligacao, Conectado, Duracao_Conectado, Tipo_Processo_id, Campanha_id, Mailing_id |
| `configuracao_aux`  | tlv_registro_id, campo_aux_id                                                       |

### 18.3 Configurações Fixas

| Parâmetro      | Valor      | Descrição                                |
| -------------- | ---------- | ---------------------------------------- |
| `campo_aux_id` | 2126       | Identificador de CPC na configuracao_aux |
| Filtro de data | 2026-02-10 | Data de corte para histórico             |

---

## 19. Limitações Conhecidas

### 19.1 Instabilidade com Baixo Volume

Pares com < 5 tentativas produzem taxas instáveis. Uma ligação atendida pode gerar `answer_rate_tel = 1.0`.

**Mitigação sugerida:** Suavização bayesiana ou Wilson score interval.

### 19.2 Ausência de Horário

O modelo não considera horário de ligação.

### 19.3 CPC Dependente de Configuração

A classificação CPC depende do `campo_aux_id = 2126`. Alterações nessa configuração afetam o modelo sem retroatividade.

### 19.4 Janela Temporal Fixa

O filtro `WHERE Dt_Ligacao >= '2026-02-10'` é hard-coded. Recomenda-se parametrizar.

### 19.5 Pesos por Expertise

Os pesos (70/30 telefone/cliente e sub-pesos 60/20/20) foram definidos por expertise de negócio, não por otimização estatística.

### 19.6 Métricas Informativas

`cpc_rate_tel`, `avg_duracao_conectado_tel`, `answered_30d_tel`, `distinct_campaigns`, `distinct_mailings`, `answered_30d_cli` são calculadas mas **não participam do score**. Estão disponíveis para análise e futuras evoluções.

### 19.7 Recência Telefone vs Recência Cliente

Quando o cliente possui apenas 1 telefone, `dias_desde_ultima_tel` = `dias_desde_ultima_cli`, fazendo com que o componente de recência contribua de forma duplicada (14% + 6% = 20% efetivo). Em clientes com múltiplos telefones, os valores podem divergir, capturando efeitos diferentes.

---

## 20. Evoluções Futuras

| #  | Evolução                                | Impacto esperado       | Complexidade |
| -- | --------------------------------------- | ---------------------- | ------------ |
| 1  | Calibração estatística dos pesos        | +5-15% de precisão     | Média        |
| 2  | Inclusão de horário ideal               | +10-20% de hit rate    | Alta         |
| 3  | Suavização bayesiana por volume         | Menos falsos positivos | Baixa        |
| 4  | Incluir `avg_duracao` e `cpc_rate` no score | Modelo mais completo | Baixa       |
| 5  | Machine learning (XGBoost/LightGBM)    | +15-25% de precisão    | Alta         |
| 6  | Monitoramento de drift temporal         | Manutenção preditiva   | Média        |
| 7  | Segmentação por canal (voz/HSM/SMS)     | Score por canal        | Média        |
| 8  | Decaimento temporal de evidência        | Dados antigos pesam menos| Média      |
| 9  | A/B test com grupo controle             | Validação do impacto   | Média        |
| 10 | Parametrização da janela temporal       | Flexibilidade          | Baixa        |

---

## 21. Changelog

| Data       | Versão | Alteração                                                              |
| ---------- | ------ | ---------------------------------------------------------------------- |
| 2026-02-26 | 3.1    | **Inclusão do fator recência no score_cliente**                        |
| 2026-02-26 | 3.1    | Score Cliente agora: 60% answer_rate + 20% recência + 20% (1-fadiga)  |
| 2026-02-26 | 3.1    | Faixas de recência_cli idênticas às do telefone (≥60/≥30/≥14/<14)     |
| 2026-02-26 | 3.1    | Pesos efetivos: answer_rate_cli 21%→18%, fadiga_cli 9%→6%, recência_cli +6% |
| 2026-02-26 | 3.1    | Arquitetura agora simétrica: ambas as camadas com 60/20/20             |
| 2026-02-26 | 3.1    | Adicionado Exemplo 5 (impacto isolado recência_cli)                    |
| 2026-02-26 | 3.1    | Adicionada limitação 19.7 (recência duplicada em clientes 1 tel.)      |
| 2026-02-24 | 3.0    | Query reestruturada com CTEs + camada cliente — alinhada com doc       |
| 2026-02-24 | 3.0    | Score: 70% Telefone + 30% Cliente (conforme documentação)              |
| 2026-02-24 | 3.0    | Score Telefone: 60% answer_rate + 20% recência + 20% (1-fadiga)       |
| 2026-02-24 | 3.0    | Score Cliente (v3.0): 70% answer_rate_cli + 30% (1-fadiga_cli)        |
| 2026-02-24 | 3.0    | Faixas de recência refinadas (4 degraus em vez de 3)                   |
| 2026-02-24 | 3.0    | Faixas de fadiga refinadas (4 degraus em vez de 3)                     |
| 2026-02-24 | 3.0    | Adicionada classificação automática A/B/C/D/E na query                 |
| 2026-02-24 | 3.0    | Thresholds de fadiga cliente (4/8/12) separados dos telefone (2/4/6)   |
| 2026-02-24 | 2.0    | Documentação v2 com base na query original                             |
| 2026-02-24 | 1.0    | Documentação inicial                                                   |

---

> **Resumo da evolução v3.0 → v3.1:**  
> A v3.0 usava no score_cliente apenas 2 componentes: `70% answer_rate_cli + 30% (1-fadiga_cli)`. A v3.1 adiciona o **fator de recência global do cliente** e redistribui os pesos para `60% answer_rate_cli + 20% recência_cli + 20% (1-fadiga_cli)`, tornando a arquitetura **simétrica** entre as camadas telefone e cliente. Isso permite que clientes "descansados" (sem contato há mais tempo) recebam um bônus na probabilidade de atendimento, capturando o efeito de que a disposição em atender melhora com o tempo sem acionamento.
