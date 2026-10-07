# Olist KPI Framework: qeydlər

**Dataset:** Kaggle, `olistbr/brazilian-ecommerce` (7 cədvəl istifadə olunub)
**Baza:** SQLite (`olist.db`)
**Qayda:** KPI məntiqi SQL-dədir (`GROUP BY`, `HAVING`, `RANK()`). pandas yalnız nəticəni göstərmək, korrelyasiya və qrafik üçündür.
**Fayllar:** `queries.sql` (DDL və Q1-Q10), `olist.ipynb` (pipeline və qrafiklər), `note.md` (bu fayl).

---

## 1. ER sketch və açarlar

```
customers (PK customer_id)
    |
    | 1 ---- N
    v
orders (PK order_id, FK customer_id)
    |                          |
    | 1 ---- N                 | 1 ---- N
    v                          v
order_items                 order_reviews
(PK order_id + order_item_id)  (PK review_id + order_id)
(FK order_id, product_id,      (FK order_id)
     seller_id)
    |             |
    | N ---- 1    | N ---- 1
    v             v
products        sellers
(PK product_id) (PK seller_id)
    |
    | N ---- 1
    v
category_translation
(PK product_category_name)
```

| Cədvəl | Primary key | Foreign key | Qeyd |
|---|---|---|---|
| customers | `customer_id` | | |
| sellers | `seller_id` | | |
| category_translation | `product_category_name` | | İngilis kateqoriya adı buradadır |
| products | `product_id` | | `product_category_name` ilə tərcümə cədvəlinə bağlanır |
| orders | `order_id` | `customer_id` → customers | |
| order_items | `(order_id, order_item_id)` | `order_id`, `product_id`, `seller_id` | Bir sifarişdə bir neçə məhsul ola bilər, ona görə açar iki sütundur |
| order_reviews | `(review_id, order_id)` | `order_id` → orders | `review_id` təkbaşına unikal deyil, bir sifarişin bir neçə review-su ola bilər |

**Sətir sayları (Q1a):** orders 99,441 · order_items 112,650 · products 32,951 · order_reviews 99,224 · sellers 3,095 · customers 99,441 · category_translation 71.

**Cardinality orders → order_items (Q1b, Q1c):**
- 99,441 sifarişin 98,666-sında item var (775-də yoxdur).
- Orta item sayı **1.13** (bütün sifarişlərə bölünəndə) və **1.14** (yalnız item-i olan sifarişlərə bölünəndə).
- 88,863 sifarişdə 1 item var. 7,516 sifarişdə 2, 1,322 sifarişdə 3, qalanında 4-dən 21-ə qədər item var.
- Yəni `orders` ilə `order_items` one-to-many əlaqədədir və birləşdirəndə sifariş bir neçə sətrə çevrilir.

---

## 2. Join seçimləri və hər birinin sətir sayına təsiri

Analitik baza `analytical_base` adlı VIEW-dur (Q2). Bütün KPI sorğuları onun üzərində qurulub.

| Mərhələ | Join | Növ | Niyə bu növ | Sətir sayı |
|---|---|---|---|---|
| 1 | delivered sifarişlər | filter | Tapşırıq yalnız `order_status = 'delivered'` tələb edir | 96,478 |
| 2 | orders → order_items | **INNER** | Item-i olmayan sifarişin gəliri yoxdur, KPI üçün lazım deyil | 110,197 |
| 3 | → products | **LEFT** | Məhsul sətri çatışmasa da satış itməsin | 110,197 (dəyişmir) |
| 4 | → category_translation | **LEFT** | İngilis adı olmayan kateqoriyanın satışı itməsin | 110,197 (dəyişmir) |
| 5 | → order_reviews (xam) | **LEFT** | Review yazmayan müştərinin sifarişi də gəlirə daxildir | **110,840 (+643)** |
| 6 | → reviews_per_order (CTE) | **LEFT** | Eyni məntiq, amma review-lar əvvəlcə sifariş səviyyəsinə yığılıb | **110,197 (düzgün)** |

**Hər join nəyi səssizcə atır və ya əlavə edir:**
- `INNER JOIN order_items` item-i olmayan sifarişləri atır. Bütün bazada belə **775** sifariş var. Statuslarına görə: unavailable 603, canceled 164, created 5, invoiced 2, shipped 1. **Bunların heç biri `delivered` deyil**, ona görə delivered sifarişlərdən heç biri itmir (96,478 sifarişin hamısı KPI-larda var).
- Mərhələ 2-də sətir sayı 96,478-dən 110,197-yə qalxır. Bu, itki yox, bir sifarişdə bir neçə item olmasının nəticəsidir.
- Mərhələ 3 və 4 sətir sayını dəyişmir, yəni hər item-in tam bir məhsulu və tam bir kateqoriya sətri var.
- Mərhələ 5 sətir **əlavə edir** (+643). Bu, double-counting-in mənbəyidir (Bölmə 3).

---

## 3. Q3: Revenue reconciliation (məcburi hissə)

| | Gəlir (BRL) | Sətir |
|---|---|---|
| (a) `order_items`-dən birbaşa `SUM(price)`, yalnız delivered | 13,221,498.11 | 110,197 |
| (b) Xam review join-i ilə VIEW | 13,279,836.59 | 110,840 |
| Fərq | **+58,338.48** | **+643** |
| (b) Düzəlişdən sonra | **13,221,498.11** | **110,197** |

**Səbəb:** `LEFT JOIN order_reviews`. `orders` ilə `order_reviews` də one-to-many əlaqədədir: bəzi sifarişlərin bir neçə review-su var. Belə sifarişin hər item sətri review sayı qədər təkrarlanır və `price` bir neçə dəfə toplanır. `order_items` ilə `order_reviews` birbaşa birləşəndə item × review sayı qədər sətir yaranır.

**Həll:** review-ları join-dən **əvvəl** CTE-də `GROUP BY order_id` ilə yığmaq (`AVG(review_score)`). Beləcə hər sifarişin yalnız 1 review sətri olur və item sətirləri təkrarlanmır. Düzəlişdən sonra (a) = (b).

**Əlavə qayda:** item səviyyəsində sətirlər çatdırılma gününü və review-nu təkrarlayır. Ona görə ortalamaları hesablamazdan əvvəl sorğular bir sətir/sifariş səviyyəsinə yığılır (kateqoriya sorğularında sifariş + kateqoriya, satıcı sorğusunda sifariş + satıcı).

---

## 4. Əsas nəticələr (yalnız delivered sifarişlər)

**Q4: ümumi KPI-lar**

| KPI | Dəyər |
|---|---|
| Sifariş sayı | 96,478 |
| Ümumi gəlir | 13,221,498.11 BRL |
| AOV | 137.04 BRL |
| Orta çatdırılma | 12.56 gün |
| Orta review | 4.16 / 5 |

**Q5: gəlirə görə kateqoriyalar.** 72 sətir var (71 kateqoriya və `unknown`). İlk 3: health_beauty 1,233,131.72 · watches_gifts 1,166,176.98 · bed_bath_table 1,023,434.76. `watches_gifts`-in AOV-si ən yüksəkdir (212.23).

**Q6: aylıq trend.** 23 ay (2016-09 ilə 2018-08 arası). Ən yüksək gəlir 2017-11-də (987,765.37 BRL, 7,289 sifariş), 2018-05 və 2018-04 də 970,000 BRL ətrafındadır.

**Q7: gəlirə görə top/bottom 5.** Top 5: health_beauty, watches_gifts, bed_bath_table, sports_leisure, computers_accessories. Bottom 5: security_and_services (2 sifariş, 283.29 BRL), fashion_childrens_clothes (7), cds_dvds_musicals (12), home_comfort_2 (24), flowers (29). Bottom 5 kateqoriyaların sifariş sayı çox azdır, ona görə yalnız gəlirə görə sıralamada rast gəlinir.

**Q8: review-ya görə top/bottom 5 (`HAVING COUNT(DISTINCT order_id) >= 100`).** Top 5: books_general_interest 4.53, food_drink 4.45, books_technical 4.43, luggage_accessories 4.37, food 4.33. Bottom 5: office_furniture 3.64, fashion_male_clothing 3.82, audio 3.84, home_confort 3.89, construction_tools_safety 3.97. `HAVING` kiçik kateqoriyaları (məsələn, security_and_services) çıxarıb.

**Q9: satıcılar.** 2,970 satıcının delivered sifarişi var. Top 10 satıcı cəmi 1,754,800.00 BRL gətirir, bu, ümumi gəlirin **13.3%-ni** təşkil edir.

**Q10 və korrelyasiya (51 kateqoriya, >= 100 sifariş):** çatdırılma günü ilə review score arasında Pearson r = **-0.585**, Spearman r = **-0.509**. **Bəli**, yavaş çatdırılan kateqoriyalar orta hesabla daha aşağı review alır. r² ≈ 0.34, yəni kateqoriyalar arasında review fərqinin təxminən üçdə biri çatdırılma müddəti ilə izah olunur. Bu, kateqoriya səviyyəsində əlaqədir və səbəb-nəticə sübut etmir (məsələn, iri gabaritli məhsullar həm gec çatır, həm də məhsulun özü review-ya təsir edir).

**Məhdudiyyətlər**
- 2016-09 və 2016-12 aylarında cəmi 1 sifariş var, onlara trend kimi baxmaq olmaz (review 1.00 və 5.00 bir sifarişdən gəlir).
- 2018-08-dəki 7.73 gün çatdırılma real yaxşılaşma deyil. Datada yalnız artıq çatdırılmış sifarişlər var, gec çatanlar hələ daxil deyil.

---

## 5. Operational insights

1. **Pik aylarda çatdırılma pisləşir (Q6).** 2017-10-da 4,478 sifariş, 11.86 gün, review 4.21 olub. 2017-11-də sifariş sayı 7,289-a qalxıb, çatdırılma 15.16 günə çıxıb, review 3.99-a düşüb. *Tövsiyə:* pik aylar üçün logistika gücünü əvvəlcədən artırmaq.

2. **2018-ci ilin fevral-mart dövrü ən zəif dövrdür (Q6).** Çatdırılma 16.95 və 16.30 gün, review 3.88 və 3.81 (bütün aylar içində ən aşağı). 2018-04-də çatdırılma 11.50 günə düşüb, review 4.21-ə qayıdıb. *Tövsiyə:* bu dövrdə nə baş verdiyini (daşıyıcı, anbar, hava) araşdırmaq.

3. **Yavaş çatdırılan kateqoriyalar aşağı review alır (Q10).** Pearson r = -0.585, Spearman r = -0.509 (51 kateqoriya). Ən sürətli kateqoriya food (9.79 gün) review 4.33 alır. *Tövsiyə:* çatdırılma vədini (SLA) düzgün qurmaq və uzun çatdırılan kateqoriyalarda prosesi sürətləndirmək, çünki bu, review yaxşılaşdırmaq üçün ən birbaşa yoldur.

4. **Bir böyük satıcı keyfiyyət riskidir (Q9).** Gəlirə görə 5-ci satıcı (`7c67e144...`): 973 sifariş, 186,570.05 BRL gəlir, amma çatdırılma 22.34 gün və review 3.50. Top 10-un qalan satıcılarında çatdırılma 10.77-15.06 gün arasındadır. Top 10 satıcı gəlirin 13.3%-ni verir, ona görə bir satıcının problemi nəzərəçarpan təsir edir. *Tövsiyə:* bu satıcı ilə performans razılaşması bağlamaq.

5. **`office_furniture` böyük həcmli problem kateqoriyadır (Q8, Q5).** 1,254 sifariş, review 3.64. Bu, 100+ sifarişi olan kateqoriyalar içində ən aşağıdır, ümumi göstərici isə 4.16-dır. Eyni zamanda `furniture_decor`-un çatdırılması 13.07 gündür, ümumi göstərici 12.56-dır. *Tövsiyə:* iri gabaritli məhsullar üçün ayrıca qablaşdırma və çatdırılma prosesi.
