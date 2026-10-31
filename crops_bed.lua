-- CropsNH 工业农场：苗床需求表（自动生成，勿手改；要覆盖用 lua set.lua bed <作物> <等级>）
-- 来源：cropsnh-2.0.134.jar 的 ICropCard.getMinSeedBedTier + txloader 中文翻译（cropsnh_crops.*）
-- 机器等级=苗床等级 1..12 = MV/HV/EV/IV/LuV/ZPM/UV/UHV/UEV/UIV/UMV/UXV
-- 种子容量=(4*等级+11)^2：225 361 529 729 961 1225 1521 1849 2209 2601 3025 3481
-- 最低苗床 > 农场等级时机器不收种子，种子会卡在输入总线里并堵住后续作物 → 分配前必须 bed<=农场等级
-- bed=0 表示无苗床要求（注意：钻石甘蔗有垫块需求但无苗床要求，所以"有垫块≠要高苗床"）
return {
  ["Belladonna"] = { bed = 0, tier = 4 }, -- Belladonna / belladonna
  ["Cactus"] = { bed = 0, tier = 3 }, -- Cactus / cactus
  ["Carrot"] = { bed = 0, tier = 2 }, -- Carrot / carrot
  ["Cocoa"] = { bed = 0, tier = 3 }, -- Cocoa / cocoa
  ["EmberMoss"] = { bed = 0, tier = 7 }, -- EmberMoss / emberMoss
  ["GaiaWart"] = { bed = 0, tier = 5 }, -- GaiaWart / gaiaWart
  ["Garlic"] = { bed = 0, tier = 3 }, -- Garlic / garlic
  ["GlintWeed"] = { bed = 0, tier = 4 }, -- GlintWeed / glintWeed
  ["Knightmetal"] = { bed = 0, tier = 8 }, -- Knightmetal / knightmetal
  ["Lily"] = { bed = 0, tier = 1 }, -- Lily / Lily
  ["Mandrake"] = { bed = 0, tier = 4 }, -- Mandrake / mandrake
  ["Melon"] = { bed = 0, tier = 2 }, -- Melon / melon
  ["Migrator Crop"] = { bed = 0, tier = 1 }, -- Migrator Crop / migrator
  ["Moss"] = { bed = 0, tier = 4 }, -- Moss / moss
  ["Netherwart"] = { bed = 0, tier = 5 }, -- Netherwart / netherwart
  ["OreBerry"] = { bed = 0, tier = 5 }, -- OreBerry / OreBerry
  ["Potato"] = { bed = 0, tier = 1 }, -- Potato / potato
  ["Pumpkin"] = { bed = 0, tier = 2 }, -- Pumpkin / pumpkin
  ["Snowbell"] = { bed = 0, tier = 4 }, -- Snowbell / snowbell
  ["SoulSand"] = { bed = 0, tier = 2 }, -- SoulSand / soulSand
  ["SpanishMoss"] = { bed = 0, tier = 7 }, -- SpanishMoss / spanishMoss
  ["Thauminite"] = { bed = 0, tier = 7 }, -- Thauminite / thauminite
  ["Thaumium"] = { bed = 0, tier = 7 }, -- Thaumium / thaumium
  ["Tin"] = { bed = 0, tier = 4 }, -- Tin / tin
  ["Void"] = { bed = 0, tier = 7 }, -- Void / void
  ["WaterArtichoke"] = { bed = 0, tier = 4 }, -- WaterArtichoke / waterArtichoke
  ["Wheat"] = { bed = 0, tier = 1 }, -- Wheat / wheat
  ["Wolfsbane"] = { bed = 0, tier = 4 }, -- Wolfsbane / wolfsbane
  ["铂叶草"] = { bed = 3, tier = 11 }, -- Platina / platina
  ["草莓"] = { bed = 0, tier = 2 }, -- Strawberry / strawberry
  ["茶"] = { bed = 0, tier = 4 }, -- Tea / tea
  ["常春藤"] = { bed = 0, tier = 2 }, -- Ivy / ivy
  ["刺莓"] = { bed = 0, tier = 4 }, -- Stingberry / stingberry
  ["大麦"] = { bed = 0, tier = 2 }, -- Barley / barley
  ["靛蓝草"] = { bed = 0, tier = 2 }, -- Indigo / indigo
  ["凋灵甘蔗"] = { bed = 0, tier = 8 }, -- Withereed / withereed
  ["锇叶草"] = { bed = 5, tier = 12 }, -- Osmianth / osmianth
  ["恶魔之矿"] = { bed = 0, tier = 8 }, -- Evil Ore / evilOre
  ["恶作剧藤"] = { bed = 0, tier = 6 }, -- Trollplant / trollplant
  ["番茄"] = { bed = 0, tier = 4 }, -- Tomato / tomato
  ["肥料草"] = { bed = 0, tier = 3 }, -- Fertilia / fertilia
  ["甘蔗"] = { bed = 0, tier = 2 }, -- Sugar Cane / sugarCane
  ["橄榄石草"] = { bed = 0, tier = 2 }, -- Olivia / olivia
  ["钢叶草"] = { bed = 0, tier = 10 }, -- Steeleafranks / steeleafranks
  ["汉麻"] = { bed = 0, tier = 5 }, -- Hemp / hemp
  ["核能草"] = { bed = 4, tier = 12 }, -- Reactoria / reactoria
  ["黑莓"] = { bed = 0, tier = 2 }, -- Blackberry / blackberry
  ["黑木果"] = { bed = 0, tier = 2 }, -- Huckleberry / huckleberry
  ["红宝石草"] = { bed = 0, tier = 4 }, -- Rubyne / rubyne
  ["红蘑菇"] = { bed = 0, tier = 1 }, -- Red Mushroom / redMushroom
  ["红石草"] = { bed = 0, tier = 6 }, -- Redstraw / redstraw
  ["鸿运浆果丛"] = { bed = 0, tier = 6 }, -- Bobs-Yer-Uncle-Ranks / bobsYerUncleRanks
  ["化生浆果"] = { bed = 4, tier = 12 }, -- Transformium / transformium
  ["黄瓜"] = { bed = 0, tier = 4 }, -- Cucumber / cucumber
  ["黄昏莓"] = { bed = 0, tier = 4 }, -- Duskberry / duskberry
  ["活根"] = { bed = 0, tier = 8 }, -- Liveroot / liveroot
  ["火炬浆果"] = { bed = 0, tier = 2 }, -- Torchberry / torchberry
  ["火焰草"] = { bed = 0, tier = 5 }, -- Cinderpearl / cinderpearl
  ["鸡蛋草"] = { bed = 0, tier = 6 }, -- Egg Plant / eggPlant
  ["浆果"] = { bed = 0, tier = 2 }, -- Berry / bopBerry
  ["僵尸草"] = { bed = 0, tier = 3 }, -- Zomplant / zomplant
  ["金叶草"] = { bed = 0, tier = 8 }, -- Auronia / auronia
  ["金鱼草"] = { bed = 0, tier = 4 }, -- Goldfish / goldfish
  ["荊藤"] = { bed = 0, tier = 3 }, -- Thornvine / thornvine
  ["巨型仙人掌"] = { bed = 0, tier = 4 }, -- Saguaro Cactus / saguaroCactus
  ["咖啡"] = { bed = 0, tier = 7 }, -- Coffee / coffee
  ["开花藤蔓"] = { bed = 0, tier = 3 }, -- Flowering Vine / floweringVine
  ["空间之花"] = { bed = 5, tier = 13 }, -- Space Flower / spaceFlower
  ["枯萎莓"] = { bed = 0, tier = 4 }, -- Blightberry / blightberry
  ["苦力怕草"] = { bed = 0, tier = 7 }, -- Creeperweed / creeperweed
  ["辣椒"] = { bed = 0, tier = 4 }, -- Chilly / chilly
  ["蓝宝石草"] = { bed = 0, tier = 4 }, -- Sapphirum / sapphirum
  ["蓝莓"] = { bed = 0, tier = 2 }, -- Blueberry / blueberry
  ["泪之语"] = { bed = 0, tier = 8 }, -- Tearstalks / tearstalks
  ["烈焰甘蔗"] = { bed = 0, tier = 6 }, -- Blazereed / blazereed
  ["硫质草"] = { bed = 0, tier = 6 }, -- Thiosulfine / thiosulfine
  ["铝土草"] = { bed = 0, tier = 6 }, -- Bauxia / bauxia
  ["锰叶草"] = { bed = 0, tier = 12 }, -- Pyrolusium / pyrolusium
  ["棉花"] = { bed = 0, tier = 3 }, -- Cotton / cotton
  ["魔豆"] = { bed = 0, tier = 5 }, -- Mana Bean / manaBean
  ["魔力夜颠茄"] = { bed = 3, tier = 13 }, -- Magical Nightshade / magicalNightshade
  ["末影花"] = { bed = 0, tier = 10 }, -- Enderbloom / enderbloom
  ["黏性甘蔗"] = { bed = 0, tier = 4 }, -- Sticky Cane / stickyCane
  ["镍叶草"] = { bed = 0, tier = 5 }, -- Nickelback / nickelback
  ["柠檬"] = { bed = 0, tier = 4 }, -- Lemon / lemon
  ["牛奶疣"] = { bed = 0, tier = 6 }, -- Milk Wart / milkWart
  ["皮革叶"] = { bed = 0, tier = 6 }, -- Corium / corium
  ["啤酒花"] = { bed = 0, tier = 5 }, -- Hops / hops
  ["葡萄"] = { bed = 0, tier = 4 }, -- Grape / grape
  ["铅粉草"] = { bed = 0, tier = 6 }, -- Plumbshade / plumbshade
  ["铅叶草"] = { bed = 0, tier = 6 }, -- Plumbilia / plumbilia
  ["青金石草"] = { bed = 0, tier = 7 }, -- Lazulia / lazulia
  ["染墨花"] = { bed = 0, tier = 4 }, -- Inkbloom / inkbloom
  ["肉玫瑰"] = { bed = 0, tier = 7 }, -- Meatrose / meatrose
  ["桑葚"] = { bed = 0, tier = 2 }, -- Maloberry / maloberry
  ["尸骨草"] = { bed = 0, tier = 5 }, -- Corpseplant / corpseplant
  ["石榴石草"] = { bed = 0, tier = 7 }, -- Garnydinia / garnydinia
  ["石油浆果丛"] = { bed = 0, tier = 4 }, -- Oil Berry / oilBerry
  ["树莓"] = { bed = 0, tier = 2 }, -- Raspberry / raspberry
  ["水银花"] = { bed = 0, tier = 5 }, -- Shimmerleaf / shimmerleaf
  ["睡莲"] = { bed = 0, tier = 2 }, -- Water Lily / waterLily
  ["死灵花"] = { bed = 0, tier = 3 }, -- Necrobloom / necrobloom
  ["钛叶草"] = { bed = 4, tier = 9 }, -- Titania / titania
  ["藤蔓"] = { bed = 0, tier = 2 }, -- Vine / vine
  ["天罚之雷"] = { bed = 3, tier = 9 }, -- God of Thunder / godOfThunder
  ["天莓"] = { bed = 0, tier = 4 }, -- Skyberry / skyberry
  ["甜菜"] = { bed = 0, tier = 4 }, -- Sugar Beet / sugarBeet
  ["铁齿蕨"] = { bed = 0, tier = 6 }, -- Ferrofern / ferrofern
  ["铜粉草"] = { bed = 0, tier = 6 }, -- Malaxia / malaxia
  ["铜线草"] = { bed = 0, tier = 6 }, -- Coppon / coppon
  ["钨叶草"] = { bed = 4, tier = 12 }, -- Scheelinium / scheelinium
  ["芜菁"] = { bed = 0, tier = 2 }, -- Turnip / turnip
  ["锡粉草"] = { bed = 0, tier = 6 }, -- Cassitine / cassitine
  ["锡芽草"] = { bed = 0, tier = 5 }, -- Tine / tine
  ["锌叶草"] = { bed = 0, tier = 6 }, -- Galvania / galvania
  ["星际之草"] = { bed = 5, tier = 12 }, -- Stargatium / stargatium
  ["星疣"] = { bed = 4, tier = 12 }, -- Star Wart / starWart
  ["亚麻"] = { bed = 0, tier = 2 }, -- Flax / flax
  ["盐根"] = { bed = 0, tier = 4 }, -- Salty Root / saltyRoot
  ["眼球花"] = { bed = 0, tier = 1 }, -- Eyebulb / eyebulb
  ["洋葱"] = { bed = 0, tier = 4 }, -- Onion / onion
  ["野萝卜"] = { bed = 0, tier = 2 }, -- Wild Carrot / wildCarrot
  ["夜光花"] = { bed = 0, tier = 3 }, -- Glowflower / glowflower
  ["夜光珊瑚"] = { bed = 0, tier = 5 }, -- Glowing Coral / glowingCoral
  ["铱叶草"] = { bed = 5, tier = 12 }, -- Iridine / iridine
  ["银粉草"] = { bed = 0, tier = 8 }, -- Silviscus / silviscus
  ["银叶草"] = { bed = 0, tier = 7 }, -- Argentia / argentia
  ["荧光菇"] = { bed = 0, tier = 3 }, -- Glowshroom / glowshroom
  ["荧石小麦"] = { bed = 0, tier = 4 }, -- Glowheat / glowheat
  ["油菜"] = { bed = 0, tier = 4 }, -- Canola / canola
  ["元始浆果"] = { bed = 0, tier = 16 }, -- Primordial Berry / primordialBerry
  ["云母草"] = { bed = 0, tier = 9 }, -- Micadia / micadia
  ["粘液草"] = { bed = 0, tier = 6 }, -- Slimeplant / slimeplant
  ["蜘蛛咬"] = { bed = 0, tier = 4 }, -- Spidernip / spidernip
  ["纸莎草"] = { bed = 0, tier = 5 }, -- Papyrus / papyrus
  ["竹笋"] = { bed = 0, tier = 2 }, -- Bamboo Shoot / bamboo
  ["棕色蘑菇"] = { bed = 0, tier = 1 }, -- Brown Mushroom / brownMushroom
  ["钻石甘蔗"] = { bed = 0, tier = 12 }, -- Diareed / diareed

  -- ===== 英文名别名（英文客户端备案）=====
  -- 中文客户端走上面的中文名；英文客户端 label 形如 "Space Flower Seeds"，
  -- 程序去掉末尾 "Seed(s)" 后用英文名匹配。手写区，生成脚本重跑时请保留。
  ["God of Thunder"]     = { bed = 3, tier = 9 },  -- 天罚之雷
  ["Titania"]            = { bed = 4, tier = 9 },  -- 钛叶草
  ["Platina"]            = { bed = 3, tier = 11 }, -- 铂叶草
  ["Scheelinium"]        = { bed = 4, tier = 12 }, -- 钨叶草
  ["Reactoria"]          = { bed = 4, tier = 12 }, -- 核能草
  ["Iridine"]            = { bed = 5, tier = 12 }, -- 铱叶草
  ["Osmianth"]           = { bed = 5, tier = 12 }, -- 锇叶草
  ["Star Wart"]          = { bed = 4, tier = 12 }, -- 星疣
  ["Stargatium"]         = { bed = 5, tier = 12 }, -- 星际之草
  ["Transformium"]       = { bed = 4, tier = 12 }, -- 化生浆果
  ["Space Flower"]       = { bed = 5, tier = 13 }, -- 空间之花
  ["Magical Nightshade"] = { bed = 3, tier = 13 }, -- 魔力夜颠茄
}
