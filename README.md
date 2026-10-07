Olist E-Commerce KPI Framework (SQL)
An operational KPI framework using SQL on the Olist marketplace dataset: revenue, AOV, delivery duration, and customer satisfaction broken down by category, month, and seller.

Dataset: Brazilian E-Commerce (Olist), Kaggle

Tools: SQLite, SQL (JOIN, CTE, window functions), pandas, matplotlib

Key Results (delivered orders)
Revenue: 13,221,498.11 BRL, AOV: 137.04 BRL

Average delivery time: 12.56 days, average review score: 4.16 / 5

Correlation between delivery days and review score: r = -0.585 (51 categories)

Double-counting: review join was inflating revenue by 58,338.48 BRL; resolved using CTEs

Files
queries.sql: DDL and Q1-Q10

olist.ipynb: pipeline and plots

note.md: ER sketch, join choices, Q3 reconciliation, 5 insights
