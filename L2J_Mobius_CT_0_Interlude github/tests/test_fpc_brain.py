import importlib.util
import os
import sys
import tempfile
import time
import unittest
from pathlib import Path


PROJECT_ROOT = Path(__file__).resolve().parents[1]
BRAIN_PATH = PROJECT_ROOT / "fpc_brain.py"


def load_brain_module():
    """Load fpc_brain without requiring a live LLM endpoint."""
    os.environ["PROVIDER"] = "ollama"
    spec = importlib.util.spec_from_file_location("fpc_brain_under_test", BRAIN_PATH)
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


class FpcBrainRegressionTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.brain = load_brain_module()

    def setUp(self):
        self.temp_dir = tempfile.TemporaryDirectory()
        self.original_memory_dir = self.brain.MEMORY_DIR
        self.original_memory_file = self.brain.MEMORY_FILE
        self.original_memory = self.brain._memory

        self.brain.MEMORY_DIR = self.temp_dir.name
        self.brain.MEMORY_FILE = os.path.join(self.temp_dir.name, "fpc_memory.json")
        self.brain._memory = {}

    def tearDown(self):
        self.brain.MEMORY_DIR = self.original_memory_dir
        self.brain.MEMORY_FILE = self.original_memory_file
        self.brain._memory = self.original_memory
        self.temp_dir.cleanup()

    def test_voice_is_stable_for_same_name(self):
        first = self.brain._voice("Mirella")
        second = self.brain._voice("Mirella")
        self.assertEqual(first, second)

    def test_sanitize_drops_ai_disclosure(self):
        self.assertEqual("", self.brain.sanitize("As an AI language model, I cannot help."))

    def test_sanitize_strips_contact_data_and_html(self):
        result = self.brain.sanitize("<br>pm me at test@example.com or https://example.com now")
        self.assertNotIn("example.com", result)
        self.assertNotIn("<br>", result)
        self.assertEqual("pm me at or now", result)

    def test_load_memory_missing_file_is_safe(self):
        self.brain._memory = {"stale": {}}
        self.brain.load_memory()
        self.assertEqual({}, self.brain._memory)

    def test_load_memory_malformed_json_is_safe(self):
        Path(self.brain.MEMORY_FILE).write_text("{not valid json", encoding="utf-8")
        self.brain._memory = {"stale": {}}
        self.brain.load_memory()
        self.assertEqual({}, self.brain._memory)

    def test_remember_fact_deduplicates_and_persists(self):
        self.brain.remember_fact("PlayerOne", "trade", "Player uses trade chat to buy items.")
        self.brain.remember_fact("PlayerOne", "trade", "Player uses trade chat to buy items.")

        entry = self.brain._memory["playerone"]
        self.assertEqual(1, len(entry["trade"]))
        self.assertTrue(Path(self.brain.MEMORY_FILE).exists())

        self.brain._memory = {}
        self.brain.load_memory()
        self.assertEqual(1, len(self.brain._memory["playerone"]["trade"]))

    def test_remember_fact_caps_each_category(self):
        for index in range(self.brain.MEMORY_MAX_FACTS_PER_CATEGORY + 5):
            self.brain.remember_fact("PlayerOne", "social", f"fact-{index}")

        facts = self.brain._memory["playerone"]["social"]
        self.assertEqual(self.brain.MEMORY_MAX_FACTS_PER_CATEGORY, len(facts))
        self.assertEqual("fact-5", facts[0]["text"])

    def test_trade_ad_extracts_d_grade_shot_habit(self):
        self.brain.remember_trade_ad("PlayerOne", "+WTB ssd 5k")
        texts = [fact["text"] for fact in self.brain._memory["playerone"]["trade"]]
        self.assertIn("Player has looked for D-grade shots in bulk.", texts)

    def test_exchange_extracts_meet_and_social_memory(self):
        self.brain.remember_from_exchange(
            "PlayerOne",
            "thanks, gk sounds good",
            "ok heading there\n[[MEET:gatekeeper]]",
            "WHISPER",
        )
        entry = self.brain._memory["playerone"]
        trade_texts = [fact["text"] for fact in entry["trade"]]
        social_texts = [fact["text"] for fact in entry["social"]]

        self.assertIn("Player agreed to meet at gatekeeper.", trade_texts)
        self.assertIn("Player often uses gatekeeper as a meeting point.", trade_texts)
        self.assertIn("Player has been friendly/appreciative.", social_texts)

    def test_trade_ad_does_not_persist_raw_ad_or_price(self):
        # The raw ad (with its one-time price/quantity) must not become permanent player-global memory.
        self.brain.remember_trade_ad("PlayerOne", "+WTB ssd 300 adena")
        texts = [fact["text"] for fact in self.brain._memory["playerone"]["trade"]]
        self.assertNotIn("Player recently posted trade ad: +WTB ssd 300 adena", texts)
        self.assertFalse(any("300" in text for text in texts), texts)
        # The generalized habit is still recorded.
        self.assertIn("Player has looked for D-grade shots in bulk.", texts)

    def test_exchange_does_not_persist_specific_deal_price(self):
        # A closed deal's item/price is per-deal state, not a lasting profile fact shared with every other phantom.
        self.brain.remember_from_exchange(
            "PlayerOne",
            "ok deal, gk",
            "cool see you there [[SHOP:SELL:Soulshot D-grade:5]]\n[[MEET:gatekeeper]]",
            "WHISPER",
        )
        texts = [fact["text"] for fact in self.brain._memory["playerone"]["trade"]]
        self.assertFalse(any("adena each" in text for text in texts), texts)
        self.assertFalse(any("Soulshot D-grade" in text for text in texts), texts)
        # Stable meet habit is still recorded from the same exchange.
        self.assertIn("Player agreed to meet at gatekeeper.", texts)

    def test_player_key_normalizes_case_and_whitespace(self):
        self.assertEqual("playerone", self.brain._player_key("  PlayerOne  "))
        self.assertEqual("", self.brain._player_key(None))

    def test_trade_ad_wts_records_selling_habit(self):
        self.brain.remember_trade_ad("PlayerOne", "WTS adena cheap")
        texts = [fact["text"] for fact in self.brain._memory["playerone"]["trade"]]
        self.assertIn("Player uses trade chat to sell items.", texts)

    def test_exchange_cancel_meet_is_recorded(self):
        self.brain.remember_from_exchange(
            "PlayerOne", "nvm changed my mind", "no worries [[MEET:cancel]]", "WHISPER"
        )
        texts = [fact["text"] for fact in self.brain._memory["playerone"]["trade"]]
        self.assertIn("Player cancelled or backed out of a meetup/trade.", texts)

    def test_exchange_records_haggling_and_afk(self):
        self.brain.remember_from_exchange(
            "PlayerOne", "too much, can you go lower? brb", "sure", "WHISPER"
        )
        entry = self.brain._memory["playerone"]
        trade_texts = [fact["text"] for fact in entry["trade"]]
        party_texts = [fact["text"] for fact in entry["party"]]
        self.assertIn("Player sometimes haggles trade prices.", trade_texts)
        self.assertIn("Player sometimes goes AFK during party play.", party_texts)

    def test_fmt_amount_shorthand(self):
        self.assertEqual("45k", self.brain.fmt_amount(45000))
        self.assertEqual("470k", self.brain.fmt_amount(470000))
        self.assertEqual("1.2k", self.brain.fmt_amount(1200))
        self.assertEqual("1k", self.brain.fmt_amount(1000))
        self.assertEqual("45kk", self.brain.fmt_amount(45000000))
        self.assertEqual("1.5kk", self.brain.fmt_amount(1500000))
        self.assertEqual("300", self.brain.fmt_amount(300))
        self.assertEqual("45k", self.brain.fmt_amount("45000"))
        self.assertEqual("junk", self.brain.fmt_amount("junk"))

    def test_deal_note_speaks_shorthand_prices(self):
        with self.brain.app.test_request_context(headers={
            "X-Deal-Side": "SELL",
            "X-Deal-Item": "Soulshot D-grade",
            "X-Deal-Count": "5000",
            "X-Deal-Unit-Price": "45000",
            "X-Deal-Total-Price": "225000000",
        }):
            note = self.brain.deal_note_from_headers()
        self.assertIn("45k adena each", note)
        self.assertNotIn("45000 adena each", note)
        self.assertIn("5kx", note)  # count also spoken in shorthand
        # The machine-parsed shop tag keeps the plain number.
        self.assertIn("[[SHOP:SELL:Soulshot D-grade:45000]]", note)

    def test_deal_note_asks_for_amount_when_needed(self):
        with self.brain.app.test_request_context(headers={
            "X-Deal-Side": "SELL",
            "X-Deal-Item": "Soulshot D-grade",
            "X-Deal-Unit-Price": "45000",
            "X-Deal-Needs-Count": "true",
        }):
            note = self.brain.deal_note_from_headers()
        self.assertIn("how many", note.lower())
        self.assertNotIn("[[SHOP:", note)

    def test_memory_note_empty_when_no_facts(self):
        self.assertEqual("", self.brain.memory_note("Nobody"))
        self.assertEqual("", self.brain.memory_note(""))

    def test_memory_note_formats_remembered_facts(self):
        self.brain.remember_fact("PlayerOne", "social", "Player has been friendly/appreciative.")
        note = self.brain.memory_note("PlayerOne")
        self.assertIn("Memory about this player", note)
        self.assertIn("- Player has been friendly/appreciative.", note)

    def test_clean_reply_treats_bare_optout_as_silence(self):
        self.assertEqual("", self.brain.clean_reply("pass"))
        self.assertEqual("", self.brain.clean_reply("Pass."))
        self.assertEqual("", self.brain.clean_reply("none"))

    def test_clean_reply_strips_trailing_pass_sentinel(self):
        # The bug: model tacked the silence sentinel onto the end of a real line.
        self.assertEqual("got ganked in innadril last night", self.brain.clean_reply("got ganked in innadril last night... pass"))
        self.assertEqual("nvm then", self.brain.clean_reply("nvm then pass"))
        # A real word ending in "pass" must survive (word boundary).
        self.assertEqual("check the compass", self.brain.clean_reply("check the compass"))
        # A normal line is untouched.
        self.assertEqual("welcome to grind city bro lol", self.brain.clean_reply("welcome to grind city bro lol"))

    def test_strip_fake_handle_removes_copied_username_prefix(self):
        # The exact garbled AMBIENT case: model invents a "vamp_wanted:" handle copied from the log format.
        self.assertEqual("wts elite set", self.brain.strip_fake_handle("vamp_wanted: wts elite set"))
        # A capitalised nick is also a handle.
        self.assertEqual("selling ssd", self.brain.strip_fake_handle("Ulras: selling ssd"))

    def test_strip_fake_handle_keeps_real_trade_prefixes_and_plain_lines(self):
        # Genuine trade prefixes before a colon must survive.
        self.assertEqual("wtb: soulshots d", self.brain.strip_fake_handle("wtb: soulshots d"))
        self.assertEqual("pc: elven necklace", self.brain.strip_fake_handle("pc: elven necklace"))
        # A normal line with no leading handle is untouched.
        self.assertEqual("anyone selling ssd cheap?", self.brain.strip_fake_handle("anyone selling ssd cheap?"))

    def test_sanitize_drops_fabricated_handle(self):
        self.assertEqual("wts elite set", self.brain.sanitize("vamp_wanted: wts elite set"))

    def test_identity_block_empty_when_nothing_known(self):
        self.assertEqual("", self.brain.identity_block())
        self.assertEqual("", self.brain.identity_block("", "", "", ""))

    def test_identity_block_formats_known_fields(self):
        note = self.brain.identity_block(level="40", clazz="Warlord", race="Orc", gear="C grade")
        self.assertIn("level: 40", note)
        self.assertIn("class: Warlord", note)
        self.assertIn("Orc", note)
        self.assertIn("C grade", note)
        # The level cap must be reinforced right where the bot reads its own level.
        self.assertIn("never claim a level above 80", note)

    def test_identity_block_omits_missing_fields(self):
        note = self.brain.identity_block(level="55")
        self.assertIn("level: 55", note)
        self.assertNotIn("class:", note)
        self.assertNotIn("gear:", note)

    def test_global_rules_cap_the_level_at_80(self):
        # The world-facts guardrail that stops a bot claiming an impossible Interlude level (e.g. 94).
        self.assertIn("level cap is 80", self.brain.GLOBAL_RULES)

    def test_global_rules_contain_the_world_and_invention_guardrails(self):
        # Keep bots from borrowing other games' content or inventing L2 zones/mobs/items.
        self.assertIn("borrow from any other game", self.brain.GLOBAL_RULES)
        self.assertIn("Do NOT invent Lineage 2 content", self.brain.GLOBAL_RULES)


class KnowledgeRetrievalTests(unittest.TestCase):
    """Grounded-fact retrieval is deterministic and prompt-safe; isolate _KB per test."""

    @classmethod
    def setUpClass(cls):
        cls.brain = load_brain_module()

    def setUp(self):
        self.original_kb = list(self.brain._KB)
        self.brain._KB.clear()
        self.brain._KB.extend([
            ({"cruma", "tower", "level", "40", "50"}, "Cruma Tower suits levels 40 to 50."),
            ({"gludio", "town"}, "Gludio is a starter town."),
        ])

    def tearDown(self):
        self.brain._KB.clear()
        self.brain._KB.extend(self.original_kb)

    def test_retrieve_matches_on_tag_overlap(self):
        self.assertEqual(["Gludio is a starter town."], self.brain.retrieve("where is gludio"))

    def test_retrieve_returns_empty_when_nothing_matches(self):
        self.assertEqual([], self.brain.retrieve("hello there friend"))

    def test_retrieve_level_band_boosts_matching_zone(self):
        # A level inside the band boosts the already-matched banded zone fact.
        self.assertIn("Cruma Tower suits levels 40 to 50.", self.brain.retrieve("is cruma good at 45"))

    def test_retrieve_allow_filter_restricts_categories(self):
        self.assertEqual([], self.brain.retrieve("gludio", allow={"item"}))

    def test_knowledge_note_empty_when_no_match(self):
        self.assertEqual("", self.brain.knowledge_note("hello there friend"))

    def test_knowledge_note_formats_matched_facts(self):
        note = self.brain.knowledge_note("gludio")
        self.assertIn("Game facts you can rely on", note)
        self.assertIn("- Gludio is a starter town.", note)

    def test_random_knowledge_note_only_uses_real_kb_facts(self):
        note = self.brain.random_knowledge_note(2)
        self.assertIn("Real Lineage 2 details", note)
        # Whatever it picked must be an actual KB fact - never invented.
        self.assertTrue(("Cruma Tower suits levels 40 to 50." in note) or ("Gludio is a starter town." in note))

    def test_random_knowledge_note_respects_allow_filter(self):
        note = self.brain.random_knowledge_note(2, allow={"town"})
        self.assertIn("Gludio is a starter town.", note)
        self.assertNotIn("Cruma Tower", note)

    def test_random_knowledge_note_empty_when_no_category_match(self):
        self.assertEqual("", self.brain.random_knowledge_note(2, allow={"item"}))


class LeakGuardTests(unittest.TestCase):
    """sanitize() must drop replies that carry leaked prompt/instruction scaffolding, structurally, not just
    the exact strings on the fixed blacklist."""

    @classmethod
    def setUpClass(cls):
        cls.brain = load_brain_module()

    def test_drops_uppercase_prompt_heading(self):
        self.assertEqual("", self.brain.sanitize("YOUR PERSONALITY:\nquiet and terse\nye 12k works"))

    def test_drops_mixed_case_scaffold_heading(self):
        self.assertEqual("", self.brain.sanitize("Memory about this player: haggles a lot"))
        self.assertEqual("", self.brain.sanitize("World Facts: level cap is 80"))

    def test_drops_copied_constitution_phrase(self):
        self.assertEqual("", self.brain.sanitize("remember you are a real human player, reply with one line"))

    def test_keeps_normal_chat_and_trade_shorthand(self):
        self.assertEqual("ye 12k works, where u wanna meet?",
                         self.brain.sanitize("ye 12k works, where u wanna meet?"))
        self.assertEqual("WTS SSD 5k pst", self.brain.sanitize("WTS SSD 5k pst"))

    def test_looks_like_leaked_prompt_is_conservative(self):
        # Ordinary lines that merely start with a lowercase word or contain a colon mid-sentence are kept.
        self.assertFalse(self.brain.looks_like_leaked_prompt("my role: tank, need a healer"))
        self.assertFalse(self.brain.looks_like_leaked_prompt("lf party cruma pst"))


class LocalSayHistoryTests(unittest.TestCase):
    """SAY history is proximity-scoped: each location label keeps its own deque, so chat in one town never
    surfaces as context in another."""

    @classmethod
    def setUpClass(cls):
        cls.brain = load_brain_module()

    def setUp(self):
        self.brain.say_logs.clear()

    def test_say_key_normalizes_location(self):
        self.assertEqual("in giran", self.brain._say_key("in Giran"))
        self.assertEqual("_unknown", self.brain._say_key(""))
        self.assertEqual("_unknown", self.brain._say_key(None))

    def test_say_logs_are_isolated_by_location(self):
        self.brain.say_logs[self.brain._say_key("in Giran")].append("Ann: wts ss")
        self.brain.say_logs[self.brain._say_key("near Dion")].append("Bob: lf party")
        giran = list(self.brain.say_logs[self.brain._say_key("in Giran")])
        dion = list(self.brain.say_logs[self.brain._say_key("near Dion")])
        self.assertIn("Ann: wts ss", giran)
        self.assertNotIn("Ann: wts ss", dion)
        self.assertIn("Bob: lf party", dion)
        self.assertNotIn("Bob: lf party", giran)


class ConversationTtlTests(unittest.TestCase):
    """The (player, bot) whisper map is pruned once a conversation has been idle past the TTL; persistent
    player memory is unaffected."""

    @classmethod
    def setUpClass(cls):
        cls.brain = load_brain_module()

    def setUp(self):
        self.brain.conversations.clear()
        self.brain._conversation_seen.clear()

    def test_conversation_for_returns_stable_deque(self):
        first = self.brain.conversation_for("PlayerOne", "Mirella")
        first.append({"role": "user", "content": "hi"})
        second = self.brain.conversation_for("PlayerOne", "Mirella")
        self.assertIs(first, second)
        self.assertEqual(1, len(second))

    def test_idle_conversations_are_pruned(self):
        hist = self.brain.conversation_for("PlayerOne", "Mirella")
        hist.append({"role": "user", "content": "hi"})
        # Backdate the last-access time past the TTL, then touch a different conversation to trigger pruning.
        key = ("PlayerOne", "Mirella")
        self.brain._conversation_seen[key] = time.time() - self.brain.CONVERSATION_TTL_SECONDS - 10
        self.brain.conversation_for("PlayerTwo", "Bob")
        self.assertNotIn(key, self.brain.conversations)
        self.assertNotIn(key, self.brain._conversation_seen)

    def test_active_conversation_survives_prune(self):
        key = ("PlayerOne", "Mirella")
        self.brain.conversation_for(*key)
        self.brain.conversation_for("PlayerTwo", "Bob")
        self.assertIn(key, self.brain.conversations)


if __name__ == "__main__":
    unittest.main()
