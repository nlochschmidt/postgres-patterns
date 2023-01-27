CREATE ROLE tenant_a IN ROLE tenant;
CREATE ROLE tenant_b IN ROLE tenant;
CREATE ROLE tenant_c IN ROLE tenant;

INSERT INTO tenants 
  (display_name, database_role) 
VALUES 
  ('Tenant A', 'tenant_a'),
  ('Tenant B', 'tenant_b'),
  ('Tenant C', 'tenant_c');

