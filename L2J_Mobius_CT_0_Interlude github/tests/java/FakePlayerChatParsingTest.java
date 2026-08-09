/*
 * Copyright (c) 2013 L2jMobius
 *
 * Permission is hereby granted, free of charge, to any person obtaining a copy
 * of this software and associated documentation files (the "Software"), to deal
 * in the Software without restriction, including without limitation the rights
 * to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
 * copies of the Software, and to permit persons to whom the Software is
 * furnished to do so, subject to the following conditions:
 *
 * The above copyright notice and this permission notice shall be
 * included in all copies or substantial portions of the Software.
 *
 * THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
 * IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
 * FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
 * AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY,
 * WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR
 * IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
 */

import java.util.List;
import java.util.regex.Matcher;

import org.l2jmobius.gameserver.managers.FakePlayerChatParsing;
import org.l2jmobius.gameserver.managers.FakePlayerChatParsing.RoleRequest;

/**
 * Standalone (no JUnit, no game server) regression harness for {@link FakePlayerChatParsing}.<br>
 * These lock down the pure trade/party/control-tag parsing that the fake-player chat system relies on -
 * quantity caps, price multipliers, meet-spot aliases, LFP levels and the tolerant control-tag patterns.
 *
 * <p>Run from the project root ("L2J_Mobius_CT_0_Interlude github"):
 * <pre>
 *   javac -d build/test-classes \
 *         "java/org/l2jmobius/gameserver/managers/FakePlayerChatParsing.java" \
 *         "tests/java/FakePlayerChatParsingTest.java"
 *   java -cp build/test-classes FakePlayerChatParsingTest
 * </pre>
 * Exit code is 0 when every check passes, 1 otherwise.
 */
public class FakePlayerChatParsingTest
{
	private static int checks = 0;
	private static int failures = 0;

	public static void main(String[] args)
	{
		testTradeQuantity();
		testTradeUnitPrice();
		testSpokenQuantity();
		testShopPriceMultiplier();
		testResolveDealPrice();
		testLfpLevel();
		testLooksLikeLfp();
		testLooksLikeTradeAd();
		testNormalizeMeetSpot();
		testMeetTagPattern();
		testShopTagPattern();
		testCountBefore();
		testParseRoleRequests();
		testFuzzyMatching();

		System.out.println();
		System.out.println("Ran " + checks + " checks, " + failures + " failure(s).");
		if (failures > 0)
		{
			System.exit(1);
		}
		System.out.println("OK");
	}

	private static void testTradeQuantity()
	{
		// Plain, k and kk/m suffixes on a stackable item.
		eq(5000, FakePlayerChatParsing.parseTradeQuantity("ssd 5k", true), "5k -> 5000");
		eq(2000000, FakePlayerChatParsing.parseTradeQuantity("adena 2m", true), "2m -> 2,000,000 (at cap)");
		eq(1000000, FakePlayerChatParsing.parseTradeQuantity("adena 1kk", true), "1kk -> 1,000,000");
		eq(42, FakePlayerChatParsing.parseTradeQuantity("42", true), "bare number -> 42");
		// Over the 2,000,000 cap is rejected, and the scanner keeps looking for a later sane quantity.
		eq(0, FakePlayerChatParsing.parseTradeQuantity("3m", true), "3m over cap -> 0");
		eq(500, FakePlayerChatParsing.parseTradeQuantity("9m or 500", true), "over-cap then valid -> 500");
		// Guards.
		eq(0, FakePlayerChatParsing.parseTradeQuantity("5k", false), "non-stackable -> 0");
		eq(0, FakePlayerChatParsing.parseTradeQuantity(null, true), "null phrase -> 0");
		eq(0, FakePlayerChatParsing.parseTradeQuantity("no digits here", true), "no number -> 0");
	}

	private static void testTradeUnitPrice()
	{
		// A number carrying a price cue is read as the unit price (with k/kk/m applied).
		eq(300, FakePlayerChatParsing.parseTradeUnitPrice("ssd 300 adena"), "300 adena -> 300");
		eq(300, FakePlayerChatParsing.parseTradeUnitPrice("ssd 300a"), "300a -> 300");
		eq(5000, FakePlayerChatParsing.parseTradeUnitPrice("ss 5k ea"), "5k ea -> 5000");
		eq(5000, FakePlayerChatParsing.parseTradeUnitPrice("ss 5k each"), "5k each -> 5000");
		eq(1200, FakePlayerChatParsing.parseTradeUnitPrice("ssd 1200 pc"), "1200 pc -> 1200");
		eq(250, FakePlayerChatParsing.parseTradeUnitPrice("ssd 250 per"), "250 per -> 250");
		eq(1000000, FakePlayerChatParsing.parseTradeUnitPrice("mats 1kk adena"), "1kk adena -> 1,000,000");
		eq(300, FakePlayerChatParsing.parseTradeUnitPrice("ssd @300"), "@300 -> 300");
		eq(5000, FakePlayerChatParsing.parseTradeUnitPrice("ssd @5k"), "@5k -> 5000");
		// A bare number is a quantity, not a price - never mistaken for one.
		eq(0, FakePlayerChatParsing.parseTradeUnitPrice("5k ssd"), "bare quantity -> no price");
		eq(0, FakePlayerChatParsing.parseTradeUnitPrice("1000 arrows"), "quantity + noun -> no price");
		// Quantity then a priced number: the priced one wins ("1000 ssd 5 adena each" -> 5).
		eq(5, FakePlayerChatParsing.parseTradeUnitPrice("1000 ssd 5 adena"), "quantity then priced -> 5");
		// Guards.
		eq(0, FakePlayerChatParsing.parseTradeUnitPrice(null), "null phrase -> 0");
		eq(0, FakePlayerChatParsing.parseTradeUnitPrice("just chatting"), "no number -> 0");
	}

	private static void testSpokenQuantity()
	{
		// Spelled-out or digit count + magnitude word.
		eq(2000, FakePlayerChatParsing.parseSpokenQuantity("a couple thousand"), "a couple thousand -> 2000");
		eq(3000, FakePlayerChatParsing.parseSpokenQuantity("few k"), "few k -> 3000");
		eq(300, FakePlayerChatParsing.parseSpokenQuantity("a few hundred"), "a few hundred -> 300");
		eq(2000, FakePlayerChatParsing.parseSpokenQuantity("2 thousand"), "2 thousand -> 2000");
		eq(1000, FakePlayerChatParsing.parseSpokenQuantity("a thousand"), "a thousand -> 1000");
		eq(1000000, FakePlayerChatParsing.parseSpokenQuantity("a million"), "a million -> 1,000,000");
		eq(2000000, FakePlayerChatParsing.parseSpokenQuantity("3 million"), "3 million capped to 2,000,000");
		// Plain digits (with suffix) fall through to the quantity parser.
		eq(5000, FakePlayerChatParsing.parseSpokenQuantity("gimme 5k"), "gimme 5k -> 5000");
		eq(500, FakePlayerChatParsing.parseSpokenQuantity("500 please"), "500 -> 500");
		// Vague bulk with no number -> use the default stack.
		eq(FakePlayerChatParsing.SPOKEN_QUANTITY_DEFAULT, FakePlayerChatParsing.parseSpokenQuantity("just give me a stack"), "a stack -> default");
		eq(FakePlayerChatParsing.SPOKEN_QUANTITY_DEFAULT, FakePlayerChatParsing.parseSpokenQuantity("some please"), "some -> default");
		eq(FakePlayerChatParsing.SPOKEN_QUANTITY_DEFAULT, FakePlayerChatParsing.parseSpokenQuantity("whatever you got"), "whatever -> default");
		// No amount at all.
		eq(0, FakePlayerChatParsing.parseSpokenQuantity("sounds good, gk"), "no amount -> 0");
		eq(0, FakePlayerChatParsing.parseSpokenQuantity(null), "null -> 0");
	}

	private static void testShopPriceMultiplier()
	{
		eq(500, FakePlayerChatParsing.applyShopPriceMultiplier(500, null), "no suffix keeps price");
		eq(5000, FakePlayerChatParsing.applyShopPriceMultiplier(5, "k"), "k -> *1000");
		eq(5000000, FakePlayerChatParsing.applyShopPriceMultiplier(5, "kk"), "kk -> *1,000,000");
		eq(5000, FakePlayerChatParsing.applyShopPriceMultiplier(5, "K"), "suffix is case-insensitive");
	}

	private static void testResolveDealPrice()
	{
		// The offer is authoritative; a genuine haggle within 4x either way is honored.
		eq(14000, FakePlayerChatParsing.resolveDealPrice(14000, 14000), "exact match kept");
		eq(12000, FakePlayerChatParsing.resolveDealPrice(12000, 14000), "small discount is a real haggle");
		eq(20000, FakePlayerChatParsing.resolveDealPrice(20000, 14000), "small markup is a real haggle");
		// The core bug: the model dropped the "k", so 14k became a literal 14 -> reject, use the offer.
		eq(14000, FakePlayerChatParsing.resolveDealPrice(14, 14000), "dropped-k 14 -> falls back to 14000");
		// An added "k" (14 offered, tag says 14000) is also outside the band -> use the offer.
		eq(14, FakePlayerChatParsing.resolveDealPrice(14000, 14), "added-k -> falls back to offer");
		// No usable tag price -> use the offer; no server anchor -> trust the tag.
		eq(14000, FakePlayerChatParsing.resolveDealPrice(0, 14000), "no tag price -> offer");
		eq(500, FakePlayerChatParsing.resolveDealPrice(500, 0), "no offer -> trust tag");
		eq(0, FakePlayerChatParsing.resolveDealPrice(0, 0), "nothing known -> 0");
	}

	private static void testLfpLevel()
	{
		eq(57, FakePlayerChatParsing.parseLfpLevel("lfm buffer lvl 57"), "lvl 57");
		eq(40, FakePlayerChatParsing.parseLfpLevel("need healer level 40"), "level 40");
		eq(30, FakePlayerChatParsing.parseLfpLevel("lf pt lv 30"), "lv 30");
		eq(0, FakePlayerChatParsing.parseLfpLevel("lfm buffer"), "no level -> 0 (match recruiter)");
		eq(0, FakePlayerChatParsing.parseLfpLevel("level 99"), "out-of-range 99 -> 0");
	}

	private static void testLooksLikeLfp()
	{
		truth(FakePlayerChatParsing.looksLikeLfp("lfm 1 more dd"), "lfm is a party call");
		truth(FakePlayerChatParsing.looksLikeLfp("looking for a healer"), "looking for ...");
		truth(!FakePlayerChatParsing.looksLikeLfp("selling soulshots cheap"), "trade ad is not a party call");
	}

	private static void testLooksLikeTradeAd()
	{
		truth(FakePlayerChatParsing.looksLikeTradeAd("WTS soulshots"), "WTS is a trade ad");
		truth(FakePlayerChatParsing.looksLikeTradeAd("b> adena"), "b> is a trade ad");
		truth(!FakePlayerChatParsing.looksLikeTradeAd("hi there anyone around"), "chit-chat is not a trade ad");
	}

	private static void testNormalizeMeetSpot()
	{
		eq("gatekeeper", FakePlayerChatParsing.normalizeMeetSpot("gk"), "gk -> gatekeeper");
		eq("warehouse", FakePlayerChatParsing.normalizeMeetSpot(" WH "), "WH (trim/case) -> warehouse");
		eq("shop", FakePlayerChatParsing.normalizeMeetSpot("store"), "store -> shop");
		eq("cancel", FakePlayerChatParsing.normalizeMeetSpot("nvm"), "nvm -> cancel");
		eq("gatekeeper", FakePlayerChatParsing.normalizeMeetSpot("somewhere"), "unknown -> gatekeeper");
		eq("gatekeeper", FakePlayerChatParsing.normalizeMeetSpot(null), "null -> gatekeeper");
	}

	private static void testMeetTagPattern()
	{
		// The tolerant close must catch the well-formed AND the malformed variants Ollama emits.
		truth(FakePlayerChatParsing.MEET_TAG.matcher("ok [[MEET:gk]]").find(), "well-formed [[MEET:gk]]");
		truth(FakePlayerChatParsing.MEET_TAG.matcher("ok [[MEET:gk]").find(), "malformed single ] close");
		truth(FakePlayerChatParsing.MEET_TAG.matcher("ok [[MEET:gk))").find(), "malformed )) close");
		final Matcher m = FakePlayerChatParsing.MEET_TAG.matcher("sure [[MEET:warehouse]] see you");
		truth(m.find(), "capturing find");
		eq("warehouse", m.group(1), "captures the spot token");
	}

	private static void testShopTagPattern()
	{
		final Matcher m = FakePlayerChatParsing.SHOP_TAG.matcher("deal [[SHOP:SELL:soulshot:5k]]");
		truth(m.find(), "SHOP tag matches");
		eq("SELL", m.group(1).toUpperCase(), "side captured");
		eq("soulshot", m.group(2), "item captured");
		eq("5", m.group(3), "price digits captured");
		eq("k", m.group(4), "price suffix captured");
	}

	private static void testCountBefore()
	{
		// "2 dd" - the count sits just before the role word at index 2.
		eq(2, FakePlayerChatParsing.countBefore("2 dd", 2), "'2 dd' -> 2");
		eq(1, FakePlayerChatParsing.countBefore("dd", 0), "no leading number -> 1");
		eq(6, FakePlayerChatParsing.countBefore("10 tanks", 3), "10 clamps to the 6 cap");
		eq(1, FakePlayerChatParsing.countBefore("0 dd", 2), "0 clamps up to 1");
		eq(3, FakePlayerChatParsing.countBefore("3   dd", 4), "extra spaces between count and word -> 3");
	}

	private static void testParseRoleRequests()
	{
		// A count applies to the very next word only; a fresh word defaults to 1.
		List<RoleRequest> r = FakePlayerChatParsing.parseRoleRequests("2 dd healer");
		eq(2, r.size(), "'2 dd healer' -> two requests");
		req(r.get(0), "dd", 2, "first request is 2 x dd");
		req(r.get(1), "healer", 1, "second request is 1 x healer");

		// "lvl N" / "level N" / "lv N": the number is a level, not a count, and must not become a count.
		r = FakePlayerChatParsing.parseRoleRequests("lfm buffer lvl 57");
		req(last(r), "buffer", 1, "level number is not counted as a recruit count");

		// A count after a consumed level still applies to the following word.
		r = FakePlayerChatParsing.parseRoleRequests("lvl 40 2 dd");
		req(last(r), "dd", 2, "count after a level token still counts");

		// Numeric count is clamped to 6.
		req(FakePlayerChatParsing.parseRoleRequests("10 dd").get(0), "dd", 6, "count clamps to 6");

		// Plurals are emitted verbatim (caller resolves the singular).
		req(FakePlayerChatParsing.parseRoleRequests("3 mages").get(0), "mages", 3, "plural token kept verbatim");

		// A race adjective attaches to the NEXT role/class word and is not itself a request.
		r = FakePlayerChatParsing.parseRoleRequests("elf archer");
		eq(1, r.size(), "'elf archer' -> one request (race is a modifier, not a recruit)");
		reqRace(r.get(0), "archer", 1, "elf", "elf archer");
		// Two-word "dark elf" resolves to dark_elf, not plain elf.
		reqRace(FakePlayerChatParsing.parseRoleRequests("dark elf tank").get(0), "tank", 1, "dark_elf", "dark elf tank");
		// Count + race both apply to the following word.
		reqRace(FakePlayerChatParsing.parseRoleRequests("2 orc buffer").get(0), "buffer", 2, "orc", "2 orc buffer");
		// A short race alias works too.
		reqRace(FakePlayerChatParsing.parseRoleRequests("de nuker lvl 40").get(0), "nuker", 1, "de", "de nuker");
		// A race word with no following role is dropped (no phantom spawns from a bare race).
		eq(0, FakePlayerChatParsing.parseRoleRequests("elf").size(), "bare race word -> no request");
		// Race must PRECEDE the role; a trailing race does not attach.
		req(FakePlayerChatParsing.parseRoleRequests("healer elf").get(0), "healer", 1, "trailing race does not attach");
		eq(1, FakePlayerChatParsing.parseRoleRequests("healer elf").size(), "'healer elf' -> one request only");

		// Empty / null inputs are safe.
		eq(0, FakePlayerChatParsing.parseRoleRequests("").size(), "empty text -> no requests");
		eq(0, FakePlayerChatParsing.parseRoleRequests(null).size(), "null text -> no requests");
	}

	private static void testFuzzyMatching()
	{
		// Edit distance: identical, empty, and single insert/delete/substitute = 1.
		eq(0, FakePlayerChatParsing.editDistance("prophet", "prophet"), "identical -> 0");
		eq(7, FakePlayerChatParsing.editDistance("", "prophet"), "empty vs word -> length");
		eq(1, FakePlayerChatParsing.editDistance("warcyer", "warcryer"), "missing letter -> 1");
		eq(1, FakePlayerChatParsing.editDistance("prophrt", "prophet"), "one substitution -> 1");
		// Adjacent transposition costs 1 (Damerau), so "bishpo" is one typo from "bishop".
		eq(1, FakePlayerChatParsing.editDistance("bishpo", "bishop"), "adjacent transposition -> 1");

		// Length-scaled budget: short aliases are exact-only, longer names forgive one/two typos.
		eq(0, FakePlayerChatParsing.fuzzyBudget(2), "2-letter alias -> exact only");
		eq(1, FakePlayerChatParsing.fuzzyBudget(6), "6-letter word -> one typo");
		eq(2, FakePlayerChatParsing.fuzzyBudget(9), "long name -> two typos");

		// nearestWithin returns the lone closest inside budget; a tie returns null so the caller asks, not guesses.
		final List<String> cands = List.of("warcryer", "prophet", "bishop", "healer", "dancer");
		eq("warcryer", FakePlayerChatParsing.nearestWithin("warcyer", cands, 1), "typo resolves to nearest");
		eq(null, FakePlayerChatParsing.nearestWithin("zzzzzz", cands, 1), "nothing within budget -> null");
		truth(FakePlayerChatParsing.nearestWithin("xealer", List.of("healer", "dealer"), 1) == null, "ambiguous tie -> null");

		// minDistance is the closest of the whole set.
		eq(1, FakePlayerChatParsing.minDistance("warcyer", cands), "minDistance finds the 1-off candidate");
		eq(Integer.MAX_VALUE, FakePlayerChatParsing.minDistance("dd", java.util.List.of()), "empty candidates -> MAX_VALUE");
	}

	// ===== tiny assertion helpers =====

	private static RoleRequest last(List<RoleRequest> list)
	{
		return list.get(list.size() - 1);
	}

	private static void req(RoleRequest actual, String token, int count, String what)
	{
		eq(token, actual.token, what + " (token)");
		eq(count, actual.count, what + " (count)");
	}

	private static void reqRace(RoleRequest actual, String token, int count, String race, String what)
	{
		eq(token, actual.token, what + " (token)");
		eq(count, actual.count, what + " (count)");
		eq(race, actual.race, what + " (race)");
	}

	private static void eq(Object expected, Object actual, String what)
	{
		checks++;
		if ((expected == null) ? (actual != null) : !expected.equals(actual))
		{
			failures++;
			System.out.println("FAIL: " + what + " -> expected [" + expected + "] but got [" + actual + "]");
		}
	}

	private static void truth(boolean condition, String what)
	{
		checks++;
		if (!condition)
		{
			failures++;
			System.out.println("FAIL: " + what);
		}
	}
}
