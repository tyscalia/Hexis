-- 0254: #92 wall parity for the two recall drill-downs (JJ1).
-- open_memory / belief_history gain the same group-context privacy wall the
-- four sibling recall verbs already enforce: when exclude_sensitive is set
-- (the Python handlers set it on context.is_group), a private memory's
-- drill-down refuses with not_found instead of leaking verbatim source turns
-- and revision content into a shared room.
--
-- Option B (param thread): the leaf functions gain p_exclude_sensitive and
-- enforce it at target grain; the dispatcher re-declaration passes the flag
-- through from p_args. The old 2-arg overloads are dropped first so the
-- dispatcher's calls resolve to the gated forms.
SET search_path = public, ag_catalog, "$user";

-- Old 2-arg forms must go first, or the dispatcher's calls keep resolving
-- to the ungated overload.
DROP FUNCTION IF EXISTS get_belief_history(UUID, INT);
DROP FUNCTION IF EXISTS get_memory_story(UUID, INT);

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
      AND e.rel_type IN ('SUPPORTS', 'CONTRADICTS')
      AND (NOT COALESCE(p_exclude_sensitive, FALSE)
           OR m.id IS NULL
           OR COALESCE(m.source_attribution->>'sensitivity', '') <> 'private');

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
          AND (NOT COALESCE(p_exclude_sensitive, FALSE)
               OR COALESCE(s.source_attribution->>'sensitivity', '') <> 'private')
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
    WHERE g.superseded_by = p_memory_id
      AND (NOT COALESCE(p_exclude_sensitive, FALSE)
           OR COALESCE(g.source_attribution->>'sensitivity', '') <> 'private');

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

CREATE OR REPLACE FUNCTION _execute_memory_tool_dispatch_legacy_temporal(
    p_tool_name TEXT,
    p_args JSONB
) RETURNS JSONB
LANGUAGE plpgsql
AS $$
DECLARE
    content TEXT;
    memory_type_value TEXT;
    importance_value FLOAT;
    memory_id UUID;
    query TEXT;
    limit_value INT;
    rows_json JSONB;
    type_filter memory_type[];
    has_filters BOOLEAN;
    use_hybrid BOOLEAN;
    target_id UUID;
    stance_value TEXT;
    revision JSONB;
    display TEXT;
    min_score_value FLOAT := 0.0;
    exclude_sensitive BOOLEAN := FALSE;
    sense_json JSONB;
    partials_json JSONB;
    metamemory_json JSONB;
    incubated BOOLEAN := FALSE;
    after_ts TIMESTAMPTZ;
    before_ts TIMESTAMPTZ;
    history_sources TEXT[];
    history_browse BOOLEAN;
    oldest_ts TIMESTAMPTZ;
    type_filter_uuids UUID[];
    candidates_json JSONB;
    candidate_lines TEXT;
BEGIN
    IF p_tool_name = 'remember' THEN
        content := NULLIF(btrim(COALESCE(p_args->>'content', '')), '');
        IF content IS NULL THEN
            RETURN tool_error('content is required', 'invalid_params');
        END IF;
        memory_type_value := COALESCE(NULLIF(p_args->>'type', ''), 'episodic');
        IF memory_type_value NOT IN ('episodic', 'semantic', 'procedural', 'strategic') THEN
            RETURN tool_error(format('Invalid memory type: %s', memory_type_value), 'invalid_params');
        END IF;
        importance_value := LEAST(1.0, GREATEST(0.0, COALESCE(NULLIF(p_args->>'importance', '')::float, 0.5)));
        -- Semantic memories carry confidence + full source provenance (#33);
        -- other types accept the first source as their attribution.
        IF memory_type_value = 'semantic' THEN
            memory_id := create_semantic_memory(
                content,
                LEAST(1.0, GREATEST(0.0, COALESCE(NULLIF(p_args->>'confidence', '')::float, 0.5))),
                NULL,
                NULL,
                CASE WHEN jsonb_typeof(p_args->'sources') = 'array' THEN p_args->'sources' ELSE NULL END,
                importance_value
            );
        ELSE
            memory_id := create_memory(
                memory_type_value::memory_type,
                content,
                importance_value,
                CASE WHEN jsonb_typeof(p_args->'sources') = 'array' THEN p_args->'sources'->0 ELSE NULL END
            );
        END IF;
        IF jsonb_typeof(COALESCE(p_args->'concepts', '[]'::jsonb)) = 'array' THEN
            PERFORM link_memory_to_concept(memory_id, value)
            FROM jsonb_array_elements_text(p_args->'concepts') c(value);
        END IF;
        RETURN tool_success(jsonb_strip_nulls(jsonb_build_object(
            'memory_id', memory_id::text,
            'type', memory_type_value,
            'content', left(content, 100),
            'confidence', (SELECT NULLIF(m.metadata->>'confidence', '')::float FROM memories m WHERE m.id = memory_id),
            'trust_level', (SELECT m.trust_level FROM memories m WHERE m.id = memory_id)
        )), format('Stored %s memory: %s...', memory_type_value, left(content, 50)));
    ELSIF p_tool_name = 'add_evidence' THEN
        target_id := _db_brain_try_uuid(p_args->>'memory_id');
        IF target_id IS NULL THEN
            RETURN tool_error('memory_id must be a valid uuid', 'invalid_params');
        END IF;
        stance_value := lower(COALESCE(p_args->>'stance', ''));
        IF stance_value NOT IN ('supports', 'contradicts') THEN
            RETURN tool_error('stance must be supports or contradicts', 'invalid_params');
        END IF;
        IF jsonb_typeof(p_args->'source') <> 'object'
           OR COALESCE(NULLIF(p_args->'source'->>'ref', ''), NULLIF(p_args->'source'->>'label', '')) IS NULL THEN
            RETURN tool_error('source must be an object with at least a ref or label', 'invalid_params');
        END IF;
        revision := add_memory_evidence(target_id, stance_value, p_args->'source', NULLIF(p_args->>'note', ''), NULL, 'add_evidence');
        IF revision->>'reason' = 'not_found' THEN
            RETURN tool_error(format('memory not found: %s', target_id), 'invalid_params');
        ELSIF revision->>'reason' = 'not_semantic' THEN
            -- #101: don't leave the caller at a dead end -- surface concrete
            -- semantic candidates to retry against (graph-linked first, else
            -- nearest by embedding) instead of only pointing at recall.
            SELECT jsonb_agg(jsonb_build_object(
                       'memory_id', c.memory_id::text,
                       'content', left(c.content, 150),
                       'confidence', c.confidence,
                       'trust_level', c.trust_level,
                       'match_reason', c.match_reason
                   )),
                   string_agg(
                       format('- %s: "%s" (confidence %s, %s match)',
                              c.memory_id, left(c.content, 100),
                              COALESCE(round(c.confidence::numeric, 2)::text, 'n/a'),
                              c.match_reason),
                       E'\n' ORDER BY c.match_reason, c.memory_id
                   )
            INTO candidates_json, candidate_lines
            FROM find_semantic_evidence_targets(target_id, 5) c;

            RETURN jsonb_build_object(
                'success', false,
                'error', CASE
                    WHEN candidates_json IS NOT NULL THEN
                        format(
                            'add_evidence targets semantic memories; this memory is another type. '
                            || 'Found %s related semantic belief(s) -- call add_evidence again with '
                            || 'one of these memory_id values instead:%s%s',
                            jsonb_array_length(candidates_json), E'\n', candidate_lines
                        )
                    ELSE
                        'add_evidence targets semantic memories; this memory is another type, and no '
                        || 'linked or similar semantic belief was found. Episodic records are the '
                        || 'immutable audit trail -- recall with memory_types=[''semantic''] to find '
                        || 'the revisable belief that was built on this episode, and attach the '
                        || 'evidence there.'
                END,
                'error_type', 'invalid_params',
                'candidates', COALESCE(candidates_json, '[]'::jsonb)
            );
        END IF;
        display := CASE
            WHEN COALESCE((revision->>'applied')::boolean, FALSE) THEN
                format('Belief confidence %s -> %s (%s; independent source)',
                       round((revision->>'prior')::numeric, 2),
                       round((revision->>'posterior')::numeric, 2),
                       stance_value)
            WHEN revision->>'reason' = 'duplicate_source' THEN
                'No change: this source is already part of the belief''s evidence'
            WHEN revision->>'reason' = 'protected' THEN
                'Recorded as a contradiction flag: this belief is protected and is questioned, not rewritten'
            ELSE
                format('No confidence change (%s); evidence recorded', revision->>'reason')
        END;
        RETURN tool_success(revision, display);
    ELSIF p_tool_name = 'sense_memory_availability' THEN
        query := NULLIF(btrim(COALESCE(p_args->>'query', '')), '');
        IF query IS NULL THEN
            RETURN tool_error('query is required', 'invalid_params');
        END IF;
        SELECT to_jsonb(s) INTO rows_json FROM sense_memory_availability(query) s;
        RETURN tool_success(COALESCE(rows_json, '{"feeling": "nothing", "estimated_count": 0, "strongest_match": 0.0}'::jsonb), format('Memory availability: %s', COALESCE(rows_json->>'feeling', 'nothing')));
    ELSIF p_tool_name = 'recall' THEN
        query := NULLIF(p_args->>'query', '');
        -- Count is a context/cost budget, not a knowledge limit (#42/WS6):
        -- default and ceiling are config-driven; min_score cuts the tail by
        -- relevance instead of position.
        limit_value := LEAST(
            GREATEST(COALESCE(
                NULLIF(p_args->>'limit', '')::int,
                get_config_int('memory.recall_default_limit'),
                5
            ), 1),
            COALESCE(get_config_int('memory.recall_max_limit'), 50)
        );
        min_score_value := GREATEST(0.0, COALESCE(
            NULLIF(p_args->>'min_score', '')::float,
            get_config_float('memory.recall_min_score'),
            0.0));
        -- Sensitivity enforcement (#92/#96 stopgap): group-context turns set
        -- exclude_sensitive; private memories stay out of shared rooms
        -- through the tool path exactly as they do through hydrate.
        exclude_sensitive := COALESCE(NULLIF(p_args->>'exclude_sensitive', '')::boolean, FALSE);
        IF jsonb_typeof(p_args->'memory_types') = 'array' AND jsonb_array_length(p_args->'memory_types') > 0 THEN
            SELECT ARRAY(SELECT value::memory_type FROM jsonb_array_elements_text(p_args->'memory_types') t(value)) INTO type_filter;
        END IF;
        has_filters := type_filter IS NOT NULL
            OR NULLIF(p_args->>'source_path', '') IS NOT NULL
            OR NULLIF(p_args->>'source_kind', '') IS NOT NULL
            OR NULLIF(p_args->>'created_after', '') IS NOT NULL
            OR NULLIF(p_args->>'created_before', '') IS NOT NULL
            OR NULLIF(p_args->>'concept', '') IS NOT NULL;
        IF query IS NULL AND NOT has_filters THEN
            RETURN tool_error('Provide at least a query or one filter (memory_types, source_path, source_kind, created_after, created_before, concept).', 'invalid_params');
        END IF;
        -- Plain-query recalls use the hybrid retriever (vector + lexical);
        -- any filter or importance floor routes to the structured query.
        use_hybrid := query IS NOT NULL AND NOT has_filters
            AND COALESCE(NULLIF(p_args->>'min_importance', '')::float, 0.0) <= 0.0;
        IF use_hybrid THEN
            SELECT COALESCE(jsonb_agg(jsonb_strip_nulls(jsonb_build_object(
                'memory_id', r.memory_id::text,
                'content', r.content,
                'type', r.memory_type::text,
                'score', COALESCE(r.score, 0.0),
                'importance', COALESCE(r.importance, 0.0),
                'retrieval_source', NULLIF(r.source, ''),
                'trust', COALESCE(r.trust_level, 0.0),
                'confidence', (SELECT NULLIF(m.metadata->>'confidence', '')::float FROM memories m WHERE m.id = r.memory_id),
                'source_kind', NULLIF(r.source_attribution->>'kind', ''),
                'source_label', NULLIF(r.source_attribution->>'label', ''),
                'source_path', NULLIF(r.source_attribution->>'path', ''),
                'source_ref', NULLIF(r.source_attribution->>'ref', '')
            ))), '[]'::jsonb)
            INTO rows_json
            FROM recall_hybrid(query, limit_value) r
            WHERE COALESCE(r.score, 0.0) >= min_score_value
              AND (NOT exclude_sensitive
                   OR COALESCE(r.source_attribution->>'sensitivity', '') <> 'private');
        ELSE
            SELECT COALESCE(jsonb_agg(jsonb_strip_nulls(jsonb_build_object(
                'memory_id', r.memory_id::text,
                'content', r.content,
                'type', r.memory_type::text,
                'score', COALESCE(r.score, 0.0),
                'importance', COALESCE(r.importance, 0.0),
                'trust', COALESCE(r.trust_level, 0.0),
                'confidence', (SELECT NULLIF(m.metadata->>'confidence', '')::float FROM memories m WHERE m.id = r.memory_id),
                'source_kind', NULLIF(r.source_attribution->>'kind', ''),
                'source_label', NULLIF(r.source_attribution->>'label', ''),
                'source_path', NULLIF(r.source_attribution->>'path', ''),
                'source_ref', NULLIF(r.source_attribution->>'ref', '')
            ))), '[]'::jsonb)
            INTO rows_json
            FROM recall_memories_structured(
                query,
                limit_value,
                type_filter,
                COALESCE(NULLIF(p_args->>'min_importance', '')::float, 0.0),
                -- Empty strings are absent filters, not filters that match
                -- nothing: models routinely fill optional params with "".
                NULLIF(p_args->>'source_path', ''),
                NULLIF(p_args->>'source_kind', ''),
                NULLIF(p_args->>'created_after', '')::timestamptz,
                NULLIF(p_args->>'created_before', '')::timestamptz,
                NULLIF(p_args->>'concept', ''),
                NULL
            ) r
            WHERE COALESCE(r.score, 0.0) >= min_score_value
              AND (NOT exclude_sensitive
                   OR COALESCE(r.source_attribution->>'sensitivity', '') <> 'private');
        END IF;
        PERFORM touch_memories(ARRAY(SELECT (value->>'memory_id')::uuid FROM jsonb_array_elements(rows_json) value));

        -- Metamemory (#96, the ice-cream test): a thin or empty recall is
        -- itself information. Report the felt state — familiar-but-blocked
        -- (tip of the tongue) vs unfamiliar (perhaps never known) — and let
        -- a blocked-but-familiar query incubate in the background: the
        -- subconscious keeps searching, and a resolution surfaces later as
        -- spontaneous recall.
        IF query IS NOT NULL AND jsonb_array_length(rows_json) < LEAST(3, limit_value) THEN
            SELECT to_jsonb(s) INTO sense_json FROM sense_memory_availability(query) s;
            SELECT COALESCE(jsonb_agg(jsonb_build_object(
                       'topic', fp.cluster_name,
                       'closeness', round(fp.cluster_similarity::numeric, 3))), '[]'::jsonb)
            INTO partials_json
            FROM find_partial_activations(query) fp;
            IF jsonb_array_length(rows_json) = 0
               AND COALESCE((sense_json->>'strongest_match')::float, 0.0)
                   >= COALESCE(get_config_float('metamemory.incubate_min_familiarity'), 0.55) THEN
                PERFORM request_background_search(query);
                incubated := TRUE;
            END IF;
            metamemory_json := jsonb_build_object(
                'feeling', COALESCE(sense_json->>'feeling', 'nothing'),
                'familiarity', COALESCE((sense_json->>'strongest_match')::float, 0.0),
                'description', sense_json->>'description',
                'tip_of_tongue', partials_json,
                'incubating', incubated);
            RETURN tool_success(
                jsonb_build_object('memories', rows_json,
                                   'count', jsonb_array_length(rows_json),
                                   'query', COALESCE(query, '(filters only)'),
                                   'metamemory', metamemory_json),
                CASE
                    WHEN incubated THEN
                        format('Nothing surfaced for %L yet, but it feels familiar — I''ll let it simmer; it may come to me later.', query)
                    WHEN jsonb_array_length(rows_json) = 0
                         AND COALESCE(sense_json->>'feeling', 'nothing') IN ('nothing', 'vague') THEN
                        format('Nothing for %L — and it doesn''t feel like something I ever knew.', query)
                    ELSE
                        format('Found %s memories for %L', jsonb_array_length(rows_json), query)
                END);
        END IF;

        RETURN tool_success(jsonb_build_object('memories', rows_json, 'count', jsonb_array_length(rows_json), 'query', COALESCE(query, '(filters only)')), format('Found %s memories for %L', jsonb_array_length(rows_json), COALESCE(query, '(filters only)')));
    ELSIF p_tool_name = 'belief_history' THEN
        target_id := _db_brain_try_uuid(p_args->>'memory_id');
        IF target_id IS NULL THEN
            RETURN tool_error('memory_id must be a valid uuid', 'invalid_params');
        END IF;
        revision := get_belief_history(target_id, COALESCE(NULLIF(p_args->>'limit', '')::int, 20), COALESCE(NULLIF(p_args->>'exclude_sensitive', '')::boolean, FALSE));
        IF revision->>'error' = 'not_found' THEN
            RETURN tool_error(format('memory not found: %s', target_id), 'invalid_params');
        END IF;
        display := format('Belief at confidence %s after %s revision(s); %s evidence link(s)',
            COALESCE(revision#>>'{memory,confidence}', 'n/a'),
            jsonb_array_length(COALESCE(revision->'revisions', '[]'::jsonb)),
            jsonb_array_length(COALESCE(revision->'evidence', '[]'::jsonb)));
        RETURN tool_success(revision, display);
    ELSIF p_tool_name = 'open_memory' THEN
        -- Graded recall's drill-down (#76): the verbatim experience behind a
        -- gist — source units time-ordered, pre-summary full text, members a
        -- retention gist superseded.
        target_id := _db_brain_try_uuid(p_args->>'memory_id');
        IF target_id IS NULL THEN
            RETURN tool_error('memory_id must be a valid uuid', 'invalid_params');
        END IF;
        revision := get_memory_story(target_id, COALESCE(NULLIF(p_args->>'max_units', '')::int, 40), COALESCE(NULLIF(p_args->>'exclude_sensitive', '')::boolean, FALSE));
        IF revision->>'error' = 'not_found' THEN
            RETURN tool_error(format('memory not found: %s', target_id), 'invalid_params');
        END IF;
        display := format('Opened memory: %s source unit(s)%s%s',
            jsonb_array_length(COALESCE(revision->'source_units', '[]'::jsonb)),
            CASE WHEN revision ? 'full_content' THEN ', pre-gist full text preserved' ELSE '' END,
            CASE WHEN revision ? 'superseded_members'
                 THEN format(', %s gisted member(s)', jsonb_array_length(revision->'superseded_members'))
                 ELSE '' END);
        RETURN tool_success(revision, display);
    ELSIF p_tool_name = 'search_history' THEN
        -- Cross-session lexical/timeline search: validation, browse-vs-keyword
        -- limit policy, and the loud-truncation paging hint all live here.
        query := trim(COALESCE(p_args->>'query', ''));
        BEGIN
            after_ts := NULLIF(p_args->>'created_after', '')::timestamptz;
            before_ts := NULLIF(p_args->>'created_before', '')::timestamptz;
        EXCEPTION WHEN OTHERS THEN
            RETURN tool_error('created_after/created_before must be ISO-8601 timestamps', 'invalid_params');
        END;
        IF after_ts IS NOT NULL AND before_ts IS NOT NULL AND after_ts >= before_ts THEN
            RETURN tool_error('created_after must be earlier than created_before', 'invalid_params');
        END IF;
        history_browse := NULLIF(trim(BOTH '* ' FROM query), '') IS NULL;
        IF history_browse AND after_ts IS NULL AND before_ts IS NULL THEN
            RETURN tool_error('Provide query keywords, or a created_after/created_before window to browse a time range chronologically', 'invalid_params');
        END IF;
        IF p_args ? 'sources' THEN
            IF jsonb_typeof(p_args->'sources') <> 'array' OR jsonb_array_length(p_args->'sources') = 0 THEN
                RETURN tool_error('history search requires at least one source', 'invalid_params');
            END IF;
            SELECT array_agg(DISTINCT value) INTO history_sources
            FROM jsonb_array_elements_text(p_args->'sources') t(value);
            IF EXISTS (SELECT 1 FROM unnest(history_sources) s(v) WHERE v NOT IN ('turn', 'memory', 'desk')) THEN
                RETURN tool_error(
                    'history search sources must be ''turn'', ''memory'', and/or ''desk''; invalid: '
                    || (SELECT string_agg(v, ', ' ORDER BY v) FROM unnest(history_sources) s(v) WHERE v NOT IN ('turn', 'memory', 'desk')),
                    'invalid_params');
            END IF;
        ELSE
            history_sources := ARRAY['turn', 'memory'];
        END IF;
        -- Browse mode reads preview-grain rows, so it affords the higher
        -- config-owned ceiling (#76); keyword search stays at 50.
        limit_value := LEAST(
            GREATEST(COALESCE(NULLIF(p_args->>'limit', '')::int, 20), 1),
            CASE WHEN history_browse
                 THEN GREATEST(COALESCE(get_config_int('memory.history_browse_max'), 200), 1)
                 ELSE 50 END);
        WITH hits AS (
            SELECT h.*, ROW_NUMBER() OVER () AS ord
            FROM search_cross_session_history(
                query, limit_value, history_sources, after_ts, before_ts,
                _db_brain_try_uuid(p_args->>'exclude_session_id'),
                COALESCE(NULLIF(p_args->>'exclude_sensitive', '')::boolean, FALSE)) h
        )
        SELECT COALESCE(jsonb_agg(jsonb_build_object(
                   'source_kind', h.source_kind,
                   'item_id', h.item_id::text,
                   'session_id', h.session_id::text,
                   'content', h.content,
                   'user_text', h.user_text,
                   'assistant_text', h.assistant_text,
                   'memory_type', h.memory_type,
                   'occurred_at', h.occurred_at,
                   'rank', h.rank,
                   'source_unit_ids', COALESCE((SELECT jsonb_agg(u::text) FROM unnest(h.source_unit_ids) u), '[]'::jsonb),
                   'source_attribution', h.source_attribution,
                   'metadata', h.metadata
               ) ORDER BY h.ord), '[]'::jsonb),
               min(h.occurred_at)
        INTO rows_json, oldest_ts
        FROM hits h;
        revision := jsonb_build_object(
            'query', query,
            'results', rows_json,
            'count', jsonb_array_length(rows_json),
            'limit', limit_value,
            -- Loud truncation (#76): a full page means the window holds
            -- more — silence here once read as "the morning was blank."
            'truncated', jsonb_array_length(rows_json) >= limit_value,
            'excluded_session_id', _db_brain_try_uuid(p_args->>'exclude_session_id')::text);
        IF jsonb_array_length(rows_json) > 0 AND jsonb_array_length(rows_json) >= limit_value THEN
            revision := revision || jsonb_build_object('note',
                'window truncated — older entries exist; page with created_before='
                || (to_jsonb(oldest_ts) #>> '{}'));
        END IF;
        RETURN tool_success(revision,
            format('Found %s history result(s)', jsonb_array_length(rows_json))
            || CASE WHEN jsonb_array_length(rows_json) >= limit_value
                    THEN ' (page full — more exist in this window)' ELSE '' END);
    ELSIF p_tool_name = 'explore_concept' THEN
        query := NULLIF(btrim(COALESCE(p_args->>'concept', '')), '');
        IF query IS NULL THEN
            RETURN tool_error('concept is required', 'invalid_params');
        END IF;
        limit_value := LEAST(GREATEST(COALESCE(NULLIF(p_args->>'limit', '')::int, 5), 1), 20);
        SELECT COALESCE(jsonb_agg(jsonb_build_object(
                   'memory_id', f.memory_id::text,
                   'content', f.memory_content,
                   'type', f.memory_type::text,
                   'importance', f.memory_importance,
                   'concept_strength', f.link_strength)), '[]'::jsonb)
        INTO rows_json
        FROM find_memories_by_concept(query, limit_value) f;
        revision := jsonb_build_object(
            'concept', query,
            'memories', rows_json,
            'related_concepts', '[]'::jsonb,
            'count', jsonb_array_length(rows_json));
        IF COALESCE(NULLIF(p_args->>'include_related', '')::boolean, TRUE)
           AND jsonb_array_length(rows_json) > 0 THEN
            revision := jsonb_set(revision, '{related_concepts}', COALESCE((
                SELECT jsonb_agg(jsonb_build_object('name', r.name, 'shared_memories', r.shared_memories))
                FROM find_related_concepts_for_memories(
                    ARRAY(SELECT (value->>'memory_id')::uuid FROM jsonb_array_elements(rows_json) value),
                    query, 10) r), '[]'::jsonb));
        END IF;
        RETURN tool_success(revision,
            format('Found %s memories for concept ''%s''', jsonb_array_length(rows_json), query));
    ELSIF p_tool_name = 'explore_subgraph' THEN
        IF jsonb_typeof(p_args->'seeds') = 'array' AND jsonb_array_length(p_args->'seeds') > 0 THEN
            BEGIN
                SELECT array_agg(value::uuid) INTO type_filter_uuids
                FROM jsonb_array_elements_text(p_args->'seeds') t(value);
            EXCEPTION WHEN OTHERS THEN
                RETURN tool_error('seeds must be memory uuids', 'invalid_params');
            END;
        ELSIF NULLIF(btrim(COALESCE(p_args->>'query', '')), '') IS NOT NULL THEN
            SELECT array_agg(f.memory_id) INTO type_filter_uuids
            FROM fast_recall(p_args->>'query', 10) f;
        ELSE
            RETURN tool_error('Provide ''query'' or ''seeds''.', 'invalid_params');
        END IF;
        IF type_filter_uuids IS NULL OR cardinality(type_filter_uuids) = 0 THEN
            RETURN tool_success(
                '{"nodes": [], "edges": [], "rendered": null}'::jsonb,
                'No seed memories found.');
        END IF;
        revision := build_context_subgraph(
            type_filter_uuids,
            LEAST(GREATEST(COALESCE(NULLIF(p_args->>'depth', '')::int, 2), 1), 4),
            CASE WHEN jsonb_typeof(p_args->'rel_types') = 'array'
                 THEN ARRAY(SELECT jsonb_array_elements_text(p_args->'rel_types')) END,
            LEAST(GREATEST(COALESCE(NULLIF(p_args->>'budget', '')::int, 30), 1), 100));
        display := render_subgraph(revision);
        RETURN tool_success(jsonb_build_object(
                'nodes', COALESCE(revision->'nodes', '[]'::jsonb),
                'edges', COALESCE(revision->'edges', '[]'::jsonb),
                'rendered', display),
            COALESCE(display, format('No typed connections among %s seed memory(ies).',
                                     cardinality(type_filter_uuids))));
    ELSIF p_tool_name IN ('get_procedures', 'get_strategies') THEN
        -- fast_recall filtered to one memory type. (The former Python path
        -- filtered on a column fast_recall does not return, so these tools
        -- errored on every call — fixed here.)
        query := NULLIF(btrim(COALESCE(
            p_args->>'task', p_args->>'situation', p_args->>'query', '')), '');
        IF query IS NULL THEN
            RETURN tool_error(
                CASE WHEN p_tool_name = 'get_procedures'
                     THEN 'task is required' ELSE 'situation is required' END,
                'invalid_params');
        END IF;
        limit_value := LEAST(GREATEST(COALESCE(NULLIF(p_args->>'limit', '')::int, 3), 1), 10);
        memory_type_value := CASE WHEN p_tool_name = 'get_procedures'
                                  THEN 'procedural' ELSE 'strategic' END;
        SELECT COALESCE(jsonb_agg(item), '[]'::jsonb) INTO rows_json FROM (
            SELECT jsonb_build_object(
                'memory_id', f.memory_id::text,
                'content', f.content,
                'similarity', f.score) AS item
            FROM fast_recall(query, limit_value * 2) f
            WHERE f.memory_type::text = memory_type_value
            LIMIT limit_value
        ) s;
        IF p_tool_name = 'get_procedures' THEN
            RETURN tool_success(
                jsonb_build_object('procedures', rows_json,
                                   'count', jsonb_array_length(rows_json), 'task', query),
                format('Found %s procedures for ''%s''', jsonb_array_length(rows_json), query));
        END IF;
        RETURN tool_success(
            jsonb_build_object('strategies', rows_json,
                               'count', jsonb_array_length(rows_json), 'situation', query),
            format('Found %s strategies for ''%s''', jsonb_array_length(rows_json), query));
    END IF;
    RETURN tool_error(format('Unsupported memory tool: %s', p_tool_name), 'invalid_params');
EXCEPTION WHEN OTHERS THEN
    RETURN tool_error(SQLERRM);
END;
$$;
