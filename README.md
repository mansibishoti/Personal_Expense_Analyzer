These module manages budgets and savings goals using MySQL and Python. 
It calculates spending, tracks budget utilization, detects overspending, and generates alerts through a background monitoring system.

budget_savings.sql — Creates budget and savings tables, the Budget_Status view, a trigger, and SQL queries.
budget_monitor.py — Monitors budgets in the background using two threads and a queue to process alerts.

Technologies:
Python 3.9+
MySQL 8.x
mysql-connector-python
OS concepts: Multithreading, synchronization, scheduling, and inter-thread communication.
