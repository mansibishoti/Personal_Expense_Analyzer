CREATE DATABASE IF NOT EXISTS expense_analyzer;
USE expense_analyzer;
CREATE TABLE IF NOT EXISTS `User` (           -- table user stores the info about the user
    user_id       INT AUTO_INCREMENT PRIMARY KEY,
    username      VARCHAR(50)  NOT NULL UNIQUE,
    email         VARCHAR(100) NOT NULL UNIQUE,
    password_hash VARCHAR(255) NOT NULL
);
CREATE TABLE IF NOT EXISTS Category (                        -- category like food,travel etc
    category_id   INT AUTO_INCREMENT PRIMARY KEY,
    category_name VARCHAR(50) NOT NULL UNIQUE
);
CREATE TABLE IF NOT EXISTS Expense (                      -- stores the data about the expense made for each category
    expense_id   INT AUTO_INCREMENT PRIMARY KEY,
    user_id      INT NOT NULL,
    category_id  INT NOT NULL,
    amount       DECIMAL(10,2) NOT NULL CHECK (amount > 0),
    expense_date DATE NOT NULL,
    description  VARCHAR(200),
    FOREIGN KEY (user_id)     REFERENCES `User`(user_id)     ON DELETE CASCADE,
    FOREIGN KEY (category_id) REFERENCES Category(category_id)
);
CREATE TABLE IF NOT EXISTS Budget (            -- sets a budget for each month with userid,categoryid and timestamp
    budget_id     INT AUTO_INCREMENT PRIMARY KEY,
    user_id       INT NOT NULL,
    category_id   INT NOT NULL,
    budget_month  DATE NOT NULL COMMENT 'always the 1st day of the month',
    budget_amount DECIMAL(10,2) NOT NULL CHECK (budget_amount > 0),
    created_at    TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    UNIQUE KEY uq_budget (user_id, category_id, budget_month),
    FOREIGN KEY (user_id)     REFERENCES `User`(user_id)     ON DELETE CASCADE,
    FOREIGN KEY (category_id) REFERENCES Category(category_id)
);

CREATE TABLE IF NOT EXISTS Savings_Goal (              -- sets a goal to be saved with a target date and status whether its completed or ongoing
    goal_id       INT AUTO_INCREMENT PRIMARY KEY,
    user_id       INT NOT NULL,
    goal_name     VARCHAR(100) NOT NULL,
    target_amount DECIMAL(10,2) NOT NULL CHECK (target_amount > 0),
    saved_amount  DECIMAL(10,2) NOT NULL DEFAULT 0 CHECK (saved_amount >= 0),
    target_date   DATE,
    status        ENUM('IN_PROGRESS','COMPLETED') NOT NULL DEFAULT 'IN_PROGRESS',
    completed_on  DATE NULL,
    FOREIGN KEY (user_id) REFERENCES `User`(user_id) ON DELETE CASCADE
);

-- table holds the data whnever user surpasses the target budget for the month and alert is to be generated
CREATE TABLE IF NOT EXISTS Budget_Alert (
    alert_id      INT AUTO_INCREMENT PRIMARY KEY,
    budget_id     INT NOT NULL UNIQUE,
    user_id       INT NOT NULL,
    alert_message VARCHAR(255) NOT NULL,
    alert_time    TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    is_read       BOOLEAN NOT NULL DEFAULT FALSE,
    FOREIGN KEY (budget_id) REFERENCES Budget(budget_id) ON DELETE CASCADE,
    FOREIGN KEY (user_id)   REFERENCES `User`(user_id)   ON DELETE CASCADE
);

CREATE OR REPLACE VIEW Budget_Status AS
SELECT  b.budget_id,
        b.user_id,
        b.category_id,
        c.category_name,
        b.budget_month,
        b.budget_amount,
        COALESCE(SUM(e.amount), 0)                          AS spent,
        b.budget_amount - COALESCE(SUM(e.amount), 0)        AS remaining,
        ROUND(COALESCE(SUM(e.amount), 0) / b.budget_amount * 100, 2) AS percent_used
FROM    Budget b
JOIN    Category c ON c.category_id = b.category_id
LEFT JOIN Expense e
        ON  e.user_id     = b.user_id
        AND e.category_id = b.category_id
        AND e.expense_date >= b.budget_month
        AND e.expense_date <  DATE_ADD(b.budget_month, INTERVAL 1 MONTH)
GROUP BY b.budget_id, b.user_id, b.category_id, c.category_name,
         b.budget_month, b.budget_amount;

-- ---------------------------------------------------------------------
-- 3. TRIGGER: auto-complete a goal when saved_amount reaches the target
-- ---------------------------------------------------------------------
DROP TRIGGER IF EXISTS trg_goal_completion;
DELIMITER //
CREATE TRIGGER trg_goal_completion
BEFORE UPDATE ON Savings_Goal
FOR EACH ROW
BEGIN
    IF NEW.saved_amount >= NEW.target_amount AND OLD.status = 'IN_PROGRESS' THEN
        SET NEW.status       = 'COMPLETED';
        SET NEW.completed_on = CURDATE();
    END IF;
END//
DELIMITER ;

-- 4. SAMPLE QUERIES  

--  SET BUDGET 
INSERT INTO Budget (user_id, category_id, budget_month, budget_amount)
VALUES (1, 2, '2026-10-01', 5000.00)
ON DUPLICATE KEY UPDATE budget_amount = VALUES(budget_amount);

-- UPDATE BUDGET
UPDATE Budget
SET    budget_amount = 6000.00
WHERE  user_id = 1
  AND  category_id = 2
  AND  budget_month = '2026-10-01';

-- REMAINING BUDGET
SELECT category_name, budget_amount, spent, remaining, percent_used
FROM   Budget_Status
WHERE  user_id = 1
  AND  budget_month = '2026-10-01'
ORDER BY remaining ASC;

-- BUDGET EXCEEDED :(categories where spending crossed the limit)
SELECT category_name, budget_amount, spent,
       spent - budget_amount AS over_by
FROM   Budget_Status
WHERE  user_id = 1
  AND  budget_month = '2026-10-01'
  AND  spent > budget_amount;

-- 4.5 SAVINGS PROGRESS
SELECT goal_name,
       target_amount,
       saved_amount,
       target_amount - saved_amount                           AS still_needed,
       LEAST(ROUND(saved_amount / target_amount * 100, 2), 100) AS percent_done,
       target_date,
       status
FROM   Savings_Goal
WHERE  user_id = 1
ORDER BY percent_done DESC;

-- 4.5b Add money to a goal (this fires the completion trigger when needed)
UPDATE Savings_Goal
SET    saved_amount = saved_amount + 1000.00
WHERE  goal_id = 1;

--  GOAL COMPLETION
UPDATE Savings_Goal
SET    status = 'COMPLETED', completed_on = CURDATE()
WHERE  goal_id > 0
  AND  saved_amount >= target_amount
  AND  status = 'IN_PROGRESS';

-- list completed goals
SELECT goal_name, target_amount, saved_amount, completed_on
FROM   Savings_Goal
WHERE  user_id = 1
  AND  status = 'COMPLETED'
ORDER BY completed_on DESC;

SELECT * from user;
SELECT * from Category;
SELECT * from Budget;
SELECT * from expense;

-- SAMPLE DATA FOR TESTING 
INSERT INTO `User` (username, email, password_hash) VALUES ('mansi', 'mansi1523@mail.com', 'x');
INSERT INTO Category (category_name) VALUES('Miscellaneous');
INSERT INTO Budget (user_id, category_id, budget_month, budget_amount) VALUES (3, 4, '2026-11-01', 3000);
INSERT INTO Expense (user_id, category_id, amount, expense_date)VALUES (3, 3, 1800, '2026-11-10');
INSERT INTO Expense (user_id, category_id, amount, expense_date)VALUES (3, 4, 1500, '2026-10-12');
INSERT INTO Savings_Goal (user_id, goal_name, target_amount, saved_amount)VALUES (3, 'Digicam', 50000, 42000);

SELECT * from savings_goal;

USE expense_analyzer;

INSERT INTO Expense (user_id, category_id, amount, expense_date)
VALUES (3, 4, 1500, '2026-11-15');
SELECT * FROM Budget_Alert;
SELECT * FROM Budget_Status WHERE user_id = 3;
INSERT INTO Expense (user_id, category_id, amount, expense_date)VALUES (3, 4, 1800, '2026-11-10');
--    INSERT INTO Expense (user_id, category_id, amount, expense_date)VALUES (3, 4, 3500, '2026-11-10');          budget is pushed over limit and and an alert will be raised in the python file