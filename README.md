# 📞 Modelo de Score de Probabilidade de Contato

### Brasilseg – Inteligência de Contactabilidade

**Versão:** 3.2  
**Última atualização:** 2026-03-10  
**Ambiente:** SQL Server (MSSQL) / Python (pandas + pyodbc)  
**Arquivo SQL:** `SCORE_PROBABILIDADE_CONTATO_v3.2.sql`

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
11. [Ranking de Melhor Telefone por Cliente](#11-ranking-de-melhor-telefone-por-cliente)
12. [Interpretação Operacional](#12-interpretação-operacional)
13. [Tratamento de Nulls e Edge Cases](#13-tratamento-de-nulls-e-edge-cases)
14. [Filtros e Escopo Temporal](#14-filtros-e-escopo-temporal)
15. [Glossário Completo de Campos](#15-glossário-completo-de-campos)
16. [Diagramas de Fluxo](#16-diagramas-de-fluxo)
17. [Exemplos Práticos de Cálculo](#17-exemplos-práticos-de-cálculo)
18. [Aplicação Operacional](#18-aplicação-operacional)
19. [Dependências Técnicas](#19-dependências-técnicas)
20. [Limitações Conhecidas](#20-limitações-conhecidas)
21. [Evoluções Futuras](#21-evoluções-futuras)
22. [Changelog](#22-changelog)

---

## 1. Objetivo

Este modelo tem como objetivo criar um **indicador numérico (0 a 100)** que estima a probabilidade de se estabelecer um contato telefônico efetivo com um cliente, considerando um número de telefone específico.

### Pergunta que o modelo responde:

> **"Dado este cliente e este número de telefone, qual a probabilidade de conseguirmos falar com ele?"**

E, a partir da v3.2:

> **"Dentre todos os telefones deste cliente, qual é o melhor número para discar?"**

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
- **Seleção do melhor número:** para cada cliente com múltiplos telefones, o modelo indica qual deve ser discado primeiro *(novo v3.2)*

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

### 2.3 Premissa de Ranking de Telefone — NOVO v3.2

O ranking interno de telefones por cliente é calculado **exclusivamente com base no `score_telefone`**, e não no `score_final`.

**Justificativa:** O `score_cliente` é **idêntico para todos os telefones de um mesmo cliente** (pois depende apenas de métricas globais do cliente). Logo, ordenar pelo `score_final` dentro de um cliente seria matematicamente equivalente a ordenar pelo `score_telefone`, porém semanticamente incorreto — o ranking deve responder a pergunta *"qual número tem maior chance de ser atendido?"*, que é exclusivamente uma qualidade do telefone.

$$\text{score\_final} = 0.70 \times \text{score\_telefone} + \underbrace{0.30 \times \text{score\_cliente}}_{\text{constante para todos os tels. do mesmo cliente}}$$

Portanto, dentro de um cliente, a ordem por `score_final` = ordem por `score_telefone`. Usar `score_telefone` diretamente é a abordagem **correta e transparente**.

### 2.4 Premissa de Blindagem

Todas as divisões e médias são protegidas contra:
- Divisão por zero (`NULLIF` + `ISNULL`)
- Registros sem conexão (`CASE WHEN ... ELSE 0`)
- Clientes sem histórico (retornam score base, nunca NULL)

### 2.5 Premissa de Granularidade

O modelo opera no nível `(Cliente_id, Numero_Telefone)`. Um mesmo cliente pode ter **vários registros** — um para cada número de telefone distinto no histórico de ligações.

---

## 3. Arquitetura Geral

O modelo é construído com **CTEs (Common Table Expressions)** em **quatro etapas** (v3.2 adicionou o CTE de ranking):

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
│           CTE 3: scores_calculados                   │
│         (JOIN telefone × cliente)                    │
│                                                      │
│  ├── score_telefone  (0 a 1)  ─── peso 70%          │
│  │    ├── 60% answer_rate_tel                        │
│  │    ├── 20% recência_tel                           │
│  │    └── 20% (1 - fadiga_tel)                       │
│  ├── score_cliente   (0 a 1)  ─── peso 30%          │
│  │    ├── 60% answer_rate_cli                        │
│  │    ├── 20% recência_cli         ← v3.1           │
│  │    └── 20% (1 - fadiga_cli)                       │
│  ├── score_final     (0 a 100)                      │
│  └── classificacao_score (A/B/C/D/E)                │
├─────────────────────────────────────────────────────┤
│           CTE 4: ranking                 ← NOVO v3.2 │
│         (PARTITION BY Cliente_id)                    │
│                                                      │
│  └── rank_telefone_cliente                           │
│       ordenado por score_telefone DESC               │
│       + critérios de desempate por telefone          │
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
- Telefone principal com score 85 (celular pessoal) → `rank_telefone_cliente = 1`
- Telefone secundário com score 12 (telefone antigo) → `rank_telefone_cliente = 2`

Isso permite que a operação escolha **qual número discar** para cada cliente, usando o campo `melhor_telefone_cliente = 1` como filtro direto.

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

**Impacto direto no score_telefone (peso 20% — componente de recência) e no ranking de desempate:**

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

**Impacto direto no score_telefone (peso 20% — componente de fadiga) e no ranking de desempate:**

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

**Uso:** Métrica informativa. Clientes com mais telefones oferecem mais opções de contato. Também indica o range possível de `rank_telefone_cliente` (1 a `qtd_telefones_cli`).

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

| Faixa (dias)    | Valor | Razão                                  |
| --------------- | ----- | -------------------------------------- |
| ≥ 60            | 1.0   | Suficientemente descansado              |
| 30–59           | 0.7   | Bom intervalo                           |
| 14–29           | 0.5   | Intervalo aceitável                     |
| < 14            | 0.3   | Contato muito recente, nunca zero       |

- Peso efetivo no score final: **14%** (0.20 × 0.70 × 100)

#### 8.3 Componente 3: (1 - Fadiga) (20%)

```sql
fator_fadiga_tel = CASE
    WHEN attempts_30d_tel >= 6 THEN 1.0
    WHEN attempts_30d_tel >= 4 THEN 0.7
    WHEN attempts_30d_tel >= 2 THEN 0.4
    ELSE 0.0
END
```

| attempts_30d_tel | fator_fadiga | (1 - fadiga) | Efeito                    |
| ---------------- | ------------ | ------------ | ------------------------- |
| 0–1              | 0.0          | **1.0**      | Score cheio               |
| 2–3              | 0.4          | **0.6**      | Penalização leve           |
| 4–5              | 0.7          | **0.3**      | Penalização forte          |
| ≥ 6              | 1.0          | **0.0**      | Score zerado neste componente |

- Peso efetivo no score final: **14%** (0.20 × 0.70 × 100)

### Tabela completa — Todos os cenários do score_telefone:

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

### Componentes:

#### 9.1 Componente 1: answer_rate_cli (60%)

- Range: 0.0 a 1.0
- Peso efetivo no score final: **18%** (0.60 × 0.30 × 100)

#### 9.2 Componente 2: Recência global (20%)

```sql
fator_recencia_cli = CASE
    WHEN dias_desde_ultima_cli >= 60 THEN 1.0
    WHEN dias_desde_ultima_cli >= 30 THEN 0.7
    WHEN dias_desde_ultima_cli >= 14 THEN 0.5
    ELSE 0.3
END
```

- Peso efetivo no score final: **6%** (0.20 × 0.30 × 100)

#### 9.3 Componente 3: (1 - Fadiga global) (20%)

```sql
fator_fadiga_cli = CASE
    WHEN attempts_30d_cli >= 12 THEN 1.0
    WHEN attempts_30d_cli >= 8  THEN 0.7
    WHEN attempts_30d_cli >= 4  THEN 0.4
    ELSE 0.0
END
```

- Peso efetivo no score final: **6%** (0.20 × 0.30 × 100)

---

## 10. Score Final — Cálculo e Pesos Efetivos

### Fórmula:

```
Score_Final = (0.70 × Score_Telefone + 0.30 × Score_Cliente) × 100
```

### Mapa de pesos efetivos (v3.1):

| #  | Variável                | Camada   | Peso interno | Peso camada | **Peso efetivo** |
| -- | ----------------------- | -------- | ------------ | ----------- | ---------------- |
| 1  | `answer_rate_tel`       | Telefone | 60%          | 70%         | **42.0%**        |
| 2  | `fator_recencia_tel`    | Telefone | 20%          | 70%         | **14.0%**        |
| 3  | `(1-fadiga_tel)`        | Telefone | 20%          | 70%         | **14.0%**        |
| 4  | `answer_rate_cli`       | Cliente  | 60%          | 30%         | **18.0%**        |
| 5  | `fator_recencia_cli`    | Cliente  | 20%          | 30%         | **6.0%**         |
| 6  | `(1-fadiga_cli)`        | Cliente  | 20%          | 30%         | **6.0%**         |
|    |                         |          |              | **TOTAL:**  | **100.0%**       |

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

## 11. Ranking de Melhor Telefone por Cliente

### NOVO v3.2

O CTE `ranking` atribui a cada telefone sua posição dentro do cliente, identificando qual número tem maior probabilidade de ser atendido.

### Campos gerados:

| Campo                    | Tipo | Range | Descrição                                              |
| ------------------------ | ---- | ----- | ------------------------------------------------------ |
| `rank_telefone_cliente`  | INT  | ≥ 1   | Posição do telefone no cliente (1 = melhor)             |
| `melhor_telefone_cliente`| BIT  | 0 / 1 | Flag: 1 indica o telefone com maior `score_telefone`   |

### Lógica de ordenação:

O ranking é calculado por `ROW_NUMBER() OVER (PARTITION BY Cliente_id ORDER BY ...)` usando **exclusivamente métricas de telefone**, em cascata:

```sql
ORDER BY
    score_telefone        DESC,   -- 1º: score principal do número
    answer_rate_tel       DESC,   -- 2º: desempata pela maior taxa histórica
    attempts_30d_tel      ASC,    -- 3º: prefere o menos pressionado recentemente
    dias_desde_ultima_tel DESC,   -- 4º: prefere o mais descansado
    total_attempts_tel    DESC    -- 5º: prefere amostra maior (taxa mais confiável)
```

### Por que não usar `score_final` para o ranking?

O `score_cliente` é **idêntico para todos os telefones do mesmo cliente** (deriva apenas de métricas globais agregadas do cliente). Portanto, dentro de um mesmo cliente:

$$\text{ordem por score\_final} \equiv \text{ordem por score\_telefone}$$

Usar `score_telefone` é matematicamente equivalente, porém **semanticamente correto** — o ranking responde à pergunta *"qual número tem maior chance de ser atendido?"*, que é uma qualidade exclusiva do telefone, não do cliente.

### Comportamento em empate:

`ROW_NUMBER()` sempre atribui posições únicas. Em empate de `score_telefone`, os critérios de desempate resolvem em cascata. Se dois números tiverem todos os 5 critérios idênticos, a ordem é determinística mas arbitrária.

> Trocar `ROW_NUMBER()` por `RANK()` caso queira que dois números com `score_telefone` exatamente igual compartilhem a mesma posição (e o próximo receba `rank = N+2`).

---

## 12. Interpretação Operacional

### 12.1 Faixas de Score

| Score    | Class. | Cor       | Ação recomendada                                      |
| -------- | ------ | --------- | ----------------------------------------------------- |
| 80 – 100 | A      | 🟢 Verde  | Prioridade máxima de discagem                         |
| 60 – 79  | B      | 🟡 Amarelo| Incluir na fila com prioridade                        |
| 40 – 59  | C      | 🟠 Laranja| Avaliar custo-benefício; considerar canal alternativo |
| 20 – 39  | D      | 🔴 Verm.  | Baixa prioridade; usar apenas se fila estiver vazia   |
| 0 – 19   | E      | ⚫ Crítico | Considerar exclusão temporária ou permanente          |

### 12.2 Perfis Típicos de Número

| Perfil                        | answer_rate_tel | answer_rate_cli | fadiga | Score aprox. |
| ----------------------------- | --------------- | --------------- | ------ | ------------ |
| Celular principal, ativo      | 0.45            | 0.40            | baixa  | 75–90        |
| Celular secundário            | 0.20            | 0.35            | média  | 40–55        |
| Fixo residencial              | 0.15            | 0.30            | baixa  | 35–50        |
| Número antigo, sem resposta   | 0.02            | 0.10            | alta   | 5–15         |
| Número novo, sem histórico    | 0.00            | 0.40            | baixa  | 18–22*       |

### 12.3 Uso na Priorização de Discagem

| Capacidade da PA | Corte sugerido | Classes incluídas |
| ---------------- | -------------- | ----------------- |
| Baixa (poucas PA)| ≥ 70          | A                 |
| Média            | ≥ 50          | A + B parcial     |
| Alta (muitas PA) | ≥ 30          | A + B + C         |
| Campanha massiva | ≥ 20          | A + B + C + D     |

---

## 13. Tratamento de Nulls e Edge Cases

### 13.1 Divisão por Zero

| Métrica            | Situação de risco          | Proteção aplicada                          | Resultado |
| ------------------ | -------------------------- | ------------------------------------------ | --------- |
| `answer_rate_tel`  | `total_attempts_tel = 0`   | `NULLIF(COUNT(...), 0)` + `ISNULL(..., 0)` | 0.0       |
| `cpc_rate_tel`     | `total_answered_tel = 0`   | `NULLIF(SUM(...), 0)` + `ISNULL(..., 0)`   | 0.0       |
| `answer_rate_cli`  | `total_attempts_cli = 0`   | `NULLIF(SUM(...), 0)` + `ISNULL(..., 0)`   | 0.0       |

### 13.2 Score Final

Todos os componentes são protegidos. O `score_final` **nunca será NULL**. Valor mínimo possível = **0**.

### 13.3 Edge Cases

| Caso                                        | Comportamento                                                             |
| ------------------------------------------- | ------------------------------------------------------------------------- |
| Cliente com 0 tentativas                     | Não aparece no resultado (filtrado pelo GROUP BY)                          |
| Cliente com apenas 1 telefone                | `rank_telefone_cliente = 1` e `melhor_telefone_cliente = 1` para o único  |
| Tel com 1 tentativa, não atendida            | answer_rate_tel=0, score ≈ (recência + fadiga) × 14 + cli × 30           |
| Tel com 1 tentativa, atendida + CPC          | answer_rate_tel=1, score alto (se cliente também bom)                     |
| Dois telefones com score_telefone idêntico   | `ROW_NUMBER()` desempata pelos critérios secundários (answer_rate, etc.)  |
| `Duracao_Conectado` NULL em ligação conectada| AVG ignora NULLs, não afeta o cálculo                                     |
| Telefone compartilhado entre 2 clientes      | Tratado como 2 registros independentes (granularidade inclui Cliente_id)  |

---

## 14. Filtros e Escopo Temporal

### 14.1 Filtro Principal

```sql
WHERE l.Dt_Ligacao >= '2026-01-01'
```

**Impacto:** Limita a análise a ligações a partir de 01/jan/2026.

**Recomendação de evolução:**
```sql
WHERE l.Dt_Ligacao >= DATEADD(MONTH, -6, GETDATE())
```

### 14.2 Janela de 30 Dias

```sql
l.Dt_Ligacao >= DATEADD(DAY, -30, GETDATE())
```

Janela **deslizante** calculada dinamicamente a cada execução.

---

## 15. Glossário Completo de Campos

### Campos retornados no SELECT final:

| Campo                        | Camada   | Tipo    | Range     | Descrição                                                    |
| ---------------------------- | -------- | ------- | --------- | ------------------------------------------------------------ |
| `Cliente_id`                 | —        | INT     | —         | FK do cliente                                                |
| `Numero_Telefone`            | —        | VARCHAR | —         | Número discado                                               |
| `rank_telefone_cliente`      | Ranking  | INT     | ≥ 1       | **Posição do telefone no cliente (1 = melhor score_telefone)**|
| `melhor_telefone_cliente`    | Ranking  | BIT     | 0 / 1     | **Flag: 1 = telefone com maior score_telefone do cliente**   |
| `total_attempts_tel`         | Telefone | INT     | ≥ 1       | Total de tentativas no telefone                              |
| `total_answered_tel`         | Telefone | INT     | 0 a N     | Total de conexões no telefone                                |
| `total_cpc_tel`              | Telefone | INT     | 0 a N     | Total de CPC no telefone                                     |
| `answer_rate_tel`            | Telefone | FLOAT   | 0.0–1.0   | Taxa de atendimento do telefone                              |
| `cpc_rate_tel`               | Telefone | FLOAT   | 0.0–1.0   | Taxa de CPC sobre conexões do telefone                       |
| `primeira_ligacao_tel`       | Telefone | DATETIME| —         | Data da primeira tentativa                                   |
| `ultima_ligacao_tel`         | Telefone | DATETIME| —         | Data da última tentativa                                     |
| `dias_desde_ultima_tel`      | Telefone | INT     | ≥ 0       | Dias desde última tentativa no telefone                      |
| `attempts_30d_tel`           | Telefone | INT     | 0 a N     | Tentativas 30d no telefone                                   |
| `answered_30d_tel`           | Telefone | INT     | 0 a N     | Conexões 30d no telefone                                     |
| `distinct_campaigns`         | Telefone | INT     | ≥ 1       | Campanhas distintas                                          |
| `distinct_mailings`          | Telefone | INT     | ≥ 1       | Mailings distintos                                           |
| `avg_duracao_conectado_tel`  | Telefone | FLOAT   | ≥ 0       | Duração média conectada (seg)                                |
| `total_attempts_cli`         | Cliente  | INT     | ≥ 1       | Total tentativas global                                      |
| `total_answered_cli`         | Cliente  | INT     | 0 a N     | Total conexões global                                        |
| `total_cpc_cli`              | Cliente  | INT     | 0 a N     | Total CPC global                                             |
| `answer_rate_cli`            | Cliente  | FLOAT   | 0.0–1.0   | Taxa de atendimento global                                   |
| `dias_desde_ultima_cli`      | Cliente  | INT     | ≥ 0       | Dias desde último contato global                             |
| `attempts_30d_cli`           | Cliente  | INT     | 0 a N     | Tentativas 30d global                                        |
| `answered_30d_cli`           | Cliente  | INT     | 0 a N     | Conexões 30d global                                          |
| `qtd_telefones_cli`          | Cliente  | INT     | ≥ 1       | Quantidade de telefones do cliente                           |
| `score_telefone`             | Score    | FLOAT   | 0.0–1.0   | Score de eficiência do número                                |
| `score_cliente`              | Score    | FLOAT   | 0.0–1.0   | Score de comportamento do cliente                            |
| `score_final`                | Score    | FLOAT   | 0–100     | **Score final de probabilidade de contato**                  |
| `classificacao_score`        | Score    | VARCHAR | A/B/C/D/E | Classificação textual                                        |

> Os campos `rank_telefone_cliente` e `melhor_telefone_cliente` aparecem **logo após `Numero_Telefone`** no SELECT, antes das métricas brutas, para facilitar filtragem direta.

---

## 16. Diagramas de Fluxo

### 16.1 Fluxo de Dados (v3.2)

```
┌──────────┐     LEFT JOIN     ┌──────────────────┐
│ ligacao  │◄──────────────────│ configuracao_aux  │
│          │  ON Tipo_Processo  │ (campo_aux=2126) │
└────┬─────┘                   └──────────────────┘
     │
     │  WHERE Dt_Ligacao >= '2026-01-01'
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
│  CTE 3: scores_calculados      │
│  JOIN telefone × cliente       │
│                                │
│  ► score_telefone   (0–1)      │
│  ► score_cliente    (0–1)      │
│  ► score_final      (0–100)    │
│  ► classificacao    (A-E)      │
└──────────┬─────────────────────┘
           │
           ▼
┌────────────────────────────────┐    ← NOVO v3.2
│  CTE 4: ranking                │
│  PARTITION BY Cliente_id       │
│  ORDER BY score_telefone DESC  │
│  + 4 critérios de desempate    │
│                                │
│  ► rank_telefone_cliente       │
└──────────┬─────────────────────┘
           │
           ▼
┌────────────────────────────────┐
│  SELECT FINAL                  │
│                                │
│  ► rank_telefone_cliente       │
│  ► melhor_telefone_cliente     │
│  ► [todas as métricas]         │
│  ► score_telefone              │
│  ► score_cliente               │
│  ► score_final                 │
│  ► classificacao_score         │
└────────────────────────────────┘
```

### 16.2 Composição do Score Final (v3.1)

```
score_final (0-100) = 100 × [
│
├── 70% ─── score_telefone  ◄── BASE do ranking de melhor telefone (v3.2)
│           ├── 60% ── answer_rate_tel ──────── total_answered_tel / total_attempts_tel
│           ├── 20% ── fator_recencia_tel ───── f(dias_desde_ultima_tel) [0.3–1.0]
│           └── 20% ── (1 - fadiga_tel) ────── 1 - f(attempts_30d_tel) [0.0–1.0]
│
└── 30% ─── score_cliente   ◄── idêntico para todos os tels. do mesmo cliente
            ├── 60% ── answer_rate_cli ──────── total_answered_cli / total_attempts_cli
            ├── 20% ── fator_recencia_cli ───── f(dias_desde_ultima_cli) [0.3–1.0]
            └── 20% ── (1 - fadiga_cli) ────── 1 - f(attempts_30d_cli) [0.0–1.0]
]
```

### 16.3 Lógica do Ranking de Telefone (v3.2)

```
Para cada Cliente_id:

  Tel A: score_telefone = 0.64  →  rank = 1  ✓ melhor_telefone_cliente = 1
  Tel B: score_telefone = 0.44  →  rank = 2
  Tel C: score_telefone = 0.22  →  rank = 3

  Em empate de score_telefone:
    → desempata por answer_rate_tel DESC
    → depois por attempts_30d_tel ASC
    → depois por dias_desde_ultima_tel DESC
    → depois por total_attempts_tel DESC
```

---

## 17. Exemplos Práticos de Cálculo

### Exemplo 1: Cliente receptivo, celular principal, sem fadiga

| Métrica                   | Valor  | Camada   |
| ------------------------- | ------ | -------- |
| answer_rate_tel           | 0.50   | Telefone |
| dias_desde_ultima_tel     | 45     | Telefone |
| attempts_30d_tel          | 1      | Telefone |
| answer_rate_cli           | 0.42   | Cliente  |
| dias_desde_ultima_cli     | 45     | Cliente  |
| attempts_30d_cli          | 3      | Cliente  |

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

| Métrica                   | Valor  |
| ------------------------- | ------ |
| answer_rate_tel           | 0.03   |
| dias_desde_ultima_tel     | 5      |
| attempts_30d_tel          | 7      |
| answer_rate_cli           | 0.08   |
| dias_desde_ultima_cli     | 2      |
| attempts_30d_cli          | 14     |

```
Score Telefone = 0.018 + 0.06 + 0.00 = 0.078
Score Cliente  = 0.048 + 0.06 + 0.00 = 0.108
Score Final    = (0.70×0.078 + 0.30×0.108) × 100 = 8.7  →  E (Muito Baixa)
```

---

### Exemplo 3: Número novo, cliente receptivo

```
Score Telefone = 0.00 + 0.06 + 0.20 = 0.26
Score Cliente  = 0.27 + 0.06 + 0.20 = 0.53
Score Final    = (0.70×0.26 + 0.30×0.53) × 100 = 34.1  →  D (Baixa)
```

**Leitura:** Sem a camada cliente, este número teria ~18 pontos. A camada cliente adicionou ~16 pontos porque o cliente é receptivo.

---

### Exemplo 4: Mesmo cliente, dois telefones — ranking aplicado (NOVO v3.2)

Demonstra como o ranking seleciona o melhor número para discar:

| Campo                    | Tel 1 (celular) | Tel 2 (fixo antigo) |
| ------------------------ | --------------- | ------------------- |
| answer_rate_tel          | 0.40            | 0.05                |
| dias_desde_ultima_tel    | 35              | 10                  |
| attempts_30d_tel         | 1               | 3                   |
| **score_telefone**       | **0.62**        | **0.15**            |
| answer_rate_cli          | 0.30            | 0.30                |
| dias_desde_ultima_cli    | 10              | 10                  |
| attempts_30d_cli         | 4               | 4                   |
| **score_cliente**        | **0.42**        | **0.42** (idêntico) |
| **score_final**          | **54.0**        | **23.1**            |
| **rank_telefone_cliente**| **1**           | **2**               |
| **melhor_telefone_cliente**| **1**         | **0**               |

**Leitura:**
- `score_cliente` é idêntico (0.42) para ambos — confirmando que não diferencia os telefones
- O ranking por `score_telefone` corretamente elege o celular como número a discar
- Filtrar `WHERE melhor_telefone_cliente = 1` retorna apenas o Tel 1 para este cliente

---

### Exemplo 5: Impacto isolado da recência do cliente

| Métrica                  | Cenário A (desc. longo) | Cenário B (cont. recente) |
| ------------------------ | ----------------------- | ------------------------- |
| answer_rate_tel          | 0.30                    | 0.30                      |
| dias_desde_ultima_tel    | 40                      | 40                        |
| attempts_30d_tel         | 0                       | 0                         |
| answer_rate_cli          | 0.30                    | 0.30                      |
| **dias_desde_ult_cli**   | **65**                  | **5**                     |
| attempts_30d_cli         | 0                       | 0                         |

```
Score Telefone (igual): 0.52
Score Cliente A: 0.18 + 0.20 + 0.20 = 0.58
Score Cliente B: 0.18 + 0.06 + 0.20 = 0.44

Score Final A: 53.8  →  C (Moderada)
Score Final B: 49.6  →  C (Moderada)
Δ = 4.2 pontos — apenas por recência do cliente
```

---

## 18. Aplicação Operacional

### 18.1 Fluxo de Uso (v3.2)

```
1. Execução da query (diária ou sob demanda)
         │
         ▼
2. Resultado com score_final + classificação + ranking
         │
         ▼
3a. Filtro por melhor_telefone_cliente = 1
    (1 linha por cliente — melhor número)
         │
         ├── 3b. OU filtro por rank_telefone_cliente <= N
         │       (Top-N números por cliente)
         │
         ▼
4. Filtro adicional por classificacao_score (A, B, C...)
         │
         ▼
5. ORDER BY score_final DESC
         │
         ▼
6. Alimentação do discador / envio HSM
         │
         ▼
7. Monitoramento de hit rate por faixa
         │
         ▼
8. Retroalimentação e ajuste de pesos (futuro)
```

### 18.2 Consultas Operacionais Prontas

```sql
-- 1. Melhor telefone de cada cliente (1 linha por cliente):
SELECT *
FROM ranking
WHERE melhor_telefone_cliente = 1
ORDER BY score_final DESC;

-- 2. Top-2 telefones por cliente (fallback se principal não atender):
SELECT *
FROM ranking
WHERE rank_telefone_cliente <= 2
ORDER BY Cliente_id, rank_telefone_cliente;

-- 3. Melhor telefone, apenas classes A e B (fila de alta prioridade):
SELECT *
FROM ranking
WHERE melhor_telefone_cliente = 1
  AND classificacao_score IN ('A - Alta Probabilidade', 'B - Boa Probabilidade')
ORDER BY score_final DESC;

-- 4. Clientes com múltiplos telefones e grande diferença entre o 1º e 2º:
SELECT r1.Cliente_id,
       r1.Numero_Telefone         AS melhor_tel,
       r1.score_telefone          AS score_tel_1,
       r2.score_telefone          AS score_tel_2,
       r1.score_telefone - r2.score_telefone AS diferenca
FROM ranking r1
JOIN ranking r2
    ON r1.Cliente_id = r2.Cliente_id
   AND r1.rank_telefone_cliente = 1
   AND r2.rank_telefone_cliente = 2
WHERE r1.score_telefone - r2.score_telefone > 0.30
ORDER BY diferenca DESC;
```

### 18.3 Integração com HSM Prestamista

1. Query de score gera probabilidade de contato por (Cliente, Telefone)
2. `melhor_telefone_cliente = 1` seleciona o número prioritário por cliente
3. Score de contato + Score de propensão (produto) = Score combinado
4. Score combinado prioriza envio de HSM WhatsApp

### 18.4 KPIs de Acompanhamento

| KPI                       | Fórmula                                             | Meta     |
| ------------------------- | --------------------------------------------------- | -------- |
| Hit rate classe A         | % contatos efetivos em score ≥ 80                   | > 40%    |
| Hit rate classe E         | % contatos efetivos em score < 20                   | < 8%     |
| Lift A/E                  | Hit rate classe A / Hit rate classe E               | > 5×     |
| Redução tentativas        | Tentativas atuais / Tentativas pré-modelo           | > 25%    |
| Acerto do melhor telefone | % de CPCs obtidos no rank_telefone_cliente = 1      | > 60%    |

---

## 19. Dependências Técnicas

### 19.1 Infraestrutura

| Componente       | Tecnologia                | Versão mínima |
| ---------------- | ------------------------- | ------------- |
| Banco de dados   | Microsoft SQL Server      | 2016+         |
| Driver           | ODBC Driver for SQL Server| 17+           |
| Linguagem        | Python                    | 3.8+          |
| Libs Python      | pandas, pyodbc, sqlalchemy| pandas ≥ 1.3  |

### 19.2 Tabelas e Campos

| Tabela              | Campos utilizados                                                                                                          |
| ------------------- | -------------------------------------------------------------------------------------------------------------------------- |
| `ligacao`           | Ligacao_Cod, Cliente_id, Numero_Telefone, Dt_Ligacao, Conectado, Duracao_Conectado, Tipo_Processo_id, Campanha_id, Mailing_id |
| `configuracao_aux`  | tlv_registro_id, campo_aux_id                                                                                              |

### 19.3 Configurações Fixas

| Parâmetro      | Valor      | Descrição                                |
| -------------- | ---------- | ---------------------------------------- |
| `campo_aux_id` | 2126       | Identificador de CPC na configuracao_aux |
| Filtro de data | 2026-01-01 | Data de corte para histórico             |

---

## 20. Limitações Conhecidas

### 20.1 Instabilidade com Baixo Volume

Pares com < 5 tentativas produzem taxas instáveis. Uma ligação atendida pode gerar `answer_rate_tel = 1.0`.

**Mitigação sugerida:** Suavização bayesiana ou Wilson score interval.

### 20.2 Ausência de Horário

O modelo não considera horário de ligação.

### 20.3 CPC Dependente de Configuração

A classificação CPC depende do `campo_aux_id = 2126`. Alterações nessa configuração afetam o modelo sem retroatividade.

### 20.4 Janela Temporal Fixa

O filtro `WHERE Dt_Ligacao >= '2026-01-01'` é hard-coded. Recomenda-se parametrizar.

### 20.5 Pesos por Expertise

Os pesos (70/30 telefone/cliente e sub-pesos 60/20/20) foram definidos por expertise de negócio, não por otimização estatística.

### 20.6 Métricas Informativas Fora do Score

`cpc_rate_tel`, `avg_duracao_conectado_tel`, `answered_30d_tel`, `distinct_campaigns`, `distinct_mailings`, `answered_30d_cli` são calculadas mas **não participam do score**. Estão disponíveis para análise e futuras evoluções.

### 20.7 Recência Duplicada em Clientes com 1 Telefone

Quando o cliente possui apenas 1 telefone, `dias_desde_ultima_tel` = `dias_desde_ultima_cli`, fazendo com que o componente de recência contribua de forma duplicada (14% + 6% = 20% efetivo). Em clientes com múltiplos telefones, os valores podem divergir, capturando efeitos diferentes.

### 20.8 Empate no Ranking de Telefone

`ROW_NUMBER()` atribui posições únicas mesmo em empate. Em casos extremamente raros onde todos os 5 critérios de desempate são idênticos, a posição é determinística mas não interpretável como diferença real de qualidade.

---

## 21. Evoluções Futuras

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
| 11 | KPI de acerto do melhor telefone        | Validação do ranking   | Baixa        |

---

## 22. Changelog

| Data       | Versão | Alteração                                                                          |
| ---------- | ------ | ---------------------------------------------------------------------------------- |
| 2026-03-10 | 3.2    | **Inclusão de `rank_telefone_cliente` e `melhor_telefone_cliente`**                |
| 2026-03-10 | 3.2    | CTE `scores_calculados` extraído do SELECT final para permitir o ranking           |
| 2026-03-10 | 3.2    | Novo CTE `ranking` com `ROW_NUMBER() OVER (PARTITION BY Cliente_id)`               |
| 2026-03-10 | 3.2    | Ranking ordenado exclusivamente por `score_telefone` (não `score_final`)           |
| 2026-03-10 | 3.2    | 5 critérios de desempate em cascata: score_tel → answer_rate → attempts_30d → recência → volume |
| 2026-03-10 | 3.2    | Justificativa formal: score_cliente é constante por cliente, logo ranking por score_final ≡ score_telefone |
| 2026-03-10 | 3.2    | Adicionada Seção 11 (Ranking de Melhor Telefone)                                   |
| 2026-03-10 | 3.2    | Adicionado Exemplo 4 (mesmo cliente, dois telefones — ranking aplicado)            |
| 2026-03-10 | 3.2    | Adicionada limitação 20.8 (empate no ranking)                                      |
| 2026-03-10 | 3.2    | Adicionado KPI de acerto do melhor telefone (seção 18.4)                           |
| 2026-03-10 | 3.2    | Atualizado filtro de data: 2026-02-10 → 2026-01-01                                |
| 2026-03-10 | 3.2    | Arquitetura expandida de 3 para 4 CTEs                                             |
| 2026-02-26 | 3.1    | Inclusão do fator recência no score_cliente                                        |
| 2026-02-26 | 3.1    | Score Cliente: 60% answer_rate + 20% recência + 20% (1-fadiga)                    |
| 2026-02-26 | 3.1    | Faixas de recência_cli idênticas às do telefone (≥60/≥30/≥14/<14)                 |
| 2026-02-26 | 3.1    | Pesos efetivos: answer_rate_cli 21%→18%, fadiga_cli 9%→6%, recência_cli +6%       |
| 2026-02-26 | 3.1    | Arquitetura agora simétrica: ambas as camadas com 60/20/20                         |
| 2026-02-24 | 3.0    | Query reestruturada com CTEs + camada cliente                                      |
| 2026-02-24 | 3.0    | Score: 70% Telefone + 30% Cliente                                                  |
| 2026-02-24 | 3.0    | Score Telefone: 60% answer_rate + 20% recência + 20% (1-fadiga)                   |
| 2026-02-24 | 3.0    | Score Cliente (v3.0): 70% answer_rate_cli + 30% (1-fadiga_cli)                    |
| 2026-02-24 | 3.0    | Adicionada classificação automática A/B/C/D/E na query                             |
| 2026-02-24 | 2.0    | Documentação v2                                                                    |
| 2026-02-24 | 1.0    | Documentação inicial                                                               |

---

> **Resumo da evolução v3.1 → v3.2:**  
> A v3.1 consolidou a arquitetura simétrica de dois níveis. A v3.2 adiciona o **índice de melhor telefone por cliente** via dois novos campos: `rank_telefone_cliente` (posição ordinal) e `melhor_telefone_cliente` (flag binária). O ranking é calculado **exclusivamente por `score_telefone`**, não por `score_final`, pois o `score_cliente` é idêntico para todos os telefones de um mesmo cliente e portanto não discrimina qual número é melhor — apenas o score do telefone carrega informação diferencial dentro do cliente. Isso torna o modelo operacionalmente completo: além de pontuar a probabilidade de contato, ele indica diretamente qual número discar primeiro.
