-- =====================================================================
-- MODELO DE SCORE DE PROBABILIDADE DE CONTATO  v3.1
-- Brasilseg – Inteligência de Contactabilidade
-- =====================================================================
--
-- Arquitetura:
--   Score Telefone (70%) + Score Cliente (30%) = Score Final (0-100)
--
-- Score Telefone: 60% answer_rate + 20% recência + 20% (1-fadiga)
-- Score Cliente:  60% answer_rate + 20% recência + 20% (1-fadiga)
--
-- v3.1: Inclusão do fator recência no score_cliente
-- =====================================================================

WITH metricas_telefone AS (

    SELECT
        l.Cliente_id,
        l.Numero_Telefone,

        -- ============================
        -- CONTAGENS POR TELEFONE
        -- ============================
        COUNT(l.Ligacao_Cod)                                            AS total_attempts_tel,
        SUM(CASE WHEN l.Conectado = 1 THEN 1 ELSE 0 END)              AS total_answered_tel,
        SUM(CASE WHEN l.Conectado = 1
                  AND cpc.tlv_registro_id IS NOT NULL
                 THEN 1 ELSE 0 END)                                    AS total_cpc_tel,

        -- ============================
        -- TAXAS POR TELEFONE (blindadas)
        -- ============================
        ISNULL(
            CAST(SUM(CASE WHEN l.Conectado = 1 THEN 1 ELSE 0 END) AS FLOAT)
            / NULLIF(COUNT(l.Ligacao_Cod), 0),
        0) AS answer_rate_tel,

        ISNULL(
            CAST(
                SUM(CASE WHEN l.Conectado = 1
                          AND cpc.tlv_registro_id IS NOT NULL
                         THEN 1 ELSE 0 END) AS FLOAT
            )
            / NULLIF(SUM(CASE WHEN l.Conectado = 1 THEN 1 ELSE 0 END), 0),
        0) AS cpc_rate_tel,

        -- ============================
        -- DATAS POR TELEFONE
        -- ============================
        MIN(l.Dt_Ligacao)                                               AS primeira_ligacao_tel,
        MAX(l.Dt_Ligacao)                                               AS ultima_ligacao_tel,
        DATEDIFF(DAY, MAX(l.Dt_Ligacao), GETDATE())                     AS dias_desde_ultima_tel,

        -- ============================
        -- JANELA 30D POR TELEFONE
        -- ============================
        SUM(CASE WHEN l.Dt_Ligacao >= DATEADD(DAY, -30, GETDATE())
                 THEN 1 ELSE 0 END)                                    AS attempts_30d_tel,

        SUM(CASE WHEN l.Conectado = 1
                  AND l.Dt_Ligacao >= DATEADD(DAY, -30, GETDATE())
                 THEN 1 ELSE 0 END)                                    AS answered_30d_tel,

        -- ============================
        -- DIVERSIDADE E DURAÇÃO
        -- ============================
        COUNT(DISTINCT l.Campanha_id)                                   AS distinct_campaigns,
        COUNT(DISTINCT l.Mailing_id)                                    AS distinct_mailings,

        ISNULL(
            AVG(CASE WHEN l.Conectado = 1 THEN l.Duracao_Conectado END),
        0) AS avg_duracao_conectado_tel

    FROM ligacao l

    LEFT JOIN configuracao_aux cpc
        ON cpc.tlv_registro_id = l.Tipo_Processo_id
       AND cpc.campo_aux_id = 2126

    WHERE l.Dt_Ligacao >= '2026-02-10'

    GROUP BY
        l.Cliente_id,
        l.Numero_Telefone

),

-- =====================================================================
-- MÉTRICAS GLOBAIS POR CLIENTE (todos os telefones agregados)
-- =====================================================================
metricas_cliente AS (

    SELECT
        Cliente_id,

        SUM(total_attempts_tel)                                         AS total_attempts_cli,
        SUM(total_answered_tel)                                         AS total_answered_cli,
        SUM(total_cpc_tel)                                              AS total_cpc_cli,

        -- answer_rate global do cliente (blindado)
        ISNULL(
            CAST(SUM(total_answered_tel) AS FLOAT)
            / NULLIF(SUM(total_attempts_tel), 0),
        0) AS answer_rate_cli,

        -- Recência global: dias desde a última ligação em QUALQUER telefone
        MIN(dias_desde_ultima_tel)                                      AS dias_desde_ultima_cli,

        -- Fadiga global: total de tentativas 30d em TODOS os telefones
        SUM(attempts_30d_tel)                                           AS attempts_30d_cli,
        SUM(answered_30d_tel)                                           AS answered_30d_cli,

        -- Quantidade de telefones distintos do cliente
        COUNT(*)                                                        AS qtd_telefones_cli

    FROM metricas_telefone
    GROUP BY Cliente_id

)

-- =====================================================================
-- SELECT FINAL: combina telefone + cliente e calcula scores
-- =====================================================================
SELECT
    t.Cliente_id,
    t.Numero_Telefone,

    -- =================================================================
    -- MÉTRICAS BRUTAS — TELEFONE
    -- =================================================================
    t.total_attempts_tel,
    t.total_answered_tel,
    t.total_cpc_tel,
    t.answer_rate_tel,
    t.cpc_rate_tel,

    t.primeira_ligacao_tel,
    t.ultima_ligacao_tel,
    t.dias_desde_ultima_tel,

    t.attempts_30d_tel,
    t.answered_30d_tel,

    t.distinct_campaigns,
    t.distinct_mailings,
    t.avg_duracao_conectado_tel,

    -- =================================================================
    -- MÉTRICAS BRUTAS — CLIENTE (GLOBAL)
    -- =================================================================
    c.total_attempts_cli,
    c.total_answered_cli,
    c.total_cpc_cli,
    c.answer_rate_cli,
    c.dias_desde_ultima_cli,
    c.attempts_30d_cli,
    c.answered_30d_cli,
    c.qtd_telefones_cli,

    -- =================================================================
    -- SCORE TELEFONE (peso 70% no score final)
    -- =================================================================
    --
    -- Composição:
    --   60% → answer_rate_tel (eficiência histórica do número)
    --   20% → recência (dias desde última ligação neste telefone)
    --   20% → (1 - fadiga recente neste telefone)
    --
    (
        -- 60% answer_rate_tel
        (0.60 * t.answer_rate_tel)
        +
        -- 20% recência do telefone
        (0.20 *
            CASE
                WHEN t.dias_desde_ultima_tel >= 60 THEN 1.0
                WHEN t.dias_desde_ultima_tel >= 30 THEN 0.7
                WHEN t.dias_desde_ultima_tel >= 14 THEN 0.5
                ELSE 0.3
            END
        )
        +
        -- 20% (1 - fadiga recente do telefone)
        (0.20 *
            (1.0 -
                CASE
                    WHEN t.attempts_30d_tel >= 6 THEN 1.0
                    WHEN t.attempts_30d_tel >= 4 THEN 0.7
                    WHEN t.attempts_30d_tel >= 2 THEN 0.4
                    ELSE 0.0
                END
            )
        )
    ) AS score_telefone,

    -- =================================================================
    -- SCORE CLIENTE (peso 30% no score final)          ← v3.1 ATUALIZADO
    -- =================================================================
    --
    -- Composição (v3.1):
    --   60% → answer_rate_cli (comportamento estrutural do cliente)
    --   20% → recência global (dias desde última ligação em qualquer tel.)
    --   20% → (1 - fadiga global do cliente em todos os telefones)
    --
    (
        -- 60% answer_rate_cli
        (0.60 * c.answer_rate_cli)
        +
        -- 20% recência global do cliente
        (0.20 *
            CASE
                WHEN c.dias_desde_ultima_cli >= 60 THEN 1.0
                WHEN c.dias_desde_ultima_cli >= 30 THEN 0.7
                WHEN c.dias_desde_ultima_cli >= 14 THEN 0.5
                ELSE 0.3
            END
        )
        +
        -- 20% (1 - fadiga global do cliente)
        (0.20 *
            (1.0 -
                CASE
                    WHEN c.attempts_30d_cli >= 12 THEN 1.0
                    WHEN c.attempts_30d_cli >= 8  THEN 0.7
                    WHEN c.attempts_30d_cli >= 4  THEN 0.4
                    ELSE 0.0
                END
            )
        )
    ) AS score_cliente,

    -- =================================================================
    -- SCORE FINAL (0 a 100)                            ← v3.1 ATUALIZADO
    -- =================================================================
    --
    -- Fórmula:
    --   Score_Final = (0.70 × Score_Telefone + 0.30 × Score_Cliente) × 100
    --
    (
        -- 70% Score Telefone
        0.70 * (
            (0.60 * t.answer_rate_tel)
            +
            (0.20 *
                CASE
                    WHEN t.dias_desde_ultima_tel >= 60 THEN 1.0
                    WHEN t.dias_desde_ultima_tel >= 30 THEN 0.7
                    WHEN t.dias_desde_ultima_tel >= 14 THEN 0.5
                    ELSE 0.3
                END
            )
            +
            (0.20 *
                (1.0 -
                    CASE
                        WHEN t.attempts_30d_tel >= 6 THEN 1.0
                        WHEN t.attempts_30d_tel >= 4 THEN 0.7
                        WHEN t.attempts_30d_tel >= 2 THEN 0.4
                        ELSE 0.0
                    END
                )
            )
        )
        +
        -- 30% Score Cliente (v3.1: agora com recência)
        0.30 * (
            (0.60 * c.answer_rate_cli)
            +
            (0.20 *
                CASE
                    WHEN c.dias_desde_ultima_cli >= 60 THEN 1.0
                    WHEN c.dias_desde_ultima_cli >= 30 THEN 0.7
                    WHEN c.dias_desde_ultima_cli >= 14 THEN 0.5
                    ELSE 0.3
                END
            )
            +
            (0.20 *
                (1.0 -
                    CASE
                        WHEN c.attempts_30d_cli >= 12 THEN 1.0
                        WHEN c.attempts_30d_cli >= 8  THEN 0.7
                        WHEN c.attempts_30d_cli >= 4  THEN 0.4
                        ELSE 0.0
                    END
                )
            )
        )
    ) * 100 AS score_final,

    -- =================================================================
    -- CLASSIFICAÇÃO DO SCORE                           ← v3.1 ATUALIZADO
    -- =================================================================
    CASE
        WHEN (
            0.70 * (
                (0.60 * t.answer_rate_tel)
                + (0.20 * CASE WHEN t.dias_desde_ultima_tel >= 60 THEN 1.0 WHEN t.dias_desde_ultima_tel >= 30 THEN 0.7 WHEN t.dias_desde_ultima_tel >= 14 THEN 0.5 ELSE 0.3 END)
                + (0.20 * (1.0 - CASE WHEN t.attempts_30d_tel >= 6 THEN 1.0 WHEN t.attempts_30d_tel >= 4 THEN 0.7 WHEN t.attempts_30d_tel >= 2 THEN 0.4 ELSE 0.0 END))
            )
            + 0.30 * (
                (0.60 * c.answer_rate_cli)
                + (0.20 * CASE WHEN c.dias_desde_ultima_cli >= 60 THEN 1.0 WHEN c.dias_desde_ultima_cli >= 30 THEN 0.7 WHEN c.dias_desde_ultima_cli >= 14 THEN 0.5 ELSE 0.3 END)
                + (0.20 * (1.0 - CASE WHEN c.attempts_30d_cli >= 12 THEN 1.0 WHEN c.attempts_30d_cli >= 8 THEN 0.7 WHEN c.attempts_30d_cli >= 4 THEN 0.4 ELSE 0.0 END))
            )
        ) * 100 >= 80 THEN 'A - Alta Probabilidade'
        WHEN (
            0.70 * (
                (0.60 * t.answer_rate_tel)
                + (0.20 * CASE WHEN t.dias_desde_ultima_tel >= 60 THEN 1.0 WHEN t.dias_desde_ultima_tel >= 30 THEN 0.7 WHEN t.dias_desde_ultima_tel >= 14 THEN 0.5 ELSE 0.3 END)
                + (0.20 * (1.0 - CASE WHEN t.attempts_30d_tel >= 6 THEN 1.0 WHEN t.attempts_30d_tel >= 4 THEN 0.7 WHEN t.attempts_30d_tel >= 2 THEN 0.4 ELSE 0.0 END))
            )
            + 0.30 * (
                (0.60 * c.answer_rate_cli)
                + (0.20 * CASE WHEN c.dias_desde_ultima_cli >= 60 THEN 1.0 WHEN c.dias_desde_ultima_cli >= 30 THEN 0.7 WHEN c.dias_desde_ultima_cli >= 14 THEN 0.5 ELSE 0.3 END)
                + (0.20 * (1.0 - CASE WHEN c.attempts_30d_cli >= 12 THEN 1.0 WHEN c.attempts_30d_cli >= 8 THEN 0.7 WHEN c.attempts_30d_cli >= 4 THEN 0.4 ELSE 0.0 END))
            )
        ) * 100 >= 60 THEN 'B - Boa Probabilidade'
        WHEN (
            0.70 * (
                (0.60 * t.answer_rate_tel)
                + (0.20 * CASE WHEN t.dias_desde_ultima_tel >= 60 THEN 1.0 WHEN t.dias_desde_ultima_tel >= 30 THEN 0.7 WHEN t.dias_desde_ultima_tel >= 14 THEN 0.5 ELSE 0.3 END)
                + (0.20 * (1.0 - CASE WHEN t.attempts_30d_tel >= 6 THEN 1.0 WHEN t.attempts_30d_tel >= 4 THEN 0.7 WHEN t.attempts_30d_tel >= 2 THEN 0.4 ELSE 0.0 END))
            )
            + 0.30 * (
                (0.60 * c.answer_rate_cli)
                + (0.20 * CASE WHEN c.dias_desde_ultima_cli >= 60 THEN 1.0 WHEN c.dias_desde_ultima_cli >= 30 THEN 0.7 WHEN c.dias_desde_ultima_cli >= 14 THEN 0.5 ELSE 0.3 END)
                + (0.20 * (1.0 - CASE WHEN c.attempts_30d_cli >= 12 THEN 1.0 WHEN c.attempts_30d_cli >= 8 THEN 0.7 WHEN c.attempts_30d_cli >= 4 THEN 0.4 ELSE 0.0 END))
            )
        ) * 100 >= 40 THEN 'C - Moderada'
        WHEN (
            0.70 * (
                (0.60 * t.answer_rate_tel)
                + (0.20 * CASE WHEN t.dias_desde_ultima_tel >= 60 THEN 1.0 WHEN t.dias_desde_ultima_tel >= 30 THEN 0.7 WHEN t.dias_desde_ultima_tel >= 14 THEN 0.5 ELSE 0.3 END)
                + (0.20 * (1.0 - CASE WHEN t.attempts_30d_tel >= 6 THEN 1.0 WHEN t.attempts_30d_tel >= 4 THEN 0.7 WHEN t.attempts_30d_tel >= 2 THEN 0.4 ELSE 0.0 END))
            )
            + 0.30 * (
                (0.60 * c.answer_rate_cli)
                + (0.20 * CASE WHEN c.dias_desde_ultima_cli >= 60 THEN 1.0 WHEN c.dias_desde_ultima_cli >= 30 THEN 0.7 WHEN c.dias_desde_ultima_cli >= 14 THEN 0.5 ELSE 0.3 END)
                + (0.20 * (1.0 - CASE WHEN c.attempts_30d_cli >= 12 THEN 1.0 WHEN c.attempts_30d_cli >= 8 THEN 0.7 WHEN c.attempts_30d_cli >= 4 THEN 0.4 ELSE 0.0 END))
            )
        ) * 100 >= 20 THEN 'D - Baixa'
        ELSE 'E - Muito Baixa'
    END AS classificacao_score

FROM metricas_telefone t
INNER JOIN metricas_cliente c
    ON t.Cliente_id = c.Cliente_id

ORDER BY score_final DESC;
