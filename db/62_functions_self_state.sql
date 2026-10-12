-- Self-state mirrors (#43/#45/#46): read paths exposing the agent's own
-- introspective ledgers — the belief-revision audit, its configuration, and
-- the ground-truth action log — as agent-facing tools. The pattern these fix:
-- mechanism built, mirror forgotten. No new machinery here, only reads.
SET search_path = public, ag_catalog, "$user";

INSERT INTO config_defaults (key, value, description) VALUES
    ('inspection.config_prefixes',
     '["agent.", "heartbeat.", "maintenance.", "memory.", "retention.", "extraction.", "origin_memories.", "belief.", "guardrails.", "inspection.", "mcp.", "recmem.", "llm."]'::jsonb,
     'Config key prefixes the agent may read via inspect_config (values with secret-like names are redacted regardless)')
ON CONFLICT (key) DO NOTHING;

-- Why do I believe this? One call returns the belief's current state, its
-- truth profile, the audited revision history, incident evidence edges, and
-- contradicting sources (#43 — completes the self-explanation bar of #40).
CREATE OR REPLACE FUNCTION get_belief_history(
    p_memory_id UUID,
    p_limit INT DEFAULT 20,
    p_exclude_sensitive BOOLEAN DEFAULT FALSE
) RETURNS JSONB AS $$
DECLARE
    mem memories%ROWTYPE;
    lim INT := LEAST(GREATEST(COALESCE(p_limit, 20), 1), 100);
    revisions JSONB;
    evidence JSONB;
BEGIN
    SELECT * INTO mem FROM memories WHERE id = p_memory_id;
    IF NOT FOUND THEN
        RETURN jsonb_build_object('error', 'not_found');
    END IF;
    IF COALESCE(p_exclude_sensitive, FALSE)
       AND COALESCE(mem.source_attribution->>'sensitivity', '') = 'private' THEN
        RETURN jsonb_build_object('error', 'not_found');
    END IF;

    SELECT COALESCE(jsonb_agg(jsonb_build_object(
               'stance', a.stance,
               'prior', a.prior_confidence,
               'posterior', a.posterior_confidence,
               'applied', a.applied,
               'reason', a.reason,
               'evidence_kind', a.evidence->>'kind',
               'evidence_ref', a.evidence->>'ref',
               'policy_context', a.policy_context,
               'at', a.created_at
           ) ORDER BY a.created_at DESC), '[]'::jsonb)
    INTO revisions
    FROM (
        SELECT * FROM belief_revision_audit
        WHERE memory_id = p_memory_id
        ORDER BY created_at DESC
        LIMIT lim
    ) a;

    SELECT COALESCE(jsonb_agg(jsonb_build_object(
               'evidence_memory_id', e.src_id,
               'relation', e.rel_type,
               'weight', e.weight,
               'excerpt', left(m.content, 200)
           )), '[]'::jsonb)
    INTO evidence
    FROM memory_edges e
    LEFT JOIN memories m ON m.id::text = e.src_id
    WHERE e.dst_type = 'memory'
      AND e.dst_id = p_memory_id::text
      AND e.rel_type IN ('SUPPORTS', 'CONTRADICTS');

    RETURN jsonb_strip_nulls(jsonb_build_object(
        'memory', jsonb_build_object(
            'id', mem.id::text,
            'type', mem.type::text,
            'content', mem.content,
            'confidence', NULLIF(mem.metadata->>'confidence', '')::float,
            'trust_level', mem.trust_level,
            'protected', COALESCE((mem.metadata->>'protected')::boolean, FALSE)
        ),
        'note', CASE WHEN mem.type <> 'semantic'
                     THEN 'Not a semantic belief: only semantic memories carry revisable confidence; history below may be empty.'
                     END,
        'profile', CASE WHEN mem.type = 'semantic'
                        THEN get_memory_truth_profile(p_memory_id) END,
        'revisions', revisions,
        'evidence', evidence,
        'contradicting_sources', COALESCE(mem.metadata->'contradicting_sources', '[]'::jsonb)
    ));
END;
$$ LANGUAGE plpgsql STABLE;

-- The agent's own settings (#45). Defense in depth: a data-driven prefix
-- allowlist (inspection.config_prefixes), hard exclusions for the keys that
-- hold or can hold literal secrets ('tools', oauth.*, token.*) regardless of
-- allowlist, and name-based value redaction. NOTE: this redaction set is
-- deliberately broader than config-import's sensitive-key filter, which
-- misses 'oauth'.
CREATE OR REPLACE FUNCTION inspect_agent_config(
    p_prefix TEXT DEFAULT NULL
) RETURNS JSONB AS $$
DECLARE
    allowed TEXT[];
    result JSONB;
BEGIN
    SELECT COALESCE(array_agg(value), ARRAY[]::TEXT[])
    INTO allowed
    FROM jsonb_array_elements_text(
        COALESCE(get_config('inspection.config_prefixes'), '[]'::jsonb)
    ) AS t(value);

    SELECT COALESCE(jsonb_object_agg(c.key,
               CASE WHEN lower(c.key) ~ '(password|secret|token|api_key|credential|key_env)'
                    THEN '"[redacted]"'::jsonb
                    ELSE c.value
               END ORDER BY c.key), '{}'::jsonb)
    INTO result
    FROM config c
    WHERE c.key LIKE ANY (SELECT p || '%' FROM unnest(allowed) AS p)
      AND (p_prefix IS NULL OR c.key LIKE p_prefix || '%')
      -- Hard exclusions: these hold (or may hold) literal secret values.
      AND c.key <> 'tools'
      AND c.key NOT LIKE 'oauth.%'
      AND c.key NOT LIKE 'token.%';

    RETURN result;
END;
$$ LANGUAGE plpgsql STABLE;

-- The verbatim action log (#46): what the agent actually did, failures
-- included — the ground truth its selective memories summarize. Metadata
-- only; the stored output blobs (up to ~10KB each) never leave the table.
-- Known v1 limitation: approval-denied calls bypass the audit hook (they
-- never reach registry.execute) and appear only in agent_turns runtime state.
CREATE OR REPLACE FUNCTION get_recent_actions(
    p_hours INT DEFAULT 24,
    p_limit INT DEFAULT 30,
    p_context TEXT DEFAULT NULL
) RETURNS JSONB AS $$
DECLARE
    hours INT := LEAST(GREATEST(COALESCE(p_hours, 24), 1), 168);
    lim INT := LEAST(GREATEST(COALESCE(p_limit, 30), 1), 100);
    actions JSONB;
    summary JSONB;
BEGIN
    SELECT COALESCE(jsonb_agg(jsonb_build_object(
               'tool', t.tool_name,
               'context', t.tool_context,
               'success', t.success,
               'error', t.error,
               'error_type', t.error_type,
               'energy_spent', t.energy_spent,
               'duration_seconds', round(COALESCE(t.duration_seconds, 0)::numeric, 2),
               'at', t.created_at
           ) ORDER BY t.created_at DESC), '[]'::jsonb)
    INTO actions
    FROM (
        SELECT * FROM tool_executions
        WHERE created_at >= CURRENT_TIMESTAMP - make_interval(hours => hours)
          AND (p_context IS NULL OR tool_context = p_context)
        ORDER BY created_at DESC
        LIMIT lim
    ) t;

    SELECT jsonb_build_object(
               'total', count(*),
               'failures', count(*) FILTER (WHERE NOT success),
               'energy_total', COALESCE(sum(energy_spent), 0),
               'window_hours', hours,
               'truncated_to', lim
           )
    INTO summary
    FROM tool_executions
    WHERE created_at >= CURRENT_TIMESTAMP - make_interval(hours => hours)
      AND (p_context IS NULL OR tool_context = p_context);

    RETURN jsonb_build_object('actions', actions, 'summary', summary);
END;
$$ LANGUAGE plpgsql STABLE;

-- Temporal self-grounding (#55): the conscious mind always knows what time it
-- is and how old it is — computable ground truth, derived from the birth
-- (initialization) memory, never guessed and never dependent on being told.
CREATE OR REPLACE FUNCTION get_temporal_context()
RETURNS JSONB AS $$
DECLARE
    tz TEXT := COALESCE(NULLIF(get_config_text('agent.timezone'), ''), 'UTC');
    now_local TIMESTAMP;
    born TIMESTAMPTZ;
BEGIN
    BEGIN
        now_local := CURRENT_TIMESTAMP AT TIME ZONE tz;
    EXCEPTION WHEN OTHERS THEN
        tz := 'UTC';
        now_local := CURRENT_TIMESTAMP AT TIME ZONE 'UTC';
    END;

    SELECT min(created_at) INTO born
    FROM memories
    WHERE type = 'episodic' AND metadata->>'type' = 'initialization';
    IF born IS NULL THEN
        SELECT min(created_at) INTO born FROM memories;
    END IF;

    RETURN jsonb_strip_nulls(jsonb_build_object(
        'now', to_char(now_local, 'FMDay, FMMonth DD, YYYY, HH24:MI'),
        'timezone', tz,
        'born_on', CASE WHEN born IS NOT NULL
                        THEN to_char(born AT TIME ZONE tz, 'FMMonth DD, YYYY') END,
        -- Calendar day-of-life (#72): "day 7" reconciles with date arithmetic
        -- at a glance; floored elapsed days ("5 day(s) ago" on the 7th
        -- calendar day) read as a contradiction the agent then distrusts.
        'day_of_life', CASE WHEN born IS NOT NULL
                            THEN ((now_local::date - (born AT TIME ZONE tz)::date) + 1) END,
        'age_days', CASE WHEN born IS NOT NULL
                         THEN GREATEST(0, EXTRACT(EPOCH FROM (CURRENT_TIMESTAMP - born))::bigint / 86400) END
    ));
END;
$$ LANGUAGE plpgsql STABLE;

-- The full story behind one memory (#76): the gist you recalled, the verbatim
-- experience underneath it. Graded recall's drill-down — recall gives shape,
-- open_memory gives the exact words. Mirrors get_belief_history's assembly.
CREATE OR REPLACE FUNCTION get_memory_story(
    p_memory_id UUID,
    p_max_units INT DEFAULT 40,
    p_exclude_sensitive BOOLEAN DEFAULT FALSE
) RETURNS JSONB AS $$
DECLARE
    mem RECORD;
    units JSONB;
    gisted_members JSONB;
    documents JSONB;
    chunks JSONB;
BEGIN
    SELECT id, type, content, importance, trust_level, fidelity, status,
           created_at, superseded_by, source_attribution, metadata
    INTO mem
    FROM memories WHERE id = p_memory_id;

    IF NOT FOUND THEN
        RETURN jsonb_build_object('error', 'not_found');
    END IF;
    IF COALESCE(p_exclude_sensitive, FALSE)
       AND COALESCE(mem.source_attribution->>'sensitivity', '') = 'private' THEN
        RETURN jsonb_build_object('error', 'not_found');
    END IF;

    SELECT COALESCE(jsonb_agg(jsonb_build_object(
        'unit_id', u.id,
        'role', u.role,
        'turn_at', u.turn_at,
        'content', u.content
    ) ORDER BY u.turn_at, u.created_at), '[]'::jsonb)
    INTO units
    FROM (
        SELECT s.id, msu.role, s.turn_at, s.created_at, s.content
        FROM memory_source_units msu
        JOIN subconscious_units s ON s.id = msu.subconscious_unit_id
        WHERE msu.memory_id = p_memory_id
          AND s.status = 'active'
        ORDER BY s.turn_at, s.created_at
        LIMIT GREATEST(COALESCE(p_max_units, 40), 1)
    ) u;

    -- A retention gist supersedes its members: opening the gist also opens
    -- the archived originals (still present through the grace window).
    SELECT COALESCE(jsonb_agg(jsonb_build_object(
        'memory_id', g.id,
        'content', g.content,
        'created_at', g.created_at
    ) ORDER BY g.created_at), '[]'::jsonb)
    INTO gisted_members
    FROM memories g
    WHERE g.superseded_by = p_memory_id;

    SELECT COALESCE(jsonb_agg(jsonb_build_object(
        'document_id', d.id,
        'title', d.title,
        'source_type', d.source_type,
        'path', d.path,
        'file_type', d.file_type,
        'content_hash', d.content_hash,
        'word_count', d.word_count,
        'size_bytes', d.size_bytes,
        'updated_at', d.updated_at
    ) ORDER BY d.updated_at DESC, d.id), '[]'::jsonb)
    INTO documents
    FROM source_documents d
    WHERE d.status = 'active'
      AND (
          d.id::text = NULLIF(mem.source_attribution->>'source_document_id', '')
          OR d.id::text = NULLIF(mem.source_attribution->>'document_id', '')
          OR
          d.content_hash = NULLIF(mem.source_attribution->>'content_hash', '')
          OR d.content_hash = NULLIF(mem.source_attribution->>'ref', '')
          OR EXISTS (
              SELECT 1
              FROM jsonb_array_elements(CASE
                  WHEN jsonb_typeof(mem.metadata->'source_references') = 'array'
                  THEN mem.metadata->'source_references'
                  ELSE '[]'::jsonb
              END) src
              WHERE d.id::text = NULLIF(src->>'source_document_id', '')
                 OR d.id::text = NULLIF(src->>'document_id', '')
                 OR d.content_hash = NULLIF(src->>'content_hash', '')
                 OR d.content_hash = NULLIF(src->>'ref', '')
          )
      );

    -- Chunk-grain provenance: the exact passage a memory was extracted from,
    -- with its locator (page/section/sheet row) for citation.
    SELECT COALESCE(jsonb_agg(jsonb_build_object(
        'chunk_id', c.id,
        'document_id', c.source_document_id,
        'chunk_index', c.chunk_index,
        'locator_kind', c.locator_kind,
        'locator', c.locator,
        'heading_path', to_jsonb(c.heading_path),
        'page_start', c.page_start,
        'page_end', c.page_end,
        'sheet_name', c.sheet_name
    ) ORDER BY c.chunk_index), '[]'::jsonb)
    INTO chunks
    FROM source_document_chunks c
    JOIN source_documents cd ON cd.id = c.source_document_id AND cd.status = 'active'
    WHERE c.id::text = NULLIF(mem.source_attribution->>'chunk_id', '')
       OR EXISTS (
           SELECT 1
           FROM jsonb_array_elements(CASE
               WHEN jsonb_typeof(mem.metadata->'source_references') = 'array'
               THEN mem.metadata->'source_references'
               ELSE '[]'::jsonb
           END) src
           WHERE c.id::text = NULLIF(src->>'chunk_id', '')
       );

    RETURN jsonb_strip_nulls(jsonb_build_object(
        'memory', jsonb_build_object(
            'id', mem.id,
            'type', mem.type,
            'content', mem.content,
            'importance', mem.importance,
            'confidence', NULLIF(mem.metadata->>'confidence', '')::float,
            'trust_level', mem.trust_level,
            'fidelity', mem.fidelity,
            'status', mem.status,
            'created_at', mem.created_at,
            'occurred_from', mem.metadata#>>'{recmem,occurred_from}',
            'occurred_to', mem.metadata#>>'{recmem,occurred_to}',
            'session_id', mem.metadata#>>'{recmem,session_id}'
        ),
        'full_content', NULLIF(mem.metadata#>>'{consolidation,full_content}', ''),
        'source_units', units,
        'source_documents', CASE WHEN documents = '[]'::jsonb THEN NULL ELSE documents END,
        'source_chunks', CASE WHEN chunks = '[]'::jsonb THEN NULL ELSE chunks END,
        'superseded_members', CASE WHEN gisted_members = '[]'::jsonb THEN NULL ELSE gisted_members END,
        'superseded_by', mem.superseded_by,
        'evidence', jsonb_build_object(
            'revisions', (SELECT count(*) FROM belief_revision_audit b WHERE b.memory_id = p_memory_id),
            'supports', (SELECT count(*) FROM memory_edges e
                         WHERE e.dst_type = 'memory' AND e.dst_id = p_memory_id::text AND e.rel_type = 'SUPPORTS'),
            'contradicts', (SELECT count(*) FROM memory_edges e
                            WHERE e.dst_type = 'memory' AND e.dst_id = p_memory_id::text AND e.rel_type = 'CONTRADICTS')
        )
    ));
END;
$$ LANGUAGE plpgsql STABLE;
