-- Create a role that all tenants will inherit from
CREATE ROLE tenant WITH LOGIN PASSWORD 'secret';

-- Basic tables

CREATE TABLE tenants (
  tenant_id SERIAL PRIMARY KEY,
  display_name TEXT NOT NULL,
  database_role TEXT NOT NULL UNIQUE
);

CREATE TABLE tenant_domains (
  tenant_id INT NOT NULL,
  fqdn TEXT NOT NULL UNIQUE
);

-- Lookup function for tenant id

CREATE OR REPLACE FUNCTION tenant_id() RETURNS INT AS
$$
BEGIN
  RETURN (SELECT tenant_id FROM tenants WHERE database_role = current_setting('role'));
END
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- Trigger function for writing discriminator column
CREATE OR REPLACE FUNCTION set_tenant_id_by_database_role() RETURNS trigger AS
$$
DECLARE
	discriminator_column TEXT = TG_ARGV[0];
BEGIN
  IF row_security_active(TG_TABLE_NAME) THEN
    RETURN json_populate_record(NEW, json_build_object(discriminator_column, tenant_id()));
  END IF;
  RETURN NEW;
END
$$ LANGUAGE plpgsql;

-- Function to enable the tenant isolation for both read and write access to the given table for all users with role tenant
CREATE OR REPLACE FUNCTION enable_multitenancy_on_table(target regclass, discriminator_column TEXT) RETURNS BOOLEAN AS
$$
DECLARE
  sequence TEXT;
BEGIN

  -- Check preconditions

  IF NOT EXISTS (SELECT FROM information_schema.columns WHERE table_name = target::text AND column_name = discriminator_column) THEN
    RAISE EXCEPTION 'column "%" does not exist on table "%"', discriminator_column, target;
  END IF;

  IF (SELECT is_nullable FROM information_schema.columns WHERE table_name = target::text AND column_name = discriminator_column) THEN
    RAISE EXCEPTION 'discriminator column "%I" on table "%s" must not be nullable', discriminator_column, target;
  END IF;

  SET LOCAL client_min_messages = warning;

  -- Install trigger to write discriminator column

  EXECUTE format('DROP TRIGGER IF EXISTS set_tenant_id ON %s', target);
  EXECUTE format('CREATE TRIGGER set_tenant_id BEFORE INSERT ON %s
    FOR EACH ROW EXECUTE PROCEDURE set_tenant_id_by_database_role(%I)',target, discriminator_column);

  -- Create row-level security policies

  EXECUTE format('ALTER TABLE %s ENABLE ROW LEVEL SECURITY', target);
  EXECUTE format('CREATE POLICY tenant_access ON %s
    FOR ALL TO tenant USING (%I = tenant_id())', target, discriminator_column);

  -- Grant necessary rights to users inheriting from tenant role

  EXECUTE format('REVOKE ALL ON %s FROM tenant', target);
  EXECUTE format('GRANT SELECT, INSERT, UPDATE, DELETE ON %s TO tenant', target);

  FOR sequence IN
    SELECT maybe_sequence AS sequence
    FROM (SELECT pg_get_serial_sequence(target::text, discriminator_column) AS maybe_sequence
          FROM information_schema.columns
          WHERE table_name = target::text) AS sequences
    WHERE maybe_sequence IS NOT NULL
  LOOP
    EXECUTE format('GRANT USAGE ON SEQUENCE %s TO tenant', sequence);
  END LOOP;

  RESET client_min_messages;
	
  RETURN TRUE;
END
$$ LANGUAGE plpgsql;

SELECT enable_multitenancy_on_table('tenants', 'tenant_id');
SELECT enable_multitenancy_on_table('tenant_domains', 'tenant_id');