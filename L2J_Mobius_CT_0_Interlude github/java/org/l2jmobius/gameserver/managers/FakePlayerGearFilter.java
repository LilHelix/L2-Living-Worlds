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
package org.l2jmobius.gameserver.managers;

import java.util.HashSet;
import java.util.Set;

import org.l2jmobius.gameserver.data.xml.BuyListData;
import org.l2jmobius.gameserver.model.buylist.BuyListHolder;
import org.l2jmobius.gameserver.model.buylist.Product;
import org.l2jmobius.gameserver.model.item.ItemTemplate;

/**
 * Allow-list of item ids that fake players and phantoms may wear, sourced from the <b>GM shop's gear buy-lists</b>
 * (the ones the {@code data/html/admin/gmstore/gear/**} panels open via {@code admin_buy}). That union is a
 * hand-curated, render-safe set of player equipment:
 * <ul>
 * <li>pet/summon gear lives in the GM shop's separate Pet Section, so it is <b>not</b> in these lists - no
 * pet/monster deny-list needed;</li>
 * <li>armor pieces with no model for some race (e.g. "Tunic of Mana", which is invisible on an Orc mystic) were
 * deliberately left out of the GM gear lists, so drawing only from here <b>needs no race-specific skip</b>.</li>
 * </ul>
 * The only residue is a handful of NPC weapons named "Monster Only(...)" that sit in the weapon lists; those are
 * dropped by name when the allow-list is built.
 * <p>
 * The allow-list is resolved lazily from {@link BuyListData} (already loaded at start-up) the first time gear is
 * built, so it stays in sync automatically if a buy-list is edited. If a listed buy-list id is missing it is
 * skipped. The set is only cached once it is non-empty, so a premature call (before BuyListData finished loading)
 * fails soft and rebuilds on the next call rather than caching an empty allow-list.
 */
public class FakePlayerGearFilter
{
	// GM shop weapon/armor/jewel buy-list ids, from data/html/admin/gmstore/gear/** (admin_buy <id>).
	private static final int[] GEAR_BUYLISTS =
	{
		9001, 9002, 9003, 9004, 9005, 9006, 9007, 9008, 9009, 9010, //
		9011, 9012, 9013, 9014, 9015, 9016, 9017, 9018, 9019, 9020, //
		9021, 9022, 9023, 9024, 9025, 9026, 9027, 9028, 9029, 9030, //
		9031, 9032, 9033, 9034, 9035, 9036, 9037, 9038, 9039, 9040, //
		9041, 9042, 9043, 9044, 9045, 9046, 9047, 9048, 9049, 9050, //
		9051, 9052, 9053, 9917, 9925, 9951, 9952, 9953, 9954, 9955, //
		9956, 9959, 9960, 9961, 9962, 9963, 9964, 9965, 9980, 9997, 9998
	};

	// Gap-fillers: the GM gear lists have NO no-grade heavy armor and NO no-grade shield, so a low-level heavy
	// role had nothing heavy to wear (it fell back to leather). These are the standard no-grade heavy pieces
	// (Bronze set + Bone Shield) - render-safe player gear - added so a no-grade tank/warrior looks heavy.
	private static final int[] EXTRA_ALLOWED =
	{
		26, // Bronze Breastplate (heavy chest)
		34, // Bronze Gaiters (heavy legs)
		46, // Bronze Helmet
		625 // Bone Shield
	};

	private static volatile Set<Integer> _allowed = null;
	private static volatile int _version = 0;

	private FakePlayerGearFilter()
	{
	}

	/**
	 * Invalidates the allow-list after {@link BuyListData} finishes loading. Dependent gear caches compare
	 * {@link #getVersion()} before use and rebuild lazily when this version changes.
	 */
	public static synchronized void onBuyListsReloaded()
	{
		_allowed = null;
		_version++;
	}

	/** @return the current allow-list generation used by dependent caches. */
	public static int getVersion()
	{
		return _version;
	}

	private static Set<Integer> allowed()
	{
		Set<Integer> set = _allowed;
		if (set != null)
		{
			return set;
		}
		synchronized (FakePlayerGearFilter.class)
		{
			set = _allowed;
			if (set != null)
			{
				return set;
			}
			final Set<Integer> built = new HashSet<>(2048);
			for (int listId : GEAR_BUYLISTS)
			{
				final BuyListHolder buyList = BuyListData.getInstance().getBuyList(listId);
				if (buyList == null)
				{
					continue;
				}
				for (Product product : buyList.getProducts())
				{
					final ItemTemplate item = product.getItem();
					if ((item != null) && !item.getName().contains("Monster Only")) // drop NPC weapons that leaked into the gear lists
					{
						built.add(item.getId());
					}
				}
			}
			if (built.isEmpty()) // BuyListData not ready yet - don't cache an empty allow-list, retry next call
			{
				return built;
			}
			for (int id : EXTRA_ALLOWED) // fill the no-grade heavy / shield gap the GM lists leave
			{
				built.add(id);
			}
			_allowed = built;
			return built;
		}
	}

	/** @return {@code true} if {@code itemId} is player gear the GM shop sells (safe to render on any race/class). */
	public static boolean isPlayerGear(int itemId)
	{
		return allowed().contains(itemId);
	}

	/** @return {@code true} if {@code item} is player gear the GM shop sells (safe to render on any race/class). */
	public static boolean isPlayerGear(ItemTemplate item)
	{
		return (item != null) && allowed().contains(item.getId());
	}
}
