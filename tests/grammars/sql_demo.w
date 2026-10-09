# wbuild: target=grammars_sql_test tag=tests dep=grammars_parser_generator
# wbuild: step="bin/parser_generator_grammars libs/extras/grammars/sql.pg -o bin/generated_grammars_sql_parser.w"
# wbuild: step="bin/wv2 tests/grammars/sql_demo.w -o bin/grammars_sql_demo"
# wbuild: step="bin/grammars_sql_demo"
/*
Demo/test for the hand-written SQL grammar (libs/extras/grammars/sql.pg):
clean parses of the covered statement shapes plus inputs it must reject.
*/
import libs.extras.grammars.matchers
import bin.generated_grammars_sql_parser
import tests.grammars.grammar_demo


int main():
	grammar_demo_begin(sql_parse, c"demo.sql")
	expect_clean(c"SELECT * FROM users;")
	expect_clean(c"SELECT id, name AS full_name FROM users WHERE active = 1;")
	expect_clean(c"SELECT u.id, COUNT(*) FROM users AS u INNER JOIN orders o ON u.id = o.user_id GROUP BY u.id HAVING COUNT(*) > 1 ORDER BY u.id DESC LIMIT 10 OFFSET 5;")
	expect_clean(c"SELECT * FROM a LEFT OUTER JOIN b ON a.id = b.a_id WHERE a.name LIKE 'A%' AND (a.score BETWEEN 1 AND 10 OR a.score IS NULL);")
	expect_clean(c"SELECT CASE WHEN score > 90 THEN 'A' WHEN score > 80 THEN 'B' ELSE 'C' END FROM grades;")
	expect_clean(c"SELECT * FROM users WHERE id IN (SELECT user_id FROM orders WHERE total > 100);")
	expect_clean(c"SELECT CAST(id AS TEXT) FROM users;")
	expect_clean(c"INSERT INTO users (id, name) VALUES (1, 'Ada'), (2, 'Grace');")
	expect_clean(c"INSERT INTO archive SELECT * FROM users WHERE active = 0;")
	expect_clean(c"UPDATE users SET active = 0, name = 'x' WHERE id = 1;")
	expect_clean(c"DELETE FROM users WHERE id = 1;")
	expect_clean(c"CREATE TABLE users (id INT PRIMARY KEY, name VARCHAR(255) NOT NULL, email VARCHAR(255) UNIQUE, CONSTRAINT fk_role FOREIGN KEY (role_id) REFERENCES roles (id));")
	expect_clean(c"CREATE UNIQUE INDEX idx_users_email ON users (email);")
	expect_clean(c"CREATE VIEW active_users AS SELECT * FROM users WHERE active = 1;")
	expect_clean(c"DROP TABLE IF EXISTS users;")
	expect_clean(c"ALTER TABLE users ADD COLUMN age INT;")
	expect_clean(c"ALTER TABLE users RENAME TO people;")
	expect_clean(c"SELECT 1 + 2 * 3, (1 + 2) * 3, 'a' || 'b';")
	expect_clean(c"SELECT * FROM users; -- trailing line comment\n")
	expect_clean(c"-- leading comment\nSELECT id FROM users WHERE name = 'O''Brien';")
	expect_clean(c"SELECT 'it''s fine' AS msg FROM dual;")

	expect_errors(c"SELECT FROM users;")
	expect_errors(c"SELEC * FROM users;")
	expect_errors(c"CREATE TABLE (id INT);")
	expect_errors(c"INSERT INTO users VALUES 1, 2;")

	return grammar_demo_finish()
