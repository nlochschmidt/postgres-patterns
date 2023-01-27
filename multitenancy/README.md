# Multitenancy in Postgres

## The problem 

We have a B2B SaaS application and we want data from our customers securely separated on the database-level. 

Our assumptions are:

- Support up to 1000 customers (with 10s to 100s of users each)
- ~50 active customers per day
- <500Mb average amount of data per customer
- Frequent database schema changes due to active development

There are three options:

1. One database per customer
2. One database schema per customer
3. Single database with a discriminator column on each table

From a security standpoint, one database per customer is ideal, however it comes with a significant management overhead. Mainly that, schema changes have to be applied to all databases and applications need to pool connections for each database. Depending on the capacity of the Postgres server, it can only handle a limit amount of connections. We might therefore need to add an external connection pool from the start (like PgBouncer or AWS RDS proxy) further complicating operations.

Depending on the number of customers, one database per customer can become difficult to handle. The alternative of one schema per customer allows for re-using connection pools (we can use `set search_path` to fix the schema). However we still need to migrate all schemas individually and need to create and migrate new schemas for each new customer.

The third option has the lowest overhead. We only need to keep a single connection pool and we can run all migrations against a single table. We need to make sure that all customer queries are correctly scoped to their data. We would like to use this approach due to its simple operational model, but we want to effectively mitigate the danger of leaking data across customers 


## Using Row Level Security with Lookup Table

This approach is using Postgres' Row Level Policies introduced in Postgres 9.5. It allows us to set a policy on each table with a mandatory `WHERE` clause that will be automatically applied to all queries on that table.

```SQL
  CREATE POLICY tenant_access ON <my_table>
    FOR ALL TO tenant USING (<tenant_column> = tenant_id());
```

The `tenant_id()` method can retrieve the current tenant id from a lookup table using the current database user (role) as the key: 

```SQL
CREATE OR REPLACE FUNCTION tenant_id() RETURNS INT AS
$$
BEGIN
  RETURN (SELECT tenant_id FROM tenants WHERE database_role = current_setting('role'));
END
$$ LANGUAGE plpgsql SECURITY DEFINER;
```

The method is using `SECURITY DEFINER` so that we can enable row level security on the `tenants` table. Otherwise we would run into a recursion when selecting from `tenants`.

The `tenants` table can be modified but needs at least two fields:

```sql
CREATE TABLE tenants (
  tenant_id SERIAL PRIMARY KEY,
  database_role TEXT NOT NULL UNIQUE
);
```

I opted to use a `SERIAL` (`INT`) for the `tenant_id`, but using `UUID` is also a good option.

We also need to make sure that every `INSERT` gets the right tenant id set. For this we can use a trigger. If we now the name of the column we want to secure we can simply set the value. 

> The actual implementation in this examples doesn't assume a column name and is therefore a little bit more complicated.

```SQL
CREATE OR REPLACE FUNCTION set_tenant_id_by_database_role() RETURNS trigger AS
$$
BEGIN
  IF row_security_active(TG_TABLE_NAME) THEN
    NEW.tenant_id = tenant_id();
  END IF;
  RETURN NEW;
END
$$ LANGUAGE plpgsql;
```

There is a little bit more needed to make everything work, like revoking and granting the correct rights to the user. All the setup is hidden inside of the `enable_multitenancy_on_table(table, column)` function.

This function can be used like this

```SQL
CREATE TABLE example_data (
  tenant_id INT NOT NULL, 
  id UUID NOT NULL,
  content TEXT NOT NULL,
  PRIMARY KEY (tenant_id, id)
);
SELECT enable_multitenancy_on_table('example_data', 'tenant_id')
```

Finally, in order to create a new tenant, a tenant creation service needs to execute the below with a user that is allowed to create new roles:

```SQL
CREATE ROLE company_123 IN ROLE tenant;

INSERT INTO tenants 
  (database_role) 
VALUES 
  ('company_123');
```

Inside the service, when getting a connection from the pool, the role needs to be set using `SET ROLE company_123` and ideally reset when returning the connection to the pool using `RESET ROLE`.

### How to run

Start postgres 

```
docker-compose up -d
```

Install the functions

```
cat row-level-security-based/init.sql | docker-compose exec -T db psql -U postgres
```

Install an example schema and data

```
cat example.sql | docker-compose exec -T db psql -U postgres
```

Connect to postgres

```
docker-compose exec db psql -U postgres
```

Query data for tenant A

```
SET ROLE tenant_a;
SELECT * FROM tenants;
```

Query data for tenant B

```
SET ROLE tenant_b;
SELECT * FROM tenants;
```