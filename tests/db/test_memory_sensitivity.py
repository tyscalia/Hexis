"""Privacy enforcement (#92): the 'sensitivity' marking survives every write
path, keeps private memories out of group-channel recall (while 1:1 recall
sees everything), propagates from sources to derived memories, and gates HMX
export behind an explicit opt-in.
"""
from __future__ import annotations

import json
import uuid

import pytest

from tests.utils import get_test_identifier

pytestmark = [pytest.mark.asyncio(loop_scope="session"), pytest.mark.db]


async def _stub_get_embedding(conn):
    """Axis-orthogonal deterministic embeddings: distinct texts land on
    distinct axes so the ingest router never dedups across them."""
    await conn.execute(
        """
        CREATE OR REPLACE FUNCTION get_embedding(text_contents TEXT[])
        RETURNS vector[] AS $$
            SELECT COALESCE(array_agg((
                array_fill(0.01::float, ARRAY[2 + abs(hashtext(t)) % (embedding_dimension() - 2)]) ||
                ARRAY[1.0::float] ||
                array_fill(0.01::float, ARRAY[embedding_dimension() - 3 - abs(hashtext(t)) % (embedding_dimension() - 2)])
            )::vector), ARRAY[]::vector[])
            FROM unnest(text_contents) t
        $$ LANGUAGE sql;
        """
    )


async def _seed_memory(conn, content: str, *, mem_type: str = "semantic",
                       sensitivity: str | None = None, query_text: str | None = None):
    """Seed an active memory whose embedding matches get_embedding(query_text)
    so it ranks at the top for that query."""
    attribution = {"kind": "conversation", "trust": 0.8}
    if sensitivity:
        attribution["sensitivity"] = sensitivity
    return await conn.fetchval(
        """
        INSERT INTO memories (type, content, embedding, importance, trust_level, status, source_attribution)
        VALUES ($1::memory_type, $2, (get_embedding(ARRAY[ensure_embedding_prefix($3, 'search_query')]))[1], 0.5, 0.8, 'active', $4::jsonb)
        RETURNING id
        """,
        mem_type, content, query_text or content, json.dumps(attribution),
    )


async def _seed_unit(conn, content: str, *, sensitivity: str | None = None,
                     query_text: str | None = None):
    attribution = {"kind": "conversation", "trust": 0.8}
    if sensitivity:
        attribution["sensitivity"] = sensitivity
    return await conn.fetchval(
        """
        INSERT INTO subconscious_units
            (content, user_text, assistant_text, embedding, embedding_status,
             status, importance, source_attribution, idempotency_key)
        VALUES ($1, $1, '', (get_embedding(ARRAY[ensure_embedding_prefix($2, 'search_query')]))[1], 'embedded',
                'active', 0.5, $3::jsonb, $4)
        RETURNING id
        """,
        content, query_text or content, json.dumps(attribution),
        f"test:{uuid.uuid4().hex}",
    )


async def test_normalizer_preserves_private(db_pool):
    async with db_pool.acquire() as conn:
        normalized = json.loads(await conn.fetchval(
            "SELECT normalize_source_reference('{\"kind\": \"conversation\", \"sensitivity\": \"private\"}'::jsonb)"
        ))
        undefined_level = json.loads(await conn.fetchval(
            "SELECT normalize_source_reference('{\"kind\": \"conversation\", \"sensitivity\": \"secret\"}'::jsonb)"
        ))
    assert normalized["sensitivity"] == "private"
    # 'private' is the one defined level; anything else is dropped rather
    # than stored as a marking that nothing enforces.
    assert "sensitivity" not in undefined_level


async def test_group_recall_excludes_private_one_to_one_includes(db_pool):
    query = f"sensitivity recall probe {get_test_identifier("sensitivity")}"
    private_content = f"private diary entry {get_test_identifier("sensitivity")}"
    public_content = f"shareable note {get_test_identifier("sensitivity")}"
    async with db_pool.acquire() as conn:
        tr = conn.transaction()
        await tr.start()
        try:
            await _stub_get_embedding(conn)
            await _seed_memory(conn, private_content, sensitivity="private", query_text=query)
            await _seed_memory(conn, public_content, query_text=query)
            await _seed_unit(conn, private_content, sensitivity="private", query_text=query)
            await _seed_unit(conn, public_content, query_text=query)

            everything = await conn.fetch(
                "SELECT content FROM recmem_recall_context($1, 10, 5, 10, NULL, FALSE)", query
            )
            filtered = await conn.fetch(
                "SELECT content FROM recmem_recall_context($1, 10, 5, 10, NULL, TRUE)", query
            )
        finally:
            await tr.rollback()

    everything_contents = " || ".join(r["content"] or "" for r in everything)
    filtered_contents = " || ".join(r["content"] or "" for r in filtered)
    assert private_content in everything_contents  # 1:1 keeps full recall
    assert public_content in everything_contents
    assert private_content not in filtered_contents  # group room recall
    assert public_content in filtered_contents


async def test_chat_turn_context_marks_unit_private(db_pool):
    marker = get_test_identifier("sensitivity")
    async with db_pool.acquire() as conn:
        tr = conn.transaction()
        await tr.start()
        try:
            await _stub_get_embedding(conn)
            result = json.loads(await conn.fetchval(
                "SELECT record_chat_turn_memory($1, $2, NULL, NULL, $3::jsonb)",
                f"a private aside {marker}", f"acknowledged {marker}",
                json.dumps({"sensitivity": "private"}),
            ))
            attribution = json.loads(await conn.fetchval(
                "SELECT source_attribution FROM subconscious_units WHERE id = $1",
                uuid.UUID(result["raw_unit_id"]),
            ))
        finally:
            await tr.rollback()
    assert attribution["sensitivity"] == "private"


async def test_extraction_propagates_sensitivity(db_pool):
    fact = f"the user's private project is codenamed {get_test_identifier("sensitivity")}"
    async with db_pool.acquire() as conn:
        tr = conn.transaction()
        await tr.start()
        try:
            await _stub_get_embedding(conn)
            unit_id = await _seed_unit(
                conn, f"private turn {get_test_identifier("sensitivity")}", sensitivity="private"
            )
            result = json.loads(await conn.fetchval(
                "SELECT apply_conscious_extraction(ARRAY[$1]::uuid[], $2::jsonb)",
                unit_id,
                json.dumps([{"content": fact, "confidence": 0.9,
                             "kind": "user_testimony", "unit_id": str(unit_id)}]),
            ))
            assert result.get("created", 0) >= 1 or result.get("created_ids"), result
            attribution = json.loads(await conn.fetchval(
                "SELECT source_attribution FROM memories WHERE content = $1", fact
            ))
        finally:
            await tr.rollback()
    assert attribution["sensitivity"] == "private"


async def test_scene_consolidation_propagates_sensitivity(db_pool):
    scene = f"an evening walk we agreed to keep between us {get_test_identifier("sensitivity")}"
    async with db_pool.acquire() as conn:
        tr = conn.transaction()
        await tr.start()
        try:
            await _stub_get_embedding(conn)
            private_unit = await _seed_unit(
                conn, f"private half {get_test_identifier("sensitivity")}", sensitivity="private"
            )
            public_unit = await _seed_unit(conn, f"public half {get_test_identifier("sensitivity")}")
            task_id = await conn.fetchval(
                """
                INSERT INTO recmem_consolidation_tasks (task_type, source_unit_ids, status)
                VALUES ('episode_create', ARRAY[$1, $2]::uuid[], 'in_progress')
                RETURNING id
                """,
                private_unit, public_unit,
            )
            result = json.loads(await conn.fetchval(
                "SELECT apply_recmem_episode_create($1, $2::jsonb)",
                task_id, json.dumps([{"content": scene, "importance": 0.6}]),
            ))
            memory_ids = result.get("memory_ids") or []
            assert memory_ids, result
            attribution = json.loads(await conn.fetchval(
                "SELECT source_attribution FROM memories WHERE id = $1",
                uuid.UUID(memory_ids[0]),
            ))
        finally:
            await tr.rollback()
    assert attribution["sensitivity"] == "private"


async def test_retention_gist_inherits_private(db_pool):
    async with db_pool.acquire() as conn:
        tr = conn.transaction()
        await tr.start()
        try:
            await _stub_get_embedding(conn)
            first = await _seed_memory(
                conn, f"quiet confession {get_test_identifier("sensitivity")}",
                mem_type="episodic", sensitivity="private",
            )
            second = await _seed_memory(
                conn, f"ordinary tuesday {get_test_identifier("sensitivity")}", mem_type="episodic"
            )
            gist_id = await conn.fetchval(
                "SELECT consolidate_memory_group(ARRAY[$1, $2]::uuid[])", first, second
            )
            assert gist_id is not None
            attribution = json.loads(await conn.fetchval(
                "SELECT source_attribution FROM memories WHERE id = $1", gist_id
            ))
        finally:
            await tr.rollback()
    assert attribution["sensitivity"] == "private"


async def test_hmx_export_requires_opt_in_for_private(db_pool):
    private_content = f"private export probe {get_test_identifier("sensitivity")}"
    unit_content = f"private unit probe {get_test_identifier("sensitivity")}"
    async with db_pool.acquire() as conn:
        tr = conn.transaction()
        await tr.start()
        try:
            await _stub_get_embedding(conn)
            await _seed_memory(conn, private_content, sensitivity="private")
            await _seed_unit(conn, unit_content, sensitivity="private")

            default_memories = await conn.fetchval(
                "SELECT hmx_export_memories(NULL, NULL, NULL, FALSE)::text"
            )
            opted_memories = await conn.fetchval(
                "SELECT hmx_export_memories(NULL, NULL, NULL, TRUE)::text"
            )
            default_units = await conn.fetchval(
                "SELECT hmx_export_raw_units(FALSE)::text"
            )
            opted_units = await conn.fetchval(
                "SELECT hmx_export_raw_units(TRUE)::text"
            )
        finally:
            await tr.rollback()

    assert private_content not in default_memories
    assert private_content in opted_memories
    assert unit_content not in default_units
    assert unit_content in opted_units


async def test_recall_tool_excludes_private_in_group_context(db_pool):
    """#96 stopgap: the conscious recall tool respects the same wall hydrate
    enforces — group context excludes private memories on both retriever
    arms (hybrid and structured)."""
    private_content = f"private tool probe {get_test_identifier('sensitivity')}"
    public_content = f"public tool probe {get_test_identifier('sensitivity')}"
    async with db_pool.acquire() as conn:
        tr = conn.transaction()
        await tr.start()
        try:
            await _stub_get_embedding(conn)
            await _seed_memory(conn, private_content, sensitivity="private",
                               query_text="tool probe search")
            await _seed_memory(conn, public_content, query_text="tool probe search")

            hybrid_group = json.loads(await conn.fetchval(
                "SELECT execute_memory_tool('recall', $1::jsonb)",
                json.dumps({"query": "tool probe search", "exclude_sensitive": True}),
            ))
            hybrid_private = json.loads(await conn.fetchval(
                "SELECT execute_memory_tool('recall', $1::jsonb)",
                json.dumps({"query": "tool probe search"}),
            ))
            structured_group = json.loads(await conn.fetchval(
                "SELECT execute_memory_tool('recall', $1::jsonb)",
                json.dumps({"query": "tool probe search", "min_importance": 0.1,
                            "exclude_sensitive": True}),
            ))
        finally:
            await tr.rollback()

    group_text = json.dumps(hybrid_group)
    assert public_content in group_text
    assert private_content not in group_text
    assert private_content in json.dumps(hybrid_private)  # 1:1 keeps everything
    structured_text = json.dumps(structured_group)
    assert public_content in structured_text
    assert private_content not in structured_text


async def test_search_history_excludes_private_in_group_context(db_pool):
    marker = get_test_identifier("sensitivity")
    private_content = f"secret diary line {marker}"
    public_content = f"shareable history line {marker}"
    async with db_pool.acquire() as conn:
        tr = conn.transaction()
        await tr.start()
        try:
            await _stub_get_embedding(conn)
            await _seed_unit(conn, private_content, sensitivity="private")
            await _seed_unit(conn, public_content)

            group_rows = await conn.fetch(
                "SELECT content FROM search_cross_session_history($1, 20, "
                "ARRAY['turn','memory']::text[], NULL, NULL, NULL, TRUE)", marker,
            )
            all_rows = await conn.fetch(
                "SELECT content FROM search_cross_session_history($1, 20)", marker,
            )
        finally:
            await tr.rollback()

    group_text = " || ".join(r["content"] for r in group_rows)
    all_text = " || ".join(r["content"] for r in all_rows)
    assert public_content in group_text
    assert private_content not in group_text
    assert private_content in all_text


async def test_metamemory_ice_cream_phenomenology(db_pool):
    """#96 Batch 1c: recall failure carries the felt state. (a) known → found;
    (b) familiar but blocked → incubation filed ("it'll come to me");
    (c) never known → honest low-familiarity miss."""
    marker = get_test_identifier("sensitivity")
    known = f"the ice cream place is called Salt and Straw {marker}"
    async with db_pool.acquire() as conn:
        tr = conn.transaction()
        await tr.start()
        try:
            await _stub_get_embedding(conn)
            await _seed_memory(conn, known, query_text="ice cream place name")

            # (a) known: same-axis query recalls it
            found = json.loads(await conn.fetchval(
                "SELECT execute_memory_tool('recall', $1::jsonb)",
                json.dumps({"query": "ice cream place name"}),
            ))
            assert found["output"]["count"] >= 1

            # (b) familiar but blocked: high min_score empties the results while
            # familiarity (sense over the same embedding space) stays high.
            blocked = json.loads(await conn.fetchval(
                "SELECT execute_memory_tool('recall', $1::jsonb)",
                json.dumps({"query": "ice cream place name", "min_score": 99.0}),
            ))
            meta = blocked["output"]["metamemory"]
            assert blocked["output"]["count"] == 0
            assert meta["familiarity"] > 0.5
            assert meta["incubating"] is True
            assert "simmer" in blocked["display_output"]
            pending = await conn.fetchval(
                "SELECT COUNT(*) FROM memory_activation WHERE background_search_pending "
                "AND query_text = 'ice cream place name'"
            )
            assert pending == 1

            # (c) never known: orthogonal query, low familiarity, honest miss
            never = json.loads(await conn.fetchval(
                "SELECT execute_memory_tool('recall', $1::jsonb)",
                json.dumps({"query": f"zz never known topic {marker}"}),
            ))
            nmeta = never["output"]["metamemory"]
            assert never["output"]["count"] == 0
            assert nmeta["incubating"] is False
            assert "ever knew" in never["display_output"]
        finally:
            await tr.rollback()


async def test_open_memory_excludes_private_in_group_context(db_pool):
    """#92 parity for open_memory: with exclude_sensitive set, a private
    memory's drill-down refuses (not_found) instead of handing a group room
    the verbatim source turns behind a private memory."""
    marker = get_test_identifier("sensitivity")
    private_content = f"private gist {marker}"
    private_unit_text = f"verbatim private source turn {marker}"
    async with db_pool.acquire() as conn:
        tr = conn.transaction()
        await tr.start()
        try:
            await _stub_get_embedding(conn)
            mem_id = await _seed_memory(conn, private_content, sensitivity="private")
            unit_id = await _seed_unit(conn, private_unit_text, sensitivity="private")
            await conn.execute(
                "INSERT INTO memory_source_units (memory_id, subconscious_unit_id)"
                " VALUES ($1, $2)",
                mem_id, unit_id,
            )

            group = json.loads(await conn.fetchval(
                "SELECT execute_memory_tool('open_memory', $1::jsonb)",
                json.dumps({"memory_id": str(mem_id), "exclude_sensitive": True}),
            ))
        finally:
            await tr.rollback()

    assert group["success"] is False
    assert private_unit_text not in json.dumps(group)


async def test_open_memory_default_keeps_verbatim_grain(db_pool):
    """Legacy compat: no exclude_sensitive key keeps the old behavior —
    fail-open on the default path, so even a PRIVATE memory's verbatim
    source unit still opens (proves the gate cannot fire when the flag is
    unset; the pre-fix behavior is unchanged)."""
    marker = get_test_identifier("sensitivity")
    private_content = f"openable private gist {marker}"
    unit_text = f"verbatim private source turn {marker}"
    async with db_pool.acquire() as conn:
        tr = conn.transaction()
        await tr.start()
        try:
            await _stub_get_embedding(conn)
            mem_id = await _seed_memory(conn, private_content, sensitivity="private")
            unit_id = await _seed_unit(conn, unit_text, sensitivity="private")
            await conn.execute(
                "INSERT INTO memory_source_units (memory_id, subconscious_unit_id)"
                " VALUES ($1, $2)",
                mem_id, unit_id,
            )

            default = json.loads(await conn.fetchval(
                "SELECT execute_memory_tool('open_memory', $1::jsonb)",
                json.dumps({"memory_id": str(mem_id)}),
            ))
        finally:
            await tr.rollback()

    assert default["success"] is True
    assert unit_text in json.dumps(default)


async def test_belief_history_excludes_private_in_group_context(db_pool):
    """#92 parity for belief_history: with exclude_sensitive set, a private
    memory's revision history refuses rather than leaking its content."""
    marker = get_test_identifier("sensitivity")
    private_content = f"private belief {marker}"
    async with db_pool.acquire() as conn:
        tr = conn.transaction()
        await tr.start()
        try:
            await _stub_get_embedding(conn)
            mem_id = await _seed_memory(conn, private_content,
                                        mem_type="worldview", sensitivity="private")

            group = json.loads(await conn.fetchval(
                "SELECT execute_memory_tool('belief_history', $1::jsonb)",
                json.dumps({"memory_id": str(mem_id), "exclude_sensitive": True}),
            ))
        finally:
            await tr.rollback()

    assert group["success"] is False
    assert private_content not in json.dumps(group)


async def test_belief_history_default_keeps_private_story(db_pool):
    """Legacy compat: no exclude_sensitive key keeps the old behavior —
    fail-open on the default path, so a PRIVATE belief's full story (its
    content, per the whole-story contract) still comes back unchanged."""
    marker = get_test_identifier("sensitivity")
    private_content = f"private belief legacy {marker}"
    async with db_pool.acquire() as conn:
        tr = conn.transaction()
        await tr.start()
        try:
            await _stub_get_embedding(conn)
            mem_id = await _seed_memory(conn, private_content,
                                        mem_type="worldview", sensitivity="private")

            default = json.loads(await conn.fetchval(
                "SELECT execute_memory_tool('belief_history', $1::jsonb)",
                json.dumps({"memory_id": str(mem_id)}),
            ))
        finally:
            await tr.rollback()

    assert default["success"] is True
    assert private_content in json.dumps(default)
