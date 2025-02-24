-- Custom types
-- Dealing with RBAC, multi-tenancy and audit logs for now, rather than business logic
create type public.app_permission as enum (
    --- System level permissions (only for superadmins)
    'system.all',                --- Full system access across all tenants
    'system.users.manage',       --- Can manage system-wide user settings
    'system.roles.manage',       --- Can manage default roles
    
    --- Tenant level permissions
    'tenants.all',              --- Full access within a specific tenant
    'tenants.create',           --- Can create new tenants
    'tenants.update',           --- Can update tenant settings
    'tenants.delete',           --- Can delete tenant
    'tenants.read',             --- Read-only access to tenant
    'tenants.members.assign',   --- Can invite users to tenant
    'tenants.members.remove',   --- Can remove users from tenant
    'tenants.roles.edit',       --- Can edit tenant custom roles
    'tenants.roles.create',     --- Can create tenant custom roles
    'tenants.roles.assign',     --- Can assign roles to users
    'tenants.roles.delete',     --- Can delete tenant custom roles
    'tenants.audit.view',       --- Can view audit logs
    
    --- Member management permissions
    'tenants.members.view',     --- Can view member list
    'tenants.members.invite',   --- Can send invitations
    
    --- Role viewing permissions
    'tenants.roles.view',       --- Can view roles but not modify
    
    --- Tenant specific
    'tenants.settings.view',    --- Can view tenant settings
    'tenants.settings.edit'     --- Can edit tenant settings
);

comment on type public.app_permission is 'Enumeration of all available application permissions';

--- App roles
create type public.app_role as enum (
    'administrator',
    'tenant_moderator',
    'member',
    'basic_user',
    'system_admin'
);
comment on type public.app_role is 'Enumeration of all available application roles';

--- User profiles
create table public.user_profiles (
    id uuid references auth.users on delete cascade not null primary key, --- UUID from auth.users
    first_name text,
    last_name text,
    display_name text,
    language text not null default 'en-GB' check (language ~'^[a-z]{2}(-[A-Z]{2})?$')
);

comment on table public.user_profiles is 'Public user profiles, editable by the users. Automatically created when the user is registered in the system.';

--- Tenants
create table public.tenants (
    id uuid primary key default gen_random_uuid(),
    name text unique not null check (name ~ '^[a-z]{3,10}$'),
    display_name text not null default '',
    logo_icon text not null default 'building',
    created_by uuid references auth.users on delete cascade not null,
    created_at timestamptz default now(),
    constraint valid_logo_icon check (
        logo_icon in ('building', 'briefcase', 'landmark', 'factory')
    )
);

--- Tenant members
create table public.tenant_members (
    tenant_id uuid references public.tenants on delete cascade not null,
    user_id uuid references auth.users on delete cascade not null, 
    created_at timestamptz default now(),
    unique (tenant_id, user_id)
);

-- Default role permissions
create table public.default_role_permissions (
    id uuid primary key default gen_random_uuid(),
    role app_role not null,
    permissions app_permission[],
    notes text,
    created_at timestamptz default now(),
    updated_at timestamptz default now(),
    unique(role)
);

--- Tenant user roles
create table public.tenant_user_roles (
    id uuid primary key default gen_random_uuid(),
    tenant_id uuid references public.tenants on delete cascade,
    user_id uuid references public.user_profiles on delete cascade not null,
    role app_role not null,
    role_type text check (role_type in ('default', 'custom')) not null default 'default',
    constraint tenant_user_role_unique unique (tenant_id, user_id, role),
    constraint valid_role_assignment check (
        (role_type = 'default' and role is not null)
    )
);

--- authorise with role-based access control (RBAC)
create or replace function public.authorise(
    requested_permission app_permission,
    tenant_id uuid default null
)
returns boolean as $$
declare
    current_user_id uuid;
    has_permission boolean;
begin
    current_user_id := auth.uid();
    raise log 'authorise() start - user: %, permission: %, tenant: %', 
        current_user_id, requested_permission, tenant_id;

    -- For tenant creation, we need to check system-wide roles
    if requested_permission = 'tenants.create' then
        raise log 'Checking tenants.create permission';
        
        select exists (
            select 1
            from tenant_user_roles tur
            join default_role_permissions drp on tur.role = drp.role
            where tur.user_id = current_user_id
            and tur.tenant_id is null  -- Check system-wide roles
            and tur.role_type = 'default'
        ) into has_permission;
        
        raise log 'Found matching role: %', has_permission;

        if has_permission then
            select exists (
                select 1
                from tenant_user_roles tur
                join default_role_permissions drp on tur.role = drp.role
                where tur.user_id = current_user_id
                and tur.tenant_id is null
                and tur.role_type = 'default'
                and (
                    'tenants.all' = any(drp.permissions) 
                    or 'tenants.create' = any(drp.permissions)
                )
            ) into has_permission;
            
            raise log 'Found matching permission: %', has_permission;
        end if;
        
        return has_permission;
    end if;

    -- First check for system-wide permissions
    if requested_permission::text like 'system.%' then
        select exists (
            select 1
            from tenant_user_roles tur
            join default_role_permissions drp on tur.role = drp.role
            where tur.user_id = current_user_id
            and tur.tenant_id is null
            and tur.role_type = 'default'
            and (
                'system.all' = any(drp.permissions) 
                or requested_permission = any(drp.permissions)
            )
        ) into has_permission;
        
        return has_permission;
    end if;

    -- Then check for tenant-specific permissions
    select exists (
        select 1
        from (
            -- Get permissions from default roles
            select unnest(drp.permissions) as permission
            from tenant_user_roles tur
            join default_role_permissions drp on tur.role = drp.role
            where tur.user_id = current_user_id
            and (tur.tenant_id = authorise.tenant_id or tur.tenant_id is null)
            and tur.role_type = 'default'
        ) permissions
        where permission = 'tenants.all' 
        or permission = requested_permission
    ) into has_permission;

    return has_permission;
end;
$$ language plpgsql security definer set search_path = public;

--- Indexes for frequently queried columns
create index idx_tenant_members_user_id on public.tenant_members(user_id);
create index idx_tenant_user_roles_user_id on public.tenant_user_roles(user_id);
create index idx_tenant_user_roles_tenant_user on public.tenant_user_roles(tenant_id, user_id);