SET statement_timeout = 0;
SET lock_timeout = 0;
SET idle_in_transaction_session_timeout = 0;
SET transaction_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SELECT pg_catalog.set_config('search_path', '', false);
SET check_function_bodies = false;
SET xmloption = content;
SET client_min_messages = warning;
SET row_security = off;

SET default_tablespace = '';

SET default_table_access_method = heap;

--
-- Name: active_storage_attachments; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.active_storage_attachments (
    id bigint NOT NULL,
    tenant_id bigint DEFAULT (NULLIF(current_setting('uris.tenant_id'::text, true), ''::text))::bigint NOT NULL,
    name character varying NOT NULL,
    record_type character varying NOT NULL,
    record_id bigint NOT NULL,
    blob_id bigint NOT NULL,
    created_at timestamp(6) without time zone NOT NULL
);

ALTER TABLE ONLY public.active_storage_attachments FORCE ROW LEVEL SECURITY;


--
-- Name: active_storage_attachments_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.active_storage_attachments_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: active_storage_attachments_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.active_storage_attachments_id_seq OWNED BY public.active_storage_attachments.id;


--
-- Name: active_storage_blobs; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.active_storage_blobs (
    id bigint NOT NULL,
    tenant_id bigint DEFAULT (NULLIF(current_setting('uris.tenant_id'::text, true), ''::text))::bigint NOT NULL,
    key character varying NOT NULL,
    filename character varying NOT NULL,
    content_type character varying,
    metadata text,
    service_name character varying NOT NULL,
    byte_size bigint NOT NULL,
    checksum character varying,
    created_at timestamp(6) without time zone NOT NULL
);

ALTER TABLE ONLY public.active_storage_blobs FORCE ROW LEVEL SECURITY;


--
-- Name: active_storage_blobs_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.active_storage_blobs_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: active_storage_blobs_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.active_storage_blobs_id_seq OWNED BY public.active_storage_blobs.id;


--
-- Name: active_storage_variant_records; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.active_storage_variant_records (
    id bigint NOT NULL,
    tenant_id bigint DEFAULT (NULLIF(current_setting('uris.tenant_id'::text, true), ''::text))::bigint NOT NULL,
    blob_id bigint NOT NULL,
    variation_digest character varying NOT NULL
);

ALTER TABLE ONLY public.active_storage_variant_records FORCE ROW LEVEL SECURITY;


--
-- Name: active_storage_variant_records_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.active_storage_variant_records_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: active_storage_variant_records_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.active_storage_variant_records_id_seq OWNED BY public.active_storage_variant_records.id;


--
-- Name: analyses; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.analyses (
    id bigint NOT NULL,
    tenant_id bigint NOT NULL,
    feed_id bigint NOT NULL,
    reference_id bigint,
    cause character varying NOT NULL,
    status character varying DEFAULT 'queued'::character varying NOT NULL,
    steps jsonb DEFAULT '{}'::jsonb NOT NULL,
    turns jsonb DEFAULT '[]'::jsonb NOT NULL,
    logs text,
    lines integer DEFAULT 0 NOT NULL,
    error character varying,
    started_at timestamp(6) without time zone,
    finished_at timestamp(6) without time zone,
    deadline timestamp(6) without time zone,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    question text,
    requested_by character varying,
    about_id bigint
);

ALTER TABLE ONLY public.analyses FORCE ROW LEVEL SECURITY;


--
-- Name: analyses_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.analyses_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: analyses_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.analyses_id_seq OWNED BY public.analyses.id;


--
-- Name: ar_internal_metadata; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.ar_internal_metadata (
    key character varying NOT NULL,
    value character varying,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL
);


--
-- Name: audit_events; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.audit_events (
    id bigint NOT NULL,
    tenant_id bigint NOT NULL,
    actor character varying NOT NULL,
    actor_name character varying,
    via character varying,
    analysis_id bigint,
    feed_id bigint,
    told character varying,
    channel character varying NOT NULL,
    action character varying NOT NULL,
    status character varying NOT NULL,
    scope character varying,
    remote_ip character varying,
    request_id character varying,
    duration_ms integer,
    detail character varying,
    arguments jsonb DEFAULT '{}'::jsonb NOT NULL,
    created_at timestamp(6) without time zone NOT NULL
);

ALTER TABLE ONLY public.audit_events FORCE ROW LEVEL SECURITY;


--
-- Name: audit_events_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.audit_events_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: audit_events_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.audit_events_id_seq OWNED BY public.audit_events.id;


--
-- Name: feed_edges; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.feed_edges (
    id bigint NOT NULL,
    tenant_id bigint NOT NULL,
    a_id bigint NOT NULL,
    b_id bigint NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    inferred boolean DEFAULT false NOT NULL,
    CONSTRAINT feed_edges_are_canonical CHECK ((a_id < b_id))
);

ALTER TABLE ONLY public.feed_edges FORCE ROW LEVEL SECURITY;


--
-- Name: feed_edges_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.feed_edges_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: feed_edges_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.feed_edges_id_seq OWNED BY public.feed_edges.id;


--
-- Name: feed_references; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.feed_references (
    id bigint NOT NULL,
    tenant_id bigint NOT NULL,
    feed_id bigint NOT NULL,
    resource_id bigint NOT NULL,
    role character varying DEFAULT 'original'::character varying NOT NULL,
    locator jsonb DEFAULT '{}'::jsonb NOT NULL,
    locator_key character varying,
    mime character varying,
    size bigint,
    digest character varying,
    version character varying,
    source_version character varying,
    changed_at timestamp(6) without time zone,
    analyzed_at timestamp(6) without time zone,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    seen_at timestamp(6) without time zone,
    gone_at timestamp(6) without time zone,
    kept_apart boolean DEFAULT false NOT NULL
);

ALTER TABLE ONLY public.feed_references FORCE ROW LEVEL SECURITY;


--
-- Name: feed_references_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.feed_references_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: feed_references_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.feed_references_id_seq OWNED BY public.feed_references.id;


--
-- Name: feeds; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.feeds (
    id bigint NOT NULL,
    tenant_id bigint NOT NULL,
    type character varying NOT NULL,
    key character varying NOT NULL,
    title character varying,
    note text,
    parent_id bigint,
    origin character varying DEFAULT 'resource'::character varying NOT NULL,
    embedding double precision[],
    embedded_digest character varying,
    embedded_at timestamp(6) without time zone,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    timeout integer,
    expires_at timestamp(6) without time zone,
    passages_digest character varying
);

ALTER TABLE ONLY public.feeds FORCE ROW LEVEL SECURITY;


--
-- Name: feeds_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.feeds_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: feeds_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.feeds_id_seq OWNED BY public.feeds.id;


--
-- Name: gates; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.gates (
    id bigint NOT NULL,
    tenant_id bigint NOT NULL,
    key character varying NOT NULL,
    reference_type character varying,
    reference_id bigint,
    enabled boolean DEFAULT true NOT NULL,
    live boolean DEFAULT true NOT NULL,
    note character varying,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL
);

ALTER TABLE ONLY public.gates FORCE ROW LEVEL SECURITY;


--
-- Name: gates_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.gates_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: gates_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.gates_id_seq OWNED BY public.gates.id;


--
-- Name: passages; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.passages (
    id bigint NOT NULL,
    tenant_id bigint NOT NULL,
    feed_id bigint NOT NULL,
    "position" integer NOT NULL,
    starts_at integer NOT NULL,
    ends_at integer NOT NULL,
    text text NOT NULL,
    embedding double precision[],
    embedded_at timestamp(6) without time zone,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL
);

ALTER TABLE ONLY public.passages FORCE ROW LEVEL SECURITY;


--
-- Name: passages_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.passages_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: passages_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.passages_id_seq OWNED BY public.passages.id;


--
-- Name: resource_blobs; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.resource_blobs (
    id bigint NOT NULL,
    tenant_id bigint NOT NULL,
    resource_id bigint NOT NULL,
    key character varying NOT NULL,
    content_type character varying,
    bytes bytea NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL
);

ALTER TABLE ONLY public.resource_blobs FORCE ROW LEVEL SECURITY;


--
-- Name: resource_blobs_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.resource_blobs_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: resource_blobs_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.resource_blobs_id_seq OWNED BY public.resource_blobs.id;


--
-- Name: resources; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.resources (
    id bigint NOT NULL,
    tenant_id bigint NOT NULL,
    type character varying NOT NULL,
    key character varying NOT NULL,
    name character varying,
    details jsonb DEFAULT '{}'::jsonb NOT NULL,
    credentials text,
    archived_at timestamp(6) without time zone,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    sync_interval integer,
    next_sync_at timestamp(6) without time zone,
    sync_started_at timestamp(6) without time zone,
    synced_at timestamp(6) without time zone,
    checked_at timestamp(6) without time zone,
    check_error character varying,
    default_storage boolean DEFAULT false NOT NULL,
    default_inference boolean DEFAULT false NOT NULL,
    via_id bigint,
    serving jsonb DEFAULT '{}'::jsonb NOT NULL,
    connected_by character varying,
    needs_connect_at timestamp(6) without time zone,
    owner_subject character varying,
    sync_state jsonb DEFAULT '{}'::jsonb NOT NULL,
    walked_at timestamp(6) without time zone
);

ALTER TABLE ONLY public.resources FORCE ROW LEVEL SECURITY;


--
-- Name: resources_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.resources_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: resources_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.resources_id_seq OWNED BY public.resources.id;


--
-- Name: runs; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.runs (
    id bigint NOT NULL,
    tenant_id bigint NOT NULL,
    resource_id bigint,
    kind character varying NOT NULL,
    status character varying DEFAULT 'queued'::character varying NOT NULL,
    selector jsonb DEFAULT '{}'::jsonb NOT NULL,
    processed integer DEFAULT 0 NOT NULL,
    started_at timestamp(6) without time zone,
    finished_at timestamp(6) without time zone,
    deadline timestamp(6) without time zone,
    error character varying,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    logs text,
    lines integer DEFAULT 0 NOT NULL
);

ALTER TABLE ONLY public.runs FORCE ROW LEVEL SECURITY;


--
-- Name: runs_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.runs_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: runs_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.runs_id_seq OWNED BY public.runs.id;


--
-- Name: schedules; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.schedules (
    id bigint NOT NULL,
    tenant_id bigint NOT NULL,
    feed_id bigint NOT NULL,
    prompt text NOT NULL,
    turns integer,
    "interval" integer,
    paused_at timestamp(6) without time zone,
    next_run_at timestamp(6) without time zone,
    ran_at timestamp(6) without time zone,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL
);

ALTER TABLE ONLY public.schedules FORCE ROW LEVEL SECURITY;


--
-- Name: schedules_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.schedules_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: schedules_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.schedules_id_seq OWNED BY public.schedules.id;


--
-- Name: schema_migrations; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.schema_migrations (
    version character varying NOT NULL
);


--
-- Name: settings; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.settings (
    id bigint NOT NULL,
    tenant_id bigint NOT NULL,
    subject character varying,
    key character varying NOT NULL,
    value jsonb,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL
);

ALTER TABLE ONLY public.settings FORCE ROW LEVEL SECURITY;


--
-- Name: settings_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.settings_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: settings_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.settings_id_seq OWNED BY public.settings.id;


--
-- Name: tenants; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.tenants (
    id bigint NOT NULL,
    subdomain character varying NOT NULL,
    name character varying NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    client_id character varying,
    client_secret text,
    registration_access_token text,
    registration_client_uri character varying,
    connected_at timestamp(6) without time zone
);


--
-- Name: tenants_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.tenants_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: tenants_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.tenants_id_seq OWNED BY public.tenants.id;


--
-- Name: active_storage_attachments id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.active_storage_attachments ALTER COLUMN id SET DEFAULT nextval('public.active_storage_attachments_id_seq'::regclass);


--
-- Name: active_storage_blobs id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.active_storage_blobs ALTER COLUMN id SET DEFAULT nextval('public.active_storage_blobs_id_seq'::regclass);


--
-- Name: active_storage_variant_records id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.active_storage_variant_records ALTER COLUMN id SET DEFAULT nextval('public.active_storage_variant_records_id_seq'::regclass);


--
-- Name: analyses id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.analyses ALTER COLUMN id SET DEFAULT nextval('public.analyses_id_seq'::regclass);


--
-- Name: audit_events id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.audit_events ALTER COLUMN id SET DEFAULT nextval('public.audit_events_id_seq'::regclass);


--
-- Name: feed_edges id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.feed_edges ALTER COLUMN id SET DEFAULT nextval('public.feed_edges_id_seq'::regclass);


--
-- Name: feed_references id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.feed_references ALTER COLUMN id SET DEFAULT nextval('public.feed_references_id_seq'::regclass);


--
-- Name: feeds id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.feeds ALTER COLUMN id SET DEFAULT nextval('public.feeds_id_seq'::regclass);


--
-- Name: gates id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.gates ALTER COLUMN id SET DEFAULT nextval('public.gates_id_seq'::regclass);


--
-- Name: passages id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.passages ALTER COLUMN id SET DEFAULT nextval('public.passages_id_seq'::regclass);


--
-- Name: resource_blobs id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.resource_blobs ALTER COLUMN id SET DEFAULT nextval('public.resource_blobs_id_seq'::regclass);


--
-- Name: resources id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.resources ALTER COLUMN id SET DEFAULT nextval('public.resources_id_seq'::regclass);


--
-- Name: runs id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.runs ALTER COLUMN id SET DEFAULT nextval('public.runs_id_seq'::regclass);


--
-- Name: schedules id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.schedules ALTER COLUMN id SET DEFAULT nextval('public.schedules_id_seq'::regclass);


--
-- Name: settings id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.settings ALTER COLUMN id SET DEFAULT nextval('public.settings_id_seq'::regclass);


--
-- Name: tenants id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.tenants ALTER COLUMN id SET DEFAULT nextval('public.tenants_id_seq'::regclass);


--
-- Name: active_storage_attachments active_storage_attachments_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.active_storage_attachments
    ADD CONSTRAINT active_storage_attachments_pkey PRIMARY KEY (id);


--
-- Name: active_storage_blobs active_storage_blobs_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.active_storage_blobs
    ADD CONSTRAINT active_storage_blobs_pkey PRIMARY KEY (id);


--
-- Name: active_storage_variant_records active_storage_variant_records_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.active_storage_variant_records
    ADD CONSTRAINT active_storage_variant_records_pkey PRIMARY KEY (id);


--
-- Name: analyses analyses_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.analyses
    ADD CONSTRAINT analyses_pkey PRIMARY KEY (id);


--
-- Name: ar_internal_metadata ar_internal_metadata_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ar_internal_metadata
    ADD CONSTRAINT ar_internal_metadata_pkey PRIMARY KEY (key);


--
-- Name: audit_events audit_events_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.audit_events
    ADD CONSTRAINT audit_events_pkey PRIMARY KEY (id);


--
-- Name: feed_edges feed_edges_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.feed_edges
    ADD CONSTRAINT feed_edges_pkey PRIMARY KEY (id);


--
-- Name: feed_references feed_references_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.feed_references
    ADD CONSTRAINT feed_references_pkey PRIMARY KEY (id);


--
-- Name: feeds feeds_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.feeds
    ADD CONSTRAINT feeds_pkey PRIMARY KEY (id);


--
-- Name: gates gates_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.gates
    ADD CONSTRAINT gates_pkey PRIMARY KEY (id);


--
-- Name: passages passages_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.passages
    ADD CONSTRAINT passages_pkey PRIMARY KEY (id);


--
-- Name: resource_blobs resource_blobs_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.resource_blobs
    ADD CONSTRAINT resource_blobs_pkey PRIMARY KEY (id);


--
-- Name: resources resources_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.resources
    ADD CONSTRAINT resources_pkey PRIMARY KEY (id);


--
-- Name: runs runs_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.runs
    ADD CONSTRAINT runs_pkey PRIMARY KEY (id);


--
-- Name: schedules schedules_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.schedules
    ADD CONSTRAINT schedules_pkey PRIMARY KEY (id);


--
-- Name: schema_migrations schema_migrations_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.schema_migrations
    ADD CONSTRAINT schema_migrations_pkey PRIMARY KEY (version);


--
-- Name: settings settings_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.settings
    ADD CONSTRAINT settings_pkey PRIMARY KEY (id);


--
-- Name: tenants tenants_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.tenants
    ADD CONSTRAINT tenants_pkey PRIMARY KEY (id);


--
-- Name: index_active_storage_attachments_on_blob_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_active_storage_attachments_on_blob_id ON public.active_storage_attachments USING btree (blob_id);


--
-- Name: index_active_storage_attachments_on_tenant_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_active_storage_attachments_on_tenant_id ON public.active_storage_attachments USING btree (tenant_id);


--
-- Name: index_active_storage_attachments_uniqueness; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_active_storage_attachments_uniqueness ON public.active_storage_attachments USING btree (record_type, record_id, name, blob_id);


--
-- Name: index_active_storage_blobs_on_digest; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_active_storage_blobs_on_digest ON public.active_storage_blobs USING btree ((((metadata)::jsonb ->> 'digest'::text))) WHERE (((metadata)::jsonb ->> 'digest'::text) IS NOT NULL);


--
-- Name: index_active_storage_blobs_on_key; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_active_storage_blobs_on_key ON public.active_storage_blobs USING btree (key);


--
-- Name: index_active_storage_blobs_on_tenant_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_active_storage_blobs_on_tenant_id ON public.active_storage_blobs USING btree (tenant_id);


--
-- Name: index_active_storage_variant_records_on_tenant_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_active_storage_variant_records_on_tenant_id ON public.active_storage_variant_records USING btree (tenant_id);


--
-- Name: index_active_storage_variant_records_uniqueness; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_active_storage_variant_records_uniqueness ON public.active_storage_variant_records USING btree (blob_id, variation_digest);


--
-- Name: index_analyses_on_about_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_analyses_on_about_id ON public.analyses USING btree (about_id);


--
-- Name: index_analyses_on_feed_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_analyses_on_feed_id ON public.analyses USING btree (feed_id);


--
-- Name: index_analyses_on_reference_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_analyses_on_reference_id ON public.analyses USING btree (reference_id);


--
-- Name: index_analyses_on_tenant_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_analyses_on_tenant_id ON public.analyses USING btree (tenant_id);


--
-- Name: index_analyses_on_tenant_id_and_feed_id_and_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_analyses_on_tenant_id_and_feed_id_and_id ON public.analyses USING btree (tenant_id, feed_id, id);


--
-- Name: index_analyses_on_tenant_id_and_finished_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_analyses_on_tenant_id_and_finished_at ON public.analyses USING btree (tenant_id, finished_at);


--
-- Name: index_analyses_on_tenant_id_and_status; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_analyses_on_tenant_id_and_status ON public.analyses USING btree (tenant_id, status);


--
-- Name: index_audit_events_on_analysis_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_audit_events_on_analysis_id ON public.audit_events USING btree (analysis_id);


--
-- Name: index_audit_events_on_feed_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_audit_events_on_feed_id ON public.audit_events USING btree (feed_id);


--
-- Name: index_audit_events_on_tenant_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_audit_events_on_tenant_id ON public.audit_events USING btree (tenant_id);


--
-- Name: index_audit_events_on_tenant_id_and_actor_and_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_audit_events_on_tenant_id_and_actor_and_id ON public.audit_events USING btree (tenant_id, actor, id);


--
-- Name: index_audit_events_on_tenant_id_and_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_audit_events_on_tenant_id_and_id ON public.audit_events USING btree (tenant_id, id);


--
-- Name: index_audit_events_on_tenant_id_and_status_and_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_audit_events_on_tenant_id_and_status_and_id ON public.audit_events USING btree (tenant_id, status, id);


--
-- Name: index_feed_edges_on_a_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_feed_edges_on_a_id ON public.feed_edges USING btree (a_id);


--
-- Name: index_feed_edges_on_b_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_feed_edges_on_b_id ON public.feed_edges USING btree (b_id);


--
-- Name: index_feed_edges_on_tenant_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_feed_edges_on_tenant_id ON public.feed_edges USING btree (tenant_id);


--
-- Name: index_feed_edges_on_tenant_id_and_a_id_and_b_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_feed_edges_on_tenant_id_and_a_id_and_b_id ON public.feed_edges USING btree (tenant_id, a_id, b_id);


--
-- Name: index_feed_edges_on_tenant_id_and_b_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_feed_edges_on_tenant_id_and_b_id ON public.feed_edges USING btree (tenant_id, b_id);


--
-- Name: index_feed_references_on_feed_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_feed_references_on_feed_id ON public.feed_references USING btree (feed_id);


--
-- Name: index_feed_references_on_locator; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_feed_references_on_locator ON public.feed_references USING btree (tenant_id, resource_id, locator_key) WHERE (locator_key IS NOT NULL);


--
-- Name: index_feed_references_on_resource_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_feed_references_on_resource_id ON public.feed_references USING btree (resource_id);


--
-- Name: index_feed_references_on_tenant_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_feed_references_on_tenant_id ON public.feed_references USING btree (tenant_id);


--
-- Name: index_feed_references_on_tenant_id_and_analyzed_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_feed_references_on_tenant_id_and_analyzed_at ON public.feed_references USING btree (tenant_id, analyzed_at);


--
-- Name: index_feed_references_on_tenant_id_and_digest; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_feed_references_on_tenant_id_and_digest ON public.feed_references USING btree (tenant_id, digest) WHERE (digest IS NOT NULL);


--
-- Name: index_feed_references_on_tenant_id_and_feed_id_and_role; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_feed_references_on_tenant_id_and_feed_id_and_role ON public.feed_references USING btree (tenant_id, feed_id, role);


--
-- Name: index_feed_references_on_tenant_id_and_resource_id_and_seen_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_feed_references_on_tenant_id_and_resource_id_and_seen_at ON public.feed_references USING btree (tenant_id, resource_id, seen_at);


--
-- Name: index_feeds_awaiting_a_vector; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_feeds_awaiting_a_vector ON public.feeds USING btree (tenant_id, id) WHERE (embedded_at IS NULL);


--
-- Name: index_feeds_on_one_row_per_address; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_feeds_on_one_row_per_address ON public.feeds USING btree (tenant_id, type, key) WHERE ((type)::text = ANY (ARRAY[('uris:tag'::character varying)::text, ('uris:feed'::character varying)::text, ('uris:mime'::character varying)::text]));


--
-- Name: index_feeds_on_parent_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_feeds_on_parent_id ON public.feeds USING btree (parent_id);


--
-- Name: index_feeds_on_tenant_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_feeds_on_tenant_id ON public.feeds USING btree (tenant_id);


--
-- Name: index_feeds_on_tenant_id_and_created_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_feeds_on_tenant_id_and_created_at ON public.feeds USING btree (tenant_id, created_at);


--
-- Name: index_feeds_on_tenant_id_and_expires_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_feeds_on_tenant_id_and_expires_at ON public.feeds USING btree (tenant_id, expires_at) WHERE (expires_at IS NOT NULL);


--
-- Name: index_feeds_on_tenant_id_and_key; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_feeds_on_tenant_id_and_key ON public.feeds USING btree (tenant_id, key);


--
-- Name: index_feeds_on_tenant_id_and_origin; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_feeds_on_tenant_id_and_origin ON public.feeds USING btree (tenant_id, origin);


--
-- Name: index_feeds_on_tenant_id_and_parent_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_feeds_on_tenant_id_and_parent_id ON public.feeds USING btree (tenant_id, parent_id);


--
-- Name: index_feeds_on_tenant_id_and_type; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_feeds_on_tenant_id_and_type ON public.feeds USING btree (tenant_id, type);


--
-- Name: index_gates_on_scope; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_gates_on_scope ON public.gates USING btree (tenant_id, key, reference_type, reference_id) NULLS NOT DISTINCT;


--
-- Name: index_gates_on_tenant_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_gates_on_tenant_id ON public.gates USING btree (tenant_id);


--
-- Name: index_passages_on_feed_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_passages_on_feed_id ON public.passages USING btree (feed_id);


--
-- Name: index_passages_on_tenant_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_passages_on_tenant_id ON public.passages USING btree (tenant_id);


--
-- Name: index_passages_on_tenant_id_and_embedded_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_passages_on_tenant_id_and_embedded_at ON public.passages USING btree (tenant_id, embedded_at);


--
-- Name: index_passages_on_tenant_id_and_feed_id_and_position; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_passages_on_tenant_id_and_feed_id_and_position ON public.passages USING btree (tenant_id, feed_id, "position");


--
-- Name: index_resource_blobs_on_resource_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_resource_blobs_on_resource_id ON public.resource_blobs USING btree (resource_id);


--
-- Name: index_resource_blobs_on_tenant_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_resource_blobs_on_tenant_id ON public.resource_blobs USING btree (tenant_id);


--
-- Name: index_resource_blobs_on_tenant_id_and_resource_id_and_key; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_resource_blobs_on_tenant_id_and_resource_id_and_key ON public.resource_blobs USING btree (tenant_id, resource_id, key);


--
-- Name: index_resources_on_id_and_tenant_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_resources_on_id_and_tenant_id ON public.resources USING btree (id, tenant_id);


--
-- Name: index_resources_on_one_default_inference_per_tenant; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_resources_on_one_default_inference_per_tenant ON public.resources USING btree (tenant_id) WHERE default_inference;


--
-- Name: index_resources_on_one_default_storage_per_tenant; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_resources_on_one_default_storage_per_tenant ON public.resources USING btree (tenant_id) WHERE default_storage;


--
-- Name: index_resources_on_serving; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_resources_on_serving ON public.resources USING gin (serving);


--
-- Name: index_resources_on_sync_due; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_resources_on_sync_due ON public.resources USING btree (tenant_id, next_sync_at) WHERE (sync_interval IS NOT NULL);


--
-- Name: index_resources_on_tenant_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_resources_on_tenant_id ON public.resources USING btree (tenant_id);


--
-- Name: index_resources_on_tenant_id_and_owner_subject; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_resources_on_tenant_id_and_owner_subject ON public.resources USING btree (tenant_id, owner_subject);


--
-- Name: index_resources_on_tenant_id_and_type_and_key; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_resources_on_tenant_id_and_type_and_key ON public.resources USING btree (tenant_id, type, key);


--
-- Name: index_resources_on_via; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_resources_on_via ON public.resources USING btree (tenant_id, via_id) WHERE (via_id IS NOT NULL);


--
-- Name: index_runs_on_resource_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_runs_on_resource_id ON public.runs USING btree (resource_id);


--
-- Name: index_runs_on_tenant_and_selector_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_runs_on_tenant_and_selector_id ON public.runs USING btree (tenant_id, ((selector ->> 'id'::text)));


--
-- Name: index_runs_on_tenant_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_runs_on_tenant_id ON public.runs USING btree (tenant_id);


--
-- Name: index_runs_on_tenant_id_and_kind_and_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_runs_on_tenant_id_and_kind_and_id ON public.runs USING btree (tenant_id, kind, id);


--
-- Name: index_runs_on_tenant_id_and_status_and_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_runs_on_tenant_id_and_status_and_id ON public.runs USING btree (tenant_id, status, id);


--
-- Name: index_schedules_on_feed_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_schedules_on_feed_id ON public.schedules USING btree (feed_id);


--
-- Name: index_schedules_on_tenant_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_schedules_on_tenant_id ON public.schedules USING btree (tenant_id);


--
-- Name: index_schedules_on_tenant_id_and_feed_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_schedules_on_tenant_id_and_feed_id ON public.schedules USING btree (tenant_id, feed_id);


--
-- Name: index_schedules_on_tenant_id_and_next_run_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_schedules_on_tenant_id_and_next_run_at ON public.schedules USING btree (tenant_id, next_run_at) WHERE ((next_run_at IS NOT NULL) AND (paused_at IS NULL));


--
-- Name: index_settings_on_scope; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_settings_on_scope ON public.settings USING btree (tenant_id, subject, key) NULLS NOT DISTINCT;


--
-- Name: index_settings_on_tenant_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_settings_on_tenant_id ON public.settings USING btree (tenant_id);


--
-- Name: index_tenants_on_subdomain; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_tenants_on_subdomain ON public.tenants USING btree (subdomain);


--
-- Name: resource_blobs fk_rails_0740d6922f; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.resource_blobs
    ADD CONSTRAINT fk_rails_0740d6922f FOREIGN KEY (tenant_id) REFERENCES public.tenants(id);


--
-- Name: schedules fk_rails_084a346429; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.schedules
    ADD CONSTRAINT fk_rails_084a346429 FOREIGN KEY (tenant_id) REFERENCES public.tenants(id);


--
-- Name: runs fk_rails_0b416d37a1; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.runs
    ADD CONSTRAINT fk_rails_0b416d37a1 FOREIGN KEY (tenant_id) REFERENCES public.tenants(id);


--
-- Name: analyses fk_rails_0c7b97356e; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.analyses
    ADD CONSTRAINT fk_rails_0c7b97356e FOREIGN KEY (tenant_id) REFERENCES public.tenants(id);


--
-- Name: gates fk_rails_1402937732; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.gates
    ADD CONSTRAINT fk_rails_1402937732 FOREIGN KEY (tenant_id) REFERENCES public.tenants(id);


--
-- Name: feed_references fk_rails_2dbee6c560; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.feed_references
    ADD CONSTRAINT fk_rails_2dbee6c560 FOREIGN KEY (resource_id) REFERENCES public.resources(id);


--
-- Name: audit_events fk_rails_36cb9d4698; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.audit_events
    ADD CONSTRAINT fk_rails_36cb9d4698 FOREIGN KEY (feed_id) REFERENCES public.feeds(id) ON DELETE SET NULL;


--
-- Name: settings fk_rails_3a7e6495d2; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.settings
    ADD CONSTRAINT fk_rails_3a7e6495d2 FOREIGN KEY (tenant_id) REFERENCES public.tenants(id);


--
-- Name: active_storage_attachments fk_rails_416c0e3daf; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.active_storage_attachments
    ADD CONSTRAINT fk_rails_416c0e3daf FOREIGN KEY (tenant_id) REFERENCES public.tenants(id);


--
-- Name: active_storage_variant_records fk_rails_44b5c7c4a1; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.active_storage_variant_records
    ADD CONSTRAINT fk_rails_44b5c7c4a1 FOREIGN KEY (tenant_id) REFERENCES public.tenants(id);


--
-- Name: audit_events fk_rails_543bbbff97; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.audit_events
    ADD CONSTRAINT fk_rails_543bbbff97 FOREIGN KEY (analysis_id) REFERENCES public.analyses(id) ON DELETE SET NULL;


--
-- Name: feed_references fk_rails_610066d82a; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.feed_references
    ADD CONSTRAINT fk_rails_610066d82a FOREIGN KEY (feed_id) REFERENCES public.feeds(id);


--
-- Name: passages fk_rails_6ffbde4107; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.passages
    ADD CONSTRAINT fk_rails_6ffbde4107 FOREIGN KEY (feed_id) REFERENCES public.feeds(id) ON DELETE CASCADE;


--
-- Name: active_storage_blobs fk_rails_717534d285; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.active_storage_blobs
    ADD CONSTRAINT fk_rails_717534d285 FOREIGN KEY (tenant_id) REFERENCES public.tenants(id);


--
-- Name: feed_edges fk_rails_90f851ca9c; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.feed_edges
    ADD CONSTRAINT fk_rails_90f851ca9c FOREIGN KEY (tenant_id) REFERENCES public.tenants(id);


--
-- Name: analyses fk_rails_966b3de0ba; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.analyses
    ADD CONSTRAINT fk_rails_966b3de0ba FOREIGN KEY (about_id) REFERENCES public.feeds(id) ON DELETE SET NULL;


--
-- Name: active_storage_variant_records fk_rails_993965df05; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.active_storage_variant_records
    ADD CONSTRAINT fk_rails_993965df05 FOREIGN KEY (blob_id) REFERENCES public.active_storage_blobs(id);


--
-- Name: analyses fk_rails_9c589bf702; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.analyses
    ADD CONSTRAINT fk_rails_9c589bf702 FOREIGN KEY (reference_id) REFERENCES public.feed_references(id) ON DELETE SET NULL;


--
-- Name: passages fk_rails_a77c30c7e1; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.passages
    ADD CONSTRAINT fk_rails_a77c30c7e1 FOREIGN KEY (tenant_id) REFERENCES public.tenants(id);


--
-- Name: feed_edges fk_rails_a9d258f3a7; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.feed_edges
    ADD CONSTRAINT fk_rails_a9d258f3a7 FOREIGN KEY (a_id) REFERENCES public.feeds(id);


--
-- Name: feeds fk_rails_be542f409b; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.feeds
    ADD CONSTRAINT fk_rails_be542f409b FOREIGN KEY (parent_id) REFERENCES public.feeds(id);


--
-- Name: active_storage_attachments fk_rails_c3b3935057; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.active_storage_attachments
    ADD CONSTRAINT fk_rails_c3b3935057 FOREIGN KEY (blob_id) REFERENCES public.active_storage_blobs(id);


--
-- Name: feed_references fk_rails_c6d964abb8; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.feed_references
    ADD CONSTRAINT fk_rails_c6d964abb8 FOREIGN KEY (tenant_id) REFERENCES public.tenants(id);


--
-- Name: schedules fk_rails_ca53661ed7; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.schedules
    ADD CONSTRAINT fk_rails_ca53661ed7 FOREIGN KEY (feed_id) REFERENCES public.feeds(id);


--
-- Name: analyses fk_rails_cca65eba28; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.analyses
    ADD CONSTRAINT fk_rails_cca65eba28 FOREIGN KEY (feed_id) REFERENCES public.feeds(id);


--
-- Name: resource_blobs fk_rails_cdd1132dc5; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.resource_blobs
    ADD CONSTRAINT fk_rails_cdd1132dc5 FOREIGN KEY (resource_id) REFERENCES public.resources(id);


--
-- Name: runs fk_rails_d4068a5e91; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.runs
    ADD CONSTRAINT fk_rails_d4068a5e91 FOREIGN KEY (resource_id) REFERENCES public.resources(id);


--
-- Name: feed_edges fk_rails_dba2ee0e5c; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.feed_edges
    ADD CONSTRAINT fk_rails_dba2ee0e5c FOREIGN KEY (b_id) REFERENCES public.feeds(id);


--
-- Name: resources fk_rails_dc32a866bd; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.resources
    ADD CONSTRAINT fk_rails_dc32a866bd FOREIGN KEY (tenant_id) REFERENCES public.tenants(id);


--
-- Name: feeds fk_rails_e5c16162e1; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.feeds
    ADD CONSTRAINT fk_rails_e5c16162e1 FOREIGN KEY (tenant_id) REFERENCES public.tenants(id);


--
-- Name: audit_events fk_rails_fcd253d0d8; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.audit_events
    ADD CONSTRAINT fk_rails_fcd253d0d8 FOREIGN KEY (tenant_id) REFERENCES public.tenants(id);


--
-- Name: resources fk_resources_via; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.resources
    ADD CONSTRAINT fk_resources_via FOREIGN KEY (via_id, tenant_id) REFERENCES public.resources(id, tenant_id) ON DELETE RESTRICT;


--
-- Name: active_storage_attachments; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.active_storage_attachments ENABLE ROW LEVEL SECURITY;

--
-- Name: active_storage_blobs; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.active_storage_blobs ENABLE ROW LEVEL SECURITY;

--
-- Name: active_storage_variant_records; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.active_storage_variant_records ENABLE ROW LEVEL SECURITY;

--
-- Name: analyses; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.analyses ENABLE ROW LEVEL SECURITY;

--
-- Name: audit_events; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.audit_events ENABLE ROW LEVEL SECURITY;

--
-- Name: feed_edges; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.feed_edges ENABLE ROW LEVEL SECURITY;

--
-- Name: feed_references; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.feed_references ENABLE ROW LEVEL SECURITY;

--
-- Name: feeds; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.feeds ENABLE ROW LEVEL SECURITY;

--
-- Name: gates; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.gates ENABLE ROW LEVEL SECURITY;

--
-- Name: passages; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.passages ENABLE ROW LEVEL SECURITY;

--
-- Name: resource_blobs; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.resource_blobs ENABLE ROW LEVEL SECURITY;

--
-- Name: resources; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.resources ENABLE ROW LEVEL SECURITY;

--
-- Name: runs; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.runs ENABLE ROW LEVEL SECURITY;

--
-- Name: schedules; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.schedules ENABLE ROW LEVEL SECURITY;

--
-- Name: settings; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.settings ENABLE ROW LEVEL SECURITY;

--
-- Name: active_storage_attachments tenant_isolation; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY tenant_isolation ON public.active_storage_attachments USING ((tenant_id = (NULLIF(current_setting('uris.tenant_id'::text, true), ''::text))::bigint)) WITH CHECK ((tenant_id = (NULLIF(current_setting('uris.tenant_id'::text, true), ''::text))::bigint));


--
-- Name: active_storage_blobs tenant_isolation; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY tenant_isolation ON public.active_storage_blobs USING ((tenant_id = (NULLIF(current_setting('uris.tenant_id'::text, true), ''::text))::bigint)) WITH CHECK ((tenant_id = (NULLIF(current_setting('uris.tenant_id'::text, true), ''::text))::bigint));


--
-- Name: active_storage_variant_records tenant_isolation; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY tenant_isolation ON public.active_storage_variant_records USING ((tenant_id = (NULLIF(current_setting('uris.tenant_id'::text, true), ''::text))::bigint)) WITH CHECK ((tenant_id = (NULLIF(current_setting('uris.tenant_id'::text, true), ''::text))::bigint));


--
-- Name: analyses tenant_isolation; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY tenant_isolation ON public.analyses USING ((tenant_id = (NULLIF(current_setting('uris.tenant_id'::text, true), ''::text))::bigint)) WITH CHECK ((tenant_id = (NULLIF(current_setting('uris.tenant_id'::text, true), ''::text))::bigint));


--
-- Name: audit_events tenant_isolation; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY tenant_isolation ON public.audit_events USING ((tenant_id = (NULLIF(current_setting('uris.tenant_id'::text, true), ''::text))::bigint)) WITH CHECK ((tenant_id = (NULLIF(current_setting('uris.tenant_id'::text, true), ''::text))::bigint));


--
-- Name: feed_edges tenant_isolation; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY tenant_isolation ON public.feed_edges USING ((tenant_id = (NULLIF(current_setting('uris.tenant_id'::text, true), ''::text))::bigint)) WITH CHECK ((tenant_id = (NULLIF(current_setting('uris.tenant_id'::text, true), ''::text))::bigint));


--
-- Name: feed_references tenant_isolation; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY tenant_isolation ON public.feed_references USING ((tenant_id = (NULLIF(current_setting('uris.tenant_id'::text, true), ''::text))::bigint)) WITH CHECK ((tenant_id = (NULLIF(current_setting('uris.tenant_id'::text, true), ''::text))::bigint));


--
-- Name: feeds tenant_isolation; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY tenant_isolation ON public.feeds USING ((tenant_id = (NULLIF(current_setting('uris.tenant_id'::text, true), ''::text))::bigint)) WITH CHECK ((tenant_id = (NULLIF(current_setting('uris.tenant_id'::text, true), ''::text))::bigint));


--
-- Name: gates tenant_isolation; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY tenant_isolation ON public.gates USING ((tenant_id = (NULLIF(current_setting('uris.tenant_id'::text, true), ''::text))::bigint)) WITH CHECK ((tenant_id = (NULLIF(current_setting('uris.tenant_id'::text, true), ''::text))::bigint));


--
-- Name: passages tenant_isolation; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY tenant_isolation ON public.passages USING ((tenant_id = (NULLIF(current_setting('uris.tenant_id'::text, true), ''::text))::bigint)) WITH CHECK ((tenant_id = (NULLIF(current_setting('uris.tenant_id'::text, true), ''::text))::bigint));


--
-- Name: resource_blobs tenant_isolation; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY tenant_isolation ON public.resource_blobs USING ((tenant_id = (NULLIF(current_setting('uris.tenant_id'::text, true), ''::text))::bigint)) WITH CHECK ((tenant_id = (NULLIF(current_setting('uris.tenant_id'::text, true), ''::text))::bigint));


--
-- Name: resources tenant_isolation; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY tenant_isolation ON public.resources USING ((tenant_id = (NULLIF(current_setting('uris.tenant_id'::text, true), ''::text))::bigint)) WITH CHECK ((tenant_id = (NULLIF(current_setting('uris.tenant_id'::text, true), ''::text))::bigint));


--
-- Name: runs tenant_isolation; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY tenant_isolation ON public.runs USING ((tenant_id = (NULLIF(current_setting('uris.tenant_id'::text, true), ''::text))::bigint)) WITH CHECK ((tenant_id = (NULLIF(current_setting('uris.tenant_id'::text, true), ''::text))::bigint));


--
-- Name: schedules tenant_isolation; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY tenant_isolation ON public.schedules USING ((tenant_id = (NULLIF(current_setting('uris.tenant_id'::text, true), ''::text))::bigint)) WITH CHECK ((tenant_id = (NULLIF(current_setting('uris.tenant_id'::text, true), ''::text))::bigint));


--
-- Name: settings tenant_isolation; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY tenant_isolation ON public.settings USING ((tenant_id = (NULLIF(current_setting('uris.tenant_id'::text, true), ''::text))::bigint)) WITH CHECK ((tenant_id = (NULLIF(current_setting('uris.tenant_id'::text, true), ''::text))::bigint));


--
-- PostgreSQL database dump complete
--

SET search_path TO "$user", public;

INSERT INTO "schema_migrations" (version) VALUES
('20260927070000'),
('20260927060000'),
('20260927050000'),
('20260927040000'),
('20260927030000'),
('20260927010000'),
('20260926210000'),
('20260926200000'),
('20260921230000'),
('20260914010000'),
('20260914000000'),
('20260913160000'),
('20260913150000'),
('20260913140000'),
('20260913130000'),
('20260913120000'),
('20260912200000');

